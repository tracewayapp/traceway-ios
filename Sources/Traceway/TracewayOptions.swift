import Foundation

/// Configuration for the Traceway SDK. Defaults mirror the Android/Flutter SDKs.
public struct TracewayOptions {

    /// Fraction of exceptions to keep, 0.0–1.0. `1.0` keeps everything.
    public var sampleRate: Double

    /// When true, the SDK logs its activity via `NSLog`.
    public var debug: Bool

    /// App version, sent as `appVersion` on every report.
    public var version: String

    /// Delay (ms) after a capture before the batch is uploaded (coalesces bursts).
    public var debounceMs: Int

    /// Delay (ms) before retrying a failed upload.
    public var retryDelayMs: Int

    /// Maximum exceptions buffered in memory; the oldest is dropped past this.
    public var maxPendingExceptions: Int

    /// Persist pending reports to disk so they survive app restarts/crashes.
    public var persistToDisk: Bool

    /// Maximum number of persisted report files kept on disk.
    public var maxLocalFiles: Int

    /// Delete persisted files that have not synced within this many hours.
    public var localFileMaxAgeHours: Int

    public init(
        sampleRate: Double = 1.0,
        debug: Bool = false,
        version: String = "",
        debounceMs: Int = 1500,
        retryDelayMs: Int = 10_000,
        maxPendingExceptions: Int = 5,
        persistToDisk: Bool = true,
        maxLocalFiles: Int = 5,
        localFileMaxAgeHours: Int = 12
    ) {
        self.sampleRate = sampleRate
        self.debug = debug
        self.version = version
        self.debounceMs = debounceMs
        self.retryDelayMs = retryDelayMs
        self.maxPendingExceptions = maxPendingExceptions
        self.persistToDisk = persistToDisk
        self.maxLocalFiles = maxLocalFiles
        self.localFileMaxAgeHours = localFileMaxAgeHours
    }
}
