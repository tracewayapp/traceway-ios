#if canImport(UIKit)
import SwiftUI
import UIKit
import WebKit
@testable import Traceway

/// The scenarios of the wireframe gallery, in the order it visits them.
enum GalleryScenes {
    static let all: [GalleryScenario] = [
        layout, text, buttons, controls, forms, images, table, collection,
        navigation, tabs, alerts, sheet, privacy, swiftUI, native, motion,
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

    static func label(_ text: String, size: CGFloat = 17, weight: UIFont.Weight = .regular, color: UIColor = .label) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        return label
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

    // MARK: - Layout: boxes, corners, borders, shadows, gradients, transforms

    static let layout = GalleryScenario(id: "layout", title: "Layout", build: {
        let page = Page("Layout")
        page.loadViewIfNeeded()
        let card = box(.systemBlue, "Card", size: CGSize(width: 150, height: 90))
        card.layer.cornerRadius = 16
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
        let gradient = GradientView()
        gradient.translatesAutoresizingMaskIntoConstraints = false
        gradient.widthAnchor.constraint(equalToConstant: 150).isActive = true
        gradient.heightAnchor.constraint(equalToConstant: 70).isActive = true
        page.row([shadow, gradient])

        let rotated = box(.systemOrange, "Rotated", size: CGSize(width: 110, height: 44))
        rotated.transform = CGAffineTransform(rotationAngle: .pi / 12)
        let faded = box(.systemPurple, "Faded", size: CGSize(width: 110, height: 44))
        faded.alpha = 0.5
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

        let hidden = label("Hidden text", size: 15)
        hidden.isHidden = true
        let transparent = label("Transparent text", size: 15)
        transparent.alpha = 0
        page.row([hidden, transparent, label("Visible text", size: 15)])
        return page
    }, script: { d, _ in
        d.checkpoint(shows: ["Layout", "Card", "Bordered", "Shadow", "Rotated", "Faded", "Corners", "Gradient",
                             "Visible text"],
                     hides: ["Hidden text", "Transparent text"])
    })

    final class GradientView: UIView {
        override class var layerClass: AnyClass { CAGradientLayer.self }

        override init(frame: CGRect) {
            super.init(frame: frame)
            let layer = self.layer as! CAGradientLayer
            layer.colors = [UIColor.systemPink.cgColor, UIColor.systemYellow.cgColor]
            layer.startPoint = CGPoint(x: 0, y: 0.5)
            layer.endPoint = CGPoint(x: 1, y: 0.5)
            layer.cornerRadius = 12
            let text = GalleryScenes.label("Gradient", size: 15, weight: .semibold, color: .white)
            text.frame = CGRect(x: 12, y: 24, width: 120, height: 20)
            addSubview(text)
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

    // MARK: - Text

    static let text = GalleryScenario(id: "text", title: "Text", build: {
        let page = Page("Text")
        page.loadViewIfNeeded()
        page.add(label("Large Title", size: 34, weight: .bold))
        page.add(label("Headline semibold", size: 17, weight: .semibold))
        page.add(label("Body regular text", size: 17))
        page.add(label("Footnote in secondary", size: 13, color: .secondaryLabel))
        let italic = UILabel()
        italic.text = "Italic serif-less"
        italic.font = UIFont.italicSystemFont(ofSize: 17)
        page.add(italic)
        let mono = UILabel()
        mono.text = "let code = 42"
        mono.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        page.add(mono)
        let centered = label("Centered line", size: 17)
        centered.textAlignment = .center
        page.add(centered)
        let right = label("Right aligned", size: 17)
        right.textAlignment = .right
        page.add(right)
        let wrapped = label("A long paragraph that wraps over several lines, the way a description or a message "
            + "body does in most apps, and keeps going for a while.", size: 15)
        wrapped.numberOfLines = 0
        page.add(wrapped)
        let truncated = label("A single line far too long for its width ends with an ellipsis here", size: 17)
        truncated.lineBreakMode = .byTruncatingTail
        page.add(truncated)
        let rich = UILabel()
        let attributed = NSMutableAttributedString(string: "Rich ", attributes: [.font: UIFont.systemFont(ofSize: 17)])
        attributed.append(NSAttributedString(string: "bold", attributes: [.font: UIFont.boldSystemFont(ofSize: 17)]))
        attributed.append(NSAttributedString(string: " red", attributes: [.foregroundColor: UIColor.systemRed]))
        attributed.append(NSAttributedString(string: " underlined", attributes: [.underlineStyle: NSUnderlineStyle.single.rawValue]))
        attributed.append(NSAttributedString(string: " struck", attributes: [.strikethroughStyle: NSUnderlineStyle.single.rawValue]))
        rich.attributedText = attributed
        page.add(rich)
        let rtl = label("שלום עולם", size: 17)
        rtl.semanticContentAttribute = .forceRightToLeft
        rtl.textAlignment = .natural
        page.add(rtl)
        let emoji = label("Emoji 🎉 and ümlauts", size: 17)
        page.add(emoji)
        return page
    }, script: { d, _ in
        d.checkpoint(shows: ["Large Title", "Headline semibold", "Body regular text", "Footnote in secondary",
                             "Italic serif-less", "let code = 42", "Centered line", "Right aligned", "bold", " red",
                             "שלום עולם", "Emoji 🎉 and ümlauts"])
    })

    // MARK: - Buttons

    static let buttons = GalleryScenario(id: "buttons", title: "Buttons", build: {
        let page = Page("Buttons")
        page.loadViewIfNeeded()
        let system = UIButton(type: .system)
        system.setTitle("System button", for: .normal)
        page.add(system)
        var filled = UIButton.Configuration.filled()
        filled.title = "Filled"
        var tinted = UIButton.Configuration.tinted()
        tinted.title = "Tinted"
        var gray = UIButton.Configuration.gray()
        gray.title = "Gray"
        page.row([UIButton(configuration: filled), UIButton(configuration: tinted), UIButton(configuration: gray)])
        var bordered = UIButton.Configuration.bordered()
        bordered.title = "Bordered"
        bordered.image = UIImage(systemName: "star.fill")
        bordered.imagePadding = 6
        var capsule = UIButton.Configuration.borderedProminent()
        capsule.title = "Prominent capsule"
        capsule.cornerStyle = .capsule
        page.row([UIButton(configuration: bordered), UIButton(configuration: capsule)])
        let destructive = UIButton(type: .system)
        destructive.setTitle("Delete", for: .normal)
        destructive.setTitleColor(.systemRed, for: .normal)
        let disabled = UIButton(type: .system)
        disabled.setTitle("Disabled", for: .normal)
        disabled.isEnabled = false
        let icon = UIButton(type: .system)
        icon.setImage(UIImage(systemName: "heart.fill"), for: .normal)
        let info = UIButton(type: .infoLight)
        let add = UIButton(type: .contactAdd)
        page.row([destructive, disabled, icon, info, add])
        let custom = UIButton(type: .custom)
        custom.setTitle("Custom", for: .normal)
        custom.setTitleColor(.white, for: .normal)
        custom.backgroundColor = .systemIndigo
        custom.layer.cornerRadius = 10
        custom.heightAnchor.constraint(equalToConstant: 44).isActive = true
        page.add(custom)
        if #available(iOS 26.0, *) {
            var glass = UIButton.Configuration.glass()
            glass.title = "Glass"
            var prominent = UIButton.Configuration.prominentGlass()
            prominent.title = "Prominent glass"
            page.row([UIButton(configuration: glass), UIButton(configuration: prominent)])
        }
        let counter = label("Tapped 0 times", size: 15, color: .secondaryLabel)
        counter.tag = 1007
        page.add(counter)
        return page
    }, script: { d, controller in
        d.checkpoint(shows: ["System button", "Filled", "Tinted", "Gray", "Bordered", "Prominent capsule", "Delete",
                             "Disabled", "Custom", "Tapped 0 times"])
        let page = controller as! Page
        guard let counter = page.view.viewWithTag(1007) as? UILabel,
              let custom = page.stack.arrangedSubviews.compactMap({ $0 as? UIButton })
              .first(where: { $0.title(for: .normal) == "Custom" }) else { return d.fail("no counter") }
        d.tap(custom) { counter.text = "Tapped 1 times" }
        d.checkpoint("tapped", shows: ["Tapped 1 times"], hides: ["Tapped 0 times"])
    })

    // MARK: - Controls

    static let controls = GalleryScenario(id: "controls", title: "Controls", build: {
        let page = Page("Controls")
        page.loadViewIfNeeded()
        let on = UISwitch()
        on.isOn = true
        let off = UISwitch()
        off.tag = 1001
        let tinted = UISwitch()
        tinted.isOn = true
        tinted.onTintColor = .systemOrange
        page.row([label("Switches", size: 17), on, off, tinted])
        let slider = UISlider()
        slider.value = 0.3
        slider.tag = 1002
        page.add(slider)
        let segmented = UISegmentedControl(items: ["First", "Second", "Third"])
        segmented.selectedSegmentIndex = 0
        segmented.tag = 1003
        page.add(segmented)
        let stepper = UIStepper()
        stepper.value = 2
        stepper.tag = 1004
        let stepperLabel = label("Value 2", size: 17)
        stepperLabel.tag = 1005
        page.row([stepperLabel, stepper])
        let progress = UIProgressView(progressViewStyle: .default)
        progress.progress = 0.4
        progress.tag = 1006
        page.add(progress)
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.startAnimating()
        let pages = UIPageControl()
        pages.numberOfPages = 5
        pages.currentPage = 1
        page.row([spinner, pages])
        let picker = UIDatePicker()
        picker.datePickerMode = .date
        picker.preferredDatePickerStyle = .compact
        picker.date = Date(timeIntervalSince1970: 1_767_225_600)
        page.row([label("Date", size: 17), picker])
        return page
    }, script: { d, controller in
        d.checkpoint(shows: ["Switches", "First", "Second", "Third", "Value 2", "Date"],
                     ignore: [spinnerRect(controller)])
        let page = controller as! Page
        let off = page.view.viewWithTag(1001) as! UISwitch
        d.tap(off) { off.setOn(true, animated: true) }
        let segmented = page.view.viewWithTag(1003) as! UISegmentedControl
        let third = CGPoint(x: segmented.bounds.width * 5 / 6, y: segmented.bounds.midY)
        d.tap(at: segmented.convert(third, to: d.window)) { segmented.selectedSegmentIndex = 2 }
        let stepper = page.view.viewWithTag(1004) as! UIStepper
        let stepperLabel = page.view.viewWithTag(1005) as! UILabel
        d.tap(at: stepper.convert(CGPoint(x: stepper.bounds.width * 0.75, y: stepper.bounds.midY), to: d.window)) {
            stepper.value = 3
            stepperLabel.text = "Value 3"
        }
        let slider = page.view.viewWithTag(1002) as! UISlider
        let track = slider.trackRect(forBounds: slider.bounds)
        let from = slider.convert(CGPoint(x: track.minX + track.width * 0.3, y: track.midY), to: d.window)
        let to = slider.convert(CGPoint(x: track.minX + track.width * 0.8, y: track.midY), to: d.window)
        d.drag(from: from, to: to, seconds: 0.4) { f in slider.value = Float(0.3 + 0.5 * f) }
        (page.view.viewWithTag(1006) as! UIProgressView).progress = 0.9
        d.checkpoint("changed", shows: ["Value 3", "Third"], hides: ["Value 2"], ignore: [spinnerRect(controller)])
    })

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

    // MARK: - Forms

    static let forms = GalleryScenario(id: "forms", title: "Forms", build: {
        let page = Page("Forms")
        page.loadViewIfNeeded()
        let name = UITextField()
        name.placeholder = "Your name"
        name.borderStyle = .roundedRect
        name.tag = 1201
        page.add(name, height: 36)
        let email = UITextField()
        email.text = "jane@example.com"
        email.borderStyle = .roundedRect
        let at = UIImageView(image: UIImage(systemName: "envelope"))
        at.tintColor = .secondaryLabel
        email.leftView = at
        email.leftViewMode = .always
        page.add(email, height: 36)
        let password = UITextField()
        password.isSecureTextEntry = true
        password.text = "hunter22"
        password.borderStyle = .roundedRect
        page.add(password, height: 36)
        let line = UITextField()
        line.placeholder = "Line border"
        line.borderStyle = .line
        page.add(line, height: 36)
        let plain = UITextField()
        plain.placeholder = "No border"
        page.add(plain, height: 36)
        let notes = UITextView()
        notes.text = "Private notes typed by the user"
        notes.font = .systemFont(ofSize: 15)
        notes.layer.borderColor = UIColor.separator.cgColor
        notes.layer.borderWidth = 1
        notes.layer.cornerRadius = 8
        page.add(notes, height: 80)
        let terms = UITextView()
        terms.text = "Read-only terms of service are shown as they are."
        terms.isEditable = false
        terms.font = .systemFont(ofSize: 15)
        page.add(terms, height: 50)
        return page
    }, script: { d, controller in
        d.secret("jane@example.com")
        d.secret("hunter22")
        d.secret("Private notes typed by the user")
        d.secret("Ada Lovelace")
        d.checkpoint(shows: ["Your name", "Line border", "No border", "Read-only terms of service are shown as they are."],
                     hides: ["jane@example.com", "hunter22"])
        let name = (controller as! Page).view.viewWithTag(1201) as! UITextField
        d.type("Ada Lovelace", into: name)
        d.checkpoint("filled", shows: ["*** ********"], hides: ["Your name", "Ada Lovelace"])
    })

    // MARK: - Images

    static let images = GalleryScenario(id: "images", title: "Images", build: {
        let page = Page("Images")
        page.loadViewIfNeeded()
        let photo = UIImageView(image: GalleryScenes.photo)
        photo.contentMode = .scaleAspectFill
        photo.clipsToBounds = true
        photo.layer.cornerRadius = 12
        let badge = label("Badge over a photo", size: 13, weight: .semibold, color: .white)
        badge.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        badge.frame = CGRect(x: 10, y: 10, width: 150, height: 22)
        photo.addSubview(badge)
        page.add(photo, height: 150)
        var symbols: [UIView] = []
        for (name, color) in [("star.fill", UIColor.systemYellow), ("heart.fill", .systemRed), ("bell", .systemBlue),
                              ("gearshape.fill", .systemGray), ("person.crop.circle", .systemGreen),
                              ("chevron.right", .tertiaryLabel)] {
            let view = UIImageView(image: UIImage(systemName: name))
            view.tintColor = color
            view.contentMode = .scaleAspectFit
            view.widthAnchor.constraint(equalToConstant: 32).isActive = true
            view.heightAnchor.constraint(equalToConstant: 32).isActive = true
            symbols.append(view)
        }
        page.row(symbols, spacing: 16)
        let big = UIImageView(image: UIImage(systemName: "cloud.sun.rain.fill"))
        big.tintColor = .systemCyan
        big.contentMode = .scaleAspectFit
        big.widthAnchor.constraint(equalToConstant: 80).isActive = true
        big.heightAnchor.constraint(equalToConstant: 80).isActive = true
        let multicolor = UIImageView(image: UIImage(systemName: "sun.max.fill")?
            .withConfiguration(UIImage.SymbolConfiguration(paletteColors: [.systemOrange])))
        multicolor.contentMode = .scaleAspectFit
        multicolor.widthAnchor.constraint(equalToConstant: 60).isActive = true
        multicolor.heightAnchor.constraint(equalToConstant: 60).isActive = true
        let template = UIImageView(image: GalleryScenes.photo.withRenderingMode(.alwaysTemplate))
        template.tintColor = .systemPurple
        template.widthAnchor.constraint(equalToConstant: 96).isActive = true
        template.heightAnchor.constraint(equalToConstant: 60).isActive = true
        page.row([big, multicolor, template], spacing: 20)
        page.add(label("Symbols keep their shape", size: 15, color: .secondaryLabel))
        return page
    }, script: { d, _ in
        d.checkpoint(shows: ["Images", "Badge over a photo", "Symbols keep their shape"])
    })

    // MARK: - Table

    final class TableController: UITableViewController {
        override func viewDidLoad() {
            super.viewDidLoad()
            tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        }

        override func numberOfSections(in tableView: UITableView) -> Int { 3 }

        override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 20 }

        override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
            "Section \(section + 1)"
        }

        override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
            let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
            var content = cell.defaultContentConfiguration()
            content.text = String(format: "Row %d.%02d", indexPath.section + 1, indexPath.row + 1)
            content.secondaryText = indexPath.row % 3 == 0 ? "Detail text" : nil
            content.image = indexPath.row % 4 == 0 ? UIImage(systemName: "folder") : nil
            cell.contentConfiguration = content
            cell.accessoryType = indexPath.row % 2 == 0 ? .disclosureIndicator : .checkmark
            return cell
        }
    }

    static let table = GalleryScenario(id: "table", title: "Table", build: {
        TableController(style: .insetGrouped)
    }, script: { d, controller in
        let table = (controller as! UITableViewController).tableView!
        d.checkpoint(shows: ["Section 1", "Row 1.01", "Row 1.02", "Detail text"])
        d.scroll(table, to: CGPoint(x: 0, y: table.contentOffset.y + 600))
        d.checkpoint("scrolled", shows: ["Row 1.15"], hides: ["Row 1.01"])
        // Cells size themselves: the content's height is only known once
        // the last rows were laid out.
        let last = IndexPath(row: 19, section: 2)
        table.scrollToRow(at: last, at: .bottom, animated: false)
        table.layoutIfNeeded()
        let bottom = table.contentOffset
        table.contentOffset = CGPoint(x: 0, y: bottom.y - 900)
        d.scroll(table, to: bottom, seconds: 0.8)
        d.checkpoint("bottom", shows: ["Row 3.20"], hides: ["Row 1.01"])
        d.scroll(table, to: CGPoint(x: 0, y: -table.adjustedContentInset.top), seconds: 0.8)
        d.checkpoint("top", shows: ["Row 1.01"], hides: ["Row 3.20"])
    })

    // MARK: - Collection

    final class CollectionController: UICollectionViewController {
        init() {
            let layout = UICollectionViewCompositionalLayout { section, _ in
                if section == 0 {
                    let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .absolute(120), heightDimension: .absolute(80)))
                    let group = NSCollectionLayoutGroup.horizontal(
                        layoutSize: .init(widthDimension: .absolute(120), heightDimension: .absolute(80)), subitems: [item])
                    let section = NSCollectionLayoutSection(group: group)
                    section.orthogonalScrollingBehavior = .continuous
                    section.interGroupSpacing = 10
                    section.contentInsets = .init(top: 10, leading: 16, bottom: 10, trailing: 16)
                    return section
                }
                let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(1 / 3), heightDimension: .fractionalHeight(1)))
                item.contentInsets = .init(top: 4, leading: 4, bottom: 4, trailing: 4)
                let group = NSCollectionLayoutGroup.horizontal(
                    layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(110)), subitems: [item])
                let section = NSCollectionLayoutSection(group: group)
                section.contentInsets = .init(top: 0, leading: 12, bottom: 0, trailing: 12)
                return section
            }
            super.init(collectionViewLayout: layout)
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override func viewDidLoad() {
            super.viewDidLoad()
            collectionView.backgroundColor = .systemBackground
            collectionView.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "cell")
        }

        override func numberOfSections(in collectionView: UICollectionView) -> Int { 2 }

        override func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            section == 0 ? 12 : 30
        }

        override func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "cell", for: indexPath)
            let hues: [UIColor] = [.systemRed, .systemOrange, .systemGreen, .systemBlue, .systemPurple, .systemPink]
            cell.contentView.backgroundColor = hues[indexPath.item % hues.count]
            cell.contentView.layer.cornerRadius = 10
            let tag = 99
            let label = (cell.contentView.viewWithTag(tag) as? UILabel) ?? {
                let label = UILabel()
                label.tag = tag
                label.textColor = .white
                label.font = .systemFont(ofSize: 15, weight: .semibold)
                label.textAlignment = .center
                label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                label.frame = cell.contentView.bounds
                cell.contentView.addSubview(label)
                return label
            }()
            label.text = String(format: indexPath.section == 0 ? "Card %02d" : "Tile %02d", indexPath.item + 1)
            return cell
        }
    }

    static let collection = GalleryScenario(id: "collection", title: "Collection", build: {
        CollectionController()
    }, script: { d, controller in
        let grid = (controller as! UICollectionViewController).collectionView!
        d.checkpoint(shows: ["Card 01", "Card 02", "Tile 01", "Tile 06"])
        if let strip = grid.subviews.compactMap({ $0 as? UIScrollView }).first(where: { $0.bounds.height < 120 }) {
            d.scroll(strip, to: CGPoint(x: 400, y: 0))
            d.checkpoint("strip", shows: ["Card 05"], hides: ["Card 01"])
        } else {
            d.fail("no horizontal section")
        }
        d.scroll(grid, to: CGPoint(x: 0, y: 500))
        d.checkpoint("scrolled", shows: ["Tile 18"], hides: ["Tile 01"])
    })

    // MARK: - Navigation

    final class ListController: UIViewController {
        override func viewDidLoad() {
            super.viewDidLoad()
            title = "Inbox"
            view.backgroundColor = .systemBackground
            navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .add, target: nil, action: nil)
            navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Edit", style: .plain, target: nil, action: nil)
            let text = GalleryScenes.label("Three new messages", size: 17)
            text.frame = CGRect(x: 20, y: 200, width: 300, height: 24)
            view.addSubview(text)
        }
    }

    static let navigation = GalleryScenario(id: "navigation", title: "Navigation", build: {
        let nav = UINavigationController(rootViewController: ListController())
        nav.navigationBar.prefersLargeTitles = true
        return nav
    }, script: { d, controller in
        let nav = controller as! UINavigationController
        d.checkpoint(shows: ["Inbox", "Edit", "Three new messages"])
        let detail = UIViewController()
        detail.title = "Message"
        detail.view.backgroundColor = .systemBackground
        detail.navigationItem.largeTitleDisplayMode = .never
        let body = GalleryScenes.label("Hello from the detail page", size: 17)
        body.frame = CGRect(x: 20, y: 160, width: 320, height: 24)
        detail.view.addSubview(body)
        d.tap(at: CGPoint(x: 200, y: 212)) { nav.pushViewController(detail, animated: true) }
        d.checkpoint("pushed", shows: ["Message", "Hello from the detail page"], hides: ["Three new messages"], settle: 0.8)
        d.tap(at: CGPoint(x: 30, y: 70)) { nav.popViewController(animated: true) }
        d.checkpoint("popped", shows: ["Three new messages"], hides: ["Hello from the detail page"], settle: 0.8)
    })

    static let tabs = GalleryScenario(id: "tabs", title: "Tabs", build: {
        func tab(_ title: String, _ symbol: String, _ text: String) -> UIViewController {
            let controller = UIViewController()
            controller.view.backgroundColor = .systemBackground
            controller.tabBarItem = UITabBarItem(title: title, image: UIImage(systemName: symbol), tag: 0)
            let body = GalleryScenes.label(text, size: 22, weight: .semibold)
            body.frame = CGRect(x: 20, y: 140, width: 320, height: 30)
            controller.view.addSubview(body)
            return controller
        }
        let tabs = UITabBarController()
        tabs.viewControllers = [tab("Home", "house.fill", "Home page"), tab("Search", "magnifyingglass", "Search page"),
                                tab("Profile", "person.fill", "Profile page")]
        return tabs
    }, script: { d, controller in
        let tabs = controller as! UITabBarController
        d.checkpoint(shows: ["Home", "Search", "Profile", "Home page"])
        let bar = tabs.tabBar.convert(tabs.tabBar.bounds, to: d.window)
        d.tap(at: CGPoint(x: bar.midX, y: bar.midY)) { tabs.selectedIndex = 1 }
        d.checkpoint("search", shows: ["Search page"], hides: ["Home page"], settle: 0.6)
    })

    // MARK: - Overlays

    static let alerts = GalleryScenario(id: "alerts", title: "Alerts", build: {
        let page = Page("Alerts")
        page.loadViewIfNeeded()
        page.add(label("Behind the alert", size: 17))
        return page
    }, script: { d, controller in
        let alert = UIAlertController(title: "Delete photo?", message: "This cannot be undone.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive))
        controller.present(alert, animated: true)
        d.checkpoint("alert", shows: ["Delete photo?", "This cannot be undone.", "Cancel", "Delete", "Behind the alert"],
                     settle: 0.8)
        alert.dismiss(animated: false)
        d.wait(0.4)
        let sheet = UIAlertController(title: "Share", message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Copy link", style: .default))
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        controller.present(sheet, animated: true)
        d.checkpoint("action-sheet", shows: ["Share", "Copy link", "Cancel"], hides: ["Delete photo?"], settle: 0.8)
        sheet.dismiss(animated: false)
        d.wait(0.4)
        d.checkpoint("dismissed", shows: ["Behind the alert"], hides: ["Copy link"])
    })

    static let sheet = GalleryScenario(id: "sheet", title: "Sheet", build: {
        let page = Page("Sheets")
        page.loadViewIfNeeded()
        page.add(label("Under the sheet", size: 17))
        return page
    }, script: { d, controller in
        let content = UIViewController()
        content.view.backgroundColor = .secondarySystemBackground
        let text = GalleryScenes.label("A half-height sheet", size: 20, weight: .semibold)
        text.frame = CGRect(x: 20, y: 30, width: 300, height: 28)
        content.view.addSubview(text)
        if let presentation = content.sheetPresentationController {
            presentation.detents = [.medium()]
            presentation.prefersGrabberVisible = true
        }
        controller.present(content, animated: true)
        d.checkpoint(shows: ["A half-height sheet", "Under the sheet"], settle: 0.9)
        content.dismiss(animated: false)
        d.wait(0.4)
    })

    // MARK: - Privacy

    static let privacy = GalleryScenario(id: "privacy", title: "Privacy", build: {
        let page = Page("Privacy")
        page.loadViewIfNeeded()
        let blank = UIView()
        blank.backgroundColor = .secondarySystemBackground
        blank.tracewayPrivacyMask = .blank()
        let card = label("Card 4242 4242 4242 4242", size: 17)
        card.frame = CGRect(x: 12, y: 14, width: 300, height: 22)
        blank.addSubview(card)
        page.add(blank, height: 50)
        let blurred = UIView()
        blurred.tracewayPrivacyMask = .blur
        let balance = label("Balance $12,345.67", size: 17)
        balance.frame = CGRect(x: 12, y: 14, width: 300, height: 22)
        blurred.addSubview(balance)
        let avatar = UIImageView(image: UIImage(systemName: "person.fill"))
        avatar.frame = CGRect(x: 280, y: 10, width: 30, height: 30)
        blurred.addSubview(avatar)
        page.add(blurred, height: 50)
        page.add(label("Public text stays", size: 17))
        return page
    }, script: { d, _ in
        d.secret("4242 4242")
        d.secret("12,345.67")
        d.checkpoint(shows: ["Public text stays", "******* **********"], hides: ["4242", "12,345.67"])
    })

    // MARK: - SwiftUI

    final class SwiftUIModel: ObservableObject {
        @Published var on = false
        @Published var count = 0
    }

    struct SwiftUIScreen: View {
        @ObservedObject var model: SwiftUIModel

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("SwiftUI").font(.largeTitle.bold())
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
                    ForEach(1..<6) { i in
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

    static let swiftUI = GalleryScenario(id: "swiftui", title: "SwiftUI", build: {
        UIHostingController(rootView: SwiftUIScreen(model: swiftUIModel))
    }, script: { d, _ in
        d.secret("555-0101")
        d.checkpoint(shows: ["SwiftUI", "Plain SwiftUI text", "Notifications", "Count 0", "List row 1"],
                     hides: ["555-0101"], settle: 0.9)
        swiftUIModel.on = true
        swiftUIModel.count = 1
        d.checkpoint("changed", shows: ["Count 1"], hides: ["Count 0", "555-0101"], settle: 1.2)
    })

    // MARK: - Native views

    static let native = GalleryScenario(id: "native", title: "Native", build: {
        let page = Page("Native views")
        page.loadViewIfNeeded()
        let web = WKWebView()
        page.add(web, height: 160)
        page.add(label("Web content is a placeholder", size: 15, color: .secondaryLabel))
        let drawn = DrawnView()
        page.add(drawn, height: 60)
        return page
    }, script: { d, _ in
        d.checkpoint(shows: ["Web view", "Web content is a placeholder"])
    })

    /// Draws itself in draw(_:): its pixels are not recorded.
    final class DrawnView: UIView {
        override func draw(_ rect: CGRect) {
            UIColor.systemMint.setFill()
            UIBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 4), cornerRadius: 10).fill()
        }
    }

    // MARK: - Motion

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
        d.checkpoint("moving", shows: ["Moving"], settle: 0, minMutations: 2)
        d.checkpoint("end", shows: ["Moving"], settle: 1.0)
    })
}
#endif
