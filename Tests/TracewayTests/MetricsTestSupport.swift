import Foundation
import XCTest
@testable import Traceway

/// A deterministic scheduler for the metrics tests: the clock moves only
/// through `advance`, timers fire in order as it passes them, and uploads
/// wait for `runIo` (or run at once with `ioInline`).
final class ManualMetricsScheduler: MetricsScheduler {
    private final class Timer: MetricsCancellable {
        let at: Int64
        let seq: Int
        let task: () -> Void
        var cancelled = false

        init(at: Int64, seq: Int, task: @escaping () -> Void) {
            self.at = at
            self.seq = seq
            self.task = task
        }

        func cancel() { cancelled = true }
    }

    private let lock = NSLock()
    private var seq = 0
    private var timers: [Timer] = []
    private var ioQueue: [() -> Void] = []
    private var _nowMs: Int64
    var ioInline: Bool

    init(nowMs: Int64 = 1_700_000_000_000, ioInline: Bool = true) {
        _nowMs = nowMs
        self.ioInline = ioInline
    }

    var nowMs: Int64 {
        get {
            lock.lock(); defer { lock.unlock() }
            return _nowMs
        }
        set {
            lock.lock()
            _nowMs = newValue
            lock.unlock()
        }
    }

    func now() -> Int64 { nowMs }

    func schedule(afterMs delayMs: Int64, _ task: @escaping () -> Void) -> MetricsCancellable {
        lock.lock(); defer { lock.unlock() }
        let timer = Timer(at: _nowMs + max(0, delayMs), seq: seq, task: task)
        seq += 1
        timers.append(timer)
        return timer
    }

    func io(_ task: @escaping () -> Void) {
        if ioInline {
            task()
        } else {
            lock.lock()
            ioQueue.append(task)
            lock.unlock()
        }
    }

    /// Moves the clock forward by `ms`, running every timer due on the way.
    func advance(_ ms: Int64) {
        let target = nowMs + ms
        while true {
            lock.lock()
            let due = timers.filter { $0.at <= target }.min { ($0.at, $0.seq) < ($1.at, $1.seq) }
            if let due = due {
                timers.removeAll { $0 === due }
                if due.at > _nowMs { _nowMs = due.at }
            }
            lock.unlock()
            guard let timer = due else { break }
            if !timer.cancelled { timer.task() }
        }
        nowMs = target
    }

    /// Runs queued uploads, including ones they queue.
    func runIo() {
        while true {
            lock.lock()
            let task = ioQueue.isEmpty ? nil : ioQueue.removeFirst()
            lock.unlock()
            guard let task = task else { break }
            task()
        }
    }

    var pendingTimers: Int {
        lock.lock(); defer { lock.unlock() }
        return timers.filter { !$0.cancelled }.count
    }
}

// MARK: - OTLP read back

/// An `ExportMetricsServiceRequest` read back from protobuf with a reader
/// of its own, so the assertions do not lean on the encoder's types.
struct DecodedRequest {
    var resources: [DecodedResourceMetrics] = []
}

struct DecodedResourceMetrics {
    var attributes: [String: MetricAttribute] = [:]
    var scopes: [DecodedScope] = []
}

struct DecodedScope {
    var name = ""
    var version = ""
    var metrics: [DecodedMetric] = []
}

struct DecodedMetric {
    var name = ""
    var unit = ""
    /// `sum` or `exponentialHistogram`; anything else is `other`.
    var kind = "other"
    var temporality = 0
    var monotonic = false
    var sumPoints: [NumberPoint] = []
    var histogramPoints: [ExpPoint] = []
}

struct NumberPoint {
    var attributes: [String: MetricAttribute] = [:]
    var startNanos: UInt64 = 0
    var timeNanos: UInt64 = 0
    var value: Double = 0
}

struct ExpPoint {
    var attributes: [String: MetricAttribute] = [:]
    var startNanos: UInt64 = 0
    var timeNanos: UInt64 = 0
    var count: UInt64 = 0
    var sum: Double = 0
    var scale: Int32 = 0
    var zeroCount: UInt64 = 0
    var offset: Int32 = 0
    var bucketCounts: [UInt64] = []
    var min: Double?
    var max: Double?
    var exemplars: [DecodedExemplar] = []
}

