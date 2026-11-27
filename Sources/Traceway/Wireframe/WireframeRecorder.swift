import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// One captured screen: the wireframe DOM of what the app showed.
struct WireframeFrame {
    /// The element holding the screen (`screenNodeId`); nil while nothing is
    /// on screen (the app is in the background, the recorder stopped).
    var screen: VNode?
    /// Size of the screen in points.
    var width: Double
    var height: Double
    var timestampMs: Int64
    /// The screen on top when the frame was taken, the replay's address.
    var href: String?
}

/// Records the screen as a wireframe in rrweb's format, the same as the
/// Flutter SDK's wireframe recorder: the app's view hierarchy becomes an
/// HTML document, and what changes from frame to frame becomes rrweb
/// mutations. The dashboard replays it with the same player as a browser
/// session.
///
/// On iOS the screen is captured on the main thread up to `fps` times a
/// second. Frames share the nodes that did not change, and a frame that
/// shows the same as the last is not kept, so the ring of the last
/// `maxFrames` frames stays small. A clip is assembled when it is asked
/// for: a full snapshot of the screen as it was when the clip starts, then
/// the mutations and touches up to its end, so every clip and segment plays
/// on its own.
///
/// Frames and touches arrive on the main thread; the `ReplaySource` calls
/// come from the client's queue. A lock keeps them apart.
final class WireframeRecorder: ReplaySource {
    let fps: Int
    let debug: Bool
    private let now: () -> Int64
    private let maxFrames: Int

    private let lock = NSLock()
    private var frames: [WireframeFrame] = []
    private var pointers: [WireframePointer] = []
    private var lastMoveMs: [Int: Int64] = [:]
    private var running = false
    private var paused = false
    private var maskInputs = true
    private var images: TracewayImagePolicy = .off
    private var resetRequested = false

    static let maxPointers = 4000
    static let moveIntervalMs: Int64 = 50

    /// The screen on top, shown as the replay's address. Called on the main
    /// thread at every capture.
    var screenName: (() -> String?)?

    #if canImport(UIKit)
    /// The capture behind the frames, made at the first tick. Main thread
    /// only.
    private(set) var capture: WireframeCapture?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var keyboardFrame: CGRect?
    private var touchStarts: [Int: (x: Double, y: Double, ms: Int64)] = [:]
    private var captureSeconds: Double = 0
    private var captureCount = 0

    /// The windows recorded, back to front; the app's visible windows when
    /// nil. Main thread only.
    var windows: (() -> [UIWindow])?
    #endif

    /// Counts the bytes of the pictures inlined per session. Set once, on
    /// the main thread, before the recorder starts.
    var imageBudget: CollectionBudget?

    init(maxFrames: Int = 150, fps: Int = 4, debug: Bool = false, now: @escaping () -> Int64 = Clock.nowMs) {
        self.maxFrames = max(2, maxFrames)
        self.fps = min(max(fps, 1), 15)
        self.debug = debug
        self.now = now
    }

    /// Masks what is typed into text fields, as rrweb's `maskAllInputs`
    /// does. On by default; remote settings can switch it off
    /// (`replay.maskAllInputs`).
    var maskAllInputs: Bool {
        get {
            lock.lock(); defer { lock.unlock() }
            return maskInputs
        }
        set {
            lock.lock(); defer { lock.unlock() }
            if maskInputs != newValue {
                maskInputs = newValue
                resetRequested = true
            }
        }
    }

    /// When the pictures of image views are inlined (`replay.images` held at
    /// `TracewayOptions.replayImages`). Off by default: the client sets it
    /// from the settings. Decided at each capture.
    var imagePolicy: TracewayImagePolicy {
        get {
            lock.lock(); defer { lock.unlock() }
            return images
        }
        set {
            lock.lock(); defer { lock.unlock() }
            images = newValue
        }
    }

    /// Number of distinct screens held; never more than the ring's capacity.
    var bufferedFrameCount: Int {
        lock.lock(); defer { lock.unlock() }
        return frames.count
    }

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    func start() {
        lock.lock()
        if running {
            lock.unlock()
            return
        }
        running = true
        paused = false
        lock.unlock()
        #if canImport(UIKit)
        onMain { self.startOnMain() }
        #endif
    }

    func stop() {
        lock.lock()
        if !running {
            lock.unlock()
            return
        }
        running = false
        lock.unlock()
        #if canImport(UIKit)
        onMain { self.stopOnMain() }
        #endif
        pushBlank()
    }

