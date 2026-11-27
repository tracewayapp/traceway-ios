import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// What a run of the app said about itself, kept for the next run to tell
/// how it ended: the versions it ran, whether it was in the
/// foreground last, whether a debugger was attached, whether it shut the
/// SDK down or was told it terminates.
struct RunRecord: Equatable {
    var startedAtMs: Int64
    var appVersion: String
    var appBuild: String
    var osVersion: String
    /// When the device booted (Unix seconds); nil where unknown.
    var bootTimeSec: Int64?
    var foreground: Bool
    var debugger: Bool
    var shutdown: Bool = false
    var terminated: Bool = false
    var sessionId: String?

    func encoded() -> JSON {
        var out: [String: JSON] = [
            "v": 1,
            "startedAtMs": JSON(startedAtMs),
            "appVersion": .string(appVersion),
            "appBuild": .string(appBuild),
            "osVersion": .string(osVersion),
            "foreground": .bool(foreground),
            "debugger": .bool(debugger),
            "shutdown": .bool(shutdown),
            "terminated": .bool(terminated),
        ]
        if let boot = bootTimeSec { out["bootTimeSec"] = JSON(boot) }
        if let session = sessionId { out["sessionId"] = .string(session) }
        return .object(out)
    }

    static func decode(_ json: JSON?) -> RunRecord? {
        guard let object = json?.object, object["v"]?.int == 1, let started = object["startedAtMs"]?.int else {
            return nil
        }
        return RunRecord(
            startedAtMs: Int64(started),
            appVersion: object["appVersion"]?.string ?? "",
            appBuild: object["appBuild"]?.string ?? "",
            osVersion: object["osVersion"]?.string ?? "",
            bootTimeSec: object["bootTimeSec"]?.int.map { Int64($0) },
            foreground: object["foreground"]?.bool ?? false,
            debugger: object["debugger"]?.bool ?? false,
            shutdown: object["shutdown"]?.bool ?? false,
            terminated: object["terminated"]?.bool ?? false,
            sessionId: object["sessionId"]?.string
        )
    }
}

/// A crash or fatal hang the SDK recorded itself: MetricKit's report of the
/// same one is not sent again.
struct ExitLedgerEntry: Equatable {
    enum Kind: String {
        /// The signal handler's crash file.
        case signal
        /// An uncaught `NSException` (then `SIGABRT`).
        case exception
        /// A hang that ended the process; `ms` is when it was last seen.
        case hang
    }

    var kind: Kind
    /// Darwin's numbering; 0 for a hang.
    var signal: Int
    var ms: Int64

    func encoded() -> JSON { ["kind": .string(kind.rawValue), "signal": JSON(signal), "ms": JSON(ms)] }

    static func decode(_ json: JSON) -> ExitLedgerEntry? {
        guard let object = json.object, let kind = object["kind"]?.string.flatMap(Kind.init(rawValue:)),
              let ms = object["ms"]?.int
        else { return nil }
        return ExitLedgerEntry(kind: kind, signal: object["signal"]?.int ?? 0, ms: Int64(ms))
    }
}

enum ExitReasons {
    static let runKey = "run"
    static let ledgerKey = "exitLedger"
    /// Entries kept, and for how long: MetricKit reports a crash at the next
    /// launch (iOS 15) or within a day (iOS 14).
    static let maxLedgerEntries = 32
    static let ledgerMaxAgeMs: Int64 = 8 * 86_400_000
    /// How long the next run waits for MetricKit before it counts a likely
    /// out-of-memory exit: a crash MetricKit reports was not one.
    static let oomGraceMs: Int64 = 20_000

    /// Whether the last run most likely ran out of memory: it was in the
    /// foreground, no crash or fatal hang was recorded, it neither shut the
    /// SDK down nor exited nor was told it terminates, no debugger was
    /// attached, and the app, its build, the OS and the boot are the same
    /// (an update, a reboot or Xcode's stop button end a run too). A
    /// heuristic: it becomes an `app.oom` count, never an issue.
    static func likelyOutOfMemory(previous: RunRecord?, current: RunRecord, exited: Bool, crashRecorded: Bool) -> Bool {
        guard let last = previous else { return false }
        return last.foreground && !last.shutdown && !last.terminated && !exited && !last.debugger && !crashRecorded
            && last.appVersion == current.appVersion && last.appBuild == current.appBuild
            && last.osVersion == current.osVersion
            && sameBoot(last.bootTimeSec, current.bootTimeSec)
    }

