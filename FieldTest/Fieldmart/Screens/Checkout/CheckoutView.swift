import SwiftUI
import UIKit
import FieldmartCore

/// The hosting controller for Checkout and what the SwiftUI form asks of
/// UIKit (the terms dialog is a UIKit modal with a `UITextView`).
enum CheckoutHost {
    static func make(model: CheckoutModel) -> UIViewController {
        let actions = CheckoutActions()
        let host = UIHostingController(rootView: CheckoutView(model: model, actions: actions))
        host.title = FMText.Checkout.title
        actions.host = host
        return host
    }
}

final class CheckoutActions {
    weak var host: UIViewController?

    func presentTerms(onAgree: @escaping () -> Void) {
        guard let host = host, host.presentedViewController == nil else { return }
        let terms = TermsViewController(onAgree: onAgree)
        host.present(terms, animated: true)
    }

    func goHome() {
        (host?.tabBarController as? RootTabBarController)?.select(.home)
    }
}

/// Checkout (`02-APP-SPEC.md` §2.5): one long scrolling form in four
/// sections with SwiftUI's standard controls. It is a `ScrollView` of
/// sections rather than a `Form`: a `Form` is a lazy list, and UI automation
/// cannot reach a field whose row has not been created yet.
struct CheckoutView: View {
    @ObservedObject var model: CheckoutModel
    let actions: CheckoutActions

