import Foundation

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

        client.addException(record)
        client.flush(timeout: twNSFlushTimeout)
    }

    twNSPrevious?(exception)
}

enum NSExceptionHandler {
    static func install(client: TracewayClient, flushTimeout: TimeInterval = 2.0) {
        twNSClient = client
        twNSFlushTimeout = flushTimeout
        twNSPrevious = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler(twNSExceptionHandler)
    }
}
