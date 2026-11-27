import Foundation

private let defaultPendingKey = "metricsPending"
private let maxPendingPayloads = 3
private let maxPendingChars = 96 * 1024
private let maxPendingAgeMs: Int64 = 24 * 60 * 60 * 1000

struct PendingPayload {
    let id: String
    let timeMs: Int64
    /// The OTLP request as protobuf, so a resend can restamp its resource.
    let body: Data
}

/// Metrics payloads whose upload failed or did not get an answer. Small and
/// short-lived on purpose, like the other SDKs': a device that stays offline
/// loses its oldest numbers, it never builds a backlog.
///
/// Not thread-safe: `MetricsRecorder` calls it under its lock, with the
/// store it resolved before taking it.
final class PendingMetrics {
    let key: String
    private let now: () -> Int64

    init(now: @escaping () -> Int64, scope: String = "") {
        self.now = now
        key = scope.isEmpty ? defaultPendingKey : "\(defaultPendingKey):\(scope)"
    }

    private func read(_ store: StateStore) -> [[String: JSON]] {
        let oldest = now() - maxPendingAgeMs
        return (store.get(key)?.array ?? []).compactMap { item in
            guard let entry = item.object, entry["id"]?.string != nil, entry["p"]?.string != nil,
                  let t = entry["t"]?.int, Int64(t) > oldest
            else { return nil }
            return entry
        }
    }

    private func write(_ store: StateStore, _ entries: [[String: JSON]]) {
        var list = entries
        func size() -> Int { JSON.array(list.map { .object($0) }).encoded().count }
        while !list.isEmpty && (list.count > maxPendingPayloads || size() > maxPendingChars) {
            list.removeFirst()
        }
        store.set(key, list.isEmpty ? nil : .array(list.map { .object($0) }))
    }

    func add(_ store: StateStore, id: String, body: Data) {
        var list = read(store).filter { $0["id"]?.string != id }
        list.append(["id": .string(id), "t": JSON(now()), "p": .string(body.base64EncodedString())])
        write(store, list)
    }

    func remove(_ store: StateStore, id: String) {
        let list = read(store)
        if list.contains(where: { $0["id"]?.string == id }) {
            write(store, list.filter { $0["id"]?.string != id })
        }
    }

    /// Hands over everything except `skip` and forgets it: a payload gets one
    /// more attempt, never a third.
    func take(_ store: StateStore, skip: Set<String>) -> [PendingPayload] {
        let list = read(store)
        let taken = list.filter { !skip.contains($0["id"]!.string!) }
        if !taken.isEmpty { write(store, list.filter { skip.contains($0["id"]!.string!) }) }
        return taken.compactMap { entry in
            guard let body = Data(base64Encoded: entry["p"]!.string!) else { return nil }
            return PendingPayload(id: entry["id"]!.string!, timeMs: Int64(entry["t"]?.int ?? 0), body: body)
        }
    }
}