struct DecodedExemplar {
    var filteredAttributes: [String: MetricAttribute] = [:]
    var timeNanos: UInt64 = 0
    var value: Double = 0
}

let temporalityDelta = 1

struct WireError: Error {}

/// Reads protobuf wire format; enough to walk an OTLP metrics request.
struct WireReader {
    private let bytes: [UInt8]
    private var position = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var hasMore: Bool { position < bytes.count }

    mutating func varint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while shift < 64 {
            guard position < bytes.count else { throw WireError() }
            let b = bytes[position]
            position += 1
            result |= UInt64(b & 0x7f) << shift
            if b & 0x80 == 0 { return result }
            shift += 7
        }
        throw WireError()
    }

    mutating func tag() throws -> (field: Int, wire: Int) {
        let key = try varint()
        return (Int(key >> 3), Int(key & 7))
    }

    mutating func fixed64() throws -> UInt64 {
        guard position + 8 <= bytes.count else { throw WireError() }
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(bytes[position + i]) << (8 * UInt64(i)) }
        position += 8
        return v
    }

    mutating func double() throws -> Double { Double(bitPattern: try fixed64()) }

    mutating func signed32() throws -> Int32 {
        let v = try varint()
        return Int32(truncatingIfNeeded: Int64(bitPattern: (v >> 1) ^ (0 &- (v & 1))))
    }

    mutating func length() throws -> [UInt8] {
        let n = Int(try varint())
        guard n >= 0, position + n <= bytes.count else { throw WireError() }
        defer { position += n }
        return Array(bytes[position..<(position + n)])
    }

    mutating func string() throws -> String { String(decoding: try length(), as: UTF8.self) }

    mutating func skip(_ wire: Int) throws {
        switch wire {
        case 0: _ = try varint()
        case 1: _ = try fixed64()
        case 2: _ = try length()
        case 5:
            guard position + 4 <= bytes.count else { throw WireError() }
            position += 4
        default: throw WireError()
        }
    }

    /// Calls `each` per field; it reads the value and returns true, or
    /// returns false to have it skipped.
    static func fields(_ bytes: [UInt8], _ each: (Int, inout WireReader) throws -> Bool) throws {
        var reader = WireReader(bytes)
        while reader.hasMore {
            let tag = try reader.tag()
            if try !each(tag.field, &reader) { try reader.skip(tag.wire) }
        }
    }
}

enum OtlpDecoder {
    static func request(_ body: Data) throws -> DecodedRequest {
        var out = DecodedRequest()
        try WireReader.fields([UInt8](body)) { field, r in
            guard field == 1 else { return false }
            out.resources.append(try resourceMetrics(try r.length()))
            return true
        }
        return out
    }

    private static func attributes(_ bytes: [UInt8], into out: inout [String: MetricAttribute]) throws {
        var key = ""
        var value: MetricAttribute = .string("")
        try WireReader.fields(bytes) { field, r in
            switch field {
            case 1: key = try r.string()
            case 2: value = try anyValue(try r.length())
            default: return false
            }
            return true
        }
        out[key] = value
    }

    private static func anyValue(_ bytes: [UInt8]) throws -> MetricAttribute {
        var value: MetricAttribute = .string("")
        try WireReader.fields(bytes) { field, r in
            switch field {
            case 1: value = .string(try r.string())
            case 2: value = .bool(try r.varint() != 0)
            case 3: value = .int(Int64(bitPattern: try r.varint()))
            case 4: value = .double(try r.double())
            default: return false
            }
            return true
        }
        return value
    }

    private static func resourceMetrics(_ bytes: [UInt8]) throws -> DecodedResourceMetrics {
        var out = DecodedResourceMetrics()
        try WireReader.fields(bytes) { field, r in
            switch field {
            case 1:
                try WireReader.fields(try r.length()) { f, rr in
                    guard f == 1 else { return false }
                    try attributes(try rr.length(), into: &out.attributes)
                    return true
                }
            case 2:
                out.scopes.append(try scopeMetrics(try r.length()))
            default: return false
            }
            return true
        }
        return out
    }

