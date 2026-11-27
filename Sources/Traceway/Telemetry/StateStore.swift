import Foundation

/// Small key-value state the SDK keeps between app starts: the OpAMP
/// instance uid, the last applied remote config, the current session,
/// trigger progress. One JSON file; without a directory it lives in memory
/// only. Used on the client's queue; writes happen on a queue of their own.
final class StateStore {
    let destination: String?
    private let directory: URL?
    private var values: [String: JSON] = [:]
    private var writeScheduled = false
    /// Set when a newer client took over the file: nothing is written then.
    private var sealed = false
    private let writer = DispatchQueue(label: "app.traceway.state", qos: .utility)
    private let lock = NSLock()

    init(directory: URL?, destination: String? = nil) {
        self.directory = directory
        self.destination = destination
    }

    /// Whether values outlive this run.
    var persistent: Bool { directory != nil }

    private var file: URL? { directory?.appendingPathComponent("state.json") }

    func load() {
        guard let file = file, let data = try? Data(contentsOf: file),
              let decoded = try? JSON.parse(data).object
        else { return }
        // State saved for other destinations (another project's token) is
        // not this installation's.
        if decoded["destination"]?.string == destination {
            lock.lock()
            values = decoded
            lock.unlock()
        }
    }

    func get(_ key: String) -> JSON? {
        lock.lock(); defer { lock.unlock() }
        return values[key]
    }

    func set(_ key: String, _ value: JSON?) {
        lock.lock()
        if let value = value, !value.isNull { values[key] = value } else { values.removeValue(forKey: key) }
        let schedule = !writeScheduled
        writeScheduled = true
        lock.unlock()
        if schedule {
            writer.asyncAfter(deadline: .now() + .milliseconds(250)) { self.write() }
        }
    }

    /// Stops writing the file for good: a newer client owns it now.
    func seal() {
        lock.lock()
        sealed = true
        lock.unlock()
    }

    /// Writes now; returns once the file is on disk.
    func flush() {
        writer.sync { self.write() }
    }

    private func write() {
        lock.lock()
        writeScheduled = false
        var snapshot = values
        let sealed = self.sealed
        lock.unlock()
        guard !sealed, let file = file, let directory = directory else { return }
        if let destination = destination { snapshot["destination"] = .string(destination) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSON.object(snapshot).encodedData().write(to: file, options: .atomic)
        } catch {
            // State is a convenience; losing it only costs a fresh id or config.
        }
    }
}
