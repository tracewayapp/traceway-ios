import UIKit
import FieldmartCore

/// Feed with `UITableView` (the default `fmToolkit`): 10,000 rows of four
/// kinds in sticky "Week N" sections, loaded 100 at a time. Shipment rows
/// get a **new** `UIImage` every time they are configured (H-I5).
final class FeedViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let env = AppEnvironment.shared
    private let store = FeedStore()
    private let controls = FeedControlsView()
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let refreshControl = UIRefreshControl()
    private var expanded = Set<Int>()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = FMText.Feed.title
        navigationItem.largeTitleDisplayMode = .never

        controls.translatesAutoresizingMaskIntoConstraints = false
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.accessibilityIdentifier = "fm-feed-list"
        tableView.dataSource = self
        tableView.delegate = self
        tableView.estimatedRowHeight = 0
        tableView.estimatedSectionHeaderHeight = 0
        tableView.sectionHeaderHeight = 30
        tableView.sectionHeaderTopPadding = 0
        tableView.register(FeedOrderCell.self, forCellReuseIdentifier: FeedOrderCell.reuse)
        tableView.register(FeedShipmentCell.self, forCellReuseIdentifier: FeedShipmentCell.reuse)
        tableView.register(FeedAlertCell.self, forCellReuseIdentifier: FeedAlertCell.reuse)
        tableView.register(FeedMessageCell.self, forCellReuseIdentifier: FeedMessageCell.reuse)
        tableView.register(FeedOrderCell.self, forCellReuseIdentifier: "placeholder")
        tableView.register(FeedHeaderView.self, forHeaderFooterViewReuseIdentifier: FeedHeaderView.reuse)
        tableView.keyboardDismissMode = .onDrag
        refreshControl.addAction(UIAction { [weak self] _ in self?.refresh() }, for: .valueChanged)
        tableView.refreshControl = refreshControl

        view.addSubview(controls)
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controls.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            controls.heightAnchor.constraint(equalToConstant: 92),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: controls.bottomAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        controls.jumpEnd.fmOnTap { [weak self] in self?.jump(to: (self?.store.total ?? 1) - 1, position: .bottom) }
        controls.jumpStart.fmOnTap { [weak self] in self?.jump(to: 0, position: .top) }
        controls.go.fmOnTap { [weak self] in
            guard let self = self, let row = self.controls.takeRow() else { return }
            self.jump(to: row, position: .top)
        }
        controls.refresh.fmOnTap { [weak self] in self?.refresh() }

        store.onLoaded.append { [weak self] range in self?.loaded(range) }
        store.ensure(0)
        store.ensure(FeedStore.pageSize)

        Autopilot.shared.scroll("fm-feed-list", tableView)
        Autopilot.shared.tap("fm-feed-jump-end") { [weak self] in
            self?.jump(to: (self?.store.total ?? 1) - 1, position: .bottom)
        }
        Autopilot.shared.tap("fm-feed-jump-start") { [weak self] in self?.jump(to: 0, position: .top) }
        Autopilot.shared.text("fm-feed-goto-field") { [weak self] text in self?.controls.field.text = text }
        Autopilot.shared.tap("fm-feed-goto-go") { [weak self] in
            guard let self = self, let row = self.controls.takeRow() else { return }
            self.jump(to: row, position: .top)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        fmScreenAppeared("feed")
    }

    private func loaded(_ range: Range<Int>) {
        UIView.performWithoutAnimation {
            // Heights depend on the row kind: let the table ask again.
            tableView.performBatchUpdates(nil)
            let visible = (tableView.indexPathsForVisibleRows ?? []).filter { range.contains(FeedStore.index($0)) }
            if !visible.isEmpty { tableView.reloadRows(at: visible, with: .none) }
        }
    }

    private func jump(to index: Int, position: UITableView.ScrollPosition) {
        let target = max(0, min(store.total - 1, index))
        store.ensure(target) { [weak self] in
            guard let self = self else { return }
            let path = FeedStore.indexPath(target)
            if FeedStore.isHeader(target) || position == .top {
                // The section's header at the top, its first rows below it.
                let rect = FeedStore.isHeader(target)
                    ? self.tableView.rect(forSection: path.section) : self.tableView.rectForRow(at: path)
                let maxY = max(-self.tableView.adjustedContentInset.top,
                               self.tableView.contentSize.height - self.tableView.bounds.height
                                   + self.tableView.adjustedContentInset.bottom)
                let y = min(maxY, rect.minY - self.tableView.adjustedContentInset.top
                    - (FeedStore.isHeader(target) ? 0 : self.tableView.sectionHeaderHeight))
                self.tableView.setContentOffset(CGPoint(x: 0, y: y), animated: false)
            } else {
                self.tableView.scrollToRow(at: path, at: position, animated: false)
            }
            // Rows around the target, so nothing above it changes height later.
            self.store.ensure(target - FeedStore.pageSize)
            self.store.ensure(target + FeedStore.pageSize)
        }
    }

    private func refresh() {
        expanded = []
        store.refresh { [weak self] in
            self?.refreshControl.endRefreshing()
            self?.tableView.reloadData()
        }
    }

    // MARK: - Table

    func numberOfSections(in tableView: UITableView) -> Int { store.sectionCount }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        store.rowsIn(section: section)
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let header = tableView.dequeueReusableHeaderFooterView(withIdentifier: FeedHeaderView.reuse) as? FeedHeaderView
        header?.show(store.header(section), index: section * FeedStore.sectionSize)
        return header
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        let index = FeedStore.index(indexPath)
        return FeedStore.height(store.row(index), expanded: expanded.contains(index), width: tableView.bounds.width)
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let index = FeedStore.index(indexPath)
        guard let row = store.row(index) else {
            store.ensure(index)
            let cell = tableView.dequeueReusableCell(withIdentifier: "placeholder", for: indexPath)
            (cell as? FeedOrderCell)?.placeholder(index)
            return cell
        }
        let cell: UITableViewCell
        switch row.kind {
        case .shipment:
            cell = tableView.dequeueReusableCell(withIdentifier: FeedShipmentCell.reuse, for: indexPath)
            (cell as? FeedShipmentCell)?.configure(row)
        case .alert:
            cell = tableView.dequeueReusableCell(withIdentifier: FeedAlertCell.reuse, for: indexPath)
            (cell as? FeedAlertCell)?.configure(row)
        case .message:
            cell = tableView.dequeueReusableCell(withIdentifier: FeedMessageCell.reuse, for: indexPath)
            (cell as? FeedMessageCell)?.configure(row, expanded: expanded.contains(index))
        case .order, .header:
            cell = tableView.dequeueReusableCell(withIdentifier: FeedOrderCell.reuse, for: indexPath)
            (cell as? FeedOrderCell)?.configure(row)
        }
        cell.accessibilityIdentifier = "fm-feed-row-\(index)"
        return cell
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        let index = FeedStore.index(indexPath)
        store.ensure(index + FeedStore.pageSize / 2)
        store.ensure(max(0, index - FeedStore.pageSize / 2))
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        let index = FeedStore.index(indexPath)
        guard store.row(index)?.kind == .message else { return }
        if expanded.contains(index) { expanded.remove(index) } else { expanded.insert(index) }
        UIView.performWithoutAnimation {
            tableView.reloadRows(at: [indexPath], with: .none)
        }
    }
}

