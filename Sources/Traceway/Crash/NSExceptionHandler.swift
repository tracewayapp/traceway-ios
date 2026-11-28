import Foundation

#if canImport(ObjectiveC)
private var twNSHandler: ((NSException) -> Void)?
private var twNSPrevious: (@convention(c) (NSException) -> Void)?
private var twNSInstalled = false
private let twNSLock = NSLock()

/// Set while the handler runs: if another SDK installed its handler after
/// ours and chains back to us, the second call returns instead of looping.
private var twNSHandling = false

private func twNSExceptionHandler(_ exception: NSException) {
    if twNSHandling { return }
    twNSHandling = true
    if let handler = twNSHandler {
        handler(exception)
        // The exception is on disk and on its way: the SIGABRT the runtime
        // raises after the handler chain must not become a second report.
        SignalHandler.suppressCrashRecord()
    }
    twNSPrevious?(exception)
}

enum NSExceptionHandler {
    /// `handler` runs on the crashing thread and must record the exception
    /// before it returns: the process ends right after.
    ///
    /// Traceway's handler is installed once per process, and the handler
    /// that was there before it is the one it hands every exception to,
    /// once. A later install (a restart of the SDK) only swaps `handler`:
    /// installing again would chain to whatever is current, which may be a
    /// handler installed after Traceway's that chains back to it, and the
    /// first one would never be called again.
    static func install(_ handler: @escaping (NSException) -> Void) {
        twNSLock.lock()
        defer { twNSLock.unlock() }
        twNSHandler = handler
        guard !twNSInstalled else { return }
        twNSInstalled = true
        twNSPrevious = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler(twNSExceptionHandler)
    }

    static func uninstall() {
        twNSLock.lock()
        twNSHandler = nil
        twNSLock.unlock()
    }

    // MARK: - Testing

    /// Forgets the install and the handler seen before it, and puts that
    /// handler back as the process's.
    static func resetForTesting() {
        twNSLock.lock()
        defer { twNSLock.unlock() }
        if twNSInstalled { NSSetUncaughtExceptionHandler(twNSPrevious) }
        twNSInstalled = false
        twNSPrevious = nil
        twNSHandler = nil
        twNSHandling = false
    }
}
#endif
