import Foundation

struct BufferEntry<T> {
    var timeMs: Int64
    var signal: String
    var bytes: Int
    var item: T
}

/// Telemetry held on the device until a trigger or capture asks for it.
/// Bounded by total size and by age; the oldest entries go first.
///
/// Not thread-safe; the client serializes calls on its queue.
final class RingBuffer<T> {
    private var maxBytes: Int
    private var maxAgeMs: Int64
    private let now: () -> Int64
    private var entries: [BufferEntry<T>] = []
    private(set) var totalBytes = 0
    private(set) var evictedCount = 0

    init(maxBytes: Int, maxAgeMs: Int64, now: @escaping () -> Int64 = Clock.nowMs) {
        self.maxBytes = maxBytes
        self.maxAgeMs = maxAgeMs
        self.now = now
    }

    var count: Int { entries.count }

    func configure(maxBytes: Int, maxAgeMs: Int64) {
        self.maxBytes = maxBytes
        self.maxAgeMs = maxAgeMs
        trim()
    }

    func push(_ entry: BufferEntry<T>) {
        entries.append(entry)
        totalBytes += entry.bytes
        trim()
    }

    /// Removes and returns the entries inside the window whose signal is
    /// selected, oldest first. `signals == nil` selects every signal.
    func take(sinceMs: Int64, signals: Set<String>?, untilMs: Int64? = nil) -> [BufferEntry<T>] {
        trim()
        var taken: [BufferEntry<T>] = []
        var kept: [BufferEntry<T>] = []
        for entry in entries {
            if entry.timeMs >= sinceMs
                && (untilMs.map { entry.timeMs <= $0 } ?? true)
                && (signals?.contains(entry.signal) ?? true)
            {
                taken.append(entry)
                totalBytes -= entry.bytes
            } else {
                kept.append(entry)
            }
        }
        entries = kept
        return taken
    }

    func snapshot() -> [BufferEntry<T>] {
        trim()
        return entries
    }

    func retain(_ keep: (BufferEntry<T>) -> Bool) {
        var kept: [BufferEntry<T>] = []
        var bytes = 0
        for entry in entries where keep(entry) {
            kept.append(entry)
            bytes += entry.bytes
        }
        entries = kept
        totalBytes = bytes
    }

    func clear() {
        entries = []
        totalBytes = 0
    }

    private func trim() {
        let cutoff = now() - maxAgeMs
        var drop = 0
        var bytes = totalBytes
        while drop < entries.count && (bytes > maxBytes || entries[drop].timeMs < cutoff) {
            bytes -= entries[drop].bytes
            drop += 1
        }
        if drop > 0 {
            entries.removeFirst(drop)
            totalBytes = bytes
            evictedCount += drop
        }
    }
}
