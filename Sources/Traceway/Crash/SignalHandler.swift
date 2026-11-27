import Foundation
#if canImport(Darwin)
import Darwin

// Everything the handler reads is allocated by `install` and never freed,
// so the handler only does async-signal-safe work: plain loads, `open`,
// `write`, `close`, `sigaction`, `raise` and `vm_read_overwrite`.
private var twPathPtr: UnsafeMutablePointer<CChar>?
/// The published metadata block: an `Int` byte count, then the bytes. One
/// pointer, so the handler never pairs a new pointer with an old length.
private var twMeta: UnsafeMutableRawPointer?
private var twImagesPtr: UnsafeMutablePointer<UInt8>?
private var twImagesLen: Int = 0
private var twBacktracePtr: UnsafeMutablePointer<UnsafeMutableRawPointer?>?
private var twIntScratch: UnsafeMutablePointer<UInt8>?
/// Two words a frame record is copied into before it is read.
private var twFrameScratch: UnsafeMutablePointer<UInt>?
private var twPrevActions: UnsafeMutablePointer<sigaction>?
private var twInstalled = false
private var twInHandler: sig_atomic_t = 0
private var twSuppressCrashRecord: sig_atomic_t = 0

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
    if twInHandler != 0 || twSuppressCrashRecord != 0 {
        twForward(signo, info)
        return
    }
    twInHandler = 1

    if let path = twPathPtr {
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        if fd >= 0 {
            twWrite(fd, "TRACEWAY_SIGNAL_V1\n")
            twWrite(fd, "signal=")
            twWriteInt(fd, Int(signo))
            twWrite(fd, "\n")
            twWrite(fd, "time=")
            twWriteInt(fd, Int(time(nil)))
            twWrite(fd, "\n")
            if let meta = twMeta {
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

    twForward(signo, info)
}

/// Hands the signal to the handler installed before Traceway's, exactly
/// once, as if Traceway's had never been there. Its action is restored
/// first. A fault the hardware raised is then left to happen again: the
/// handler returns, the instruction runs again and faults, and the kernel
/// calls the previous handler with the crash's own `siginfo` and context
/// (or ends the process, for the default action). A signal sent by
/// software (`abort`, `raise`, `kill`) does not come back on its own, so it
/// is raised again; it is delivered when this handler returns.
private func twForward(_ signo: Int32, _ info: UnsafeMutablePointer<siginfo_t>?) {
    if let prev = twPrevActions, signo > 0, signo < 32 {
        sigaction(signo, prev.advanced(by: Int(signo)), nil)
    } else {
        signal(signo, SIG_DFL)
    }
    if twRaisedByHardware(signo, info) { return }
    raise(signo)
}

/// A synchronous fault of the instruction that crashed: its `si_code` is a
/// fault code, not one of the codes of a signal that was sent.
private func twRaisedByHardware(_ signo: Int32, _ info: UnsafeMutablePointer<siginfo_t>?) -> Bool {
    guard let info = info else { return false }
    let code = info.pointee.si_code
    guard code > 0, code < SI_USER else { return false }
    #if arch(x86_64)
    // `int3` traps after the instruction: run again, the code would go on.
    if signo == SIGTRAP { return false }
    #endif
    return signo == SIGSEGV || signo == SIGBUS || signo == SIGILL || signo == SIGFPE || signo == SIGTRAP
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
    /// Orders a block's bytes before the pointer that publishes it.
    private static let publishLock = NSLock()
    /// Spare metadata blocks, so an update reuses memory instead of leaking
    /// a buffer each time. The published one is never written.
    private static var metaBlocks: [(block: UnsafeMutableRawPointer, capacity: Int)] = []
    private static var metaAllocations = 0

    static var isInstalled: Bool {
        lock.lock(); defer { lock.unlock() }
        return twInstalled
    }

    /// Installs the handlers once per process; later calls only update the
    /// metadata. The handlers that were installed before are kept and get
    /// every signal after Traceway's handler.
    static func install(crashPath: String, metadata: [UInt8], imagesSection: [UInt8] = []) {
        lock.lock()
        defer { lock.unlock() }
        guard !twInstalled else {
            storeMetadata(metadata)
            return
        }

        prepareScratch()
        twPrevActions = UnsafeMutablePointer<sigaction>.allocate(capacity: 32)
        twPrevActions?.initialize(repeating: sigaction(), count: 32)

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

        // The alternate stack is per thread: the main thread's is the one a
        // stack overflow in the app needs most.
        twInstallAltStack()
        if !Thread.isMainThread { DispatchQueue.main.async { twInstallAltStack() } }

        for sig in twHandledSignals {
            var action = sigaction()
            sigemptyset(&action.sa_mask)
            action.sa_flags = SA_SIGINFO | SA_ONSTACK
            action.__sigaction_u.__sa_sigaction = twSignalHandler
            sigaction(sig, &action, twPrevActions?.advanced(by: Int(sig)))
        }

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
        twSuppressCrashRecord = 1
    }

    /// What a crash record says about the app. Ignored until the handlers
    /// are installed (`persistToDisk: false` never installs them).
    static func setMetadata(_ metadata: [UInt8]) {
        lock.lock()
        defer { lock.unlock() }
        guard twInstalled else { return }
        storeMetadata(metadata)
    }

    /// Under `lock`. Fills a block the handler does not read, then
    /// publishes it with one pointer store. Blocks are reused; one too small
    /// is replaced by one twice as large, and the old one is kept (never
    /// freed), since a handler on another thread may still be reading it.
    private static func storeMetadata(_ metadata: [UInt8]) {
        let published = twMeta
        var index = metaBlocks.firstIndex { $0.block != published && $0.capacity >= metadata.count }
        if index == nil {
            let spare = metaBlocks.firstIndex { $0.block != published }
            let capacity = max(metadata.count, 2 * (spare.map { metaBlocks[$0].capacity } ?? 1024))
            let block = UnsafeMutableRawPointer.allocate(byteCount: twMetaHeader + capacity,
                                                         alignment: MemoryLayout<Int>.alignment)
            metaAllocations += 1
            if let spare = spare {
                metaBlocks[spare] = (block, capacity)
                index = spare
            } else {
                metaBlocks.append((block, capacity))
                index = metaBlocks.count - 1
            }
        }
        guard let slot = index else { return }
        let block = metaBlocks[slot].block
        // A release then an acquire order the bytes before the pointer that
        // publishes them; the handler reads through that pointer.
        publishLock.lock()
        block.storeBytes(of: metadata.count, as: Int.self)
        metadata.withUnsafeBytes { bytes in
            if let base = bytes.baseAddress {
                block.advanced(by: twMetaHeader).copyMemory(from: base, byteCount: bytes.count)
            }
        }
        publishLock.unlock()
        publishLock.lock()
        twMeta = block
        publishLock.unlock()
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
        guard let meta = twMeta else { return [] }
        let length = meta.load(as: Int.self)
        return Array(UnsafeRawBufferPointer(start: meta.advanced(by: twMetaHeader), count: length))
    }

    /// Puts back the actions that were installed before Traceway's and
    /// forgets the install, so a test can install again.
    static func uninstallForTesting() {
        lock.lock()
        defer { lock.unlock() }
        if twInstalled, let prev = twPrevActions {
            for sig in twHandledSignals { sigaction(sig, prev.advanced(by: Int(sig)), nil) }
        }
        twInstalled = false
        twInHandler = 0
        twSuppressCrashRecord = 0
        twMeta = nil
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
