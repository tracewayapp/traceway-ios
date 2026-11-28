import UIKit
import FieldmartCore

/// The hero carousel: 8 slides of 1600 × 900 pictures with a two-line
/// headline, paging, page dots, advancing every 4 s while Home is visible.
final class HeroView: UIView, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    static let slideCount = 8

    /// From `/fx/api/hero`; until it answers, the slides show only their pictures.
    private var slides: [HeroSlide] = []

    let collection: UICollectionView
    private let pageControl = UIPageControl()
    private var timer: Timer?
    private var page = 0
    var onFirstImage: (() -> Void)?

    override init(frame: CGRect) {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0
        collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: frame)
        collection.isPagingEnabled = true
        collection.showsHorizontalScrollIndicator = false
        collection.accessibilityIdentifier = "fm-home-hero"
        collection.dataSource = self
        collection.delegate = self
        collection.register(HeroSlideCell.self, forCellWithReuseIdentifier: HeroSlideCell.reuse)
        pageControl.numberOfPages = HeroView.slideCount
        pageControl.isUserInteractionEnabled = false
        pageControl.currentPageIndicatorTintColor = .white
        pageControl.pageIndicatorTintColor = UIColor.white.withAlphaComponent(0.45)
        addSubview(collection)
        addSubview(pageControl)
        collection.fmPin(to: self)
        pageControl.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            pageControl.centerXAnchor.constraint(equalTo: centerXAnchor),
            pageControl.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func startAutoAdvance() {
        stopAutoAdvance()
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in self?.advance() }
    }

    func stopAutoAdvance() {
        timer?.invalidate()
        timer = nil
    }

    private func advance() {
        guard collection.bounds.width > 0, !collection.isTracking, !collection.isDecelerating else { return }
        let next = (currentPage + 1) % HeroView.slideCount
        collection.scrollToItem(at: IndexPath(item: next, section: 0), at: .centeredHorizontally, animated: true)
    }

    private var currentPage: Int {
        guard collection.bounds.width > 0 else { return 0 }
        return max(0, min(HeroView.slideCount - 1,
                          Int((collection.contentOffset.x / collection.bounds.width).rounded())))
    }

    func set(_ slides: [HeroSlide]) {
        self.slides = Array(slides.prefix(HeroView.slideCount))
        collection.reloadData()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let current = currentPage
        if current != page {
            page = current
            pageControl.currentPage = current
        }
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        HeroView.slideCount
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: HeroSlideCell.reuse, for: indexPath)
        guard let slide = cell as? HeroSlideCell else { return cell }
        let env = AppEnvironment.shared
        let url: URL
        if indexPath.item < slides.count {
            url = env.urls.relative(slides[indexPath.item].image)
            slide.headline.text = slides[indexPath.item].title
            slide.subtitle.text = slides[indexPath.item].subtitle
        } else {
            url = env.urls.hero(indexPath.item + 1)
            slide.headline.text = nil
            slide.subtitle.text = nil
        }
        slide.image.fmImageURL = url
        if let image = env.images.cached(url) {
            slide.image.image = image
        } else {
            slide.image.image = nil
            env.images.load(url) { [weak self, weak slide] image in
                if indexPath.item == 0, image != nil {
                    self?.onFirstImage?()
                    self?.onFirstImage = nil
                }
                guard let slide = slide, slide.image.fmImageURL == url else { return }
                slide.image.image = image
            }
        }
        return slide
    }

    func collectionView(_ collectionView: UICollectionView, layout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        collectionView.bounds.size
    }
}

final class HeroSlideCell: UICollectionViewCell {
    static let reuse = "HeroSlideCell"
    let image = UIImageView()
    let headline = UILabel.fm("", size: 22, weight: .heavy, color: .white, lines: 2)
    let subtitle = UILabel.fm("", size: 14, weight: .medium, color: .white, lines: 1)

    override init(frame: CGRect) {
        super.init(frame: frame)
        image.contentMode = .scaleAspectFill
        image.clipsToBounds = true
        image.backgroundColor = Palette.accentSoft
        contentView.addSubview(image)
        image.fmPin(to: contentView)
        for label in [headline, subtitle] {
            label.layer.shadowColor = UIColor.black.cgColor
            label.layer.shadowOpacity = 0.6
            label.layer.shadowRadius = 4
            label.layer.shadowOffset = .zero
            contentView.addSubview(label)
        }
        NSLayoutConstraint.activate([
            headline.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            headline.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -20),
            subtitle.leadingAnchor.constraint(equalTo: headline.leadingAnchor),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -20),
            subtitle.topAnchor.constraint(equalTo: headline.bottomAnchor, constant: 2),
            subtitle.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -30),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}

