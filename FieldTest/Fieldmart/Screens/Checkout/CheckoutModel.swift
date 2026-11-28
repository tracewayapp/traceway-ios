import Foundation
import SwiftUI
import FieldmartCore

/// Everything the checkout form holds. It lives as long as the app, so the
/// form keeps what was typed while the shopper visits another tab.
final class CheckoutModel: ObservableObject {
    @Published var name = ""
    @Published var email = ""
    @Published var phone = ""
    @Published var createAccount = false
    @Published var password = ""
    @Published var address = ""
    @Published var city = ""
    @Published var postcode = ""
    @Published var country = "Choose"
    @Published var countries: [String] = FMText.fallbackCountries
    @Published var deliveryDate = Calendar.current.startOfDay(for: Date())
    @Published var window = 0
    @Published var leaveAtDoor = false
    @Published var giftWrap = false
    @Published var giftNote = ""
    @Published var card = ""
    @Published var expiry = ""
    @Published var cvv = ""
    @Published var cardName = ""
    @Published var saveCard = false
    @Published var tip: Double = 10
    @Published var promo = ""
    @Published var promoOptions: [Promo] = []
    @Published var appliedPromo: String?
    @Published var menuChoice: Int?
    @Published var quantities = [1, 2, 1]
    @Published var rating = 0
    @Published var notes = ""
    @Published var agreed = false
    @Published var orderNumber: String?
    @Published var placing = false
    @Published var showCountry = false
    @Published var showDate = false
    @Published var showEdit = false

    private let env = AppEnvironment.shared
    private var promoWork: DispatchWorkItem?
    private var suppressPromoQuery = false

    init() {
        registerAutopilot()
    }

    var dateRange: ClosedRange<Date> {
        let today = Calendar.current.startOfDay(for: Date())
        let end = Calendar.current.date(byAdding: .day, value: 90, to: today) ?? today
        return today...end
    }

    var subtotalCents: Int {
        zip(quantities, FMText.editItemPrices).map { $0 * $1 }.reduce(0, +)
    }

    var tipCents: Int { Int((Double(subtotalCents) * tip / 100).rounded()) }

    func loadCountries() {
        guard countries == FMText.fallbackCountries else { return }
        env.client.json(env.urls.countries) { [weak self] json in
            guard let self = self, let json = json else { return }
            let names = Fixtures.countries(json)
            if !names.isEmpty { self.countries = names }
        }
    }

    /// Type-ahead for the promo field, 250 ms after the last change.
    func promoChanged(_ text: String) {
        promoWork?.cancel()
        if suppressPromoQuery {
            suppressPromoQuery = false
            return
        }
        appliedPromo = nil
        let query = text.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            promoOptions = []
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.env.client.json(self.env.urls.promos(query)) { [weak self] json in
                guard let self = self, let json = json, self.promo.trimmingCharacters(in: .whitespaces) == query else {
                    return
                }
                self.promoOptions = Array(Fixtures.promos(json).prefix(8))
            }
        }
        promoWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    func applyPromo(_ index: Int) {
        guard index >= 0, index < promoOptions.count else { return }
        suppressPromoQuery = true
        promo = promoOptions[index].code
        appliedPromo = promoOptions[index].code
        promoOptions = []
    }

    func change(item: Int, by delta: Int) {
        guard item >= 0, item < quantities.count else { return }
        quantities[item] = max(0, min(10, quantities[item] + delta))
    }

    func place() {
        guard !placing else { return }
        placing = true
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        let body: [String: Any] = [
            "name": name, "email": email, "phone": phone, "createAccount": createAccount,
            "address": address, "city": city, "postcode": postcode, "country": country,
            "deliveryDate": formatter.string(from: deliveryDate), "window": window, "leaveAtDoor": leaveAtDoor,
            "giftWrap": giftWrap, "giftNote": giftNote, "cardName": cardName, "saveCard": saveCard,
            "tipPercent": Int(tip.rounded()), "promo": appliedPromo ?? promo, "rating": rating, "notes": notes,
            "items": quantities, "instructions": menuChoice.map { FMText.menuItems[$0] } ?? "",
        ]
        env.client.post(env.urls.checkout, body: body) { [weak self] json, status in
            guard let self = self else { return }
            self.placing = false
            if let json = json, (200..<300).contains(status) {
                self.orderNumber = Fixtures.orderNumber(json) ?? "FM-000000"
                self.env.cart.clear()
            }
        }
    }

    /// After the success screen: an empty form for the next order.
    func reset() {
        name = ""; email = ""; phone = ""; createAccount = false; password = ""
        address = ""; city = ""; postcode = ""; country = "Choose"
        deliveryDate = Calendar.current.startOfDay(for: Date()); window = 0
        leaveAtDoor = false; giftWrap = false; giftNote = ""
        card = ""; expiry = ""; cvv = ""; cardName = ""; saveCard = false; tip = 10
        suppressPromoQuery = true; promo = ""; promoOptions = []; appliedPromo = nil
        menuChoice = nil; quantities = [1, 2, 1]; rating = 0; notes = ""; agreed = false
        orderNumber = nil; placing = false
    }

    private func registerAutopilot() {
        let autopilot = Autopilot.shared
        let fields: [(String, ReferenceWritableKeyPath<CheckoutModel, String>)] = [
            ("fm-checkout-name", \.name), ("fm-checkout-email", \.email), ("fm-checkout-phone", \.phone),
            ("fm-checkout-password", \.password), ("fm-checkout-address", \.address), ("fm-checkout-city", \.city),
            ("fm-checkout-postcode", \.postcode), ("fm-checkout-giftnote", \.giftNote), ("fm-checkout-card", \.card),
            ("fm-checkout-expiry", \.expiry), ("fm-checkout-cvv", \.cvv), ("fm-checkout-cardname", \.cardName),
            ("fm-checkout-promo", \.promo), ("fm-checkout-notes", \.notes),
        ]
        for (id, path) in fields {
            autopilot.text(id) { [weak self] text in
                guard let self = self else { return }
                self[keyPath: path] = text
            }
        }
        autopilot.tap("fm-checkout-account") { [weak self] in self?.createAccount.toggle() }
        autopilot.tap("fm-checkout-gift") { [weak self] in self?.giftWrap.toggle() }
        autopilot.tap("fm-checkout-door") { [weak self] in self?.leaveAtDoor.toggle() }
        autopilot.tap("fm-checkout-savecard") { [weak self] in self?.saveCard.toggle() }
        autopilot.tap("fm-checkout-place") { [weak self] in self?.place() }
        autopilot.tap(prefix: "fm-checkout-window-") { [weak self] suffix in
            if let index = Int(suffix) { self?.window = index }
        }
        autopilot.tap(prefix: "fm-checkout-rating-") { [weak self] suffix in
            if let value = Int(suffix) { self?.rating = value }
        }
        autopilot.tap(prefix: "fm-checkout-promo-option-") { [weak self] suffix in
            if let index = Int(suffix) { self?.applyPromo(index) }
        }
    }
}