// MARK: - Cells

final class FeedOrderCell: UITableViewCell {
    static let reuse = "FeedOrderCell"
    private let icon = UIImageView(image: UIImage(systemName: "shippingbox"))
    private let title = UILabel.fm("", size: 15)
    private let time = UILabel.fm("", size: 12, color: .secondaryLabel)

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        icon.tintColor = Palette.accent
        icon.contentMode = .scaleAspectFit
        icon.translatesAutoresizingMaskIntoConstraints = false
        for view in [icon, title, time] { contentView.addSubview(view) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            icon.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 26),
            icon.heightAnchor.constraint(equalToConstant: 26),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            title.trailingAnchor.constraint(lessThanOrEqualTo: time.leadingAnchor, constant: -8),
            title.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            time.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            time.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
        time.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(_ row: FeedRow) {
        icon.isHidden = row.kind == .header
        title.font = .systemFont(ofSize: 15, weight: row.kind == .header ? .bold : .regular)
        title.text = row.title.isEmpty ? row.text : row.title
        time.text = row.time
    }

    func placeholder(_ index: Int) {
        accessibilityIdentifier = "fm-feed-row-\(index)"
        icon.isHidden = true
        title.text = " "
        time.text = ""
    }
}

final class FeedShipmentCell: UITableViewCell {
    static let reuse = "FeedShipmentCell"
    private let picture = UIImageView()
    private let title = UILabel.fm("", size: 15, weight: .semibold, lines: 2)
    private let detail = UILabel.fm("", size: 13, color: .secondaryLabel)
    private let progress = UIProgressView(progressViewStyle: .default)

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        picture.contentMode = .scaleAspectFill
        picture.clipsToBounds = true
        picture.layer.cornerRadius = 8
        picture.backgroundColor = .tertiarySystemFill
        picture.translatesAutoresizingMaskIntoConstraints = false
        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.progressTintColor = Palette.accent
        for view in [picture, title, detail, progress] { contentView.addSubview(view) }
        NSLayoutConstraint.activate([
            picture.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            picture.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            picture.widthAnchor.constraint(equalToConstant: 80),
            picture.heightAnchor.constraint(equalToConstant: 80),
            title.leadingAnchor.constraint(equalTo: picture.trailingAnchor, constant: 12),
            title.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            title.topAnchor.constraint(equalTo: picture.topAnchor, constant: 4),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            progress.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            progress.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            progress.topAnchor.constraint(equalTo: detail.bottomAnchor, constant: 8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(_ row: FeedRow) {
        let env = AppEnvironment.shared
        title.text = row.title
        detail.text = row.text
        progress.setProgress(Float(max(0, min(1, row.progress))), animated: false)
        let url = row.productId.map { env.urls.productImage($0, size: 160) }
        picture.fmSetFreshImage(url, loader: env.freshImages)
    }
}

final class FeedAlertCell: UITableViewCell {
    static let reuse = "FeedAlertCell"
    private let symbol = UILabel.fm("", size: 15, weight: .semibold)
    private let price = UILabel.fm("", size: 13, weight: .regular, color: .secondaryLabel)
    private let spark = SparklineView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        price.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        spark.translatesAutoresizingMaskIntoConstraints = false
        for view in [symbol, price, spark] { contentView.addSubview(view) }
        NSLayoutConstraint.activate([
            symbol.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            symbol.trailingAnchor.constraint(lessThanOrEqualTo: spark.leadingAnchor, constant: -8),
            symbol.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            price.leadingAnchor.constraint(equalTo: symbol.leadingAnchor),
            price.topAnchor.constraint(equalTo: symbol.bottomAnchor, constant: 2),
            spark.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            spark.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            spark.widthAnchor.constraint(equalToConstant: 110),
            spark.heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(_ row: FeedRow) {
        let cents = row.priceCents ?? 10_000
        symbol.text = row.title.isEmpty ? (row.symbol ?? "") : row.title
        price.text = FMFormat.price(cents)
        let values = row.spark.count > 1 ? row.spark : FeedStore.spark(for: row.index, around: cents)
        spark.set(values, up: (values.last ?? 0) >= (values.first ?? 0))
    }
}

final class FeedMessageCell: UITableViewCell {
    static let reuse = "FeedMessageCell"
    private let avatar = UIImageView()
    private let title = UILabel.fm("", size: 15, weight: .semibold)
    private let body = UILabel.fm("", size: 14, lines: 3)

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        avatar.layer.cornerRadius = 20
        avatar.clipsToBounds = true
        avatar.backgroundColor = .tertiarySystemFill
        avatar.translatesAutoresizingMaskIntoConstraints = false
        for view in [avatar, title, body] { contentView.addSubview(view) }
        NSLayoutConstraint.activate([
            avatar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            avatar.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            avatar.widthAnchor.constraint(equalToConstant: 40),
            avatar.heightAnchor.constraint(equalToConstant: 40),
            title.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 10),
            title.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            title.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            body.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            body.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(_ row: FeedRow, expanded: Bool) {
        let env = AppEnvironment.shared
        avatar.fmSetImage(env.urls.avatar(row.avatarId ?? (row.index % 64) + 1), loader: env.images)
        title.text = row.title
        body.text = row.lines.joined(separator: "\n")
        body.numberOfLines = expanded ? 0 : 3
    }
}

/// The sticky "Week N" header of a section (the data's header row).
final class FeedHeaderView: UITableViewHeaderFooterView {
    static let reuse = "FeedHeaderView"
    private let label = UILabel.fm("", size: 14, weight: .bold, color: .secondaryLabel)

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            label.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func show(_ text: String, index: Int) {
        label.text = text
        accessibilityIdentifier = "fm-feed-row-\(index)"
    }
}