    func clearBuffer() {
        lock.lock(); defer { lock.unlock() }
        frames.removeAll()
        pointers.removeAll()
        lastMoveMs.removeAll()
        resetRequested = true
    }

    // MARK: - Frames

    /// Keeps a captured frame, unless it shows the same as the last one.
    func push(_ frame: WireframeFrame) {
        lock.lock(); defer { lock.unlock() }
        if let last = frames.last, last.screen === frame.screen,
           last.width == frame.width, last.height == frame.height {
            return
        }
        frames.append(frame)
        if frames.count > maxFrames { frames.removeFirst(frames.count - maxFrames) }
    }

    /// Nothing is on screen from now on: the app went to the background or
    /// the recorder stopped.
    func pushBlank() {
        lock.lock(); defer { lock.unlock() }
        pushBlankLocked()
    }

    private func pushBlankLocked() {
        guard let last = frames.last, last.screen != nil else { return }
        frames.append(WireframeFrame(
            screen: nil, width: last.width, height: last.height, timestampMs: now(), href: last.href
        ))
        if frames.count > maxFrames { frames.removeFirst(frames.count - maxFrames) }
    }

    // MARK: - Pointers

    /// A finger (`touch`) or a pointer went down at `x`, `y`, in points of
    /// the screen the frames are captured in.
    func pointerDown(pointer: Int, x: Double, y: Double, touch: Bool) {
        add(WireframePointer(kind: .down, x: x, y: y, timestampMs: now(), touch: touch))
    }

    /// Moves are kept at most every 50 ms per pointer.
    func pointerMove(pointer: Int, x: Double, y: Double, touch: Bool) {
        let ms = now()
        lock.lock()
        if let last = lastMoveMs[pointer], ms - last < WireframeRecorder.moveIntervalMs {
            lock.unlock()
            return
        }
        lastMoveMs[pointer] = ms
        lock.unlock()
        add(WireframePointer(kind: .move, x: x, y: y, timestampMs: ms, touch: touch))
    }

    /// `tap` when the pointer went up where it went down, a click.
    func pointerUp(pointer: Int, x: Double, y: Double, touch: Bool, tap: Bool) {
        lock.lock()
        lastMoveMs.removeValue(forKey: pointer)
        lock.unlock()
        add(WireframePointer(kind: tap ? .tap : .up, x: x, y: y, timestampMs: now(), touch: touch))
    }

    func pointerCancel(pointer: Int, x: Double, y: Double, touch: Bool) {
        lock.lock()
        lastMoveMs.removeValue(forKey: pointer)
        lock.unlock()
        add(WireframePointer(kind: .cancel, x: x, y: y, timestampMs: now(), touch: touch))
    }

    private func add(_ pointer: WireframePointer) {
        lock.lock(); defer { lock.unlock() }
        guard running, !paused else { return }
        pointers.append(pointer)
        if pointers.count > WireframeRecorder.maxPointers {
            pointers.removeFirst(pointers.count - WireframeRecorder.maxPointers)
        }
    }

    // MARK: - Clips

    func hasFrames(sinceMs: Int64?, untilMs: Int64?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let since = sinceMs, let until = untilMs, since >= until { return false }
        if let since = sinceMs {
            let at = WireframeRecorder.frameIndex(frames, at: since)
            if at >= 0, frames[at].screen != nil { return true }
        }
        return frames.contains { f in
            f.screen != nil
                && (sinceMs == nil || f.timestampMs >= sinceMs!)
                && (untilMs == nil || f.timestampMs < untilMs!)
        }
    }

