import Foundation
import OpenTelemetryApi
#if canImport(UIKit)
import UIKit
#endif
#if canImport(SwiftUI)
import SwiftUI
#endif
#if canImport(URLSessionInstrumentation)
import URLSessionInstrumentation
#endif

extension TracewayClient {
    /// Crash handlers, app lifecycle, navigation, taps, network spans and
    /// the wireframe recorder. Tests get none of these unless they attach a
    /// replay source.
    func installPlatformHooks() {
        if let source = testReplaySource {
            attachReplaySource(source)
            return
        }
        guard !isTesting else { return }
        let metadata = onQueueSync { crashMetadata() }
        CrashReporter.install(
            baseDir: supportDirectory(),
            persistToDisk: options.persistToDisk,
            metadata: metadata,
            appVersion: serviceVersion
        )
        #if canImport(ObjectiveC)
        NSExceptionHandler.install { exception in TracewayClient.shared?.captureFatalException(exception) }
        #endif
        installExitAndLogCapture()
        #if canImport(UIKit)
        PlatformHooks.install(self)
        #endif
        #if canImport(URLSessionInstrumentation)
        if options.captureNetwork { NetworkInstrumentation.install() }
        #endif
    }

    /// Why earlier runs ended (an `exit` marker, MetricKit) and the log
    /// lines the app writes (the unified log, standard output and error).
    private func installExitAndLogCapture() {
        if options.captureExitReasons, let directory = onQueueSync({ stateDirectoryForHooks }) {
            ExitMarker.install(directory: directory)
        }
        #if canImport(MetricKit) && os(iOS)
        if options.captureExitReasons, #available(iOS 14.0, *) { MetricKitSubscriber.install() }
        #endif
        #if canImport(OSLog)
        if options.captureLogs, #available(iOS 15.0, macOS 12.0, tvOS 15.0, watchOS 8.0, *) {
            startLogCapture(OSLogReader(source: OSLogStoreSource(), since: Date()))
        }
        #endif
        if options.captureStdout {
            StdoutCapture.install { lines, stream in TracewayClient.shared?.recordStdLines(lines, stream: stream) }
        }
    }

    func uninstallPlatformHooks() {
        #if canImport(UIKit)
        let id = ObjectIdentifier(self)
        // Only this client's hooks: a client started since keeps its own.
        DispatchQueue.main.async { PlatformHooks.uninstall(for: id) }
        #endif
    }
}

#if canImport(UIKit)
/// The UIKit side of the SDK. Swizzles are installed once per process and
/// look up the running client on each call, so a restarted SDK keeps them.
final class PlatformHooks {
    private static var current: PlatformHooks?
    private static var swizzled = false
    private static var displaySwizzled = false

    /// Where background tasks begin and end; tests stand in for UIKit.
    static var backgroundTasks: BackgroundTasks = ApplicationBackgroundTasks()

    private weak var client: TracewayClient?
    private let clientId: ObjectIdentifier
    private var observers: [NSObjectProtocol] = []
    private var backgroundTask: BackgroundTask?
    let recorder: WireframeRecorder?
    let touches = TouchTracker()
    /// Frames, lifecycle and the main thread for the app performance metrics.
    let vitalsHost: UIKitVitalsHost?

    private init(client: TracewayClient) {
        self.client = client
        clientId = ObjectIdentifier(client)
        if client.options.screenCapture, !client.standalone {
            let recorder = WireframeRecorder(
                maxFrames: max(2, client.options.maxBufferFrames),
                fps: min(max(client.options.fps, 1), 15),
                debug: client.options.debug
            )
            let screen = client.screen
            recorder.screenName = { screen.name }
            recorder.imageBudget = client.replay.budget
            self.recorder = recorder
        } else {
            recorder = nil
        }
        vitalsHost = client.vitals.map { UIKitVitalsHost(frames: $0.recordsMetrics) }
    }

