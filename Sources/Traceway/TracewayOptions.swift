import Foundation

public struct TracewayOptions {

    public var sampleRate: Double

    public var debug: Bool

    public var version: String

    public var debounceMs: Int

    public var retryDelayMs: Int

    public var maxPendingExceptions: Int

    public var persistToDisk: Bool

    public var maxLocalFiles: Int

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