/// The 12 category chips in a horizontally scrolling row.
final class ChipsView: UIView {
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private var buttons: [UIButton] = []
    private var categories: [ProductCategory] = []
    private var selected: Int?
    var onSelect: ((Int) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        scroll.showsHorizontalScrollIndicator = false
        scroll.accessibilityIdentifier = "fm-home-chips"
        stack.axis = .horizontal
        stack.spacing = 8
        addSubview(scroll)
        scroll.fmPin(to: self)
        scroll.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -8),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor, constant: -16),
        ])
        Autopilot.shared.scroll("fm-home-chips", scroll)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func set(_ categories: [ProductCategory]) {
        self.categories = Array(categories.prefix(12))
        for button in buttons { button.removeFromSuperview() }
        buttons = self.categories.enumerated().map { index, category in
            let button = UIButton(type: .system)
            button.setTitle(category.name, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
            button.contentEdgeInsets = UIEdgeInsets(top: 6, left: 14, bottom: 6, right: 14)
            button.layer.cornerRadius = 17
            button.layer.borderWidth = 1
            button.accessibilityIdentifier = "fm-home-chip-\(index)"
            button.fmOnTap { [weak self] in self?.select(index: index) }
            stack.addArrangedSubview(button)
            return button
        }
        restyle()
    }

    func select(index: Int) {
        guard index >= 0, index < categories.count else { return }
        selected = index
        restyle()
        onSelect?(categories[index].id)
    }

    private func restyle() {
        for (index, button) in buttons.enumerated() {
            let on = index == selected
            button.backgroundColor = on ? Palette.accent : .systemBackground
            button.setTitleColor(on ? .white : .label, for: .normal)
            button.layer.borderColor = (on ? Palette.accent : Palette.line).cgColor
        }
    }
}

/// The 20 deal cards in a horizontal collection.
final class DealsView: UIView, UICollectionViewDataSource, UICollectionViewDelegate {
    let collection: UICollectionView
    private let heading = UILabel.fm(FMText.Home.deals, size: 19, weight: .bold)
    private var deals: [(deal: Deal, product: Product?)] = []
    var onSelect: ((Int) -> Void)?

    override init(frame: CGRect) {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = CGSize(width: 150, height: 184)
        layout.minimumLineSpacing = 12
        layout.sectionInset = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: frame)
        collection.showsHorizontalScrollIndicator = false
        collection.backgroundColor = .systemBackground
        collection.accessibilityIdentifier = "fm-home-deals"
        collection.dataSource = self
        collection.delegate = self
        collection.register(DealCell.self, forCellWithReuseIdentifier: DealCell.reuse)
        addSubview(heading)
        addSubview(collection)
        collection.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            heading.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            collection.leadingAnchor.constraint(equalTo: leadingAnchor),
            collection.trailingAnchor.constraint(equalTo: trailingAnchor),
            collection.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 8),
            collection.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func set(_ deals: [(Deal, Product?)]) {
        self.deals = deals.map { (deal: $0.0, product: $0.1) }
        collection.reloadData()
    }

    func update(_ product: Product) {
        for index in deals.indices where deals[index].deal.productId == product.id {
            deals[index].product = product
            let path = IndexPath(item: index, section: 0)
            if collection.indexPathsForVisibleItems.contains(path),
               let cell = collection.cellForItem(at: path) as? DealCell {
                cell.configure(deals[index].deal, deals[index].product, index: index)
            }
        }
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        deals.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: DealCell.reuse, for: indexPath)
        let entry = deals[indexPath.item]
        (cell as? DealCell)?.configure(entry.deal, entry.product, index: indexPath.item)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        onSelect?(deals[indexPath.item].deal.productId)
    }
}

