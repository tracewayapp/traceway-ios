import Foundation
import OpenTelemetryApi
import OpenTelemetrySdk

/// A record waiting in the ring buffer or on its way to an exporter. A
/// reference, so attributes the SDK adds after routing (the replay status of
/// an exception) reach the copy in the buffer too.
final class TelemetryItem {
    enum Record {
        case log(ReadableLogRecord)
        case span(SpanData)
    }

    var record: Record

    init(_ record: Record) { self.record = record }

    var attributes: [String: AttributeValue] {
        switch record {
        case .log(let log): return log.attributes
        case .span(let span): return span.attributes
        }
    }

    func setAttribute(_ key: String, _ value: AttributeValue) {
        switch record {
        case .log(var log):
            log.setAttribute(key: key, value: value)
            record = .log(log)
        case .span(var span):
            var attributes = span.attributes
            attributes[key] = value
            span.replacingAttributes(attributes)
            record = .span(span)
        }
    }
}

enum Routed { case stream, buffer, off, filtered }

struct ObservedRecord {
    let signal: String
    let timeMs: Int64
    let lookup: FieldLookup
    let item: TelemetryItem
    /// Whether the record was sent, buffered or dropped. Triggers still see
    /// dropped records.
    let routed: Routed
}

protocol RouterHooks: AnyObject {
    var sessionId: String? { get }
    func globalAttribute(_ key: String) -> String?
    /// Adds what the SDK knows to a record; returning false drops it.
    func enrichLog(_ record: inout ReadableLogRecord, signal: String) -> Bool
    func observe(_ record: ObservedRecord)
}

/// Records per export of a buffer flush, as many as a batch processor sends.
private let flushBatchSize = 512

private let baselineSignals: Set<String> = ["network", "console", "navigation", "userActions", "custom"]

/// Decides for every log record and span whether it is sent now, kept in the
/// ring buffer or dropped, according to the `ControlState`. Triggers observe
/// records after routing, so a triggered flush includes the record that
/// caused it. Used only on the client's queue.
final class TelemetryRouter {
    let control: ControlState
    let buffer: RingBuffer<TelemetryItem>
    let logSink: LogRecordProcessor
    let spanSink: SpanBatcher
    /// The exporters behind the sinks, for buffer flushes.
    let logExporter: LogRecordExporter
    let spanExporter: SpanExporter
    weak var hooks: RouterHooks?
    /// Writes an issue (exception or message) to disk before it is sent,
    /// when there is a disk: the app may not live to see the answer. True
    /// when it was written; the outbox then sends it.
    var persistIssue: ((ReadableLogRecord) -> Bool)?
    private let random: () -> Double
    /// Where flushed batches are exported; serial, so `settle` can wait.
    let exportQueue = DispatchQueue(label: "app.traceway.flush", qos: .utility)

    init(
        control: ControlState,
        buffer: RingBuffer<TelemetryItem>,
        logSink: LogRecordProcessor,
        spanSink: SpanBatcher,
        logExporter: LogRecordExporter,
        spanExporter: SpanExporter,
        hooks: RouterHooks,
        random: @escaping () -> Double = { Double.random(in: 0..<1) }
    ) {
        self.control = control
        self.buffer = buffer
        self.logSink = logSink
        self.spanSink = spanSink
        self.logExporter = logExporter
        self.spanExporter = spanExporter
        self.hooks = hooks
        self.random = random
    }

    /// The dashboard's captures running now. Only these are stamped, as the
    /// browser SDK does: the server tracks captures by the ids it created,
    /// not by the ones triggers make up on the device.
    private func activeCaptureIds() -> [String] {
        let now = Date()
        return control.settings.captures.filter { $0.until > now }.map { $0.id }
    }