    /// Boot times read in two runs differ by a second or so; unknown ones
    /// do not decide.
    static func sameBoot(_ a: Int64?, _ b: Int64?) -> Bool {
        guard let a = a, let b = b else { return true }
        return a <= Int64.saturatingSum(b, 5) && b <= Int64.saturatingSum(a, 5)
    }

    static func ledger(_ json: JSON?) -> [ExitLedgerEntry] {
        (json?.array ?? []).compactMap(ExitLedgerEntry.decode)
    }

    /// `entries` with `entry` added, the oldest beyond `maxLedgerEntries`
    /// and those older than `ledgerMaxAgeMs` gone.
    static func appending(_ entry: ExitLedgerEntry, to entries: [ExitLedgerEntry], nowMs: Int64) -> [ExitLedgerEntry] {
        let oldest = Int64.saturatingSum(nowMs, -ledgerMaxAgeMs)
        let kept = (entries + [entry]).filter { $0.ms >= oldest }
        return Array(kept.suffix(maxLedgerEntries))
    }

    /// Whether the SDK's own handlers recorded the crash MetricKit reports:
    /// the same signal within a minute of its window.
    static func recordedInProcess(_ crash: MetricKitCrash, ledger: [ExitLedgerEntry]) -> Bool {
        ledger.contains { $0.kind != .hang && crash.matches(signal: $0.signal, atMs: $0.ms) }
    }

    /// Whether a watchdog termination is the end of a hang the SDK already
    /// reported as fatal.
    static func fatalHangReported(_ crash: MetricKitCrash, ledger: [ExitLedgerEntry]) -> Bool {
        crash.isWatchdogTermination && ledger.contains { $0.kind == .hang && crash.covers($0.ms) }
    }

    /// When the device booted, in Unix seconds; nil where it cannot be read.
    static func bootTimeSec() -> Int64? {
        #if canImport(Darwin)
        var boot = timeval()
        var size = MemoryLayout<timeval>.stride
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0, boot.tv_sec > 0 else { return nil }
        return Int64(boot.tv_sec)
        #else
        guard let stat = try? String(contentsOfFile: "/proc/stat", encoding: .utf8) else { return nil }
        for line in stat.split(separator: "\n") where line.hasPrefix("btime ") {
            return Int64(line.dropFirst("btime ".count).trimmingCharacters(in: .whitespaces))
        }
        return nil
        #endif
    }

    /// The app's build number (`CFBundleVersion`).
    static var appBuild: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? ""
    }
}

// MARK: - exit()

/// Where `exit` leaves its marker; set once, never freed: the handler runs
/// while the process ends.
private var twExitMarkerPath: UnsafeMutablePointer<CChar>?
private let twExitMarkerLock = NSLock()
private var twExitHandlerRegistered = false

private func twExitHandler() {
    guard let path = twExitMarkerPath else { return }
    let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
    if fd >= 0 { close(fd) }
}

/// A run that ends with `exit` (the app's own call) leaves a marker file, so
/// the next run does not take it for a crash or an out-of-memory exit.
enum ExitMarker {
    static let fileName = "run_exited"

    /// Registers the `atexit` handler once per process; a later call only
    /// moves the marker to `directory`.
    static func install(directory: URL) {
        let bytes = Array(directory.appendingPathComponent(fileName).path.utf8)
        let path = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count + 1)
        for (index, byte) in bytes.enumerated() { path[index] = CChar(bitPattern: byte) }
        path[bytes.count] = 0
        twExitMarkerLock.lock()
        defer { twExitMarkerLock.unlock() }
        // The old path is kept: an exit on another thread may be reading it.
        twExitMarkerPath = path
        guard !twExitHandlerRegistered else { return }
        twExitHandlerRegistered = true
        atexit(twExitHandler)
    }

    /// Whether the last run left the marker; it is removed.
    static func take(directory: URL?) -> Bool {
        guard let marker = directory?.appendingPathComponent(fileName),
              FileManager.default.fileExists(atPath: marker.path)
        else { return false }
        try? FileManager.default.removeItem(at: marker)
        return true
    }

    /// Runs the handler `exit` would (tests).
    static func runHandlerForTesting() { twExitHandler() }
}
