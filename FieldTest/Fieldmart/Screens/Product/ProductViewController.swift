import UIKit
import FieldmartCore

/// Product (`02-APP-SPEC.md` §2.2): a `UITableView` whose header holds the
/// paging gallery, the summary, the size and colour pickers, the quantity
/// stepper and the description; its rows are the reviews (500 for product
/// 17), loaded 50 at a time. A sticky bar adds to the cart.
final class ProductViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    let productId: Int
    private let env = AppEnvironment.shared
    private let tableView = FMTableView(frame: .zero, style: .plain)
    private let header = ProductHeaderView()
    private let bar = UIView()
    private let barPrice = UILabel.fm("", size: 18, weight: .bold)
    private let addButton = UIButton.fmFilled(FMText.Product.add, id: "fm-product-add")
    private var detail: ProductDetail?
    private var reviews: [Review] = []
    private var nextReviewPage = 0
    private var loadingReviews = false
    private var reviewsExhausted = false
    private var helpful: Set<String> = []
    private var lastHeaderWidth: CGFloat = 0

    static let reviewPageSize = 50

    init(productId: Int) {
        self.productId = productId
        super.init(nibName: nil, bundle: nil)
        hidesBottomBarWhenPushed = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "Product"
        fmInstallBackButton()

        tableView.accessibilityIdentifier = "fm-product-reviews"
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 132
        tableView.register(ReviewCell.self, forCellReuseIdentifier: ReviewCell.reuse)
        tableView.tableHeaderView = header
        view.addSubview(tableView)
        tableView.fmPin(to: view)

        bar.backgroundColor = .systemBackground
        bar.layer.shadowColor = UIColor.black.cgColor
        bar.layer.shadowOpacity = 0.12
        bar.layer.shadowRadius = 6
        bar.layer.shadowOffset = CGSize(width: 0, height: -2)
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(barPrice)
        bar.addSubview(addButton)
        view.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 68),
            barPrice.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 16),
            barPrice.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            addButton.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -16),
            addButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])
        tableView.contentInset.bottom = 68
        tableView.verticalScrollIndicatorInsets.bottom = 68

        addButton.fmOnTap { [weak self] in self?.addToCart() }
        header.onLayoutChange = { [weak self] in self?.resizeHeader(force: true) }

        Autopilot.shared.scroll("fm-product-reviews", tableView)
        Autopilot.shared.scroll("fm-product-gallery", header.gallery.scroll)
        Autopilot.shared.tap("fm-product-add") { [weak self] in self?.addToCart() }
        Autopilot.shared.tap("fm-product-readmore") { [weak self] in self?.header.toggleReadMore() }

        loadDetail()
        loadReviews()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        fmScreenAppeared("product")
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        resizeHeader(force: false)
    }

    /// A table header does not size itself: measure it for the table's
    /// width and assign it again when its height changes.
    private func resizeHeader(force: Bool) {
        let width = tableView.bounds.width
        guard width > 0, force || width != lastHeaderWidth else { return }
        lastHeaderWidth = width
        let size = header.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        if abs(header.frame.height - size.height) > 0.5 || header.frame.width != width {
            header.frame = CGRect(x: 0, y: 0, width: width, height: size.height)
            tableView.tableHeaderView = header
        }
    }

    // MARK: - Data

    private func loadDetail() {
        env.client.json(env.urls.product(productId)) { [weak self] json in
            guard let self = self, let json = json, let detail = ProductDetail(json: json) else { return }
            self.detail = detail
            self.header.configure(detail)
            self.barPrice.text = FMFormat.price(detail.product.priceCents)
            self.resizeHeader(force: true)
        }
    }

    private func loadReviews() {
        guard !loadingReviews, !reviewsExhausted else { return }
        loadingReviews = true
        let page = nextReviewPage
        env.client.json(env.urls.reviews(product: productId, page: page, size: ProductViewController.reviewPageSize)) {
            [weak self] json in
            guard let self = self else { return }
            self.loadingReviews = false
            guard let json = json else { return }
            let items = Fixtures.reviews(json)
            self.nextReviewPage = page + 1
            if items.count < ProductViewController.reviewPageSize { self.reviewsExhausted = true }
            let known = Set(self.reviews.map(\.id))
            let fresh = items.filter { !known.contains($0.id) }
            guard !fresh.isEmpty else { return }
            let start = self.reviews.count
            self.reviews.append(contentsOf: fresh)
            let paths = (start..<self.reviews.count).map { IndexPath(row: $0, section: 0) }
            UIView.performWithoutAnimation {
                self.tableView.insertRows(at: paths, with: .none)
            }
            self.header.setReviewCount(self.detail?.product.reviewCount ?? self.reviews.count)
        }
    }

    // MARK: - Table

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        reviews.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: ReviewCell.reuse, for: indexPath)
        guard let review = cell as? ReviewCell, indexPath.row < reviews.count else { return cell }
        let item = reviews[indexPath.row]
        review.configure(item, helpful: helpful.contains(item.id))
        review.onHelpful = { [weak self, weak review] in
            guard let self = self else { return }
            if self.helpful.contains(item.id) { self.helpful.remove(item.id) } else { self.helpful.insert(item.id) }
            review?.setHelpful(self.helpful.contains(item.id))
        }
        return review
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        if indexPath.row >= reviews.count - 10 { loadReviews() }
    }

    // MARK: - Actions

    private func addToCart() {
        env.cart.add(header.quantity)
        Toast.show(FMText.Product.added, in: view, above: 68 + view.safeAreaInsets.bottom + 12)
    }
}

