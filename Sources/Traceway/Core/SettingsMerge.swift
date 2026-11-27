import Foundation

// Parses the settings document and lays it over the defaults, the same as
// the browser and Flutter SDKs do: fields this SDK does not know are
// ignored, so a newer server can add settings, and malformed values of known
// fields are skipped one by one instead of rejecting the whole document.

struct SettingsError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

private let conditionOps: Set<String> = [
    "eq", "neq", "in", "not_in", "contains", "icontains", "starts_with", "glob",
    "exists", "not_exists", "gt", "gte", "lt", "lte", "version",
]

private let maxMatcherDepth = 8
private let maxStepCount = 1000
private let maxBufferBytes: Double = 64 * 1024 * 1024
private let maxBufferAgeSeconds: Double = 24 * 60 * 60

private let eventTypes: Set<String> = ["click", "hover", "navigation", "log"]

/// A finite number clamped to [0, 1].
private func rate(_ value: JSON?) -> Double? {
    guard let n = value?.number else { return nil }
    return min(max(n, 0), 1)
}

/// A finite number above zero, at most `max`.
private func positive(_ value: JSON?, _ max: Double) -> Double? {
    guard let n = value?.number, n > 0 else { return nil }
    return n > max ? max : n
}

/// Parses the document the server sent. Throws for anything this SDK cannot
/// apply.
func parseSettingsDocument(_ body: Data) throws -> [String: JSON] {
    let parsed: JSON
    do {
        parsed = try JSON.parse(body)
    } catch {
        throw SettingsError(message: "settings document is not valid JSON")
    }
    guard let object = parsed.object else {
        throw SettingsError(message: "settings document must be a JSON object")
    }
    if let version = object["schemaVersion"], !version.isNull, version.number != 1 {
        throw SettingsError(message: "unsupported settings schemaVersion \(version.text)")
    }
    return object
}

func parseSettingsDocument(_ text: String) throws -> [String: JSON] {
    try parseSettingsDocument(Data(text.utf8))
}

private func containsUnsupportedSelectorChars(_ text: String) -> Bool {
    text.contains(":") || text.contains(",") || text.contains("\\")
}

func parseMatcher(_ value: JSON?, depth: Int = 0) -> Matcher? {
    guard let object = value?.object, depth <= maxMatcherDepth else { return nil }
    if let event = object["event"]?.object {
        let mode = event["mode"]
        guard let type = event["type"]?.string, eventTypes.contains(type),
              let text = event["value"]?.string,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf16.count <= 256
        else { return nil }
        var modeName: String?
        if let mode = mode, !mode.isNull {
            guard let name = mode.string, name == "exact" || name == "contains" else { return nil }
            modeName = name
        }
        if (type == "click" || type == "hover") && containsUnsupportedSelectorChars(text) {
            return nil
        }
        return .event(EventMatcher(type: type, value: text, mode: modeName))
    }
    if object["all"]?.array != nil || object["any"]?.array != nil {
        let isAll = object["all"]?.array != nil
        var items: [Matcher] = []
        for item in (isAll ? object["all"] : object["any"])?.array ?? [] {
            guard let parsed = parseMatcher(item, depth: depth + 1) else { return nil }
            items.append(parsed)
        }
        return isAll ? .all(items) : .any(items)
    }
    if object.keys.contains("not") {
        guard let inner = parseMatcher(object["not"], depth: depth + 1) else { return nil }
        return .not(inner)
    }
    guard let key = object["key"]?.string, !key.isEmpty else { return nil }
    guard let op = object["op"]?.string, conditionOps.contains(op) else { return nil }
    var raw = object["value"]
    if raw?.isNull == true { raw = nil }
    if let raw = raw, !raw.isScalar { return nil }
    var values: [JSON]?
    if let rawValues = object["values"], !rawValues.isNull {
        guard let list = rawValues.array, list.allSatisfy({ $0.isScalar }) else { return nil }
        values = list
    }
    return .condition(Condition(key: key, op: op, value: raw, values: values))
}

