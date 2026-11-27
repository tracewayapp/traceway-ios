import Foundation

/// One frame of a MetricKit call stack.
struct MetricKitFrame: Equatable {
    /// The binary's UUID as the wire trace writes it: 32 lowercase hex
    /// digits; nil when MetricKit gave none.
    var uuid: String?
    var offset: UInt?
    var address: UInt?
    var binaryName: String?
}

/// A crash of an earlier run that MetricKit reported
/// (`MXCrashDiagnostic`), read from the JSON `jsonRepresentation()` gives,
/// so the same parser runs everywhere (CONTRACT §14.1).
struct MetricKitCrash {
    /// Signal number, in Darwin's numbering.
    var signal: Int?
    /// Mach exception type (`EXC_BAD_ACCESS` is 1).
    var exceptionType: Int?
    var exceptionCode: Int?
    /// `Namespace SPRINGBOARD, Code 0x8badf00d`.
    var terminationReason: String?
    /// The uncaught Objective-C exception (iOS 17 and later).
    var exceptionName: String?
    var exceptionMessage: String?
    var appVersion: String?
    var appBuild: String?
    /// `iPhone OS 17.2 (21C62)`.
    var osVersion: String?
    var deviceType: String?
    var architecture: String?
    /// The crashed thread's stack, innermost first.
    var frames: [MetricKitFrame]
    /// When it happened, somewhere in between (the payload's window).
    var begin: Date
    var end: Date

    /// The system ended the app for not responding in time (`0x8badf00d`):
    /// a watchdog termination, reported as `WatchdogTermination`.
    var isWatchdogTermination: Bool {
        terminationReason?.lowercased().contains("8badf00d") == true
    }

    /// The signals an in-process handler would have recorded this crash as.
    var signals: Set<Int> {
        if let signal = signal { return [signal] }
        switch exceptionType {
        case 1?: return [MetricKitDiagnostics.sigsegv, MetricKitDiagnostics.sigbus]
        case 2?: return [MetricKitDiagnostics.sigill]
        case 3?: return [MetricKitDiagnostics.sigfpe]
        case 6?: return [MetricKitDiagnostics.sigtrap]
        case 10?: return [MetricKitDiagnostics.sigabrt]
        default: return []
        }
    }

    /// `exception.type` of the issue, as the server groups it:
    /// `WatchdogTermination`, or `NativeCrash` for any other crash.
    var issueType: String { isWatchdogTermination ? "WatchdogTermination" : "NativeCrash" }

    /// `exception.message`: what ended the app, in words.
    /// `SIGSEGV (EXC_BAD_ACCESS)`, `SIGABRT (EXC_CRASH), uncaught
    /// NSInvalidArgumentException: -[NSNull length]: …`, or for a watchdog
    /// `The system ended the app for not responding in time (Namespace
    /// SPRINGBOARD, Code 0x8badf00d)`.
    var issueMessage: String {
        if isWatchdogTermination {
            return "The system ended the app for not responding in time (\(terminationReason ?? "0x8badf00d"))"
        }
        var parts: [String] = []
        var cause = signal.map(MetricKitDiagnostics.signalName) ?? ""
        if let type = exceptionType {
            let name = MetricKitDiagnostics.machExceptionName(type)
            cause = cause.isEmpty ? name : "\(cause) (\(name))"
        }
        if !cause.isEmpty { parts.append(cause) }
        if let name = exceptionName {
            parts.append("uncaught \(name)" + (exceptionMessage.map { ": \($0)" } ?? ""))
        } else if let reason = terminationReason, signal == MetricKitDiagnostics.sigkill {
            // A kill says why only in its termination reason.
            parts.append(reason)
        }
        return parts.isEmpty ? (terminationReason ?? "The app crashed") : parts.joined(separator: ", ")
    }

