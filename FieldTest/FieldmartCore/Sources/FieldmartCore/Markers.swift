import Foundation

/// The marker lines of `02-APP-SPEC.md` §7 (`FM_READY <epochMs>` …), plus
/// their JSON-lines form in the marker files the app writes.
public struct Marker: Equatable {
    public enum Kind: String {
        case ready = "FM_READY"
        case fully = "FM_FULLY"
        case screen = "FM_SCREEN"
        case session = "FM_SESSION"
        case checkpoint = "FM_CP"
        case done = "FM_DONE"
        /// iOS addition: the process start time the kernel reports.
        case processStart = "FM_PROC_START"
        /// iOS addition: the SDK start returned (`detail` = ms it took).
        case sdkStarted = "FM_SDK_STARTED"
    }

    public var kind: Kind
    public var epochMs: Int64
    /// The screen or checkpoint name, the session id, or a note.
    public var detail: String?

    public init(_ kind: Kind, epochMs: Int64, detail: String? = nil) {
        self.kind = kind
        self.epochMs = epochMs
        self.detail = detail
    }

    /// `FM_SCREEN home 1795000000000`, `FM_SESSION <id>`, `FM_READY <ms>`.
    public var line: String {
        switch kind {
        case .session:
            return "\(kind.rawValue) \(detail ?? "")"
        case .screen, .checkpoint, .sdkStarted:
            return "\(kind.rawValue) \(detail ?? "") \(epochMs)"
        default:
            return "\(kind.rawValue) \(epochMs)"
        }
    }

    /// One line of a marker file.
    public var jsonLine: String {
        var parts = ["\"name\":\(Marker.quote(kind.rawValue))", "\"epochMs\":\(epochMs)"]
        if let detail = detail { parts.append("\"detail\":\(Marker.quote(detail))") }
        return "{" + parts.joined(separator: ",") + "}"
    }

    /// Parses `line` (the log form) back.
    public init?(line: String) {
        let parts = line.split(separator: " ").map(String.init)
        guard let first = parts.first, let kind = Kind(rawValue: first) else { return nil }
        switch kind {
        case .session:
            guard parts.count >= 2 else { return nil }
            self.init(kind, epochMs: 0, detail: parts[1])
        case .screen, .checkpoint, .sdkStarted:
            guard parts.count >= 3, let ms = Int64(parts[parts.count - 1]) else { return nil }
            self.init(kind, epochMs: ms, detail: parts[1..<(parts.count - 1)].joined(separator: " "))
        default:
            guard parts.count >= 2, let ms = Int64(parts[1]) else { return nil }
            self.init(kind, epochMs: ms)
        }
    }

    /// Parses one marker-file line.
    public init?(jsonLine: String) {
        guard let data = jsonLine.data(using: .utf8), let json = try? JSONValue.parse(data),
              let name = json["name"]?.string, let kind = Kind(rawValue: name) else { return nil }
        self.init(kind, epochMs: json["epochMs"]?.int64 ?? 0, detail: json["detail"]?.string)
    }

    /// Every marker in a marker file's contents, in file order.
    public static func parseFile(_ text: String) -> [Marker] {
        text.split(separator: "\n").compactMap { Marker(jsonLine: String($0)) }
    }

    /// A JSON string literal.
    public static func quote(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    let hex = String(scalar.value, radix: 16)
                    out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}

/// One line per second of the in-app probe (`03-MEASUREMENT.md` §3.4),
/// written to `Documents/fm-probe/<run>.jsonl`. The first line of a file is
/// a `ProbeHeader`.
public struct ProbeSample: Equatable {
    /// Milliseconds since the probe started.
    public var t: Int64
    public var epochMs: Int64
    /// Process CPU time (`getrusage`, every thread that ever ran).
    public var cpuUserMs: Double
    public var cpuSysMs: Double
    /// The main thread's CPU time (`thread_info`).
    public var mainUserMs: Double
    public var mainSysMs: Double
    public var threads: Int
    /// `task_info(TASK_VM_INFO).phys_footprint`.
    public var footprintKb: Int64
    public var residentKb: Int64
    /// Intervals between display-link callbacks since the last line, µs.
    public var frames: [Int]

    public init(t: Int64, epochMs: Int64, cpuUserMs: Double, cpuSysMs: Double, mainUserMs: Double,
                mainSysMs: Double, threads: Int, footprintKb: Int64, residentKb: Int64, frames: [Int]) {
        self.t = t
        self.epochMs = epochMs
        self.cpuUserMs = cpuUserMs
        self.cpuSysMs = cpuSysMs
        self.mainUserMs = mainUserMs
        self.mainSysMs = mainSysMs
        self.threads = threads
        self.footprintKb = footprintKb
        self.residentKb = residentKb
        self.frames = frames
    }

    public var jsonLine: String {
        func ms(_ value: Double) -> String { String(Int64((value * 1000).rounded())).padMilli() }
        return "{\"t\":\(t),\"epochMs\":\(epochMs),\"cpuUserMs\":\(ms(cpuUserMs)),\"cpuSysMs\":\(ms(cpuSysMs)),"
            + "\"mainUserMs\":\(ms(mainUserMs)),\"mainSysMs\":\(ms(mainSysMs)),\"threads\":\(threads),"
            + "\"footprintKb\":\(footprintKb),\"residentKb\":\(residentKb),"
            + "\"frames\":[\(frames.map(String.init).joined(separator: ","))]}"
    }
}

public struct ProbeHeader: Equatable {
    public var run: String
    public var variant: String
    public var scenario: String
    public var build: String
    public var startEpochMs: Int64
    public var processStartEpochMs: Int64?
    public var maxFramesPerSecond: Int

    public init(run: String, variant: String, scenario: String, build: String, startEpochMs: Int64,
                processStartEpochMs: Int64?, maxFramesPerSecond: Int) {
        self.run = run
        self.variant = variant
        self.scenario = scenario
        self.build = build
        self.startEpochMs = startEpochMs
        self.processStartEpochMs = processStartEpochMs
        self.maxFramesPerSecond = maxFramesPerSecond
    }

    public var jsonLine: String {
        var parts = [
            "\"probe\":1",
            "\"run\":\(Marker.quote(run))",
            "\"variant\":\(Marker.quote(variant))",
            "\"scenario\":\(Marker.quote(scenario))",
            "\"build\":\(Marker.quote(build))",
            "\"startEpochMs\":\(startEpochMs)",
            "\"maxFps\":\(maxFramesPerSecond)",
        ]
        if let start = processStartEpochMs { parts.append("\"procStartEpochMs\":\(start)") }
        return "{" + parts.joined(separator: ",") + "}"
    }
}

extension String {
    /// `"12345"` (thousandths) → `"12.345"`: three decimals without
    /// floating-point text.
    func padMilli() -> String {
        var digits = self
        var negative = false
        if digits.hasPrefix("-") {
            negative = true
            digits.removeFirst()
        }
        while digits.count < 4 { digits = "0" + digits }
        let split = digits.index(digits.endIndex, offsetBy: -3)
        let whole = String(digits[..<split])
        let fraction = String(digits[split...])
        return (negative ? "-" : "") + whole + "." + fraction
    }
}
