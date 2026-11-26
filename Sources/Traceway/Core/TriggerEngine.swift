import Foundation

struct FiredTrigger {
    let trigger: Trigger
    /// The event that completed the trigger, e.g. the exception a clip
    /// belongs to.
    let cause: ObservedEvent
}

/// A completed prefix waiting for its next step: when it completed, and the
/// hit it started counting from.
private final class Anchor {
    let at: Int64
    var from: Int
    init(_ at: Int64, _ from: Int) {
        self.at = at
        self.from = from
    }
}

private final class StepState {
    /// Unused on the first step, which is always open. Oldest first.
    var anchors: [Anchor] = []
    /// Times of the records counted towards this step, when it needs more
    /// than one.
    var hits: [Int64] = []
    /// Hits dropped from the front of `hits`, so an anchor's `from` stays
    /// valid.
    var base = 0
}

private final class TriggerState {
    let signature: String
    var steps: [StepState]
    /// Per step, the event types (`click`, `hover`, ...) its matcher names.
    let kinds: [Set<String>]
    var fires: Int
    var lastFireMs: Int64

    init(signature: String, steps: [StepState], kinds: [Set<String>], fires: Int = 0, lastFireMs: Int64 = 0) {
        self.signature = signature
        self.steps = steps
        self.kinds = kinds
        self.fires = fires
        self.lastFireMs = lastFireMs
    }
}

private let maxAnchors = 8
private let maxHits = 1000
private let maxRestoreAgeMs: Int64 = 86_400_000

private func millis(_ seconds: Double) -> Int64 {
    Int64((seconds * 1000).rounded())
}

/// Runs the server-defined triggers against every event on the device. A
/// trigger is a sequence of steps. Every way the sequence could be under way
/// is followed at once: each step remembers when the steps before it last
/// completed, so an event that could also start the sequence over does not
/// discard the progress already made. A step that arrives later than its
/// `withinSeconds` is dropped, and the last step fires the trigger's
/// actions. Progress and fire counts are per session.
///
/// The same algorithm as the browser and Flutter SDKs, so a rule behaves the
/// same on every platform.
final class TriggerEngine {
    private let random: () -> Double
    private(set) var triggers: [Trigger] = []
    private var states: [String: TriggerState] = [:]

    /// Fires and the last fire time per trigger id in the current session.
    private var sessionLimits: [String: (fires: Int, lastFireMs: Int64)] = [:]

    /// Changes whenever progress does, so the caller can skip saving it.
    var progressVersion = 0

    /// Why a trigger that completed did not fire on the last `observe` call.
    var skipped: [String: String] = [:]

    init(random: @escaping () -> Double = { Double.random(in: 0..<1) }) {
        self.random = random
    }

    /// Returns the ids of the triggers that start without progress: new
    /// ones, and ones whose steps or actions changed.
    @discardableResult
    func setTriggers(_ triggers: [Trigger]) -> Set<String> {
        self.triggers = triggers.filter { $0.enabled != false && !$0.steps.isEmpty && !$0.actions.isEmpty }
        var next: [String: TriggerState] = [:]
        var created = Set<String>()
        for trigger in self.triggers {
            let signature = trigger.signature
            let previous = states[trigger.id]
            let limits = sessionLimits[trigger.id]
            if let previous = previous, previous.signature == signature {
                next[trigger.id] = previous
                continue
            }
            created.insert(trigger.id)
            next[trigger.id] = TriggerState(
                signature: signature,
                steps: trigger.steps.map { _ in StepState() },
                kinds: trigger.steps.map { eventKinds($0.match) },
                fires: previous?.fires ?? limits?.fires ?? 0,
                lastFireMs: previous?.lastFireMs ?? limits?.lastFireMs ?? 0
            )
        }
        states = next
        progressVersion += 1
        return created
    }

    /// The progress of every trigger under way, as JSON, to continue it
    /// after an app restart within the same session.
    func snapshotProgress() -> JSON {
        var out: [JSON] = []
        var seen = Set<String>()
        for trigger in triggers where !seen.contains(trigger.id) {
            seen.insert(trigger.id)
            guard let state = states[trigger.id],
                  state.steps.contains(where: { !$0.anchors.isEmpty || !$0.hits.isEmpty })
            else { continue }
            out.append([
                "id": .string(trigger.id),
                "v": 2,
                "signature": .string(state.signature),
                "steps": .array(state.steps.map { step in
                    [
                        "anchors": .array(step.anchors.map { anchor in
                            [JSON(anchor.at), JSON(max(0, anchor.from - step.base))]
                        }),
                        "hits": .array(step.hits.map { JSON($0) }),
                    ]
                }),
            ])
        }
        return .array(out)
    }

