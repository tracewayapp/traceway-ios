import Foundation

struct PendingEntry {
    let id: String
    let createdAtMs: Int64
    let exception: ExceptionStackTrace
}

final class ExceptionStore {
    private let dir: URL
    private let maxLocalFiles: Int
    private let maxAgeHours: Int
    private let fileManager = FileManager.default
    private let lock = NSLock()

    private(set) var isAvailable = false

    init(dir: URL, maxLocalFiles: Int, maxAgeHours: Int) {
        self.dir = dir
        self.maxLocalFiles = maxLocalFiles
        self.maxAgeHours = maxAgeHours
    }

    func initialize() {
        lock.lock(); defer { lock.unlock() }
        if isAvailable { return }
        do {
            if !fileManager.fileExists(atPath: dir.path) {
                try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            excludeFromBackup(dir)
            var isDir: ObjCBool = false
            isAvailable = fileManager.fileExists(atPath: dir.path, isDirectory: &isDir) && isDir.boolValue
            pruneExpiredLocked()
            pruneExcessLocked()
            if isAvailable { Log.debug("exception store ready at \(dir.path)") }
        } catch {
            isAvailable = false
            Log.warn("disk storage unavailable: \(error)")
        }
    }

    @discardableResult
    func write(_ exception: ExceptionStackTrace) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard isAvailable else { return nil }
        let id = UUID().uuidString
        let wrapper = JSONValue.object([
            ("createdAt", .string(ISO8601.format(millis: ISO8601.nowMillis()))),
            ("exception", exception.toJSON()),
        ])
        do {
            try Data(wrapper.serialize().utf8).write(to: fileURL(id), options: .atomic)
            Log.debug("persisted exception \(id)")
            return id
        } catch {
            Log.warn("failed to write exception to disk: \(error)")
            return nil
        }
    }

    func remove(_ fileIds: [String]) {
        lock.lock(); defer { lock.unlock() }
        guard isAvailable else { return }
        for id in fileIds {
            try? fileManager.removeItem(at: fileURL(id))
        }
    }

    func loadAll() -> [PendingEntry] {
        lock.lock(); defer { lock.unlock() }
        guard isAvailable else { return [] }
        var entries: [PendingEntry] = []
        for file in jsonFilesLocked() {
            do {
                let data = try Data(contentsOf: file)
                guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let exceptionObj = obj["exception"] as? [String: Any] else {
                    try? fileManager.removeItem(at: file)
                    continue
                }
                let id = file.deletingPathExtension().lastPathComponent
                let exception = ExceptionStackTrace.from(jsonObject: exceptionObj)
                exception.fileId = id
                let createdAt = ISO8601.parseMillis(obj["createdAt"] as? String ?? "")
                entries.append(PendingEntry(id: id, createdAtMs: createdAt, exception: exception))
            } catch {
                try? fileManager.removeItem(at: file)
                Log.warn("removed corrupt file \(file.lastPathComponent): \(error)")
            }
        }
        entries.sort { $0.createdAtMs < $1.createdAtMs }
        return entries
    }

    private func pruneExpiredLocked() {
        guard isAvailable else { return }
        let cutoff = ISO8601.nowMillis() - Int64(maxAgeHours) * 3_600_000
        for file in jsonFilesLocked() {
            guard let data = try? Data(contentsOf: file),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                try? fileManager.removeItem(at: file)
                continue
            }
            let createdAt = ISO8601.parseMillis(obj["createdAt"] as? String ?? "")
            if createdAt < cutoff {
                try? fileManager.removeItem(at: file)
            }
        }
    }

    private func pruneExcessLocked() {
        guard isAvailable else { return }
        let files = jsonFilesLocked().sorted { modificationDate($0) < modificationDate($1) }
        guard files.count > maxLocalFiles else { return }
        for file in files.prefix(files.count - maxLocalFiles) {
            try? fileManager.removeItem(at: file)
        }
    }

    private func fileURL(_ id: String) -> URL {
        dir.appendingPathComponent("\(id).json")
    }

    private func jsonFilesLocked() -> [URL] {
        let contents = (try? fileManager.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents.filter { $0.pathExtension == "json" }
    }

    private func modificationDate(_ url: URL) -> Date {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        return (attributes?[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
    }

    private func excludeFromBackup(_ url: URL) {
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutableURL.setResourceValues(values)
    }
}