    static func install(_ client: TracewayClient) {
        let work = {
            current?.removeObservers()
            current?.vitalsHost?.uninstall()
            let hooks = PlatformHooks(client: client)
            current = hooks
            hooks.addObservers()
            // The hang watchdog takes the main thread's stack from another
            // thread; it is noted here, on it.
            MainThreadStack.prepare()
            client.runForeground(UIApplication.shared.applicationState != .background)
            client.screen.viewportProvider = PlatformHooks.viewport
            client.screen.viewport = PlatformHooks.viewport()
            if !swizzled {
                swizzled = true
                UIApplication.tracewaySwizzleSendEvent()
                UIViewController.tracewaySwizzleViewDidAppear()
            }
            if client.vitals?.recordsMetrics == true, !displaySwizzled {
                displaySwizzled = true
                UIViewController.tracewaySwizzleDisplayStart()
            }
            if let recorder = hooks.recorder { client.attachReplaySource(recorder) }
            client.vitals?.start(host: hooks.vitalsHost)
            if client.options.debug, client.options.captureNavigation { hintSwiftUIScreens(client) }
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    /// With `debug`, once, 10 s after the start: a SwiftUI app whose window
    /// holds a hosting controller records no screens by itself.
    private static func hintSwiftUIScreens(_ client: TracewayClient) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak client] in
            guarded("screen hint") {
                guard let client = client, client === TracewayClient.shared, !client.isShutdown,
                      client.screen.name == nil,
                      let root = WireframeRoots.screenWindow(of: WireframeRoots.visibleWindows())?.rootViewController,
                      String(describing: type(of: root)).hasPrefix("UIHostingController<")
                else { return }
                Log.debugOnce("swiftui screens", "no screen recorded yet: this is a SwiftUI app, add "
                    + ".tracewayScreen(\"/path\") to its screens")
            }
        }
    }

    /// Set once a `.tracewayScreen` modifier has named a screen: from then
    /// on hosting controllers are not screens, so an explicit name is not
    /// replaced a moment later by the hosting controller's. Main thread.
    static var explicitScreens = false

    static func uninstall(for clientId: ObjectIdentifier) {
        guard let hooks = current, hooks.clientId == clientId else { return }
        hooks.removeObservers()
        hooks.vitalsHost?.uninstall()
        hooks.recorder?.stop()
        current = nil
    }

    static var active: PlatformHooks? {
        guard let hooks = current, let client = hooks.client, client === TracewayClient.shared,
              !client.isShutdown
        else { return nil }
        return hooks
    }

    var activeClient: TracewayClient? { PlatformHooks.active === self ? client : nil }

    private func addObservers() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in guarded("didEnterBackground") { self?.didEnterBackground() } })
        observers.append(center.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in guarded("willEnterForeground") { self?.client?.appResumed() } })
        observers.append(center.addObserver(
            forName: UIApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guarded("willTerminate") {
                self?.client?.appTerminating()
                self?.client?.flush(timeout: 2)
            }
        })
    }

    private func removeObservers() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
    }

    /// The app may be killed in the background: what is ready leaves under
    /// a background task, and the buffer is saved. The task is held by the
    /// flush's completion and by its expiration handler, not by the hooks:
    /// it ends even when the hooks are gone first (a shutdown, or a newer
    /// client), since iOS kills an app whose task is still open when its
    /// time runs out.
    private func didEnterBackground() {
        guard let client = client else { return }
        let task: BackgroundTask
        if let open = backgroundTask, open.isOpen {
            task = open
        } else {
            task = BackgroundTask(PlatformHooks.backgroundTasks, name: "Traceway flush")
            backgroundTask = task
        }
        client.appPaused { DispatchQueue.main.async { task.end() } }
    }

    // MARK: - Navigation

    /// The size of the key window (or the first one in front), in points,
    /// as issues carry it (`viewport`). Main thread only.
    static func viewport() -> String? {
        let windows = WireframeRoots.visibleWindows()
        guard let window = WireframeRoots.screenWindow(of: windows) else { return nil }
        let size = window.bounds.size
        guard size.width > 0, size.height > 0 else { return nil }
        return "\(Int(size.width.rounded()))x\(Int(size.height.rounded()))"
    }

    private var lastScreen: (path: String, at: TimeInterval)?

    func viewDidAppear(_ controller: UIViewController) {
        guard let client = activeClient, client.options.captureNavigation,
              let path = PlatformHooks.screenPath(for: controller)
        else { return }
        let now = Date().timeIntervalSince1970
        if let last = lastScreen, last.path == path, now - last.at < 0.3 { return }
        let from = lastScreen?.path
        lastScreen = (path, now)
        let action = controller.isMovingToParent || controller.isBeingPresented ? "push" : "pop"
        if let viewport = PlatformHooks.viewport() { client.screen.viewport = viewport }
        let displayStart = controller.tracewayDisplayStartMs
        controller.tracewayDisplayStartMs = nil
        client.recordNavigation(to: path, action: action, from: from, time: Date(), displayStartMs: displayStart)
    }

    /// A view controller begins to load its view (`load`) or to appear: the
    /// start of its time to initial display. A view loaded long before it
    /// appears counts from its appearance.
    func displayStarting(_ controller: UIViewController, load: Bool) {
        guard let client = activeClient, client.vitals?.recordsMetrics == true else { return }
        let now = Clock.nowMs()
        if load {
            controller.tracewayDisplayStartMs = now
        } else if let start = controller.tracewayDisplayStartMs, now - start <= 10_000 {
            return
        } else {
            controller.tracewayDisplayStartMs = now
        }
    }

    /// `/` and the name of a screen's view controller, or of the SwiftUI
    /// view a hosting controller shows. Containers, child view controllers
    /// and the system's own controllers are not screens.
    static func screenPath(for controller: UIViewController) -> String? {
        if controller is UINavigationController || controller is UITabBarController
            || controller is UISplitViewController || controller is UIPageViewController {
            return nil
        }
        if let parent = controller.parent,
           !(parent is UINavigationController || parent is UITabBarController
               || parent is UISplitViewController || parent is UIPageViewController) {
            return nil
        }
        let name = String(describing: type(of: controller))
        if name.hasPrefix("UIHostingController<") {
            if explicitScreens { return nil }
            var inner = String(name.dropFirst("UIHostingController<".count).dropLast())
            while inner.hasPrefix("ModifiedContent<") {
                inner = String(inner.dropFirst("ModifiedContent<".count))
                if let comma = inner.firstIndex(of: ",") { inner = String(inner[..<comma]) }
            }
            let type = selectorTypeName(inner)
            return type.isEmpty || type == "AnyView" ? nil : "/" + type
        }
        if name.hasPrefix("_") { return nil }
        if Bundle(for: type(of: controller)).bundlePath.contains("/System/Library/") { return nil }
        let type = selectorTypeName(name)
        return type.isEmpty ? nil : "/" + type
    }
}

