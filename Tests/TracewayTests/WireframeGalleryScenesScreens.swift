#if canImport(UIKit)
import UIKit
@testable import Traceway

// The gallery's screen scenarios: lists, grids, a carousel, navigation,
// tabs, dialogs, sheets and popover menus.
extension GalleryScenes {
    // MARK: - 15 lists: a grouped table with sections, scrolled

    final class TableController: UITableViewController {
        override func viewDidLoad() {
            super.viewDidLoad()
            tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        }

        override func numberOfSections(in tableView: UITableView) -> Int { 3 }

        override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 20 }

        override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
            "Section \(section + 1)"
        }

        override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
            let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
            var content = cell.defaultContentConfiguration()
            content.text = String(format: "Row %d.%02d", indexPath.section + 1, indexPath.row + 1)
            content.secondaryText = indexPath.row % 3 == 0 ? String(format: "Detail %d.%02d", indexPath.section + 1, indexPath.row + 1) : nil
            content.image = indexPath.row % 4 == 0 ? UIImage(systemName: "folder") : nil
            cell.contentConfiguration = content
            cell.accessoryType = indexPath.row % 2 == 0 ? .disclosureIndicator : .checkmark
            return cell
        }
    }

    static let lists = GalleryScenario(id: "lists", title: "Lists", build: {
        TableController(style: .insetGrouped)
    }, script: { d, controller in
        let table = (controller as! UITableViewController).tableView!
        d.checkpoint(shows: ["Section 1", "Row 1.01", "Row 1.02", "Detail 1.01"])
        d.scroll(table, to: CGPoint(x: 0, y: table.contentOffset.y + 900))
        d.checkpoint("middle", shows: ["Row 1.18", "Section 2"], hides: ["Row 1.01"])
        // Cells size themselves: the content's height is only known once
        // the last rows were laid out.
        let last = IndexPath(row: 19, section: 2)
        table.scrollToRow(at: last, at: .bottom, animated: false)
        table.layoutIfNeeded()
        let bottom = table.contentOffset
        table.contentOffset = CGPoint(x: 0, y: bottom.y - 900)
        d.scroll(table, to: bottom, seconds: 0.8)
        // The rows on the way sized themselves: the end moved.
        table.layoutIfNeeded()
        table.scrollToRow(at: last, at: .bottom, animated: true)
        d.checkpoint("bottom", shows: ["Row 3.18", "Row 3.20"], hides: ["Row 1.01"], settle: 0.8)
        d.scroll(table, to: CGPoint(x: 0, y: -table.adjustedContentInset.top), seconds: 0.8)
        d.checkpoint("top", shows: ["Row 1.01"], hides: ["Row 3.18"])
    })

    // MARK: - 16 grids: a three-column collection view, scrolled

    final class GridController: UICollectionViewController {
        init() {
            let layout = UICollectionViewCompositionalLayout { _, _ in
                let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(1 / 3), heightDimension: .fractionalHeight(1)))
                item.contentInsets = .init(top: 4, leading: 4, bottom: 4, trailing: 4)
                let group = NSCollectionLayoutGroup.horizontal(
                    layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(110)), subitems: [item])
                let section = NSCollectionLayoutSection(group: group)
                section.contentInsets = .init(top: 12, leading: 12, bottom: 12, trailing: 12)
                return section
            }
            super.init(collectionViewLayout: layout)
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override func viewDidLoad() {
            super.viewDidLoad()
            collectionView.backgroundColor = .systemBackground
            collectionView.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "cell")
        }

        override func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { 60 }

        override func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            GalleryScenes.tileCell(collectionView, indexPath, format: "Tile %02d")
        }
    }

    /// A cell in one of six colors with its centered title.
    static func tileCell(_ collectionView: UICollectionView, _ indexPath: IndexPath, format: String) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "cell", for: indexPath)
        let hues: [UIColor] = [.systemRed, .systemOrange, .systemGreen, .systemBlue, .systemPurple, .systemPink]
        cell.contentView.backgroundColor = hues[indexPath.item % hues.count]
        cell.contentView.layer.cornerRadius = 10
        let tag = 99
        let label = (cell.contentView.viewWithTag(tag) as? UILabel) ?? {
            let label = UILabel()
            label.tag = tag
            label.textColor = .white
            label.font = .systemFont(ofSize: 15, weight: .semibold)
            label.textAlignment = .center
            label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            label.frame = cell.contentView.bounds
            cell.contentView.addSubview(label)
            return label
        }()
        label.text = String(format: format, indexPath.item + 1)
        return cell
    }

    static let grids = GalleryScenario(id: "grids", title: "Grids", build: {
        GridController()
    }, script: { d, controller in
        let grid = (controller as! UICollectionViewController).collectionView!
        d.checkpoint(shows: ["Tile 01", "Tile 02", "Tile 03", "Tile 06"])
        d.scroll(grid, to: CGPoint(x: 0, y: grid.contentOffset.y + 560))
        d.checkpoint("scrolled", shows: ["Tile 18", "Tile 30"], hides: ["Tile 01"])
        d.scroll(grid, to: CGPoint(x: 0, y: grid.contentOffset.y + 560))
        d.checkpoint("further", shows: ["Tile 36"], hides: ["Tile 12"])
    })

    // MARK: - 17 carousel: a horizontal strip in a vertical list

    final class CarouselController: UICollectionViewController {
        init() {
            let layout = UICollectionViewCompositionalLayout { section, _ in
                if section == 0 {
                    let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .absolute(120), heightDimension: .absolute(80)))
                    let group = NSCollectionLayoutGroup.horizontal(
                        layoutSize: .init(widthDimension: .absolute(120), heightDimension: .absolute(80)), subitems: [item])
                    let section = NSCollectionLayoutSection(group: group)
                    section.orthogonalScrollingBehavior = .continuous
                    section.interGroupSpacing = 10
                    section.contentInsets = .init(top: 10, leading: 16, bottom: 10, trailing: 16)
                    return section
                }
                let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .fractionalHeight(1)))
                let group = NSCollectionLayoutGroup.horizontal(
                    layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(56)), subitems: [item])
                let section = NSCollectionLayoutSection(group: group)
                section.interGroupSpacing = 8
                section.contentInsets = .init(top: 8, leading: 16, bottom: 16, trailing: 16)
                return section
            }
            super.init(collectionViewLayout: layout)
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override func viewDidLoad() {
            super.viewDidLoad()
            collectionView.backgroundColor = .systemBackground
            collectionView.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "cell")
        }

        override func numberOfSections(in collectionView: UICollectionView) -> Int { 2 }

        override func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            section == 0 ? 12 : 24
        }

        override func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            GalleryScenes.tileCell(collectionView, indexPath, format: indexPath.section == 0 ? "Card %02d" : "Row item %02d")
        }
    }

    static let carousel = GalleryScenario(id: "carousel", title: "Carousel", build: {
        CarouselController()
    }, script: { d, controller in
        let list = (controller as! UICollectionViewController).collectionView!
        d.checkpoint(shows: ["Card 01", "Card 02", "Row item 01", "Row item 06"])
        guard let strip = list.subviews.compactMap({ $0 as? UIScrollView }).first(where: { $0.bounds.height < 120 }) else {
            return d.fail("no horizontal section")
        }
        d.scroll(strip, to: CGPoint(x: 400, y: 0))
        d.checkpoint("strip", shows: ["Card 05", "Row item 01"], hides: ["Card 01"])
        d.scroll(list, to: CGPoint(x: 0, y: list.contentOffset.y + 400))
        d.checkpoint("scrolled", shows: ["Row item 12"], hides: ["Row item 01"])
        d.scroll(list, to: CGPoint(x: 0, y: -list.adjustedContentInset.top))
        d.scroll(strip, to: CGPoint(x: 0, y: 0))
        d.checkpoint("back", shows: ["Card 01", "Row item 01"], hides: ["Card 06"])
    })

    // MARK: - 18 navigation: push and pop under a large title

    final class ListController: UIViewController {
        override func viewDidLoad() {
            super.viewDidLoad()
            title = "Inbox"
            view.backgroundColor = .systemBackground
            navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .add, target: nil, action: nil)
            navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Edit", style: .plain, target: nil, action: nil)
            let text = GalleryScenes.label("Three new messages", size: 17)
            text.frame = CGRect(x: 20, y: 200, width: 300, height: 24)
            view.addSubview(text)
        }
    }

    static let navigation = GalleryScenario(id: "navigation", title: "Navigation", build: {
        let nav = UINavigationController(rootViewController: ListController())
        nav.navigationBar.prefersLargeTitles = true
        return nav
    }, script: { d, controller in
        let nav = controller as! UINavigationController
        d.checkpoint(shows: ["Inbox", "Edit", "Three new messages"])
        let detail = UIViewController()
        detail.title = "Message"
        detail.view.backgroundColor = .systemBackground
        detail.navigationItem.largeTitleDisplayMode = .never
        let body = GalleryScenes.label("Hello from the detail page", size: 17)
        body.frame = CGRect(x: 20, y: 160, width: 320, height: 24)
        detail.view.addSubview(body)
        d.tap(at: CGPoint(x: 200, y: 212)) { nav.pushViewController(detail, animated: true) }
        d.checkpoint("pushed", shows: ["Message", "Hello from the detail page"], hides: ["Three new messages"], settle: 0.8)
        d.tap(at: CGPoint(x: 30, y: 70)) { nav.popViewController(animated: true) }
        d.checkpoint("popped", shows: ["Three new messages"], hides: ["Hello from the detail page"], settle: 0.8)
    })

    // MARK: - 19 tabs

    static let tabs = GalleryScenario(id: "tabs", title: "Tabs", build: {
        func tab(_ title: String, _ symbol: String, _ text: String) -> UIViewController {
            let controller = UIViewController()
            controller.view.backgroundColor = .systemBackground
            controller.tabBarItem = UITabBarItem(title: title, image: UIImage(systemName: symbol), tag: 0)
            let body = GalleryScenes.label(text, size: 22, weight: .semibold)
            body.frame = CGRect(x: 20, y: 140, width: 320, height: 30)
            controller.view.addSubview(body)
            return controller
        }
        let tabs = UITabBarController()
        tabs.viewControllers = [tab("Home", "house.fill", "Home page"), tab("Search", "magnifyingglass", "Search page"),
                                tab("Profile", "person.fill", "Profile page")]
        return tabs
    }, script: { d, controller in
        let tabs = controller as! UITabBarController
        d.checkpoint(shows: ["Home", "Search", "Profile", "Home page"])
        let bar = tabs.tabBar.convert(tabs.tabBar.bounds, to: d.window)
        d.tap(at: CGPoint(x: bar.midX, y: bar.midY)) { tabs.selectedIndex = 1 }
        d.checkpoint("search", shows: ["Search page"], hides: ["Home page"], settle: 0.6)
        d.tap(at: CGPoint(x: bar.maxX - 60, y: bar.midY)) { tabs.selectedIndex = 2 }
        d.checkpoint("profile", shows: ["Profile page"], hides: ["Search page"], settle: 0.6)
    })

    // MARK: - 20 dialogs: an alert and an action sheet over the page

    static let dialogs = GalleryScenario(id: "dialogs", title: "Dialogs", build: {
        let page = Page("Dialogs")
        page.loadViewIfNeeded()
        page.add(label("Behind the dialog", size: 17))
        return page
    }, script: { d, controller in
        d.checkpoint(shows: ["Dialogs", "Behind the dialog"])
        let alert = UIAlertController(title: "Delete photo?", message: "This cannot be undone.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive))
        controller.present(alert, animated: true)
        d.checkpoint("alert", shows: ["Delete photo?", "This cannot be undone.", "Cancel", "Delete", "Behind the dialog"],
                     settle: 0.8)
        alert.dismiss(animated: false)
        d.wait(0.4)
        let sheet = UIAlertController(title: "Share", message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Copy link", style: .default))
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        controller.present(sheet, animated: true)
        d.checkpoint("action-sheet", shows: ["Share", "Copy link", "Cancel"], hides: ["Delete photo?"], settle: 0.8)
        sheet.dismiss(animated: false)
        d.wait(0.4)
        d.checkpoint("dismissed", shows: ["Behind the dialog"], hides: ["Copy link"])
    })

    // MARK: - 21 sheets: a page sheet at its medium detent, then large

    static let sheets = GalleryScenario(id: "sheets", title: "Sheets", build: {
        let page = Page("Sheets")
        page.loadViewIfNeeded()
        page.add(label("Under the sheet", size: 17))
        return page
    }, script: { d, controller in
        let content = UIViewController()
        content.view.backgroundColor = .secondarySystemBackground
        let text = GalleryScenes.label("A half-height sheet", size: 20, weight: .semibold)
        text.frame = CGRect(x: 20, y: 30, width: 300, height: 28)
        content.view.addSubview(text)
        let presentation = content.sheetPresentationController
        presentation?.detents = [.medium(), .large()]
        presentation?.prefersGrabberVisible = true
        controller.present(content, animated: true)
        d.checkpoint(shows: ["A half-height sheet", "Under the sheet"], settle: 0.9)
        presentation?.animateChanges { presentation?.selectedDetentIdentifier = .large }
        text.text = "Now a full-height sheet"
        d.checkpoint("large", shows: ["Now a full-height sheet"], hides: ["A half-height sheet"], settle: 0.9)
        content.dismiss(animated: true)
        d.checkpoint("dismissed", shows: ["Under the sheet"], hides: ["Now a full-height sheet"], settle: 0.9)
    })

    // MARK: - 22 menus: a popover over its anchor

    final class PopoverStyle: NSObject, UIPopoverPresentationControllerDelegate {
        func adaptivePresentationStyle(for controller: UIPresentationController, traitCollection: UITraitCollection)
            -> UIModalPresentationStyle { .none }
    }

    static let popoverStyle = PopoverStyle()

    static let menus = GalleryScenario(id: "menus", title: "Menus", build: {
        let page = Page("Menus")
        page.loadViewIfNeeded()
        page.add(label("Behind the menu", size: 17))
        let anchor = UIButton(type: .system)
        anchor.setTitle("More actions", for: .normal)
        anchor.tag = 2201
        page.row([anchor, UIView()])
        page.add(label("Further down the page", size: 17))
        return page
    }, script: { d, controller in
        guard let anchor = controller.view.viewWithTag(2201) else { return d.fail("no anchor") }
        let menu = UIViewController()
        menu.view.backgroundColor = .systemBackground
        menu.preferredContentSize = CGSize(width: 220, height: 132)
        for (i, title) in ["Rename file", "Duplicate file", "Move to trash"].enumerated() {
            let row = GalleryScenes.label(title, size: 17, color: i == 2 ? .systemRed : .label)
            row.frame = CGRect(x: 16, y: 12 + CGFloat(i) * 40, width: 190, height: 28)
            menu.view.addSubview(row)
        }
        menu.modalPresentationStyle = .popover
        if let popover = menu.popoverPresentationController {
            popover.sourceView = anchor
            popover.sourceRect = anchor.bounds
            popover.permittedArrowDirections = .up
            popover.delegate = GalleryScenes.popoverStyle
        }
        d.tap(anchor) { controller.present(menu, animated: true) }
        d.checkpoint(shows: ["Rename file", "Duplicate file", "Move to trash", "More actions", "Behind the menu"], settle: 0.9)
        d.tap(at: CGPoint(x: 60, y: d.size.height - 120)) { menu.dismiss(animated: true) }
        d.checkpoint("dismissed", shows: ["More actions", "Further down the page"], hides: ["Rename file"], settle: 0.9)
    })
}
#endif