private func parseSignalSelector(_ value: JSON?) -> [String]? {
    guard let list = value?.array else { return nil }
    return list.compactMap { $0.string }.filter { $0 == "*" || signalNames.contains($0) }
}

private func parseAction(_ value: JSON?) -> TriggerAction? {
    guard let object = value?.object else { return nil }
    switch object["type"]?.string {
    case "flush":
        guard let lookback = positive(object["lookbackSeconds"], maxBufferAgeSeconds) else { return nil }
        return TriggerAction(
            type: "flush",
            lookbackSeconds: lookback,
            signals: parseSignalSelector(object["signals"]),
            replay: object["replay"]?.bool == true
        )
    case "stream":
        guard let duration = positive(object["durationSeconds"], maxBufferAgeSeconds) else { return nil }
        return TriggerAction(
            type: "stream",
            durationSeconds: duration,
            signals: parseSignalSelector(object["signals"]),
            replay: object["replay"]?.bool == true
        )
    case "startReplay":
        guard let duration = positive(object["durationSeconds"], maxBufferAgeSeconds) else { return nil }
        return TriggerAction(type: "startReplay", durationSeconds: duration)
    case "capture":
        guard let duration = positive(object["durationSeconds"], maxBufferAgeSeconds) else { return nil }
        return TriggerAction(
            type: "capture",
            lookbackSeconds: positive(object["lookbackSeconds"], maxBufferAgeSeconds),
            durationSeconds: duration,
            signals: parseSignalSelector(object["signals"]),
            replay: object["replay"]?.bool == true
        )
    case "emit":
        guard let eventName = object["eventName"]?.string, !eventName.isEmpty else { return nil }
        var attributes: [String: String] = [:]
        if let raw = object["attributes"]?.object {
            for (key, value) in raw {
                if let text = value.string { attributes[key] = text }
            }
        }
        return TriggerAction(type: "emit", eventName: eventName, attributes: attributes)
    default:
        return nil
    }
}

private func parseSteps(_ value: JSON?) -> [TriggerStep]? {
    guard let list = value?.array, !list.isEmpty else { return nil }
    var steps: [TriggerStep] = []
    for raw in list {
        guard let object = raw.object, let match = parseMatcher(object["match"]) else { return nil }
        var within: Double?
        if let w = object["withinSeconds"]?.number, w > 0 { within = w }
        var count: Int?
        var period: Double?
        if let rawCount = object["count"]?.number, rawCount == rawCount.rounded(), rawCount > 1 {
            count = rawCount > Double(maxStepCount) ? maxStepCount : Int(rawCount)
            if let rawPeriod = object["periodSeconds"]?.number, rawPeriod > 0 {
                period = rawPeriod > maxBufferAgeSeconds ? maxBufferAgeSeconds : rawPeriod
            }
        }
        steps.append(TriggerStep(match: match, withinSeconds: within, count: count, periodSeconds: period))
    }
    return steps
}

private func parseActions(_ value: JSON?) -> [TriggerAction]? {
    guard let list = value?.array, !list.isEmpty else { return nil }
    var actions: [TriggerAction] = []
    for raw in list {
        guard let action = parseAction(raw) else { return nil }
        actions.append(action)
    }
    return actions
}

private func mergeTrigger(_ base: Trigger?, _ raw: [String: JSON], id: String) -> Trigger? {
    let steps = raw.keys.contains("steps") ? parseSteps(raw["steps"]) : base?.steps
    let actions = raw.keys.contains("actions") ? parseActions(raw["actions"]) : base?.actions
    guard let steps = steps, let actions = actions else { return nil }
    var out = base ?? Trigger(id: id, steps: steps, actions: actions)
    out.steps = steps
    out.actions = actions
    if let name = raw["name"]?.string { out.name = name }
    if let enabled = raw["enabled"]?.bool { out.enabled = enabled }
    if let sampleRate = rate(raw["sampleRate"]) { out.sampleRate = sampleRate }
    if let cooldown = raw["cooldownSeconds"]?.number, cooldown >= 0 { out.cooldownSeconds = cooldown }
    if let maxPerSession = raw["maxPerSession"]?.number, maxPerSession >= 0 {
        out.maxPerSession = maxPerSession >= Double(Int.max) ? Int.max : Int(maxPerSession)
    }
    return out
}

