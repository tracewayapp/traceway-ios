import SwiftUI
import UIKit
import FieldmartCore

/// Feed as a SwiftUI `List` (`fmToolkit=swiftui`), on the same store.
final class FeedListModel: ObservableObject {
    let store = FeedStore()
    @Published private(set) var version = 0
    @Published var expanded = Set<Int>()
    @Published var gotoText = ""
    /// A scroll request: the row and a counter, so the same row twice still
    /// scrolls.
    @Published private(set) var target: ScrollTarget?

    struct ScrollTarget: Equatable {
        let index: Int
        let bottom: Bool
        let serial: Int
    }

    private var serial = 0

    init() {
        store.onLoaded.append { [weak self] _ in self?.version += 1 }
        store.ensure(0)
        store.ensure(FeedStore.pageSize)
    }

    func row(_ index: Int) -> FeedRow? { store.row(index) }

    func appeared(_ index: Int) {
        store.ensure(index + FeedStore.pageSize / 2)
        store.ensure(max(0, index - FeedStore.pageSize / 2))
    }

    func jump(to index: Int, bottom: Bool) {
        let clamped = max(0, min(store.total - 1, index))
        store.ensure(clamped) { [weak self] in
            guard let self = self else { return }
            self.serial += 1
            // A header row is its section's header: scroll to the section's first row.
            let row = FeedStore.isHeader(clamped) ? min(self.store.total - 1, clamped + 1) : clamped
            self.target = ScrollTarget(index: row, bottom: bottom, serial: self.serial)
        }
    }

    func toggle(_ index: Int) {
        guard store.row(index)?.kind == .message else { return }
        if expanded.contains(index) { expanded.remove(index) } else { expanded.insert(index) }
    }

    func refresh(_ done: @escaping () -> Void) {
        expanded = []
        store.refresh { [weak self] in
            self?.version += 1
            done()
        }
    }
}

struct FeedListView: View {
    @ObservedObject var model: FeedListModel

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            ScrollViewReader { proxy in
                List {
                    ForEach(0..<model.store.sectionCount, id: \.self) { section in
                        Section(header: Text(model.store.header(section))
                                    .fmID("fm-feed-row-\(section * FeedStore.sectionSize)")) {
                            ForEach(rowRange(section), id: \.self) { index in
                                FeedListRow(row: model.row(index), index: index,
                                            expanded: model.expanded.contains(index), version: model.version)
                                    .id(index)
                                    .contentShape(Rectangle())
                                    .onTapGesture { model.toggle(index) }
                                    .onAppear { model.appeared(index) }
                                    .fmID("fm-feed-row-\(index)")
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .accessibilityIdentifier("fm-feed-list")
                .onChange(of: model.target) { target in
                    guard let target = target else { return }
                    proxy.scrollTo(target.index, anchor: target.bottom ? .bottom : .top)
                }
                .refreshable {
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        DispatchQueue.main.async { model.refresh { continuation.resume() } }
                    }
                }
            }
        }
        .fmScreen("feed")
    }

    /// The data rows of a section after its header row.
    private func rowRange(_ section: Int) -> Range<Int> {
        let start = section * FeedStore.sectionSize + 1
        return start..<(start + model.store.rowsIn(section: section))
    }

    private var controls: some View {
        HStack(spacing: 10) {
            VStack(spacing: 6) {
                HStack(spacing: 14) {
                    Button(FMText.Feed.jumpStart) { model.jump(to: 0, bottom: false) }.fmID("fm-feed-jump-start")
                    Button(FMText.Feed.jumpEnd) { model.jump(to: model.store.total - 1, bottom: true) }
                        .fmID("fm-feed-jump-end")
                    Spacer()
                    Button(FMText.Feed.refresh) { model.refresh {} }.fmID("fm-feed-refresh")
                }
                HStack(spacing: 10) {
                    TextField(FMText.Feed.goTo, text: $model.gotoText)
                        .keyboardType(.numberPad)
                        .textFieldStyle(.roundedBorder)
                        .fmID("fm-feed-goto-field")
                    Button(FMText.Feed.go) {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                        if let row = Int(model.gotoText.trimmingCharacters(in: .whitespaces)) { model.jump(to: row, bottom: false) }
                    }.fmID("fm-feed-goto-go")
                }
            }
        }
        .font(.system(size: 14, weight: .semibold))
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }
}

private struct FeedListRow: View {
    let row: FeedRow?
    let index: Int
    let expanded: Bool
    let version: Int

