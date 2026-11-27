import Foundation

/// Hard crashes: uncaught `NSException`s are recorded on the crashing thread;
/// fatal signals (Swift traps, `fatalError`, bad memory access) are written
/// to disk by an async-signal-safe handler and reported on the next start.
enum CrashReporter {
    static func install(
        owner: ObjectIdentifier,
        baseDir: URL?,
        persistToDisk: Bool,
        metadata: [String: String],
        appVersion: String
    ) {
        guard persistToDisk, let baseDir = baseDir else {
            #if canImport(Darwin)
            SignalHandler.disableRecording()
            #endif
            Log.debug("signal handlers disabled (persistToDisk = false)")
            return
        }
        #if canImport(Darwin)
        let crashDir = CrashRecordStore.directory(base: baseDir)
        try? FileManager.default.createDirectory(at: crashDir, withIntermediateDirectories: true)
        SignalHandler.install(
            crashPath: CrashRecordStore.crashFilePath(dir: crashDir),
            metadata: CrashRecordStore.buildMetadata(attributes: metadata, appVersion: appVersion),
            imagesSection: CrashRecordStore.buildImagesSection(
                arch: BinaryImages.currentArch(),
                images: BinaryImages.capture()
            ),
            owner: owner
        )
        #endif
    }

    static func uninstall(owner: ObjectIdentifier) {
        #if canImport(Darwin)
        SignalHandler.uninstall(owner: owner)
        #endif
    }

    /// Whether the signal handler records crashes in this process: without
    /// it there is no metadata to keep up to date.
    static var recordsSignals: Bool {
        #if canImport(Darwin)
        return SignalHandler.isInstalled
        #else
        return false
        #endif
    }

    /// What a crash record says about the app: the session it happened in
    /// and the attributes known then. Called when they change.
    static func updateMetadata(_ metadata: [String: String], owner: ObjectIdentifier, appVersion: String) {
        #if canImport(Darwin)
        SignalHandler.setMetadata(CrashRecordStore.buildMetadata(attributes: metadata, appVersion: appVersion), owner: owner)
        #endif
    }

    /// The crashes earlier runs left on disk; the files are removed.
    static func takePendingCrashes(baseDir: URL?) -> [CrashRecord] {
        guard let baseDir = baseDir else { return [] }
        return CrashRecordStore.convertPending(dir: CrashRecordStore.directory(base: baseDir))
    }

    /// Older crash, hang and 0.1.x report files carry no destination identity.
    static func discardUnscopedReports(support: URL?, state: URL?) {
        for file in [support.map(CrashRecordStore.directory(base:)),
                     support?.appendingPathComponent("traceway_pending"),
                     state?.appendingPathComponent(AppHangMonitor.fileName)].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
