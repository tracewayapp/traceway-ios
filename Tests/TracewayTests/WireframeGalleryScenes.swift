#if canImport(UIKit)
import SwiftUI
import UIKit
@testable import Traceway

/// The scenarios of the wireframe gallery, in the order it visits them: the
/// 28 of CONTRACT §5.2, with the same names as the Android gallery. Every
/// text of a scenario is unique on its screen, so the checker can find the
/// replayed element of each measured label by its text.
enum GalleryScenes {
    static let all: [GalleryScenario] = [
        layout, positioning, transforms, clipping, stacks, constraints,
        text, richText, buttons, controls, forms, keyboard, images, imagesOff,
        lists, grids, carousel, navigation, tabs, dialogs, sheets, menus,
        privacy, declarative, native, motion, rtl, darkMode,
    ]

    // MARK: - Helpers

    /// A page: a scrollable column of rows under a title.
    final class Page: UIViewController {
        let heading: String
        let scroll = UIScrollView()
        let stack = UIStackView()

        init(_ heading: String) {
            self.heading = heading
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .systemBackground
            let title = UILabel()
            title.text = heading
            title.font = .systemFont(ofSize: 28, weight: .bold)
            stack.axis = .vertical
            stack.spacing = 14
            stack.alignment = .fill
            stack.addArrangedSubview(title)
            scroll.translatesAutoresizingMaskIntoConstraints = false
            stack.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(scroll)
            scroll.addSubview(stack)
            NSLayoutConstraint.activate([
                scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
                scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 12),
                stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
                stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 20),
                stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -20),
            ])
        }

        func add(_ view: UIView, height: CGFloat? = nil) {
            if let height = height {
                view.heightAnchor.constraint(equalToConstant: height).isActive = true
            }
            stack.addArrangedSubview(view)
        }

        /// Views side by side.
        func row(_ views: [UIView], spacing: CGFloat = 12, height: CGFloat? = nil) {
            let row = UIStackView(arrangedSubviews: views)
            row.axis = .horizontal
            row.spacing = spacing
            row.alignment = .center
            row.distribution = .fill
            add(row, height: height)
        }
    }

    /// A board: a title over a canvas whose views are placed by their own
    /// frames (or constraints inside them), for scenarios about geometry.
    final class Board: UIViewController {
        let heading: String
        let canvas = UIView()
        private let titleLabel = UILabel()

        init(_ heading: String) {
            self.heading = heading
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .systemBackground
            titleLabel.text = heading
            titleLabel.font = .systemFont(ofSize: 28, weight: .bold)
            view.addSubview(titleLabel)
            view.addSubview(canvas)
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            let top = view.safeAreaInsets.top
            titleLabel.frame = CGRect(x: 20, y: top + 12, width: view.bounds.width - 40, height: 34)
            canvas.frame = CGRect(x: 0, y: top + 60, width: view.bounds.width, height: view.bounds.height - top - 60)
        }

        /// Adds `view` to the canvas at `frame`.
        @discardableResult
        func place<V: UIView>(_ view: V, _ frame: CGRect) -> V {
            view.frame = frame
            canvas.addSubview(view)
            return view
        }
    }

    static func label(_ text: String, size: CGFloat = 17, weight: UIFont.Weight = .regular, color: UIColor = .label) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        return label
    }

    /// A label with a fill behind its centered text, as a chip.
    static func chip(_ text: String, _ color: UIColor, height: CGFloat = 36) -> UILabel {
        let chip = label(text, size: 15, weight: .semibold, color: .white)
        chip.backgroundColor = color
        chip.textAlignment = .center
        chip.translatesAutoresizingMaskIntoConstraints = false
        chip.heightAnchor.constraint(equalToConstant: height).isActive = true
        return chip
    }

    static func box(_ color: UIColor, _ text: String? = nil, size: CGSize) -> UIView {
        let view = UIView()
        view.backgroundColor = color
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: size.width).isActive = true
        view.heightAnchor.constraint(equalToConstant: size.height).isActive = true
        if let text = text {
            let label = GalleryScenes.label(text, size: 13, weight: .semibold, color: .white)
            label.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            ])
        }
        return view
    }

    /// A box placed by its bounds and center (so a transform turns it about
    /// its center) with a label filling it.
    static func tile(_ color: UIColor, _ text: String, size: CGSize, center: CGPoint, fontSize: CGFloat = 13) -> UIView {
        let view = UIView()
        view.backgroundColor = color
        view.bounds = CGRect(origin: .zero, size: size)
        view.center = center
        let title = label(text, size: fontSize, weight: .semibold, color: .white)
        title.textAlignment = .center
        title.frame = view.bounds
        view.addSubview(title)
        return view
    }

    /// A picture the app made itself: a gradient with a sun, like a photo.
    static let photo: UIImage = {
        let size = CGSize(width: 240, height: 150)
        return UIGraphicsImageRenderer(size: size).image { context in
            let colors = [UIColor(red: 0.35, green: 0.6, blue: 0.92, alpha: 1).cgColor,
                          UIColor(red: 0.75, green: 0.88, blue: 1, alpha: 1).cgColor]
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1]) {
                context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            }
            UIColor(red: 1, green: 0.84, blue: 0.25, alpha: 1).setFill()
            UIBezierPath(ovalIn: CGRect(x: 160, y: 24, width: 44, height: 44)).fill()
            UIColor(red: 0.25, green: 0.55, blue: 0.24, alpha: 1).setFill()
            UIRectFill(CGRect(x: 0, y: 105, width: size.width, height: 45))
        }
    }()

    /// A second picture: a sunset in warm colors.
    static let sunset: UIImage = {
        let size = CGSize(width: 200, height: 200)
        return UIGraphicsImageRenderer(size: size).image { context in
            let colors = [UIColor(red: 0.98, green: 0.55, blue: 0.25, alpha: 1).cgColor,
                          UIColor(red: 0.55, green: 0.2, blue: 0.45, alpha: 1).cgColor]
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1]) {
                context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            }
            UIColor(red: 1, green: 0.92, blue: 0.5, alpha: 1).setFill()
            UIBezierPath(ovalIn: CGRect(x: 70, y: 110, width: 60, height: 60)).fill()
            UIColor(red: 0.15, green: 0.12, blue: 0.3, alpha: 1).setFill()
            UIRectFill(CGRect(x: 0, y: 150, width: size.width, height: 50))
        }
    }()

    static func spinnerRect(_ controller: UIViewController) -> CGRect {
        guard let spinner = find(UIActivityIndicatorView.self, in: controller.view) else { return .zero }
        return spinner.convert(spinner.bounds, to: nil).insetBy(dx: -4, dy: -4)
    }

    static func find<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = find(type, in: subview) { return match }
        }
        return nil
    }

    /// The label showing `text` in `view`, if one does.
    static func find(label text: String, in view: UIView) -> UILabel? {
        if let label = view as? UILabel, label.text == text { return label }
        for subview in view.subviews {
            if let match = find(label: text, in: subview) { return match }
        }
        return nil
    }

    // MARK: - 1 layout: fills, borders, corners, shadows, gradients, opacity, hidden

    static let layout = GalleryScenario(id: "layout", title: "Layout", build: {
        let page = Page("Layout")
        page.loadViewIfNeeded()
        let card = box(.systemBlue, "Card", size: CGSize(width: 150, height: 90))
        card.layer.cornerRadius = 16
        card.tag = 1301
        let bordered = box(.systemBackground, nil, size: CGSize(width: 150, height: 90))
        bordered.layer.borderWidth = 2
        bordered.layer.borderColor = UIColor.systemRed.cgColor
        bordered.layer.cornerRadius = 8
        let inner = label("Bordered", size: 15)
        inner.frame = CGRect(x: 12, y: 34, width: 120, height: 20)
        bordered.addSubview(inner)
        page.row([card, bordered])

        let shadow = box(.white, nil, size: CGSize(width: 150, height: 70))
        shadow.layer.cornerRadius = 12
        shadow.layer.shadowColor = UIColor.black.cgColor
        shadow.layer.shadowOpacity = 0.25
        shadow.layer.shadowRadius = 8
        shadow.layer.shadowOffset = CGSize(width: 0, height: 4)
        let shadowLabel = label("Shadow", size: 15)
        shadowLabel.frame = CGRect(x: 12, y: 24, width: 120, height: 20)
        shadow.addSubview(shadowLabel)
        let gradient = GradientView(type: .axial, text: "Gradient")
        gradient.translatesAutoresizingMaskIntoConstraints = false
        gradient.widthAnchor.constraint(equalToConstant: 150).isActive = true
        gradient.heightAnchor.constraint(equalToConstant: 70).isActive = true
        page.row([shadow, gradient])

        let radial = GradientView(type: .radial, text: "Radial")
        radial.translatesAutoresizingMaskIntoConstraints = false
        radial.widthAnchor.constraint(equalToConstant: 110).isActive = true
        radial.heightAnchor.constraint(equalToConstant: 70).isActive = true
        // One side only: a layer the app adds along the bottom edge.
        let underlined = box(.systemGray6, nil, size: CGSize(width: 150, height: 50))
        let edge = CALayer()
        edge.backgroundColor = UIColor.systemRed.cgColor
        edge.frame = CGRect(x: 0, y: 47, width: 150, height: 3)
        underlined.layer.addSublayer(edge)
        let edgeLabel = label("Bottom border", size: 15)
        edgeLabel.frame = CGRect(x: 12, y: 14, width: 130, height: 20)
        underlined.addSubview(edgeLabel)
        page.row([radial, underlined])

        let rotated = box(.systemOrange, "Rotated", size: CGSize(width: 110, height: 44))
        rotated.transform = CGAffineTransform(rotationAngle: .pi / 12)
        let faded = box(.systemPurple, "Faded", size: CGSize(width: 110, height: 44))
        faded.alpha = 0.5
        faded.tag = 1302
        let corners = box(.systemTeal, "Corners", size: CGSize(width: 110, height: 44))
        corners.layer.cornerRadius = 18
        corners.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMaxYCorner]
        page.row([rotated, faded, corners], height: 70)

        let clip = box(.systemGray5, nil, size: CGSize(width: 320, height: 60))
        clip.clipsToBounds = true
        clip.layer.cornerRadius = 30
        let overflow = label("Clipped to a capsule, the end of this line is cut away by the edge", size: 15)
        overflow.frame = CGRect(x: 20, y: 20, width: 600, height: 20)
        clip.addSubview(overflow)
        page.add(clip, height: 60)

        let shapes = ShapesView()
        shapes.translatesAutoresizingMaskIntoConstraints = false
        page.add(shapes, height: 70)

        let hidden = label("Revealed later", size: 15)
        hidden.isHidden = true
        hidden.tag = 1303
        let transparent = label("Transparent text", size: 15)
        transparent.alpha = 0
        page.row([hidden, transparent, label("Visible text", size: 15)])
        return page
    }, script: { d, controller in
        d.checkpoint(shows: ["Layout", "Card", "Bordered", "Shadow", "Gradient", "Radial", "Bottom border", "Rotated",
                             "Faded", "Corners", "Text layer", "Visible text"],
                     hides: ["Revealed later", "Transparent text"])
        let view = controller.view!
        view.viewWithTag(1301)?.backgroundColor = .systemGreen
        view.viewWithTag(1302)?.alpha = 1
        view.viewWithTag(1303)?.isHidden = false
        d.checkpoint("changed", shows: ["Revealed later", "Card", "Faded"], hides: ["Transparent text"])
    })

    final class GradientView: UIView {
        override class var layerClass: AnyClass { CAGradientLayer.self }

        init(type: CAGradientLayerType, text: String) {
            super.init(frame: .zero)
            let layer = self.layer as! CAGradientLayer
            layer.type = type
            if type == .radial {
                layer.colors = [UIColor.systemYellow.cgColor, UIColor.systemRed.cgColor]
                layer.startPoint = CGPoint(x: 0.5, y: 0.5)
                layer.endPoint = CGPoint(x: 1, y: 1)
            } else {
                layer.colors = [UIColor.systemPink.cgColor, UIColor.systemYellow.cgColor]
                layer.startPoint = CGPoint(x: 0, y: 0.5)
                layer.endPoint = CGPoint(x: 1, y: 0.5)
            }
            layer.cornerRadius = 12
            let title = GalleryScenes.label(text, size: 15, weight: .semibold, color: .white)
            title.frame = CGRect(x: 12, y: 24, width: 90, height: 20)
            addSubview(title)
        }

        required init?(coder: NSCoder) { fatalError("not used") }
    }

    /// Shape and text layers the app adds itself.
    final class ShapesView: UIView {
        override init(frame: CGRect) {
            super.init(frame: frame)
            let circle = CAShapeLayer()
            circle.path = UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: 60, height: 60)).cgPath
            circle.fillColor = UIColor.systemGreen.cgColor
            circle.frame = CGRect(x: 0, y: 5, width: 60, height: 60)
            layer.addSublayer(circle)
            let ring = CAShapeLayer()
            ring.path = UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: 90, height: 60), cornerRadius: 10).cgPath
            ring.fillColor = UIColor.clear.cgColor
            ring.strokeColor = UIColor.systemIndigo.cgColor
            ring.lineWidth = 3
            ring.frame = CGRect(x: 76, y: 5, width: 90, height: 60)
            layer.addSublayer(ring)
            let text = CATextLayer()
            text.string = "Text layer"
            text.fontSize = 16
            text.foregroundColor = UIColor.label.cgColor
            text.frame = CGRect(x: 184, y: 24, width: 120, height: 22)
            text.contentsScale = 2
            layer.addSublayer(text)
        }

        required init?(coder: NSCoder) { fatalError("not used") }
    }

    // MARK: - 2 positioning: alignment grid, margins and padding, nesting, z-order

    static let positioning = GalleryScenario(id: "positioning", title: "Positioning", build: {
        let board = Board("Positioning")
        board.loadViewIfNeeded()
        let grid = board.place(UIView(), CGRect(x: 20, y: 0, width: 260, height: 150))
        grid.backgroundColor = .systemGray6
        grid.layer.cornerRadius = 10
        let names = [["TL", "TC", "TR"], ["ML", "MC", "MR"], ["BL", "BC", "BR"]]
        for (row, line) in names.enumerated() {
            for (column, name) in line.enumerated() {
                let cell = label(name, size: 13, weight: .semibold)
                cell.translatesAutoresizingMaskIntoConstraints = false
                grid.addSubview(cell)
                let x: NSLayoutConstraint
                switch column {
                case 0: x = cell.leadingAnchor.constraint(equalTo: grid.leadingAnchor, constant: 8)
                case 1: x = cell.centerXAnchor.constraint(equalTo: grid.centerXAnchor)
                default: x = cell.trailingAnchor.constraint(equalTo: grid.trailingAnchor, constant: -8)
                }
                let y: NSLayoutConstraint
                switch row {
                case 0: y = cell.topAnchor.constraint(equalTo: grid.topAnchor, constant: 8)
                case 1: y = cell.centerYAnchor.constraint(equalTo: grid.centerYAnchor)
                default: y = cell.bottomAnchor.constraint(equalTo: grid.bottomAnchor, constant: -8)
                }
                NSLayoutConstraint.activate([x, y])
            }
        }

        // Margins around a box times padding inside it.
        let holder = board.place(UIView(), CGRect(x: 20, y: 165, width: 400, height: 100))
        for (i, (margin, padding)) in [(4.0, 4.0), (4.0, 12.0), (12.0, 4.0), (12.0, 12.0)].enumerated() {
            let cell = CGRect(x: CGFloat(i % 2) * 200, y: CGFloat(i / 2) * 50, width: 200, height: 50)
            let outer = UIView(frame: cell.insetBy(dx: CGFloat(margin), dy: CGFloat(margin)))
            outer.backgroundColor = UIColor.systemTeal.withAlphaComponent(0.35)
            outer.directionalLayoutMargins = NSDirectionalEdgeInsets(
                top: CGFloat(padding), leading: CGFloat(padding), bottom: CGFloat(padding), trailing: CGFloat(padding))
            let text = label("Margin \(Int(margin)) padding \(Int(padding))", size: 12)
            text.backgroundColor = UIColor.white.withAlphaComponent(0.8)
            text.translatesAutoresizingMaskIntoConstraints = false
            outer.addSubview(text)
            NSLayoutConstraint.activate([
                text.leadingAnchor.constraint(equalTo: outer.layoutMarginsGuide.leadingAnchor),
                text.trailingAnchor.constraint(equalTo: outer.layoutMarginsGuide.trailingAnchor),
                text.topAnchor.constraint(equalTo: outer.layoutMarginsGuide.topAnchor),
                text.bottomAnchor.constraint(equalTo: outer.layoutMarginsGuide.bottomAnchor),
            ])
            holder.addSubview(outer)
        }

        // Four levels, each offset inside the one above.
        var parent: UIView = board.place(UIView(), CGRect(x: 20, y: 280, width: 180, height: 110))
        parent.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.15)
        for level in 2...4 {
            let size = parent.bounds.insetBy(dx: 12, dy: 10).size
            let child = UIView(frame: CGRect(x: 12, y: 10, width: size.width, height: size.height))
            child.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.1 + 0.1 * CGFloat(level))
            parent.addSubview(child)
            parent = child
        }
        let deepest = label("Depth four", size: 13, weight: .semibold)
        deepest.frame = CGRect(x: 8, y: 15, width: 90, height: 20)
        parent.addSubview(deepest)

        // A child half outside its parent, which does not clip.
        let host = board.place(UIView(), CGRect(x: 260, y: 300, width: 150, height: 80))
        host.backgroundColor = UIColor.systemOrange.withAlphaComponent(0.3)
        let outside = UIView(frame: CGRect(x: -40, y: -14, width: 110, height: 36))
        outside.backgroundColor = .systemOrange
        let outsideLabel = label("Half outside", size: 13, weight: .semibold, color: .white)
        outsideLabel.frame = CGRect(x: 8, y: 8, width: 94, height: 20)
        outside.addSubview(outsideLabel)
        host.addSubview(outside)

        let moved = board.place(UIView(), CGRect(x: 20, y: 410, width: 120, height: 40))
        moved.backgroundColor = .systemGreen
        moved.tag = 1401
        let movedLabel = label("Translated", size: 13, weight: .semibold, color: .white)
        movedLabel.frame = CGRect(x: 10, y: 10, width: 100, height: 20)
        moved.addSubview(movedLabel)
        moved.transform = CGAffineTransform(translationX: 40, y: 8)

        // Overlapping siblings: the first in front by its zPosition, then
        // the later one in front by order.
        @discardableResult
        func card(_ text: String, _ color: UIColor, _ frame: CGRect, tag: Int) -> UIView {
            let view = board.place(UIView(), frame)
            view.backgroundColor = color
            view.tag = tag
            let title = label(text, size: 13, weight: .semibold, color: .white)
            title.frame = CGRect(x: 8, y: 6, width: frame.width - 16, height: 18)
            view.addSubview(title)
            return view
        }
        card("Front by z", .systemRed, CGRect(x: 230, y: 410, width: 120, height: 50), tag: 1402).layer.zPosition = 1
        card("Back by z", .systemBlue, CGRect(x: 270, y: 432, width: 120, height: 50), tag: 1403)
        card("Under by order", .systemPurple, CGRect(x: 20, y: 480, width: 130, height: 50), tag: 1404)
        card("Over by order", .systemBrown, CGRect(x: 60, y: 502, width: 130, height: 50), tag: 1405)
        return board
    }, script: { d, controller in
        let all = ["TL", "TC", "TR", "ML", "MC", "MR", "BL", "BC", "BR", "Margin 4 padding 4", "Margin 12 padding 12",
                   "Depth four", "Half outside", "Translated", "Front by z", "Back by z", "Under by order", "Over by order"]
        d.checkpoint(shows: all)
        let board = controller as! Board
        board.canvas.viewWithTag(1402)?.layer.zPosition = 0
        if let under = board.canvas.viewWithTag(1404) { board.canvas.bringSubviewToFront(under) }
        board.canvas.viewWithTag(1401)?.transform = CGAffineTransform(translationX: 90, y: 0)
        d.checkpoint("moved", shows: all)
    })

    // MARK: - 3 transforms: rotations, scales about the center and a corner, mirroring

    static let transforms = GalleryScenario(id: "transforms", title: "Transforms", build: {
        let board = Board("Transforms")
        board.loadViewIfNeeded()
        let xs: [CGFloat] = [80, 220, 360], ys: [CGFloat] = [60, 190, 320, 450]
        let size = CGSize(width: 100, height: 40)
        func add(_ view: UIView, _ transform: CGAffineTransform, tag: Int = 0) {
            view.transform = transform
            view.tag = tag
            board.canvas.addSubview(view)
        }
        add(tile(.systemRed, "Rot 15", size: size, center: CGPoint(x: xs[0], y: ys[0])), .init(rotationAngle: .pi / 12), tag: 1501)
        add(tile(.systemOrange, "Rot 45", size: size, center: CGPoint(x: xs[1], y: ys[0])), .init(rotationAngle: .pi / 4))
        add(tile(.systemYellow, "Rot 90", size: size, center: CGPoint(x: xs[2], y: ys[0])), .init(rotationAngle: .pi / 2))
        add(tile(.systemGreen, "Rot 180", size: size, center: CGPoint(x: xs[0], y: ys[1])), .init(rotationAngle: .pi))
        add(tile(.systemTeal, "Half size", size: size, center: CGPoint(x: xs[1], y: ys[1])), .init(scaleX: 0.5, y: 0.5))
        add(tile(.systemBlue, "Double", size: CGSize(width: 60, height: 24), center: CGPoint(x: xs[2], y: ys[1]), fontSize: 11),
            .init(scaleX: 2, y: 2))
        // Scaled about the top left corner: the anchor point is the pivot.
        for (i, (text, scale)) in [("Pivot half", 0.5), ("Pivot grow", 1.6)].enumerated() {
            let view = tile(.systemIndigo, text, size: CGSize(width: 80, height: 30), center: .zero)
            view.layer.anchorPoint = .zero
            view.layer.position = CGPoint(x: xs[i] - 50, y: ys[2] - 40)
            add(view, .init(scaleX: CGFloat(scale), y: CGFloat(scale)))
        }
        add(tile(.systemPurple, "Turn and grow", size: CGSize(width: 90, height: 30), center: CGPoint(x: xs[2], y: ys[2]), fontSize: 11),
            CGAffineTransform(rotationAngle: .pi / 6).scaledBy(x: 1.3, y: 1.3))
        let outer = UIView()
        outer.backgroundColor = UIColor.systemPink.withAlphaComponent(0.3)
        outer.bounds = CGRect(x: 0, y: 0, width: 120, height: 60)
        outer.center = CGPoint(x: xs[0], y: ys[3])
        let nested = tile(.systemPink, "Nested turn", size: CGSize(width: 90, height: 30), center: CGPoint(x: 60, y: 30))
        nested.transform = CGAffineTransform(rotationAngle: .pi / 9)
        outer.addSubview(nested)
        add(outer, .init(rotationAngle: .pi / 9))
        add(tile(.systemBrown, "Mirrored", size: size, center: CGPoint(x: xs[1], y: ys[3])), .init(scaleX: -1, y: 1), tag: 1502)
        return board
    }, script: { d, controller in
        d.checkpoint(shows: ["Rot 15", "Rot 45", "Rot 90", "Rot 180", "Half size", "Double", "Pivot half", "Pivot grow",
                             "Turn and grow", "Nested turn", "Mirrored"])
        let canvas = (controller as! Board).canvas
        if let turned = canvas.viewWithTag(1501) {
            turned.transform = CGAffineTransform(rotationAngle: .pi / 3)
            (turned.subviews.first as? UILabel)?.text = "Rot 60"
        }
        if let mirrored = canvas.viewWithTag(1502) {
            mirrored.transform = CGAffineTransform(scaleX: -1, y: -1)
            (mirrored.subviews.first as? UILabel)?.text = "Flipped"
        }
        d.checkpoint("changed", shows: ["Rot 60", "Flipped", "Rot 45"], hides: ["Rot 15", "Mirrored"])
    })

    // MARK: - 4 clipping: on and off, rounded, capsule, inside a scrolled view

    static let clipping = GalleryScenario(id: "clipping", title: "Clipping", build: {
        let board = Board("Clipping")
        board.loadViewIfNeeded()
        for (i, (clips, text)) in [(false, "Overflow shown past the edge"), (true, "Overflow cut at the edge")].enumerated() {
            let host = board.place(UIView(), CGRect(x: 20 + CGFloat(i) * 210, y: 0, width: 150, height: 70))
            host.backgroundColor = UIColor.systemIndigo.withAlphaComponent(0.2)
            host.clipsToBounds = clips
            let title = label(text, size: 14)
            title.frame = CGRect(x: 12, y: 10, width: 220, height: 20)
            host.addSubview(title)
            let square = UIView(frame: CGRect(x: 110, y: 40, width: 60, height: 50))
            square.backgroundColor = .systemIndigo
            host.addSubview(square)
        }
        let rounded = board.place(UIView(), CGRect(x: 20, y: 110, width: 120, height: 120))
        rounded.backgroundColor = .systemGray5
        rounded.layer.cornerRadius = 28
        rounded.clipsToBounds = true
        let corner = UIView(frame: CGRect(x: 0, y: 0, width: 70, height: 70))
        corner.backgroundColor = .systemPink
        rounded.addSubview(corner)
        let roundedLabel = label("Rounded clip", size: 14, weight: .semibold)
        roundedLabel.frame = CGRect(x: 14, y: 84, width: 100, height: 20)
        rounded.addSubview(roundedLabel)

        let capsule = board.place(UIView(), CGRect(x: 160, y: 130, width: 260, height: 50))
        capsule.backgroundColor = .systemGray5
        capsule.layer.cornerRadius = 25
        capsule.clipsToBounds = true
        let capsuleLabel = label("Capsule clip cuts this long line where the edge is", size: 15)
        capsuleLabel.frame = CGRect(x: 18, y: 14, width: 400, height: 22)
        capsule.addSubview(capsuleLabel)

        let scroll = board.place(UIScrollView(), CGRect(x: 20, y: 260, width: 400, height: 170))
        scroll.backgroundColor = .secondarySystemBackground
        scroll.layer.cornerRadius = 12
        scroll.contentSize = CGSize(width: 400, height: 10 + 12 * 44)
        scroll.tag = 1601
        for i in 0..<12 {
            let row = UIView(frame: CGRect(x: 16, y: 10 + CGFloat(i) * 44, width: 368, height: 36))
            row.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.15)
            row.layer.cornerRadius = 8
            row.clipsToBounds = true
            let text = i == 2 ? "Scroll row 03 clips a line far longer than its own rounded box" : String(format: "Scroll row %02d", i + 1)
            let title = label(text, size: 15)
            title.frame = CGRect(x: 12, y: 8, width: i == 2 ? 520 : 300, height: 20)
            row.addSubview(title)
            scroll.addSubview(row)
        }
        return board
    }, script: { d, controller in
        d.checkpoint(shows: ["Overflow shown past the edge", "Overflow cut at the edge", "Rounded clip",
                             "Capsule clip cuts", "Scroll row 01", "Scroll row 03 clips"],
                     hides: ["Scroll row 06"])
        guard let scroll = (controller as! Board).canvas.viewWithTag(1601) as? UIScrollView else { return d.fail("no scroll view") }
        d.scroll(scroll, to: CGPoint(x: 0, y: 200))
        d.checkpoint("scrolled", shows: ["Scroll row 07", "Overflow cut at the edge"], hides: ["Scroll row 01", "Scroll row 12"])
    })

    // MARK: - 5 stacks: axes, distributions, alignments

    static let stacks = GalleryScenario(id: "stacks", title: "Stacks", build: {
        let page = Page("Stacks")
        page.loadViewIfNeeded()
        func stack(_ views: [UIView], axis: NSLayoutConstraint.Axis = .horizontal,
                   distribution: UIStackView.Distribution = .fill, alignment: UIStackView.Alignment = .fill,
                   tag: Int = 0) -> UIStackView {
            let stack = UIStackView(arrangedSubviews: views)
            stack.axis = axis
            stack.distribution = distribution
            stack.alignment = alignment
            stack.spacing = 8
            stack.tag = tag
            return stack
        }
        let hugs = chip("Hugs", .systemBlue)
        hugs.setContentHuggingPriority(.required, for: .horizontal)
        let stretches = chip("Stretches to fill", .systemTeal)
        stretches.setContentHuggingPriority(.defaultLow, for: .horizontal)
        page.add(stack([hugs, stretches]))
        let two = chip("Equal two", .systemOrange)
        two.tag = 1701
        page.add(stack([chip("Equal one", .systemRed), two, chip("Equal three", .systemPink)], distribution: .fillEqually))
        page.add(stack([chip("Gap A", .systemGreen), chip("Gap B", .systemGreen), chip("Gap C", .systemGreen)],
                       distribution: .equalSpacing))
        let leading = stack([chip("Leading item", .systemIndigo), chip("Leading longer item", .systemIndigo)],
                            axis: .vertical, alignment: .leading, tag: 1702)
        page.add(leading)
        page.add(stack([chip("Centered item", .systemPurple)], axis: .vertical, alignment: .center))
        page.add(stack([chip("Trailing item", .systemBrown)], axis: .vertical, alignment: .trailing))
        let low = chip("Low", .systemGray, height: 30), mid = chip("Mid", .systemGray2, height: 50)
        let high = chip("High", .systemGray3, height: 70)
        page.add(stack([low, mid, high], distribution: .fillEqually, alignment: .bottom))
        page.add(stack([chip("Top aligned", .systemMint, height: 30), chip("Tall neighbour", .systemCyan, height: 60)],
                       distribution: .fillEqually, alignment: .top))
        return page
    }, script: { d, controller in
        d.checkpoint(shows: ["Hugs", "Stretches to fill", "Equal one", "Equal two", "Gap A", "Gap C", "Leading longer item",
                             "Centered item", "Trailing item", "Low", "High", "Top aligned"])
        let view = controller.view!
        view.viewWithTag(1701)?.isHidden = true
        (view.viewWithTag(1702) as? UIStackView)?.alignment = .trailing
        d.checkpoint("changed", shows: ["Equal one", "Equal three", "Leading item"], hides: ["Equal two"])
    })

    // MARK: - 6 constraints: centering, multipliers, aspect ratio, pins, chains

    final class ConstraintsController: UIViewController {
        let box = UIView()
        var half: NSLayoutConstraint!
        var offset: NSLayoutConstraint!
        let halfLabel = GalleryScenes.label("Half width", size: 13, weight: .semibold, color: .white)

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .systemBackground
            let title = GalleryScenes.label("Constraints", size: 28, weight: .bold)
            box.backgroundColor = .systemGray6
            box.layer.cornerRadius = 12
            let halfBar = UIView()
            halfBar.backgroundColor = .systemBlue
            let aspect = UIView()
            aspect.backgroundColor = .systemOrange
            let aspectLabel = GalleryScenes.label("Aspect 2:1", size: 13, weight: .semibold, color: .white)
            let centered = GalleryScenes.label("Centered", size: 15, weight: .semibold)
            let lead = GalleryScenes.label("Leading pin", size: 14)
            let trail = GalleryScenes.label("Trailing pin", size: 14)
            let shifted = GalleryScenes.label("Offset center", size: 14)
            let first = GalleryScenes.chip("Chained first", .systemGreen, height: 32)
            let second = GalleryScenes.chip("Chained second", .systemMint, height: 32)
            for v in [title, box, first, second] { view.addSubview(v) }
            for v in [halfBar, aspect, centered, lead, trail, shifted] { box.addSubview(v) }
            halfBar.addSubview(halfLabel)
            aspect.addSubview(aspectLabel)
            for v in [title, box, halfBar, aspect, aspectLabel, halfLabel, centered, lead, trail, shifted, first, second] {
                v.translatesAutoresizingMaskIntoConstraints = false
            }
            let guide = view.safeAreaLayoutGuide
            half = halfBar.widthAnchor.constraint(equalTo: box.widthAnchor, multiplier: 0.5)
            offset = shifted.centerXAnchor.constraint(equalTo: box.centerXAnchor, constant: 60)
            NSLayoutConstraint.activate([
                title.topAnchor.constraint(equalTo: guide.topAnchor, constant: 12),
                title.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
                box.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 16),
                box.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
                box.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
                box.heightAnchor.constraint(equalToConstant: 300),
                halfBar.leadingAnchor.constraint(equalTo: box.leadingAnchor),
                halfBar.topAnchor.constraint(equalTo: box.topAnchor, constant: 12),
                halfBar.heightAnchor.constraint(equalToConstant: 30),
                half,
                halfLabel.centerXAnchor.constraint(equalTo: halfBar.centerXAnchor),
                halfLabel.centerYAnchor.constraint(equalTo: halfBar.centerYAnchor),
                aspect.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -12),
                aspect.topAnchor.constraint(equalTo: halfBar.bottomAnchor, constant: 12),
                aspect.widthAnchor.constraint(equalToConstant: 120),
                aspect.heightAnchor.constraint(equalTo: aspect.widthAnchor, multiplier: 0.5),
                aspectLabel.centerXAnchor.constraint(equalTo: aspect.centerXAnchor),
                aspectLabel.centerYAnchor.constraint(equalTo: aspect.centerYAnchor),
                centered.centerXAnchor.constraint(equalTo: box.centerXAnchor),
                centered.centerYAnchor.constraint(equalTo: box.centerYAnchor),
                lead.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 16),
                lead.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -16),
                trail.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -16),
                trail.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -16),
                offset,
                shifted.centerYAnchor.constraint(equalTo: box.centerYAnchor, constant: 50),
                first.topAnchor.constraint(equalTo: box.bottomAnchor, constant: 16),
                first.leadingAnchor.constraint(equalTo: box.leadingAnchor),
                first.widthAnchor.constraint(equalToConstant: 150),
                second.topAnchor.constraint(equalTo: first.topAnchor),
                second.leadingAnchor.constraint(equalTo: first.trailingAnchor, constant: 12),
                second.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            ])
        }
    }

    static let constraints = GalleryScenario(id: "constraints", title: "Constraints", build: {
        ConstraintsController()
    }, script: { d, controller in
        d.checkpoint(shows: ["Constraints", "Half width", "Aspect 2:1", "Centered", "Leading pin", "Trailing pin",
                             "Offset center", "Chained first", "Chained second"])
        let c = controller as! ConstraintsController
        c.half.isActive = false
        c.half = c.halfLabel.superview!.widthAnchor.constraint(equalTo: c.box.widthAnchor, multiplier: 0.75)
        c.half.isActive = true
        c.halfLabel.text = "Three quarters"
        c.offset.constant = -60
        d.checkpoint("changed", shows: ["Three quarters", "Offset center"], hides: ["Half width"])
    })
}
#endif
