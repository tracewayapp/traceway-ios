import UIKit
import FieldmartCore

/// The terms dialog: a UIKit modal card over a dimmed page with 3,000
/// characters of scrolling text in a `UITextView` and an "I agree" button.
final class TermsViewController: UIViewController {
    private let onAgree: () -> Void
    private let card = UIView()
    private let textView = UITextView()
    private let agree = UIButton.fmFilled(FMText.Checkout.agree, id: "fm-checkout-terms-agree")

    init(onAgree: @escaping () -> Void) {
        self.onAgree = onAgree
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        card.backgroundColor = .systemBackground
        card.layer.cornerRadius = 16
        card.accessibilityIdentifier = "fm-checkout-terms-dialog"
        card.translatesAutoresizingMaskIntoConstraints = false
        let title = UILabel.fm(FMText.Checkout.terms, size: 19, weight: .bold)
        textView.text = ""
        textView.font = .systemFont(ofSize: 15)
        textView.isEditable = false
        textView.isSelectable = false
        textView.accessibilityIdentifier = "fm-checkout-terms-text"
        textView.translatesAutoresizingMaskIntoConstraints = false
        agree.fmOnTap { [weak self] in
            self?.onAgree()
            self?.dismiss(animated: true)
        }
        view.addSubview(card)
        card.addSubview(title)
        card.addSubview(textView)
        card.addSubview(agree)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            card.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            card.heightAnchor.constraint(equalTo: view.heightAnchor, multiplier: 0.62),
            title.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            title.topAnchor.constraint(equalTo: card.topAnchor, constant: 18),
            textView.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            textView.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            textView.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            textView.bottomAnchor.constraint(equalTo: agree.topAnchor, constant: -12),
            agree.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            agree.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            agree.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -18),
        ])
        let env = AppEnvironment.shared
        env.client.json(env.urls.terms) { [weak self] json in
            guard let json = json, let terms = Fixtures.terms(json) else { return }
            self?.textView.text = terms.text
        }
        Autopilot.shared.scroll("fm-checkout-terms-text", textView)
        Autopilot.shared.tap("fm-checkout-terms-agree") { [weak self] in
            self?.onAgree()
            self?.dismiss(animated: true)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        fmScreenAppeared("terms")
    }
}