    func captureRecording(clipId: String, sinceMs: Int64?, untilMs: Int64?) -> SessionRecordingPayload? {
        lock.lock()
        let frames = self.frames
        let pointers = self.pointers
        lock.unlock()

        let end = untilMs ?? now()
        // An empty or inverted window holds nothing to replay.
        if let since = sinceMs, since >= end { return nil }
        var index = sinceMs == nil ? -1 : WireframeRecorder.frameIndex(frames, at: sinceMs!)
        let start: Int64
        if index >= 0, frames[index].screen != nil {
            start = sinceMs!
        } else {
            index = -1
            for (i, f) in frames.enumerated() {
                if f.screen == nil { continue }
                if let since = sinceMs, f.timestampMs < since { continue }
                if f.timestampMs >= end { break }
                index = i
                break
            }
            if index < 0 { return nil }
            start = frames[index].timestampMs
        }

        var screenEvents: [JSON] = []
        func snapshot(_ frame: WireframeFrame, at ms: Int64) {
            screenEvents.append([
                "type": 4,
                "data": [
                    "href": .string(frame.href ?? "/"),
                    "width": JSON(Int(frame.width.rounded())),
                    "height": JSON(Int(frame.height.rounded())),
                ],
                "timestamp": JSON(ms),
            ])
            screenEvents.append([
                "type": 2,
                "data": [
                    "node": serializeDocument(frame.screen ?? WireframeRecorder.awayScreen(frame.width, frame.height)),
                    "initialOffset": ["left": 0, "top": 0],
                ],
                "timestamp": JSON(ms),
            ])
        }

        var previous = frames[index]
        snapshot(previous, at: start)
        var i = index + 1
        while i < frames.count {
            let frame = frames[i]
            if frame.timestampMs >= end { break }
            if let before = previous.screen, let after = frame.screen,
               previous.width == frame.width, previous.height == frame.height {
                if let mutation = diffScreens(before, after) {
                    screenEvents.append(["type": 3, "data": mutation, "timestamp": JSON(frame.timestampMs)])
                }
            } else {
                snapshot(frame, at: frame.timestampMs)
            }
            previous = frame
            i += 1
        }

        var pointerEvents: [JSON] = []
        for p in pointers where p.timestampMs >= start && p.timestampMs < end {
            pointerEvents.append(contentsOf: WireframeRecorder.events(of: p))
        }
        var events = WireframeRecorder.merge(screenEvents, pointerEvents)
        if let last = events.last?["timestamp"]?.number, Int64(last) < end {
            // The screen stayed as it was until the clip ends: the replay's
            // timeline runs to then.
            events.append([
                "type": 5,
                "data": ["tag": "traceway.end", "payload": [:]],
                "timestamp": JSON(end),
            ])
        }
        let bytes = JSON.array(events).encoded().utf8.count
        if debug {
            NSLog("[Traceway] wireframe clip of %ld events, %ldKB, %.1fs", events.count, bytes / 1024,
                  Double(end - start) / 1000)
        }
        return SessionRecordingPayload(clipId: clipId, events: events, startedAtMs: start, endedAtMs: end, approxBytes: bytes)
    }

    /// The index of the frame showing at `at`: the last one taken at or
    /// before it, or -1.
    static func frameIndex(_ frames: [WireframeFrame], at: Int64) -> Int {
        var i = frames.count - 1
        while i >= 0 {
            if frames[i].timestampMs <= at { return i }
            i -= 1
        }
        return -1
    }