    /// `only` limits the restore to those trigger ids.
    func restoreProgress(_ saved: JSON?, nowMs: Int64? = nil, only: Set<String>? = nil) {
        guard let list = saved?.array else { return }
        let now = nowMs ?? Clock.nowMs()
        for item in list.prefix(20) {
            guard let object = item.object, object["v"]?.number == 2, let id = object["id"]?.string else {
                continue
            }
            if let only = only, !only.contains(id) { continue }
            let trigger = triggers.last { $0.id == id }
            guard let state = states[id], let trigger = trigger,
                  state.signature == object["signature"]?.string,
                  let steps = object["steps"]?.array, steps.count == trigger.steps.count
            else { continue }
            state.steps = trigger.steps.indices.map { k in
                restoreStep(trigger.steps[k], k, steps[k], now)
            }
            progressVersion += 1
        }
    }

    private func restoreStep(_ step: TriggerStep, _ k: Int, _ from: JSON, _ now: Int64) -> StepState {
        let restored = StepState()
        guard let object = from.object else { return restored }
        let rawHits = object["hits"]?.array
        let needed = step.count ?? 1
        if needed > 1 {
            let oldest = step.periodSeconds.map { now - millis($0) } ?? now - maxRestoreAgeMs
            let hits: [Int64] = (rawHits ?? []).compactMap { value in
                guard let n = value.number, n <= Double(now), n >= Double(oldest) else { return nil }
                return Int64(n)
            }
            restored.hits = hits.count > maxHits ? Array(hits.suffix(maxHits)) : hits
        }
        guard k > 0, let rawAnchors = object["anchors"]?.array else {
            if k > 0 { restored.hits = [] }
            return restored
        }
        let maxAge = step.withinSeconds.map(millis) ?? maxRestoreAgeMs
        let dropped = rawHits != nil && needed > 1 ? rawHits!.count - restored.hits.count : 0
        for anchor in rawAnchors.prefix(maxAnchors) {
            guard let pair = anchor.array, pair.count >= 2,
                  let at = pair[0].number, at <= Double(now), Double(now) - at <= Double(maxAge),
                  let start = pair[1].int, start >= 0
            else { continue }
            restored.anchors.append(Anchor(Int64(at), min(restored.hits.count, max(0, start - dropped))))
        }
        if restored.anchors.isEmpty { restored.hits = [] }
        return restored
    }

    func resetSession() {
        sessionLimits = [:]
        for state in states.values {
            state.steps = state.steps.map { _ in StepState() }
            state.fires = 0
            state.lastFireMs = 0
        }
        progressVersion += 1
    }

    func snapshotSessionLimits() -> JSON {
        var out: [String: JSON] = [:]
        for (id, limits) in sessionLimits {
            out[id] = ["fires": JSON(limits.fires), "lastFireMs": JSON(limits.lastFireMs)]
        }
        return .object(out)
    }

    func restoreSessionLimits(_ saved: JSON?) {
        guard let object = saved?.object else { return }
        for (id, value) in object {
            guard let fires = value["fires"]?.int, fires >= 0, let last = value["lastFireMs"]?.int else {
                continue
            }
            sessionLimits[id] = (fires, Int64(last))
            if let state = states[id] {
                state.fires = fires
                state.lastFireMs = Int64(last)
            }
        }
    }

    func observe(_ event: ObservedEvent) -> [FiredTrigger] {
        skipped.removeAll()
        var fired: [FiredTrigger] = []
        for trigger in triggers {
            guard let state = states[trigger.id] else { continue }
            if !advance(trigger, state, event) { continue }
            if !mayFire(trigger, state, event.timeMs) { continue }
            state.fires += 1
            state.lastFireMs = event.timeMs
            sessionLimits[trigger.id] = (state.fires, state.lastFireMs)
            fired.append(FiredTrigger(trigger: trigger, cause: event))
        }
        return fired
    }

