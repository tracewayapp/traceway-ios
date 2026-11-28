import Foundation
import UIKit
import XCTest
import FieldmartCore

/// Plays one scenario of `journey.json` on the app with real input events
/// (`02-APP-SPEC.md` §5, `shared/journey.md`): every step starts at T0 + t
/// and never earlier; a step more than `rules.lateMs` late marks the run
/// `late`. T0 is the app's `FM_READY` marker, read from the marker file the
/// app writes to `FM_OUT`.
///
/// Writes `checkpoints.json`, `actions.json`, `driver.json`, `driver.log`
/// and, in evidence runs, `boxes.json`, `app/<checkpoint>.png` and
/// `tree/<checkpoint>.json`.
final class JourneyDriver {
    static let platform = "ios"

    let config: RunConfig
    let app: XCUIApplication
    let log: DriverLog
    private var scenarioKey = ""
    private var scenario: Scenario!
    private var steps: [Step] = []
    private var lateLimitMs: Int64 = StepTiming.lateLimitMs
    private var t0Ms: Int64 = 0
    private var t0Source = "none"
    private var timings: [StepTiming] = []
    private var notes: [String] = []
    private var checkpoints: [String] = []
    private var actions: [String] = []
    private var boxes: [String] = []
    private var frameCache: [String: CGRect] = [:]
    private var lastTextId: String?
    /// Checkpoints taken while a held drag keeps the finger down: their time.
    private var heldCheckpoints: [Int: Int64] = [:]
    /// The release steps a held drag already performed.
    private var releasedBy: [Int: Int] = [:]
    private var launchStartMs: Int64 = 0
    private var launchEndMs: Int64 = 0
    private var flags: Set<String> = []
    private var device: (width: CGFloat, height: CGFloat, scale: CGFloat) = (0, 0, 0)
    /// The top of the tab bar (it does not move), once known.
    private var tabBarTop: CGFloat?
    private var notedFallbacks: Set<String> = []
    private var tabBarLooked = false
    private var lastScene: Scene?
    /// When the last drag or fling ended: a list may still be moving.
    private var lastGestureEndMs: Int64 = 0

    init(config: RunConfig) {
        self.config = config
        app = XCUIApplication(bundleIdentifier: config.app)
        try? FileManager.default.createDirectory(at: config.out, withIntermediateDirectories: true)
        log = DriverLog(url: config.out.appendingPathComponent("driver.log"))
    }

    func run() throws {
        let journey = try config.loadJourney()
        guard let found = journey.scenario(named: config.scenario) else {
            throw DriverError("scenario \(config.scenario) is not in journey.json")
        }
        scenarioKey = found.key
        scenario = found.scenario
        steps = scenario.steps
        lateLimitMs = Int64(journey.lateMs)
        log.write("run \(config.run) scenario \(scenarioKey) variant \(config.variant) app \(config.app) "
            + "evidence \(config.evidence) type \(config.typeMode) quiescence \(config.quiescence)")
        if !scenario.exists(on: JourneyDriver.platform) { note("scenario \(scenarioKey) is not for iOS") }
        if config.quiescence == "skip" { log.write(Quiescence.skip()) }
        log.write(Quiescence.interruptionMethods())
        if config.evidence {
            for folder in ["app", "tree"] {
                try? FileManager.default.createDirectory(at: config.out.appendingPathComponent(folder),
                                                         withIntermediateDirectories: true)
            }
        }
        try? FileManager.default.removeItem(at: config.markersFile)

        app.launchArguments = config.launchArguments(scenarioSettings: scenario.settings)
        log.write("launch \(app.launchArguments.joined(separator: " "))")
        launchStartMs = FMClock.nowMs()
        app.launch()
        launchEndMs = FMClock.nowMs()
        log.write("launched in \(launchEndMs - launchStartMs) ms")
        findT0()

        for (index, step) in steps.enumerated() {
            guard step.runs(on: JourneyDriver.platform) else {
                log.write("step \(index) \(step.action.name) skipped: platforms \(step.platforms ?? [])")
                continue
            }
            let due = t0Ms + Int64(step.t)
            sleep(until: due)
            let start = FMClock.nowMs()
            perform(step, index: index)
            let end = FMClock.nowMs()
            let timing = StepTiming(index: index, action: step.action.name, dueEpochMs: due, startEpochMs: start,
                                    endEpochMs: end)
            timings.append(timing)
            // A waitFor is the one step allowed to wait on the app: the first
            // one starts when launch() returns, after FM_READY (T0).
            if timing.lateMs > lateLimitMs, step.action != .waitFor { flags.insert("late") }
            log.write("step \(index) \(step.action.name) \(step.id ?? step.name ?? step.into ?? "") t=\(step.t) "
                + "late=\(timing.lateMs) took=\(end - start)")
        }
        sleep(until: t0Ms + Int64(scenario.durationMs))
        if device.width == 0 { measureDevice() }
        standardEnding()
        writeOutputs()
    }

    private func measureDevice(_ known: Scene? = nil) {
        let window = (known ?? scene()).window ?? .zero
        device = (window.width, window.height, UIScreen.main.scale)
        log.write("device \(Out.number(window.width)) x \(Out.number(window.height)) @\(UIScreen.main.scale)x")
    }

    // MARK: - T0

