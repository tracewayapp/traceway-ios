#if canImport(UIKit)
import UIKit

/// Where a wireframe capture starts: the windows of the scene in front,
/// back to front, and the one whose coordinate space the frames are in.
/// Every window is walked into the same screen node, so alerts, sheets and
/// action sheets in windows of their own paint over the app in order.
/// Keyboard windows are left out: the keyboard is a neutral box.
enum WireframeRoots {
    /// The visible windows of the foreground scene (the active one, else an
    /// inactive one), sorted by window level and then by order. Main thread
    /// only.
    static func visibleWindows() -> [UIWindow] {
        var windows: [UIWindow] = []
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let scene = scenes.first(where: { $0.activationState == .foregroundActive })
            ?? scenes.first(where: { $0.activationState == .foregroundInactive }) {
            windows = scene.windows
        }
        // KVC raises for a key that is gone: asked only while it answers.
        if windows.isEmpty, UIApplication.shared.responds(to: NSSelectorFromString("windows")),
           let legacy = UIApplication.shared.value(forKey: "windows") as? [UIWindow] {
            windows = legacy
        }
        let shown = windows.enumerated().filter { _, window in
            !window.isHidden && window.alpha > 0.01 && window.bounds.width > 0
                && !ClassInfo.of(window).isKeyboardWindow
        }
        return shown.sorted { a, b in
            (a.element.windowLevel.rawValue, a.offset) < (b.element.windowLevel.rawValue, b.offset)
        }.map { $0.element }
    }

    /// The window frames are measured in: the key window, else the first
    /// normal-level one, else the first.
    static func screenWindow(of windows: [UIWindow]) -> UIWindow? {
        windows.first(where: { $0.isKeyWindow })
            ?? windows.first(where: { $0.windowLevel == .normal })
            ?? windows.first
    }
}
#endif
