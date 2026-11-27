#if canImport(UIKit)
import UIKit
@testable import Traceway

// The gallery's content scenarios: text, rich text, buttons, controls,
// forms, the keyboard and images.
extension GalleryScenes {
    // MARK: - 7 text: sizes, weights, styles, alignment, wrapping, truncation, spacing

    static let text = GalleryScenario(id: "text", title: "Text", build: {
        let page = Page("Text")
        page.loadViewIfNeeded()
        page.add(label("Large Title", size: 34, weight: .bold))
        page.add(label("Headline semibold", size: 17, weight: .semibold))
        let body = label("Body regular text", size: 17)
        body.tag = 1801
        page.add(body)
        page.row([label("Light", size: 17, weight: .light), label("Medium", size: 17, weight: .medium),
                  label("Heavy", size: 17, weight: .heavy)], spacing: 16)
        page.add(label("Footnote in secondary", size: 13, color: .secondaryLabel))
        page.add(label("Caption eleven points", size: 11, color: .secondaryLabel))
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
        centered.tag = 1802
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
        let twoLines = label("At most two lines: this text goes on well past the second line of the label, so the "
            + "rest of it is cut off at the end of that line", size: 15)
        twoLines.numberOfLines = 2
        page.add(twoLines)
        let spaced = UILabel()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 8
        spaced.attributedText = NSAttributedString(
            string: "Lines spaced eight points apart, wrapped over two lines or more at this width",
            attributes: [.font: UIFont.systemFont(ofSize: 15), .paragraphStyle: paragraph])
        spaced.numberOfLines = 0
        page.add(spaced)
        page.add(label("Emoji 🎉 and ümlauts", size: 17))
        return page
    }, script: { d, controller in
        d.checkpoint(shows: ["Large Title", "Headline semibold", "Body regular text", "Light", "Heavy",
                             "Footnote in secondary", "Italic serif-less", "let code = 42", "Centered line",
                             "Right aligned", "At most two lines", "Lines spaced", "Emoji 🎉 and ümlauts"])
        (controller.view.viewWithTag(1801) as? UILabel)?.text = "Body text after a change"
        (controller.view.viewWithTag(1802) as? UILabel)?.textAlignment = .right
        d.checkpoint("changed", shows: ["Body text after a change", "Centered line"], hides: ["Body regular text"])
    })

    // MARK: - 8 rich text: colors, bold, underline, strike, background, sizes, links

