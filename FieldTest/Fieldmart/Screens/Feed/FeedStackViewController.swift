import UIKit
import FieldmartCore

/// Feed as one deliberately non-lazy `UIStackView` of 5,000 rows inside a
/// `UIScrollView` (`fmToolkit=stack`, H-I2: the SDK's node budget is spent
/// before its hidden and off-screen checks). Every row view exists at once;
/// shipment rows show a grey box instead of a picture (5,000 rows of
/// pictures at once would make the app itself unusable).
final class FeedStackViewController: UIViewController {
    static let rowCount = 5000

    private let env = AppEnvironment.shared
    private let store = FeedStore(total: FeedStackViewController.rowCount)
    private let controls = FeedControlsView()
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private var rowViews: [Int: UIView] = [:]
    private var built = 0
    private var expanded = Set<Int>()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = FMText.Feed.title
        navigationItem.largeTitleDisplayMode = .never
        controls.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.accessibilityIdentifier = "fm-feed-list"
        stack.axis = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controls)
        view.addSubview(scroll)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controls.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            controls.heightAnchor.constraint(equalToConstant: 92),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: controls.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
        ])
        controls.jumpEnd.fmOnTap { [weak self] in self?.jump(to: FeedStackViewController.rowCount - 1, bottom: true) }
        controls.jumpStart.fmOnTap { [weak self] in self?.jump(to: 0, bottom: false) }
        controls.go.fmOnTap { [weak self] in
            guard let self = self, let row = self.controls.takeRow() else { return }
            self.jump(to: row, bottom: false)
        }
        controls.refresh.fmOnTap { [weak self] in self?.scroll.setContentOffset(.zero, animated: true) }

        store.onLoaded.append { [weak self] _ in self?.buildLoadedRows() }
        // Every page up front, in order: the stack holds all 5,000 rows.
        for page in 0..<(FeedStackViewController.rowCount / FeedStore.pageSize) {
            store.ensure(page * FeedStore.pageSize)
        }

        Autopilot.shared.scroll("fm-feed-list", scroll)
        Autopilot.shared.tap("fm-feed-jump-end") { [weak self] in
            self?.jump(to: FeedStackViewController.rowCount - 1, bottom: true)
        }
        Autopilot.shared.tap("fm-feed-jump-start") { [weak self] in self?.jump(to: 0, bottom: false) }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        fmScreenAppeared("feed")
    }

    /// Appends rows in index order as long as the next one is loaded.
    private func buildLoadedRows() {
        // Header rows ("Week N") are rows of the data here too (not sticky).
        while built < FeedStackViewController.rowCount, let row = store.row(built) {
            let view = makeRow(row)
            rowViews[built] = view
            stack.addArrangedSubview(view)
            built += 1
        }
    }

    private func makeRow(_ row: FeedRow) -> UIView {
        let container = UIView()
        container.accessibilityIdentifier = "fm-feed-row-\(row.index)"
        let height = FeedStore.height(row, expanded: false, width: view.bounds.width)
        container.heightAnchor.constraint(equalToConstant: height).isActive = true
        let title = UILabel.fm(row.title, size: 15, weight: row.kind == .header ? .bold : .regular)
        let detail = UILabel.fm("", size: 13, color: .secondaryLabel, lines: row.kind == .message ? 3 : 1)
        container.addSubview(title)
        container.addSubview(detail)
        var leading: CGFloat = 16
        switch row.kind {
        case .shipment:
            let box = UIView()
            box.backgroundColor = .tertiarySystemFill
            box.layer.cornerRadius = 8
            box.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(box)
            NSLayoutConstraint.activate([
                box.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
                box.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                box.widthAnchor.constraint(equalToConstant: 80),
                box.heightAnchor.constraint(equalToConstant: 80),
            ])
            leading = 108
            detail.text = row.text
        case .alert:
            detail.text = FMFormat.price(row.priceCents ?? 10_000)
        case .message:
            detail.text = row.lines.joined(separator: "\n")
        case .order, .header:
            detail.text = row.time
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: leading),
            title.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            title.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
        ])
        let separator = UIView()
        separator.backgroundColor = Palette.line
        separator.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(separator)
        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            separator.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 0.5),
        ])
        return container
    }

    private func jump(to index: Int, bottom: Bool) {
        let target = max(0, min(built - 1, index))
        guard let row = rowViews[target] else { return }
        view.layoutIfNeeded()
        let frame = row.convert(row.bounds, to: scroll)
        let maxY = max(0, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
        var y = bottom ? frame.maxY - scroll.bounds.height + scroll.adjustedContentInset.bottom : frame.minY
        y = max(-scroll.adjustedContentInset.top, min(maxY, y))
        scroll.setContentOffset(CGPoint(x: 0, y: y), animated: false)
    }
}
