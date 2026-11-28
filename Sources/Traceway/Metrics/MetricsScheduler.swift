import Foundation

/// A timer or task that can be called off.
protocol MetricsCancellable: AnyObject {
    func cancel()
}

extension DispatchWorkItem: MetricsCancellable {}

/// The clock, timers and upload thread of the metrics pipeline, so tests
/// can drive them by hand.
protocol MetricsScheduler: AnyObject {
    /// Unix milliseconds.
    func now() -> Int64
    /// Runs `task` once after `delayMs`, on a background queue.
    func schedule(afterMs delayMs: Int64, _ task: @escaping () -> Void) -> MetricsCancellable
    /// Runs `task` on the queue blocking uploads go to.
    func io(_ task: @escaping () -> Void)
}

/// Timers on a utility queue and uploads on a serial queue of their own, so
/// a slow network never holds up the client's queue or the main thread.
final class DispatchMetricsScheduler: MetricsScheduler {
    private let timers = DispatchQueue(label: "app.traceway.metrics.timers", qos: .utility)
    private let uploads = DispatchQueue(label: "app.traceway.metrics.uploads", qos: .utility)

    func now() -> Int64 { Clock.nowMs() }

    func schedule(afterMs delayMs: Int64, _ task: @escaping () -> Void) -> MetricsCancellable {
        let work = DispatchWorkItem(block: task)
        timers.asyncAfter(deadline: .now() + .milliseconds(Int(max(0, delayMs))), execute: work)
        return work
    }

    func io(_ task: @escaping () -> Void) {
        uploads.async(execute: task)
    }
}

/// A value read and written from several threads.
final class Locked<Value> {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get {
            lock.lock(); defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }

    /// Reads and changes the value in one step.
    func withValue<T>(_ body: (inout Value) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body(&stored)
    }
}