    func routeLog(_ input: ReadableLogRecord) {
        var record = input
        let signal = classifyLog(record.eventName)
        if let session = hooks?.sessionId, record.attributes[Attr.sessionId] == nil {
            record.setAttribute(key: Attr.sessionId, value: .string(session))
        }
        if signal != signalControl {
            let captures = activeCaptureIds()
            if !captures.isEmpty {
                record.setAttribute(key: Attr.captureIds, value: .string(JSON(captures).encoded()))
            }
        }
        if let hooks = hooks, !hooks.enrichLog(&record, signal: signal) { return }

        let item = TelemetryItem(.log(record))
        let timeMs = Clock.ms(record.timestamp)
        let minSeverity = control.settings.signal("console").minSeverity
        let severity = record.severity
        let routed = decide(signal, item, timeMs) {
            guard signal == "console", let minimum = minSeverity, let severity = severity else { return true }
            return severity.rawValue >= severityNumber(of: minimum)
        }
        observeAndSend(ObservedRecord(
            signal: signal, timeMs: timeMs, lookup: logLookup(item, signal), item: item, routed: routed
        ))
    }

    func routeSpan(_ input: SpanData) {
        var span = input
        var attributes = span.attributes
        let session = hooks?.sessionId
        if let session = session { attributes[Attr.sessionId] = .string(session) }
        let captures = activeCaptureIds()
        if !captures.isEmpty { attributes[Attr.captureIds] = .string(JSON(captures).encoded()) }
        let baselineRate = control.settings.baselineSampleRate
        attributes["traceway.collection.source"] = .string(
            (session.map { Ids.unitHash($0) < baselineRate } ?? false) ? "baseline" : "diagnostic"
        )
        attributes["traceway.collection.baseline_rate"] = .double(baselineRate)
        span.replacingAttributes(attributes)

        // Requests are `network`; any other span an app makes through the
        // SDK's tracer is `custom`.
        let isRequest = attributes["http.request.method"] != nil || attributes["http.method"] != nil
        let signal = isRequest ? "network" : "custom"
        let item = TelemetryItem(.span(span))
        let timeMs = Clock.ms(span.endTime)
        let routed = decide(signal, item, timeMs) { true }
        observeAndSend(ObservedRecord(
            signal: signal, timeMs: timeMs, lookup: spanLookup(item, signal), item: item, routed: routed
        ))
    }

    /// Triggers see a record before it is handed to the exporter. A buffered
    /// record is already in the buffer then, so a flush it triggers includes
    /// it; a streamed one follows the flushed breadcrumbs.
    private func observeAndSend(_ observed: ObservedRecord) {
        hooks?.observe(observed)
        if observed.routed == .stream { send(observed.item) }
    }

    /// Sends a record that was dropped when it arrived but whose signal
    /// streams now, because the trigger it fired started a capture.
    func sendIfStreaming(_ observed: ObservedRecord) {
        guard observed.routed == .off, observed.signal != signalControl else { return }
        if control.modeFor(observed.signal) == .stream { send(observed.item) }
    }

    /// Sends what the buffer holds in the window. `signals == nil` selects
    /// every signal. Returns the number of records taken. They go straight
    /// to the exporters, a batch after the other: the batch processors'
    /// queues are bounded and would drop the newest breadcrumbs of a full
    /// buffer, the ones right before the error.
    @discardableResult
    func flushBuffered(sinceMs: Int64, signals: Set<String>?, untilMs: Int64? = nil) -> Int {
        let entries = buffer.take(sinceMs: sinceMs, signals: signals, untilMs: untilMs)
        var logs: [ReadableLogRecord] = []
        var spans: [SpanData] = []
        for entry in entries where control.canExport(entry.signal) {
            switch entry.item.record {
            case .log(let record): if !persisted(record) { logs.append(record) }
            case .span(let span): spans.append(span)
            }
        }
        export(logs: logs, spans: spans)
        return entries.count
    }

    /// Exports records on the flush queue in batches.
    func export(logs: [ReadableLogRecord], spans: [SpanData]) {
        guard !logs.isEmpty || !spans.isEmpty else { return }
        let logExporter = self.logExporter
        let spanExporter = self.spanExporter
        exportQueue.async {
            var start = 0
            while start < logs.count {
                let end = min(start + flushBatchSize, logs.count)
                _ = logExporter.export(logRecords: Array(logs[start..<end]), explicitTimeout: nil)
                start = end
            }
            start = 0
            while start < spans.count {
                let end = min(start + flushBatchSize, spans.count)
                _ = spanExporter.export(spans: Array(spans[start..<end]), explicitTimeout: nil)
                start = end
            }
        }
    }

