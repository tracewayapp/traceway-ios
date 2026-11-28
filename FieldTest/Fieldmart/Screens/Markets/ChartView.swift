import UIKit
import FieldmartCore

/// The candle chart, drawn with Core Graphics in `draw(_:)` (H-I4: the SDK
/// records a view that draws itself as a dashed outline). The price axis,
/// the time axis, the current price and the crosshair tooltip are real
/// `UILabel`s.
final class ChartView: UIView {
    static let visibleCount = 80
    static let axisWidth: CGFloat = 64
    static let timeAxisHeight: CGFloat = 20

    private(set) var candles: [Candle] = []
    private var low = 0
    private var high = 1
    private let priceLabels = (0..<5).map { _ in UILabel.fm("", size: 10, color: .secondaryLabel) }
    private let timeLabels = (0..<4).map { _ in UILabel.fm("", size: 10, color: .secondaryLabel) }
    private let currentLabel = UILabel.fm("", size: 11, weight: .bold, color: .white)
    private let crosshair = UIView()
    private let tooltip = UILabel.fm("", size: 11, weight: .medium, lines: 2)
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()
    private static let tooltipFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemBackground
        isOpaque = true
        contentMode = .redraw
        accessibilityIdentifier = "fm-markets-chart"
        for label in priceLabels + timeLabels {
            label.translatesAutoresizingMaskIntoConstraints = true
            label.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            addSubview(label)
        }
        currentLabel.translatesAutoresizingMaskIntoConstraints = true
        currentLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .bold)
        currentLabel.textAlignment = .center
        currentLabel.layer.cornerRadius = 4
        currentLabel.layer.masksToBounds = true
        addSubview(currentLabel)
        crosshair.backgroundColor = UIColor.label.withAlphaComponent(0.6)
        crosshair.isHidden = true
        crosshair.isUserInteractionEnabled = false
        addSubview(crosshair)
        tooltip.translatesAutoresizingMaskIntoConstraints = true
        tooltip.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        tooltip.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.92)
        tooltip.layer.borderColor = Palette.line.cgColor
        tooltip.layer.borderWidth = 1
        tooltip.layer.cornerRadius = 6
        tooltip.layer.masksToBounds = true
        tooltip.isHidden = true
        tooltip.accessibilityIdentifier = "fm-markets-tooltip"
        addSubview(tooltip)
        let press = UILongPressGestureRecognizer(target: self, action: #selector(pressed(_:)))
        press.minimumPressDuration = 0.1
        press.allowableMovement = .greatestFiniteMagnitude
        addGestureRecognizer(press)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private var plotRect: CGRect {
        CGRect(x: 0, y: 6, width: max(1, bounds.width - ChartView.axisWidth),
               height: max(1, bounds.height - ChartView.timeAxisHeight - 6))
    }

    private var visible: ArraySlice<Candle> { candles.suffix(ChartView.visibleCount) }

    func set(_ candles: [Candle]) {
        self.candles = candles
        refresh()
    }

    /// The live (last) candle changed or a new one started.
    func update(lastPrice price: Int, startNew: Bool, step: Int64) {
        guard var last = candles.last else { return }
        if startNew {
            candles.append(Candle(t: last.t + step, open: price, high: price, low: price, close: price))
            if candles.count > 6000 { candles.removeFirst(candles.count - 6000) }
        } else {
            last.update(price: price)
            candles[candles.count - 1] = last
        }
    }

    /// Redraw and move the labels (once per display refresh with ticks).
    func refresh() {
        let window = visible
        if let minimum = window.map(\.low).min(), let maximum = window.map(\.high).max() {
            let pad = max(1, (maximum - minimum) / 12)
            low = minimum - pad
            high = maximum + pad
        }
        layoutLabels()
        setNeedsDisplay()
    }

    private func y(_ price: Int, in plot: CGRect) -> CGFloat {
        let span = CGFloat(max(1, high - low))
        return plot.maxY - CGFloat(price - low) / span * plot.height
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutLabels()
    }

    private func layoutLabels() {
        let plot = plotRect
        for (index, label) in priceLabels.enumerated() {
            let price = high - (high - low) * index / 4
            label.text = FMFormat.cents(price)
            label.frame = CGRect(x: plot.maxX + 6, y: y(price, in: plot) - 7, width: ChartView.axisWidth - 8, height: 14)
        }
        let window = Array(visible)
        for (index, label) in timeLabels.enumerated() {
            guard !window.isEmpty else { label.text = ""; continue }
            let candleIndex = min(window.count - 1, (window.count - 1) * index / 3)
            label.text = ChartView.timeFormatter.string(from: ChartView.date(window[candleIndex].t))
            let x = plot.minX + plot.width * CGFloat(index) / 3
            label.frame = CGRect(x: min(max(0, x - 30), plot.maxX - 60), y: plot.maxY + 4, width: 60, height: 14)
        }
        if let last = window.last {
            currentLabel.text = FMFormat.cents(last.close)
            currentLabel.backgroundColor = last.close >= last.open ? Palette.up : Palette.down
            currentLabel.frame = CGRect(x: plot.maxX + 2, y: y(last.close, in: plot) - 9, width: ChartView.axisWidth - 4,
                                        height: 18)
        }
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let plot = plotRect
        context.setStrokeColor(Palette.line.cgColor)
        context.setLineWidth(0.5)
        for index in 0..<5 {
            let lineY = plot.minY + plot.height * CGFloat(index) / 4
            context.move(to: CGPoint(x: plot.minX, y: lineY))
            context.addLine(to: CGPoint(x: plot.maxX, y: lineY))
        }
        context.strokePath()

        let window = Array(visible)
        guard !window.isEmpty else { return }
        let width = plot.width / CGFloat(ChartView.visibleCount)
        let offset = CGFloat(ChartView.visibleCount - window.count) * width
        for (index, candle) in window.enumerated() {
            let x = plot.minX + offset + (CGFloat(index) + 0.5) * width
            let color = candle.close >= candle.open ? Palette.up : Palette.down
            context.setStrokeColor(color.cgColor)
            context.setFillColor(color.cgColor)
            context.setLineWidth(1)
            context.move(to: CGPoint(x: x, y: y(candle.high, in: plot)))
            context.addLine(to: CGPoint(x: x, y: y(candle.low, in: plot)))
            context.strokePath()
            let top = y(max(candle.open, candle.close), in: plot)
            let bottom = y(min(candle.open, candle.close), in: plot)
            context.fill(CGRect(x: x - width * 0.35, y: top, width: width * 0.7, height: max(1, bottom - top)))
        }
        if let last = window.last {
            let lineY = y(last.close, in: plot)
            context.setStrokeColor(UIColor.secondaryLabel.cgColor)
            context.setLineWidth(0.75)
            context.setLineDash(phase: 0, lengths: [3, 3])
            context.move(to: CGPoint(x: plot.minX, y: lineY))
            context.addLine(to: CGPoint(x: plot.maxX, y: lineY))
            context.strokePath()
        }
    }

    // MARK: - Crosshair

    @objc private func pressed(_ press: UILongPressGestureRecognizer) {
        switch press.state {
        case .began, .changed:
            showCrosshair(at: press.location(in: self).x)
        default:
            crosshair.isHidden = true
            tooltip.isHidden = true
        }
    }

    private func showCrosshair(at x: CGFloat) {
        let plot = plotRect
        let window = Array(visible)
        guard !window.isEmpty else { return }
        let width = plot.width / CGFloat(ChartView.visibleCount)
        let offset = CGFloat(ChartView.visibleCount - window.count) * width
        let index = max(0, min(window.count - 1, Int((x - plot.minX - offset) / width)))
        let candle = window[index]
        let lineX = plot.minX + offset + (CGFloat(index) + 0.5) * width
        crosshair.isHidden = false
        crosshair.frame = CGRect(x: lineX - 0.5, y: plot.minY, width: 1, height: plot.height)
        tooltip.isHidden = false
        tooltip.text = " \(ChartView.tooltipFormatter.string(from: ChartView.date(candle.t)))\n"
            + " O \(FMFormat.cents(candle.open)) H \(FMFormat.cents(candle.high)) "
            + "L \(FMFormat.cents(candle.low)) C \(FMFormat.cents(candle.close))"
        let size = CGSize(width: 250, height: 34)
        let tooltipX = lineX + 8 + size.width > plot.maxX ? lineX - 8 - size.width : lineX + 8
        tooltip.frame = CGRect(origin: CGPoint(x: max(0, tooltipX), y: plot.minY + 4), size: size)
    }

    /// Candle times may be seconds or milliseconds.
    static func date(_ t: Int64) -> Date {
        Date(timeIntervalSince1970: t > 100_000_000_000 ? Double(t) / 1000 : Double(t))
    }
}