    var body: some View {
        Group {
            if let order = model.orderNumber {
                success(order)
            } else {
                form
            }
        }
        .fmScreen("checkout")
    }

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                contact
                delivery
                payment
                review
            }
            .padding(16)
        }
        .accessibilityIdentifier("fm-checkout-form")
        .modifier(DismissKeyboardOnDrag())
        .onAppear { model.loadCountries() }
    }

    private func success(_ order: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 64)).foregroundColor(Color(Palette.up))
            Text(FMText.Checkout.success).font(.title.bold())
            Text(FMText.Checkout.successDetail(order)).font(.headline)
            Button("Continue shopping") { actions.goHome() }.fmID("fm-checkout-continue")
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fmContainer("fm-checkout-success")
        .onDisappear { model.reset() }
    }

    // MARK: - Sections

    private var contact: some View {
        CheckoutSection(title: FMText.Checkout.sections[0]) {
            LabeledField(label: FMText.Checkout.name) {
                TextField(FMText.Checkout.name, text: $model.name)
                    .fmText(.default)
                    .fmID("fm-checkout-name")
            }
            LabeledField(label: FMText.Checkout.email) {
                TextField(FMText.Checkout.email, text: $model.email)
                    .fmText(.emailAddress)
                    .fmID("fm-checkout-email")
            }
            LabeledField(label: FMText.Checkout.phone) {
                TextField(FMText.Checkout.phone, text: $model.phone)
                    .fmText(.phonePad)
                    .fmID("fm-checkout-phone")
            }
            Toggle(FMText.Checkout.account, isOn: $model.createAccount).fmID("fm-checkout-account")
            if model.createAccount {
                LabeledField(label: FMText.Checkout.password) {
                    SecureField(FMText.Checkout.password, text: $model.password)
                        .textFieldStyle(.roundedBorder)
                        .fmID("fm-checkout-password")
                }
            }
        }
    }

    private var delivery: some View {
        CheckoutSection(title: FMText.Checkout.sections[1]) {
            LabeledField(label: FMText.Checkout.address) {
                TextEditor(text: $model.address)
                    .fmEditor(height: 64)
                    .fmID("fm-checkout-address")
            }
            LabeledField(label: FMText.Checkout.city) {
                TextField(FMText.Checkout.city, text: $model.city).fmText(.default).fmID("fm-checkout-city")
            }
            LabeledField(label: FMText.Checkout.postcode) {
                TextField(FMText.Checkout.postcode, text: $model.postcode).fmText(.default).fmID("fm-checkout-postcode")
            }
            countryRow
            dateRow
            VStack(alignment: .leading, spacing: 6) {
                Text(FMText.Checkout.window).font(.subheadline.weight(.semibold))
                HStack(spacing: 8) {
                    ForEach(0..<FMText.Checkout.windows.count, id: \.self) { index in
                        Button { model.window = index } label: {
                            Text(FMText.Checkout.windows[index])
                                .font(.system(size: 14, weight: .medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .foregroundColor(model.window == index ? .white : .primary)
                                .background(RoundedRectangle(cornerRadius: 8)
                                    .fill(model.window == index ? Color(Palette.accent) : Color(UIColor.tertiarySystemFill)))
                        }
                        .buttonStyle(.plain)
                        .fmID("fm-checkout-window-\(index)")
                    }
                }
            }
            Toggle(FMText.Checkout.door, isOn: $model.leaveAtDoor).fmID("fm-checkout-door")
            Toggle(FMText.Checkout.gift, isOn: $model.giftWrap).fmID("fm-checkout-gift")
            if model.giftWrap {
                LabeledField(label: FMText.Checkout.giftNote) {
                    TextEditor(text: $model.giftNote).fmEditor(height: 56).fmID("fm-checkout-giftnote")
                }
            }
        }
    }

    private var countryRow: some View {
        Button { model.showCountry = true } label: {
            HStack {
                Text(FMText.Checkout.country).foregroundColor(.primary)
                Spacer()
                Text(model.country).foregroundColor(.secondary)
                Image(systemName: "chevron.up.chevron.down").foregroundColor(.secondary)
            }
            .padding(.vertical, 6)
        }
        .fmID("fm-checkout-country")
        .sheet(isPresented: $model.showCountry) {
            PickerSheet(title: FMText.Checkout.countryPicker, doneId: "fm-checkout-country-done", done: { model.showCountry = false }) {
                Picker(FMText.Checkout.country, selection: $model.country) {
                    ForEach(model.countries, id: \.self) { name in Text(name).tag(name) }
                }
                .pickerStyle(.wheel)
                .labelsHidden()
                .accessibilityIdentifier("fm-checkout-country-picker")
            }
            .onAppear { if model.country == "Choose", let first = model.countries.first { model.country = first } }
        }
    }

    private var dateRow: some View {
        Button { model.showDate = true } label: {
            HStack {
                Text(FMText.Checkout.date).foregroundColor(.primary)
                Spacer()
                Text(CheckoutView.dateText(model.deliveryDate)).foregroundColor(.secondary)
                Image(systemName: "calendar").foregroundColor(.secondary)
            }
            .padding(.vertical, 6)
        }
        .fmID("fm-checkout-date")
        .sheet(isPresented: $model.showDate) {
            PickerSheet(title: FMText.Checkout.datePicker, doneId: "fm-checkout-date-done", done: { model.showDate = false }) {
                DatePicker(FMText.Checkout.date, selection: $model.deliveryDate, in: model.dateRange,
                           displayedComponents: .date)
                    .datePickerStyle(.wheel)
                    .labelsHidden()
                    .accessibilityIdentifier("fm-checkout-date-picker")
            }
        }
    }

    private var payment: some View {
        CheckoutSection(title: FMText.Checkout.sections[2]) {
            LabeledField(label: FMText.Checkout.card) {
                TextField(FMText.Checkout.card, text: $model.card)
                    .fmText(.numberPad)
                    .fmID("fm-checkout-card")
                    .fmMask(.blur)
            }
            HStack(spacing: 12) {
                LabeledField(label: FMText.Checkout.expiry) {
                    TextField("MM/YY", text: $model.expiry).fmText(.numbersAndPunctuation).fmID("fm-checkout-expiry")
                }
                LabeledField(label: FMText.Checkout.cvv) {
                    TextField(FMText.Checkout.cvv, text: $model.cvv)
                        .fmText(.numberPad)
                        .fmID("fm-checkout-cvv")
                        .fmMask(.blank)
                }
            }
            LabeledField(label: FMText.Checkout.cardName) {
                TextField(FMText.Checkout.cardName, text: $model.cardName).fmText(.default).fmID("fm-checkout-cardname")
            }
            Toggle(FMText.Checkout.saveCard, isOn: $model.saveCard).fmID("fm-checkout-savecard")
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(FMText.Checkout.tip).font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(FMText.Checkout.tipValue(Int(model.tip.rounded()))).font(.subheadline)
                }
                Slider(value: $model.tip, in: 0...30, step: 1).fmID("fm-checkout-tip")
            }
            LabeledField(label: FMText.Checkout.promo) {
                TextField(FMText.Checkout.promo, text: $model.promo)
                    .fmText(.default)
                    .fmID("fm-checkout-promo")
                    .onChange(of: model.promo) { text in model.promoChanged(text) }
            }
            if let applied = model.appliedPromo {
                Text("Code \(applied) applied").font(.footnote).foregroundColor(Color(Palette.up))
            }
            ForEach(Array(model.promoOptions.enumerated()), id: \.offset) { index, promo in
                Button { model.applyPromo(index) } label: {
                    HStack {
                        Text(promo.code).font(.system(size: 15, weight: .semibold))
                        Text(promo.label).font(.footnote).foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
                .fmID("fm-checkout-promo-option-\(index)")
            }
        }
    }

    private var review: some View {
        CheckoutSection(title: FMText.Checkout.sections[3]) {
            summary
            reviewControls
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(FMText.Checkout.summary).font(.subheadline.weight(.semibold))
            ForEach(0..<FMText.editItems.count, id: \.self) { index in
                HStack {
                    Text("\(model.quantities[index]) × \(FMText.editItems[index])")
                    Spacer()
                    Text(FMFormat.price(model.quantities[index] * FMText.editItemPrices[index]))
                }
                .font(.system(size: 15))
            }
            HStack {
                Text("Tip").foregroundColor(.secondary)
                Spacer()
                Text(FMFormat.price(model.tipCents)).foregroundColor(.secondary)
            }
            HStack {
                Text("Total").font(.headline)
                Spacer()
                Text(FMFormat.price(model.subtotalCents + model.tipCents)).font(.headline)
            }
            HStack {
                Text(FMText.Checkout.loyalty).foregroundColor(.secondary)
                Spacer()
                LoyaltyLabel().frame(width: 150, height: 22)
            }
        }
    }

    private var reviewControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(FMText.Checkout.terms) {
                actions.presentTerms { model.agreed = true }
            }
            .fmID("fm-checkout-terms")
            if model.agreed {
                Text("Terms accepted").font(.footnote).foregroundColor(Color(Palette.up))
            }
            HStack {
                Text(FMText.Checkout.menu)
                Spacer()
                Menu {
                    ForEach(0..<FMText.Checkout.menuItems.count, id: \.self) { index in
                        Button(FMText.Checkout.menuItems[index]) { model.menuChoice = index }
                            .accessibilityIdentifier("fm-checkout-menu-item-\(index)")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.system(size: 22))
                }
                .accessibilityLabel(FMText.Checkout.menu)
                .fmID("fm-checkout-menu")
            }
            if let choice = model.menuChoice {
                Text(FMText.Checkout.menuItems[choice]).font(.footnote).foregroundColor(.secondary)
            }
            Button(FMText.Checkout.edit) { model.showEdit = true }
                .fmID("fm-checkout-edit")
                .sheet(isPresented: $model.showEdit) { EditItemsSheet(model: model) }
            finish
        }
    }

    private var finish: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(FMText.Checkout.rating).font(.subheadline.weight(.semibold))
                HStack(spacing: 6) {
                    ForEach(1...5, id: \.self) { value in
                        Button { model.rating = value } label: {
                            Image(systemName: value <= model.rating ? "star.fill" : "star")
                                .font(.system(size: 26))
                                .foregroundColor(.orange)
                        }
                        .accessibilityLabel("\(value) stars")
                        .fmID("fm-checkout-rating-\(value)")
                    }
                }
            }
            LabeledField(label: FMText.Checkout.notes) {
                TextEditor(text: $model.notes).fmEditor(height: 96).fmID("fm-checkout-notes")
            }
            Button { model.place() } label: {
                Text(FMText.Checkout.place)
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color(Palette.accent)))
            }
            .buttonStyle(.plain)
            .fmID("fm-checkout-place")
        }
    }

    static func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