    /// `FM_READY` from the marker file; else the first `waitFor` success.
    private func findT0() {
        // Up to 60 s: one first launch after install took 25 s to FM_READY.
        let deadline = FMClock.nowMs() + 60_000
        while FMClock.nowMs() < deadline {
            if let ready = readMarkers().first(where: { $0.kind == .ready }) {
                t0Ms = ready.epochMs
                t0Source = "FM_READY marker file"
                log.write("T0 \(t0Ms) from FM_READY (launch() returned \(launchEndMs - t0Ms) ms after it)")
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        if let first = steps.first(where: { $0.action == .waitFor }), let id = first.id {
            _ = element(id).waitForExistence(timeout: Double(first.timeoutMs ?? 15_000) / 1000)
        }
        t0Ms = FMClock.nowMs()
        t0Source = "first waitFor success (no FM_READY marker)"
        flags.insert("t0-approx")
        log.write("T0 \(t0Ms) approximated: no FM_READY in \(config.markersFile.path)")
    }

    private func readMarkers() -> [Marker] {
        guard let text = try? String(contentsOf: config.markersFile, encoding: .utf8) else { return [] }
        return Marker.parseFile(text)
    }

    // MARK: - Steps

    private func perform(_ step: Step, index: Int) {
        switch step.action {
        case .waitFor:
            guard let id = step.id else { return }
            let found = element(id).waitForExistence(timeout: Double(step.timeoutMs ?? 15_000) / 1000)
            if !found {
                flags.insert("waitFor-failed")
                note("waitFor \(id) timed out")
            }
            if device.width == 0 {
                // The screen and the tab bar, once, while nothing is due.
                let now = scene()
                measureDevice(now)
                if tabBarTop == nil { tabBarTop = now.tabBar?.minY }
            }
        case .tap:
            guard let id = step.id else { return }
            let revealed = step.reveal == true ? reveal(id) : nil
            tap(id, step: index, knownFrame: revealed)
        case .longPress:
            guard let id = step.id else { return }
            let revealed = step.reveal == true ? reveal(id) : nil
            guard let frame = revealed ?? resolveFrame(id) else { return }
            let started = FMClock.nowMs()
            let center = CGPoint(x: frame.midX, y: frame.midY)
            coordinate(center).press(forDuration: Double(step.ms ?? 800) / 1000)
            action("longPress", step: index, id: id, start: started, point: center)
        case .fling:
            guard let id = step.id else { return }
            if step.reveal == true { _ = reveal(id) }
            fling(id, dir: step.dir ?? "up", distance: step.distance ?? 0.6, durationMs: step.durationMs ?? 250, step: index)
        case .drag:
            guard let id = step.id else { return }
            if step.reveal == true { _ = reveal(id) }
            drag(step, id: id, index: index)
        case .release:
            if let drag = releasedBy[index] {
                log.write("release: the finger of step \(drag) was lifted at the end of its held drag")
            } else {
                note("release at step \(index) without a held drag")
            }
        case .type:
            type(step.text ?? "", into: step.into, perCharMs: step.perCharMs ?? 120, start: t0Ms + Int64(step.t),
                 step: index)
        case .paste:
            paste(step.text ?? "", into: step.into, step: index)
        case .key:
            key(step.name ?? step.value ?? "enter")
        case .pick:
            guard let id = step.id else { return }
            if step.reveal == true { _ = reveal(id) }
            pick(id, value: step.value ?? "", step: index)
        case .idle:
            break
        case .background:
            XCUIDevice.shared.press(.home)
        case .foreground:
            app.activate()
        case .checkpoint:
            checkpoint(step, index: index)
        case .mark:
            record(name: step.name ?? "mark-\(index)", step: step, epochMs: FMClock.nowMs(), screenshot: nil)
        case .fault:
            fault(mode: step.mode ?? "refuse", seconds: step.seconds ?? 0)
        case .kill:
            app.terminate()
        case .relaunch:
            app.launch()
        case .other(let raw):
            note("step \(index): unknown step kind \(raw), skipped")
        }
    }

    /// The element with automation id `id` (first match in the whole app).
    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// One look at the screen: a single accessibility snapshot of the app,
    /// from which every lookup of a step is answered. (A query costs a
    /// snapshot of the whole app each time, 0.3–1 s on the runner, and an
    /// element found by one query can be gone by the next.)
    struct Scene {
        var ids: [String: CGRect] = [:]
        var window: CGRect?
        var navigationBar: CGRect?
        var navigationButtons: [CGRect] = []
        var tabBar: CGRect?
        var tabButtons: [String: CGRect] = [:]
        var buttons: [String: CGRect] = [:]
        var keyboard: CGRect?
        /// The switch inside a toggle row (a SwiftUI toggle only reacts there).
        var switches: [String: CGRect] = [:]
        var switchValues: [String: String] = [:]
        var root: XCUIElementSnapshot?
    }

    private func scene() -> Scene {
        var scene = Scene()
        defer { lastScene = scene }
        guard let root = try? app.snapshot() else { return scene }
        scene.root = root
        func visit(_ node: XCUIElementSnapshot, inTabBar: Bool, inNavigationBar: Bool) {
            let frame = node.frame
            let type = node.elementType
            if !frame.isEmpty {
                let id = node.identifier
                if !id.isEmpty, scene.ids[id] == nil { scene.ids[id] = frame }
                if !id.isEmpty, type == .switch, scene.switches[id] == nil,
                   let inner = node.children.first(where: { $0.elementType == .switch && !$0.frame.isEmpty }) {
                    scene.switches[id] = inner.frame
                    scene.switchValues[id] = (node.value as? String) ?? "\(node.value ?? "")"
                }
                switch type {
                case .window where scene.window == nil: scene.window = frame
                case .navigationBar where scene.navigationBar == nil: scene.navigationBar = frame
                case .tabBar where scene.tabBar == nil: scene.tabBar = frame
                case .keyboard where scene.keyboard == nil: scene.keyboard = frame
                case .button:
                    let label = node.label
                    if inTabBar, !label.isEmpty, scene.tabButtons[label] == nil { scene.tabButtons[label] = frame }
                    if inNavigationBar { scene.navigationButtons.append(frame) }
                    if !label.isEmpty, scene.buttons[label] == nil { scene.buttons[label] = frame }
                default: break
                }
            }
            for child in node.children {
                visit(child, inTabBar: inTabBar || type == .tabBar,
                      inNavigationBar: inNavigationBar || type == .navigationBar)
            }
        }
        visit(root, inTabBar: false, inNavigationBar: false)
        return scene
    }

    /// The frame of `id` in `scene`, with the fallbacks for ids the system
    /// does not expose: tabs by their title, the back button, menu items by
    /// label.
    private func lookup(_ id: String, in scene: Scene) -> (frame: CGRect, how: String?)? {
        if let frame = scene.ids[id] { return (frame, nil) }
        if let title = FMText.tabs[id], let frame = scene.tabButtons[title] { return (frame, "tab found by its title") }
        if id == "fm-nav-back", let frame = scene.navigationButtons.first { return (frame, "first navigation bar button") }
        if id.hasPrefix("fm-checkout-menu-item-"), let index = Int(id.dropFirst("fm-checkout-menu-item-".count)),
           index >= 0, index < FMText.menuItems.count, let frame = scene.buttons[FMText.menuItems[index]] {
            return (frame, "menu item found by label")
        }
        return nil
    }

    /// The frame of `id`, looking again for up to a second.
    private func resolveFrame(_ id: String) -> CGRect? {
        let deadline = Date().addingTimeInterval(1)
        repeat {
            if let found = lookup(id, in: scene()) {
                if let how = found.how, !notedFallbacks.contains(id) {
                    notedFallbacks.insert(id)
                    log.write("\(id): \(how)")
                }
                return found.frame
            }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        flags.insert("element-missing")
        note("element \(id) not found")
        return nil
    }

    /// A real tap at the element's centre (a coordinate tap: it does not
    /// need the element to still be there when the finger lands).
    private func tap(_ id: String, step: Int, knownFrame: CGRect? = nil) {
        guard var frame = knownFrame ?? resolveFrame(id) else { return }
        if let inner = lastScene?.switches[id], frame.contains(CGPoint(x: inner.midX, y: inner.midY)) { frame = inner }
        // The keyboard's window reaches the bottom of the screen (its
        // accessibility frame stops above the home indicator area).
        if let keyboard = lastScene?.keyboard, frame.midY >= keyboard.minY {
            // The keyboard covers it (a tab after typing): a short drag down on
            // the screen above the keyboard dismisses it, as a user would.
            let x = keyboard.midX
            let from = CGPoint(x: x, y: max(150, keyboard.minY - 160))
            coordinate(from).press(forDuration: 0.05, thenDragTo: coordinate(CGPoint(x: x, y: from.y + 100)),
                                   withVelocity: XCUIGestureVelocity(rawValue: 700), thenHoldForDuration: 0.35)
            lastGestureEndMs = FMClock.nowMs()
            note("tap \(id): under the keyboard, keyboard dismissed with a drag first")
            if let again = resolveFrame(id) { frame = again }
        }
        // The middle of the part that is on screen.
        let screen = CGRect(x: 0, y: 0, width: device.width, height: device.height)
        let onScreen = device.width > 0 ? frame.intersection(screen) : frame
        let target = onScreen.isNull || onScreen.isEmpty ? frame : onScreen
        let center = CGPoint(x: target.midX, y: target.midY)
        let started = FMClock.nowMs()
        coordinate(center).tap()
        action("tap", step: step, id: id, start: started, point: center)
        frameCache.removeAll()
        lastTextId = id
        if let before = lastScene?.switchValues[id] {
            // A toggle that did not change (seen once in six smoke runs, with a
            // keyboard up): one more tap, noted.
            Thread.sleep(forTimeInterval: 0.3)
            if let after = scene().switchValues[id], after == before {
                note("tap \(id): the switch stayed \(before), tapped again")
                coordinate(center).tap()
                action("tap", step: step, id: id, start: FMClock.nowMs(), point: center)
            }
        }
    }

    // MARK: - Reveal

    /// The scroll container an id lives in (vertical, then horizontal).
    private static func containers(for id: String) -> (vertical: String?, horizontal: String?) {
        if id.hasPrefix("fm-home-chip-") { return ("fm-home-grid", "fm-home-chips") }
        if id.hasPrefix("fm-home-deal-") { return ("fm-home-grid", "fm-home-deals") }
        if id.hasPrefix("fm-home-") && id != "fm-home-logo" && id != "fm-home-search" && id != "fm-home-cart" {
            return ("fm-home-grid", nil)
        }
        if id.hasPrefix("fm-product-") && id != "fm-product-add" { return ("fm-product-reviews", nil) }
        if id.hasPrefix("fm-markets-row-") { return ("fm-markets-watchlist", nil) }
        if id.hasPrefix("fm-feed-row-") { return ("fm-feed-list", nil) }
        if id.hasPrefix("fm-search-result-") { return ("fm-search-results", nil) }
        if id.hasPrefix("fm-diag-") { return ("fm-diag-list", nil) }
        if id.hasPrefix("fm-more-") { return ("fm-more-list", nil) }
        if id.hasPrefix("fm-checkout-terms-") || id.hasPrefix("fm-checkout-edit-")
            || id.hasPrefix("fm-checkout-country-") || id.hasPrefix("fm-checkout-date-") {
            return (nil, nil)
        }
        if id.hasPrefix("fm-checkout-") { return ("fm-checkout-form", nil) }
        return (nil, nil)
    }

    /// What covers the screen while a reveal runs: the navigation bar's
    /// bottom, and the top of the tab bar and of Product's sticky bar.
    private struct Bars {
        var top: CGFloat = 0
        var bottom: CGFloat = .greatestFiniteMagnitude
    }

    private func bars(for id: String, in scene: Scene) -> Bars {
        var bars = Bars()
        if let navigation = scene.navigationBar { bars.top = navigation.maxY }
        if tabBarTop == nil { tabBarTop = scene.tabBar?.minY }
        bars.bottom = tabBarTop ?? .greatestFiniteMagnitude
        if id.hasPrefix("fm-product-"), let add = scene.ids["fm-product-add"] {
            bars.bottom = min(bars.bottom, add.minY - 14)
        }
        return bars
    }

    private func currentTabBarTop() -> CGFloat {
        if tabBarTop == nil, !tabBarLooked {
            tabBarLooked = true
            tabBarTop = scene().tabBar?.minY
        }
        return tabBarTop ?? .greatestFiniteMagnitude
    }

    /// The part of `container` the user can see: not under the bars or the keyboard.
    private func visibleArea(of container: CGRect, bars: Bars, keyboardTop: CGFloat?) -> CGRect {
        let top = max(container.minY, bars.top)
        var bottom = min(container.maxY, bars.bottom)
        if let keyboard = keyboardTop, keyboard > top { bottom = min(bottom, keyboard) }
        return CGRect(x: container.minX, y: top, width: container.width, height: max(0, bottom - top))
    }

    /// Makes `id` fully visible (`journey.md` rules: a drag of its scroll
    /// container, which also dismisses a keyboard that covers it). An
    /// element that does not exist yet (a lazy list's row) is searched for by
    /// dragging towards the end of the list.
    @discardableResult
    private func reveal(_ id: String) -> CGRect? {
        let started = FMClock.nowMs()
        let (vertical, horizontal) = JourneyDriver.containers(for: id)
        var drags = 0
        var now = scene()
        if let containerId = vertical, containerId != id, let containerFrame = now.ids[containerId] {
            // Drags of at most half the visible list, so no row passes unseen:
            // towards the end while the row does not exist yet (a lazy list
            // creates it), back when a drag took it past the edge, and back
            // after eight drags without it. A drag also dismisses the keyboard
            // (the lists dismiss it on drag).
            var direction: CGFloat = -1
            var lastDy: CGFloat = 0
            var seen = false
            var previous: CGRect?
            var looks = 0
            while drags < 14, FMClock.nowMs() - started < 10_000 {
                let area = visibleArea(of: containerFrame, bars: bars(for: id, in: now),
                                       keyboardTop: now.keyboard?.minY).insetBy(dx: 0, dy: 4)
                var dy: CGFloat
                if let frame = now.ids[id] {
                    if frame.minY >= area.minY && frame.maxY <= area.maxY {
                        // In view; done once the list has stopped (a tap on a moving
                        // list only stops it: the fourth smoke run missed product 17).
                        let still = previous.map { abs($0.minY - frame.minY) < 1 }
                            ?? (drags == 0 && FMClock.nowMs() - lastGestureEndMs > 3000)
                        if still || looks >= 4 { break }
                        previous = frame
                        looks += 1
                        Thread.sleep(forTimeInterval: 0.15)
                        now = scene()
                        continue
                    }
                    previous = nil
                    seen = true
                    dy = frame.maxY > area.maxY ? -(frame.maxY - area.maxY + 24) : (area.minY - frame.minY + 24)
                } else {
                    if seen && lastDy != 0 {
                        direction = lastDy < 0 ? 1 : -1
                    } else if drags == 8 {
                        direction = -direction
                    }
                    dy = direction * area.height * 0.5
                }
                dy = max(-area.height * 0.5, min(area.height * 0.5, dy))
                dragContainer(area, dy: dy)
                lastDy = dy
                drags += 1
                now = scene()
            }
        }
        if let containerId = horizontal, let containerFrame = now.ids[containerId] {
            var sideDrags = 0
            while sideDrags < 4, let frame = now.ids[id] {
                let area = containerFrame.insetBy(dx: 4, dy: 0)
                if frame.minX >= area.minX && frame.maxX <= area.maxX { break }
                let delta = frame.maxX > area.maxX ? -(frame.maxX - area.maxX + 24) : (area.minX - frame.minX + 24)
                dragContainer(area, dx: delta)
                sideDrags += 1
                drags += 1
                now = scene()
            }
            // The row must have stopped too.
            var looks = 0
            while sideDrags > 0, looks < 4, let before = now.ids[id] {
                Thread.sleep(forTimeInterval: 0.15)
                now = scene()
                looks += 1
                if let after = now.ids[id], abs(after.minX - before.minX) < 1 { break }
            }
        }
        if drags > 0 {
            frameCache.removeAll()
            log.write("reveal \(id): \(drags) drag(s), \(FMClock.nowMs() - started) ms")
        }
        guard let final = lookup(id, in: now)?.frame else {
            flags.insert("reveal-failed")
            note("reveal \(id): not found after \(drags) drag(s)")
            return nil
        }
        return final
    }

    /// A drag with the finger held at the end, so the content stops where it
    /// was dragged to (no fling). `dy` < 0 moves the finger up (towards the
    /// end of a list).
    private func dragContainer(_ area: CGRect, dx: CGFloat = 0, dy: CGFloat = 0) {
        let maxDy = max(40, area.height - 40)
        let maxDx = max(40, area.width - 40)
        let moveY = max(-maxDy, min(maxDy, dy))
        let moveX = max(-maxDx, min(maxDx, dx))
        let start = CGPoint(x: area.midX - moveX / 2, y: area.midY - moveY / 2)
        let end = CGPoint(x: start.x + moveX, y: start.y + moveY)
        // Slow, and held still before the lift, so the list stops where the
        // finger stops: at 2,500 pt/s with a 0.12 s hold the list flung on
        // and the row went by (second smoke run).
        coordinate(start).press(forDuration: 0.05, thenDragTo: coordinate(end),
                                withVelocity: XCUIGestureVelocity(rawValue: 700), thenHoldForDuration: 0.35)
        lastGestureEndMs = FMClock.nowMs()
    }

    // MARK: - Gestures

    private func frame(_ id: String) -> CGRect? {
        if let cached = frameCache[id] { return cached }
        guard let frame = resolveFrame(id) else { return nil }
        frameCache[id] = frame
        return frame
    }

    /// Points inside `frame`, kept above the tab bar.
    private func clamp(_ point: CGPoint, in frame: CGRect) -> CGPoint {
        let bottom = min(frame.maxY - 6, currentTabBarTop() - 10)
        return CGPoint(x: min(max(point.x, frame.minX + 6), frame.maxX - 6),
                       y: min(max(point.y, frame.minY + 6), max(frame.minY + 6, bottom)))
    }

    private func coordinate(_ point: CGPoint) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0)).withOffset(CGVector(dx: point.x, dy: point.y))
    }