/// Turns touches into replay pointer events and taps.
final class TouchTracker {
    private var touches: [ObjectIdentifier: (start: CGPoint, time: TimeInterval, id: Int)] = [:]
    private var nextId = 1

    func handle(_ event: UIEvent, hooks: PlatformHooks) {
        guard event.type == .touches, let all = event.allTouches, let client = hooks.activeClient else { return }
        // The replay's pointers, in the coordinates of the window its frames
        // show; taps below are hit-tested in their own window.
        hooks.recorder?.handle(event)
        for touch in all {
            guard let window = touch.window else { continue }
            let point = touch.location(in: window)
            let key = ObjectIdentifier(touch)
            switch touch.phase {
            case .began:
                let id = nextId
                nextId += 1
                touches[key] = (point, touch.timestamp, id)
                client.markActivity()
            case .ended:
                guard let began = touches.removeValue(forKey: key) else { continue }
                let tap = TapGesture.isTap(
                    dx: Double(point.x - began.start.x), dy: Double(point.y - began.start.y),
                    durationMs: Int64(((touch.timestamp - began.time) * 1000).rounded())
                )
                if tap { self.tap(at: point, in: window, view: touch.view, client: client) }
            case .cancelled:
                touches.removeValue(forKey: key)
            default:
                break
            }
        }
        if touches.count > 32 { touches.removeAll() }
    }

    private func tap(at point: CGPoint, in window: UIWindow, view: UIView?, client: TracewayClient) {
        let (recordTaps, selectors) = client.interaction.snapshot
        guard recordTaps || !selectors.isEmpty else { return }
        guard let path = UIViewPath.at(point, in: window) ?? view.map({ UIViewPath(leaf: $0) }) else { return }
        let target = recordTaps ? describeTap(path) : nil
        var matched: Set<String> = []
        for selector in selectors where ViewSelector.parse(selector)?.matches(path) == true {
            matched.insert(selector)
        }
        client.recordTap(target: target, x: Double(point.x), y: Double(point.y), matched: matched)
    }
}

/// `UIApplication`'s background tasks.
protocol BackgroundTasks: AnyObject {
    func begin(name: String, expiration: @escaping () -> Void) -> UIBackgroundTaskIdentifier
    func end(_ task: UIBackgroundTaskIdentifier)
}