final class DealCell: UICollectionViewCell {
    static let reuse = "DealCell"
    private let image = UIImageView()
    private let badge = UIImageView()
    private let title = UILabel.fm("", size: 14, weight: .medium, lines: 1)
    private let price = UILabel.fm("", size: 15, weight: .bold)
    private let was = UILabel.fm("", size: 12, color: .secondaryLabel)

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = Palette.card
        contentView.layer.cornerRadius = 12
        contentView.clipsToBounds = true
        image.contentMode = .scaleAspectFill
        image.clipsToBounds = true
        image.backgroundColor = .tertiarySystemFill
        image.translatesAutoresizingMaskIntoConstraints = false
        badge.contentMode = .scaleAspectFit
        badge.translatesAutoresizingMaskIntoConstraints = false
        for view in [image, badge, title, price, was] { contentView.addSubview(view) }
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            image.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            image.topAnchor.constraint(equalTo: contentView.topAnchor),
            image.heightAnchor.constraint(equalToConstant: 120),
            badge.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            badge.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -6),
            badge.widthAnchor.constraint(equalToConstant: 44),
            badge.heightAnchor.constraint(equalToConstant: 44),
            title.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            title.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            title.topAnchor.constraint(equalTo: image.bottomAnchor, constant: 6),
            price.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            price.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            was.leadingAnchor.constraint(equalTo: price.trailingAnchor, constant: 6),
            was.firstBaselineAnchor.constraint(equalTo: price.firstBaselineAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(_ deal: Deal, _ product: Product?, index: Int) {
        let env = AppEnvironment.shared
        accessibilityIdentifier = "fm-home-deal-\(index)"
        image.fmSetImage(env.urls.productImage(deal.productId), loader: env.images)
        // The badge picture carries the percentage (`pct-25`).
        badge.fmSetImage(env.urls.badge(deal.badge), loader: env.images)
        title.text = product?.title ?? " "
        if let product = product {
            let original = product.compareAtCents
                ?? Int((Double(product.priceCents) * 100 / Double(max(1, 100 - deal.discountPercent))).rounded())
            price.text = FMFormat.price(product.priceCents)
            was.attributedText = NSAttributedString(string: FMFormat.price(original), attributes: [
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .foregroundColor: UIColor.secondaryLabel,
            ])
        } else {
            price.text = " "
            was.attributedText = nil
        }
    }
}

/// A grid cell: picture, two-line title, price, rating and review count, and
/// a "New" or "Sale" badge.
final class ProductCell: UICollectionViewCell {
    static let reuse = "ProductCell"
    private let image = UIImageView()
    private let badge = UILabel.fm("", size: 11, weight: .heavy, color: .white)
    private let title = UILabel.fm("", size: 14, weight: .medium, lines: 2)
    private let price = UILabel.fm("", size: 16, weight: .bold)
    private let rating = UILabel.fm("", size: 12, color: .secondaryLabel)

    override init(frame: CGRect) {
        super.init(frame: frame)
        image.contentMode = .scaleAspectFill
        image.clipsToBounds = true
        image.layer.cornerRadius = 10
        image.backgroundColor = .tertiarySystemFill
        image.translatesAutoresizingMaskIntoConstraints = false
        badge.textAlignment = .center
        badge.layer.cornerRadius = 6
        badge.layer.masksToBounds = true
        for view in [image, badge, title, price, rating] { contentView.addSubview(view) }
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            image.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            image.topAnchor.constraint(equalTo: contentView.topAnchor),
            image.heightAnchor.constraint(equalTo: contentView.widthAnchor, multiplier: 0.8),
            badge.leadingAnchor.constraint(equalTo: image.leadingAnchor, constant: 8),
            badge.topAnchor.constraint(equalTo: image.topAnchor, constant: 8),
            badge.heightAnchor.constraint(equalToConstant: 20),
            badge.widthAnchor.constraint(equalToConstant: 44),
            title.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 2),
            title.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -2),
            title.topAnchor.constraint(equalTo: image.bottomAnchor, constant: 6),
            price.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            price.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            rating.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            rating.topAnchor.constraint(equalTo: price.bottomAnchor, constant: 2),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(_ product: Product, urls: FixtureURLs, images: ImageLoader) {
        accessibilityIdentifier = "fm-home-product-\(product.id)"
        image.fmSetImage(urls.productImage(product.id), loader: images)
        title.text = product.title
        price.text = FMFormat.price(product.priceCents)
        rating.text = "★ \(FMFormat.rating(product.rating)) \(FMText.Home.reviews(product.reviewCount))"
        if let text = product.badgeText {
            badge.isHidden = false
            badge.text = text
            badge.backgroundColor = text.lowercased() == "sale" ? Palette.sale : Palette.accent
        } else {
            badge.isHidden = true
        }
    }
}

/// "Popular now" over the product grid.
final class GridHeaderView: UICollectionReusableView {
    static let kind = "grid-header"
    private let label = UILabel.fm(FMText.Home.grid, size: 19, weight: .bold)

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}