    /// `dir` is the direction the finger moves: `up` scrolls a list towards
    /// its end. The swipe ends while moving, so the list keeps going.
    private func fling(_ id: String, dir: String, distance: Double, durationMs: Int, step: Int) {
        guard let frame = frame(id) else { return }
        let fraction = CGFloat(max(0.05, min(0.95, distance)))
        let mid = CGPoint(x: frame.midX, y: frame.midY)
        var start = mid
        var end = mid
        switch dir {
        case "up":
            start.y += frame.height * fraction / 2
            end.y -= frame.height * fraction / 2
        case "down":
            start.y -= frame.height * fraction / 2
            end.y += frame.height * fraction / 2
        case "left":
            start.x += frame.width * fraction / 2
            end.x -= frame.width * fraction / 2
        default:
            start.x -= frame.width * fraction / 2
            end.x += frame.width * fraction / 2
        }
        start = clamp(start, in: frame)
        end = clamp(end, in: frame)
        let length = hypot(end.x - start.x, end.y - start.y)
        let velocity = max(400, length / CGFloat(max(50, durationMs)) * 1000)
        let started = FMClock.nowMs()
        coordinate(start).press(forDuration: 0.01, thenDragTo: coordinate(end),
                                withVelocity: XCUIGestureVelocity(rawValue: velocity), thenHoldForDuration: 0)
        lastGestureEndMs = FMClock.nowMs()
        action("fling", step: step, id: id, start: started, point: start)
    }

