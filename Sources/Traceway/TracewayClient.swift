import Foundation
import OpenTelemetryApi
import OpenTelemetrySdk

/// Replaces the parts of the SDK that touch the platform or the network, so
/// tests can run it against in-memory exporters and a fake server.
struct TracewayTestOverrides {
    var logExporter: LogRecordExporter?
    var spanExporter: SpanExporter?
    var transport: HTTPTransport?
    /// Nil keeps state in memory only.
    var stateDirectory: URL?
    var deviceAttributes: [String: String] = [:]
    var random: (() -> Double)?
    var opampMinPollIntervalMs: Int64?
    /// Stands in for the wireframe recorder.
    var replaySource: ReplaySource?
    /// Receives each metrics payload instead of the network and answers with
    /// an HTTP status. Without it, a test that keeps OTLP logs in memory
    /// (`logExporter`) has its metrics discarded, and one that does not
    /// sends them through `transport`.
    var metricsSink: ((Data) -> Int)?
    var metricsScheduler: MetricsScheduler?
}

private let maxErrorsPerMinute = 60
private let duplicateErrorWindowMs: Int64 = 1000
private let maxGlobalAttributes = 64
/// A rule may answer the event of another rule's `emit` action this many
/// deep; a rule that emits what it matches would otherwise never return.
private let maxEmitDepth = 4
/// The first health report waits this long; each next one twice as long, up
/// to `maxHealthDelayMs`, as the browser SDK does.
private let healthDelayMs = 1000
private let maxHealthDelayMs = 300_000

/// The Traceway SDK. Start it with `Traceway.initialize`; `TracewayClient.shared`
/// is the running instance.
///
/// Every record is an OpenTelemetry log record or span made with the
/// official opentelemetry-swift SDK. The client routes each one by its
/// signal's mode (stream, buffer, off) from the effective settings — the
/// built-in defaults, the app's `collection`, the server's rules over OpAMP,
/// clamped to the ceilings the options set — and runs triggers and captures
/// on every record. All state lives on one serial queue.
public final class TracewayClient {
    private static let queueKey = DispatchSpecificKey<UInt8>()
    private static let sharedLock = NSLock()
    private static var _shared: TracewayClient?

    /// The running client, or nil before `Traceway.initialize`.
    public static var shared: TracewayClient? {
        sharedLock.lock(); defer { sharedLock.unlock() }
        return _shared
    }

    let queue = DispatchQueue(label: "app.traceway.client", qos: .utility)
    let options: TracewayOptions
    private let overrides: TracewayTestOverrides?
    /// Without a connection string the SDK runs standalone: no OpAMP, no
    /// replay uploads, no session records, and every record goes to the
    /// `telemetry` receivers.
    let standalone: Bool
    private let token: String?
    let endpoints: TracewayEndpoints?
    let routes: TelemetryRoutes
    let control: ControlState
    let buffer: RingBuffer<TelemetryItem>
    let triggers: TriggerEngine
    let transport: HTTPTransport
    let recordings: RecordingsTransport
    let replay: ReplayController
    /// App performance metrics: the aggregates and their uploads.
    let metrics: MetricsRecorder
    let memoryPeaks: MemoryPeaks
    /// Start, display, frame and hang measurements; nil without
    /// `captureMetrics`. The UIKit hooks give it its host.
    let vitals: AppVitals?
    /// What the metrics pipeline reads from any thread: the session, the
    /// installation id, the resource and the state store, as the client's
    /// queue last set them.
    private let metricsSession = Locked<String?>(nil)
    private let metricsInstallation = Locked("")
    private let metricsResource = Locked<[String: String]>([:])
    private let metricsStore = Locked(StateStore(directory: nil))

    private var globalAttributes: [String: String] = [:]
    private(set) var resourceAttributes: [String: String] = [:]
    private(set) var store = StateStore(directory: nil) {
        didSet { metricsStore.value = store }
    }
    private var outbox: Outbox?
    /// Traceway's queue when the live one belongs to another receiver.
    private var tracewayOutbox: Outbox?
    private var persisted: BufferPersistence?
    private(set) var sessions: SessionManager?
    private(set) var router: TelemetryRouter?
    private var logSink: BatchLogRecordProcessor?
    private var spanSink: SpanBatcher?
    private var loggerProvider: LoggerProviderSdk?
    private var tracerProvider: TracerProviderSdk?
    private var logger: OpenTelemetryApi.Logger?
    private(set) var tracer: Tracer?
    private var opamp: OpampClient?
    private(set) var instanceUid: [UInt8] = Array(repeating: 0, count: 16)
    private(set) var screenRecorder: ReplaySource?
    private var stateDirectory: URL?

    private var started = false
    private let shutdownLock = NSLock()
    private var shutdownState = false
    /// Read from the main thread too (taps, navigation), so it is locked.
    private(set) var isShutdown: Bool {
        get {
            shutdownLock.lock(); defer { shutdownLock.unlock() }
            return shutdownState
        }
        set {
            shutdownLock.lock()
            shutdownState = newValue
            shutdownLock.unlock()
        }
    }
    private var emitDepth = 0
    private var errorTimes: [Int64] = []
    private var lastErrorKey: String?
    private var lastErrorMs: Int64 = 0
    private var suppressedErrors = 0
    /// Errors suppressed in this run, reported on session and health events.
    private var suppressedErrorsTotal = 0
    private var healthTimer: DispatchWorkItem?
    private var nextHealthDelayMs = healthDelayMs
    private var healthReported = false
    /// The images policy in effect when the current session started.
    private var sessionImages: (id: String, policy: TracewayImagePolicy)?
    /// Sessions whose start (or resumption) was reported in this run: their
    /// end is reported too, and only theirs.
    private var reportedSessions: Set<String> = []
    /// Captures known only from the cached config keep streaming, but start
    /// nothing new until the server has answered.
    private var capturesConfirmed = false
    private var overrideTimer: DispatchWorkItem?
    private var refreshTimer: DispatchWorkItem?
    private var flushTimer: DispatchWorkItem?
    private var progressTimer: DispatchWorkItem?
    private var savedProgressVersion = -1
    private var savedProgress = ""
    private var lastProgressSaveMs: Int64 = 0
    /// Clips flushed so far; an exception compares it before and after its
    /// triggers run.
    private var replayFlushes = 0
    /// Where the app is, for the records that name the screen.
    let screen = ScreenState()
    /// The path of the screen on top, as the last navigation reported it.
    var currentScreen: String? { screen.name }
    /// Event types (`click`, `navigation`, ...) the triggers name.
    private var sequenceKinds: Set<String> = []
    private var screenObservedForSequences = false

    /// What the main thread needs to know to record taps without touching
    /// the client's queue.
    let interaction = InteractionState()

    // MARK: - Starting

    init(connectionString: String?, options: TracewayOptions, overrides: TracewayTestOverrides? = nil) throws {
        self.options = options
        self.overrides = overrides
        standalone = connectionString == nil
        if let connectionString = connectionString {
            let parsed = try parseConnectionString(connectionString)
            token = parsed.token
            endpoints = try resolveEndpoints(parsed.apiUrl)
        } else {
            guard options.telemetry?.coversAllSignals == true else {
                throw ConfigurationError(description:
                    "Without a connection string, TracewayOptions.telemetry needs a url or all three signal endpoints")
            }
            token = nil
            endpoints = nil
        }
        routes = try TelemetryRoutes.resolve(endpoints: endpoints, token: token, telemetry: options.telemetry)
        for (key, value) in options.attributes where globalAttributes.count < maxGlobalAttributes {
            globalAttributes[key] = value
        }

        var defaults = defaultSettings(
            baselineSampleRate: options.baselineSampleRate,
            recordAllSessions: options.recordAllSessions
        )
        let errorRate = options.sampleRate.isFinite ? min(max(options.sampleRate, 0), 1) : 1
        defaults.signals["errors"]?.sampleRate = errorRate
        defaults.signals["messages"]?.sampleRate = errorRate
        if let collection = options.collection {
            do {
                let data = try JSONSerialization.data(withJSONObject: collection)
                defaults = applyOverlay(defaults, try parseSettingsDocument(data))
            } catch {
                NSLog("[Traceway] ignoring TracewayOptions.collection: %@", "\(error)")
            }
        }
        let screenCapture = options.screenCapture && !standalone
        control = ControlState(
            defaults: defaults,
            ceilings: ceilingsFrom(
                screenCapture: screenCapture,
                captureLogs: options.captureLogs,
                captureNetwork: options.captureNetwork,
                captureNavigation: options.captureNavigation,
                captureUserActions: options.captureUserActions,
                // Standalone, nothing receives the session rows; the session
                // id still correlates records and samples.
                sessions: options.sessions && !standalone,
                captureMetrics: options.captureMetrics,
                replayImages: options.replayImages
            )
        )
        let settings = control.settings
        buffer = RingBuffer(
            maxBytes: settings.bufferMaxBytes,
            maxAgeMs: Int64(settings.bufferMaxAgeSeconds * 1000)
        )
        triggers = TriggerEngine(random: overrides?.random ?? { Double.random(in: 0..<1) })
        triggers.setTriggers(settings.triggers)
        transport = overrides?.transport ?? URLSessionTransport.shared
        recordings = RecordingsTransport(url: endpoints?.recordings, token: token ?? "", transport: transport)
        // A streamed segment must leave before the frame ring wraps.
        let fps = min(max(options.fps, 1), 15)
        let ringMs = max(1, options.maxBufferFrames) * 1000 / fps
        var sessionsRef: (() -> SessionManager?)?
        replay = ReplayController(
            transport: recordings,
            queue: queue,
            sessionId: { sessionsRef?()?.currentId },
            nextSegmentIndex: { sessionsRef?()?.nextSegmentIndex() ?? 0 },
            segmentMs: min(max(Int(Double(ringMs) * 0.8), 200), 10_000)
        )

        let scheduler = overrides?.metricsScheduler ?? DispatchMetricsScheduler()
        let send: (Data) -> Int
        if let sink = overrides?.metricsSink {
            send = sink
        } else if overrides?.logExporter != nil {
            send = { _ in 200 }
        } else {
            let destination = routes.metrics
            let transport = self.transport
            send = { TracewayClient.postMetrics($0, to: destination, transport: transport) }
        }
        let session = metricsSession, installation = metricsInstallation
        let resource = metricsResource, store = metricsStore
        metrics = MetricsRecorder(
            settings: settings.activeMetrics,
            sessionId: { session.value },
            installationId: { installation.value },
            resource: { resource.value },
            send: send,
            store: { store.value },
            scheduler: scheduler,
            dimensions: options.metricDimensions,
            deferUntilStart: true,
            storageScope: routes.metrics.key
        )
        memoryPeaks = MemoryPeaks(recorder: metrics, store: { store.value }, storageScope: routes.metrics.key)
        if options.captureMetrics {
            let screen = self.screen
            vitals = AppVitals(
                recorder: metrics,
                currentScreen: { TracewayClient.metricsScreen(screen) },
                scheduler: scheduler,
                reportHangsWithDebugger: options.reportHangsInDebug
            )
        } else {
            vitals = nil
        }

        queue.setSpecific(key: TracewayClient.queueKey, value: 1)
        sessionsRef = { [weak self] in self?.sessions }
    }

