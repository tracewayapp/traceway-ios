import Foundation

/// The one scale every histogram uses, the server's included
/// (`backend/app/repositories/telemetry/shared/histogram.go`): bucket `i`
/// holds the values in (2^(i/8), 2^((i+1)/8)], about 9% wide, so a
/// percentile read from it is within about 4.5% of the true value. One scale
/// everywhere means histograms from different devices add up bucket by
/// bucket.
let histogramScale: Int32 = 3

private let bucketsPerDoubling = Double(1 << histogramScale)
private let zeroThreshold = 1e-6
private let maxHistogramValue = 1e12
private let invLn2 = 1.4426950408889634 // 1 / ln(2)

func bucketIndex(_ value: Double) -> Int {
    Int((goLog2(value) * bucketsPerDoubling).rounded(.up)) - 1
}

/// log2 the way Go computes it: exact for powers of two, where
/// `log(x) / ln2` is not, so a value on a bucket boundary lands in the
/// bucket the server would put it in.
func goLog2(_ x: Double) -> Double {
    let raw = x.bitPattern
    let exp = Int((raw >> 52) & 0x7ff) - 1022
    let frac = Double(bitPattern: (raw & ~(UInt64(0x7ff) << 52)) | (UInt64(1022) << 52))
    if frac == 0.5 { return Double(exp - 1) }
    return Foundation.log(frac) * invLn2 + Double(exp)
}

/// A base-2 exponential histogram at `histogramScale`, the shape OTLP calls
/// `ExponentialHistogram`, as the browser, Flutter and Android SDKs build it.
struct Histogram {
    private(set) var count: Int64 = 0
    private(set) var sum: Double = 0
    private(set) var min = Double.infinity
    private(set) var max = -Double.infinity
    private(set) var zeroCount: Int64 = 0
    private(set) var buckets: [Int: Int64] = [:]

    /// False for a value a histogram cannot hold (negative, NaN, infinite).
    @discardableResult
    mutating func record(_ value: Double) -> Bool {
        guard value.isFinite, value >= 0 else { return false }
        let v = Swift.min(value, maxHistogramValue)
        count += 1
        sum += v
        if v < min { min = v }
        if v > max { max = v }
        if v < zeroThreshold {
            zeroCount += 1
        } else {
            buckets[bucketIndex(v), default: 0] += 1
        }
        return true
    }
}
