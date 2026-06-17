import Foundation

public enum Traceway {

    @discardableResult
    public static func start(
        connectionString: String,
        options: TracewayOptions = TracewayOptions()
    ) -> TracewayClient? {
        if let existing = TracewayClient.shared { return existing }
        Log.debugEnabled = options.debug

        let baseDir = supportDirectory()
        let persistDir = baseDir?.appendingPathComponent("traceway_pending")

        let client: TracewayClient
        do {
            client = try TracewayClient.parseAndCreate(
                connectionString: connectionString,
                options: options,
                persistDir: persistDir,
                sender: DefaultReportSender()
            )
        } catch {
            Log.warn("invalid connection string: \(error)")
            return nil
        }

        client.setDeviceAttributes(DeviceInfoCollector.collectSync())

        if let baseDir = baseDir {
            CrashReporter.install(client: client, baseDir: baseDir, persistToDisk: options.persistToDisk)
            CrashReporter.convertPendingCrashes(client: client, baseDir: baseDir)
        }

        client.loadPendingFromDisk()

        DispatchQueue.global(qos: .utility).async {
            let asyncInfo = DeviceInfoCollector.collectAsync()
            guard !asyncInfo.isEmpty else { return }
            var merged = client.currentDeviceAttributes()
            for (key, value) in asyncInfo { merged[key] = value }
            client.setDeviceAttributes(merged)
            CrashReporter.updateMetadata(client: client)
        }

        return client
    }

    @inline(never)
    public static func capture(_ error: Error) {
        let callStack = Array(Thread.callStackReturnAddresses.map { UInt(truncating: $0) }.dropFirst(1))
        TracewayClient.shared?.capture(error, callStack: callStack)
    }

    @inline(never)
    public static func capture(error: NSError) {
        let callStack = Array(Thread.callStackReturnAddresses.map { UInt(truncating: $0) }.dropFirst(1))
        TracewayClient.shared?.capture(error as Error, callStack: callStack)
    }

    public static func capture(message: String) {
        TracewayClient.shared?.capture(message: message)
    }

    public static func recordAction(category: String, name: String, data: [String: Any]? = nil) {
        Log.debug("recordAction \(category)/\(name)")
    }

    public static func flush(timeout: TimeInterval? = nil) {
        TracewayClient.shared?.flush(timeout: timeout)
    }

    private static func supportDirectory() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    }
}