    /// Starts a client and makes it the shared one. Device information is
    /// read on the calling thread (the main thread at app launch), the rest
    /// on the client's queue.
    @discardableResult
    static func start(
        connectionString: String?,
        options: TracewayOptions,
        overrides: TracewayTestOverrides? = nil
    ) throws -> TracewayClient {
        let sdkStartMs = AppVitals.monotonicMs()
        sharedLock.lock()
        if let existing = _shared, !existing.isShutdown {
            sharedLock.unlock()
            return existing
        }
        sharedLock.unlock()
        Log.debugEnabled = options.debug
        let client = try TracewayClient(connectionString: connectionString, options: options, overrides: overrides)
        if overrides == nil {
            client.vitals?.watchColdStart(sdkStartMs: sdkStartMs, processStartMs: AppVitals.processStartMonotonicMs())
        }
        let device = overrides?.deviceAttributes
            ?? DeviceInfoCollector.collectSync().merging(DeviceDimensions.collect()) { $1 }
        client.queue.sync { client.startOnQueue(device: device) }
        sharedLock.lock()
        _shared = client
        sharedLock.unlock()
        client.installPlatformHooks()
        return client
    }

    private func startOnQueue(device: [String: String]) {
        let stateDir = resolveStateDirectory()
        stateDirectory = stateDir
        store = StateStore(directory: stateDir, destination: routes.traceway?.key ?? bufferDestination)
        store.load()
        replay.budget.store = store
        replay.onBudgetDrop = { [weak self] in self?.scheduleHealth() }
        recordings.onFailure = { [weak self] in self?.onQueue { self?.scheduleHealth() } }

        if let saved = store.get("instanceUid")?.string, let uid = Ids.uuidBytes(saved) {
            instanceUid = uid
        } else {
            instanceUid = Ids.uuidBytes(Ids.uuidv7()) ?? Ids.randomBytes(16)
            store.set("instanceUid", .string(Ids.uuidString(instanceUid)))
        }
        metricsInstallation.value = Ids.uuidString(instanceUid)

        var appliedHash: [UInt8]?
        if remoteConfigEnabled, let cached = store.get("config")?.object,
           let body = cached["body"]?.string, let hash = cached["hash"]?.string,
           let overlay = try? parseSettingsDocument(body) {
            control.applyRemote(overlay)
            appliedHash = Ids.bytes(hex: hash)
        }
        triggers.setTriggers(control.settings.triggers)

        buildResource(device)
        metricsResource.value = resourceAttributes
        setUpOTel(stateDir)

        // Sessions always run: their id correlates records, samples and keys
        // trigger state. `sessions` only decides whether session records are
        // sent.
        let manager = SessionManager(
            store: store,
            queue: queue,
            onStart: { [weak self] session, resumed in self?.onSessionStart(session, resumed: resumed) },
            onEnd: { [weak self] session, endedAt in self?.onSessionEnd(session, endedAtMs: endedAt) }
        )
        sessions = manager
        manager.start()

        if let stateDir = stateDir {
            let persistence = BufferPersistence(directory: stateDir, destination: bufferDestination)
            persisted = persistence
            let settings = control.settings
            if settings.persist {
                let restored = persistence.load(
                    sessionId: manager.currentId,
                    maxAgeMs: Int64(settings.bufferMaxAgeSeconds * 1000),
                    maxBytes: settings.bufferMaxBytes
                ).filter { control.canExport($0.signal) }
                if !restored.isEmpty {
                    // Older than anything recorded since the start: they go first.
                    let recent = buffer.snapshot()
                    buffer.clear()
                    for entry in restored + recent { buffer.push(entry) }
                    Log.debug("restored \(restored.count) buffered records")
                }
            } else {
                persistence.clear()
            }
        }

        reportEarlierRuns(stateDir)

        if remoteConfigEnabled, let endpoints = endpoints {
            let client = OpampClient(
                endpoint: endpoints.opamp,
                headers: ["Authorization": "Bearer \(token ?? "")"],
                instanceUid: instanceUid,
                capabilities: AgentCapabilities.reportsStatus | AgentCapabilities.acceptsRemoteConfig
                    | AgentCapabilities.reportsRemoteConfig | AgentCapabilities.reportsHeartbeat,
                customCapabilities: [
                    "io.traceway.sdk.buffer/v1",
                    "io.traceway.sdk.capture/v1",
                    "io.traceway.sdk.sequence-triggers/v1",
                ],
                describe: { [weak self] in self?.describe() ?? AgentDescription(identifying: [:], nonIdentifying: [:]) },
                onRemoteConfig: { [weak self] config in self?.applyRemoteConfig(config) ?? .failed("stopped") },
                appliedConfigHash: appliedHash,
                onInstanceUidChange: { [weak self] uid in
                    self?.instanceUid = uid
                    self?.metricsInstallation.value = Ids.uuidString(uid)
                    self?.store.set("instanceUid", .string(Ids.uuidString(uid)))
                },
                onStopped: { code in Log.warn("remote config stopped (HTTP \(code))") },
                minPollIntervalMs: overrides?.opampMinPollIntervalMs ?? 30_000,
                transport: transport,
                queue: queue
            )
            opamp = client
            client.start()
        }

        started = true
        if options.captureMetrics {
            let settings = control.settings
            metrics.configure(settings.activeMetrics, flushSeconds: settings.metrics.flushSeconds)
            metrics.start()
        }
        control.onChange { [weak self] settings in self?.onSettingsChanged(settings) }
        restoreLocalCaptures()
        onSettingsChanged(control.settings)
        if let opamp = opamp {
            opamp.poll { [weak self] in self?.confirmCaptures() }
        } else {
            confirmCaptures()
        }
        outbox?.schedule(afterMs: 2000)
        tracewayOutbox?.schedule(afterMs: 2000)
        Log.debug("started, instance \(Ids.uuidString(instanceUid))")
    }

    private var remoteConfigEnabled: Bool { options.remoteConfig && !standalone }

    private func resolveStateDirectory() -> URL? {
        if let overrides = overrides { return overrides.stateDirectory }
        guard options.persistToDisk else { return nil }
        return supportDirectory()?.appendingPathComponent("traceway_v2")
    }

    func supportDirectory() -> URL? {
        if let overrides = overrides { return overrides.stateDirectory?.deletingLastPathComponent() }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    }

    private var bufferDestination: String {
        Ids.fingerprint64(JSON([routes.traceway?.key ?? "", routes.logs.key, routes.traces.key]).encoded())
    }

    var serviceName: String {
        if let name = options.serviceName, !name.isEmpty { return name }
        return Bundle.main.bundleIdentifier ?? "ios-app"
    }

    var serviceVersion: String {
        if !options.version.isEmpty { return options.version }
        let bundle = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return bundle?.isEmpty == false ? bundle! : "unknown"
    }

    private func buildResource(_ device: [String: String]) {
        var attrs = device
        attrs["service.name"] = serviceName
        attrs["service.version"] = serviceVersion
        attrs["service.instance.id"] = Ids.uuidString(instanceUid)
        attrs["telemetry.sdk.language"] = "swift"
        attrs["traceway.sdk.name"] = TracewaySDK.name
        attrs["traceway.sdk.version"] = TracewaySDK.version
        if let environment = options.environment, !environment.isEmpty {
            attrs["deployment.environment.name"] = environment
        }
        // The SDK's performance numbers arrive as metrics: the server must
        // not count them a second time from the records.
        if options.captureMetrics { attrs["traceway.metrics"] = "aggregated" }
        resourceAttributes = attrs
    }