final class ApplicationBackgroundTasks: BackgroundTasks {
    func begin(name: String, expiration: @escaping () -> Void) -> UIBackgroundTaskIdentifier {
        UIApplication.shared.beginBackgroundTask(withName: name, expirationHandler: expiration)
    }

    func end(_ task: UIBackgroundTaskIdentifier) {
        UIApplication.shared.endBackgroundTask(task)
    }
}

/// One background task, ended exactly once: by whichever comes first of
/// the work finishing and the system's expiration. Main thread only.
final class BackgroundTask {
    private let tasks: BackgroundTasks
    private var id: UIBackgroundTaskIdentifier = .invalid

    init(_ tasks: BackgroundTasks, name: String) {
        self.tasks = tasks
        // The handler holds the task until it ends; then UIKit lets it go.
        id = tasks.begin(name: name) { self.end() }
    }

    var isOpen: Bool { id != .invalid }

    func end() {
        guard id != .invalid else { return }
        let ending = id
        id = .invalid
        tasks.end(ending)
    }
}

/// Method swizzling that keeps the method it replaces whole: the
/// replacement runs Traceway's part, then calls the implementation that was
/// there before, once, with the selector it was called with. A hook
/// installed before Traceway's that relies on `_cmd` (forwarding to
/// `forwardInvocation:`, swizzlers keyed by selector) keeps working, which
/// exchanging implementations with a `traceway_` method broke.
enum Swizzle {
    private static let lock = NSLock()
    private static var done = Set<String>()

    /// Replaces `selector` on `cls` with the block `make` returns for the
    /// original implementation. Once per class and selector; false when the
    /// class has no such method or it was replaced already. A method `cls`
    /// only inherits is added to it, so the superclass keeps its own.
    @discardableResult
    static func replace(_ cls: AnyClass, _ selector: Selector, _ make: (IMP) -> Any) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let key = "\(NSStringFromClass(cls)) \(NSStringFromSelector(selector))"
        guard !done.contains(key), let method = class_getInstanceMethod(cls, selector) else { return false }
        done.insert(key)
        let original = method_getImplementation(method)
        let replacement = imp_implementationWithBlock(make(original))
        if !class_addMethod(cls, selector, replacement, method_getTypeEncoding(method)) {
            method_setImplementation(method, replacement)
        }
        return true
    }
}

private typealias VoidIMP = @convention(c) (AnyObject, Selector) -> Void
private typealias BoolIMP = @convention(c) (AnyObject, Selector, Bool) -> Void
private typealias EventIMP = @convention(c) (AnyObject, Selector, UIEvent) -> Void

extension UIApplication {
    static func tracewaySwizzleSendEvent(on cls: UIApplication.Type = UIApplication.self) {
        let selector = #selector(UIApplication.sendEvent(_:))
        Swizzle.replace(cls, selector) { original in
            let call = unsafeBitCast(original, to: EventIMP.self)
            let block: @convention(block) (AnyObject, UIEvent) -> Void = { application, event in
                // Before the event is delivered, so the tap names what was
                // under the finger, not what the tap brings up.
                guarded("sendEvent") {
                    if let hooks = PlatformHooks.active { hooks.touches.handle(event, hooks: hooks) }
                }
                call(application, selector, event)
            }
            return block
        }
    }
}

private var displayStartKey: UInt8 = 0

