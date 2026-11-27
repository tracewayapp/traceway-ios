import Foundation
#if canImport(Darwin)
import Darwin

import TracewaySignalSupport

private var twPathPtr: UnsafeMutablePointer<CChar>?
private var twImagesPtr: UnsafeMutablePointer<UInt8>?
private var twImagesLen: Int = 0
private var twBacktracePtr: UnsafeMutablePointer<UnsafeMutableRawPointer?>?
private var twIntScratch: UnsafeMutablePointer<UInt8>?
/// Two words a frame record is copied into before it is read.
private var twFrameScratch: UnsafeMutablePointer<UInt>?
private var twInstalled = false
private var twInHandler: sig_atomic_t = 0

private let twBacktraceCap: Int32 = 128
private let twIntScratchLen = 32
private let twHandledSignals: [Int32] = [SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGSEGV, SIGTRAP]
private let twHandlerFrameSkip = 2
private let twMetaHeader = MemoryLayout<Int>.stride

@inline(__always)
private func twWrite(_ fd: Int32, _ text: StaticString) {
    _ = write(fd, text.utf8Start, text.utf8CodeUnitCount)
}

private func twWriteInt(_ fd: Int32, _ value: Int) {
    guard let scratch = twIntScratch else { return }
    if value == 0 {
        scratch[0] = 48
        _ = write(fd, scratch, 1)
        return
    }
    // In magnitude, digit by digit: `-Int.min` would overflow.
    var v = value
    let negative = v < 0
    var index = twIntScratchLen
    while v != 0 && index > 0 {
        index -= 1
        let digit = v % 10
        scratch[index] = UInt8(48 + (digit < 0 ? -digit : digit))
        v /= 10
    }
    if negative && index > 0 {
        index -= 1
        scratch[index] = 45
    }
    _ = write(fd, scratch.advanced(by: index), twIntScratchLen - index)
}

private func twWriteHex(_ fd: Int32, _ value: UInt) {
    guard let scratch = twIntScratch else { return }
    twWrite(fd, "0x")
    if value == 0 {
        scratch[0] = 48
        _ = write(fd, scratch, 1)
        return
    }
    var v = value
    var index = twIntScratchLen
    while v > 0 && index > 0 {
        index -= 1
        let nibble = UInt8(v & 0xf)
        scratch[index] = nibble < 10 ? (48 + nibble) : (97 &+ nibble &- 10)
        v >>= 4
    }
    _ = write(fd, scratch.advanced(by: index), twIntScratchLen - index)
}

@inline(__always)
private func twCrashContext(_ context: UnsafeMutableRawPointer?) -> (pc: UInt, fp: UInt) {
    guard let context = context else { return (0, 0) }
    let uc = context.assumingMemoryBound(to: ucontext_t.self)
    guard let mc = uc.pointee.uc_mcontext else { return (0, 0) }
    #if arch(arm64)
    return (UInt(mc.pointee.__ss.__pc), UInt(mc.pointee.__ss.__fp))
    #elseif arch(x86_64)
    return (UInt(mc.pointee.__ss.__rip), UInt(mc.pointee.__ss.__rbp))
    #else
    return (0, 0)
    #endif
}

/// Walks the frame records from `fp0`. A smashed stack can point anywhere:
/// each record is copied with `vm_read_overwrite`, which fails instead of
/// faulting inside the handler on memory that is not readable.
private func twWriteFrameChain(_ fd: Int32, _ fp0: UInt) {
    guard let scratch = twFrameScratch else { return }
    var fp = fp0
    var prev: UInt = 0
    var n = 0
    while fp != 0, fp % 16 == 0, fp > prev, n < Int(twBacktraceCap) {
        var copied: vm_size_t = 0
        let size = vm_size_t(2 * MemoryLayout<UInt>.size)
        let result = vm_read_overwrite(
            mach_task_self_, vm_address_t(fp), size, vm_address_t(UInt(bitPattern: scratch)), &copied
        )
        if result != KERN_SUCCESS || copied != size { break }
        let savedFP = scratch[0]
        let savedLR = scratch[1]
        if savedLR == 0 { break }
        twWriteHex(fd, savedLR)
        twWrite(fd, "\n")
        prev = fp
        fp = savedFP
        n += 1
    }
}

private func twSignalHandler(
    _ signo: Int32,
    _ info: UnsafeMutablePointer<siginfo_t>?,
    _ context: UnsafeMutableRawPointer?
) {
    if tw_try_lock_crash_record() {
        if twInHandler == 0, !tw_crash_record_suppressed(), let path = twPathPtr {
            twInHandler = 1
            twRecordSignal(signo, context, path)
        }
        tw_unlock_crash_record()
    }
    tw_forward_signal(signo, info, context, twSignalHandler)
}

