#if canImport(UIKit)
import AVFoundation
import MapKit
import SwiftUI
import UIKit
import WebKit
@testable import Traceway

// The gallery's remaining scenarios: privacy masks, SwiftUI, native views,
// motion, right-to-left layout and dark mode.
extension GalleryScenes {
    // MARK: - 23 privacy: blank and blur masks, secure fields

    static let privacy = GalleryScenario(id: "privacy", title: "Privacy", build: {
        let page = Page("Privacy")
        page.loadViewIfNeeded()
        let blank = UIView()
        blank.backgroundColor = .secondarySystemBackground
        blank.tracewayPrivacyMask = .blank()
        let card = label("Card 4242 4242 4242 4242", size: 17)
        card.frame = CGRect(x: 12, y: 14, width: 300, height: 22)
        card.tag = 2301
        blank.addSubview(card)
        page.add(blank, height: 50)
        let blurred = UIView()
        blurred.backgroundColor = .systemGray6
        blurred.layer.cornerRadius = 10
        blurred.tracewayPrivacyMask = .blur
        let balance = label("Balance $12,345.67", size: 17)
        balance.frame = CGRect(x: 12, y: 14, width: 250, height: 22)
        balance.tag = 2302
        blurred.addSubview(balance)
        let avatar = UIImageView(image: UIImage(systemName: "person.fill"))
        avatar.frame = CGRect(x: 280, y: 10, width: 30, height: 30)
        blurred.addSubview(avatar)
        page.add(blurred, height: 50)
        let pin = UITextField()
        pin.isSecureTextEntry = true
        pin.text = "open-sesame"
        pin.borderStyle = .roundedRect
        page.add(pin, height: 36)
        let status = label("Public text stays", size: 17)
        status.tag = 2303
        page.add(status)
        return page
    }, script: { d, controller in
        for secret in ["4242 4242", "12,345.67", "open-sesame", "9876 5432", "99,000.01"] { d.secret(secret) }
        d.checkpoint(shows: ["Public text stays", "******* **********", String(repeating: "\u{2022}", count: 11)],
                     hides: ["4242", "12,345.67"])
        let view = controller.view!
        (view.viewWithTag(2301) as? UILabel)?.text = "Card 9876 5432 9876 5432"
        (view.viewWithTag(2302) as? UILabel)?.text = "Balance $99,000.01"
        (view.viewWithTag(2303) as? UILabel)?.text = "Public text changed"
        d.checkpoint("changed", shows: ["Public text changed", "******* **********"], hides: ["9876", "99,000.01"])
    })

    // MARK: - 24 declarative: a SwiftUI screen

    final class SwiftUIModel: ObservableObject {
        @Published var on = false
        @Published var count = 0
    }

