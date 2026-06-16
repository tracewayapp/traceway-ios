import Foundation

public final class TracewayClient {

    private let apiUrl: String
    private let token: String
    let options: TracewayOptions
    private let sender: ReportSender
    private let store: ExceptionStore?

    private let lock = NSLock()
    private var pendingExceptions: [ExceptionStackTrace] = []
    private var deviceAttributes: [String: String] = [:]
    private var isSyncing = false
    private var debounceWorkItem: DispatchWorkItem?
    private var retryWorkItem: DispatchWorkItem?

    private let scheduler = DispatchQueue(label: "app.traceway.scheduler")

    init(apiUrl: String, token: String, options: TracewayOptions, persistDir: URL?, sender: ReportSender) {
        self.apiUrl = apiUrl
        self.token = token
        self.options = options
        self.sender = sender
        if options.persistToDisk, let persistDir = persistDir {
            let store = ExceptionStore(
                dir: persistDir,
                maxLocalFiles: options.maxLocalFiles,
                maxAgeHours: options.localFileMaxAgeHours
            )
            store.initialize()
            self.store = store
        } else {
            self.store = nil
        }
    }

    var debug: Bool { options.debug }

    func setDeviceAttributes(_ attributes: [String: String]) {
        lock.lock()
        deviceAttributes = attributes
        lock.unlock()
        Log.debug("device attributes: \(attributes)")
    }

