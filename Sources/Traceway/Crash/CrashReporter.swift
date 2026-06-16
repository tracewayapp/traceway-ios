import Foundation

enum CrashReporter {

    static func install(client: TracewayClient, baseDir: URL, persistToDisk: Bool) {

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

    static func updateMetadata(client: TracewayClient) {
        let metadata = CrashRecordStore.buildMetadata(
            attributes: client.currentDeviceAttributes(),
            appVersion: client.appVersion
        )
        SignalHandler.setMetadata(metadata)
    }

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