    var body: some View {
        Group {
            if let row = row {
                switch row.kind {
                case .shipment: shipment(row)
                case .alert: alert(row)
                case .message: message(row)
                case .order, .header: order(row)
                }
            } else {
                Text(" ").frame(height: 44)
            }
        }
    }

    private func order(_ row: FeedRow) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "shippingbox").foregroundColor(Color(Palette.accent))
            Text(row.title).font(.system(size: 15, weight: row.kind == .header ? .bold : .regular)).lineLimit(1)
            Spacer()
            Text(row.time).font(.system(size: 12)).foregroundColor(.secondary)
        }
    }

    private func shipment(_ row: FeedRow) -> some View {
        HStack(alignment: .top, spacing: 12) {
            FreshImage(url: row.productId.map { AppEnvironment.shared.urls.productImage($0, size: 160) })
                .frame(width: 80, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                Text(row.title).font(.system(size: 15, weight: .semibold)).lineLimit(2)
                Text(row.text).font(.system(size: 13)).foregroundColor(.secondary).lineLimit(1)
                ProgressView(value: max(0, min(1, row.progress)))
            }
        }
    }

    private func alert(_ row: FeedRow) -> some View {
        HStack {
            Text(row.title).font(.system(size: 15, weight: .semibold))
            Spacer()
            Text(FMFormat.price(row.priceCents ?? 10_000)).font(.system(size: 13, design: .monospaced))
        }
    }

    private func message(_ row: FeedRow) -> some View {
        HStack(alignment: .top, spacing: 10) {
            StableImage(url: AppEnvironment.shared.urls.avatar(row.avatarId ?? (row.index % 64) + 1))
                .frame(width: 40, height: 40)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(row.title).font(.system(size: 15, weight: .semibold))
                Text(row.lines.joined(separator: "\n")).font(.system(size: 14)).lineLimit(expanded ? nil : 3)
            }
        }
    }
}

/// A picture from the app's stable loader.
struct StableImage: View {
    let url: URL?
    @StateObject private var holder = ImageHolder()

    var body: some View {
        ZStack {
            Color(UIColor.tertiarySystemFill)
            if let image = holder.image {
                Image(uiImage: image).resizable().scaledToFill()
            }
        }
        .onAppear { holder.load(url, fresh: false) }
    }
}

/// A picture decoded into a new `UIImage` each time it appears (H-I5).
struct FreshImage: View {
    let url: URL?
    @StateObject private var holder = ImageHolder()

    var body: some View {
        ZStack {
            Color(UIColor.tertiarySystemFill)
            if let image = holder.image {
                Image(uiImage: image).resizable().scaledToFill()
            }
        }
        .onAppear { holder.load(url, fresh: true) }
    }
}

final class ImageHolder: ObservableObject {
    @Published var image: UIImage?
    private var url: URL?

    func load(_ url: URL?, fresh: Bool) {
        guard let url = url else {
            image = nil
            return
        }
        self.url = url
        let env = AppEnvironment.shared
        let done: (UIImage?) -> Void = { [weak self] loaded in
            guard let self = self, self.url == url else { return }
            self.image = loaded
        }
        if fresh {
            env.freshImages.load(url, completion: done)
        } else {
            env.images.load(url, completion: done)
        }
    }
}