    func currentDeviceAttributes() -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        return deviceAttributes
    }

    var appVersion: String { options.version }

    func loadPendingFromDisk() {
        guard let store = store, store.isAvailable else { return }
        let entries = store.loadAll()
        guard !entries.isEmpty else { return }
        lock.lock()
        for entry in entries {
            pendingExceptions.append(entry.exception)
        }
        trimPendingLocked()
        lock.unlock()
        Log.debug("loaded \(entries.count) pending entries from disk")
        scheduleSync()
    }

    public func capture(_ error: Error) {
        let formatted = CrashRecordStore.renderWireTrace(
            header: StackTraceFormatter.errorHeader(error),
            arch: BinaryImages.currentArch(),
            images: BinaryImages.capture(),
            addresses: Thread.callStackReturnAddresses.map { UInt(truncating: $0) }
        )
        addException(ExceptionStackTrace(
            stackTrace: formatted,
            recordedAtMs: ISO8601.nowMillis(),
            isMessage: false
        ))
    }

    public func capture(message: String) {
        addException(ExceptionStackTrace(
            stackTrace: message,
            recordedAtMs: ISO8601.nowMillis(),
            isMessage: true
        ))
    }

    func addException(_ exception: ExceptionStackTrace) {
        guard shouldSample() else {
            Log.debug("exception dropped by sampling")
            return
        }
        lock.lock()
        if !deviceAttributes.isEmpty {
            var merged = deviceAttributes
            if let own = exception.attributes {
                for (key, value) in own { merged[key] = value }
            }
            exception.attributes = merged
        }
        pendingExceptions.append(exception)
        if let store = store, let id = store.write(exception) {
            exception.fileId = id
        }
        trimPendingLocked()
        lock.unlock()

        scheduleSync()
    }

    public func flush(timeout: TimeInterval? = nil) {
        cancelDebounce()
        cancelRetry()
        let semaphore = DispatchSemaphore(value: 0)
        scheduler.async { [weak self] in
            self?.doSync()
            semaphore.signal()
        }
        if let timeout = timeout {
            _ = semaphore.wait(timeout: .now() + timeout)
        } else {
            semaphore.wait()
        }
    }

    private func shouldSample() -> Bool {
        if options.sampleRate >= 1.0 { return true }
        if options.sampleRate <= 0.0 { return false }
        return Double.random(in: 0..<1) < options.sampleRate
    }

    private func trimPendingLocked() {
        while pendingExceptions.count > options.maxPendingExceptions {
            let dropped = pendingExceptions.removeFirst()
            if let id = dropped.fileId { store?.remove([id]) }
            Log.debug("dropped oldest exception (buffer full)")
        }
    }

    private func scheduleSync() {
        lock.lock()
        debounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.doSync() }
        debounceWorkItem = work
        lock.unlock()
        scheduler.asyncAfter(deadline: .now() + Double(options.debounceMs) / 1000.0, execute: work)
    }

    private func cancelDebounce() {
        lock.lock()
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        lock.unlock()
    }

    private func cancelRetry() {
        lock.lock()
        retryWorkItem?.cancel()
        retryWorkItem = nil
        lock.unlock()
    }

    private func scheduleRetry() {
        lock.lock()
        if retryWorkItem != nil { lock.unlock(); return }
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.lock.lock(); self.retryWorkItem = nil; self.lock.unlock()
            self.doSync()
        }
        retryWorkItem = work
        lock.unlock()
        scheduler.asyncAfter(deadline: .now() + Double(options.retryDelayMs) / 1000.0, execute: work)
    }

    private func doSync() {
        let batch: [ExceptionStackTrace]
        lock.lock()
        if isSyncing { lock.unlock(); return }
        if pendingExceptions.isEmpty { lock.unlock(); return }
        isSyncing = true
        batch = pendingExceptions
        pendingExceptions.removeAll()
        lock.unlock()

        let frame = CollectionFrame(stackTraces: batch)
        let payload = ReportRequest(collectionFrames: [frame], appVersion: options.version, serverName: "")
        let jsonBody = payload.serialized()
        Log.debug("payload_size_bytes=\(jsonBody.utf8.count)")

        var failed = false
        let success = sender.send(apiUrl: apiUrl, token: token, jsonBody: jsonBody)
        if success {
            let fileIds = batch.compactMap { $0.fileId }
            if !fileIds.isEmpty { store?.remove(fileIds) }
        } else {
            failed = true
            lock.lock()
            pendingExceptions.insert(contentsOf: batch, at: 0)
            trimPendingLocked()
            lock.unlock()
            Log.warn("sync failed, re-queued exceptions")
        }

        let hasMore: Bool
        lock.lock()
        isSyncing = false
        hasMore = !pendingExceptions.isEmpty
        lock.unlock()

        if hasMore {
            if failed {
                scheduleRetry()
            } else {
                scheduler.async { [weak self] in self?.doSync() }
            }
        }
    }

    private static let sharedLock = NSLock()
    private static var _shared: TracewayClient?

    public static var shared: TracewayClient? {
        sharedLock.lock(); defer { sharedLock.unlock() }
        return _shared
    }

    @discardableResult
    static func parseAndCreate(
        connectionString: String,
        options: TracewayOptions,
        persistDir: URL?,
        sender: ReportSender
    ) throws -> TracewayClient {
        let parsed = try parseConnectionString(connectionString)
        let client = TracewayClient(
            apiUrl: parsed.apiUrl,
            token: parsed.token,
            options: options,
            persistDir: persistDir,
            sender: sender
        )
        sharedLock.lock()
        _shared = client
        sharedLock.unlock()
        return client
    }

    static func initializeForTesting(
        connectionString: String,
        options: TracewayOptions,
        persistDir: URL? = nil,
        sender: ReportSender
    ) throws -> TracewayClient {
        try parseAndCreate(
            connectionString: connectionString,
            options: options,
            persistDir: persistDir,
            sender: sender
        )
    }

    static func resetForTest() {
        sharedLock.lock()
        let client = _shared
        _shared = nil
        sharedLock.unlock()
        client?.cancelDebounce()
        client?.cancelRetry()
    }

    func pendingExceptionCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return pendingExceptions.count
    }

    func pendingExceptionsSnapshot() -> [ExceptionStackTrace] {
        lock.lock(); defer { lock.unlock() }
        return pendingExceptions
    }
}
