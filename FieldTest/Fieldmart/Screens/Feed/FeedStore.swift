import SwiftUI
import UIKit
import FieldmartCore

/// The 10,000 feed rows, fetched 100 at a time (`/fx/api/feed`) as they are
/// needed. Every 50 rows start a sticky "Week N" section. Main thread.
final class FeedStore {
    static let pageSize = 100
    static let sectionSize = 50

    private let env = AppEnvironment.shared
    private(set) var total: Int
    private var rows: [Int: FeedRow] = [:]
    private var loadedPages = Set<Int>()
    private var waiting: [Int: [() -> Void]] = [:]
    private var generation = 0
    /// Called with the index range of each page that arrives.
    var onLoaded: [(Range<Int>) -> Void] = []

    init(total: Int = 10_000) {
        self.total = total
    }

    // Every 50th row of the data is a "Week N" header: in a table it is the
    // sticky section header, and the section's rows are the 49 after it.
    var sectionCount: Int { (total + FeedStore.sectionSize - 1) / FeedStore.sectionSize }

    /// Rows of a section, not counting its header row.
    func rowsIn(section: Int) -> Int {
        max(0, min(FeedStore.sectionSize, total - section * FeedStore.sectionSize) - 1)
    }

    func row(_ index: Int) -> FeedRow? { rows[index] }

    /// The header text of a section (its header row's label).
    func header(_ section: Int) -> String {
        rows[section * FeedStore.sectionSize]?.title ?? FMText.Feed.header(section + 1)
    }

    static func isHeader(_ index: Int) -> Bool { index % sectionSize == 0 }

    static func index(_ indexPath: IndexPath) -> Int { indexPath.section * sectionSize + 1 + indexPath.row }

    /// The table position of data row `index` (a header row: its section's first row).
    static func indexPath(_ index: Int) -> IndexPath {
        IndexPath(row: max(0, index % sectionSize - 1), section: index / sectionSize)
    }

    /// Loads the page holding `index` (and calls `completion` once it is
    /// there).
    func ensure(_ index: Int, completion: (() -> Void)? = nil) {
        guard index >= 0, index < total else {
            completion?()
            return
        }
        let page = index / FeedStore.pageSize
        if loadedPages.contains(page) {
            completion?()
            return
        }
        if waiting[page] != nil {
            if let completion = completion { waiting[page]?.append(completion) }
            return
        }
        waiting[page] = completion.map { [$0] } ?? []
        let cursor = page * FeedStore.pageSize
        let generation = self.generation
        env.client.json(env.urls.feed(cursor: cursor, size: FeedStore.pageSize)) { [weak self] json in
            guard let self = self, generation == self.generation else { return }
            let callbacks = self.waiting.removeValue(forKey: page) ?? []
            if let json = json {
                self.loadedPages.insert(page)
                if let total = Fixtures.total(json), total > 0, total != self.total, page == 0 { self.total = total }
                let items = Fixtures.feed(json, cursor: cursor)
                for (offset, row) in items.enumerated() {
                    var row = row
                    if row.index < cursor || row.index >= cursor + FeedStore.pageSize { row.index = cursor + offset }
                    self.rows[row.index] = row
                }
                let range = cursor..<min(self.total, cursor + FeedStore.pageSize)
                for listener in self.onLoaded { listener(range) }
            }
            for callback in callbacks { callback() }
        }
    }

    /// Pull to refresh: drop everything and load the first page again.
    func refresh(completion: @escaping () -> Void) {
        generation += 1
        rows = [:]
        loadedPages = []
        waiting = [:]
        ensure(0, completion: completion)
    }

    /// The row height for a kind (fixed, so jumps land in the same place
    /// every run).
    static func height(_ row: FeedRow?, expanded: Bool, width: CGFloat) -> CGFloat {
        guard let row = row else { return 64 }
        switch row.kind {
        case .order: return 60
        case .shipment: return 104
        case .alert: return 64
        case .header: return 36
        case .message:
            guard expanded else { return 96 }
            let text = row.lines.joined(separator: "\n") as NSString
            let bounds = text.boundingRect(
                with: CGSize(width: max(100, width - 90), height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin], attributes: [.font: UIFont.systemFont(ofSize: 14)], context: nil)
            return max(96, ceil(bounds.height) + 44)
        }
    }

    /// The sparkline of a price alert row, from the shared generator.
    static func spark(for index: Int, around cents: Int) -> [Int] {
        var random = FMRandom(seed: TickModel.baseSeed ^ UInt32(truncatingIfNeeded: index))
        var value = max(100, cents)
        return (0..<20).map { _ in
            value = TickModel.step(value, u: random.next())
            return value
        }
    }
}

/// Jump to end, jump to start, go to row, refresh.
final class FeedControlsView: UIView {
    let jumpEnd = UIButton.fm(FMText.Feed.jumpEnd, id: "fm-feed-jump-end", size: 14)
    let jumpStart = UIButton.fm(FMText.Feed.jumpStart, id: "fm-feed-jump-start", size: 14)
    let field = UITextField()
    let go = UIButton.fm(FMText.Feed.go, id: "fm-feed-goto-go", size: 14)
    let refresh = UIButton.fm(FMText.Feed.refresh, id: "fm-feed-refresh", size: 14)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemBackground
        field.placeholder = FMText.Feed.goTo
        field.keyboardType = .numberPad
        field.borderStyle = .roundedRect
        field.accessibilityIdentifier = "fm-feed-goto-field"
        field.autocorrectionType = .no
        let first = UIStackView(arrangedSubviews: [jumpStart, jumpEnd, UIView(), refresh])
        first.axis = .horizontal
        first.spacing = 14
        first.alignment = .center
        let second = UIStackView(arrangedSubviews: [field, go])
        second.axis = .horizontal
        second.spacing = 10
        second.alignment = .center
        let stack = UIStackView(arrangedSubviews: [first, second])
        stack.axis = .vertical
        stack.spacing = 6
        addSubview(stack)
        stack.fmPin(to: self, insets: UIEdgeInsets(top: 6, left: 16, bottom: 8, right: 16))
        go.widthAnchor.constraint(equalToConstant: 44).isActive = true
        let separator = UIView()
        separator.backgroundColor = Palette.line
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)
        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 0.5),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The row number typed, if any (the keyboard is dismissed).
    func takeRow() -> Int? {
        field.resignFirstResponder()
        return Int(field.text?.trimmingCharacters(in: .whitespaces) ?? "")
    }
}

enum FeedFactory {
    static func make(_ toolkit: FeedToolkit) -> UIViewController {
        switch toolkit {
        case .uikit:
            return FeedViewController()
        case .stack:
            return FeedStackViewController()
        case .swiftui:
            let host = UIHostingController(rootView: FeedListView(model: FeedListModel()))
            host.title = FMText.Feed.title
            return host
        }
    }
}