    private func setUpOTel(_ stateDir: URL?) {
        func dir(_ name: String) -> URL? { stateDir?.appendingPathComponent(name) }
        var auth: [String: String] = [:]
        if let token = token { auth["Authorization"] = "Bearer \(token)" }
        // Batches queued for Traceway wait in `outbox`; batches for another
        // receiver wait in a directory of their own destinations.
        let tracewayOutbox = endpoints.map {
            Outbox(
                directory: dir("outbox"),
                destinations: [
                    "logs": OtlpDestination(url: $0.logs, headers: auth),
                    "traces": OtlpDestination(url: $0.traces, headers: auth),
                ],
                transport: transport
            )
        }
        let external = routes.logs.external || routes.traces.external
        let externalName = external
            ? "outbox-" + Ids.fingerprint64(JSON([routes.logs.key, routes.traces.key]).encoded())
            : nil
        let live: Outbox
        if externalName == nil, let tracewayOutbox = tracewayOutbox {
            live = tracewayOutbox
        } else {
            live = Outbox(
                directory: dir(externalName ?? "outbox"),
                destinations: ["logs": routes.logs, "traces": routes.traces],
                transport: transport
            )
        }
        outbox = live
        self.tracewayOutbox = tracewayOutbox === live ? nil : tracewayOutbox
        live.claim()
        self.tracewayOutbox?.claim()
        pruneOutboxes(stateDir, keep: externalName)

        var logExporter = overrides?.logExporter ?? makeLogExporter(routes.logs, outbox: live, transport: transport)
        if routes.splitsLogs, let traceway = routes.traceway, let tracewayOutbox = tracewayOutbox {
            logExporter = RoutingLogExporter(
                inner: logExporter,
                traceway: makeLogExporter(traceway, outbox: tracewayOutbox, transport: transport)
            )
        }
        let spanExporter = overrides?.spanExporter ?? makeSpanExporter(routes.traces, outbox: live, transport: transport)
        let delayMs = max(50, options.exportDelayMs)
        let logSink = BatchLogRecordProcessor(
            logRecordExporter: logExporter,
            scheduleDelay: Double(delayMs) / 1000
        )
        let spanSink = SpanBatcher(exporter: spanExporter, delayMs: delayMs)
        self.logSink = logSink
        self.spanSink = spanSink
        let router = TelemetryRouter(
            control: control,
            buffer: buffer,
            logSink: logSink,
            spanSink: spanSink,
            logExporter: logExporter,
            spanExporter: spanExporter,
            hooks: self,
            random: overrides?.random ?? { Double.random(in: 0..<1) }
        )
        if stateDir != nil, overrides?.logExporter == nil {
            let issues = self.tracewayOutbox ?? live
            router.persistIssue = { record in issues.persist(logs: [record]) }
        }
        self.router = router

        var resourceValues: [String: AttributeValue] = [:]
        for (key, value) in resourceAttributes { resourceValues[key] = .string(value) }
        let resource = Resource().merging(other: Resource(attributes: resourceValues))
        let logProcessor = ControlLogProcessor(
            route: { [weak self] record in self?.onQueue { self?.router?.routeLog(record) } },
            sink: { [weak self] in self?.logSink }
        )
        let spanProcessor = ControlSpanProcessor(
            route: { [weak self] span in
                self?.observeRequest(span)
                self?.onQueue { self?.router?.routeSpan(span) }
            }
        )
        let loggerProvider = LoggerProviderBuilder()
            .with(resource: resource)
            .with(processors: [logProcessor])
            .build()
        let tracerProvider = TracerProviderBuilder()
            .with(resource: resource)
            .add(spanProcessor: spanProcessor)
            .build()
        self.loggerProvider = loggerProvider
        self.tracerProvider = tracerProvider
        logger = loggerProvider.loggerBuilder(instrumentationScopeName: TracewaySDK.name)
            .setInstrumentationVersion(TracewaySDK.version)
            .build()
        tracer = tracerProvider.get(instrumentationName: TracewaySDK.name, instrumentationVersion: TracewaySDK.version)
        // An app without OpenTelemetry of its own gets these providers as the
        // global ones, so its spans and logs join the session; an app with
        // its own keeps them.
        if overrides == nil {
            if OpenTelemetry.instance.loggerProvider is DefaultLoggerProvider {
                OpenTelemetry.registerLoggerProvider(loggerProvider: loggerProvider)
            }
            if OpenTelemetry.instance.tracerProvider is DefaultTracerProvider {
                OpenTelemetry.registerTracerProvider(tracerProvider: tracerProvider)
            }
        }
    }

    /// Queues of receivers no longer configured: nothing would send them.
    private func pruneOutboxes(_ stateDir: URL?, keep: String?) {
        guard let stateDir = stateDir,
              let names = try? FileManager.default.contentsOfDirectory(atPath: stateDir.path)
        else { return }
        for name in names where name.hasPrefix("outbox-") && name != keep {
            try? FileManager.default.removeItem(at: stateDir.appendingPathComponent(name))
        }
    }

    /// Crashes the signal handler wrote in an earlier run, and reports the
    /// 1.x SDK left unsent, are reported now with their original time and
    /// the session they happened in.
    private func reportEarlierRuns(_ stateDir: URL?) {
        let base = supportDirectory()
        for crash in CrashReporter.takePendingCrashes(baseDir: base) {
            var attributes: [String: AttributeValue] = [:]
            for (key, value) in crash.attributes ?? [:] {
                if key == Attr.sessionStartedAt, let ms = Int(value) {
                    attributes[key] = .int(ms)
                } else {
                    attributes[key] = .string(value)
                }
            }
            attributes["exception.type"] = .string(crash.header)
            attributes["exception.stacktrace"] = .string(crash.stackTrace)
            attributes["exception.escaped"] = .bool(true)
            attributes["traceway.crash"] = .bool(true)
            attributes[Attr.exceptionId] = .string(Ids.uuidv4())
            emit(eventName: Events.exception, severity: .fatal, attributes: attributes,
                 time: Clock.date(ms: crash.recordedAtMs))
            if options.captureMetrics { metrics.crash() }
        }
        for report in LegacyReports.take(baseDir: base) {
            var attributes: [String: AttributeValue] = [Attr.exceptionId: .string(Ids.uuidv4())]
            for (key, value) in report.attributes { attributes[key] = .string(value) }
            if report.isMessage {
                emit(eventName: Events.message, severity: .info, body: report.stackTrace,
                     attributes: attributes, time: Clock.date(ms: report.recordedAtMs))
            } else {
                let firstLine = report.stackTrace.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
                attributes["exception.type"] = .string(firstLine)
                attributes["exception.stacktrace"] = .string(report.stackTrace)
                emit(eventName: Events.exception, severity: .error, attributes: attributes,
                     time: Clock.date(ms: report.recordedAtMs))
            }
        }
    }

    // MARK: - Threading

    var isOnQueue: Bool { DispatchQueue.getSpecific(key: TracewayClient.queueKey) != nil }

    /// Runs `work` on the client's queue: now when already there, else soon.
    func onQueue(_ work: @escaping () -> Void) {
        if isOnQueue {
            work()
        } else {
            let job = Unchecked(work)
            queue.async { job.value() }
        }
    }

    /// Runs `work` on the client's queue and waits for it.
    func onQueueSync<T>(_ work: () -> T) -> T {
        isOnQueue ? work() : queue.sync(execute: work)
    }

    // MARK: - Public API

    /// The id this installation reports to the server (`service.instance.id`),
    /// usable to target it from the dashboard.
    public var instanceId: String {
        onQueueSync { Ids.uuidString(instanceUid) }
    }

    /// The current session, or nil before the SDK started.
    public var currentSessionId: String? {
        onQueueSync { sessions?.currentId }
    }

    /// Reports an error as an issue, with the stack of the caller and the
    /// screen it happened on.
    @inline(never)
    public func captureException(_ error: Error, attributes: [String: String] = [:]) {
        let stack = Array(Thread.callStackReturnAddresses.map { UInt(truncating: $0) }.dropFirst(1))
        captureException(error, callStack: stack, attributes: attributes)
    }

    func captureException(_ error: Error, callStack: [UInt], attributes: [String: String] = [:]) {
        let spanContext = OpenTelemetry.instance.contextProvider.activeSpan?.context
        let (type, message) = StackTraceFormatter.errorTypeAndMessage(error)
        var attrs = screen.context(nowMs: Clock.nowMs())
        for (key, value) in attributes { attrs[key] = .string(value) }
        guard !ignored(type: type, message: message ?? "") else { return }
        let header = StackTraceFormatter.format(type: type, message: message, frames: [])
        let trace = CrashRecordStore.renderWireTrace(
            header: header,
            arch: BinaryImages.currentArch(),
            images: BinaryImages.capture(),
            addresses: callStack
        )
        guard reports(TracewayCapturedError(
            error: error, type: type, message: message ?? "", isMessage: false,
            attributes: TracewayClient.strings(attrs), stackTrace: trace
        )) else { return }
        attrs["exception.type"] = .string(type)
        if let message = message { attrs["exception.message"] = .string(message) }
        attrs["exception.stacktrace"] = .string(trace)
        attrs[Attr.exceptionId] = .string(Ids.uuidv4())
        let now = Date()
        onQueue {
            self.emit(eventName: Events.exception, severity: .error, attributes: attrs, time: now, spanContext: spanContext)
        }
    }

