import Foundation

/// The Traceway public facade.
///
/// Call ``start(connectionString:options:)`` as early as possible — typically in
/// your SwiftUI `App` initializer or `application(_:didFinishLaunchingWithOptions:)`.
/// After that, uncaught `NSException`s and fatal signals are captured
/// automatically; use ``capture(_:)``/``capture(message:)`` for explicit reports.
public enum Traceway {

    /// Starts Traceway and installs crash handlers. Idempotent — the first call
    /// wins. Returns the shared client, or `nil` if the connection string is
    /// invalid (the SDK never crashes the host app over a bad DSN).
    ///
    /// - Parameters:
    ///   - connectionString: `"{token}@{apiUrl}"`, e.g.
    ///     `"abc123@https://your-traceway/api/report"`.
    ///   - options: Optional configuration.
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

        // Device attributes available synchronously.
        client.setDeviceAttributes(DeviceInfoCollector.collectSync())

        // Install crash handlers, then recover crashes from the previous run.
        if let baseDir = baseDir {
            CrashReporter.install(client: client, baseDir: baseDir, persistToDisk: options.persistToDisk)
            CrashReporter.convertPendingCrashes(client: client, baseDir: baseDir)
        }

        // Re-queue anything persisted by a previous process (incl. NSExceptions).
        client.loadPendingFromDisk()

        // Best-effort async device info (IP), then refresh crash metadata.
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

    /// Capture a caught Swift `Error`.
    public static func capture(_ error: Error) {
        TracewayClient.shared?.capture(error)
    }

    /// Capture a caught `NSError`.
    public static func capture(error: NSError) {
        TracewayClient.shared?.capture(error as Error)
    }

    /// Capture a free-form message.
    public static func capture(message: String) {
        TracewayClient.shared?.capture(message: message)
    }

    /// Accepted for API parity with the other Traceway SDKs. This SDK reports
    /// exceptions only (no session timeline), so breadcrumbs are not buffered.
    public static func recordAction(category: String, name: String, data: [String: Any]? = nil) {
        Log.debug("recordAction \(category)/\(name)")
    }

    /// Force a synchronous flush, waiting up to `timeout` seconds (nil = no timeout).
    public static func flush(timeout: TimeInterval? = nil) {
        TracewayClient.shared?.flush(timeout: timeout)
    }

    private static func supportDirectory() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    }
}
