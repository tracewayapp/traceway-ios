import QuartzCore
import SwiftUI
import UIKit
import FieldmartCore

/// Markets (`02-APP-SPEC.md` §2.3): a header whose price changes on every
/// tick, the Core Graphics candle chart, timeframe tabs, a 300-row watchlist
/// (`UITableView`, `CAShapeLayer` sparklines) and a SwiftUI order book
/// sheet. Ticks follow `TickModel`: tick `n` is `n × 100 ms` after the screen
/// first appeared; a display link applies every tick that is due.
final class MarketsViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    static let timeframes = ["1H", "1D", "1W", "1M", "1Y"]
    static let candleTicks = 50
    static let sparkLength = 30

    private let env = AppEnvironment.shared
    private let symbolLabel = UILabel.fm("", size: 15, weight: .semibold, color: .secondaryLabel)
    private let priceLabel = UILabel.fm("", size: 30, weight: .bold)
    private let changeLabel = UILabel.fm("", size: 15, weight: .semibold)
    private let quotesLabel = UILabel.fm(FMText.Markets.polls(0), size: 12, color: .secondaryLabel)
    private let watchlistTitle = UILabel.fm(FMText.Markets.watchlist, size: 17, weight: .bold)
    private let chart = ChartView()
    private var timeframeButtons: [UIButton] = []
    private let bookButton = UIButton.fm(FMText.Markets.openBook, id: "fm-markets-book-open")
    private let tableView = UITableView(frame: .zero, style: .plain)

    private var symbols: [MarketSymbol] = []
    private var model: TickModel?
    private var history: [[Int]] = []
    private var startTime: CFTimeInterval?
    private var link: CADisplayLink?
    private var pollTimer: Timer?
    private var quotes = 0
    private var timeframe = "1H"
    private var candleStep: Int64 = 60
    private var pendingRows = Set<Int>()
    private weak var book: OrderBookModel?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = FMText.Markets.title
        navigationItem.largeTitleDisplayMode = .never

        priceLabel.font = .monospacedDigitSystemFont(ofSize: 30, weight: .bold)
        priceLabel.accessibilityIdentifier = "fm-markets-price"
        priceLabel.layer.cornerRadius = 6
        priceLabel.layer.masksToBounds = true
        changeLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)

        let priceRow = UIStackView(arrangedSubviews: [priceLabel, changeLabel, UIView(), quotesLabel])
        priceRow.axis = .horizontal
        priceRow.spacing = 10
        priceRow.alignment = .center

        timeframeButtons = FMText.Markets.timeframes.map { name in
            let button = UIButton.fm(name, id: "fm-markets-tf-\(name)", size: 14)
            button.layer.cornerRadius = 8
            button.widthAnchor.constraint(equalToConstant: 44).isActive = true
            button.fmOnTap { [weak self] in self?.select(timeframe: name) }
            return button
        }
        let tabs = UIStackView(arrangedSubviews: timeframeButtons + [bookButton])
        tabs.axis = .horizontal
        tabs.spacing = 6
        tabs.distribution = .fill
        bookButton.contentHorizontalAlignment = .trailing
        bookButton.fmOnTap { [weak self] in self?.openBook() }

        let top = UIStackView(arrangedSubviews: [symbolLabel, priceRow, chart, tabs, watchlistTitle])
        top.axis = .vertical
        top.spacing = 6
        top.isLayoutMarginsRelativeArrangement = true
        top.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 12)
        top.translatesAutoresizingMaskIntoConstraints = false

        tableView.accessibilityIdentifier = "fm-markets-watchlist"
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 56
        tableView.register(WatchlistCell.self, forCellReuseIdentifier: WatchlistCell.reuse)
        tableView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(top)
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            top.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            top.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            top.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            chart.heightAnchor.constraint(equalToConstant: 240),
            tabs.heightAnchor.constraint(equalToConstant: 34),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: top.bottomAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        styleTimeframes()

        Autopilot.shared.scroll("fm-markets-watchlist", tableView)
        Autopilot.shared.tap(prefix: "fm-markets-tf-") { [weak self] name in self?.select(timeframe: name) }
        Autopilot.shared.tap("fm-markets-book-open") { [weak self] in self?.openBook() }

        loadSymbols()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        fmScreenAppeared("markets")
        if startTime == nil { startTime = CACurrentMediaTime() }
        startTicking()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // The order book sheet keeps the screen "visible" underneath.
        if presentedViewController == nil { stopTicking() }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if presentedViewController == nil { stopTicking() }
    }

    // MARK: - Ticks

    private func startTicking() {
        guard link == nil else { return }
        let link = CADisplayLink(target: TickProxy(self), selector: #selector(TickProxy.tick))
        link.preferredFramesPerSecond = 30
        link.add(to: .main, forMode: .common)
        self.link = link
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }
    }

    private func stopTicking() {
        link?.invalidate()
        link = nil
        pollTimer?.invalidate()
        pollTimer = nil
    }

    fileprivate func applyDueTicks() {
        guard let start = startTime, var model = model else { return }
        let elapsedMs = (CACurrentMediaTime() - start) * 1000
        let due = Int(elapsedMs / Double(TickModel.tickMs)) + 1
        guard due > model.ticks else { return }
        var lastUp = true
        while model.ticks < due {
            let n = model.ticks
            let before = model.cents.first ?? 0
            model.tick()
            let price = model.cents.first ?? 0
            lastUp = price >= before
            chart.update(lastPrice: price, startNew: n > 0 && n % MarketsViewController.candleTicks == 0, step: candleStep)
            for row in TickModel.rowsUpdated(onTick: n, symbolCount: model.cents.count) {
                history[row].append(model.cents[row])
                if history[row].count > MarketsViewController.sparkLength { history[row].removeFirst() }
                pendingRows.insert(row)
            }
        }
        self.model = model
        chart.refresh()
        showHeader(flashUp: lastUp)
        refreshVisibleRows()
        book?.setMid(model.cents.first ?? 0)
    }

    private func showHeader(flashUp: Bool?) {
        guard let model = model, let first = symbols.first else { return }
        let price = model.cents.first ?? first.startCents
        symbolLabel.text = "\(first.symbol) · \(first.name)"
        priceLabel.text = FMFormat.cents(price)
        changeLabel.text = FMFormat.changePercent(from: first.startCents, to: price)
        changeLabel.textColor = price >= first.startCents ? Palette.up : Palette.down
        // A flash without animation: one tick green or red, then the next tick decides again.
        if let up = flashUp {
            priceLabel.backgroundColor = (up ? Palette.up : Palette.down).withAlphaComponent(0.18)
        }
        quotesLabel.text = FMText.Markets.polls(quotes)
    }

    private func refreshVisibleRows() {
        guard !pendingRows.isEmpty, let model = model else { return }
        for indexPath in tableView.indexPathsForVisibleRows ?? [] where pendingRows.contains(indexPath.row) {
            (tableView.cellForRow(at: indexPath) as? WatchlistCell)?.show(
                symbols[indexPath.row], cents: model.cents[indexPath.row], history: history[indexPath.row])
        }
        pendingRows.removeAll(keepingCapacity: true)
    }

    private func poll() {
        let since = model?.ticks ?? 0
        env.client.json(env.urls.quotes(since: since)) { [weak self] json in
            guard let self = self, json != nil else { return }
            self.quotes += 1
            self.quotesLabel.text = FMText.Markets.polls(self.quotes)
        }
    }

    // MARK: - Data

    private func loadSymbols() {
        env.client.json(env.urls.symbols) { [weak self] json in
            guard let self = self, let json = json else { return }
            let symbols = Fixtures.symbols(json)
            guard !symbols.isEmpty else { return }
            self.symbols = symbols
            self.model = TickModel(startCents: symbols.map(\.startCents))
            self.history = symbols.map { [$0.startCents] }
            self.tableView.reloadData()
            self.showHeader(flashUp: nil)
            self.loadCandles()
        }
    }

    private func loadCandles() {
        guard let first = symbols.first else { return }
        let requested = timeframe
        env.client.json(env.urls.candles(symbol: first.symbol, timeframe: requested)) { [weak self] json in
            guard let self = self, requested == self.timeframe, let json = json else { return }
            var candles = Fixtures.candles(json)
            if candles.count >= 2 { self.candleStep = max(1, candles[candles.count - 1].t - candles[candles.count - 2].t) }
            // The live candle starts at the current price.
            let price = self.model?.cents.first ?? first.startCents
            let t = (candles.last?.t ?? 0) + self.candleStep
            candles.append(Candle(t: t, open: price, high: price, low: price, close: price))
            self.chart.set(candles)
        }
    }

    private func select(timeframe name: String) {
        guard MarketsViewController.timeframes.contains(name) else { return }
        timeframe = name
        styleTimeframes()
        loadCandles()
    }

    private func styleTimeframes() {
        for (index, button) in timeframeButtons.enumerated() {
            let on = MarketsViewController.timeframes[index] == timeframe
            button.backgroundColor = on ? Palette.accent : .tertiarySystemFill
            button.setTitleColor(on ? .white : .label, for: .normal)
        }
    }

    private func openBook() {
        guard presentedViewController == nil else { return }
        let model = OrderBookModel(mid: self.model?.cents.first ?? symbols.first?.startCents ?? 10_000)
        book = model
        let host = UIHostingController(rootView: OrderBookView(model: model, close: { [weak self] in
            self?.dismiss(animated: true)
        }))
        host.modalPresentationStyle = .pageSheet
        if let sheet = host.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
            sheet.largestUndimmedDetentIdentifier = .medium
        }
        present(host, animated: true)
    }

    // MARK: - Watchlist

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        symbols.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: WatchlistCell.reuse, for: indexPath)
        if let row = cell as? WatchlistCell, indexPath.row < symbols.count {
            let cents = model?.cents[indexPath.row] ?? symbols[indexPath.row].startCents
            row.show(symbols[indexPath.row], cents: cents, history: history[indexPath.row])
        }
        return cell
    }
}