/// The table header: gallery, summary, pickers, quantity, description.
final class ProductHeaderView: UIView {
    let gallery = GalleryView()
    private let titleLabel = UILabel.fm("", size: 22, weight: .bold, lines: 2)
    private let brand = UILabel.fm("", size: 14, color: .secondaryLabel)
    private let price = UILabel.fm("", size: 20, weight: .bold)
    private let rating = UILabel.fm("", size: 14, color: .secondaryLabel)
    private let stock = UILabel.fm("", size: 14, color: Palette.up)
    private let sizeTitle = UILabel.fm(FMText.Product.size, size: 15, weight: .semibold)
    private let sizes = UIStackView()
    private let colourTitle = UILabel.fm(FMText.Product.colour, size: 15, weight: .semibold)
    private let colours = UIStackView()
    private let minus = UIButton.fm("−", id: "fm-product-qty-minus", size: 22)
    private let plus = UIButton.fm("+", id: "fm-product-qty-plus", size: 22)
    private let quantityLabel = UILabel.fm(FMText.Product.quantity(1), size: 17, weight: .semibold)
    private let descriptionLabel = UILabel.fm("", size: 15, lines: 4)
    private let readMore = UIButton.fm(FMText.Product.readMore, id: "fm-product-readmore")
    private let reviewsTitle = UILabel.fm(FMText.Product.reviews, size: 19, weight: .bold)
    private let reviewsCount = UILabel.fm("", size: 14, color: .secondaryLabel)
    private var sizeButtons: [UIButton] = []
    private var colourButtons: [UIButton] = []
    private var selectedSize = 0
    private var selectedColour = 0
    private(set) var quantity = 1
    private var expanded = false
    var onLayoutChange: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemBackground
        sizes.axis = .horizontal
        sizes.spacing = 8
        sizes.distribution = .fillEqually
        colours.axis = .horizontal
        colours.spacing = 10
        quantityLabel.textAlignment = .center
        for button in [minus, plus] {
            button.layer.cornerRadius = 18
            button.layer.borderWidth = 1
            button.layer.borderColor = Palette.line.cgColor
        }
        minus.fmOnTap { [weak self] in self?.changeQuantity(-1) }
        plus.fmOnTap { [weak self] in self?.changeQuantity(1) }
        readMore.contentHorizontalAlignment = .leading
        readMore.fmOnTap { [weak self] in self?.toggleReadMore() }

        let quantityRow = UIStackView(arrangedSubviews: [minus, quantityLabel, plus, UIView()])
        quantityRow.axis = .horizontal
        quantityRow.spacing = 12
        quantityRow.alignment = .center