    /// Runs `completion` (on the flush queue) once every flush handed over so
    /// far has been exported.
    func settle(_ completion: @escaping () -> Void) {
        let done = Unchecked(completion)
        exportQueue.async { done.value() }
    }

    /// Decides what happens to a record; a buffered one is stored here, a
    /// streamed one is sent by the caller once triggers have seen it.
    private func decide(_ signal: String, _ item: TelemetryItem, _ timeMs: Int64, _ accept: () -> Bool) -> Routed {
        if signal == signalControl { return control.enabled ? .stream : .off }
        let mode = control.modeFor(signal)
        let sampleRate = control.sampleRate(signal)
        if !accept() || (sampleRate < 1 && random() >= sampleRate) { return .filtered }
        if mode == .off { return .off }
        let session = hooks?.sessionId
        let baselineSampled = baselineSignals.contains(signal)
            && (session.map { Ids.unitHash($0) < control.settings.baselineSampleRate } ?? false)
        if mode == .stream || baselineSampled { return .stream }
        buffer.push(BufferEntry(timeMs: timeMs, signal: signal, bytes: estimateBytes(item), item: item))
        return .buffer
    }

    private func persisted(_ record: ReadableLogRecord) -> Bool {
        (record.eventName == Events.exception || record.eventName == Events.message)
            && persistIssue?(record) == true
    }

    private func send(_ item: TelemetryItem) {
        switch item.record {
        case .log(let record): if !persisted(record) { logSink.onEmit(logRecord: record) }
        case .span(let span): spanSink.add(span)
        }
    }

    // MARK: - Lookups for triggers

    private func logLookup(_ item: TelemetryItem, _ signal: String) -> FieldLookup {
        return { [weak self] key in
            guard case .log(let record) = item.record else { return nil }
            switch key {
            case "event.name": return JSON(record.eventName)
            case "signal": return .string(signal)
            case "severity": return record.severity.map { JSON($0.rawValue) }
            case "severity.text": return record.severity.map { .string($0.description) }
            case "body":
                guard let body = record.body else { return nil }
                if case .string(let text) = body { return .string(text) }
                return .string(jsonValue(body).encoded())
            default:
                return self?.prefixed(key, record.attributes, record.resource.attributes)
            }
        }
    }

    private func spanLookup(_ item: TelemetryItem, _ signal: String) -> FieldLookup {
        return { [weak self] key in
            guard case .span(let span) = item.record else { return nil }
            switch key {
            case "signal": return .string(signal)
            case "span.name": return .string(span.name)
            case "span.kind": return .string(span.kind.rawValue)
            case "span.status":
                if span.status.isError { return "error" }
                return span.status.isOk ? "ok" : "unset"
            case "duration_ms":
                return .number(span.endTime.timeIntervalSince(span.startTime) * 1000)
            default:
                return self?.prefixed(key, span.attributes, span.resource.attributes)
            }
        }
    }

    private func prefixed(_ key: String, _ attributes: [String: AttributeValue], _ resource: [String: AttributeValue]) -> JSON? {
        if key.hasPrefix("attributes.") {
            return attributes[String(key.dropFirst("attributes.".count))].map(jsonValue)
        }
        if key.hasPrefix("resource.") {
            return resource[String(key.dropFirst("resource.".count))].map(jsonValue)
        }
        if key.hasPrefix("global.") {
            return hooks?.globalAttribute(String(key.dropFirst("global.".count))).map { .string($0) }
        }
        if key == Attr.sessionId {
            return attributes[Attr.sessionId].map(jsonValue) ?? hooks?.sessionId.map { .string($0) }
        }
        return nil
    }
}

private func estimateBytes(_ item: TelemetryItem) -> Int {
    var size = 200
    switch item.record {
    case .log(let record):
        if let body = record.body { size += 2 * body.description.utf16.count }
        for (key, value) in record.attributes {
            size += 2 * (key.utf16.count + value.description.utf16.count) + 16
        }
    case .span(let span):
        size += 2 * span.name.utf16.count
        for (key, value) in span.attributes {
            size += 2 * (key.utf16.count + value.description.utf16.count) + 16
        }
    }
    return size
}

