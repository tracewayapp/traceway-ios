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
    /// The reader ended and closed `original`: its number may be another
    /// descriptor's by now.
    private var ended = false

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
    /// after the last buffered bytes have reached the original destination.
    /// When the reader ended already (the app pointed `fd` somewhere else
    /// itself, so the pipe lost its writer), `fd` is left as the app set it.
    func stop(waitForDrain: Bool = true) {
        if fd == STDOUT_FILENO { fflush(stdout) }
        lock.lock()
        if !ended { dup2(original, fd) }
        lock.unlock()
        if waitForDrain { _ = finished.wait(timeout: .now() + 2) }
    }

    /// Whether the reader ended and gave its descriptors back.
    var readerEnded: Bool {
        lock.lock(); defer { lock.unlock() }
        return ended
    }

    private func run() {
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: StreamTee.bufferSize)
        defer {
            buffer.deallocate()
            lock.lock()
            ended = true
            close(readEnd)
            close(original)
            lock.unlock()
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

/// Each opted-in client owns fresh pipes. Already-buffered bytes can only
/// reach the client that owned the corresponding descriptor.
enum StdoutCapture {
    private static let lock = NSLock()
    private static var tees: [StreamTee] = []
    private static var owner: ObjectIdentifier?

    static func install(for client: TracewayClient) {
        lock.lock()
        defer { lock.unlock() }
        stopTees()
        guard client.options.captureStdout else { return }
        owner = ObjectIdentifier(client)
        for (fd, name) in [(STDOUT_FILENO, "stdout"), (STDERR_FILENO, "stderr")] {
            if let tee = StreamTee(fd: fd, name: name, onLines: { [weak client] lines in
                client?.recordStdLines(lines, stream: name)
            }) { tees.append(tee) }
        }
    }

    static func uninstall(for client: TracewayClient) {
        lock.lock()
        defer { lock.unlock() }
        if owner == ObjectIdentifier(client) { stopTees() }
    }

    private static func stopTees() {
        for tee in tees {
            tee.setHandler(nil)
            tee.stop(waitForDrain: false)
        }
        tees.removeAll()
        owner = nil
    }
}
