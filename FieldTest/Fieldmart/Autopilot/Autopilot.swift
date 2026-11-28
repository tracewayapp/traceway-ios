import UIKit
import FieldmartCore

/// With `-fmAutopilot 1` the app plays a reduced journey itself, with no
/// touches and no UI test attached (so accessibility stays off, H-I3): it
/// switches tabs, pushes screens, scrolls with `setContentOffset(_:animated:)`,
/// sets typed text one character at a time, and writes an `FM_CP` marker at
/// each checkpoint (the runner screenshots the Simulator when it sees one).
///
/// Screens register what an id does here only while the autopilot is on.
final class Autopilot {
    static let shared = Autopilot()

    private(set) var isOn = false
    weak var tabs: RootTabBarController?
    private var taps: [String: () -> Void] = [:]
    private var prefixTaps: [(prefix: String, action: (String) -> Void)] = []
    private var scrollViews: [String: WeakScroll] = [:]
    private var texts: [String: (String) -> Void] = [:]
    private var focusedText: String?
    private var typed: [String: String] = [:]
    private var t0: Date = Date()
    private var log: [String] = []

    private final class WeakScroll {
        weak var view: UIScrollView?
        init(_ view: UIScrollView) { self.view = view }
    }

    /// Called before any screen loads, so registrations are kept.
    func prepare(settings: LaunchSettings) {
        isOn = settings.autopilot
    }

    // MARK: - Registration (no-ops unless on)

    func tap(_ id: String, _ action: @escaping () -> Void) {
        guard isOn else { return }
        taps[id] = action
    }

    func tap(prefix: String, _ action: @escaping (String) -> Void) {
        guard isOn else { return }
        prefixTaps.removeAll { $0.prefix == prefix }
        prefixTaps.append((prefix, action))
    }

    func scroll(_ id: String, _ view: UIScrollView) {
        guard isOn else { return }
        scrollViews[id] = WeakScroll(view)
    }

    func text(_ id: String, _ set: @escaping (String) -> Void) {
        guard isOn else { return }
        texts[id] = set
    }

    // MARK: - Playing

    /// Starts the scenario at `FM_READY` (T0 = now).
    func begin(settings: LaunchSettings) {
        guard isOn else { return }
        guard let url = Bundle.main.url(forResource: "journey", withExtension: "json"),
              let data = try? Data(contentsOf: url), let journey = try? Journey.load(data) else {
            note("no journey.json in the app bundle")
            return
        }
        let name = settings.scenario ?? "S6"
        guard let found = journey.scenario(named: name) else {
            note("no scenario \(name)")
            return
        }
        let scenario = found.scenario
        t0 = Date()
        note("playing \(found.key), \(scenario.steps.count) steps")
        for (index, step) in scenario.steps.enumerated() where step.runs(on: "ios") {
            schedule(at: step.t) { [weak self] in self?.perform(step, index: index) }
        }
        schedule(at: scenario.durationMs) { [weak self] in
            AppEnvironment.shared.markers.write(.done)
            self?.writeLog(run: settings.run)
        }
    }

    private func schedule(at ms: Int, _ work: @escaping () -> Void) {
        let deadline = t0.addingTimeInterval(Double(ms) / 1000)
        let delay = max(0, deadline.timeIntervalSinceNow)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func perform(_ step: Step, index: Int) {
        let late = Int(-t0.addingTimeInterval(Double(step.t) / 1000).timeIntervalSinceNow * 1000)
        switch step.action {
        case .tap:
            guard let id = step.id else { return }
            note("\(index) tap \(id) late=\(late)")
            tap(id)
        case .fling:
            guard let id = step.id else { return }
            note("\(index) fling \(id) \(step.dir ?? "?") late=\(late)")
            fling(id, dir: step.dir ?? "up", distance: step.distance ?? 0.6)
        case .type:
            guard let text = step.text, let id = step.into ?? focusedText, let set = texts[id] else {
                note("\(index) type skipped (no field)")
                return
            }
            note("\(index) type \(text.count) chars into \(id) late=\(late)")
            let perChar = Double(step.perCharMs ?? 120) / 1000
            let base = typed[id] ?? ""
            for offset in 0..<text.count {
                let value = base + String(text.prefix(offset + 1))
                DispatchQueue.main.asyncAfter(deadline: .now() + perChar * Double(offset)) { [weak self] in
                    self?.typed[id] = value
                    set(value)
                }
            }
        case .paste:
            guard let text = step.text, let id = step.into ?? focusedText, let set = texts[id] else { return }
            typed[id] = (typed[id] ?? "") + text
            set(typed[id] ?? text)
        case .key:
            if step.name == "back" { back() }
        case .checkpoint:
            let name = step.name ?? "cp\(index)"
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(step.settle) / 1000) {
                AppEnvironment.shared.markers.write(.checkpoint, detail: name)
            }
        case .mark:
            AppEnvironment.shared.markers.write(.checkpoint, detail: "mark:" + (step.name ?? "\(index)"))
        default:
            note("\(index) \(step.action.name) skipped")
        }
    }

    private func tap(_ id: String) {
        if texts[id] != nil {
            focusedText = id
            return
        }
        switch id {
        case "fm-nav-home": tabs?.select(.home)
        case "fm-nav-markets": tabs?.select(.markets)
        case "fm-nav-feed": tabs?.select(.feed)
        case "fm-nav-checkout": tabs?.select(.checkout)
        case "fm-nav-more": tabs?.select(.more)
        case "fm-nav-back": back()
        default:
            if let action = taps[id] {
                action()
            } else if let match = prefixTaps.first(where: { id.hasPrefix($0.prefix) }) {
                match.action(String(id.dropFirst(match.prefix.count)))
            } else {
                note("tap \(id): nothing registered")
            }
        }
    }

    private func back() {
        let selected = tabs?.selectedViewController as? UINavigationController
        if let presented = selected?.presentedViewController {
            presented.dismiss(animated: true)
        } else {
            selected?.popViewController(animated: true)
        }
    }

    /// `dir` is the direction the finger moves: `up` scrolls the content
    /// towards its end.
    private func fling(_ id: String, dir: String, distance: Double) {
        guard let view = scrollViews[id]?.view, view.window != nil else {
            note("fling \(id): no scroll view on screen")
            return
        }
        let size = view.bounds.size
        var offset = view.contentOffset
        let inset = view.adjustedContentInset
        // A fling travels about three times the finger's distance.
        let travel = CGFloat(distance) * 3
        switch dir {
        case "up": offset.y += size.height * travel
        case "down": offset.y -= size.height * travel
        case "left": offset.x += size.width * travel
        case "right": offset.x -= size.width * travel
        default: break
        }
        let maxX = max(-inset.left, view.contentSize.width - size.width + inset.right)
        let maxY = max(-inset.top, view.contentSize.height - size.height + inset.bottom)
        offset.x = min(max(-inset.left, offset.x), maxX)
        offset.y = min(max(-inset.top, offset.y), maxY)
        view.setContentOffset(offset, animated: true)
    }

    private func note(_ line: String) {
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        log.append("\(ms) \(line)")
    }

    private func writeLog(run: String) {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = documents.appendingPathComponent("fm-autopilot-\(run).log")
        try? log.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