/// A titled card of the form.
private struct CheckoutSection<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.bold())
            content
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(UIColor.secondarySystemBackground)))
    }
}

/// A caption over a control.
private struct LabeledField<Content: View>: View {
    let label: String
    let content: Content

    init(label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundColor(.secondary)
            content
        }
    }
}

/// A bottom sheet with one picker and a Done button.
private struct PickerSheet<Content: View>: View {
    let title: String
    let doneId: String
    let done: () -> Void
    let content: Content

    init(title: String, doneId: String, done: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.title = title
        self.doneId = doneId
        self.done = done
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button(FMText.Checkout.done, action: done).fmID(doneId)
            }
            content
            Spacer(minLength: 0)
        }
        .padding(16)
        .modifier(MediumDetent())
    }
}

/// "Edit items": a bottom sheet with a quantity stepper per item.
private struct EditItemsSheet: View {
    @ObservedObject var model: CheckoutModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(FMText.Checkout.edit).font(.headline)
                Spacer()
                Button(FMText.Checkout.done) { model.showEdit = false }.fmID("fm-checkout-edit-done")
            }
            ForEach(0..<FMText.editItems.count, id: \.self) { index in
                HStack {
                    Text(FMText.editItems[index])
                    Spacer()
                    Button { model.change(item: index, by: -1) } label: {
                        Image(systemName: "minus.circle").font(.system(size: 26))
                    }
                    .accessibilityLabel("Decrease")
                    .fmID("fm-checkout-edit-minus-\(index)")
                    Text("\(model.quantities[index])").font(.system(size: 17, weight: .semibold)).frame(width: 30)
                    Button { model.change(item: index, by: 1) } label: {
                        Image(systemName: "plus.circle").font(.system(size: 26))
                    }
                    .accessibilityLabel("Increase")
                    .fmID("fm-checkout-edit-plus-\(index)")
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .modifier(MediumDetent())
    }
}