    #if canImport(ObjectiveC)
    /// An uncaught NSException, on the crashing thread: recorded and written
    /// to disk before this returns, then sent for up to `timeout` seconds.
    func captureFatalException(_ exception: NSException, timeout: TimeInterval = 2) {
        if options.captureMetrics {
            // Counted whatever the filters say, and on disk before the
            // process ends; sent with the flush below, or by the next start.
            metrics.crash()
            metrics.flush(final: true)
            metricsStore.value.flush()
        }
        // A crash that ends the process is always reported: neither `ignoreErrors` (its default `timeout`
        // pattern would hide real crashes) nor app code in `beforeCapture`, which must not run while the
        // process is going down, decides about it. The same as the Android SDK.
        let type = exception.name.rawValue
        var attrs = screen.context(nowMs: Clock.nowMs())
        let header = StackTraceFormatter.format(type: type, message: exception.reason, frames: [])
        let trace = CrashRecordStore.renderWireTrace(
            header: header,
            arch: BinaryImages.currentArch(),
            images: BinaryImages.capture(),
            addresses: exception.callStackReturnAddresses.map { UInt(truncating: $0) }
        )
        attrs["exception.type"] = .string(type)
        attrs["exception.stacktrace"] = .string(trace)
        attrs["exception.escaped"] = .bool(true)
        attrs["traceway.crash"] = .bool(true)
        attrs[Attr.exceptionId] = .string(Ids.uuidv4())
        if let reason = exception.reason { attrs["exception.message"] = .string(reason) }
        let now = Date()
        onQueueSync {
            emit(eventName: Events.exception, severity: .fatal, attributes: attrs, time: now)
            saveTriggerProgress(now: true)
        }
        flush(timeout: timeout)
    }
    #endif

    /// Reports a message as an issue, with the screen it was sent from.
    public func captureMessage(_ message: String, attributes: [String: String] = [:]) {
        let spanContext = OpenTelemetry.instance.contextProvider.activeSpan?.context
        var attrs = screen.context(nowMs: Clock.nowMs())
        for (key, value) in attributes { attrs[key] = .string(value) }
        guard !ignored(type: nil, message: message) else { return }
        guard reports(TracewayCapturedError(
            error: nil, type: nil, message: message, isMessage: true,
            attributes: TracewayClient.strings(attrs), stackTrace: nil
        )) else { return }
        attrs[Attr.exceptionId] = .string(Ids.uuidv4())
        let now = Date()
        onQueue {
            self.emit(eventName: Events.message, severity: .info, body: message, attributes: attrs, time: now,
                      spanContext: spanContext)
        }
    }

    /// Whether `ignoreErrors` (or the default list) matches the issue's
    /// first line.
    private func ignored(type: String?, message: String) -> Bool {
        let line = ignoreLine(type: type, message: message)
        return (options.ignoreErrors ?? TracewayOptions.defaultIgnoreErrors).contains { $0.matches(line) }
    }

    /// Whether `beforeCapture` lets the issue through. One that throws
    /// keeps it: a bug in the callback must not hide the app's errors.
    private func reports(_ captured: TracewayCapturedError) -> Bool {
        guard let before = options.beforeCapture else { return true }
        do {
            return try before(captured)
        } catch {
            Log.warn("beforeCapture threw, the record is kept: \(error)")
            return true
        }
    }

