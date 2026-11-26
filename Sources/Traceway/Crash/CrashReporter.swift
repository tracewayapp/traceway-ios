import Foundation

/// Hard crashes: uncaught `NSException`s are recorded on the crashing thread;
/// fatal signals (Swift traps, `fatalError`, bad memory access) are written
/// to disk by an async-signal-safe handler and reported on the next start.
enum CrashReporter {
    static func install(
        baseDir: URL?,
        persistToDisk: Bool,
        metadata: [String: String],
        appVersion: String
    ) {
        guard persistToDisk, let baseDir = baseDir else {
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
            )
        )
        #endif
    }

    /// What a crash record says about the app: the session it happened in
    /// and the attributes known then. Called when they change.
    static func updateMetadata(_ metadata: [String: String], appVersion: String) {
        #if canImport(Darwin)
        SignalHandler.setMetadata(CrashRecordStore.buildMetadata(attributes: metadata, appVersion: appVersion))
        #endif
    }

    /// The crashes earlier runs left on disk; the files are removed.
    static func takePendingCrashes(baseDir: URL?) -> [CrashRecord] {
        guard let baseDir = baseDir else { return [] }
        return CrashRecordStore.convertPending(dir: CrashRecordStore.directory(base: baseDir))
    }
}

/// Reports the 1.x SDK left on disk without sending them: they are reported
/// once over OTLP, as exceptions and messages of this project, if they are
/// younger than the 12 hours 1.x kept them. The directory is removed.
enum LegacyReports {
    static let maxAgeMs: Int64 = 12 * 60 * 60 * 1000

    struct Report {
        var stackTrace: String
        var recordedAtMs: Int64
        var attributes: [String: String]
        var isMessage: Bool
    }

    static func take(baseDir: URL?, now: Int64 = Clock.nowMs()) -> [Report] {
        guard let dir = baseDir?.appendingPathComponent("traceway_pending"),
              FileManager.default.fileExists(atPath: dir.path)
        else { return [] }
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var reports: [Report] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let object = try? JSON.parse(data).object,
                  let exception = object["exception"]?.object,
                  let stackTrace = exception["stackTrace"]?.string, !stackTrace.isEmpty
            else { continue }
            let recordedAt = ISO8601.parseMillis(exception["recordedAt"]?.string ?? "")
            let createdAt = ISO8601.parseMillis(object["createdAt"]?.string ?? "")
            guard now - max(recordedAt, createdAt) < maxAgeMs else { continue }
            var attributes: [String: String] = [:]
            for (key, value) in exception["attributes"]?.object ?? [:] { attributes[key] = value.text }
            reports.append(Report(
                stackTrace: stackTrace,
                recordedAtMs: recordedAt > 0 ? recordedAt : createdAt,
                attributes: attributes,
                isMessage: exception["isMessage"]?.bool ?? false
            ))
        }
        return reports.sorted { $0.recordedAtMs < $1.recordedAtMs }
    }
}