    struct SwiftUIScreen: View {
        @ObservedObject var model: SwiftUIModel

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Declarative").font(.largeTitle.bold())
                    Text("Plain SwiftUI text")
                    Text("Secondary caption").font(.caption).foregroundColor(.secondary)
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 12).fill(Color.red).frame(width: 80, height: 50)
                        Circle().fill(Color.green).frame(width: 50, height: 50)
                        Capsule().stroke(Color.blue, lineWidth: 3).frame(width: 90, height: 40)
                        Image(systemName: "star.fill").foregroundColor(.yellow).font(.system(size: 30))
                    }
                    LinearGradient(colors: [.purple, .orange], startPoint: .leading, endPoint: .trailing)
                        .frame(height: 40).cornerRadius(8)
                    Toggle("Notifications", isOn: $model.on)
                    Button("Count \(model.count)") { model.count += 1 }
                        .buttonStyle(.borderedProminent)
                    Text("Masked in SwiftUI 555-0101").tracewayPrivacyMask()
                    ForEach(1..<16) { i in
                        HStack {
                            Text("List row \(i)")
                            Spacer()
                            Image(systemName: "chevron.right").foregroundColor(.secondary)
                        }
                        .padding(.vertical, 6)
                        Divider()
                    }
                }
                .padding(20)
            }
        }
    }

    static let swiftUIModel = SwiftUIModel()

    static let declarative = GalleryScenario(id: "declarative", title: "Declarative", build: {
        swiftUIModel.on = false
        swiftUIModel.count = 0
        return UIHostingController(rootView: SwiftUIScreen(model: swiftUIModel))
    }, script: { d, controller in
        d.secret("555-0101")
        // SwiftUI's text is readable only through accessibility, which iOS
        // fills in while an assistive technology runs; otherwise each text
        // is a bar where it is drawn.
        let readable = controller.view.accessibilityElementCount() > 0
            || !(controller.view.accessibilityElements?.isEmpty ?? true)
        d.checkpoint(shows: readable ? ["Declarative", "Plain SwiftUI text", "Notifications", "Count 0", "List row 1"] : [],
                     hides: ["555-0101"], settle: 0.9)
        swiftUIModel.on = true
        swiftUIModel.count = 1
        d.checkpoint("changed", shows: readable ? ["Count 1"] : [], hides: ["555-0101"], settle: 1.2)
        guard let scroll = find(UIScrollView.self, in: controller.view) else { return d.fail("no scroll view") }
        d.scroll(scroll, to: CGPoint(x: 0, y: max(0, scroll.contentSize.height - scroll.bounds.height)))
        d.checkpoint("scrolled", shows: readable ? ["List row 15"] : [], hides: readable ? ["Declarative"] : [], settle: 0.6)
    })

    // MARK: - 25 native: web, map and video placeholders, a view that draws itself

    /// A view whose layer is a video player's.
    final class VideoView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
    }

    static let native = GalleryScenario(id: "native", title: "Native", build: {
        let page = Page("Native views")
        page.loadViewIfNeeded()
        let web = WKWebView()
        web.tag = 2501
        page.add(web, height: 140)
        page.add(label("Web content is a placeholder", size: 15, color: .secondaryLabel))
        let map = MKMapView()
        map.tag = 2502
        page.add(map, height: 120)
        let video = VideoView()
        video.backgroundColor = .black
        page.add(video, height: 90)
        let drawn = DrawnView()
        page.add(drawn, height: 60)
        page.add(label("Drawn by the app itself", size: 15, color: .secondaryLabel))
        return page
    }, script: { d, controller in
        let mapRect = controller.view.viewWithTag(2502).map { $0.convert($0.bounds, to: nil) } ?? .zero
        d.checkpoint(shows: ["Web view", "Map", "Video", "Web content is a placeholder", "Drawn by the app itself"],
                     ignore: [mapRect], settle: 0.8)
        controller.view.viewWithTag(2501)?.isHidden = true
        let moved = controller.view.viewWithTag(2502).map { $0.convert($0.bounds, to: nil) } ?? .zero
        d.checkpoint("changed", shows: ["Map", "Video"], hides: ["Web view"], ignore: [moved], settle: 0.8)
    })

    /// Draws itself in draw(_:): its pixels are not recorded.
    final class DrawnView: UIView {
        override func draw(_ rect: CGRect) {
            UIColor.systemMint.setFill()
            UIBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 4), cornerRadius: 10).fill()
        }
    }

    // MARK: - 26 motion: an animation at its start, in flight and at its end

    static let motion = GalleryScenario(id: "motion", title: "Motion", build: {
        let page = Page("Motion")
        page.loadViewIfNeeded()
        let lane = UIView()
        lane.backgroundColor = .systemGray6
        page.add(lane, height: 60)
        let mover = box(.systemPink, "Moving", size: CGSize(width: 80, height: 40))
        mover.translatesAutoresizingMaskIntoConstraints = true
        mover.frame = CGRect(x: 0, y: 10, width: 80, height: 40)
        mover.tag = 1101
        lane.addSubview(mover)
        return page
    }, script: { d, controller in
        guard let mover = controller.view.viewWithTag(1101) else { return d.fail("no mover") }
        d.checkpoint("start", shows: ["Moving"])
        UIView.animate(withDuration: 1.2, delay: 0, options: [.curveLinear]) {
            mover.frame.origin.x = 240
        }
        d.wait(0.6)
        d.checkpoint("moving", shows: ["Moving"], settle: 0, minMutations: 2, measure: false)
        d.checkpoint("end", shows: ["Moving"], settle: 1.0)
    })

    // MARK: - 27 rtl: right-to-left layout, mirrored stacks, aligned text

    /// Shows its child laid out right to left, as an app in Hebrew or
    /// Arabic is.
    final class RightToLeft: UIViewController {
        let child: UIViewController

        init(_ child: UIViewController) {
            self.child = child
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override func viewDidLoad() {
            super.viewDidLoad()
            addChild(child)
            setOverrideTraitCollection(UITraitCollection(layoutDirection: .rightToLeft), forChild: child)
            child.view.frame = view.bounds
            child.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(child.view)
            child.didMove(toParent: self)
            RightToLeft.force(child.view)
        }

        static func force(_ view: UIView) {
            view.semanticContentAttribute = .forceRightToLeft
            view.subviews.forEach(force)
        }
    }

    static let rtl = GalleryScenario(id: "rtl", title: "Right to left", build: {
        let page = Page("ימין לשמאל")
        page.loadViewIfNeeded()
        page.add(label("שורה ראשונה של טקסט", size: 17))
        let natural = label("Natural alignment follows the layout", size: 15, color: .secondaryLabel)
        natural.textAlignment = .natural
        page.add(natural)
        page.row([chip("One", .systemRed), chip("Two", .systemGreen), chip("Three", .systemBlue)], spacing: 10)
        let field = UITextField()
        field.placeholder = "חיפוש"
        field.borderStyle = .roundedRect
        page.add(field, height: 36)
        let toggle = UISwitch()
        toggle.tag = 2701
        let caption = label("Switch at the start", size: 17)
        caption.tag = 2702
        page.row([caption, toggle])
        let leftAligned = label("Left stays left", size: 15)
        leftAligned.textAlignment = .left
        page.add(leftAligned)
        return RightToLeft(page)
    }, script: { d, controller in
        d.checkpoint(shows: ["ימין לשמאל", "שורה ראשונה של טקסט", "Natural alignment follows the layout", "One", "Three",
                             "חיפוש", "Switch at the start", "Left stays left"])
        let view = controller.view!
        (view.viewWithTag(2701) as? UISwitch)?.setOn(true, animated: true)
        (view.viewWithTag(2702) as? UILabel)?.text = "המתג פועל"
        d.checkpoint("changed", shows: ["המתג פועל", "One"], hides: ["Switch at the start"])
    })

    // MARK: - 28 dark mode: dynamic colors in the dark appearance, then light

    static let darkMode = GalleryScenario(id: "dark-mode", title: "Dark mode", build: {
        let page = Page("Dark mode")
        page.loadViewIfNeeded()
        page.add(label("Primary label color", size: 17))
        page.add(label("Secondary label color", size: 15, color: .secondaryLabel))
        let card = UIView()
        card.backgroundColor = .secondarySystemBackground
        card.layer.cornerRadius = 12
        let cardText = label("On a secondary background", size: 15)
        cardText.frame = CGRect(x: 14, y: 14, width: 300, height: 22)
        card.addSubview(cardText)
        page.add(card, height: 50)
        let separator = UIView()
        separator.backgroundColor = .separator
        page.add(separator, height: 1)
        var tinted = UIButton.Configuration.filled()
        tinted.title = "Tinted action"
        let toggle = UISwitch()
        toggle.isOn = true
        page.row([UIButton(configuration: tinted), toggle])
        let field = UITextField()
        field.placeholder = "Placeholder in the dark"
        field.borderStyle = .roundedRect
        page.add(field, height: 36)
        page.overrideUserInterfaceStyle = .dark
        return page
    }, script: { d, controller in
        d.checkpoint(shows: ["Primary label color", "Secondary label color", "On a secondary background", "Tinted action",
                             "Placeholder in the dark"])
        controller.overrideUserInterfaceStyle = .light
        d.checkpoint("light", shows: ["Primary label color", "Tinted action"])
    })
}
#endif
