import Foundation

typealias MetricDims = [String: String]

struct MetricExemplar {
    let value: Double
    let timeMs: Int64
    let sessionId: String
    /// What caused the value, when known.
    var target: String?
}

final class HistogramPoint {
    let name: String
    let unit: String
    let dims: MetricDims
    var histogram = Histogram()
    var exemplars: [MetricExemplar] = []

    init(name: String, unit: String, dims: MetricDims) {
        self.name = name
        self.unit = unit
        self.dims = dims
    }
}

final class SumPoint {
    let name: String
    let dims: MetricDims
    var value: Double = 0

    init(name: String, dims: MetricDims) {
        self.name = name
        self.dims = dims
    }
}

/// Everything observed between two flushes. Delta temporality, so batches
/// from different devices add up.
struct MetricBatch {
    let startMs: Int64
    let endMs: Int64
    let histograms: [HistogramPoint]
    let sums: [SumPoint]

    var cells: Int { histograms.count + sums.count }
}

private let defaultMaxCells = 200
private let maxExemplars = 3
/// Room for the folded cells, so folding never has to drop an observation
/// of a known metric.
private let foldHeadroom = 50

let overflowValue = "other"

/// The dimension folded to `overflowValue` when there are too many cells:
/// the screen, as the browser SDK folds the page path.
let screenDimension = "screen"

private func metricCellKey(_ name: String, _ dims: MetricDims) -> String {
    guard !dims.isEmpty else { return name }
    var out = name
    for (key, value) in dims.sorted(by: { $0.key < $1.key }) {
        out += "\u{1f}\(key)=\(value)"
    }
    return out
}

/// The metrics of one device between two uploads. An observation increments
/// a bucket or a counter and nothing else: memory depends on the number of
/// cells, never on how long the app runs. A port of the browser SDK's
/// `MetricAggregator`, cell for cell the Android SDK's.
///
/// Not thread-safe: `MetricsRecorder` calls it under its lock.
final class MetricAggregator {
    private let maxCells: Int
    private let now: () -> Int64
    /// Insertion order, as the payload lists the cells.
    private var histogramKeys: [String] = []
    private var histograms: [String: HistogramPoint] = [:]
    private var sumKeys: [String] = []
    private var sums: [String: SumPoint] = [:]
    private var startMs: Int64

    /// Observations lost because the cell limit was reached even after
    /// folding.
    private(set) var dropped = 0

    init(maxCells: Int = defaultMaxCells, now: @escaping () -> Int64 = Clock.nowMs) {
        self.maxCells = maxCells
        self.now = now
        startMs = now()
    }

    var size: Int { histograms.count + sums.count }

    /// `exemplarSession` is passed only for a value worth opening a session
    /// for.
    func observe(
        _ name: String,
        _ value: Double,
        dims: MetricDims = [:],
        unit: String = "",
        exemplarSession: String? = nil,
        exemplarTarget: String? = nil
    ) {
        guard let key = cellKey(forHistogram: name, dims) else { return }
        let cell: HistogramPoint
        if let existing = histograms[key.key] {
            cell = existing
        } else {
            cell = HistogramPoint(name: name, unit: unit, dims: key.dims)
            histograms[key.key] = cell
            histogramKeys.append(key.key)
        }
        guard cell.histogram.record(value) else { return }
        if let session = exemplarSession, !session.isEmpty {
            keepExemplar(cell, MetricExemplar(value: value, timeMs: now(), sessionId: session, target: exemplarTarget))
        }
    }

    func count(_ name: String, _ n: Double = 1, dims: MetricDims = [:]) {
        guard n.isFinite, n > 0 else { return }
        guard let key = cellKey(forSum: name, dims) else { return }
        if let existing = sums[key.key] {
            existing.value += n
        } else {
            let cell = SumPoint(name: name, dims: key.dims)
            cell.value = n
            sums[key.key] = cell
            sumKeys.append(key.key)
        }
    }

    /// A ratio is two counters, `<name>` and `<name>.total`, so ratios from
    /// different devices add up.
    func ratio(_ name: String, part: Double, total: Double, dims: MetricDims = [:]) {
        guard total > 0 else { return }
        count("\(name).total", total, dims: dims)
        count(name, min(max(part, 0), total), dims: dims)
    }

    /// Hands over what was collected and starts a new interval. Nil when
    /// nothing was observed.
    func drain() -> MetricBatch? {
        let endMs = now()
        let begin = startMs
        startMs = endMs
        guard size > 0 else { return nil }
        let batch = MetricBatch(
            startMs: begin,
            endMs: endMs,
            histograms: histogramKeys.compactMap { histograms[$0] },
            sums: sumKeys.compactMap { sums[$0] }
        )
        histograms = [:]
        histogramKeys = []
        sums = [:]
        sumKeys = []
        return batch
    }

    private func cellKey(forHistogram name: String, _ dims: MetricDims) -> (key: String, dims: MetricDims)? {
        resolve(name, dims) { histograms[$0] != nil }
    }

    private func cellKey(forSum name: String, _ dims: MetricDims) -> (key: String, dims: MetricDims)? {
        resolve(name, dims) { sums[$0] != nil }
    }

    /// The cell an observation goes to: its own, or past the limit the one
    /// with the screen folded to `other`; nil when even that does not fit.
    private func resolve(
        _ name: String,
        _ dims: MetricDims,
        exists: (String) -> Bool
    ) -> (key: String, dims: MetricDims)? {
        let key = metricCellKey(name, dims)
        if exists(key) { return (key, dims) }
        guard size >= maxCells else { return (key, dims) }
        guard dims[screenDimension] != nil, size < maxCells + foldHeadroom else {
            dropped += 1
            return nil
        }
        var folded = dims
        folded[screenDimension] = overflowValue
        return (metricCellKey(name, folded), folded)
    }

    /// Keeps the highest values: an exemplar is a session worth opening.
    private func keepExemplar(_ cell: HistogramPoint, _ exemplar: MetricExemplar) {
        if cell.exemplars.count < maxExemplars {
            cell.exemplars.append(exemplar)
            return
        }
        var lowest = 0
        for i in 1..<cell.exemplars.count where cell.exemplars[i].value < cell.exemplars[lowest].value {
            lowest = i
        }
        if cell.exemplars[lowest].value < exemplar.value { cell.exemplars[lowest] = exemplar }
    }
}
