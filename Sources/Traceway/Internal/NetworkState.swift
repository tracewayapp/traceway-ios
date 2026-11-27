import Foundation
#if canImport(Network)
import Network
#endif

/// Whether the device is on an unmetered connection, for the `wifi` replay
/// images policy. On Apple platforms an `NWPathMonitor` follows the path:
/// unmetered is a satisfied path that is neither expensive (cellular, a
/// personal hotspot) nor constrained (Low Data Mode). Until the first path
/// arrives, and where there is no Network framework, the connection counts
/// as metered. Monitoring starts the first time `shared` is used.
/// Thread-safe.
final class NetworkState {
    static let shared = NetworkState()

    private let lock = NSLock()
    private var unmetered = false
    #if canImport(Network)
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "app.traceway.network", qos: .utility)
    #endif

    private init() {
        #if canImport(Network)
        monitor.pathUpdateHandler = { [weak self] path in
            self?.set(NetworkState.isUnmetered(
                satisfied: path.status == .satisfied,
                expensive: path.isExpensive,
                constrained: path.isConstrained
            ))
        }
        monitor.start(queue: queue)
        #endif
    }

    var isUnmetered: Bool {
        lock.lock(); defer { lock.unlock() }
        return unmetered
    }

    private func set(_ value: Bool) {
        lock.lock()
        unmetered = value
        lock.unlock()
    }

    static func isUnmetered(satisfied: Bool, expensive: Bool, constrained: Bool) -> Bool {
        satisfied && !expensive && !constrained
    }
}