private func twRecordSignal(_ signo: Int32, _ context: UnsafeMutableRawPointer?, _ path: UnsafePointer<CChar>) {
    let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
    if fd >= 0 {
        twWrite(fd, "TRACEWAY_SIGNAL_V1\n")
        twWrite(fd, "signal=")
        twWriteInt(fd, Int(signo))
        twWrite(fd, "\n")
        twWrite(fd, "time=")
        twWriteInt(fd, Int(time(nil)))
        twWrite(fd, "\n")
        if let meta = tw_current_metadata() {
            let length = meta.load(as: Int.self)
            if length > 0 { _ = write(fd, meta.advanced(by: twMetaHeader), length) }
        }

        if let images = twImagesPtr, twImagesLen > 0 {
            _ = write(fd, images, twImagesLen)
        }
        twWrite(fd, "---FRAMES---\n")
        let crash = twCrashContext(context)
        if crash.pc != 0 {
            twWriteHex(fd, crash.pc)
            twWrite(fd, "\n")
        }
        if crash.fp != 0 {
            twWriteFrameChain(fd, crash.fp)
        } else if let backtraceBuf = twBacktracePtr {
            let count = Int(backtrace(backtraceBuf, twBacktraceCap))
            var i = min(twHandlerFrameSkip, count)
            while i < count {
                twWriteHex(fd, UInt(bitPattern: backtraceBuf[i]))
                twWrite(fd, "\n")
                i += 1
            }
        }
        close(fd)
    }
}

/// The alternate signal stack: 64 KiB, at least what Darwin requires.
private let twAltStackSize = max(64 * 1024, Int(MINSIGSTKSZ))

/// Gives the calling thread a stack of its own for the handler, so a stack
/// overflow on it can still be recorded: the overflowing
/// stack has no room left for the handler's frames. Each thread needs its
/// own. One the thread already has (the app's, another crash reporter's)
/// is kept.
private func twInstallAltStack() {
    var current = stack_t()
    if sigaltstack(nil, &current) == 0, current.ss_flags & SS_DISABLE == 0, current.ss_sp != nil,
       current.ss_size >= Int(MINSIGSTKSZ) {
        return
    }
    guard let alt = malloc(twAltStackSize) else { return }
    var ss = stack_t()
    ss.ss_sp = alt
    ss.ss_size = twAltStackSize
    ss.ss_flags = 0
    if sigaltstack(&ss, nil) != 0 { free(alt) }
}

enum SignalHandler {
    /// Serializes install and metadata updates: two starts at once must
    /// not both install, or the second would chain to the first.
    private static let lock = NSLock()
    private static var owner: ObjectIdentifier?
    /// Only configuration changes wait. An interrupting handler always uses try-lock.
    private static func acquireCaptureGate() {
        while !tw_try_lock_crash_record() { sched_yield() }
    }

    private static var blocks: [(memory: UnsafeMutableRawPointer, capacity: Int)] = []
    private static var metaAllocations = 0

    static var isInstalled: Bool {
        lock.lock(); defer { lock.unlock() }
        return twInstalled
    }

    /// Binds recording to this client and its directory. The actions already
    /// installed receive the signal with its original information and context.
    static func install(crashPath: String, metadata: [UInt8], imagesSection: [UInt8] = [], owner: ObjectIdentifier? = nil) {
        lock.lock()
        defer { lock.unlock() }
        acquireCaptureGate()
        defer { tw_unlock_crash_record() }
        self.owner = owner
        prepareScratch()
        twPathPtr?.deallocate()
        twImagesPtr?.deallocate()
        twImagesPtr = nil
        twImagesLen = 0
        let pathBytes = Array(crashPath.utf8)
        let pathPtr = UnsafeMutablePointer<CChar>.allocate(capacity: pathBytes.count + 1)
        for (i, byte) in pathBytes.enumerated() { pathPtr[i] = CChar(bitPattern: byte) }
        pathPtr[pathBytes.count] = 0
        twPathPtr = pathPtr

        if !imagesSection.isEmpty {
            let imgPtr = UnsafeMutablePointer<UInt8>.allocate(capacity: imagesSection.count)
            for (i, byte) in imagesSection.enumerated() { imgPtr[i] = byte }
            twImagesPtr = imgPtr
            twImagesLen = imagesSection.count
        }

        storeMetadata(metadata)

        guard !twInstalled else { return }

        // The alternate stack is per thread: the main thread's is the one a
        // stack overflow in the app needs most.
        twInstallAltStack()
        if !Thread.isMainThread { DispatchQueue.main.async { twInstallAltStack() } }

        for sig in twHandledSignals { tw_install_signal(sig, twSignalHandler) }

        twInHandler = 0
        twInstalled = true
    }

