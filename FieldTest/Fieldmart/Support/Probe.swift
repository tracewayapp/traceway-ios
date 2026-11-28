import Darwin
import Foundation
import QuartzCore
import UIKit
import FieldmartCore

/// The in-app measurement probe of `03-MEASUREMENT.md` §3.4, compiled into
/// every build so its own cost cancels out. Once a second, on a
/// utility-priority queue, it reads the process CPU time (`getrusage`), the
/// main thread's CPU time (`thread_info`), the thread count (`task_threads`)
/// and `phys_footprint` (`task_info(TASK_VM_INFO)`); a `CADisplayLink`
/// collects the intervals between frames. One JSON line per second goes to
/// `Documents/fm-probe/<run>.jsonl`; every line is written straight away, so
/// a kill loses at most the last second.
final class Probe: NSObject {
    private let queue = DispatchQueue(label: "com.tracewayapp.fieldmart.probe", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var displayLink: CADisplayLink?
    private var lastFrameTimestamp: CFTimeInterval = 0
    private let framesLock = NSLock()
    private var pendingFrames: [Int] = []
    private var handle: FileHandle?
    private var mainThread: thread_act_t = 0
    private var startEpochMs: Int64 = 0

    /// Starts sampling; call on the main thread.
    func start(settings: LaunchSettings, build: String, processStartEpochMs: Int64?) {
        guard timer == nil else { return }
        mainThread = mach_thread_self()
        startEpochMs = FMClock.nowMs()
        if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let url = documents.appendingPathComponent("fm-probe", isDirectory: true)
                .appendingPathComponent(settings.run + ".jsonl")
            handle = MarkerWriter.open(url)
        }
        let header = ProbeHeader(
            run: settings.run, variant: settings.variant, scenario: settings.scenario ?? "none", build: build,
            startEpochMs: startEpochMs, processStartEpochMs: processStartEpochMs,
            maxFramesPerSecond: UIScreen.main.maximumFramesPerSecond
        )
        write(header.jsonLine)

        let link = CADisplayLink(target: DisplayLinkProxy(self), selector: #selector(DisplayLinkProxy.tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link

        let source = DispatchSource.makeTimerSource(queue: queue)
        // The first line at once, so T0 (the first frame, later) lies between two samples.
        source.schedule(deadline: .now(), repeating: 1, leeway: .milliseconds(5))
        source.setEventHandler { [weak self] in self?.sample() }
        source.resume()
        timer = source

        NotificationCenter.default.addObserver(
            self, selector: #selector(didEnterBackground), name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
    }

    /// The app goes to the background: write a line now.
    @objc private func didEnterBackground() {
        queue.async { [weak self] in self?.sample() }
    }

    fileprivate func frame(_ link: CADisplayLink) {
        let timestamp = link.timestamp
        if lastFrameTimestamp > 0 {
            let micros = Int(((timestamp - lastFrameTimestamp) * 1_000_000).rounded())
            framesLock.lock()
            pendingFrames.append(micros)
            framesLock.unlock()
        }
        lastFrameTimestamp = timestamp
    }

    private func sample() {
        let now = FMClock.nowMs()
        framesLock.lock()
        let frames = pendingFrames
        pendingFrames.removeAll(keepingCapacity: true)
        framesLock.unlock()

        let process = Probe.processTimes()
        let main = Probe.threadTimes(mainThread)
        let memory = Probe.memory()
        let line = ProbeSample(
            t: now - startEpochMs, epochMs: now,
            cpuUserMs: process.user, cpuSysMs: process.system,
            mainUserMs: main?.user ?? 0, mainSysMs: main?.system ?? 0,
            threads: Probe.threadCount(),
            footprintKb: memory.footprint / 1024, residentKb: memory.resident / 1024,
            frames: frames
        ).jsonLine
        write(line)
    }

    private func write(_ line: String) {
        guard let handle = handle else { return }
        try? handle.write(contentsOf: Data((line + "\n").utf8))
    }

    // MARK: - Readings

    /// User and system CPU time of the whole process, in ms.
    static func processTimes() -> (user: Double, system: Double) {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return (0, 0) }
        func ms(_ value: timeval) -> Double { Double(value.tv_sec) * 1000 + Double(value.tv_usec) / 1000 }
        return (ms(usage.ru_utime), ms(usage.ru_stime))
    }

    /// User and system CPU time of one thread, in ms.
    static func threadTimes(_ thread: thread_act_t) -> (user: Double, system: Double)? {
        guard thread != 0 else { return nil }
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        func ms(_ value: time_value_t) -> Double { Double(value.seconds) * 1000 + Double(value.microseconds) / 1000 }
        return (ms(info.user_time), ms(info.system_time))
    }

    static func threadCount() -> Int {
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let threads = list else { return 0 }
        for index in 0..<Int(count) {
            mach_port_deallocate(mach_task_self_, threads[index])
        }
        let size = vm_size_t(Int(count) * MemoryLayout<thread_act_t>.stride)
        vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threads)), size)
        return Int(count)
    }

    /// `phys_footprint` and `resident_size`, in bytes.
    static func memory() -> (footprint: Int64, resident: Int64) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, 0) }
        return (Int64(info.phys_footprint), Int64(info.resident_size))
    }
}

/// Holds the probe weakly, so the display link does not keep it alive.
private final class DisplayLinkProxy: NSObject {
    weak var probe: Probe?

    init(_ probe: Probe) {
        self.probe = probe
    }

    @objc func tick(_ link: CADisplayLink) {
        probe?.frame(link)
    }
}

/// When the kernel started this process (`sysctl(KERN_PROC_PID)`), for
/// M-ST-1 measured inside the app.
enum ProcessStart {
    static func epochMs() -> Int64? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        let result = mib.withUnsafeMutableBufferPointer { buffer -> Int32 in
            sysctl(buffer.baseAddress, u_int(buffer.count), &info, &size, nil, 0)
        }
        guard result == 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        let ms = Int64(start.tv_sec) * 1000 + Int64(start.tv_usec) / 1000
        return ms > 0 ? ms : nil
    }
}
