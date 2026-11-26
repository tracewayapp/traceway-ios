import Foundation

struct StreamOverride {
    /// `"*"` covers every signal that is not off; listing a signal also
    /// turns it on. Either way the result stays within the ceilings and plan
    /// limits.
    var signals: [String]
    var untilMs: Int64
    /// Streams the screen recording too, as segments, while it lasts.
    var replay = false
    /// A capture: `"*"` also brings back the signals rules switched off.
    var includeOff = false
}

/// The effective collection settings at any moment: built-in defaults (with
/// the app's local collection settings), then the remote overlay, clamped
/// to the app's ceilings, then any temporary "stream for a while" overrides
/// from triggers and captures.
///
/// Not thread-safe; the client serializes calls on its queue.
final class ControlState {
    private let defaults: Settings
    private let appCeilings: Ceilings
    private let now: () -> Int64
    private var ceilings: Ceilings
    private var effective: Settings
    private var overrides: [String: [StreamOverride]] = [:]
    private var overrideSequence = 0
    private var listeners: [(Settings) -> Void] = []

    init(defaults: Settings, ceilings: Ceilings, now: @escaping () -> Int64 = Clock.nowMs) {
        self.defaults = defaults
        self.appCeilings = ceilings
        self.now = now
        self.ceilings = ceilings
        self.effective = clampToCeilings(defaults, ceilings)
    }

    var settings: Settings { effective }

    /// Applies a parsed remote document, or `nil` to fall back to defaults.
    func applyRemote(_ overlay: [String: JSON]?) {
        ceilings = applyLimits(appCeilings, overlay)
        let merged = overlay.map { applyOverlay(defaults, $0) } ?? defaults
        effective = clampToCeilings(merged, ceilings)
        for listener in listeners {
            listener(effective)
        }
    }

    func onChange(_ listener: @escaping (Settings) -> Void) {
        listeners.append(listener)
    }

    func addOverride(_ override: StreamOverride) {
        setOverrides("stream:\(overrideSequence)", [override])
        overrideSequence += 1
    }

    func setOverrides(_ owner: String, _ overrides: [StreamOverride]) {
        if overrides.isEmpty {
            self.overrides.removeValue(forKey: owner)
        } else {
            self.overrides[owner] = overrides
        }
        _ = activeOverrides()
    }

    /// When the next override ends, so the caller can re-apply replay then.
    var nextOverrideExpiryMs: Int64? {
        activeOverrides().map(\.untilMs).min()
    }

    private func activeOverrides() -> [StreamOverride] {
        let now = self.now()
        var active: [StreamOverride] = []
        for (owner, list) in overrides {
            let kept = list.filter { $0.untilMs > now }
            if kept.isEmpty {
                overrides.removeValue(forKey: owner)
            } else {
                if kept.count != list.count { overrides[owner] = kept }
                active.append(contentsOf: kept)
            }
        }
        return active
    }

    func canExport(_ signal: String) -> Bool {
        enabled && ceilings.signal(signal) == .stream && modeFor(signal) != .off
    }

    var enabled: Bool { effective.enabled }

    func modeFor(_ signal: String) -> Mode {
        if !effective.enabled { return .off }
        let base = effective.signal(signal).mode
        if base == .stream { return base }
        for override in activeOverrides() where covers(override, signal, base) {
            return lowerMode(.stream, ceilings.signal(signal))
        }
        return base
    }

    private func covers(_ override: StreamOverride, _ signal: String, _ base: Mode) -> Bool {
        if override.signals.contains(signal) { return true }
        if !override.signals.contains("*") { return false }
        return base != .off || (override.includeOff && defaults.signal(signal).mode != .off)
    }

    var replayMode: Mode {
        if !effective.enabled { return .off }
        let base = effective.replayMode
        if base != .stream && activeOverrides().contains(where: { $0.replay }) {
            return lowerMode(.stream, ceilings.replay)
        }
        return base
    }

    func sampleRate(_ signal: String) -> Double {
        effective.signal(signal).sampleRate
    }
}