    private static func strings(_ attributes: [String: AttributeValue]) -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in attributes { out[key] = value.description }
        return out
    }

    /// A line for the session timeline (signal `console`) at `level`, with
    /// `log.source: api` and the given attributes.
    public func log(_ message: String, level: TracewayLogLevel = .info, attributes: [String: String] = [:]) {
        let spanContext = OpenTelemetry.instance.contextProvider.activeSpan?.context
        var attrs: [String: AttributeValue] = [:]
        for (key, value) in attributes { attrs[key] = .string(value) }
        attrs["log.source"] = .string("api")
        let now = Date()
        onQueue {
            self.emit(eventName: nil, severity: level.severity, body: message, attributes: attrs, time: now,
                      spanContext: spanContext)
        }
    }

    @available(*, deprecated, renamed: "log(_:level:attributes:)")
    public func log(_ message: String, severity: TracewayLogLevel) {
        log(message, level: severity)
    }

    /// Records a custom breadcrumb, shown on the session timeline.
    public func recordAction(category: String, name: String, data: [String: Any]? = nil) {
        var attrs: [String: AttributeValue] = [
            "traceway.action.category": .string(category),
            "traceway.action.name": .string(name),
        ]
        if let data = data, !data.isEmpty {
            if JSONSerialization.isValidJSONObject(data),
               let encoded = try? JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]) {
                attrs["traceway.action.data"] = .string(String(decoding: encoded, as: UTF8.self))
            } else {
                attrs["traceway.action.data"] = .string("\(data)")
            }
        }
        let now = Date()
        onQueue {
            self.sessions?.markActivity()
            self.emit(eventName: Events.action, severity: .info, attributes: attrs, time: now)
        }
    }

    /// Emits a named product event, e.g. `checkout_failed`. Triggers can
    /// match it by `event.name`.
    public func track(_ eventName: String, attributes: [String: Any] = [:]) {
        guard !eventName.isEmpty else { return }
        var attrs: [String: AttributeValue] = [:]
        for (key, value) in attributes { attrs[key] = TracewayClient.attribute(value) }
        let now = Date()
        onQueue { self.emit(eventName: eventName, severity: .info, attributes: attrs, time: now) }
    }

    static func attribute(_ value: Any) -> AttributeValue {
        switch value {
        case let v as String: return .string(v)
        case let v as Bool: return .bool(v)
        case let v as Int: return .int(v)
        case let v as Double: return .double(v)
        case let v as Float: return .double(Double(v))
        case let v as AttributeValue: return v
        default: return .string("\(value)")
        }
    }

    /// Sets an attribute attached to every later record and reported to the
    /// server for remote-config targeting (`user.id`, a plan, a cohort).
    public func setAttribute(_ key: String, _ value: String) {
        guard !key.isEmpty else { return }
        onQueue {
            if self.globalAttributes[key] == nil, self.globalAttributes.count >= maxGlobalAttributes { return }
            guard self.globalAttributes[key] != value else { return }
            self.globalAttributes[key] = value
            self.attributesChanged()
        }
    }

    public func setAttributes(_ attributes: [String: String]) {
        for (key, value) in attributes { setAttribute(key, value) }
    }

    public func removeAttribute(_ key: String) {
        onQueue {
            if self.globalAttributes.removeValue(forKey: key) != nil { self.attributesChanged() }
        }
    }

    public func clearAttributes() {
        onQueue {
            guard !self.globalAttributes.isEmpty else { return }
            self.globalAttributes.removeAll()
            self.attributesChanged()
        }
    }

    private func attributesChanged() {
        scheduleRefresh()
        updateCrashMetadata()
    }

    /// Records that the app shows `path`, for routers and SwiftUI navigation
    /// that no view controller reports.
    public func recordNavigation(_ path: String, action: String = "push", from: String? = nil, route: String? = nil) {
        recordNavigation(to: path, action: action, from: from, route: route, time: Date())
    }

    /// `displayStartMs` is when the screen began to load or appear (Unix ms),
    /// when that was before the navigation is reported.
    func recordNavigation(to path: String, action: String, from: String?, route: String? = nil, time: Date,
                          displayStartMs: Int64? = nil) {
        // The screen changes now, on the caller's thread: an issue captured
        // right after names the screen it happened on.
        let shown = screen.navigated(to: path, atMs: Clock.ms(time), route: route)
        vitals?.navigated(path.isEmpty ? nil : ScreenState.template(route) ?? normalizePath(path), action: action,
                          timeMs: displayStartMs ?? Clock.ms(time))
        onQueue {
            self.sessions?.markActivity()
            var attrs: [String: AttributeValue] = [
                "url.full": .string(path),
                "navigation.action": .string(action),
                // The session timeline labels a navigation by this.
                "browser.navigation.type": .string(action),
                "navigation.to": .string(path),
            ]
            if let from = from { attrs["navigation.from"] = .string(from) }
            if let name = shown.name { attrs["app.screen.name"] = .string(name) }
            if let route = shown.route { attrs["app.screen.route"] = .string(route) }
            self.emit(eventName: Events.navigation, severity: .info, attributes: attrs, time: time)
        }
    }

    /// Names the current screen by its route template (`/orders/{id}`):
    /// issues and navigation records carry it as `app.screen.route`, and
    /// metrics group by it instead of by the path with its ids folded, until
    /// the app reaches another screen. Nil removes it.
    public func setRoute(_ template: String?) {
        screen.setRoute(template)
        if let route = screen.route { vitals?.routeNamed(route) }
    }

    // MARK: - Metrics

    /// The screen on top shows everything it loads: ends its time to full
    /// display (`app.screen.ttfd`).
    public func reportFullyDisplayed() {
        vitals?.fullyDisplayed()
    }

    /// Observes `value` of an app-defined distribution, e.g.
    /// `checkout.duration`. Names are `[a-z][a-z0-9_.]`, up to 63
    /// characters, outside `app.`, `browser.`, `traceway.` and `custom.`;
    /// at most two dimensions, values as text.
    public func metric(_ name: String, value: Double, dimensions: [String: Any] = [:]) {
        guard options.captureMetrics else { return }
        metrics.metric(name, value, dims: dimensions)
    }

    /// Adds `n` to an app-defined counter, with the names and dimensions of
    /// `metric`.
    public func count(_ name: String, n: Double = 1, dimensions: [String: Any] = [:]) {
        guard options.captureMetrics else { return }
        metrics.count(name, n, dims: dimensions)
    }

    /// Sets an app-defined dimension on every metric from now on
    /// (`custom.<key>`), at most two keys; nil removes it.
    public func setMetricDimension(_ key: String, _ value: String?) {
        metrics.setDimension(key, value)
    }

    /// The current screen as a metrics dimension: its route template, or
    /// its path with ids folded.
    static func metricsScreen(_ screen: ScreenState) -> String? {
        if let route = screen.route { return route }
        guard let name = screen.name, !name.isEmpty else { return nil }
        return normalizePath(name)
    }

    /// A finished request span (the URLSession instrumentation's, or a client
    /// span of the app's own) as `app.request.*`. Any thread.
    func observeRequest(_ span: SpanData) {
        guard options.captureMetrics, span.kind == .client else { return }
        let attributes = span.attributes
        guard attributes["http.request.method"] != nil || attributes["http.method"] != nil,
              let url = (attributes["url.full"] ?? attributes["http.url"])?.description
        else { return }
        let status = (attributes["http.response.status_code"] ?? attributes["http.status_code"])
            .flatMap { Int($0.description) }
        let failed = attributes["error.type"] != nil || (status ?? 0) <= 0 || (status ?? 0) >= 400
        let bytes = attributes["http.response.body.size"].flatMap { Int64($0.description) }
        let ms = max(0, span.endTime.timeIntervalSince(span.startTime) * 1000)
        metrics.request(url, ms: ms, failed: failed, responseBytes: bytes)
    }

    /// One blocking upload of a metrics payload, gzipped where zlib is
    /// there: the HTTP status, 0 without an answer.
    static func postMetrics(_ body: Data, to destination: OtlpDestination, transport: HTTPTransport) -> Int {
        var headers = destination.headers
        headers["Content-Type"] = "application/x-protobuf"
        var payload = body
        if let compressed = Gzip.compress(body) {
            payload = compressed
            headers["Content-Encoding"] = "gzip"
        }
        let status = Locked(0)
        let done = DispatchSemaphore(value: 0)
        transport.post(url: destination.url, headers: headers, body: payload, timeout: 20) { result in
            status.value = result.statusCode
            done.signal()
        }
        _ = done.wait(timeout: .now() + 25)
        return status.value
    }

    /// Starts an interaction named `name`: a span (`traceway.interaction`)
    /// that requests made in its `run` are children of. One started inside
    /// another's `run` is its child.
    public func startInteraction(_ name: String, attributes: [String: Any] = [:]) -> TracewayInteraction {
        // The tracer is set before the client is shared and never changes.
        guard !name.isEmpty, !isShutdown, let tracer = tracer else {
            return TracewayInteraction(span: nil, client: self)
        }
        let builder = tracer.spanBuilder(spanName: name).setSpanKind(spanKind: .internal)
        builder.setAttribute(key: "traceway.interaction", value: true)
        for (key, value) in attributes where !key.isEmpty {
            builder.setAttribute(key: key, value: TracewayClient.attribute(value))
        }
        return TracewayInteraction(span: builder.startSpan(), client: self)
    }

    /// Asks the server for collection settings now instead of at the next poll.
    public func refreshConfig() {
        onQueue { self.opamp?.refresh() }
    }

    /// Notes user activity so the session's inactivity timeout restarts.
    func markActivity() {
        onQueue { self.sessions?.markActivity() }
    }

    /// The OpenTelemetry tracer of this installation: spans made with it are
    /// routed like the SDK's own (requests as `network`, others `custom`).
    public var openTelemetryTracer: Tracer? { onQueueSync { tracer } }

    // MARK: - Flushing

    /// Sends everything that is ready now: queued records, replay clips and
    /// telemetry that failed earlier, waiting at most `timeout` seconds
    /// (nil waits until done). Telemetry held in the ring buffer stays there.
    public func flush(timeout: TimeInterval? = nil) {
        if isOnQueue {
            flushAll {}
            return
        }
        let done = DispatchSemaphore(value: 0)
        queue.async { self.flushAll { done.signal() } }
        if let timeout = timeout {
            _ = done.wait(timeout: .now() + timeout)
        } else {
            done.wait()
        }
    }

    /// On the client's queue; `completion` runs on it once everything that
    /// was ready has been handed over and the outboxes were drained.
    func flushAll(_ completion: @escaping () -> Void) {
        flushTimer?.cancel()
        flushTimer = nil
        saveTriggerProgress(now: true)
        let group = DispatchGroup()
        if let spanSink = spanSink {
            group.enter()
            spanSink.flush { group.leave() }
        }
        if let router = router {
            group.enter()
            router.settle { group.leave() }
        }
        if let logSink = logSink {
            group.enter()
            let sink = Unchecked(logSink)
            DispatchQueue.global(qos: .utility).async {
                sink.value.forceFlush(timeout: 20)
                group.leave()
            }
        }
        group.enter()
        replay.drain { group.leave() }
        group.enter()
        let metrics = self.metrics
        DispatchQueue.global(qos: .utility).async {
            metrics.flush()
            metrics.awaitUploads(timeoutMs: 20_000)
            group.leave()
        }
        group.notify(queue: queue) {
            // Batches that failed just now are in the outboxes.
            let drained = DispatchGroup()
            for box in [self.outbox, self.tracewayOutbox].compactMap({ $0 }) {
                drained.enter()
                box.drain { drained.leave() }
            }
            drained.enter()
            self.persistBuffer { drained.leave() }
            drained.notify(queue: self.queue) {
                self.store.flush()
                completion()
            }
        }
    }

    /// Flushes and stops the SDK. A new `Traceway.initialize` starts it again.
    public func shutdown() {
        let done = DispatchSemaphore(value: 0)
        onQueue {
            guard !self.isShutdown else {
                done.signal()
                return
            }
            if let session = self.sessions?.current {
                self.emitSessionEnd(session, endedAtMs: Clock.nowMs())
                // The session may go on after a restart: its memory is
                // observed when it ends.
                if self.options.captureMetrics { self.memoryPeaks.remember(session.id) }
            }
            self.vitals?.stop()
            self.flushAll {
                self.metrics.stop()
                self.isShutdown = true
                self.sessions?.stop()
                self.opamp?.stop()
                self.replay.stop()
                for timer in [self.refreshTimer, self.overrideTimer, self.progressTimer, self.flushTimer,
                              self.healthTimer] {
                    timer?.cancel()
                }
                self.store.flush()
                self.uninstallPlatformHooks()
                DispatchQueue.global(qos: .utility).async {
                    _ = self.logSink?.shutdown(explicitTimeout: 5)
                    self.tracerProvider?.shutdown()
                    // After the processors' last export: a batch that fails then
                    // is still queued on disk for the next start.
                    self.outbox?.dispose()
                    self.tracewayOutbox?.dispose()
                    TracewayClient.sharedLock.lock()
                    if TracewayClient._shared === self { TracewayClient._shared = nil }
                    TracewayClient.sharedLock.unlock()
                    done.signal()
                }
            }
        }
        if !isOnQueue { _ = done.wait(timeout: .now() + 30) }
    }

    /// An error should not wait for the batch delay: the app may be about to
    /// die.
    private func flushSoon() {
        guard flushTimer == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.flushTimer = nil
            (self.tracewayOutbox ?? self.outbox)?.drain()
            let sink = Unchecked(self.logSink)
            DispatchQueue.global(qos: .utility).async { sink.value?.forceFlush(timeout: 20) }
            self.spanSink?.flush()
        }
        flushTimer = work
        queue.asyncAfter(deadline: .now() + .milliseconds(100), execute: work)
    }

    // MARK: - Lifecycle

    /// The app returned to the foreground.
    func appResumed() {
        onQueue {
            guard !self.isShutdown else { return }
            self.sessions?.markActivity()
            self.opamp?.poll()
            self.outbox?.drain()
            self.tracewayOutbox?.drain()
        }
    }

    /// The app went to the background, where it may be killed: what is
    /// ready leaves, and the buffer and trigger progress are saved.
    func appPaused(_ completion: @escaping () -> Void) {
        onQueue {
            guard !self.isShutdown else {
                completion()
                return
            }
            self.replay.onPaused()
            if self.options.captureMetrics, self.started {
                self.memoryPeaks.remember(self.sessions?.currentId)
                // Stored before it is sent: the app may not live to see the answer.
                self.metrics.flush(final: true)
            }
            self.flushAll(completion)
        }
    }

    // MARK: - Emission

    /// Emits a log record. `spanContext` is the span active where the
    /// record was made (an interaction's), read on that thread.
    func emit(
        eventName: String?,
        severity: Severity?,
        body: String? = nil,
        attributes: [String: AttributeValue] = [:],
        time: Date? = nil,
        spanContext: SpanContext? = nil
    ) {
        guard !isShutdown, let logger = logger else { return }
        emitDepth += 1
        defer { emitDepth -= 1 }
        let builder = logger.logRecordBuilder()
        if let spanContext = spanContext { _ = builder.setSpanContext(spanContext) }
        if let eventName = eventName { _ = builder.setEventName(eventName) }
        if let severity = severity { _ = builder.setSeverity(severity) }
        if let body = body { _ = builder.setBody(.string(body)) }
        if !attributes.isEmpty { _ = builder.setAttributes(attributes) }
        _ = builder.setTimestamp(time ?? Date())
        builder.emit()
    }

    private func emitSessionEnd(_ session: SessionInfo, endedAtMs: Int64) {
        guard reportedSessions.remove(session.id) != nil else { return }
        emit(eventName: Events.sessionEnd, severity: .info, attributes: sessionAttributes(session),
             time: Clock.date(ms: endedAtMs))
    }

    /// What every session event carries: the session, how much of its
    /// diagnostic budget replay used, what was dropped, and the images
    /// policy it started with, shown on the session page.
    private func sessionAttributes(_ session: SessionInfo) -> [String: AttributeValue] {
        var attrs: [String: AttributeValue] = [
            Attr.sessionId: .string(session.id),
            Attr.sessionStartedAt: .int(Int(session.startedAtMs)),
            "traceway.replay.failed_segments": .int(recordings.failedSegments),
            "traceway.context.evicted": .int(buffer.evictedCount),
            "traceway.error.suppressed_total": .int(suppressedErrorsTotal),
        ]
        let images = sessionImages?.id == session.id ? sessionImages!.policy : control.settings.replayImages
        attrs["traceway.replay.images"] = .string(images.rawValue)
        for (key, value) in replay.budget.snapshot(session.id) { attrs[key] = .int(value) }
        return attrs
    }

    /// Tells the server that the SDK dropped data (the session's budget ran
    /// out, errors were suppressed, replay segments failed), as the browser
    /// SDK does: at most once per period, which starts at a second and
    /// doubles up to five minutes. The first report of a session also
    /// updates the session's row.
    private func scheduleHealth() {
        guard healthTimer == nil, !isShutdown else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.healthTimer = nil
            let session = self.sessions?.current
            var attrs: [String: AttributeValue] = [
                "traceway.error.suppressed_total": .int(self.suppressedErrorsTotal),
                "traceway.context.evicted": .int(self.buffer.evictedCount),
                "traceway.replay.failed_segments": .int(self.recordings.failedSegments),
            ]
            for (key, value) in self.replay.budget.snapshot(session?.id) { attrs[key] = .int(value) }
            self.emit(eventName: Events.collectionHealth, severity: .info, attributes: attrs)
            if let session = session, !self.healthReported, self.reportedSessions.contains(session.id) {
                self.emit(eventName: Events.sessionUpdate, severity: .info, attributes: self.sessionAttributes(session))
            }
            self.healthReported = true
            self.nextHealthDelayMs = min(self.nextHealthDelayMs * 2, maxHealthDelayMs)
        }
        healthTimer = work
        queue.asyncAfter(deadline: .now() + .milliseconds(nextHealthDelayMs), execute: work)
    }

    private func onSessionStart(_ session: SessionInfo, resumed: Bool) {
        // What an earlier session left behind is not this one's context.
        if !resumed { buffer.clear() }
        replay.budget.use(session.id)
        sessionImages = (session.id, control.settings.replayImages)
        nextHealthDelayMs = healthDelayMs
        healthReported = false
        triggers.resetSession()
        if let limits = store.get("triggerLimits")?.object, limits["sessionId"]?.string == session.id {
            triggers.restoreSessionLimits(limits["limits"])
        }
        restoreTriggerProgress(session.id)
        replay.onSessionStart()
        metricsSession.value = session.id
        if options.captureMetrics {
            memoryPeaks.settle(session.id)
            metrics.sessionStarted(session.id, resumed: resumed)
        }
        if control.settings.sessionsEnabled {
            reportedSessions.insert(session.id)
            emit(
                eventName: resumed ? Events.sessionUpdate : Events.sessionStart,
                severity: .info,
                attributes: sessionAttributes(session),
                time: resumed ? nil : Clock.date(ms: session.startedAtMs)
            )
        }
        updateCrashMetadata(session)
        applyReplay()
        scheduleRefresh()
    }

    private func onSessionEnd(_ session: SessionInfo, endedAtMs: Int64) {
        replay.onSessionEnd(session.id)
        if options.captureMetrics { memoryPeaks.ended(session.id) }
        emitSessionEnd(session, endedAtMs: endedAtMs)
    }

    /// The signal handler writes what is known now into a crash record.
    private func updateCrashMetadata(_ session: SessionInfo? = nil) {
        guard started || session != nil else { return }
        var metadata = resourceAttributes
        for (key, value) in globalAttributes { metadata[key] = value }
        if let session = session ?? sessions?.current {
            metadata[Attr.sessionId] = session.id
            metadata[Attr.sessionStartedAt] = String(session.startedAtMs)
        }
        if let name = screen.name { metadata["app.screen.name"] = name }
        CrashReporter.updateMetadata(metadata, appVersion: serviceVersion)
    }

    func crashMetadata() -> [String: String] {
        var metadata = resourceAttributes
        for (key, value) in globalAttributes { metadata[key] = value }
        if let session = sessions?.current {
            metadata[Attr.sessionId] = session.id
            metadata[Attr.sessionStartedAt] = String(session.startedAtMs)
        }
        return metadata
    }

    // MARK: - Taps and pointer triggers

    /// A tap the main thread described: a `browser.user_action.click` record
    /// naming the view, and a click for recording triggers. `matched` holds
    /// the click selectors of the triggers that the tapped view matched.
    func recordTap(target: TapTarget?, x: Double, y: Double, matched: Set<String>) {
        onQueue {
            guard !self.isShutdown, self.options.captureUserActions else { return }
            self.sessions?.markActivity()
            if let target = target, self.control.modeFor("userActions") != .off {
                var attrs: [String: AttributeValue] = [
                    "browser.css_selector": .string(target.selector),
                    "browser.tag_name": .string(target.tag),
                    "app.widget.name": .string(target.tag),
                    "app.screen.coordinate.x": .int(Int(x.rounded())),
                    "app.screen.coordinate.y": .int(Int(y.rounded())),
                ]
                if let id = target.id { attrs["app.widget.id"] = .string(id) }
                if let text = target.text { attrs["app.widget.text"] = .string(text) }
                if let label = target.label { attrs["app.widget.label"] = .string(label) }
                if let name = self.screen.name { attrs["app.screen.name"] = .string(name) }
                self.emit(eventName: Events.click, severity: .info, attributes: attrs)
            }
            if self.sequenceKinds.contains("click") {
                self.observePointer("click") { matched.contains($0) }
            }
        }
    }

    private func observePointer(_ type: String, _ test: @escaping (String) -> Bool) {
        guard control.enabled, sessions?.currentId != nil else { return }
        runFired(triggers.observe(ObservedEvent(
            timeMs: Clock.nowMs(),
            lookup: pageLookup([keyPointerAction: .string(type)]),
            sequence: type,
            targetMatches: test
        )))
    }

    /// The fields of an event the app reports itself, next to what every
    /// record can be matched on.
    private func pageLookup(_ fields: [String: JSON]) -> FieldLookup {
        return { [weak self] key in
            if let value = fields[key] { return value }
            guard let self = self else { return nil }
            if key.hasPrefix("global.") {
                return self.globalAttributes[String(key.dropFirst("global.".count))].map { .string($0) }
            }
            if key.hasPrefix("resource.") {
                return self.resourceAttributes[String(key.dropFirst("resource.".count))].map { .string($0) }
            }
            if key == Attr.sessionId { return self.sessions?.currentId.map { .string($0) } }
            return nil
        }
    }

    /// True for the SDK's own requests, which are not recorded as spans.
    /// Thread-safe: reads only constants.
    func isOwnRequest(_ url: String) -> Bool {
        endpoints?.isOwn(url) == true || routes.isOwn(url)
    }

    /// Whether a request to `url` carries a `traceparent` header.
    func propagatesTrace(to url: String) -> Bool {
        !isOwnRequest(url) && options.propagateTraceHeaderUrls.contains { url.hasPrefix($0) }
    }

    // MARK: - Triggers

    private func runFired(_ fired: [FiredTrigger]) {
        for trigger in fired { runTrigger(trigger) }
        if !fired.isEmpty {
            store.set("triggerLimits", [
                "sessionId": JSON(sessions?.currentId),
                "limits": triggers.snapshotSessionLimits(),
            ])
        }
        saveTriggerProgress()
    }

    /// Keeps sequences under way across an app restart within the session.
    /// At most every two seconds: a step that counts frequent records changes
    /// progress on each of them.
    private func saveTriggerProgress(now: Bool = false) {
        guard triggers.progressVersion != savedProgressVersion else { return }
        let nowMs = Clock.nowMs()
        if !now, nowMs - lastProgressSaveMs < 2000 {
            if progressTimer == nil {
                let work = DispatchWorkItem { [weak self] in
                    self?.progressTimer = nil
                    self?.saveTriggerProgress(now: true)
                }
                progressTimer = work
                queue.asyncAfter(deadline: .now() + 2, execute: work)
            }
            return
        }
        progressTimer?.cancel()
        progressTimer = nil
        lastProgressSaveMs = nowMs
        savedProgressVersion = triggers.progressVersion
        let progress = triggers.snapshotProgress()
        let encoded = JSON.array([JSON(sessions?.currentId), progress]).encoded(sortedKeys: true)
        guard encoded != savedProgress else { return }
        savedProgress = encoded
        store.set("triggerProgress", ["sessionId": JSON(sessions?.currentId), "progress": progress])
    }

    private func restoreTriggerProgress(_ session: String?, only: Set<String>? = nil) {
        guard let session = session, let saved = store.get("triggerProgress")?.object,
              saved["sessionId"]?.string == session
        else { return }
        triggers.restoreProgress(saved["progress"], nowMs: nil, only: only)
    }

    private func runTrigger(_ fired: FiredTrigger) {
        let exceptionId = fired.cause.lookup("attributes.\(Attr.exceptionId)")?.string
        for action in fired.trigger.actions {
            runAction(action, exceptionId: exceptionId, triggerId: fired.trigger.id)
        }
        let wantsReplay = fired.trigger.actions.contains { $0.replay || $0.type == "startReplay" }
        var attrs: [String: AttributeValue] = ["traceway.trigger.id": .string(fired.trigger.id)]
        if let name = fired.trigger.name { attrs["traceway.trigger.name"] = .string(name) }
        // The server lists the sessions a recording trigger asked replay
        // for, with the sequence that did.
        if wantsReplay, control.replayMode != .off {
            attrs["traceway.trigger.replay"] = .string("true")
            attrs["traceway.trigger.steps"] = .string(fired.trigger.stepsJSON().encoded(sortedKeys: true))
        }
        emit(eventName: Events.triggerFired, severity: .info, attributes: attrs)
    }

    private static func selectorSet(_ signals: [String]?) -> Set<String>? {
        guard let signals = signals, !signals.contains("*") else { return nil }
        return Set(signals)
    }

    private func runAction(_ action: TriggerAction, exceptionId: String? = nil, triggerId: String? = nil) {
        let now = Clock.nowMs()
        switch action.type {
        case "flush":
            let lookbackMs = Int64((action.lookbackSeconds ?? 0) * 1000)
            router?.flushBuffered(sinceMs: now - lookbackMs, signals: TracewayClient.selectorSet(action.signals), untilMs: now)
            if action.replay, replay.flush(lookbackMs: lookbackMs, exceptionId: exceptionId) {
                replayFlushes += 1
            }
            // The file must not hold records that just left, or a crash
            // before the next save would send them again after a restart.
            if persisted != nil { persistBuffer() }
        case "stream":
            streamFor(action.signals ?? ["*"], replay: action.replay,
                      untilMs: now + Int64((action.durationSeconds ?? 0) * 1000))
        case "startReplay":
            streamFor([], replay: true, untilMs: now + Int64((action.durationSeconds ?? 0) * 1000))
        case "emit":
            guard emitDepth < maxEmitDepth, let name = action.eventName else { break }
            var attrs: [String: AttributeValue] = [:]
            for (key, value) in action.attributes ?? [:] { attrs[key] = .string(value) }
            emit(eventName: name, severity: .info, attributes: attrs)
        case "capture":
            startLocalCapture(action, exceptionId: exceptionId, triggerId: triggerId ?? "local")
        default:
            break
        }
    }

    private func persistBuffer(_ completion: (() -> Void)? = nil) {
        guard let persisted = persisted, control.settings.persist, !isShutdown else {
            completion?()
            return
        }
        persisted.save(sessionId: sessions?.currentId, entries: buffer.snapshot(), completion: completion)
    }

    private func streamFor(_ signals: [String], replay wantsReplay: Bool, untilMs: Int64,
                           capture: Bool = false, owner: String? = nil) {
        let override = StreamOverride(signals: signals, untilMs: untilMs, replay: wantsReplay, includeOff: capture)
        if let owner = owner {
            control.setOverrides(owner, [override])
        } else {
            control.addOverride(override)
        }
        applyReplay()
        scheduleOverrideExpiry()
    }

    /// Re-applies replay when the next override ends, so a streaming
    /// capture returns to buffering on time.
    private func scheduleOverrideExpiry() {
        overrideTimer?.cancel()
        overrideTimer = nil
        guard let expiry = control.nextOverrideExpiryMs, !isShutdown else { return }
        let delay = max(0, expiry - Clock.nowMs()) + 1
        let work = DispatchWorkItem { [weak self] in
            self?.overrideTimer = nil
            self?.applyReplay()
            self?.scheduleOverrideExpiry()
        }
        overrideTimer = work
        queue.asyncAfter(deadline: .now() + .milliseconds(Int(delay)), execute: work)
    }

    func applyReplay() {
        let session = sessions?.currentId
        let settings = control.settings
        if let recorder = screenRecorder as? WireframeRecorder {
            recorder.maskAllInputs = settings.replayMaskAllInputs
            recorder.imagePolicy = settings.replayImages
        }
        replay.apply(
            control.replayMode,
            maxAgeMs: Int64(settings.bufferMaxAgeSeconds * 1000),
            sessionSampled: session != nil && Ids.unitHash(session!) < settings.replaySessionSampleRate
        )
    }

    /// Attaches the screen recorder replay clips come from.
    func attachReplaySource(_ source: ReplaySource?) {
        onQueue {
            self.screenRecorder = source
            self.replay.attach(source)
            self.applyReplay()
        }
    }

    // MARK: - Captures

    private func readLocalCaptures() -> [[String: JSON]] {
        let now = Clock.nowMs()
        return (store.get("localCaptures")?.array ?? []).compactMap { item in
            guard let capture = item.object, capture["id"]?.string != nil, capture["triggerId"]?.string != nil,
                  let until = capture["untilMs"]?.int, Int64(until) > now
            else { return nil }
            return capture
        }
    }

    /// Local captures outlive the app run that started them, like the
    /// browser SDK's outlive a page: a restart keeps streaming until they end.
    private func restoreLocalCaptures() {
        for capture in readLocalCaptures() {
            let signals = capture["signals"]?.array?.compactMap { $0.string } ?? ["*"]
            control.setOverrides("local:\(capture["triggerId"]!.string!)", [
                StreamOverride(
                    signals: signals,
                    untilMs: Int64(capture["untilMs"]!.int!),
                    replay: capture["replay"]?.bool == true,
                    includeOff: true
                ),
            ])
        }
    }

    /// A capture a trigger started on this device: upload the lookback
    /// once, then stream the selected signals until it ends. While it runs,
    /// the same trigger only extends it.
    private func startLocalCapture(_ action: TriggerAction, exceptionId: String?, triggerId: String) {
        let now = Clock.nowMs()
        var untilMs = now + Int64((action.durationSeconds ?? 0) * 1000)
        let signals = action.signals ?? ["*"]
        var captures = readLocalCaptures()
        if let index = captures.firstIndex(where: { $0["triggerId"]?.string == triggerId }) {
            untilMs = max(Int64(captures[index]["untilMs"]?.int ?? 0), untilMs)
            captures[index]["untilMs"] = JSON(untilMs)
        } else {
            let id = "\(triggerId):\(now)"
            captures.append([
                "id": .string(id),
                "triggerId": .string(triggerId),
                "untilMs": JSON(untilMs),
                "signals": JSON(signals),
                "replay": .bool(action.replay),
            ])
            runAction(
                TriggerAction(type: "flush", lookbackSeconds: action.lookbackSeconds ?? 60,
                              signals: signals, replay: action.replay),
                exceptionId: exceptionId
            )
            emit(eventName: Events.captureStarted, severity: .info, attributes: [
                "traceway.capture.id": .string(id),
                "traceway.capture.source": .string("trigger"),
                "traceway.trigger.id": .string(triggerId),
                "traceway.capture.until": .string(ISO8601.format(millis: untilMs)),
            ])
        }
        store.set("localCaptures", .array(captures.map { .object($0) }))
        streamFor(signals, replay: action.replay, untilMs: untilMs, capture: true, owner: "local:\(triggerId)")
    }

    private func confirmCaptures() {
        guard !capturesConfirmed, !isShutdown else { return }
        capturesConfirmed = true
        runCaptures(control.settings)
        applyReplay()
    }

    /// Starts the dashboard's captures aimed at this app. The lookback flush
    /// runs once per capture, remembered across app starts; streaming lasts
    /// until the capture's end.
    private func runCaptures(_ settings: Settings) {
        guard started else { return }
        let now = Date()
        let nowMs = Clock.ms(now)
        control.setOverrides("remote-captures", settings.captures.filter { $0.until > now }.map {
            StreamOverride(signals: $0.signals ?? ["*"], untilMs: Clock.ms($0.until),
                           replay: $0.replay, includeOff: true)
        })
        scheduleOverrideExpiry()
        guard capturesConfirmed else { return }
        let stored = store.get("captures")?.array ?? []
        var done: [[String: JSON]] = stored.compactMap { item in
            guard let capture = item.object, capture["id"]?.string != nil,
                  let until = capture["untilMs"]?.int, Int64(until) > nowMs
            else { return nil }
            return ["id": capture["id"]!, "untilMs": capture["untilMs"]!]
        }
        var changed = done.count != stored.count
        for capture in settings.captures where capture.until > now {
            if done.contains(where: { $0["id"]?.string == capture.id }) { continue }
            let lookbackSeconds = capture.lookbackSeconds ?? 600
            if lookbackSeconds > 0 {
                runAction(TriggerAction(type: "flush", lookbackSeconds: lookbackSeconds,
                                        signals: capture.signals ?? ["*"], replay: capture.replay))
            }
            emit(eventName: Events.captureStarted, severity: .info, attributes: [
                "traceway.capture.id": .string(capture.id),
                "traceway.capture.source": .string("remote"),
            ])
            done.append(["id": .string(capture.id), "untilMs": JSON(Clock.ms(capture.until))])
            changed = true
        }
        if changed { store.set("captures", .array(done.map { .object($0) })) }
    }

    private func onSettingsChanged(_ settings: Settings) {
        runCaptures(settings)
        buffer.retain { control.canExport($0.signal) }
        if !settings.persist { persisted?.clear() }
        buffer.configure(maxBytes: settings.bufferMaxBytes, maxAgeMs: Int64(settings.bufferMaxAgeSeconds * 1000))
        // Triggers that were already running keep their progress: what was
        // saved can be up to two seconds older, and would undo a fire.
        restoreTriggerProgress(sessions?.currentId, only: triggers.setTriggers(settings.triggers))
        var kinds: Set<String> = []
        var clickSelectors: [String] = []
        for trigger in triggers.triggers {
            for step in trigger.steps {
                kinds.formUnion(eventKinds(step.match))
                collectSelectors(step.match, type: "click", into: &clickSelectors)
            }
        }
        sequenceKinds = kinds
        interaction.update(
            recordTaps: options.captureUserActions && control.modeFor("userActions") != .off,
            clickSelectors: options.captureUserActions ? clickSelectors : []
        )
        observeScreenForSequences()
        applyReplay()
        metrics.configure(settings.activeMetrics, flushSeconds: settings.metrics.flushSeconds)
    }

    private func collectSelectors(_ matcher: Matcher, type: String, into out: inout [String]) {
        switch matcher {
        case .event(let event): if event.type == type, !out.contains(event.value) { out.append(event.value) }
        case .all(let items), .any(let items): for item in items { collectSelectors(item, type: type, into: &out) }
        case .not(let inner): collectSelectors(inner, type: type, into: &out)
        case .condition: break
        }
    }

    /// Triggers that arrive after the app reached its current screen still
    /// see that screen once, as the browser SDK lets them see the page it
    /// loaded.
    private func observeScreenForSequences() {
        guard !screenObservedForSequences, let screen = currentScreen, sequenceKinds.contains("navigation"),
              control.enabled, sessions?.currentId != nil, options.captureNavigation
        else { return }
        screenObservedForSequences = true
        runFired(triggers.observe(ObservedEvent(
            timeMs: Clock.nowMs(),
            lookup: pageLookup([
                "event.name": .string(Events.navigation),
                "signal": "navigation",
                "attributes.url.full": .string(screen),
            ])
        )))
    }

    // MARK: - OpAMP

    private func describe() -> AgentDescription {
        var nonIdentifying: [String: JSON] = [:]
        for (key, value) in resourceAttributes where key != "service.name" && key != "service.instance.id" {
            nonIdentifying[key] = .string(TracewayClient.clip(value))
        }
        for (key, value) in globalAttributes where key.utf8.count <= 128 {
            nonIdentifying[key] = .string(TracewayClient.clip(value))
        }
        if let session = sessions?.currentId { nonIdentifying[Attr.sessionId] = .string(session) }
        return AgentDescription(
            identifying: [
                "service.name": .string(serviceName),
                "service.instance.id": .string(Ids.uuidString(instanceUid)),
            ],
            nonIdentifying: OpampAttributes(nonIdentifying)
        )
    }

    /// At most the 1024 UTF-8 bytes the server reads of a value.
    static func clip(_ value: String) -> String {
        guard value.utf8.count > 1024 else { return value }
        var out = ""
        var bytes = 0
        for scalar in value.unicodeScalars {
            bytes += String(scalar).utf8.count
            if bytes > 1024 { break }
            out.unicodeScalars.append(scalar)
        }
        return out
    }

    private func applyRemoteConfig(_ config: RemoteConfig) -> ApplyResult {
        let body = config.configMap["traceway"].map { String(decoding: $0.body, as: UTF8.self) } ?? "{}"
        let overlay: [String: JSON]
        do {
            overlay = try parseSettingsDocument(body)
        } catch {
            return .failed("\(error)")
        }
        control.applyRemote(overlay)
        let hash = Ids.hex(config.configHash)
        store.set("config", ["hash": .string(hash), "body": .string(body)])
        emit(eventName: Events.configApplied, severity: .info, attributes: ["traceway.config.hash": .string(hash)])
        Log.debug("remote config applied (\(hash))")
        return .applied
    }

    /// A targeting attribute or the session changed: let the server
    /// re-evaluate its rules soon, without a poll per change.
    private func scheduleRefresh() {
        guard opamp != nil, refreshTimer == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.refreshTimer = nil
            self?.opamp?.refresh()
        }
        refreshTimer = work
        queue.asyncAfter(deadline: .now() + 2, execute: work)
    }

    // MARK: - Testing

    var isTesting: Bool { overrides != nil }
    var testReplaySource: ReplaySource? { overrides?.replaySource }

    /// Stops the client the way the system kills an app: nothing more is
    /// saved or sent.
    func killForTesting() {
        queue.sync {
            isShutdown = true
            opamp?.stop()
            replay.stop()
            metrics.stop()
            vitals?.stop()
        }
        TracewayClient.sharedLock.lock()
        if TracewayClient._shared === self { TracewayClient._shared = nil }
        TracewayClient.sharedLock.unlock()
    }

    static func resetForTesting() {
        let client = shared
        client?.shutdown()
        sharedLock.lock()
        _shared = nil
        sharedLock.unlock()
    }
}

