import Foundation
#if canImport(Darwin)
import Darwin

/// The main thread's stack, taken from another thread while the main thread
/// is blocked (an `AppHang`, CONTRACT §14.2): the main thread is suspended,
/// its registers are read with `thread_get_state`, its frame records are
/// walked (at most `maxFrames`, each copied with `vm_read_overwrite` and
/// checked to lie on the main thread's stack, above the one before), and it
/// is resumed at once. Nothing is allocated and no lock the main thread may
/// hold is taken while it is suspended: it may be inside the allocator.
/// The addresses go through the binary-image symbolication of crashes.
enum MainThreadStack {
    static let maxFrames = 128

    /// Serializes captures; the main thread only takes it in `prepare`,
    /// never while it is suspended.
    private static let lock = NSLock()
    // Set once by `prepare`, on the main thread.
    private static var mainPort: mach_port_t = 0
    private static var stackLow: UInt = 0
    private static var stackHigh: UInt = 0
    // Allocated once: a capture writes here while the main thread is
    // suspended.
    private static let frames = UnsafeMutablePointer<UInt>.allocate(capacity: maxFrames)
    private static let record = UnsafeMutablePointer<UInt>.allocate(capacity: 2)
    /// The thread state `thread_get_state` fills, read at the kernel ABI's
    /// fixed offsets: no C struct's type metadata is needed while the main
    /// thread is suspended (instantiating it takes a lock).
    private static let stateWords = UnsafeMutablePointer<natural_t>.allocate(capacity: 128)

    /// Where the registers are in the thread state of this architecture
    /// (`arm_thread_state64_t`, `x86_thread_state64_t`), in bytes, and its
    /// size in 32-bit words; nil where there is none.
    struct RegisterLayout: Equatable {
        let flavor: thread_state_flavor_t
        let words: mach_msg_type_number_t
        let pc: Int
        let fp: Int
        /// The link register; nil where return addresses live on the stack.
        let lr: Int?
    }

    static let layout: RegisterLayout? = {
        #if arch(arm64)
        // x0…x28, then fp, lr, sp, pc, cpsr and a pad: 68 words.
        return RegisterLayout(flavor: thread_state_flavor_t(ARM_THREAD_STATE64), words: 68, pc: 256, fp: 232, lr: 240)
        #elseif arch(x86_64)
        // rax, rbx, rcx, rdx, rdi, rsi, rbp, rsp, r8…r15, rip, rflags, cs,
        // fs, gs: 42 words.
        return RegisterLayout(flavor: thread_state_flavor_t(x86_THREAD_STATE64), words: 42, pc: 128, fp: 48, lr: nil)
        #else
        return nil
        #endif
    }()

    /// Notes the main thread and the bounds of its stack. Call on the main
    /// thread; later calls change nothing.
    static func prepare() {
        guard Thread.isMainThread else { return }
        lock.lock()
        defer { lock.unlock() }
        guard mainPort == 0 else { return }
        let me = pthread_self()
        let high = UInt(bitPattern: pthread_get_stackaddr_np(me))
        let size = UInt(clamping: pthread_get_stacksize_np(me))
        stackHigh = high
        stackLow = high > size ? high - size : 0
        mainPort = mach_thread_self()
    }

    static var isPrepared: Bool {
        lock.lock()
        defer { lock.unlock() }
        return mainPort != 0
    }

    /// The main thread's return addresses, innermost first (the program
    /// counter, on arm64 the link register, then the frame records); nil on
    /// the main thread itself, before `prepare`, or when it cannot be read.
    static func capture() -> [UInt]? {
        guard !Thread.isMainThread else { return nil }
        lock.lock()
        defer { lock.unlock() }
        // Every static is read before the main thread stops: a first read
        // of a lazy static allocates, and the main thread may hold the
        // allocator's lock.
        let port = mainPort
        let walk = Walk(frames: frames, limit: maxFrames, record: record, state: stateWords,
                        low: stackLow, high: stackHigh)
        guard port != 0, let registers = layout, thread_suspend(port) == KERN_SUCCESS else { return nil }
        let count = walkSuspended(port, registers, walk)
        thread_resume(port)
        guard count > 0 else { return nil }
        return Array(UnsafeBufferPointer(start: walk.frames, count: count))
    }

    /// What the suspended walk uses, read before it starts.
    private struct Walk {
        let frames: UnsafeMutablePointer<UInt>
        let limit: Int
        let record: UnsafeMutablePointer<UInt>
        let state: UnsafeMutablePointer<natural_t>
        let low: UInt
        let high: UInt
    }

    /// With the main thread suspended: plain loads and stores into the
    /// preallocated buffers, and two Mach calls; no static is touched.
    private static func walkSuspended(_ port: mach_port_t, _ registers: RegisterLayout, _ walk: Walk) -> Int {
        var count = registers.words
        guard thread_get_state(port, registers.flavor, walk.state, &count) == KERN_SUCCESS else { return 0 }
        let state = UnsafeRawPointer(walk.state)
        let pc = UInt(state.load(fromByteOffset: registers.pc, as: UInt64.self))
        var fp = UInt(state.load(fromByteOffset: registers.fp, as: UInt64.self))
        var lr: UInt = 0
        if let offset = registers.lr { lr = UInt(state.load(fromByteOffset: offset, as: UInt64.self)) }

        var n = 0
        if pc != 0 {
            walk.frames[n] = strip(pc)
            n += 1
        }
        // A function that calls nothing (a system call's stub) keeps its
        // return address in the link register only.
        if lr != 0 && n < walk.limit {
            walk.frames[n] = strip(lr)
            n += 1
        }
        let size = vm_size_t(2 * MemoryLayout<UInt>.size)
        var previous: UInt = 0
        while fp != 0 && n < walk.limit {
            // A frame record lies on the main thread's stack, word aligned,
            // above the one before it.
            guard fp % UInt(MemoryLayout<UInt>.size) == 0, fp > previous, fp >= walk.low, fp < walk.high,
                  walk.high - fp >= UInt(size)
            else { break }
            var copied: vm_size_t = 0
            let read = vm_read_overwrite(
                mach_task_self_, vm_address_t(fp), size, vm_address_t(UInt(bitPattern: walk.record)), &copied
            )
            guard read == KERN_SUCCESS, copied == size else { break }
            let next = walk.record[0]
            let returnAddress = walk.record[1]
            if returnAddress == 0 { break }
            walk.frames[n] = strip(returnAddress)
            n += 1
            previous = fp
            fp = next
        }
        return n
    }

    /// A code address without the pointer-authentication bits arm64e
    /// code signs return addresses with.
    @inline(__always)
    private static func strip(_ address: UInt) -> UInt {
        #if arch(arm64) && os(iOS) && !targetEnvironment(simulator)
        return address & 0x0000_000F_FFFF_FFFF
        #elseif arch(arm64)
        return address & 0x0000_7FFF_FFFF_FFFF
        #else
        return address
        #endif
    }
}
#endif