    private static func scopeMetrics(_ bytes: [UInt8]) throws -> DecodedScope {
        var out = DecodedScope()
        try WireReader.fields(bytes) { field, r in
            switch field {
            case 1:
                try WireReader.fields(try r.length()) { f, rr in
                    switch f {
                    case 1: out.name = try rr.string()
                    case 2: out.version = try rr.string()
                    default: return false
                    }
                    return true
                }
            case 2: out.metrics.append(try metric(try r.length()))
            default: return false
            }
            return true
        }
        return out
    }

    private static func metric(_ bytes: [UInt8]) throws -> DecodedMetric {
        var out = DecodedMetric()
        try WireReader.fields(bytes) { field, r in
            switch field {
            case 1: out.name = try r.string()
            case 3: out.unit = try r.string()
            case 7:
                out.kind = "sum"
                try WireReader.fields(try r.length()) { f, rr in
                    switch f {
                    case 1: out.sumPoints.append(try numberPoint(try rr.length()))
                    case 2: out.temporality = Int(try rr.varint())
                    case 3: out.monotonic = try rr.varint() != 0
                    default: return false
                    }
                    return true
                }
            case 10:
                out.kind = "exponentialHistogram"
                try WireReader.fields(try r.length()) { f, rr in
                    switch f {
                    case 1: out.histogramPoints.append(try expPoint(try rr.length()))
                    case 2: out.temporality = Int(try rr.varint())
                    default: return false
                    }
                    return true
                }
            default: return false
            }
            return true
        }
        return out
    }

    private static func numberPoint(_ bytes: [UInt8]) throws -> NumberPoint {
        var out = NumberPoint()
        try WireReader.fields(bytes) { field, r in
            switch field {
            case 2: out.startNanos = try r.fixed64()
            case 3: out.timeNanos = try r.fixed64()
            case 4: out.value = try r.double()
            case 7: try attributes(try r.length(), into: &out.attributes)
            default: return false
            }
            return true
        }
        return out
    }

    private static func expPoint(_ bytes: [UInt8]) throws -> ExpPoint {
        var out = ExpPoint()
        try WireReader.fields(bytes) { field, r in
            switch field {
            case 1: try attributes(try r.length(), into: &out.attributes)
            case 2: out.startNanos = try r.fixed64()
            case 3: out.timeNanos = try r.fixed64()
            case 4: out.count = try r.fixed64()
            case 5: out.sum = try r.double()
            case 6: out.scale = try r.signed32()
            case 7: out.zeroCount = try r.fixed64()
            case 8:
                try WireReader.fields(try r.length()) { f, rr in
                    switch f {
                    case 1: out.offset = try rr.signed32()
                    case 2:
                        var packed = WireReader(try rr.length())
                        while packed.hasMore { out.bucketCounts.append(try packed.varint()) }
                    default: return false
                    }
                    return true
                }
            case 11: out.exemplars.append(try exemplar(try r.length()))
            case 12: out.min = try r.double()
            case 13: out.max = try r.double()
            default: return false
            }
            return true
        }
        return out
    }

    private static func exemplar(_ bytes: [UInt8]) throws -> DecodedExemplar {
        var out = DecodedExemplar()
        try WireReader.fields(bytes) { field, r in
            switch field {
            case 2: out.timeNanos = try r.fixed64()
            case 3: out.value = try r.double()
            case 7: try attributes(try r.length(), into: &out.filteredAttributes)
            default: return false
            }
            return true
        }
        return out
    }
}

/// Every point of a set of payloads, with histograms by
/// `name|dim=value,...` and counter sums by the same key, as the Android
/// and Flutter tests read them.
struct Decoded {
    let requests: [DecodedRequest]

    init(_ bodies: [Data]) {
        requests = bodies.map { (try? OtlpDecoder.request($0)) ?? DecodedRequest() }
    }

    private static func key(_ name: String, _ attributes: [String: MetricAttribute]) -> String {
        let dims = attributes.map { "\($0.key)=\(Decoded.text($0.value))" }.sorted()
        return dims.isEmpty ? name : "\(name)|\(dims.joined(separator: ","))"
    }

    static func text(_ value: MetricAttribute) -> String {
        switch value {
        case .string(let v): return v
        case .int(let v): return "\(v)"
        case .double(let v): return "\(v)"
        case .bool(let v): return "\(v)"
        }
    }