extension UIViewController {
    /// When this controller began to load or appear (Unix ms), until its
    /// `viewDidAppear` hands it to the navigation.
    var tracewayDisplayStartMs: Int64? {
        get { (objc_getAssociatedObject(self, &displayStartKey) as? NSNumber)?.int64Value }
        set {
            objc_setAssociatedObject(self, &displayStartKey, newValue.map { NSNumber(value: $0) },
                                     .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }

    static func tracewaySwizzleDisplayStart(on cls: UIViewController.Type = UIViewController.self) {
        let didLoad = #selector(UIViewController.viewDidLoad)
        Swizzle.replace(cls, didLoad) { original in
            let call = unsafeBitCast(original, to: VoidIMP.self)
            let block: @convention(block) (AnyObject) -> Void = { controller in
                guarded("viewDidLoad") {
                    if let controller = controller as? UIViewController {
                        PlatformHooks.active?.displayStarting(controller, load: true)
                    }
                }
                call(controller, didLoad)
            }
            return block
        }
        let willAppear = #selector(UIViewController.viewWillAppear(_:))
        Swizzle.replace(cls, willAppear) { original in
            let call = unsafeBitCast(original, to: BoolIMP.self)
            let block: @convention(block) (AnyObject, Bool) -> Void = { controller, animated in
                guarded("viewWillAppear") {
                    if let controller = controller as? UIViewController {
                        PlatformHooks.active?.displayStarting(controller, load: false)
                    }
                }
                call(controller, willAppear, animated)
            }
            return block
        }
    }

    static func tracewaySwizzleViewDidAppear(on cls: UIViewController.Type = UIViewController.self) {
        let selector = #selector(UIViewController.viewDidAppear(_:))
        Swizzle.replace(cls, selector) { original in
            let call = unsafeBitCast(original, to: BoolIMP.self)
            let block: @convention(block) (AnyObject, Bool) -> Void = { controller, animated in
                call(controller, selector, animated)
                guarded("viewDidAppear") {
                    if let controller = controller as? UIViewController {
                        PlatformHooks.active?.viewDidAppear(controller)
                    }
                }
            }
            return block
        }
    }
}

#if canImport(SwiftUI)
@available(iOS 13.0, *)
private struct TracewayScreenModifier: ViewModifier {
    let path: String
    let route: String?
    @State private var appeared = false

    func body(content: Content) -> some View {
        content.onAppear {
            guarded("tracewayScreen") {
                PlatformHooks.explicitScreens = true
                let navigation = ScreenAppearance.of(path, again: appeared, shown: TracewayClient.shared?.screen.name)
                appeared = true
                Traceway.recordNavigation(path, action: navigation.action, from: navigation.from, route: route)
            }
        }
    }
}

@available(iOS 13.0, *)
public extension View {
    /// Names this view as the screen `path` (`/orders/42`), with its route
    /// template when the router knows it (`/orders/:id`): each time it
    /// appears it is recorded as a navigation, `push` the first time and
    /// `pop` when it comes back, from the screen shown before. Navigation
    /// triggers match it, and the replay shows it as the address. Once a
    /// screen is named this way, hosting controllers are no longer recorded
    /// as screens of their own.
    func tracewayScreen(_ path: String, route: String? = nil) -> some View {
        modifier(TracewayScreenModifier(path: path, route: route))
    }
}
#endif
#endif

#if canImport(URLSessionInstrumentation)
/// URLSession requests as client spans, by the official opentelemetry-swift
/// instrumentation with the stable HTTP semantic conventions. Installed once
/// per process, with a tracer that is the running client's at each request:
/// requests are recorded while a client runs with `captureNetwork`, also
/// one started after a shutdown, never the SDK's own.
enum NetworkInstrumentation {
    private static var instrumentation: URLSessionInstrumentation?
    private static let lock = NSLock()

    static func install() {
        lock.lock()
        defer { lock.unlock() }
        guard instrumentation == nil else { return }
        let tracer = CurrentClientTracer { TracewayClient.shared?.tracer }
        let configuration = URLSessionInstrumentationConfiguration(
            shouldInstrument: { request in
                guard let client = TracewayClient.shared, client.options.captureNetwork,
                      let url = request.url?.absoluteString
                else { return false }
                return !client.isOwnRequest(url)
            },
            shouldInjectTracingHeaders: { request in
                guard let client = TracewayClient.shared, let url = request.url?.absoluteString else { return false }
                return client.propagatesTrace(to: url)
            },
            receivedResponse: { response, dataOrFile, span in
                guard let http = response as? HTTPURLResponse else { return }
                if http.statusCode >= 400 {
                    span.setAttribute(key: "error.type", value: .string("\(http.statusCode)"))
                }
                // `app.request.bytes` without a Content-Length header: what arrived.
                if http.value(forHTTPHeaderField: "Content-Length") == nil, let data = dataOrFile as? Data {
                    span.setAttribute(key: "http.response.body.size", value: .int(data.count))
                }
            },
            receivedError: { error, _, _, span in
                span.setAttribute(key: "error.type", value: .string(String(describing: type(of: error))))
            },
            tracer: tracer,
            semanticConvention: .stable
        )
        instrumentation = URLSessionInstrumentation(configuration: configuration)
    }
}
#endif
