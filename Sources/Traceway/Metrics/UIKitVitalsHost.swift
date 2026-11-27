#if canImport(UIKit)
import UIKit

/// The UIKit side of `AppVitals`: a display link for frames and for the
/// frame a start or a screen waits for, the app's lifecycle notifications,
/// and the main queue for the hang watchdog. Everything but `requestDraw`,
/// `cancelDraw` and `postToMain` runs on the main thread.
final class UIKitVitalsHost: VitalsHost {
    private weak var vitals: AppVitals?
    private var link: CADisplayLink?
    private var observers: [NSObjectProtocol] = []
    /// The timestamps of the last frame and of the vsync it expected next.
    private var lastTimestamp: CFTimeInterval = 0
    private var lastTarget: CFTimeInterval = 0
    private let drawPending = Locked(false)

    func install(_ vitals: AppVitals) {
        self.vitals = vitals
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.pauseFrames()
            self?.vitals?.lifecycleChanged(foreground: false)
        })
        observers.append(center.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.vitals?.lifecycleChanged(foreground: true)
            self?.resumeFrames()
        })
        observers.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.resumeFrames() })
        observers.append(center.addObserver(
            forName: UIScene.willConnectNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.vitals?.sceneConnected() })

        let link = CADisplayLink(target: DisplayLinkTarget(self), selector: #selector(DisplayLinkTarget.tick(_:)))
        link.add(to: .main, forMode: .common)
        link.isPaused = UIApplication.shared.applicationState == .background
        self.link = link
    }

    func uninstall() {
        let work = {
            for observer in self.observers { NotificationCenter.default.removeObserver(observer) }
            self.observers = []
            self.link?.invalidate()
            self.link = nil
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    func requestDraw() { drawPending.value = true }

    func cancelDraw() { drawPending.value = false }

    func postToMain(_ task: @escaping () -> Void) -> Bool {
        DispatchQueue.main.async(execute: task)
        return true
    }

    func checkLaunch(_ result: @escaping (LaunchInfo) -> Void) {
        // After the launch transaction: by then a launch for the UI has its
        // scene in the foreground.
        DispatchQueue.main.async { result(LaunchInfo(foreground: UIKitVitalsHost.launchedForUI())) }
    }

    func debuggerAttached() -> Bool { AppVitals.debuggerAttached() }

    static func launchedForUI() -> Bool {
        let application = UIApplication.shared
        if application.applicationState != .background { return true }
        return application.connectedScenes.contains {
            $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive
        }
    }

    private func pauseFrames() {
        link?.isPaused = true
        lastTimestamp = 0
        vitals?.framesPaused()
    }

    private func resumeFrames() {
        guard let link = link, link.isPaused else { return }
        lastTimestamp = 0
        link.isPaused = false
    }

    /// One display refresh. The time since the previous one, against the
    /// frame duration that one expected, says whether the main thread kept
    /// up.
    fileprivate func tick(_ link: CADisplayLink) {
        let timestamp = link.timestamp
        if lastTimestamp > 0, lastTarget > lastTimestamp {
            let intervalNs = Int64(((timestamp - lastTimestamp) * 1e9).rounded())
            let budgetNs = Int64(((lastTarget - lastTimestamp) * 1e9).rounded())
            vitals?.frame(FrameRules.classify(intervalNs: intervalNs, budgetNs: budgetNs))
        }
        lastTimestamp = timestamp
        lastTarget = link.targetTimestamp
        if drawPending.value, UIApplication.shared.applicationState == .active {
            drawPending.value = false
            vitals?.drawn()
        }
    }
}

/// Holds the host weakly: a display link retains its target until it is
/// invalidated.
private final class DisplayLinkTarget: NSObject {
    weak var host: UIKitVitalsHost?

    init(_ host: UIKitVitalsHost) { self.host = host }

    @objc func tick(_ link: CADisplayLink) {
        if let host = host { host.tick(link) } else { link.invalidate() }
    }
}
#endif