        let reviewsRow = UIStackView(arrangedSubviews: [reviewsTitle, reviewsCount, UIView()])
        reviewsRow.axis = .horizontal
        reviewsRow.spacing = 8
        reviewsRow.alignment = .center
        let stack = UIStackView(arrangedSubviews: [
            gallery, titleLabel, brand, price, rating, stock, sizeTitle, sizes, colourTitle, colours, quantityRow,
            descriptionLabel, readMore, reviewsRow,
        ])
        stack.axis = .vertical
        stack.spacing = 8
        stack.setCustomSpacing(14, after: gallery)
        stack.setCustomSpacing(16, after: stock)
        stack.setCustomSpacing(16, after: sizes)
        stack.setCustomSpacing(16, after: colours)
        stack.setCustomSpacing(16, after: quantityRow)
        stack.setCustomSpacing(20, after: readMore)
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 16, bottom: 8, trailing: 16)
        addSubview(stack)
        stack.fmPin(to: self)
        NSLayoutConstraint.activate([
            gallery.heightAnchor.constraint(equalTo: gallery.widthAnchor, multiplier: 0.82),
            sizes.heightAnchor.constraint(equalToConstant: 36),
            colours.heightAnchor.constraint(equalToConstant: 34),
            minus.widthAnchor.constraint(equalToConstant: 36),
            minus.heightAnchor.constraint(equalToConstant: 36),
            plus.widthAnchor.constraint(equalToConstant: 36),
            plus.heightAnchor.constraint(equalToConstant: 36),
            quantityLabel.widthAnchor.constraint(equalToConstant: 64),
        ])
        quantityLabel.textAlignment = .center
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(_ detail: ProductDetail) {
        let product = detail.product
        gallery.configure(productId: product.id, count: max(1, min(8, product.imageCount)))
        titleLabel.text = product.title
        brand.text = product.brand
        price.text = FMFormat.price(product.priceCents)
        rating.text = "\(fmStars(product.rating)) \(FMFormat.rating(product.rating)) · \(product.reviewCount) reviews"
        stock.text = FMText.Product.stock(detail.stock)
        descriptionLabel.text = detail.description
        setReviewCount(product.reviewCount)

        let sizeNames = detail.sizes.isEmpty ? ["XS", "S", "M", "L", "XL", "XXL"] : Array(detail.sizes.prefix(6))
        sizes.arrangedSubviews.forEach { $0.removeFromSuperview() }
        sizeButtons = sizeNames.enumerated().map { index, name in
            let button = UIButton.fm(name, id: "fm-product-size-\(index)", size: 14)
            button.layer.cornerRadius = 8
            button.layer.borderWidth = 1
            button.fmOnTap { [weak self] in
                self?.selectedSize = index
                self?.restyle()
            }
            sizes.addArrangedSubview(button)
            return button
        }
        let colourCount = detail.colours.isEmpty ? 8 : min(8, detail.colours.count)
        colours.arrangedSubviews.forEach { $0.removeFromSuperview() }
        colourButtons = (0..<colourCount).map { index in
            let button = UIButton(type: .custom)
            button.backgroundColor = index < detail.colourHex.count
                ? (UIColor(fmHex: detail.colourHex[index]) ?? Palette.swatches[index % Palette.swatches.count])
                : Palette.swatches[index % Palette.swatches.count]
            button.layer.cornerRadius = 17
            button.accessibilityIdentifier = "fm-product-colour-\(index)"
            button.accessibilityLabel = index < detail.colours.count ? detail.colours[index] : "Colour \(index + 1)"
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 34).isActive = true
            button.fmOnTap { [weak self] in
                self?.selectedColour = index
                self?.restyle()
            }
            colours.addArrangedSubview(button)
            return button
        }
        colours.addArrangedSubview(UIView())
        restyle()
    }

    func setReviewCount(_ count: Int) {
        reviewsCount.text = "\(count)"
    }

    private func restyle() {
        for (index, button) in sizeButtons.enumerated() {
            let on = index == selectedSize
            button.backgroundColor = on ? Palette.accent : .systemBackground
            button.setTitleColor(on ? .white : .label, for: .normal)
            button.layer.borderColor = (on ? Palette.accent : Palette.line).cgColor
        }
        for (index, button) in colourButtons.enumerated() {
            button.layer.borderWidth = index == selectedColour ? 3 : 1
            button.layer.borderColor = (index == selectedColour ? Palette.accent : Palette.line).cgColor
        }
    }

    private func changeQuantity(_ delta: Int) {
        quantity = max(1, min(10, quantity + delta))
        quantityLabel.text = FMText.Product.quantity(quantity)
    }

    func toggleReadMore() {
        expanded.toggle()
        descriptionLabel.numberOfLines = expanded ? 0 : 4
        readMore.setTitle(expanded ? FMText.Product.readLess : FMText.Product.readMore, for: .normal)
        onLayoutChange?()
    }
}