    /// A slow drag with the finger held. `hold: true` keeps the finger down
    /// until the next `release` step: XCUITest cannot hold across calls, so
    /// the drag's own hold lasts until the release time, and a checkpoint
    /// with `during: "drag"` in between is recorded at its planned time (its
    /// picture comes from the screen video).
    private func drag(_ step: Step, id: String, index: Int) {
        guard let frame = frame(id) else { return }
        let from = step.from ?? FractionPoint(x: 0.2, y: 0.5)
        let to = step.to ?? FractionPoint(x: 0.8, y: 0.5)
        let start = clamp(CGPoint(x: frame.minX + frame.width * CGFloat(from.x),
                                  y: frame.minY + frame.height * CGFloat(from.y)), in: frame)
        let end = clamp(CGPoint(x: frame.minX + frame.width * CGFloat(to.x),
                                y: frame.minY + frame.height * CGFloat(to.y)), in: frame)
        let durationMs = step.durationMs ?? 1000
        let pressMs = 300
        var holdMs = step.holdMs ?? 0
        if step.hold == true, let release = steps[(index + 1)...].firstIndex(where: { $0.action == .release }) {
            // Lift the finger at the release step's time.
            let liftAt = t0Ms + Int64(steps[release].t)
            let moveEnds = FMClock.nowMs() + Int64(pressMs + durationMs)
            holdMs = max(0, Int(liftAt - moveEnds))
            releasedBy[release] = index
            for between in (index + 1)..<release where steps[between].action == .checkpoint {
                heldCheckpoints[between] = t0Ms + Int64(steps[between].t + steps[between].settle)
            }
        }
        let length = hypot(end.x - start.x, end.y - start.y)
        let velocity = max(20, length / CGFloat(max(100, durationMs)) * 1000)
        let started = FMClock.nowMs()
        coordinate(start).press(forDuration: Double(pressMs) / 1000, thenDragTo: coordinate(end),
                                withVelocity: XCUIGestureVelocity(rawValue: velocity),
                                thenHoldForDuration: Double(holdMs) / 1000)
        lastGestureEndMs = FMClock.nowMs()
        action("drag", step: index, id: id, start: started, point: start)
        if holdMs > 0 { log.write("drag \(id): finger held \(holdMs) ms") }
    }