private func parseCapture(_ value: JSON) -> Capture? {
    guard let object = value.object,
          let id = object["id"]?.string,
          let untilText = object["until"]?.string,
          let until = parseRFC3339(untilText)
    else { return nil }
    let rawLookback = object["lookbackSeconds"]
    return Capture(
        id: id,
        until: until,
        lookbackSeconds: rawLookback?.number == 0 ? 0 : positive(rawLookback, maxBufferAgeSeconds),
        signals: parseSignalSelector(object["signals"]),
        replay: object["replay"]?.bool == true
    )
}

/// Lays a remote overlay over `base`.
func applyOverlay(_ base: Settings, _ overlay: [String: JSON]) -> Settings {
    var out = base
    if let enabled = overlay["enabled"]?.bool { out.enabled = enabled }

    if let signals = overlay["signals"]?.object {
        for signal in signalNames {
            guard let raw = signals[signal]?.object else { continue }
            var target = out.signal(signal)
            if let mode = Mode(name: raw["mode"]) { target.mode = mode }
            if let sampleRate = rate(raw["sampleRate"]) { target.sampleRate = sampleRate }
            if let minSeverity = raw["minSeverity"]?.string, severityNames.contains(minSeverity) {
                target.minSeverity = minSeverity
            }
            out.signals[signal] = target
        }
    }

    if let sessions = overlay["sessions"]?.object {
        if let enabled = sessions["enabled"]?.bool { out.sessionsEnabled = enabled }
        if let baseline = rate(sessions["baselineSampleRate"]) { out.baselineSampleRate = baseline }
    }

    if let replay = overlay["replay"]?.object {
        if let mode = Mode(name: replay["mode"]) { out.replayMode = mode }
        if let sampleRate = rate(replay["sessionSampleRate"]) { out.replaySessionSampleRate = sampleRate }
        if let mask = replay["maskAllInputs"]?.bool { out.replayMaskAllInputs = mask }
        if let images = replay["images"]?.string.flatMap(TracewayImagePolicy.init(rawValue:)) {
            out.replayImages = images
        }
    }

    if let metrics = overlay["metrics"]?.object {
        if let enabled = metrics["enabled"]?.bool { out.metrics.enabled = enabled }
        if let sampleRate = rate(metrics["sampleRate"]) { out.metrics.sampleRate = sampleRate }
        if let seconds = positive(metrics["flushSeconds"], maxMetricsFlushSeconds) {
            out.metrics.flushSeconds = max(seconds, minMetricsFlushSeconds)
        }
    }

    if let buffer = overlay["buffer"]?.object {
        if let maxBytes = positive(buffer["maxBytes"], maxBufferBytes) { out.bufferMaxBytes = Int(maxBytes) }
        if let maxAge = positive(buffer["maxAgeSeconds"], maxBufferAgeSeconds) { out.bufferMaxAgeSeconds = maxAge }
        if let persist = buffer["persist"]?.bool { out.persist = persist }
    }

    if let triggers = overlay["triggers"]?.array {
        for item in triggers {
            guard let raw = item.object, let id = raw["id"]?.string, !id.isEmpty else { continue }
            let index = out.triggers.firstIndex { $0.id == id }
            guard let merged = mergeTrigger(index.map { out.triggers[$0] }, raw, id: id) else { continue }
            if let index = index {
                out.triggers[index] = merged
            } else {
                out.triggers.append(merged)
            }
        }
    }

    if let captures = overlay["captures"]?.array {
        out.captures = captures.compactMap(parseCapture)
    }

    return out
}

