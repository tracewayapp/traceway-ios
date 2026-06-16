import Foundation

/// Orchestrates crash capture: installs the NSException + signal handlers,
/// keeps the signal handler's device metadata current, and converts crashes
/// recorded by a previous run into normal reports.
enum CrashReporter {

    /// Installs handlers. Signal capture requires disk persistence (a hard crash
    /// cannot be uploaded in-process), so it is gated on `persistToDisk`.
    static func install(client: TracewayClient, baseDir: URL, persistToDisk: Bool) {
        // NSException capture works without disk (best-effort in-process flush).
        NSExceptionHandler.install(client: client)

        guard persistToDisk else {
            Log.debug("signal handlers disabled (persistToDisk = false)")
            return
        }

        let crashDir = CrashRecordStore.directory(base: baseDir)
        try? FileManager.default.createDirectory(at: crashDir, withIntermediateDirectories: true)

        let metadata = CrashRecordStore.buildMetadata(
            attributes: client.currentDeviceAttributes(),
            appVersion: client.appVersion
        )
        // Capture the binary-image map once: the ASLR slide is fixed for the
        // process lifetime, so these load addresses stay valid for any crash.
        let imagesSection = CrashRecordStore.buildImagesSection(
            arch: BinaryImages.currentArch(),
            images: BinaryImages.capture()
        )
        SignalHandler.install(
            crashPath: CrashRecordStore.crashFilePath(dir: crashDir),
            metadata: metadata,
            imagesSection: imagesSection
        )
    }

    /// Refreshes the signal handler's pre-serialized device metadata (e.g. after
    /// the async IP lookup completes).
    static func updateMetadata(client: TracewayClient) {
        let metadata = CrashRecordStore.buildMetadata(
            attributes: client.currentDeviceAttributes(),
            appVersion: client.appVersion
        )
        SignalHandler.setMetadata(metadata)
    }

    /// Converts crash records left by a previous run into pending reports.
    static func convertPendingCrashes(client: TracewayClient, baseDir: URL) {
        let crashDir = CrashRecordStore.directory(base: baseDir)
        let records = CrashRecordStore.convertPending(dir: crashDir)
        if records.isEmpty { return }
        Log.debug("recovered \(records.count) crash(es) from previous run")
        for record in records {
            client.addException(record)
        }
    }
}
