import Foundation

/// The 32-bit generator every Fieldmart build shares (`02-APP-SPEC.md` §3.4),
/// so the chart, the watchlist and the order book show the same numbers on
/// every platform. Every step wraps at 32 bits.
public struct FMRandom: Equatable {
    public private(set) var state: UInt32

    public init(seed: UInt32) {
        state = seed
    }

    /// The next value in [0, 1).
    public mutating func next() -> Double {
        Double(nextUInt32()) / 4_294_967_296.0
    }

    /// The next raw 32-bit value (what `next()` divides by 2^32).
    public mutating func nextUInt32() -> UInt32 {
        state = state &+ 0x6D2B_79F5
        var t = state
        t = (t ^ (t >> 15)) &* (t | 1)
        t ^= t &+ ((t ^ (t >> 7)) &* (t | 61))
        return t ^ (t >> 14)
    }

    /// An integer in `0..<bound` (bound > 0).
    public mutating func nextInt(_ bound: Int) -> Int {
        guard bound > 1 else { return 0 }
        return min(bound - 1, Int(next() * Double(bound)))
    }
}

/// The tick model of the Markets screen: symbol `k` has its own generator
/// seeded `20261128 XOR (k × 2654435761 mod 2^32)`; on each tick its price
/// becomes `max(1, round(cents × (1 + (u − 0.5) × 0.004)))`. Tick `n` is
/// `n × 100 ms` after the Markets screen first appeared.
public struct TickModel {
    public static let baseSeed: UInt32 = 20_261_128
    public static let tickMs = 100

    public static func seed(forSymbol k: Int) -> UInt32 {
        baseSeed ^ (UInt32(truncatingIfNeeded: k) &* 2_654_435_761)
    }

    /// One tick of one price.
    public static func step(_ cents: Int, u: Double) -> Int {
        let next = (Double(cents) * (1 + (u - 0.5) * 0.004)).rounded(.toNearestOrAwayFromZero)
        return max(1, Int(next))
    }

    public private(set) var cents: [Int]
    public private(set) var generators: [FMRandom]
    /// Ticks applied so far: prices are those after tick `ticks - 1`.
    public private(set) var ticks: Int = 0

    public init(startCents: [Int]) {
        cents = startCents
        generators = startCents.indices.map { FMRandom(seed: TickModel.seed(forSymbol: $0)) }
    }

    /// Applies one tick to every symbol.
    public mutating func tick() {
        for k in cents.indices {
            cents[k] = TickModel.step(cents[k], u: generators[k].next())
        }
        ticks += 1
    }

    /// Applies ticks until `ticks == count` (never goes back).
    public mutating func advance(to count: Int) {
        while ticks < count { tick() }
    }

    /// The symbols whose watchlist rows show a new price on tick `n`: 30 of
    /// the 300, in round-robin order.
    public static func rowsUpdated(onTick n: Int, symbolCount: Int, perTick: Int = 30) -> [Int] {
        guard symbolCount > 0 else { return [] }
        let first = (n * perTick) % symbolCount
        return (0..<min(perTick, symbolCount)).map { (first + $0) % symbolCount }
    }

    /// The first `count` prices of symbol `k` from `startCents` (for tests
    /// and the reference file).
    public static func series(symbol k: Int, startCents: Int, count: Int) -> [Int] {
        var generator = FMRandom(seed: seed(forSymbol: k))
        var cents = startCents
        var out: [Int] = []
        out.reserveCapacity(count)
        for _ in 0..<count {
            cents = step(cents, u: generator.next())
            out.append(cents)
        }
        return out
    }
}