// MARK: - RouterHooks

extension TracewayClient: RouterHooks {
    var sessionId: String? { sessions?.currentId }

    func globalAttribute(_ key: String) -> String? { globalAttributes[key] }

    func enrichLog(_ record: inout ReadableLogRecord, signal: String) -> Bool {
        let existing = record.attributes
        if let session = sessions?.current, existing[Attr.sessionStartedAt] == nil {
            record.setAttribute(key: Attr.sessionStartedAt, value: .int(Int(session.startedAtMs)))
        }
        for (key, value) in globalAttributes where existing[key] == nil {
            record.setAttribute(key: key, value: .string(value))
        }
        if signal == "errors" {
            let key = "\(existing["exception.type"]?.description ?? ""):\(existing["exception.message"]?.description ?? "")"
            guard admitError(key) else {
                suppressedErrorsTotal += 1
                scheduleHealth()
                return false
            }
            if suppressedErrors > 0 {
                record.setAttribute(key: "traceway.error.suppressed_count", value: .int(suppressedErrors))
                suppressedErrors = 0
            }
        }
        return true
    }

    /// Stops a crash loop from flooding the server: identical errors within
    /// a second collapse into one, and no more than 60 leave per minute.
    private func admitError(_ key: String) -> Bool {
        let now = Clock.nowMs()
        if key == lastErrorKey, now - lastErrorMs < duplicateErrorWindowMs {
            suppressedErrors += 1
            return false
        }
        errorTimes.removeAll { now - $0 > 60_000 }
        if errorTimes.count >= maxErrorsPerMinute {
            suppressedErrors += 1
            return false
        }
        errorTimes.append(now)
        lastErrorKey = key
        lastErrorMs = now
        return true
    }