/// A half-height sheet where the system supports detents (iOS 16).
private struct MediumDetent: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content.presentationDetents([.medium])
        } else {
            content
        }
    }
}

/// The loyalty number: a `UILabel` masked through the marker identifier
/// `traceway-mask` (the other masking route), inside a container that carries
/// the automation id `fm-checkout-loyalty`.
private struct LoyaltyLabel: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.accessibilityIdentifier = "fm-checkout-loyalty"
        let label = UILabel()
        label.text = FMText.loyaltyNumber
        label.font = .monospacedDigitSystemFont(ofSize: 15, weight: .medium)
        label.textAlignment = .right
        label.accessibilityIdentifier = "traceway-mask"
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            label.topAnchor.constraint(equalTo: container.topAnchor),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        container.accessibilityElements = [label]
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

/// Dragging the form dismisses the keyboard (iOS 16 and later).
private struct DismissKeyboardOnDrag: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content.scrollDismissesKeyboard(.immediately)
        } else {
            content
        }
    }
}

extension View {
    /// The text-entry settings every checkout field shares: no
    /// autocorrection or capitalisation, so typed text stays exact.
    func fmText(_ keyboard: UIKeyboardType) -> some View {
        self.keyboardType(keyboard)
            .textInputAutocapitalization(.never)
            .disableAutocorrection(true)
            .textFieldStyle(.roundedBorder)
    }

    /// A bordered multi-line editor.
    func fmEditor(height: CGFloat) -> some View {
        self.frame(height: height)
            .textInputAutocapitalization(.never)
            .disableAutocorrection(true)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(UIColor.separator)))
    }
}