    func resource(_ index: Int = 0) -> [String: MetricAttribute] {
        requests[index].resources.first?.attributes ?? [:]
    }

    var metrics: [DecodedMetric] {
        requests.flatMap { $0.resources.flatMap { $0.scopes.flatMap { $0.metrics } } }
    }

    var sums: [String: Double] {
        var out: [String: Double] = [:]
        for metric in metrics where metric.kind == "sum" {
            XCTAssertEqual(metric.temporality, temporalityDelta)
            XCTAssertTrue(metric.monotonic)
            for point in metric.sumPoints { out[Decoded.key(metric.name, point.attributes), default: 0] += point.value }
        }
        return out
    }

    var histograms: [String: ExpPoint] {
        var out: [String: ExpPoint] = [:]
        for metric in metrics where metric.kind == "exponentialHistogram" {
            XCTAssertEqual(metric.temporality, temporalityDelta)
            for point in metric.histogramPoints { out[Decoded.key(metric.name, point.attributes)] = point }
        }
        return out
    }
}

// MARK: - Recorder harness

/// A recorder with its payloads, store, scheduler and settings.
final class Recorded {
    let recorder: MetricsRecorder
    let bodies: Locked<[Data]>
    let store: StateStore
    let scheduler: ManualMetricsScheduler
    let control: ControlState
    let directory: URL?

    init(recorder: MetricsRecorder, bodies: Locked<[Data]>, store: StateStore,
         scheduler: ManualMetricsScheduler, control: ControlState, directory: URL?) {
        self.recorder = recorder
        self.bodies = bodies
        self.store = store
        self.scheduler = scheduler
        self.control = control
        self.directory = directory
    }

    var decoded: Decoded { Decoded(bodies.value) }

    /// Applies a remote document and hands the result to the recorder.
    func apply(_ overlay: [String: JSON]) {
        control.applyRemote(overlay)
        recorder.configure(control.settings.activeMetrics, flushSeconds: control.settings.metrics.flushSeconds)
    }
}

/// A session id whose hash falls under `rate`, or above it.
func sessionFor(rate: Double, sampled: Bool) -> String {
    var i = 0
    while true {
        let id = "session-\(i)"
        if (Ids.unitHash(id) < rate) == sampled { return id }
        i += 1
    }
}

func settingsDocument(_ overlay: [String: JSON]) -> [String: JSON] {
    (try? parseSettingsDocument(JSON.object(overlay).encoded())) ?? [:]
}

func makeRecorder(
    overlay: [String: JSON]? = nil,
    session: @escaping () -> String? = { "session-a" },
    persistent: Bool = false,
    statuses: [Int] = [],
    scheduler: ManualMetricsScheduler = ManualMetricsScheduler(),
    deferUntilStart: Bool = false,
    onSend: @escaping (Data) -> Void = { _ in }
) -> Recorded {
    let control = ControlState(defaults: defaultSettings(), ceilings: ceilingsFrom())
    if let overlay = overlay { control.applyRemote(settingsDocument(overlay)) }
    let bodies = Locked<[Data]>([])
    let queue = Locked(statuses)
    let directory = persistent ? temporaryDirectory() : nil
    let store = StateStore(directory: directory)
    let recorder = MetricsRecorder(
        settings: control.settings.activeMetrics,
        sessionId: session,
        installationId: { "install-1" },
        resource: {
            [
                "service.name": "shop",
                "service.version": "1.2.3",
                "service.instance.id": "must-not-be-sent",
                "os.name": "ios",
                "os.major": "18",
                "device.form_factor": "phone",
                "device.model": "must-not-be-sent",
            ]
        },
        send: { body in
            onSend(body)
            bodies.withValue { $0.append(body) }
            return queue.withValue { $0.isEmpty ? 200 : $0.removeFirst() }
        },
        store: { store },
        scheduler: scheduler,
        scopeName: "traceway-ios",
        scopeVersion: "test",
        deferUntilStart: deferUntilStart
    )
    return Recorded(recorder: recorder, bodies: bodies, store: store, scheduler: scheduler,
                    control: control, directory: directory)
}
