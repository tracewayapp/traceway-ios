import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// The peak memory of each session (`app.memory.peak`), observed once the
/// session is known to have ended. The app may be killed in the background,
/// so what a session used so far is kept in the state store and reported by
/// the next run when that session is over.
///
/// Thread-safe as far as the state store and the recorder are.
final class MemoryPeaks {
    private let recorder: MetricsRecorder
    private let store: () -> StateStore
    private let key: String
    private let readPeak: () -> Int64

    init(
        recorder: MetricsRecorder,
        store: @escaping () -> StateStore,
        storageScope: String = "",
        readPeak: @escaping () -> Int64 = MemoryPeaks.readPeakBytes
    ) {
        self.recorder = recorder
        self.store = store
        key = storageScope.isEmpty ? "metricsMemory" : "metricsMemory:\(storageScope)"
        self.readPeak = readPeak
    }

    /// Going to the background or shutting down: `session` may go on in a
    /// later run.
    func remember(_ session: String?) {
        guard let session = session else { return }
        let storage = store()
        let bytes = peak(storage, session)
        if bytes > 0 { storage.set(key, ["s": .string(session), "b": JSON(bytes)]) }
    }

    /// `session` ended in this run.
    func ended(_ session: String) {
        let storage = store()
        let bytes = peak(storage, session)
        storage.set(key, nil)
        recorder.memoryPeak(session: session, bytes: bytes)
    }

    /// A session started: one that ended while the app was not running is
    /// reported now.
    func settle(_ current: String) {
        let storage = store()
        guard let record = storage.get(key)?.object, let session = record["s"]?.string,
              session != current, let bytes = record["b"]?.int
        else { return }
        storage.set(key, nil)
        recorder.memoryPeak(session: session, bytes: Int64(bytes))
    }

    /// The most memory `session` used: now, or in an earlier run of the app.
    private func peak(_ storage: StateStore, _ session: String) -> Int64 {
        var remembered: Int64 = 0
        if let record = storage.get(key)?.object, record["s"]?.string == session, let bytes = record["b"]?.int {
            remembered = Int64(bytes)
        }
        return max(readPeak(), remembered)
    }

    /// The highest physical footprint of the process (`task_vm_info`'s
    /// `ledger_phys_footprint_peak`, what the system's memory limit counts;
    /// `resident_size_peak` on systems without it), in bytes. On Linux the
    /// peak resident set (`VmHWM`). 0 when unknown.
    static func readPeakBytes() -> Int64 {
        #if canImport(Darwin)
        var info = task_vm_info_data_t()
        let size = MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        var count = mach_msg_type_number_t(size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: size) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        // The fields up to the footprint peak are there from revision 3 on.
        if let offset = MemoryLayout<task_vm_info_data_t>.offset(of: \.ledger_phys_footprint_peak),
           Int(count) * MemoryLayout<natural_t>.size >= offset + MemoryLayout<Int64>.size,
           info.ledger_phys_footprint_peak > 0 {
            return info.ledger_phys_footprint_peak
        }
        return Int64(info.resident_size_peak)
        #else
        guard let status = try? String(contentsOfFile: "/proc/self/status", encoding: .utf8) else { return 0 }
        return parseVmHwmBytes(status)
        #endif
    }

    /// `VmHWM` of `/proc/self/status`, in bytes; 0 when it is not there.
    static func parseVmHwmBytes(_ status: String) -> Int64 {
        for line in status.split(separator: "\n") where line.hasPrefix("VmHWM:") {
            let value = line.dropFirst("VmHWM:".count).split(whereSeparator: { $0 == " " || $0 == "\t" }).first
            guard let kb = value.flatMap({ Int64($0) }) else { return 0 }
            return kb * 1024
        }
        return 0
    }
}
