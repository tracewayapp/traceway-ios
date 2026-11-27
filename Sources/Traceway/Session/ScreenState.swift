import Foundation
import OpenTelemetryApi

/// Where the app is: the screen on top, its route template, the screen
/// before it, since when it shows, and the size of the window. Navigation
/// writes it on any thread; issues read it where they are captured, so it
/// is locked.
final class ScreenState {
    private let lock = NSLock()
    private var _name: String?
    private var _route: String?
    private var _previous: String?
    private var _sinceMs: Int64?
    private var _viewport: String?
    private var _viewportProvider: (() -> String?)?

    /// The path of the screen on top, as the last navigation reported it.
    var name: String? {
        lock.lock(); defer { lock.unlock() }
        return _name
    }

    /// The route template of the current screen, from `setRoute`.
    var route: String? {
        lock.lock(); defer { lock.unlock() }
        return _route
    }

    /// The window's size in points, `<width>x<height>`.
    var viewport: String? {
        get {
            lock.lock(); defer { lock.unlock() }
            return _viewport
        }
        set {
            lock.lock()
            _viewport = newValue
            lock.unlock()
        }
    }

    /// Reads the window's size; called on the main thread only. Set by the
    /// UIKit hooks.
    var viewportProvider: (() -> String?)? {
        get {
            lock.lock(); defer { lock.unlock() }
            return _viewportProvider
        }
        set {
            lock.lock()
            _viewportProvider = newValue
            lock.unlock()
        }
    }

    /// The app reached `path`. A different path is a new screen: the one it
    /// replaces becomes the previous one, and its route template goes with
    /// it. An empty path changes nothing. Returns the screen and route now.
    @discardableResult
    func navigated(to path: String, atMs: Int64) -> (name: String?, route: String?) {
        lock.lock(); defer { lock.unlock() }
        if !path.isEmpty, path != _name {
            _previous = _name
            _name = path
            _sinceMs = atMs
            _route = nil
        }
        return (_name, _route)
    }

    func setRoute(_ template: String?) {
        let route = ScreenState.template(template)
        lock.lock()
        _route = route
        lock.unlock()
    }

    /// A route template as records carry it: trimmed, starting with `/`, at
    /// most 64 characters; nil when empty.
    static func template(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        let route = trimmed.hasPrefix("/") ? trimmed : "/" + trimmed
        return route.count > 64 ? String(route.prefix(64)) : route
    }

    /// What an exception or message carries of where the app was:
    /// `app.screen.name`, `app.screen.route`, `app.screen.previous`,
    /// `app.screen.duration_ms` and `viewport`, read when it is captured.
    func context(nowMs: Int64) -> [String: AttributeValue] {
        if Thread.isMainThread, let fresh = viewportProvider?() { viewport = fresh }
        lock.lock(); defer { lock.unlock() }
        var out: [String: AttributeValue] = [:]
        if let name = _name {
            out["app.screen.name"] = .string(name)
            if let since = _sinceMs { out["app.screen.duration_ms"] = .int(Int(max(0, nowMs - since))) }
        }
        if let route = _route { out["app.screen.route"] = .string(route) }
        if let previous = _previous { out["app.screen.previous"] = .string(previous) }
        if let viewport = _viewport { out["viewport"] = .string(viewport) }
        return out
    }
}