    static func merge(_ a: [JSON], _ b: [JSON]) -> [JSON] {
        func time(_ e: JSON) -> Double { e["timestamp"]?.number ?? 0 }
        var out: [JSON] = []
        out.reserveCapacity(a.count + b.count)
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if j >= b.count || (i < a.count && time(a[i]) <= time(b[j])) {
                out.append(a[i])
                i += 1
            } else {
                out.append(b[j])
                j += 1
            }
        }
        return out
    }

    static func events(of p: WireframePointer) -> [JSON] {
        let x = JSON(Int(p.x.rounded())), y = JSON(Int(p.y.rounded()))
        let ms = JSON(p.timestampMs)
        func interaction(_ type: Int) -> JSON {
            [
                "type": 3,
                "data": [
                    "source": 2,
                    "type": JSON(type),
                    "id": JSON(screenNodeId),
                    "x": x,
                    "y": y,
                    "pointerType": p.touch ? 2 : 0,
                ],
                "timestamp": ms,
            ]
        }
        switch p.kind {
        case .down:
            return [interaction(p.touch ? 7 : 1)]
        case .move:
            return [[
                "type": 3,
                "data": [
                    "source": p.touch ? 6 : 1,
                    "positions": [["x": x, "y": y, "id": JSON(screenNodeId), "timeOffset": 0]],
                ],
                "timestamp": ms,
            ]]
        case .up:
            return [interaction(p.touch ? 9 : 0)]
        case .tap:
            return [interaction(p.touch ? 9 : 0), interaction(2)]
        case .cancel:
            return [interaction(p.touch ? 10 : 0)]
        }
    }

    /// What the replay shows while the app is in the background.
    static func awayScreen(_ width: Double, _ height: Double) -> VNode {
        VNode(
            element: screenNodeId,
            tag: "div",
            attributes: [
                "id": "tw",
                "style": screenNodeStyle(width: width.rounded(), height: height.rounded()) + "background:#1e1e1e",
            ],
            children: [
                VNode(
                    element: awayScreenTextBoxId,
                    tag: "div",
                    attributes: ["style": "left:0;top:45%;width:100%;text-align:center;color:#9e9e9e;font-size:14px"],
                    children: [VNode(text: awayScreenTextId, text: "App in the background")]
                ),
            ]
        )
    }

    // MARK: - UIKit

    #if canImport(UIKit)
    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    private func setPaused(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        paused = value
        if value { pushBlankLocked() }
    }

    private func startOnMain() {
        guard isRunning, timer == nil else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.setPaused(true)
        })
        observers.append(center.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            self.setPaused(false)
            self.tick()
        })
        observers.append(center.addObserver(
            forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main
        ) { [weak self] note in
            self?.keyboardChanged(note)
        })
        observers.append(center.addObserver(
            forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.keyboardFrame = nil
        })
        setPaused(UIApplication.shared.applicationState == .background)
        let timer = Timer(timeInterval: 1.0 / Double(fps), repeats: true) { [weak self] _ in
            self?.tick()
        }
        timer.tolerance = 0.25 / Double(fps)
        // `.common` keeps capturing while a scroll view tracks a finger.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        if debug { NSLog("[Traceway] wireframe recorder started (up to %ldfps)", fps) }
        tick()
    }

    private func stopOnMain() {
        timer?.invalidate()
        timer = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        keyboardFrame = nil
        touchStarts.removeAll()
    }

    private func keyboardChanged(_ note: Notification) {
        guard let value = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue else { return }
        let frame = value.cgRectValue
        let screen = capture?.screenWindow?.screen.bounds
        keyboardFrame = frame.isEmpty || (screen != nil && frame.minY >= screen!.maxY) ? nil : frame
    }

    /// Captures a frame now, off the timer. Main thread only.
    func captureNow() { tick() }

    private func tick() {
        lock.lock()
        let active = running && !paused
        let mask = maskInputs
        let policy = images
        let reset = resetRequested
        resetRequested = false
        lock.unlock()
        guard active else { return }
        let capture = self.capture ?? WireframeCapture()
        self.capture = capture
        if reset { capture.reset() }
        capture.maskAllInputs = mask
        capture.imagePolicy = policy
        if capture.images.budget == nil { capture.images.budget = imageBudget }
        let started = CFAbsoluteTimeGetCurrent()
        let frame: WireframeFrame?
        if let windows = windows?() {
            frame = capture.capture(windows: windows, timestampMs: now(), href: screenName?(), keyboardFrame: keyboardFrame)
        } else {
            frame = capture.captureScreen(timestampMs: now(), href: screenName?(), keyboardFrame: keyboardFrame)
        }
        captureSeconds += CFAbsoluteTimeGetCurrent() - started
        captureCount += 1
        if debug, captureCount % 100 == 0 {
            NSLog("[Traceway] wireframe capture takes %.2f ms on average", captureSeconds / Double(captureCount) * 1000)
        }
        if let frame = frame { push(frame) }
    }

    /// Feeds the touches of an event the app received to the recording, as
    /// rrweb touch events. Call it on the main thread for every event
    /// `UIApplication.sendEvent` or `UIWindow.sendEvent` sees.
    func handle(_ event: UIEvent) {
        guard event.type == .touches, let touches = event.allTouches, isRunning else { return }
        for touch in touches {
            let point = position(of: touch)
            let x = Double(point.x), y = Double(point.y)
            let pointer = ObjectIdentifier(touch).hashValue
            var isTouch = true
            if #available(iOS 13.4, *) { isTouch = touch.type != .indirectPointer }
            switch touch.phase {
            case .began:
                touchStarts[pointer] = (x, y, now())
                pointerDown(pointer: pointer, x: x, y: y, touch: isTouch)
            case .moved:
                pointerMove(pointer: pointer, x: x, y: y, touch: isTouch)
            case .ended:
                var tap = false
                if let start = touchStarts.removeValue(forKey: pointer) {
                    tap = TapGesture.isTap(dx: x - start.x, dy: y - start.y, durationMs: now() - start.ms)
                }
                pointerUp(pointer: pointer, x: x, y: y, touch: isTouch, tap: tap)
            case .cancelled:
                touchStarts.removeValue(forKey: pointer)
                pointerCancel(pointer: pointer, x: x, y: y, touch: isTouch)
            default:
                break
            }
        }
    }

    /// Where a touch is, in points of the screen the frames show.
    func position(of touch: UITouch) -> CGPoint {
        if let window = capture?.screenWindow {
            return touch.location(in: window)
        }
        return touch.location(in: nil)
    }
    #endif
}

struct WireframePointer {
    enum Kind { case down, move, up, tap, cancel }
    var kind: Kind
    var x: Double
    var y: Double
    var timestampMs: Int64
    var touch: Bool
}
