import SwiftUI
import FieldmartCore

/// One price level of the order book.
struct BookLevel: Identifiable, Equatable {
    let id: Int
    var cents: Int
    var size: Int
}

/// 20 bids and 20 asks around the current price; every size changes five
/// times a second (from the shared generator, so every platform shows the
/// same numbers).
final class OrderBookModel: ObservableObject {
    @Published private(set) var bids: [BookLevel] = []
    @Published private(set) var asks: [BookLevel] = []
    private var mid: Int
    private var random = FMRandom(seed: TickModel.baseSeed ^ 0xB00C)
    private var timer: Timer?

    init(mid: Int) {
        self.mid = max(100, mid)
        rebuild()
    }

    func start() {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.tick() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func setMid(_ cents: Int) {
        guard cents > 0, cents != mid else { return }
        mid = cents
    }

    private func rebuild() {
        let step = max(1, mid / 2000)
        bids = (0..<20).map { BookLevel(id: $0, cents: mid - step * ($0 + 1), size: 100 + random.nextInt(900)) }
        asks = (0..<20).map { BookLevel(id: $0, cents: mid + step * ($0 + 1), size: 100 + random.nextInt(900)) }
    }

    private func tick() {
        rebuild()
    }
}

struct OrderBookView: View {
    @ObservedObject var model: OrderBookModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(FMText.Markets.orderBook).font(.headline)
                Spacer()
                Button(FMText.Markets.close, action: close).fmID("fm-markets-book-close")
            }
            HStack(alignment: .top, spacing: 16) {
                column(FMText.Markets.bids, levels: model.bids, color: Color(Palette.up))
                column(FMText.Markets.asks, levels: model.asks, color: Color(Palette.down))
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .fmContainer("fm-markets-book")
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    private func column(_ title: String, levels: [BookLevel], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundColor(.secondary)
            ForEach(levels) { level in
                HStack {
                    Text(FMFormat.cents(level.cents)).foregroundColor(color)
                    Spacer()
                    Text("\(level.size)")
                }
                .font(.system(size: 12, design: .monospaced))
            }
        }
        .frame(maxWidth: .infinity)
    }
}