    /// The wire trace the server symbolicates: the frames' binary UUIDs and
    /// offsets, as the in-process reports write them.
    var stackTrace: String {
        var out = "\(issueType): \(issueMessage)"
        out += "\n*** *** *** *** *** *** *** *** *** *** *** *** *** *** *** ***"
        out += "\nos: ios arch: \(MetricKitDiagnostics.archToken(architecture))"
        for (index, frame) in frames.enumerated() {
            let label = String(format: "#%02d", index)
            if let uuid = frame.uuid, let offset = frame.offset {
                out += "\n\(label) \(uuid) 0x\(String(offset, radix: 16)) \(frame.binaryName ?? "<unknown>")"
            } else {
                let address = frame.address ?? 0
                out += "\n\(label) \(String(repeating: "0", count: 32)) 0x\(String(address, radix: 16)) <unknown>"
            }
        }
        return out
    }

    /// Whether an in-process record of a crash (its signal, Unix ms) is
    /// this one: the same signal within a minute of the payload's window.
    func matches(signal recorded: Int, atMs: Int64) -> Bool {
        let wanted = signals
        guard wanted.isEmpty || wanted.contains(recorded) else { return false }
        return covers(atMs)
    }

    /// Whether `atMs` lies within a minute of the payload's window.
    func covers(_ atMs: Int64) -> Bool {
        let from = Int64.saturatingSum(millisecondsSaturating(begin.timeIntervalSince1970), -60_000)
        let to = Int64.saturatingSum(millisecondsSaturating(end.timeIntervalSince1970), 60_000)
        return atMs >= from && atMs <= to
    }
}

enum MetricKitDiagnostics {
    // Darwin's signal numbers: MetricKit's, whatever the host.
    static let sigill = 4
    static let sigtrap = 5
    static let sigabrt = 6
    static let sigfpe = 8
    static let sigkill = 9
    static let sigbus = 10
    static let sigsegv = 11

    /// Frames kept of one stack.
    static let maxFrames = 512

    /// The crash diagnostics of a payload's JSON. `begin`/`end` are the
    /// payload's own dates when the caller has them; else they are read
    /// from `timeStampBegin`/`timeStampEnd` in `timeZone`. Anything
    /// unreadable is skipped, never thrown.
    static func parseCrashes(_ data: Data, begin: Date? = nil, end: Date? = nil,
                             timeZone: TimeZone = .current) -> [MetricKitCrash] {
        guard let root = (try? JSON.parse(data))?.object else { return [] }
        let windowEnd = end ?? root["timeStampEnd"]?.string.flatMap { timestamp($0, timeZone: timeZone) }
        let windowBegin = begin ?? root["timeStampBegin"]?.string.flatMap { timestamp($0, timeZone: timeZone) }
        guard let first = windowBegin ?? windowEnd, let last = windowEnd ?? windowBegin else { return [] }
        return (root["crashDiagnostics"]?.array ?? []).compactMap { item in
            guard let diagnostic = item.object else { return nil }
            return crash(diagnostic, begin: min(first, last), end: max(first, last))
        }
    }

    private static func crash(_ diagnostic: [String: JSON], begin: Date, end: Date) -> MetricKitCrash? {
        let meta = diagnostic["diagnosticMetaData"]?.object ?? diagnostic["metaData"]?.object ?? [:]
        var crash = MetricKitCrash(
            signal: meta["signal"]?.int,
            exceptionType: meta["exceptionType"]?.int,
            exceptionCode: meta["exceptionCode"]?.int,
            terminationReason: nonEmpty(meta["terminationReason"]?.string),
            exceptionName: nil,
            exceptionMessage: nil,
            appVersion: nonEmpty(meta["appVersion"]?.string),
            appBuild: nonEmpty(meta["appBuildVersion"]?.string),
            osVersion: nonEmpty(meta["osVersion"]?.string),
            deviceType: nonEmpty(meta["deviceType"]?.string),
            architecture: nonEmpty(meta["platformArchitecture"]?.string),
            frames: [],
            begin: begin,
            end: end
        )
        if let reason = (meta["objectiveCexceptionReason"] ?? diagnostic["objectiveCexceptionReason"])?.object {
            crash.exceptionName = nonEmpty(reason["exceptionName"]?.string) ?? nonEmpty(reason["exceptionType"]?.string)
            crash.exceptionMessage = nonEmpty(reason["composedMessage"]?.string)
        }
        crash.frames = crashedThreadFrames(diagnostic["callStackTree"]?.object)
        return crash
    }

