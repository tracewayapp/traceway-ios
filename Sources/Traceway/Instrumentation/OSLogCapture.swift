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
    /// The entries logged at or after `since`, oldest first.
    func entries(since: Date) throws -> [CapturedLogLine]
}

/// Reads what the app logs with `NSLog`, `os_log` and `Logger`
/// incrementally (CONTRACT §14.3): each `read` returns the entries since
/// the last one, once each, without the SDK's own lines and the system
/// frameworks' (`com.apple.*` subsystems), at most `maxLinesPerRead` (the
/// newest), each message at most `maxMessageBytes`. Thread-safe.
final class OSLogReader {
    static let maxLinesPerRead = 1000
    static let maxMessageBytes = 16 * 1024

    private let source: OSLogEntrySource
    private let lock = NSLock()
    private var cursor: Date
    /// Entries at exactly `cursor` already returned: the next read starts
    /// there again.
    private var seenAtCursor: Set<String> = []

    init(source: OSLogEntrySource, since: Date) {
        self.source = source
        cursor = since
    }

    func read() -> [CapturedLogLine] {
        lock.lock()
        defer { lock.unlock() }
        let since = cursor
        guard let entries = guarded("os log read", fallback: nil, { try source.entries(since: since) }) else {
            return []
        }
        var fresh: [CapturedLogLine] = []
        var newest = cursor
        var seenAtNewest = seenAtCursor
        for entry in entries {
            if entry.date < cursor { continue }
            let key = OSLogReader.identity(entry)
            if entry.date == cursor, seenAtCursor.contains(key) { continue }
            if entry.date > newest {
                newest = entry.date
                seenAtNewest = []
            }
            if entry.date == newest { seenAtNewest.insert(key) }
            if OSLogReader.isCaptured(entry) { fresh.append(entry) }
        }
        cursor = newest
        seenAtCursor = seenAtNewest
        if fresh.count > OSLogReader.maxLinesPerRead { fresh = Array(fresh.suffix(OSLogReader.maxLinesPerRead)) }
        return fresh.map(OSLogReader.clipped)
    }

    private static func identity(_ entry: CapturedLogLine) -> String {
        "\(entry.subsystem)\u{1}\(entry.category)\u{1}\(entry.message)"
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

#if canImport(OSLog)
/// The current process's entries, through `OSLogStore` (iOS 15, macOS 12).
@available(iOS 15.0, macOS 12.0, tvOS 15.0, watchOS 8.0, *)
final class OSLogStoreSource: OSLogEntrySource {
    func entries(since: Date) throws -> [CapturedLogLine] {
        // A store opened now: one opened earlier does not see later entries.
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        var out: [CapturedLogLine] = []
        for entry in try store.getEntries(at: store.position(date: since)) {
            // The system frameworks' entries are dropped here already.
            guard let log = entry as? OSLogEntryLog, !log.subsystem.hasPrefix("com.apple.") else { continue }
            out.append(CapturedLogLine(
                date: log.date,
                level: OSLogReader.level(osLogLevel: log.level.rawValue),
                message: log.composedMessage,
                subsystem: log.subsystem,
                category: log.category
            ))
        }
        return out
    }
}
#endif