/// An attribute value as JSON, for trigger conditions.
func jsonValue(_ value: AttributeValue) -> JSON {
    switch value {
    case .string(let v): return .string(v)
    case .bool(let v): return .bool(v)
    case .int(let v): return JSON(v)
    case .double(let v): return .number(v)
    case .array(let array): return .array(array.values.map(jsonValue))
    case .set(let set): return .object(set.labels.mapValues(jsonValue))
    default: return .string(value.description)
    }
}

/// A JSON value as an attribute value, for attributes the app passes in.
func attributeValue(_ value: JSON) -> AttributeValue {
    switch value {
    case .string(let v): return .string(v)
    case .bool(let v): return .bool(v)
    case .number(let v):
        if let int = value.int { return .int(int) }
        return .double(v)
    case .null: return .string("")
    case .array, .object: return .string(value.encoded(sortedKeys: true))
    }
}

// MARK: - Processors

/// The only log processor on the SDK's logger provider: hands every record
/// to the router, which owns the real batch processor.
final class ControlLogProcessor: LogRecordProcessor {
    private let route: (ReadableLogRecord) -> Void
    private let sink: () -> LogRecordProcessor?

    init(route: @escaping (ReadableLogRecord) -> Void, sink: @escaping () -> LogRecordProcessor?) {
        self.route = route
        self.sink = sink
    }

    func onEmit(logRecord: ReadableLogRecord) {
        route(logRecord)
    }

    func forceFlush(explicitTimeout: TimeInterval?) -> ExportResult {
        sink()?.forceFlush(explicitTimeout: explicitTimeout) ?? .success
    }

    func shutdown(explicitTimeout: TimeInterval?) -> ExportResult {
        sink()?.shutdown(explicitTimeout: explicitTimeout) ?? .success
    }
}

/// The span processor on the SDK's tracer provider: hands every ended span
/// to the router.
final class ControlSpanProcessor: SpanProcessor {
    private let route: (SpanData) -> Void

    init(route: @escaping (SpanData) -> Void) {
        self.route = route
    }

    var isStartRequired: Bool { false }
    var isEndRequired: Bool { true }

    func onStart(parentContext: SpanContext?, span: ReadableSpan) {}

    func onEnd(span: ReadableSpan) {
        route(span.toSpanData())
    }

    func shutdown(explicitTimeout: TimeInterval?) {}

    func forceFlush(timeout: TimeInterval?) {}
}

/// Batches streamed spans for their exporter: sent after `delayMs`, or at
/// once when a batch is full. Thread-safe.
final class SpanBatcher {
    private let exporter: SpanExporter
    private let delayMs: Int
    private let queue = DispatchQueue(label: "app.traceway.spans", qos: .utility)
    private let lock = NSLock()
    private var pending: [SpanData] = []
    private var scheduled = false
    static let maxQueued = 2048

    init(exporter: SpanExporter, delayMs: Int) {
        self.exporter = exporter
        self.delayMs = delayMs
    }

    func add(_ span: SpanData) {
        lock.lock()
        if pending.count < SpanBatcher.maxQueued { pending.append(span) }
        let full = pending.count >= flushBatchSize
        let schedule = !scheduled
        scheduled = true
        lock.unlock()
        if full {
            queue.async { self.exportPending() }
        } else if schedule {
            queue.asyncAfter(deadline: .now() + .milliseconds(delayMs)) { self.exportPending() }
        }
    }

    /// Exports what is pending; `completion` runs once it has been sent.
    func flush(_ completion: (() -> Void)? = nil) {
        queue.async {
            self.exportPending()
            completion?()
        }
    }

    private func exportPending() {
        while true {
            lock.lock()
            let batch = Array(pending.prefix(flushBatchSize))
            pending.removeFirst(batch.count)
            if pending.isEmpty { scheduled = false }
            lock.unlock()
            if batch.isEmpty { return }
            _ = exporter.export(spans: batch, explicitTimeout: nil)
        }
    }
}

extension SpanData {
    /// Sets the attributes and keeps the count of recorded attributes at
    /// least as high: the OTLP exporter sends the difference as the dropped
    /// count, an unsigned number, and traps when attributes were added
    /// without it.
    mutating func replacingAttributes(_ attributes: [String: AttributeValue]) {
        let dropped = max(0, totalAttributeCount - self.attributes.count)
        settingAttributes(attributes)
        settingTotalAttributeCount(attributes.count + dropped)
    }
}