    // MARK: - Keyboard

    /// Typing through the keyboard. `paced` (the default) types every
    /// character whose time has come in one `typeText` call, so XCUITest's
    /// cost per call does not push the typing behind the journey; `chars`
    /// types one character per call; `chunk` the whole text in one call.
    private func type(_ text: String, into: String?, perCharMs: Int, start: Int64, step: Int) {
        guard !text.isEmpty else { return }
        if let field = into, !app.keyboards.firstMatch.exists {
            note("type: no keyboard, tapping \(field) first")
            tap(field, step: step)
        }
        // Typing with no focused field fails the whole test in XCUITest.
        guard hasKeyboard() else {
            flags.insert("type-skipped")
            note("type \(into ?? ""): no keyboard, text not typed")
            return
        }
        let started = FMClock.nowMs()
        let characters = Array(text)
        switch config.typeMode {
        case "chunk":
            app.typeText(text)
        case "chars":
            for (offset, character) in characters.enumerated() {
                sleep(until: start + Int64(offset * perCharMs))
                app.typeText(String(character))
            }
        default:
            var typed = 0
            while typed < characters.count {
                sleep(until: start + Int64(typed * perCharMs))
                let due = Int((FMClock.nowMs() - start) / Int64(max(1, perCharMs))) + 1
                let upTo = min(characters.count, max(typed + 1, due))
                app.typeText(String(characters[typed..<upTo]))
                typed = upTo
            }
        }
        actions.append("{\"step\":\(step),\"do\":\"type\",\"epochMs\":\(started),\"endEpochMs\":\(FMClock.nowMs()),"
            + "\"text\":\(Out.string(text))" + (into.map { ",\"into\":\(Out.string($0))" } ?? "") + "}")
    }

