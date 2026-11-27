import Foundation

enum Log {
    static var debugEnabled: Bool = false
    static let tag = "Traceway"

    private static let lock = NSLock()
    private static var said = Set<String>()
    private static var _sink: ((String) -> Void)?

    /// Receives every line the SDK prints, in tests; the lines still go to
    /// `NSLog`.
    static var sink: ((String) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _sink }
        set { lock.lock(); _sink = newValue; lock.unlock() }
    }

    /// SDK activity, with `debug` only.
    static func debug(_ message: @autoclosure () -> String) {
        guard debugEnabled else { return }
        print("[\(tag)] \(message())")
    }

    /// A mistake in how the app uses the SDK (a pattern that does not
    /// compile, settings it cannot use): printed whatever `debug` says.
    static func warn(_ message: @autoclosure () -> String) {
        print("[\(tag)] \(message())")
    }

    /// Printed once per `key` per process, whatever `debug` says: the app
    /// does not get what it asked for, and nothing else would tell it.
    static func once(_ key: String, _ message: @autoclosure () -> String) {
        guard first(key) else { return }
        print("[\(tag)] \(message())")
    }

    /// Once per `key` per process, with `debug` only.
    static func debugOnce(_ key: String, _ message: @autoclosure () -> String) {
        guard debugEnabled, first(key) else { return }
        print("[\(tag)] \(message())")
    }

    /// Forgets the once-per-process lines, for tests.
    static func resetForTesting() {
        lock.lock()
        said.removeAll()
        lock.unlock()
    }

    private static func first(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return said.insert(key).inserted
    }

    private static func print(_ line: String) {
        NSLog("%@", line)
        sink?(line)
    }
}