/// The 8-picture pager with page dots and a "3 / 8" counter.
final class GalleryView: UIView, UIScrollViewDelegate {
    let scroll = UIScrollView()
    private var imageViews: [UIImageView] = []
    private let dots = UIPageControl()
    private let counter = UILabel.fm("1 / 8", size: 13, weight: .semibold, color: .white)
    private var count = 0
    private var page = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        scroll.isPagingEnabled = true
        scroll.showsHorizontalScrollIndicator = false
        scroll.accessibilityIdentifier = "fm-product-gallery"
        scroll.delegate = self
        scroll.layer.cornerRadius = 12
        scroll.backgroundColor = .tertiarySystemFill
        addSubview(scroll)
        scroll.fmPin(to: self)
        dots.isUserInteractionEnabled = false
        dots.currentPageIndicatorTintColor = Palette.accent
        dots.pageIndicatorTintColor = UIColor.white.withAlphaComponent(0.7)
        dots.translatesAutoresizingMaskIntoConstraints = false
        counter.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        counter.textAlignment = .center
        counter.layer.cornerRadius = 11
        counter.layer.masksToBounds = true
        addSubview(dots)
        addSubview(counter)
        NSLayoutConstraint.activate([
            dots.centerXAnchor.constraint(equalTo: centerXAnchor),
            dots.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            counter.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            counter.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            counter.widthAnchor.constraint(equalToConstant: 52),
            counter.heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(productId: Int, count: Int) {
        self.count = count
        imageViews.forEach { $0.removeFromSuperview() }
        let env = AppEnvironment.shared
        imageViews = (0..<count).map { index in
            let view = UIImageView()
            view.contentMode = .scaleAspectFill
            view.clipsToBounds = true
            view.fmSetImage(env.urls.productImage(productId, index: index, size: 800), loader: env.images)
            scroll.addSubview(view)
            return view
        }
        dots.numberOfPages = count
        update(page: 0)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = scroll.bounds.size
        for (index, view) in imageViews.enumerated() {
            view.frame = CGRect(x: CGFloat(index) * size.width, y: 0, width: size.width, height: size.height)
        }
        scroll.contentSize = CGSize(width: size.width * CGFloat(imageViews.count), height: size.height)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView.bounds.width > 0, count > 0 else { return }
        let current = max(0, min(count - 1, Int((scrollView.contentOffset.x / scrollView.bounds.width).rounded())))
        if current != page { update(page: current) }
    }

    private func update(page: Int) {
        self.page = page
        dots.currentPage = page
        counter.text = FMText.Product.galleryCounter(page + 1, of: max(count, 1))
    }
}

final class ReviewCell: UITableViewCell {
    static let reuse = "ReviewCell"
    private let avatar = UIImageView()
    private let name = UILabel.fm("", size: 15, weight: .semibold)
    private let date = UILabel.fm("", size: 12, color: .secondaryLabel)
    private let stars = UILabel.fm("", size: 13, color: .systemOrange)
    private let body = UILabel.fm("", size: 14, lines: 0)
    private let helpfulButton = UIButton.fm(FMText.Product.helpful, id: "", size: 13)
    var onHelpful: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        avatar.layer.cornerRadius = 20
        avatar.clipsToBounds = true
        avatar.backgroundColor = .tertiarySystemFill
        avatar.translatesAutoresizingMaskIntoConstraints = false
        helpfulButton.contentHorizontalAlignment = .leading
        helpfulButton.fmOnTap { [weak self] in self?.onHelpful?() }
        for view in [avatar, name, date, stars, body, helpfulButton] { contentView.addSubview(view) }
        NSLayoutConstraint.activate([
            avatar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            avatar.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            avatar.widthAnchor.constraint(equalToConstant: 40),
            avatar.heightAnchor.constraint(equalToConstant: 40),
            name.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 10),
            name.topAnchor.constraint(equalTo: avatar.topAnchor),
            date.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            date.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 2),
            stars.leadingAnchor.constraint(equalTo: date.trailingAnchor, constant: 8),
            stars.centerYAnchor.constraint(equalTo: date.centerYAnchor),
            body.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            body.topAnchor.constraint(equalTo: avatar.bottomAnchor, constant: 6),
            helpfulButton.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            helpfulButton.topAnchor.constraint(equalTo: body.bottomAnchor, constant: 4),
            helpfulButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            helpfulButton.heightAnchor.constraint(equalToConstant: 30),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(_ review: Review, helpful: Bool) {
        let env = AppEnvironment.shared
        avatar.fmSetImage(env.urls.avatar(review.avatarId), loader: env.images)
        name.text = review.author
        date.text = review.date
        stars.text = fmStars(Double(review.rating))
        body.text = review.text
        helpfulButton.accessibilityIdentifier = "fm-product-helpful-\(review.id)"
        setHelpful(helpful)
    }

    func setHelpful(_ on: Bool) {
        helpfulButton.setTitle(on ? "\(FMText.Product.helpful) ✓" : FMText.Product.helpful, for: .normal)
    }
}
