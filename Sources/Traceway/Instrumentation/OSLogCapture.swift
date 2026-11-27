import Foundation
#if canImport(OSLog)
import OSLog
#endif

/// A line the app logged through the system, for the `console` signal.
struct CapturedLogLine: Equatable {
    var date: Date
    var level: TracewayLogLevel
    var message: String
    var subsystem: String
    var category: String
}

/// The app's own entries in the unified log.
protocol OSLogEntrySource: AnyObject {
    /// Hands `visit` each entry logged at or after `since`, oldest first,
    /// one at a time: nothing is gathered here, so a read holds only what
    /// the reader keeps.
    func entries(since: Date, _ visit: (CapturedLogLine) -> Void) throws
}

/// Reads what the app logs with `NSLog`, `os_log` and `Logger`
/// incrementally: each `read` returns the entries since the last one, once
/// each, without the SDK's own lines and the system frameworks'
/// (`com.apple.*` subsystems), at most `maxLinesPerRead` (the newest), each
/// message at most `maxMessageBytes`. The limits hold while the entries are
/// read, so a burst of 100,000 lines or a multi-megabyte line never sits in
/// memory. Thread-safe.
final class OSLogReader {
    static let maxLinesPerRead = 1000
    static let maxMessageBytes = 16 * 1024

    private let source: OSLogEntrySource
    private let lock = NSLock()
    private var cursor: Date
    /// Entries at exactly `cursor` already returned: the next read starts
    /// there again.
    private var seenAtCursor: Set<Int> = []
    /// The most lines the last read held at once, for tests.
    private(set) var lastReadPeak = 0

    init(source: OSLogEntrySource, since: Date) {
        self.source = source
        cursor = since
    }

    func read() -> [CapturedLogLine] {
        lock.lock()
        defer { lock.unlock() }
        let since = cursor
        let seenBefore = seenAtCursor
        var kept = LineRing(capacity: OSLogReader.maxLinesPerRead)
        var newest = cursor
        var seenAtNewest = seenAtCursor
        let read = guarded("os log read", fallback: false) {
            try source.entries(since: since) { entry in
                if entry.date < since { return }
                let message = OSLogReader.clip(entry.message)
                let key = OSLogReader.identity(entry, message: message)
                if entry.date == since, seenBefore.contains(key) { return }
                if entry.date > newest {
                    newest = entry.date
                    seenAtNewest = []
                }
                // Bounded: only lines logged in one instant are kept here.
                if entry.date == newest, seenAtNewest.count < OSLogReader.maxLinesPerRead {
                    seenAtNewest.insert(key)
                }
                var line = entry
                line.message = message
                if OSLogReader.isCaptured(line) { kept.append(line) }
            }
            return true
        }
        lastReadPeak = kept.peak
        guard read else { return [] }
        cursor = newest
        seenAtCursor = seenAtNewest
        return kept.lines
    }

    private static func identity(_ entry: CapturedLogLine, message: String) -> Int {
        var hasher = Hasher()
        hasher.combine(entry.subsystem)
        hasher.combine(entry.category)
        hasher.combine(message)
        return hasher.finalize()
    }

    /// Whether a line is the app's: not the SDK's own debug output, not a
    /// system framework's.
    static func isCaptured(_ entry: CapturedLogLine) -> Bool {
        if entry.message.isEmpty { return false }
        if entry.subsystem.hasPrefix("com.apple.") { return false }
        if isOwnLine(entry.message) { return false }
        return true
    }

    /// A line the SDK logged itself (`[Traceway] …`).
    static func isOwnLine(_ text: String) -> Bool {
        text.contains("[\(Log.tag)] ")
    }

    static func clipped(_ entry: CapturedLogLine) -> CapturedLogLine {
        var out = entry
        out.message = clip(entry.message)
        return out
    }

    /// At most `maxMessageBytes` of UTF-8, cut at a character.
    static func clip(_ text: String) -> String {
        guard text.utf8.count > maxMessageBytes else { return text }
        var bytes = 0
        var end = text.startIndex
        for index in text.indices {
            let size = text[index].utf8.count
            if bytes + size > maxMessageBytes { break }
            bytes += size
            end = text.index(after: index)
        }
        return String(text[..<end])
    }

    /// `OSLogEntryLog.Level` (undefined 0, debug 1, info 2, notice 3, error
    /// 4, fault 5) as a log level: `notice`, what `NSLog` and a plain
    /// `os_log` write, is `info`; a fault is `fatal`.
    static func level(osLogLevel raw: Int) -> TracewayLogLevel {
        switch raw {
        case 1: return .debug
        case 4: return .error
        case 5: return .fatal
        default: return .info
        }
    }
}

/// The newest `capacity` lines appended, oldest first.
struct LineRing {
    private var storage: [CapturedLogLine] = []
    private var next = 0
    let capacity: Int
    private(set) var peak = 0

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    mutating func append(_ line: CapturedLogLine) {
        if storage.count < capacity {
            storage.append(line)
            peak = storage.count
        } else {
            storage[next] = line
            next = (next + 1) % capacity
        }
    }

    var lines: [CapturedLogLine] {
        Array(storage[next...] + storage[..<next])
    }
}

#if canImport(OSLog)
/// The current process's entries, through `OSLogStore` (iOS 15, macOS 12).
/// Entries are enumerated one by one; the system frameworks' are skipped
/// before their message is composed. (No `NSPredicate`: a key the store does
/// not support raises an Objective-C exception Swift cannot contain.)
@available(iOS 15.0, macOS 12.0, tvOS 15.0, watchOS 8.0, *)
final class OSLogStoreSource: OSLogEntrySource {
    func entries(since: Date, _ visit: (CapturedLogLine) -> Void) throws {
        // A store opened now: one opened earlier does not see later entries.
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        for entry in try store.getEntries(at: store.position(date: since)) {
            guard let log = entry as? OSLogEntryLog, !log.subsystem.hasPrefix("com.apple.") else { continue }
            visit(CapturedLogLine(
                date: log.date,
                level: OSLogReader.level(osLogLevel: log.level.rawValue),
                message: log.composedMessage,
                subsystem: log.subsystem,
                category: log.category
            ))
        }
    }
}
#endif
