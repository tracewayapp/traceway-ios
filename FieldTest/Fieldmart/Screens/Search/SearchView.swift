import SwiftUI
import UIKit
import FieldmartCore

final class SearchModel: ObservableObject {
    @Published var query = ""
    @Published private(set) var results: [Product] = []
    @Published private(set) var recent: [String] = []
    @Published private(set) var searching = false
    @Published private(set) var searched = false
    private let env = AppEnvironment.shared
    private var work: DispatchWorkItem?

    /// `GET /fx/api/search?q=` 250 ms after the last keystroke.
    func changed(_ text: String) {
        work?.cancel()
        let query = text.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            results = []
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.search(query) }
        self.work = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func search(_ query: String) {
        searching = true
        env.client.json(env.urls.search(query)) { [weak self] json in
            guard let self = self else { return }
            self.searching = false
            guard let json = json, self.query.trimmingCharacters(in: .whitespaces) == query else { return }
            self.results = Array(Fixtures.products(json).prefix(50))
            self.searched = true
            if query.count >= 3, !self.recent.contains(query) {
                self.recent.insert(query, at: 0)
                if self.recent.count > 5 { self.recent.removeLast() }
            }
        }
    }
}

/// Search (`02-APP-SPEC.md` §2.6): a field with type-ahead results and
/// recent searches as chips.
struct SearchView: View {
    let openProduct: (Int) -> Void
    @StateObject private var model = SearchModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(FMText.Search.field, text: $model.query)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .textFieldStyle(.roundedBorder)
                .fmID("fm-search-field")
                .padding(.horizontal, 16)
                .onChange(of: model.query) { text in model.changed(text) }
            if !model.recent.isEmpty {
                Text(FMText.Search.recent).font(.caption).foregroundColor(.secondary).padding(.horizontal, 16)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(model.recent.enumerated()), id: \.offset) { index, text in
                            Button(text) { model.query = text }
                                .font(.system(size: 14, weight: .medium))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Capsule().fill(Color(UIColor.tertiarySystemFill)))
                                .fmID("fm-search-recent-\(index)")
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            if model.searched && model.results.isEmpty {
                Text(FMText.Search.empty).foregroundColor(.secondary).padding(.horizontal, 16)
            }
            List {
                ForEach(Array(model.results.enumerated()), id: \.offset) { index, product in
                    Button { openProduct(product.id) } label: {
                        HStack(spacing: 12) {
                            StableImage(url: AppEnvironment.shared.urls.productImage(product.id, size: 160))
                                .frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(product.title).font(.system(size: 15, weight: .medium)).lineLimit(2)
                                Text(FMFormat.price(product.priceCents)).font(.system(size: 14, weight: .bold))
                            }
                        }
                    }
                    .foregroundColor(.primary)
                    .fmID("fm-search-result-\(index)")
                }
            }
            .listStyle(.plain)
            .accessibilityIdentifier("fm-search-results")
        }
        .padding(.top, 8)
        .fmScreen("search")
    }
}