    /// A large text in one action: the pasteboard and the edit menu's
    /// Paste; typed instead if the menu does not appear.
    private func paste(_ text: String, into: String?, step: Int) {
        UIPasteboard.general.string = text
        let started = FMClock.nowMs()
        if let id = into ?? lastTextId, let field = resolveFrame(id) {
            coordinate(CGPoint(x: field.midX, y: field.midY)).press(forDuration: 1.0)
            for candidate in [app.menuItems["Paste"].firstMatch, app.buttons["Paste"].firstMatch] {
                if candidate.waitForExistence(timeout: 1.5) {
                    candidate.tap()
                    actions.append("{\"step\":\(step),\"do\":\"paste\",\"epochMs\":\(started),\"endEpochMs\":\(FMClock.nowMs()),"
                        + "\"into\":\(Out.string(id))}")
                    return
                }
            }
        }
        guard hasKeyboard() else {
            flags.insert("type-skipped")
            note("paste \(into ?? ""): no Paste menu and no keyboard, text not entered")
            return
        }
        note("paste: no Paste menu, typed instead")
        flags.insert("paste-typed")
        app.typeText(text)
        actions.append("{\"step\":\(step),\"do\":\"type\",\"epochMs\":\(started),\"endEpochMs\":\(FMClock.nowMs()),"
            + "\"text\":\(Out.string(text))" + (into.map { ",\"into\":\(Out.string($0))" } ?? "") + "}")
    }

    private func hasKeyboard() -> Bool {
        app.keyboards.firstMatch.waitForExistence(timeout: 1)
    }

    private func key(_ name: String) {
        if name != "back", !hasKeyboard() {
            note("key \(name): no keyboard, not pressed")
            return
        }
        switch name {
        case "enter": app.typeText("\n")
        case "tab": app.typeText("\t")
        case "back": tap("fm-nav-back", step: -1)
        case "escape": app.typeText(XCUIKeyboardKey.escape.rawValue)
        default: note("key \(name) not supported")
        }
    }

    /// Opens a picker (unless one is open) and chooses `value` with its own
    /// wheel; then its Done button.
    private func pick(_ id: String, value: String, step: Int) {
        let wheels = app.pickerWheels
        if !wheels.firstMatch.exists { tap(id, step: step) }
        guard wheels.firstMatch.waitForExistence(timeout: 3) else {
            let option = app.buttons[value].firstMatch
            if option.waitForExistence(timeout: 1) {
                option.tap()
            } else {
                note("pick \(id): no picker and no option \(value)")
                flags.insert("pick-failed")
            }
            return
        }
        if id.contains("date") {
            pickDate(value)
        } else {
            wheels.firstMatch.adjust(toPickerWheelValue: value)
        }
        let done = element(id + "-done")
        if done.waitForExistence(timeout: 1) { done.tap() }
    }

    /// A date wheel: `value` is `+Nd` (N days after today) or a
    /// `yyyy-MM-dd` date. The Simulator's locale (en_US) orders the wheels
    /// month, day, year.
    private func pickDate(_ value: String) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        var target = today
        if value.hasPrefix("+") || value.hasSuffix("d"), let days = Step.dayOffset(value) {
            target = calendar.date(byAdding: .day, value: days, to: today) ?? today
        } else {
            let parser = DateFormatter()
            parser.locale = Locale(identifier: "en_US_POSIX")
            parser.dateFormat = "yyyy-MM-dd"
            target = parser.date(from: value) ?? today
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "MMMM"
        let month = formatter.string(from: target)
        let day = String(calendar.component(.day, from: target))
        let year = String(calendar.component(.year, from: target))
        let wheels = app.datePickers.firstMatch.pickerWheels
        let values = [month, day, year]
        for index in 0..<min(3, wheels.count) {
            wheels.element(boundBy: index).adjust(toPickerWheelValue: values[index])
        }
        note("pick date \(month) \(day) \(year)")
    }

    // MARK: - Checkpoints

    private func checkpoint(_ step: Step, index: Int) {
        let name = step.name ?? "cp-\(index)"
        if let held = heldCheckpoints[index] {
            // The finger was held through this moment; the picture comes from the video.
            record(name: name, step: step, epochMs: held, screenshot: config.evidence ? "video" : nil)
            log.write("checkpoint \(name) during the held drag, at its planned time")
            return
        }
        Thread.sleep(forTimeInterval: Double(step.settle) / 1000)
        let epochMs = FMClock.nowMs()
        guard config.evidence else {
            record(name: name, step: step, epochMs: epochMs, screenshot: nil)
            return
        }
        let shot = XCUIScreen.main.screenshot()
        let shotEnd = FMClock.nowMs()
        let file = "app/\(name).png"
        if let data = scaled(shot.image) {
            try? data.write(to: config.out.appendingPathComponent(file))
        }
        record(name: name, step: step, epochMs: epochMs, screenshot: file, shotEndMs: shotEnd)
        dumpTree(name: name, step: step)
    }

