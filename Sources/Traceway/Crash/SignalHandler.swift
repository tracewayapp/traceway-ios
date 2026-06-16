import Foundation
#if canImport(Darwin)
import Darwin
#endif

private var twPathPtr: UnsafeMutablePointer<CChar>?
private var twMetaPtr: UnsafeMutablePointer<UInt8>?
private var twMetaLen: Int = 0
private var twImagesPtr: UnsafeMutablePointer<UInt8>?
private var twImagesLen: Int = 0
private var twBacktracePtr: UnsafeMutablePointer<UnsafeMutableRawPointer?>?
private var twIntScratch: UnsafeMutablePointer<UInt8>?
private var twPrevActions: UnsafeMutablePointer<sigaction>?
private var twAltStack: UnsafeMutableRawPointer?
private var twInstalled = false
private var twInHandler: sig_atomic_t = 0

private let twBacktraceCap: Int32 = 128
private let twIntScratchLen = 32
private let twHandledSignals: [Int32] = [SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGSEGV, SIGTRAP]

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
    var v = value
    let negative = v < 0
    if negative { v = -v }
    var index = twIntScratchLen
    while v > 0 && index > 0 {
        index -= 1
        scratch[index] = UInt8(48 + (v % 10))
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

private func twSignalHandler(
    _ signo: Int32,
    _ info: UnsafeMutablePointer<siginfo_t>?,
    _ context: UnsafeMutableRawPointer?
) {

    if twInHandler != 0 {
        twRestoreAndReRaise(signo)
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
            if let meta = twMetaPtr, twMetaLen > 0 {
                _ = write(fd, meta, twMetaLen)
            }

            if let images = twImagesPtr, twImagesLen > 0 {
                _ = write(fd, images, twImagesLen)
            }
            twWrite(fd, "---FRAMES---\n")
            if let backtraceBuf = twBacktracePtr {

                let count = Int(backtrace(backtraceBuf, twBacktraceCap))
                var i = 0
                while i < count {
                    twWriteHex(fd, UInt(bitPattern: backtraceBuf[i]))
                    twWrite(fd, "\n")
                    i += 1
                }
            }
            close(fd)
        }
    }

    twRestoreAndReRaise(signo)
}

private func twRestoreAndReRaise(_ signo: Int32) {
    if let prev = twPrevActions, signo >= 0, signo < 32 {
        sigaction(signo, prev.advanced(by: Int(signo)), nil)
    } else {
        signal(signo, SIG_DFL)
    }
    raise(signo)
}

enum SignalHandler {

    static func install(crashPath: String, metadata: [UInt8], imagesSection: [UInt8] = []) {
        guard !twInstalled else { return }

        twIntScratch = UnsafeMutablePointer<UInt8>.allocate(capacity: twIntScratchLen)
        twBacktracePtr = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: Int(twBacktraceCap))
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

        setMetadata(metadata)

        let altSize = 64 * 1024
        let alt = malloc(altSize)
        twAltStack = alt
        var ss = stack_t()
        ss.ss_sp = alt
        ss.ss_size = altSize
        ss.ss_flags = 0
        sigaltstack(&ss, nil)

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

    static func setMetadata(_ metadata: [UInt8]) {
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: max(metadata.count, 1))
        for (i, byte) in metadata.enumerated() { buffer[i] = byte }

        twMetaLen = 0
        twMetaPtr = buffer
        twMetaLen = metadata.count
    }
}