/// Lowers the app's ceilings to the `limits` a remote document carries: what
/// the organization's plan accepts at ingest.
func applyLimits(_ ceilings: Ceilings, _ overlay: [String: JSON]?) -> Ceilings {
    guard let limits = overlay?["limits"]?.object else { return ceilings }
    var out = ceilings
    if let limitSignals = limits["signals"]?.object {
        for signal in signalNames {
            if let mode = Mode(name: limitSignals[signal]) {
                out.signals[signal] = lowerMode(ceilings.signal(signal), mode)
            }
        }
    }
    if let replay = Mode(name: limits["replay"]) {
        out.replay = lowerMode(ceilings.replay, replay)
    }
    if limits["metrics"]?.string == "off" { out.metrics = false }
    return out
}

/// Holds every mode at or below what start allowed in this app.
func clampToCeilings(_ settings: Settings, _ ceilings: Ceilings) -> Settings {
    var out = settings
    out.enabled = out.enabled && ceilings.enabled
    for signal in signalNames {
        var target = out.signal(signal)
        target.mode = lowerMode(target.mode, ceilings.signal(signal))
        out.signals[signal] = target
    }
    out.replayMode = lowerMode(out.replayMode, ceilings.replay)
    // Without replay (no screen capture, or a plan without it) there is no
    // picture to record either.
    out.replayImages = ceilings.replay == .off ? .off : min(out.replayImages, ceilings.replayImages)
    out.sessionsEnabled = out.sessionsEnabled && ceilings.sessions
    out.metrics.enabled = out.metrics.enabled && ceilings.metrics
    return out
}

// MARK: - Dates

private let dateTimePattern = try! NSRegularExpression(
    pattern: #"^([+-]?\d{4,6})-?(\d\d)-?(\d\d)(?:[ T](\d\d)(?::?(\d\d)(?::?(\d\d)(?:[.,](\d+))?)?)?( ?[zZ]| ?([-+])(\d\d)(?::?(\d\d))?)?)?$"#
)

/// Parses a timestamp the way Dart's `DateTime.tryParse` does (the subset of
/// ISO 8601 / RFC 3339 the other SDKs accept): a date, optionally a time
/// with fractional seconds, and `Z` or an offset. Without a zone the time is
/// local.
func parseRFC3339(_ text: String) -> Date? {
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = dateTimePattern.firstMatch(in: text, options: [], range: range) else { return nil }
    func group(_ i: Int) -> String? {
        let r = match.range(at: i)
        guard r.location != NSNotFound, let swiftRange = Range(r, in: text) else { return nil }
        return String(text[swiftRange])
    }
    func int(_ i: Int) -> Int { group(i).flatMap { Int($0) } ?? 0 }
    guard let year = group(1).flatMap({ Int($0) }) else { return nil }
    var micros = 0
    if let fraction = group(7) {
        let digits = String(fraction.prefix(6))
        micros = (Int(digits) ?? 0) * Int(pow(10, Double(6 - digits.count)))
    }
    var components = DateComponents()
    components.year = year
    components.month = int(2)
    components.day = int(3)
    components.hour = int(4)
    components.minute = int(5)
    components.second = int(6)
    var calendar = Calendar(identifier: .gregorian)
    let zoned = group(8) != nil
    calendar.timeZone = zoned ? TimeZone(identifier: "UTC")! : TimeZone.current
    guard var date = calendar.date(from: components) else { return nil }
    date = date.addingTimeInterval(Double(micros) / 1_000_000)
    if let sign = group(9) {
        let offset = Double(int(10) * 3600 + int(11) * 60)
        // `+02:00` is two hours ahead of UTC: the instant is two hours earlier.
        date = date.addingTimeInterval(sign == "-" ? offset : -offset)
    }
    return date
}