    static func runs(_ parts: [(String, [NSAttributedString.Key: Any])]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (text, attributes) in parts {
            var all: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 17)]
            for (key, value) in attributes { all[key] = value }
            out.append(NSAttributedString(string: text, attributes: all))
        }
        return out
    }

    static let richText = GalleryScenario(id: "rich-text", title: "Rich text", build: {
        let page = Page("Rich text")
        page.loadViewIfNeeded()
        let rich = UILabel()
        rich.numberOfLines = 0
        rich.attributedText = runs([
            ("Rich plain ", [:]),
            ("bold run", [.font: UIFont.boldSystemFont(ofSize: 17)]),
            (" red run", [.foregroundColor: UIColor.systemRed]),
            (" underlined run", [.underlineStyle: NSUnderlineStyle.single.rawValue]),
            (" struck run", [.strikethroughStyle: NSUnderlineStyle.single.rawValue]),
            (" highlighted run", [.backgroundColor: UIColor.systemYellow]),
            (" big run", [.font: UIFont.systemFont(ofSize: 24)]),
            (" small run", [.font: UIFont.systemFont(ofSize: 12)]),
        ])
        page.add(rich)
        let colors = UILabel()
        colors.tag = 1901
        colors.attributedText = runs([("Green ", [.foregroundColor: UIColor.systemGreen]),
                                      ("Blue ", [.foregroundColor: UIColor.systemBlue]),
                                      ("Orange", [.foregroundColor: UIColor.systemOrange])])
        page.add(colors)
        let both = UILabel()
        both.attributedText = runs([("Underlined and struck", [.underlineStyle: NSUnderlineStyle.single.rawValue,
                                                                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                                                                .foregroundColor: UIColor.systemPurple])])
        page.add(both)
        let terms = UITextView()
        terms.isEditable = false
        terms.isScrollEnabled = false
        terms.attributedText = runs([("Read the ", [:]),
                                     ("terms of use", [.link: URL(string: "https://example.com/terms")!]),
                                     (" before you start.", [:])])
        page.add(terms, height: 44)
        return page
    }, script: { d, controller in
        d.checkpoint(shows: ["Rich plain ", "bold run", " red run", " underlined run", " struck run", " highlighted run",
                             " big run", " small run", "Green ", "Orange", "Underlined and struck", "terms of use"])
        (controller.view.viewWithTag(1901) as? UILabel)?.attributedText = runs([
            ("Purple ", [.foregroundColor: UIColor.systemPurple]),
            ("Pink ", [.foregroundColor: UIColor.systemPink, .font: UIFont.boldSystemFont(ofSize: 17)]),
            ("Gray", [.foregroundColor: UIColor.systemGray]),
        ])
        d.checkpoint("changed", shows: ["Purple ", "Pink ", "Gray", "bold run"], hides: ["Green ", "Orange"])
    })

    // MARK: - 9 buttons

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
        d.tap(custom) { counter.text = "Tapped 2 times" }
        d.checkpoint("tapped", shows: ["Tapped 2 times"], hides: ["Tapped 0 times"])
    })

    // MARK: - 10 controls: switches, toggle buttons, segmented, slider, progress, spinner, stepper, page dots

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
        var toggle = UIButton.Configuration.tinted()
        toggle.title = "Bold toggle"
        let toggleButton = UIButton(configuration: toggle)
        toggleButton.changesSelectionAsPrimaryAction = true
        toggleButton.tag = 1008
        page.row([label("Toggle button", size: 17), toggleButton])
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
        pages.tag = 1009
        page.row([spinner, pages])
        let picker = UIDatePicker()
        picker.datePickerMode = .date
        picker.preferredDatePickerStyle = .compact
        picker.date = Date(timeIntervalSince1970: 1_767_225_600)
        page.row([label("Date", size: 17), picker])
        return page
    }, script: { d, controller in
        d.checkpoint(shows: ["Switches", "Toggle button", "Bold toggle", "First", "Second", "Third", "Value 2", "Date"],
                     ignore: [spinnerRect(controller)])
        let page = controller as! Page
        let off = page.view.viewWithTag(1001) as! UISwitch
        d.tap(off) { off.setOn(true, animated: true) }
        let toggle = page.view.viewWithTag(1008) as! UIButton
        d.tap(toggle) { toggle.isSelected = true }
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
        (page.view.viewWithTag(1009) as! UIPageControl).currentPage = 3
        d.checkpoint("changed", shows: ["Value 3", "Third", "Bold toggle"], hides: ["Value 2"], ignore: [spinnerRect(controller)])
    })

    // MARK: - 11 forms: field variants, secure, multiline, placeholders, labels over fields

    static let forms = GalleryScenario(id: "forms", title: "Forms", build: {
        let page = Page("Forms")
        page.loadViewIfNeeded()
        let name = UITextField()
        name.placeholder = "Your name"
        name.borderStyle = .roundedRect
        name.tag = 1201
        page.add(name, height: 36)
        // A label over its field, as a floating label sits once filled.
        let caption = label("Email address", size: 12, weight: .medium, color: .secondaryLabel)
        page.add(caption)
        let email = UITextField()
        email.text = "jane@example.com"
        email.borderStyle = .roundedRect
        let at = UIImageView(image: UIImage(systemName: "envelope"))
        at.tintColor = .secondaryLabel
        email.leftView = at
        email.leftViewMode = .always
        email.clearButtonMode = .always
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
        let bezel = UITextField()
        bezel.placeholder = "Bezel border"
        bezel.borderStyle = .bezel
        page.add(bezel, height: 36)
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
        d.checkpoint(shows: ["Your name", "Email address", "Line border", "Bezel border", "No border",
                             "Read-only terms of service are shown as they are."],
                     hides: ["jane@example.com", "hunter22"])
        let name = (controller as! Page).view.viewWithTag(1201) as! UITextField
        d.type("Ada Lovelace", into: name)
        d.checkpoint("filled", shows: ["*** ********"], hides: ["Your name", "Ada Lovelace"])
    })

    // MARK: - 12 keyboard: a focused field and the system keyboard

    static let keyboard = GalleryScenario(id: "keyboard", title: "Keyboard", build: {
        let page = Page("Compose")
        page.loadViewIfNeeded()
        page.add(label("Write a reply below", size: 17))
        let field = UITextField()
        field.placeholder = "Type a message"
        field.borderStyle = .roundedRect
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.tag = 2001
        page.add(field, height: 40)
        return page
    }, script: { d, controller in
        let field = controller.view.viewWithTag(2001) as! UITextField
        d.tap(field) { _ = field.becomeFirstResponder() }
        if !d.wait(upTo: 5, until: { d.keyboardFrame != nil }) {
            d.fail("the keyboard did not come up (first responder: \(field.isFirstResponder))")
        }
        let keys = d.keyboardFrame.map { [$0] } ?? []
        d.checkpoint(shows: ["Write a reply below", "Type a message", "Keyboard"], ignore: keys, settle: 0.8)
        d.secret("Hello there")
        d.type("Hello there", into: field)
        d.checkpoint("typed", shows: ["***** *****", "Keyboard"], hides: ["Hello there", "Type a message"],
                     ignore: d.keyboardFrame.map { [$0] } ?? keys)
        d.tap(at: CGPoint(x: 200, y: 200)) { _ = field.resignFirstResponder() }
        d.wait(upTo: 3, until: { d.keyboardFrame == nil })
        d.checkpoint("hidden", shows: ["Write a reply below", "***** *****"], hides: ["Keyboard"], settle: 0.8)
    })

    // MARK: - 13, 14 images: photos in each content mode, tinted and symbol images; inlined or not

    /// The same screen for `images` and `images-off`.
    static func imagesPage(_ heading: String) -> Page {
        let page = Page(heading)
        page.loadViewIfNeeded()
        var photos: [UIView] = []
        for (i, (mode, caption)) in [(UIView.ContentMode.scaleToFill, "Photo fill"), (.scaleAspectFit, "Photo fit"),
                                     (.center, "Photo center"), (.scaleAspectFill, "Photo crop")].enumerated() {
            let view = UIImageView(image: i == 2 ? GalleryScenes.sunset : GalleryScenes.photo)
            view.contentMode = mode
            view.clipsToBounds = true
            view.backgroundColor = .systemGray6
            view.layer.cornerRadius = 8
            view.tag = 2101 + i
            view.translatesAutoresizingMaskIntoConstraints = false
            view.heightAnchor.constraint(equalToConstant: 90).isActive = true
            let title = label(caption, size: 12, weight: .semibold, color: .white)
            title.backgroundColor = UIColor.black.withAlphaComponent(0.5)
            title.frame = CGRect(x: 6, y: 6, width: 82, height: 18)
            view.addSubview(title)
            photos.append(view)
        }
        let top = UIStackView(arrangedSubviews: Array(photos[0..<2]))
        let bottom = UIStackView(arrangedSubviews: Array(photos[2..<4]))
        for row in [top, bottom] {
            row.axis = .horizontal
            row.distribution = .fillEqually
            row.spacing = 12
            page.add(row)
        }
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
        symbols[0].tag = 2110
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
    }

    static func imagesScript(pictures: Bool) -> (GalleryDriver, UIViewController) -> Void {
        { d, controller in
            // The first frames show placeholders while the pictures encode.
            d.checkpoint(shows: ["Photo fill", "Photo fit", "Photo center", "Photo crop", "Symbols keep their shape"],
                         settle: 1.2, pictures: pictures)
            (controller.view.viewWithTag(2101) as? UIImageView)?.image = GalleryScenes.sunset
            (controller.view.viewWithTag(2110) as? UIImageView)?.tintColor = .systemPink
            d.checkpoint("changed", shows: ["Photo fill", "Photo crop"], settle: 1.2, pictures: pictures)
        }
    }

    static let images = GalleryScenario(
        id: "images", title: "Images", collection: ["replay": ["images": "always"]],
        build: { imagesPage("Images") }, script: imagesScript(pictures: true)
    )

    static let imagesOff = GalleryScenario(
        id: "images-off", title: "Images off", collection: ["replay": ["images": "off"]],
        build: { imagesPage("Images off") }, script: imagesScript(pictures: false)
    )
}
#endif