    func observe(_ observed: ObservedRecord) {
        guard observed.signal != signalControl, control.enabled else { return }
        // An error or message left out by its sample rate is as if it never
        // happened: it must not upload breadcrumbs or a clip of its own.
        if observed.routed == .filtered, observed.signal == "errors" || observed.signal == "messages" { return }
        if observed.signal == "navigation", sequenceKinds.contains("navigation") {
            screenObservedForSequences = true
        }
        let fired = triggers.observe(ObservedEvent(timeMs: observed.timeMs, lookup: observed.lookup))
        let item = observed.item
        var isError = false
        if observed.signal == "errors", case .log = item.record { isError = true }

        var flushRequested = false
        var replayAvailable = false
        if isError {
            replayAvailable = control.replayMode != .off
            let defaultTrigger = control.settings.triggers.first { $0.id == defaultExceptionTriggerId }
            let replayRequested = fired.contains { $0.trigger.actions.contains { $0.replay || $0.type == "startReplay" } }
            flushRequested = fired.contains {
                $0.trigger.actions.contains { $0.replay && ($0.type == "flush" || $0.type == "capture") }
            }
            let skipped = triggers.skipped[defaultExceptionTriggerId]
            let status: String
            if control.replayMode == .off {
                status = "disabled"
            } else if replayRequested {
                status = "requested"
            } else if let skipped = skipped {
                status = skipped
            } else {
                status = defaultTrigger?.enabled == false ? "trigger_disabled" : "not_triggered"
            }
            item.setAttribute(Attr.replayStatus, .string(status))
            // A clip skipped for cooldown or the per-session limit still gets
            // its breadcrumbs: only the replay is rationed.
            let contextActions = (defaultTrigger?.actions ?? []).filter { $0.type == "flush" && !$0.replay }
            if skipped == "cooldown" || skipped == "session_clip_limit" {
                for action in contextActions { runAction(action) }
            }
            let lookback = contextActions.map { $0.lookbackSeconds ?? 0 }.max() ?? 0
            item.setAttribute("traceway.context.lookback_seconds", .double(lookback))
            item.setAttribute("traceway.context.evicted", .int(buffer.evictedCount))
        }

        let flushesBefore = replayFlushes
        runFired(fired)
        if isError, replayAvailable, flushRequested, replayFlushes == flushesBefore {
            item.setAttribute(Attr.replayStatus, .string("buffer_unavailable"))
        }
        if !fired.isEmpty { router?.sendIfStreaming(observed) }
        if observed.signal == "errors" || observed.signal == "messages" { flushSoon() }
    }
}

/// Hands a value the SDK synchronizes itself to another queue.
struct Unchecked<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// What the main thread reads to record taps: whether taps are recorded and
/// which click selectors the triggers name. Updated on the client's queue.
final class InteractionState {
    private let lock = NSLock()
    private var _recordTaps = false
    private var _clickSelectors: [String] = []

    func update(recordTaps: Bool, clickSelectors: [String]) {
        lock.lock()
        _recordTaps = recordTaps
        _clickSelectors = clickSelectors
        lock.unlock()
    }

    var snapshot: (recordTaps: Bool, clickSelectors: [String]) {
        lock.lock(); defer { lock.unlock() }
        return (_recordTaps, _clickSelectors)
    }
}

extension TracewayLogLevel {
    var severity: Severity {
        switch self {
        case .trace: return .trace
        case .debug: return .debug
        case .info: return .info
        case .warn: return .warn
        case .error: return .error
        case .fatal: return .fatal
        }
    }
}
