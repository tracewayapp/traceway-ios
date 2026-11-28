import SwiftUI
import UIKit
import FieldmartCore

/// Home (`02-APP-SPEC.md` §2.1): a pinned top bar over one
/// `UICollectionView` with a compositional layout and a diffable data
/// source: the hero carousel, the category chips, the deals carousel and
/// the 2,000-product grid, loaded 40 at a time as the user nears the end.
final class HomeViewController: UIViewController, UICollectionViewDelegate, UICollectionViewDataSourcePrefetching {
    enum Section: Int, CaseIterable {
        case hero, chips, deals, grid
    }

    enum Item: Hashable {
        case hero, chips, deals
        case product(Int)
    }

    private let env = AppEnvironment.shared
    private let topBar = HomeTopBar()
    private let hero = HeroView()
    private let chips = ChipsView()
    private let deals = DealsView()
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!

    private var products: [Int: Product] = [:]
    private var gridIds: [Int] = []
    private var nextPage = 0
    private var loading = false
    private var exhausted = false
    private var category: Int?
    private var generation = 0
    private var fullyPending: Set<String> = []
    private var fullyStarted = false

    static let pageSize = 40

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "Home"

        view.addSubview(topBar)
        topBar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 56),
        ])

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: HomeViewController.layout())
        collectionView.backgroundColor = .systemBackground
        collectionView.accessibilityIdentifier = "fm-home-grid"
        collectionView.delegate = self
        collectionView.prefetchDataSource = self
        collectionView.register(ContainerCell.self, forCellWithReuseIdentifier: "hero")
        collectionView.register(ContainerCell.self, forCellWithReuseIdentifier: "chips")
        collectionView.register(ContainerCell.self, forCellWithReuseIdentifier: "deals")
        collectionView.register(ProductCell.self, forCellWithReuseIdentifier: ProductCell.reuse)
        collectionView.register(GridHeaderView.self, forSupplementaryViewOfKind: GridHeaderView.kind,
                                withReuseIdentifier: GridHeaderView.kind)
        view.insertSubview(collectionView, belowSubview: topBar)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        dataSource = UICollectionViewDiffableDataSource<Section, Item>(collectionView: collectionView) {
            [weak self] collectionView, indexPath, item in
            self?.cell(collectionView, indexPath, item)
        }
        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: GridHeaderView.kind,
                                                            for: indexPath)
        }
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections(Section.allCases)
        snapshot.appendItems([.hero], toSection: .hero)
        snapshot.appendItems([.chips], toSection: .chips)
        snapshot.appendItems([.deals], toSection: .deals)
        dataSource.apply(snapshot, animatingDifferences: false)

        topBar.logo.fmOnTap { [weak self] in self?.scrollToTop() }
        topBar.search.fmOnTap { [weak self] in self?.openSearch() }
        topBar.cart.fmOnTap { [weak self] in
            (self?.tabBarController as? RootTabBarController)?.select(.checkout)
        }
        chips.onSelect = { [weak self] id in self?.select(category: id) }
        deals.onSelect = { [weak self] id in self?.openProduct(id) }

        Autopilot.shared.scroll("fm-home-grid", collectionView)
        Autopilot.shared.scroll("fm-home-deals", deals.collection)
        Autopilot.shared.scroll("fm-home-hero", hero.collection)
        Autopilot.shared.tap("fm-home-logo") { [weak self] in self?.scrollToTop() }
        Autopilot.shared.tap(prefix: "fm-home-product-") { [weak self] suffix in
            if let id = Int(suffix) { self?.openProduct(id) }
        }
        Autopilot.shared.tap(prefix: "fm-home-chip-") { [weak self] suffix in
            if let index = Int(suffix) { self?.chips.select(index: index) }
        }

        startFullyDrawnWatch()
        loadHero()
        loadCategories()
        loadDeals()
        loadNextPage()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: animated)
        topBar.setCart(env.cart.count)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        fmScreenAppeared("home")
        hero.startAutoAdvance()
        NotificationCenter.default.addObserver(self, selector: #selector(cartChanged), name: Cart.changed, object: nil)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        hero.stopAutoAdvance()
        navigationController?.setNavigationBarHidden(false, animated: animated)
        NotificationCenter.default.removeObserver(self, name: Cart.changed, object: nil)
    }

    @objc private func cartChanged() {
        topBar.setCart(env.cart.count)
    }

    // MARK: - Layout

    private static func layout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { index, _ in
            func full(height: CGFloat) -> NSCollectionLayoutSection {
                let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(height))
                let item = NSCollectionLayoutItem(layoutSize: size)
                let group = NSCollectionLayoutGroup.horizontal(layoutSize: size, subitems: [item])
                return NSCollectionLayoutSection(group: group)
            }
            switch Section(rawValue: index) ?? .grid {
            case .hero:
                return full(height: 190)
            case .chips:
                return full(height: 48)
            case .deals:
                return full(height: 240)
            case .grid:
                let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(0.5), heightDimension: .fractionalHeight(1)))
                item.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6)
                let group = NSCollectionLayoutGroup.horizontal(
                    layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(266)),
                    subitems: [item])
                let section = NSCollectionLayoutSection(group: group)
                // "Popular now" over the grid.
                let header = NSCollectionLayoutBoundarySupplementaryItem(
                    layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(30)),
                    elementKind: GridHeaderView.kind, alignment: .top)
                section.boundarySupplementaryItems = [header]
                section.interGroupSpacing = 12
                section.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 6, bottom: 24, trailing: 6)
                return section
            }
        }
    }

    private func cell(_ collectionView: UICollectionView, _ indexPath: IndexPath, _ item: Item) -> UICollectionViewCell? {
        switch item {
        case .hero:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "hero", for: indexPath) as? ContainerCell
            cell?.host(hero)
            return cell
        case .chips:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "chips", for: indexPath) as? ContainerCell
            cell?.host(chips)
            return cell
        case .deals:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "deals", for: indexPath) as? ContainerCell
            cell?.host(deals)
            return cell
        case .product(let id):
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: ProductCell.reuse, for: indexPath) as? ProductCell
            if let product = products[id] { cell?.configure(product, urls: env.urls, images: env.images) }
            return cell
        }
    }

    // MARK: - Data

    private func loadHero() {
        env.client.json(env.urls.heroSlides) { [weak self] json in
            guard let self = self, let json = json else { return }
            let slides = Fixtures.hero(json)
            if !slides.isEmpty { self.hero.set(slides) }
        }
    }

    private func loadCategories() {
        env.client.json(env.urls.categories) { [weak self] json in
            guard let self = self, let json = json else { return }
            self.chips.set(Fixtures.categories(json))
        }
    }

    private func loadDeals() {
        env.client.json(env.urls.deals) { [weak self] json in
            guard let self = self, let json = json else { return }
            let entries = Array(Fixtures.deals(json).prefix(20))
            // Deal entries that carry the product itself are used as they
            // are; otherwise each product is fetched.
            let embedded = json.items("deals").prefix(20).compactMap { Product(json: $0["product"] ?? .null) }
            if !entries.isEmpty, embedded.count == entries.count {
                self.deals.set(zip(entries, embedded).map { pair -> (Deal, Product?) in (pair.0, pair.1) })
                return
            }
            self.deals.set(entries.map { deal -> (Deal, Product?) in (deal, nil) })
            for deal in entries {
                self.env.client.json(self.env.urls.product(deal.productId)) { [weak self] json in
                    guard let json = json, let detail = ProductDetail(json: json) else { return }
                    self?.deals.update(detail.product)
                }
            }
        }
    }

    private func loadNextPage() {
        guard !loading, !exhausted else { return }
        loading = true
        let page = nextPage
        let generation = self.generation
        env.client.json(env.urls.products(page: page, size: HomeViewController.pageSize, category: category)) {
            [weak self] json in
            guard let self = self, generation == self.generation else { return }
            self.loading = false
            guard let json = json else { return }
            let items = Fixtures.products(json)
            self.nextPage = page + 1
            if items.count < HomeViewController.pageSize { self.exhausted = true }
            for product in items { self.products[product.id] = product }
            let shown = Set(self.gridIds)
            var seen = Set<Int>()
            let fresh = items.map(\.id).filter { !shown.contains($0) && seen.insert($0).inserted }
            self.gridIds.append(contentsOf: fresh)
            var snapshot = self.dataSource.snapshot()
            snapshot.appendItems(fresh.map(Item.product), toSection: .grid)
            self.dataSource.apply(snapshot, animatingDifferences: false)
            if page == 0 { self.firstGridPage(items) }
        }
    }

    private func select(category id: Int) {
        guard id != category else { return }
        category = id
        generation += 1
        loading = false
        exhausted = false
        nextPage = 0
        var snapshot = dataSource.snapshot()
        snapshot.deleteItems(gridIds.map(Item.product))
        gridIds = []
        dataSource.apply(snapshot, animatingDifferences: false)
        loadNextPage()
    }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        if indexPath.section == Section.grid.rawValue, indexPath.item >= gridIds.count - 8 { loadNextPage() }
    }

    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        for indexPath in indexPaths where indexPath.section == Section.grid.rawValue && indexPath.item < gridIds.count {
            env.images.load(env.urls.productImage(gridIds[indexPath.item])) { _ in }
            if indexPath.item >= gridIds.count - 8 { loadNextPage() }
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard case .product(let id)? = dataSource.itemIdentifier(for: indexPath) else { return }
        openProduct(id)
    }

    // MARK: - Actions

    private func scrollToTop() {
        collectionView.setContentOffset(CGPoint(x: 0, y: -collectionView.adjustedContentInset.top), animated: true)
    }

    func openProduct(_ id: Int) {
        navigationController?.pushViewController(ProductViewController(productId: id), animated: true)
    }

    private func openSearch() {
        let search = SearchView(openProduct: { [weak self] id in self?.openProduct(id) })
        let host = UIHostingController(rootView: search)
        host.title = FMText.Search.title
        host.fmInstallBackButton()
        navigationController?.pushViewController(host, animated: true)
    }

    // MARK: - Fully drawn

    /// `FM_FULLY`: the first hero slide and the first eight grid pictures
    /// are decoded.
    private func startFullyDrawnWatch() {
        fullyPending = ["hero"]
        hero.onFirstImage = { [weak self] in self?.fullyPart("hero") }
    }

    private func firstGridPage(_ items: [Product]) {
        guard !fullyStarted else { return }
        fullyStarted = true
        for product in items.prefix(8) {
            let key = "p\(product.id)"
            fullyPending.insert(key)
            env.images.load(env.urls.productImage(product.id)) { [weak self] _ in self?.fullyPart(key) }
        }
    }

    private func fullyPart(_ key: String) {
        fullyPending.remove(key)
        if fullyPending.isEmpty, fullyStarted { env.fullyDrawn() }
    }
}