    private static func prepareScratch() {
        if twIntScratch == nil { twIntScratch = UnsafeMutablePointer<UInt8>.allocate(capacity: twIntScratchLen) }
        if twFrameScratch == nil { twFrameScratch = UnsafeMutablePointer<UInt>.allocate(capacity: 2) }
        if twBacktracePtr == nil {
            twBacktracePtr = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: Int(twBacktraceCap))
        }
    }

    // Called once another handler (the NSException handler) has already
    // recorded the crash: the runtime's follow-up abort() must not produce a
    // second crash record for the same event. The process is dying, so the
    // flag is never reset.
    static func suppressCrashRecord() {
        tw_suppress_crash_record(true)
    }

    /// What a crash record says about the app. Ignored until the handlers
    /// are installed (`persistToDisk: false` never installs them).
    static func setMetadata(_ metadata: [UInt8], owner: ObjectIdentifier? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard twInstalled, self.owner == owner, !tw_crash_record_busy() else { return }
        storeMetadata(metadata)
    }

    /// Writers update only the unpublished block. A handler that begins
    /// during this update reads one complete version. While it is reading,
    /// later updates leave both blocks alone.
    private static func storeMetadata(_ metadata: [UInt8]) {
        let current = tw_current_metadata()
        let spare = blocks.firstIndex { $0.memory != current }
        let block: UnsafeMutableRawPointer
        if let spare = spare, blocks[spare].capacity >= metadata.count {
            block = blocks[spare].memory
        } else {
            let capacity = max(metadata.count, 2 * (spare.map { blocks[$0].capacity } ?? 1024))
            block = UnsafeMutableRawPointer.allocate(byteCount: twMetaHeader + capacity,
                                                     alignment: MemoryLayout<Int>.alignment)
            metaAllocations += 1
            if let spare = spare {
                blocks[spare].memory.deallocate()
                blocks[spare] = (block, capacity)
            } else {
                blocks.append((block, capacity))
            }
        }
        block.storeBytes(of: metadata.count, as: Int.self)
        metadata.withUnsafeBytes { bytes in
            if let base = bytes.baseAddress {
                block.advanced(by: twMetaHeader).copyMemory(from: base, byteCount: bytes.count)
            }
        }
        tw_publish_metadata(block)
    }

    // MARK: - Testing

    /// Metadata blocks allocated so far.
    static var metadataAllocationsForTesting: Int {
        lock.lock(); defer { lock.unlock() }
        return metaAllocations
    }

    /// The metadata the handler would write now.
    static var publishedMetadataForTesting: [UInt8] {
        lock.lock(); defer { lock.unlock() }
        guard let meta = tw_current_metadata() else { return [] }
        let length = meta.load(as: Int.self)
        return Array(UnsafeRawBufferPointer(start: meta.advanced(by: twMetaHeader), count: length))
    }

    static func uninstall(owner: ObjectIdentifier?) {
        lock.lock()
        defer { lock.unlock() }
        guard self.owner == owner else { return }
        uninstallLocked()
    }

    static func disableRecording() {
        lock.lock()
        defer { lock.unlock() }
        uninstallLocked()
    }

    private static func uninstallLocked() {
        acquireCaptureGate()
        defer { tw_unlock_crash_record() }
        if twInstalled {
            for sig in twHandledSignals { tw_uninstall_signal(sig, twSignalHandler) }
        }
        owner = nil
        twInstalled = false
        twInHandler = 0
        tw_suppress_crash_record(false)
        tw_publish_metadata(nil)
        for block in blocks { block.memory.deallocate() }
        blocks.removeAll()
        twImagesPtr?.deallocate()
        twImagesPtr = nil
        twImagesLen = 0
        twPathPtr?.deallocate()
        twPathPtr = nil
    }

    /// The calling thread's alternate signal stack: its base and size, and
    /// whether it is on.
    static func altStackForTesting() -> (base: UInt, size: Int, enabled: Bool) {
        var current = stack_t()
        guard sigaltstack(nil, &current) == 0 else { return (0, 0, false) }
        return (UInt(bitPattern: current.ss_sp), current.ss_size, current.ss_flags & SS_DISABLE == 0)
    }

    /// Sets up the calling thread's alternate stack as `install` does.
    static func installAltStackForTesting() {
        twInstallAltStack()
    }

    /// The flags of the action installed for `signal` now.
    static func actionFlagsForTesting(_ signal: Int32) -> Int32 {
        var action = sigaction()
        guard sigaction(signal, nil, &action) == 0 else { return 0 }
        return action.sa_flags
    }

    /// The frame walk on its own, writing to `fd`.
    static func writeFrameChainForTesting(_ fd: Int32, framePointer: UInt) {
        lock.lock()
        prepareScratch()
        lock.unlock()
        twWriteFrameChain(fd, framePointer)
    }
}
#endif
