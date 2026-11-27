import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Tees a file descriptor (standard output or error) into the SDK
/// (`captureStdout`): the descriptor is pointed at a pipe,
/// and a thread of its own reads the pipe, writes every byte to the
/// original destination first, then cuts lines. The reader never waits for
/// the SDK: lines are handed over on another queue, at most `maxPending` of
/// them wait (more are dropped, never the bytes to the original), and a line
/// keeps at most `maxLineBytes`. So a writer is never held up by Traceway,
/// only, as before, by the original destination.
final class StreamTee {
    static let maxLineBytes = 16 * 1024
    static let maxPending = 1000
    private static let bufferSize = 16 * 1024

    let fd: Int32
    /// `stdout` or `stderr`: what the lines' `log.source` says.
    let name: String
    private let original: Int32
    private let readEnd: Int32
    private let delivery = DispatchQueue(label: "app.traceway.stdout", qos: .utility)
    private let finished = DispatchSemaphore(value: 0)

    private let lock = NSLock()
    // Under `lock`.
    private var partial: [UInt8] = []
    private var pending: [String] = []
    private var scheduled = false
    private var handler: (([String]) -> Void)?

    /// Starts teeing `fd`; nil when the descriptors could not be set up
    /// (then `fd` is left as it was).
    init?(fd: Int32, name: String, onLines: @escaping ([String]) -> Void) {
        let original = dup(fd)
        guard original >= 0 else { return nil }
        var ends: [Int32] = [-1, -1]
        guard pipe(&ends) == 0 else {
            close(original)
            return nil
        }
        if fd == STDOUT_FILENO {
            // What `print` buffered goes out first, and lines keep leaving
            // one by one now that the destination is a pipe.
            fflush(stdout)
            setvbuf(stdout, nil, _IOLBF, 0)
        }
        guard dup2(ends[1], fd) >= 0 else {
            close(ends[0])
            close(ends[1])
            close(original)
            return nil
        }
        close(ends[1])
        self.fd = fd
        self.name = name
        self.original = original
        readEnd = ends[0]
        handler = onLines
        let thread = Thread { [self] in self.run() }
        thread.name = "app.traceway.\(name)"
        thread.start()
    }

    /// Where lines go from now on; nil drops them (bytes still reach the
    /// original destination).
    func setHandler(_ onLines: (([String]) -> Void)?) {
        lock.lock()
        handler = onLines
        lock.unlock()
    }

    /// Points `fd` back at the original destination and ends the reader
    /// (tests; the SDK keeps its tees for the life of the process).
    func stop() {
        if fd == STDOUT_FILENO { fflush(stdout) }
        dup2(original, fd)
        _ = finished.wait(timeout: .now() + 2)
        close(original)
    }

    private func run() {
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: StreamTee.bufferSize)
        defer {
            buffer.deallocate()
            close(readEnd)
            finished.signal()
        }
        while true {
            let count = read(readEnd, buffer, StreamTee.bufferSize)
            if count > 0 {
                forward(buffer, count)
                collect(UnsafeBufferPointer(start: buffer, count: count))
            } else if count < 0 && errno == EINTR {
                continue
            } else {
                // The write end is gone (`stop`), or the pipe broke.
                return
            }
        }
    }

    /// Every byte reaches the original destination, before anything else.
    private func forward(_ bytes: UnsafeMutablePointer<UInt8>, _ count: Int) {
        var offset = 0
        while offset < count {
            let written = write(original, bytes.advanced(by: offset), count - offset)
            if written > 0 {
                offset += written
            } else if written < 0 && errno == EINTR {
                continue
            } else {
                return
            }
        }
    }

    private func collect(_ bytes: UnsafeBufferPointer<UInt8>) {
        lock.lock()
        var lines: [String] = []
        for byte in bytes {
            if byte == 10 {
                if partial.last == 13 { partial.removeLast() }
                if !partial.isEmpty { lines.append(String(decoding: partial, as: UTF8.self)) }
                partial.removeAll(keepingCapacity: true)
            } else if partial.count < StreamTee.maxLineBytes {
                partial.append(byte)
            }
        }
        let room = max(0, StreamTee.maxPending - pending.count)
        pending.append(contentsOf: lines.prefix(room))
        let schedule = !pending.isEmpty && !scheduled
        if schedule { scheduled = true }
        lock.unlock()
        if schedule { delivery.async { [weak self] in self?.deliver() } }
    }

    private func deliver() {
        lock.lock()
        let lines = pending
        pending = []
        scheduled = false
        let handler = self.handler
        lock.unlock()
        guard !lines.isEmpty, let handler = handler else { return }
        guarded("stdout lines") { handler(lines) }
    }
}

/// The process's standard output and error tees, set up once: a restarted
/// SDK only gets the lines.
enum StdoutCapture {
    private static let lock = NSLock()
    private static var tees: [StreamTee] = []
    private static var sink: ((_ lines: [String], _ stream: String) -> Void)?

    static var isInstalled: Bool {
        lock.lock(); defer { lock.unlock() }
        return !tees.isEmpty
    }

    static func install(_ sink: @escaping (_ lines: [String], _ stream: String) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        self.sink = sink
        guard tees.isEmpty else { return }
        for (fd, name) in [(STDOUT_FILENO, "stdout"), (STDERR_FILENO, "stderr")] {
            if let tee = StreamTee(fd: fd, name: name, onLines: { StdoutCapture.deliver($0, name) }) {
                tees.append(tee)
            }
        }
    }

    /// Lines are dropped from now on; the bytes still reach the original
    /// destinations.
    static func uninstall() {
        lock.lock()
        sink = nil
        lock.unlock()
    }

    private static func deliver(_ lines: [String], _ stream: String) {
        lock.lock()
        let sink = self.sink
        lock.unlock()
        sink?(lines, stream)
    }
}