/// Holds the screen weakly for its display link.
private final class TickProxy: NSObject {
    weak var target: MarketsViewController?

    init(_ target: MarketsViewController) {
        self.target = target
    }

    @objc func tick() {
        target?.applyDueTicks()
    }
}

final class WatchlistCell: UITableViewCell {
    static let reuse = "WatchlistCell"
    private let symbol = UILabel.fm("", size: 15, weight: .bold)
    private let name = UILabel.fm("", size: 12, color: .secondaryLabel)
    private let spark = SparklineView()
    private let price = UILabel.fm("", size: 15, weight: .semibold)
    private let change = UILabel.fm("", size: 12, weight: .medium)

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        price.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        price.textAlignment = .right
        change.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        change.textAlignment = .right
        spark.translatesAutoresizingMaskIntoConstraints = false
        for view in [symbol, name, spark, price, change] { contentView.addSubview(view) }
        NSLayoutConstraint.activate([
            symbol.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            symbol.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 9),
            name.leadingAnchor.constraint(equalTo: symbol.leadingAnchor),
            name.topAnchor.constraint(equalTo: symbol.bottomAnchor, constant: 2),
            name.widthAnchor.constraint(lessThanOrEqualToConstant: 150),
            spark.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 180),
            spark.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            spark.widthAnchor.constraint(equalToConstant: 90),
            spark.heightAnchor.constraint(equalToConstant: 28),
            price.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            price.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 9),
            change.trailingAnchor.constraint(equalTo: price.trailingAnchor),
            change.topAnchor.constraint(equalTo: price.bottomAnchor, constant: 2),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func show(_ item: MarketSymbol, cents: Int, history: [Int]) {
        accessibilityIdentifier = "fm-markets-row-\(item.symbol)"
        symbol.text = item.symbol
        name.text = item.name
        price.text = FMFormat.cents(cents)
        let up = cents >= item.startCents
        change.text = FMFormat.changePercent(from: item.startCents, to: cents)
        change.textColor = up ? Palette.up : Palette.down
        spark.set(history, up: up)
    }
}
