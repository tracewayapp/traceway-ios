import Foundation

// The SDK never takes the app down. Everything it runs in the
// app's control flow (public API, swizzled methods, observers, callbacks the
// app hands it, timers) contains its own failures with `guarded`, and the
// app's operation goes on unchanged.
//
// Swift cannot catch a trap (an overflow, a force unwrap of nil, `try!`) or
// an Objective-C exception, so `guarded` only contains thrown errors: traps
// are kept out of the SDK's sources instead, which `CrashSafetyTests`
// checks.

/// Runs `body`; an error it throws is contained: logged once per `where`
/// when debug logging is on, and otherwise dropped. Never rethrows, never
/// reports through Traceway itself, and costs nothing when `body` succeeds.
func guarded(_ `where`: StaticString, _ body: () throws -> Void) {
    do {
        try body()
    } catch {
        GuardedLog.failed(`where`, error)
    }
}

/// `body`'s result, or `fallback` when it throws (the error is handled as
/// `guarded` does).
func guarded<T>(_ `where`: StaticString, fallback: T, _ body: () throws -> T) -> T {
    do {
        return try body()
    } catch {
        GuardedLog.failed(`where`, error)
        return fallback
    }
}

enum GuardedLog {
    private static let lock = NSLock()
    private static var logged = Set<String>()

    static func failed(_ `where`: StaticString, _ error: Error) {
        guard Log.debugEnabled else { return }
        let name = `where`.withUTF8Buffer { String(decoding: $0, as: UTF8.self) }
        lock.lock()
        let first = logged.insert(name).inserted
        lock.unlock()
        if first { NSLog("[%@] %@ failed, contained: %@", Log.tag, name, "\(error)") }
    }
}