    private func scaled(_ image: UIImage) -> Data? {
        let logical = CGSize(width: image.size.width, height: image.size.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = config.shotScale
        let renderer = UIGraphicsImageRenderer(size: logical, format: format)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: logical)) }
        return resized.pngData()
    }

    private func record(name: String, step: Step, epochMs: Int64, screenshot: String?, shotEndMs: Int64? = nil) {
        var parts = [
            "\"name\":\(Out.string(name))",
            "\"epochMs\":\(epochMs)",
            "\"tMs\":\(epochMs - t0Ms)",
            "\"plannedTMs\":\(step.t + (step.action == .checkpoint ? step.settle : 0))",
            "\"scenario\":\(Out.string(scenarioKey))",
            "\"shows\":\(Out.strings(step.shows))",
            "\"hides\":\(Out.strings(step.hides))",
            "\"masked\":\(Out.strings(step.masked))",
        ]
        if let overlay = step.overlay { parts.append("\"overlay\":\(Out.string(overlay))") }
        if let list = step.list { parts.append("\"list\":\(Out.string(list))") }
        if let screen = step.screen { parts.append("\"screen\":\(Out.string(screen))") }
        if let during = step.during { parts.append("\"during\":\(Out.string(during))") }
        if step.action == .mark { parts.append("\"mark\":true") }
        if let screenshot = screenshot { parts.append("\"screenshot\":\(Out.string(screenshot))") }
        if let end = shotEndMs { parts.append("\"shotEndMs\":\(end)") }
        checkpoints.append("{" + parts.joined(separator: ",") + "}")
    }

    /// One accessibility snapshot (`boxes.json`, roles of the shared schema):
    /// the frame of the smallest element whose label or value holds each
    /// `shows` text, every `masked` id on screen, the first and last visible
    /// rows of the checkpoint's `list`, and the chart and hero regions; and
    /// the whole tree in `tree/<checkpoint>.json`.
    private func dumpTree(name: String, step: Step) {
        let now = scene()
        if device.width == 0 { measureDevice(now) }
        guard let root = now.root else {
            note("\(name): no accessibility snapshot")
            return
        }
        let shows = step.shows ?? []
        let screen = CGRect(x: 0, y: 0, width: device.width > 0 ? device.width : 10_000,
                            height: device.height > 0 ? device.height : 10_000)
        var nodes: [String] = []
        var matches: [String: (area: CGFloat, frame: CGRect)] = [:]
        var byId: [String: CGRect] = [:]
        var listRows: [(text: String, frame: CGRect)] = []
        func firstText(_ node: XCUIElementSnapshot) -> String? {
            if node.elementType == .staticText, !node.label.isEmpty { return node.label }
            for child in node.children {
                if let text = firstText(child) { return text }
            }
            return nil
        }
        func walk(_ node: XCUIElementSnapshot, depth: Int, inList: Bool) {
            let frame = node.frame
            let label = node.label
            let value = (node.value as? String) ?? ""
            let id = node.identifier
            if !frame.isEmpty, nodes.count < 4000 {
                nodes.append("{\"d\":\(depth),\"type\":\(Out.string(JourneyDriver.typeName(node.elementType))),"
                    + "\"id\":\(Out.string(id)),\"label\":\(Out.string(String(label.prefix(160)))),"
                    + "\"value\":\(Out.string(String(value.prefix(80)))),"
                    + "\"x\":\(Out.number(frame.minX)),\"y\":\(Out.number(frame.minY)),"
                    + "\"w\":\(Out.number(frame.width)),\"h\":\(Out.number(frame.height))}")
            }
            if !id.isEmpty, byId[id] == nil, !frame.isEmpty { byId[id] = frame }
            for text in shows where !frame.isEmpty && (label.contains(text) || value.contains(text)) {
                let area = frame.width * frame.height
                if let best = matches[text], best.area <= area { continue }
                matches[text] = (area, frame)
            }
            let isList = step.list != nil && id == step.list
            if inList, node.elementType == .cell || id.hasPrefix("fm-feed-row-") || id.hasPrefix("fm-markets-row-") {
                let visible = frame.intersection(screen)
                if visible.height >= frame.height * 0.5, let text = firstText(node) {
                    listRows.append((text, frame))
                }
                return
            }
            for child in node.children { walk(child, depth: depth + 1, inList: inList || isList) }
        }
        walk(root, depth: 0, inList: false)
        Out.write("[\n" + nodes.joined(separator: ",\n") + "\n]\n", to: config.out.appendingPathComponent("tree/\(name).json"))
        func box(_ frame: CGRect) -> String {
            "\"x\":\(Out.number(frame.minX)),\"y\":\(Out.number(frame.minY)),\"w\":\(Out.number(frame.width)),\"h\":\(Out.number(frame.height))"
        }
        var entries = shows.compactMap { text -> String? in
            guard let match = matches[text] else { return nil }
            return "{\"text\":\(Out.string(text)),\"role\":\"shows\",\(box(match.frame))}"
        }
        for id in step.masked ?? [] {
            guard let frame = byId[id], frame.intersects(screen) else { continue }
            entries.append("{\"id\":\(Out.string(id)),\"role\":\"masked\",\(box(frame))}")
        }
        let rows = listRows.sorted { $0.frame.minY < $1.frame.minY }
        if let first = rows.first {
            entries.append("{\"text\":\(Out.string(first.text)),\"role\":\"first-row\",\(box(first.frame))}")
        }
        if let last = rows.last, rows.count > 1 {
            entries.append("{\"text\":\(Out.string(last.text)),\"role\":\"last-row\",\(box(last.frame))}")
        }
        for id in ["fm-markets-chart", "fm-home-hero"] {
            guard let frame = byId[id], frame.intersects(screen) else { continue }
            entries.append("{\"id\":\(Out.string(id)),\"role\":\"region\",\(box(frame.intersection(screen)))}")
        }
        boxes.append("\(Out.string(name)):[" + entries.joined(separator: ",") + "]")
    }

    static func typeName(_ type: XCUIElement.ElementType) -> String {
        switch type {
        case .button: return "button"
        case .staticText: return "text"
        case .textField: return "textField"
        case .secureTextField: return "secureTextField"
        case .textView: return "textView"
        case .cell: return "cell"
        case .image: return "image"
        case .other: return "other"
        case .scrollView: return "scrollView"
        case .table: return "table"
        case .collectionView: return "collectionView"
        case .slider: return "slider"
        case .navigationBar: return "navigationBar"
        case .tabBar: return "tabBar"
        case .window: return "window"
        case .application: return "application"
        case .pickerWheel: return "pickerWheel"
        case .sheet: return "sheet"
        case .alert: return "alert"
        case .keyboard: return "keyboard"
        default: return "t\(type.rawValue)"
        }
    }

    // MARK: - Gateway, ending, outputs

    private func action(_ kind: String, step: Int, id: String, start: Int64, point: CGPoint) {
        actions.append("{\"step\":\(step),\"do\":\(Out.string(kind)),\"id\":\(Out.string(id)),\"epochMs\":\(start),"
            + "\"endEpochMs\":\(FMClock.nowMs()),\"x\":\(Out.number(point.x)),\"y\":\(Out.number(point.y))}")
    }

    private func fault(mode: String, seconds: Double) {
        guard let url = URL(string: config.gateway + "/ctl/fault") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{\"mode\":\(Out.string(mode)),\"seconds\":\(seconds)}".utf8)
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            NSLog("FMDRIVER fault %@ -> %ld %@", mode, status, error.map { "\($0)" } ?? "")
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 5)
    }

    /// `02-APP-SPEC.md` §5.5: Home, 5 s, force stop.
    private func standardEnding() {
        let start = FMClock.nowMs()
        XCUIDevice.shared.press(.home)
        log.write("ending: home pressed")
        Thread.sleep(forTimeInterval: 5)
        app.terminate()
        log.write("ending: terminated \(FMClock.nowMs() - start) ms after home")
    }

    private func writeOutputs() {
        Out.write("[\n" + checkpoints.joined(separator: ",\n") + "\n]\n",
                  to: config.out.appendingPathComponent("checkpoints.json"))
        Out.write("[\n" + actions.joined(separator: ",\n") + "\n]\n", to: config.out.appendingPathComponent("actions.json"))
        if config.evidence {
            Out.write("{\n" + boxes.joined(separator: ",\n") + "\n}\n", to: config.out.appendingPathComponent("boxes.json"))
        }
        let late = timings.filter { $0.action != "waitFor" }.map(\.lateMs)
        let stepLines = timings.map {
            "{\"i\":\($0.index),\"do\":\(Out.string($0.action)),\"dueEpochMs\":\($0.dueEpochMs),"
                + "\"startEpochMs\":\($0.startEpochMs),\"endEpochMs\":\($0.endEpochMs),\"lateMs\":\($0.lateMs)}"
        }
        let summary = [
            "\"run\":\(Out.string(config.run))",
            "\"scenario\":\(Out.string(scenarioKey))",
            "\"scenarioKey\":\(Out.string(scenarioKey))",
            "\"variant\":\(Out.string(config.variant))",
            "\"app\":\(Out.string(config.app))",
            "\"evidence\":\(config.evidence)",
            "\"device\":{\"width\":\(Out.number(device.width)),\"height\":\(Out.number(device.height)),"
                + "\"scale\":\(Out.number(device.scale))}",
            "\"t0EpochMs\":\(t0Ms)",
            "\"t0Source\":\(Out.string(t0Source))",
            "\"launchStartEpochMs\":\(launchStartMs)",
            "\"launchEndEpochMs\":\(launchEndMs)",
            "\"durationMs\":\(scenario.durationMs)",
            "\"endEpochMs\":\(t0Ms + Int64(scenario.durationMs))",
            "\"lateLimitMs\":\(lateLimitMs)",
            "\"typeMode\":\(Out.string(config.typeMode))",
            "\"quiescence\":\(Out.string(config.quiescence))",
            "\"maxLateMs\":\(late.max() ?? 0)",
            "\"stepsLate\":\(timings.filter { $0.lateMs > lateLimitMs && $0.action != "waitFor" }.count)",
            "\"flags\":\(Out.strings(flags.sorted()))",
            "\"notes\":\(Out.strings(notes))",
            "\"steps\":[\n" + stepLines.joined(separator: ",\n") + "\n]",
        ]
        Out.write("{\n" + summary.joined(separator: ",\n") + "\n}\n", to: config.out.appendingPathComponent("driver.json"))
        log.write("done: \(timings.count) steps, max late \(late.max() ?? 0) ms, flags \(flags.sorted())")
    }

    private func note(_ text: String) {
        notes.append(text)
        log.write("note: " + text)
    }

    private func sleep(until epochMs: Int64) {
        let wait = epochMs - FMClock.nowMs()
        if wait > 0 { Thread.sleep(forTimeInterval: Double(wait) / 1000) }
    }
}
