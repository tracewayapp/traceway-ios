import Foundation

#if canImport(ObjectiveC)
private var twNSHandler: ((NSException) -> Void)?
private var twNSPrevious: (@convention(c) (NSException) -> Void)?

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
    static func install(_ handler: @escaping (NSException) -> Void) {
        twNSHandler = handler
        let current = NSGetUncaughtExceptionHandler()
        // Installing twice (a restart of the SDK) must not chain to itself.
        if let current = current, unsafeBitCast(current, to: UnsafeRawPointer.self)
            == unsafeBitCast(twNSExceptionHandler as @convention(c) (NSException) -> Void, to: UnsafeRawPointer.self) {
            return
        }
        twNSPrevious = current
        NSSetUncaughtExceptionHandler(twNSExceptionHandler)
    }

    static func uninstall() {
        twNSHandler = nil
    }
}
#endif
