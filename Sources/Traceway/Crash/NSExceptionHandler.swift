import Foundation

// Stored outside the enum so the @convention(c) handler can reach them without
// a capture. `private` is file-scoped, so only this file sees them.
private weak var twNSClient: TracewayClient?
private var twNSPrevious: (@convention(c) (NSException) -> Void)?
private var twNSFlushTimeout: TimeInterval = 2.0

private func twNSExceptionHandler(_ exception: NSException) {
    if let client = twNSClient {
        let stackTrace = CrashRecordStore.renderWireTrace(
            header: StackTraceFormatter.format(
                type: exception.name.rawValue, message: exception.reason, frames: []
            ),
            arch: BinaryImages.currentArch(),
            images: BinaryImages.capture(),
            addresses: exception.callStackReturnAddresses.map { UInt(truncating: $0) }
        )
        let record = ExceptionStackTrace(
            stackTrace: stackTrace,
            recordedAtMs: ISO8601.nowMillis(),
            isMessage: false
        )
        // Persist first (guaranteed on disk), then a best-effort synchronous
        // flush — URLSession sometimes completes before the process dies.
        client.addException(record)
        client.flush(timeout: twNSFlushTimeout)
    }
    // Chain the previously-installed handler (Crashlytics/Sentry/etc.).
    twNSPrevious?(exception)
}

/// Captures uncaught Objective-C `NSException`s. Unlike the signal path, this
/// runs in a normal runtime context, so Foundation is safe to use here.
enum NSExceptionHandler {
    static func install(client: TracewayClient, flushTimeout: TimeInterval = 2.0) {
        twNSClient = client
        twNSFlushTimeout = flushTimeout
        twNSPrevious = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler(twNSExceptionHandler)
    }
}