    /// Feeds one record to a trigger; true when it completed the last step.
    /// Later steps are tried first, so the progress a record makes on one
    /// step is not also counted towards the next one.
    private func advance(_ trigger: Trigger, _ state: TriggerState, _ event: ObservedEvent) -> Bool {
        let last = trigger.steps.count - 1
        let now = event.timeMs
        var completed = false
        var k = last
        while k >= 1 && !completed {
            defer { k -= 1 }
            let step = trigger.steps[k]
            let at = state.steps[k]
            if at.anchors.isEmpty { continue }
            if let within = step.withinSeconds, within > 0 {
                let oldest = now - millis(within)
                if at.anchors[0].at < oldest {
                    at.anchors = at.anchors.filter { $0.at >= oldest }
                    if at.anchors.isEmpty { at.hits = [] }
                    progressVersion += 1
                    if at.anchors.isEmpty { continue }
                }
            }
            if !stepMatches(step, state.kinds[k], event) { continue }
            progressVersion += 1
            let needed = step.count ?? 1
            if needed > 1 {
                countHit(at, step, now)
                let counted = at.base + at.hits.count - max(at.anchors[0].from, at.base)
                if counted < needed { continue }
                at.anchors.removeFirst()
                if at.anchors.isEmpty { at.hits = [] }
            } else {
                at.anchors = []
            }
            if k == last {
                completed = true
            } else {
                open(state.steps[k + 1], trigger.steps[k + 1], now)
            }
        }
        if !completed {
            let step = trigger.steps[0]
            if !stepMatches(step, state.kinds[0], event) { return false }
            let first = state.steps[0]
            let needed = step.count ?? 1
            if needed > 1 {
                progressVersion += 1
                countHit(first, step, now)
                if first.hits.count < needed { return false }
                first.hits = []
                first.base = 0
            }
            if last == 0 {
                completed = true
            } else {
                progressVersion += 1
                open(state.steps[1], trigger.steps[1], now)
            }
        }
        if !completed { return false }
        if last > 0 {
            state.steps = state.steps.map { _ in StepState() }
            progressVersion += 1
        }
        return true
    }

    private func mayFire(_ trigger: Trigger, _ state: TriggerState, _ nowMs: Int64) -> Bool {
        if let maxPerSession = trigger.maxPerSession, state.fires >= maxPerSession {
            skipped[trigger.id] = "session_clip_limit"
            return false
        }
        if let cooldown = trigger.cooldownSeconds, cooldown > 0, state.fires > 0,
           Double(nowMs - state.lastFireMs) < cooldown * 1000
        {
            skipped[trigger.id] = "cooldown"
            return false
        }
        let sampleRate = trigger.sampleRate ?? 1
        let accepted = sampleRate >= 1 || random() < sampleRate
        if !accepted { skipped[trigger.id] = "sampled_out" }
        return accepted
    }
}

private func countHit(_ at: StepState, _ step: TriggerStep, _ now: Int64) {
    at.hits.append(now)
    var drop = max(0, at.hits.count - maxHits)
    if let period = step.periodSeconds, period > 0 {
        let cutoff = now - millis(period)
        while drop < at.hits.count && at.hits[drop] < cutoff { drop += 1 }
    }
    if drop > 0 {
        at.hits.removeFirst(drop)
        at.base += drop
    }
}

/// Records that the steps before this one just completed.
private func open(_ at: StepState, _ step: TriggerStep, _ now: Int64) {
    if (step.count ?? 1) <= 1 {
        at.anchors = [Anchor(now, 0)]
        return
    }
    let anchor = Anchor(now, at.base + at.hits.count)
    if at.anchors.count >= maxAnchors {
        at.anchors[maxAnchors - 1] = anchor
    } else {
        at.anchors.append(anchor)
    }
}

private func stepMatches(_ step: TriggerStep, _ kinds: Set<String>, _ event: ObservedEvent) -> Bool {
    if let sequence = event.sequence, !kinds.contains(sequence) { return false }
    return matches(step.match, event)
}

/// The event types (`click`, `hover`, `navigation`, `log`) a matcher names.
func eventKinds(_ matcher: Matcher) -> Set<String> {
    var out = Set<String>()
    collectEventKinds(matcher, into: &out)
    return out
}

private func collectEventKinds(_ matcher: Matcher, into out: inout Set<String>) {
    switch matcher {
    case .event(let e): out.insert(e.type)
    case .all(let items), .any(let items): for item in items { collectEventKinds(item, into: &out) }
    case .not(let inner): collectEventKinds(inner, into: &out)
    case .condition: break
    }
}