    /// The stack of the thread the crash is attributed to (else the first):
    /// a chain of root frames and their first sub-frames, innermost first.
    static func crashedThreadFrames(_ tree: [String: JSON]?) -> [MetricKitFrame] {
        let stacks = (tree?["callStacks"]?.array ?? []).compactMap { $0.object }
        guard let stack = stacks.first(where: { $0["threadAttributed"]?.bool == true }) ?? stacks.first else {
            return []
        }
        var out: [MetricKitFrame] = []
        var node = stack["callStackRootFrames"]?.array?.first
        while let frame = node?.object, out.count < maxFrames {
            out.append(MetricKitFrame(
                uuid: uuidToken(frame["binaryUUID"]?.string),
                offset: unsigned(frame["offsetIntoBinaryTextSegment"]),
                address: unsigned(frame["address"]),
                binaryName: nonEmpty(frame["binaryName"]?.string)
            ))
            node = frame["subFrames"]?.array?.first
        }
        return out
    }

    /// `6B5F4C2A-…` as 32 lowercase hex digits; nil when it is not a UUID.
    static func uuidToken(_ raw: String?) -> String? {
        guard let raw = raw else { return nil }
        let hex = raw.replacingOccurrences(of: "-", with: "").lowercased()
        guard hex.count == 32, hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        return hex
    }

    private static func unsigned(_ value: JSON?) -> UInt? {
        guard let int = value?.int, int >= 0 else { return nil }
        return UInt(exactly: int)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value, !value.isEmpty else { return nil }
        return value
    }

    /// The architecture token of the wire trace (`arm64`, `x64`).
    static func archToken(_ raw: String?) -> String {
        guard let raw = raw?.lowercased(), !raw.isEmpty else { return BinaryImages.currentArch() }
        if raw.hasPrefix("arm64") { return "arm64" }
        if raw == "x86_64" || raw == "x64" { return "x64" }
        if raw.hasPrefix("arm") { return "arm" }
        if raw == "i386" || raw == "x86" { return "ia32" }
        return raw
    }

    /// `2020-06-04 22:49:00` (MetricKit's form, in `timeZone`), with an
    /// offset, or ISO 8601.
    static func timestamp(_ text: String, timeZone: TimeZone) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        for format in ["yyyy-MM-dd HH:mm:ss Z", "yyyy-MM-dd HH:mm:ss"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        let millis = ISO8601.parseMillis(text)
        return millis > 0 ? Date(timeIntervalSince1970: Double(millis) / 1000) : nil
    }

    /// `17.2` of `iPhone OS 17.2 (21C62)`.
    static func osVersionNumber(_ raw: String) -> String? {
        raw.split(separator: " ").first { $0.first?.isNumber == true }.map(String.init)
    }

    static func signalName(_ signal: Int) -> String {
        switch signal {
        case 1: return "SIGHUP"
        case 2: return "SIGINT"
        case 3: return "SIGQUIT"
        case 4: return "SIGILL"
        case 5: return "SIGTRAP"
        case 6: return "SIGABRT"
        case 7: return "SIGEMT"
        case 8: return "SIGFPE"
        case 9: return "SIGKILL"
        case 10: return "SIGBUS"
        case 11: return "SIGSEGV"
        case 12: return "SIGSYS"
        case 13: return "SIGPIPE"
        case 14: return "SIGALRM"
        case 15: return "SIGTERM"
        default: return "SIG\(signal)"
        }
    }

    static func machExceptionName(_ type: Int) -> String {
        switch type {
        case 1: return "EXC_BAD_ACCESS"
        case 2: return "EXC_BAD_INSTRUCTION"
        case 3: return "EXC_ARITHMETIC"
        case 4: return "EXC_EMULATION"
        case 5: return "EXC_SOFTWARE"
        case 6: return "EXC_BREAKPOINT"
        case 10: return "EXC_CRASH"
        case 11: return "EXC_RESOURCE"
        case 12: return "EXC_GUARD"
        default: return "EXC_\(type)"
        }
    }
}