/// A cell that shows one long-lived view (the carousels and the chips keep
/// their scroll position and timers across cell reuse).
final class ContainerCell: UICollectionViewCell {
    func host(_ view: UIView) {
        guard view.superview !== contentView else { return }
        for subview in contentView.subviews where subview !== view { subview.removeFromSuperview() }
        view.removeFromSuperview()
        contentView.addSubview(view)
        view.fmPin(to: contentView)
    }
}

/// The pinned bar: logo (scrolls Home to the top), search field, cart.
final class HomeTopBar: UIView {
    let logo = UIButton.fm(FMText.appName, id: "fm-home-logo", size: 22, weight: .heavy)
    let search = UIButton(type: .system)
    let cart = UIButton(type: .system)
    private let badge = UILabel.fm("0", size: 11, weight: .bold, color: .white)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemBackground
        logo.setTitleColor(Palette.accent, for: .normal)

        search.setTitle(FMText.Home.search, for: .normal)
        search.titleEdgeInsets = UIEdgeInsets(top: 0, left: 6, bottom: 0, right: -6)
        search.setImage(UIImage(systemName: "magnifyingglass"), for: .normal)
        search.contentHorizontalAlignment = .leading
        search.tintColor = .secondaryLabel
        search.setTitleColor(.secondaryLabel, for: .normal)
        search.backgroundColor = .tertiarySystemFill
        search.layer.cornerRadius = 10
        search.contentEdgeInsets = UIEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        search.accessibilityIdentifier = "fm-home-search"
        search.translatesAutoresizingMaskIntoConstraints = false

