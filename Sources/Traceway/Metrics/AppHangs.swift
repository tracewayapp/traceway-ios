import Foundation

/// A main-thread hang for an `AppHang` issue.
struct AppHangReport {
    /// How long the main thread was blocked; for a fatal hang, as long as
    /// it was seen blocked before the process died.
    var blockedMs: Int64
    /// Unix ms when the watchdog first found the main thread blocked.
    var startedAtMs: Int64
    /// The wire trace's lines after its header (`*** …`, `os:`, the
    /// frames), rendered when the stack was taken, against that run's
    /// binary images.
    var traceBody: String
    /// Where the app was when it hung: the screen context, the session.
    var attributes: [String: String]
    /// What described the run that hung (its app and OS version), for a
    /// hang reported by the next run.
    var resource: [String: String]
    /// The process ended during the hang; reported by the next run.
    var fatal: Bool

    static let type = "AppHang"

    /// `Main thread blocked for 3.2 s`; a fatal hang lasted `at least` as
    /// long as it was seen. The dashboard reads the duration from it.
    static func message(blockedMs: Int64, fatal: Bool = false) -> String {
        let seconds = String(format: "%.1f", Double(max(0, blockedMs)) / 1000)
        return "Main thread blocked for \(fatal ? "at least " : "")\(seconds) s"
    }

    var message: String { AppHangReport.message(blockedMs: blockedMs, fatal: fatal) }

    var stackTrace: String { "\(AppHangReport.type): \(message)" + traceBody }

    func encoded() -> JSON {
        [
            "v": 1,
            "blockedMs": JSON(blockedMs),
            "startedAtMs": JSON(startedAtMs),
            "trace": .string(traceBody),
            "attributes": .object(attributes.mapValues { .string($0) }),
            "resource": .object(resource.mapValues { .string($0) }),
        ]
    }

    static func decode(_ json: JSON) -> AppHangReport? {
        guard let object = json.object, object["v"]?.int == 1,
              let trace = object["trace"]?.string, let blocked = object["blockedMs"]?.int,
              let started = object["startedAtMs"]?.int
        else { return nil }
        func strings(_ key: String) -> [String: String] {
            var out: [String: String] = [:]
            for (name, value) in object[key]?.object ?? [:] { if let text = value.string { out[name] = text } }
            return out
        }
        return AppHangReport(
            blockedMs: Int64(blocked), startedAtMs: Int64(started), traceBody: trace,
            attributes: strings("attributes"), resource: strings("resource"), fatal: true
        )
    }
}

/// Turns the watchdog's stalls into `AppHang` issues. When a probe has
/// waited `thresholdMs`, `stalled` takes the main thread's stack on the
/// watchdog's thread (the main thread is still blocked) and writes the hang
/// to disk; while the block goes on, its duration on disk follows. When the
/// probe runs, `recovered` removes the file and reports the hang. A hang
/// whose process died is still on disk at the next start: `takeFatal`
/// returns it, reported with `app.hang.fatal = true`. File writes and
/// reports run on a queue of their own, never on the main thread.
final class AppHangMonitor {
    let thresholdMs: Int64
    private let captureStack: () -> [UInt]?
    /// The wire trace's lines after its header for these addresses.
    private let render: ([UInt]) -> String
    /// Attributes and resource of the hang, read when its stack is taken.
    private let context: () -> (attributes: [String: String], resource: [String: String])
    private let nowMs: () -> Int64
    private let report: (AppHangReport) -> Void
    private let queue = DispatchQueue(label: "app.traceway.hangs", qos: .utility)

    private let lock = NSLock()
    // Under `lock`.
    private var file: URL?
    private var current: (id: Int, hang: AppHangReport)?
    private var lastWriteMs: Int64 = 0

    init(
        thresholdMs: Int64,
        captureStack: @escaping () -> [UInt]?,
        render: @escaping ([UInt]) -> String,
        context: @escaping () -> (attributes: [String: String], resource: [String: String]),
        nowMs: @escaping () -> Int64 = Clock.nowMs,
        report: @escaping (AppHangReport) -> Void
    ) {
        self.thresholdMs = thresholdMs
        self.captureStack = captureStack
        self.render = render
        self.context = context
        self.nowMs = nowMs
        self.report = report
    }

    static let fileName = "app_hang.json"

    /// Where a hang under way is kept; nil keeps it in memory only.
    func setDirectory(_ directory: URL?) {
        lock.lock()
        file = directory?.appendingPathComponent(AppHangMonitor.fileName)
        lock.unlock()
    }

    /// The watchdog's probe `id` has waited `waitedMs`; on the watchdog's
    /// thread, the main thread still blocked.
    func stalled(id: Int, waitedMs: Int64) {
        lock.lock()
        let known = current?.id == id
        lock.unlock()
        if known {
            lock.lock()
            defer { lock.unlock() }
            guard var hang = current, hang.id == id else { return }
            hang.hang.blockedMs = waitedMs
            current = hang
            // The duration on disk follows the block, about once a second.
            let now = nowMs()
            guard now - lastWriteMs >= 1000 else { return }
            lastWriteMs = now
            persistLocked(hang.hang)
            return
        }
        guard let stack = guarded("hang stack", fallback: nil, { captureStack() }), !stack.isEmpty else { return }
        let body = render(stack)
        let described = context()
        let hang = AppHangReport(
            blockedMs: waitedMs, startedAtMs: nowMs() - waitedMs, traceBody: body,
            attributes: described.attributes, resource: described.resource, fatal: false
        )
        lock.lock()
        defer { lock.unlock() }
        current = (id, hang)
        lastWriteMs = nowMs()
        persistLocked(hang)
    }

    /// Probe `id` ran after `blockedMs`; on the main thread.
    func recovered(id: Int, blockedMs: Int64) {
        lock.lock()
        defer { lock.unlock() }
        guard var ended = current?.hang, current?.id == id else { return }
        current = nil
        ended.blockedMs = blockedMs
        let hang = ended
        let target = file
        let report = self.report
        // Enqueued under the lock: after every write of this hang.
        queue.async {
            if let target = target { try? FileManager.default.removeItem(at: target) }
            guarded("hang report") { report(hang) }
        }
    }

    /// Forgets a hang under way (the SDK stopped): it is not reported, now
    /// or at the next start.
    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        current = nil
        let target = file
        queue.async {
            if let target = target { try? FileManager.default.removeItem(at: target) }
        }
    }

    /// Waits for the writes and reports queued so far (tests).
    func settle() {
        queue.sync {}
    }

    /// Under `lock`: queued in the order the hang changed.
    private func persistLocked(_ hang: AppHangReport) {
        guard let target = file else { return }
        queue.async {
            let data = hang.encoded().encodedData()
            try? FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try? data.write(to: target, options: .atomic)
        }
    }

    /// The hang a process that died during it left in `directory`; the
    /// file is removed first, so a bad one never comes back.
    static func takeFatal(directory: URL?) -> AppHangReport? {
        guard let target = directory?.appendingPathComponent(fileName),
              FileManager.default.fileExists(atPath: target.path)
        else { return nil }
        let data = try? Data(contentsOf: target)
        try? FileManager.default.removeItem(at: target)
        guard let data = data, let json = try? JSON.parse(data) else { return nil }
        return AppHangReport.decode(json)
    }
}
