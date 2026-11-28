import UIKit
import FieldmartCore

/// Fieldmart's colours: made up, not any real store's.
enum Palette {
    static let accent = UIColor(red: 0.07, green: 0.45, blue: 0.40, alpha: 1)
    static let accentSoft = UIColor(red: 0.85, green: 0.94, blue: 0.92, alpha: 1)
    static let sale = UIColor(red: 0.80, green: 0.18, blue: 0.20, alpha: 1)
    static let up = UIColor(red: 0.10, green: 0.62, blue: 0.32, alpha: 1)
    static let down = UIColor(red: 0.85, green: 0.22, blue: 0.24, alpha: 1)
    static let card = UIColor.secondarySystemBackground
    static let line = UIColor.separator
    static let swatches: [UIColor] = [
        UIColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1), UIColor(red: 0.95, green: 0.95, blue: 0.93, alpha: 1),
        UIColor(red: 0.13, green: 0.30, blue: 0.62, alpha: 1), UIColor(red: 0.70, green: 0.16, blue: 0.18, alpha: 1),
        UIColor(red: 0.20, green: 0.48, blue: 0.27, alpha: 1), UIColor(red: 0.93, green: 0.69, blue: 0.18, alpha: 1),
        UIColor(red: 0.55, green: 0.35, blue: 0.62, alpha: 1), UIColor(red: 0.56, green: 0.42, blue: 0.30, alpha: 1),
    ]
}

extension UILabel {
    static func fm(_ text: String = "", size: CGFloat = 15, weight: UIFont.Weight = .regular,
                   color: UIColor = .label, lines: Int = 1) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.numberOfLines = lines
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }
}

extension UIButton {
    /// A plain system button with an automation id.
    static func fm(_ title: String, id: String, size: CGFloat = 15, weight: UIFont.Weight = .semibold) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: size, weight: weight)
        button.accessibilityIdentifier = id
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    /// A filled rounded button.
    static func fmFilled(_ title: String, id: String) -> UIButton {
        let button = fm(title, id: id, size: 17, weight: .semibold)
        button.backgroundColor = Palette.accent
        button.setTitleColor(.white, for: .normal)
        button.layer.cornerRadius = 12
        button.contentEdgeInsets = UIEdgeInsets(top: 12, left: 20, bottom: 12, right: 20)
        return button
    }

    /// Runs `action` on a tap.
    func fmOnTap(_ action: @escaping () -> Void) {
        addAction(UIAction { _ in action() }, for: .touchUpInside)
    }
}

extension UIView {
    /// Pins this view to `other`'s edges (or its safe area).
    func fmPin(to other: UIView, insets: UIEdgeInsets = .zero, safeArea: Bool = false) {
        translatesAutoresizingMaskIntoConstraints = false
        let guide: UILayoutGuide? = safeArea ? other.safeAreaLayoutGuide : nil
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: guide?.leadingAnchor ?? other.leadingAnchor, constant: insets.left),
            trailingAnchor.constraint(equalTo: guide?.trailingAnchor ?? other.trailingAnchor, constant: -insets.right),
            topAnchor.constraint(equalTo: guide?.topAnchor ?? other.topAnchor, constant: insets.top),
            bottomAnchor.constraint(equalTo: guide?.bottomAnchor ?? other.bottomAnchor, constant: -insets.bottom),
        ])
    }
}

extension UIViewController {
    /// A "Back" button with the automation id `fm-nav-back` in place of the
    /// system one (whose id cannot be set).
    func fmInstallBackButton() {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "chevron.left"), for: .normal)
        button.setTitle(" Back", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 17)
        button.accessibilityIdentifier = "fm-nav-back"
        button.accessibilityLabel = "Back"
        button.fmOnTap { [weak self] in self?.navigationController?.popViewController(animated: true) }
        button.sizeToFit()
        navigationItem.leftBarButtonItem = UIBarButtonItem(customView: button)
    }

    /// The `FM_SCREEN` marker and the `FM log <n>` line for a UIKit screen.
    func fmScreenAppeared(_ name: String) {
        AppEnvironment.shared.screenAppeared(name)
    }
}

/// The 3-second "Added to cart" message.
final class Toast {
    static func show(_ text: String, in view: UIView, above bottom: CGFloat) {
        let label = UILabel.fm(text, size: 15, weight: .semibold, color: .white)
        label.textAlignment = .center
        label.backgroundColor = UIColor.black.withAlphaComponent(0.82)
        label.layer.cornerRadius = 18
        label.layer.masksToBounds = true
        label.accessibilityIdentifier = "fm-toast"
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -bottom),
            label.heightAnchor.constraint(equalToConstant: 36),
            label.widthAnchor.constraint(equalToConstant: 200),
        ])
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            label.removeFromSuperview()
        }
    }
}

/// A row of star characters for a rating: `"★★★★☆"`.
func fmStars(_ rating: Double) -> String {
    let full = max(0, min(5, Int(rating.rounded())))
    return String(repeating: "★", count: full) + String(repeating: "☆", count: 5 - full)
}

/// A tiny line chart in a `CAShapeLayer` (Markets' and Feed's sparklines).
final class SparklineView: UIView {
    private let shape = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        shape.fillColor = UIColor.clear.cgColor
        shape.lineWidth = 1.5
        shape.strokeColor = Palette.up.cgColor
        layer.addSublayer(shape)
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private var values: [Int] = []

    func set(_ values: [Int], up: Bool) {
        self.values = values
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.strokeColor = (up ? Palette.up : Palette.down).cgColor
        shape.path = path(in: bounds)
        CATransaction.commit()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.frame = bounds
        shape.path = path(in: bounds)
        CATransaction.commit()
    }

    private func path(in rect: CGRect) -> CGPath {
        let path = UIBezierPath()
        guard values.count > 1, rect.width > 0, rect.height > 0,
              let low = values.min(), let high = values.max() else { return path.cgPath }
        let span = CGFloat(max(1, high - low))
        let step = rect.width / CGFloat(values.count - 1)
        for (index, value) in values.enumerated() {
            let point = CGPoint(x: CGFloat(index) * step,
                                y: rect.height - 2 - CGFloat(value - low) / span * (rect.height - 4))
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path.cgPath
    }
}

extension UIColor {
    /// `#rrggbb` from the data (a product's colour swatch).
    convenience init?(fmHex: String) {
        var text = fmHex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(red: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}