        cart.setImage(UIImage(systemName: "cart"), for: .normal)
        cart.accessibilityIdentifier = "fm-home-cart"
        cart.accessibilityLabel = "Cart"
        cart.translatesAutoresizingMaskIntoConstraints = false

        badge.backgroundColor = Palette.sale
        badge.textAlignment = .center
        badge.layer.cornerRadius = 9
        badge.layer.masksToBounds = true
        badge.isHidden = true

        let separator = UIView()
        separator.backgroundColor = Palette.line
        separator.translatesAutoresizingMaskIntoConstraints = false

        for subview in [logo, search, cart, badge, separator] { addSubview(subview) }
        NSLayoutConstraint.activate([
            logo.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            logo.centerYAnchor.constraint(equalTo: centerYAnchor),
            search.leadingAnchor.constraint(equalTo: logo.trailingAnchor, constant: 12),
            search.centerYAnchor.constraint(equalTo: centerYAnchor),
            search.heightAnchor.constraint(equalToConstant: 38),
            cart.leadingAnchor.constraint(equalTo: search.trailingAnchor, constant: 8),
            cart.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            cart.centerYAnchor.constraint(equalTo: centerYAnchor),
            cart.widthAnchor.constraint(equalToConstant: 40),
            cart.heightAnchor.constraint(equalToConstant: 40),
            badge.centerXAnchor.constraint(equalTo: cart.trailingAnchor, constant: -6),
            badge.centerYAnchor.constraint(equalTo: cart.topAnchor, constant: 8),
            badge.heightAnchor.constraint(equalToConstant: 18),
            badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 18),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 0.5),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func setCart(_ count: Int) {
        badge.text = "\(count)"
        badge.isHidden = count == 0
    }
}
