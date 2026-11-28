import SwiftUI
import UIKit
import FieldmartCore

/// Home, Markets, Feed, Checkout and More, each in its own navigation
/// controller (`02-APP-SPEC.md` §2.8).
final class RootTabBarController: UITabBarController {
    enum Tab: Int {
        case home, markets, feed, checkout, more
    }

    let checkoutModel = CheckoutModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        let settings = AppEnvironment.shared.settings
        let checkout = CheckoutHost.make(model: checkoutModel)
        viewControllers = [
            navigation(HomeViewController(), image: "house", id: "fm-nav-home"),
            navigation(MarketsViewController(), image: "chart.line.uptrend.xyaxis", id: "fm-nav-markets"),
            navigation(FeedFactory.make(settings.toolkit), image: "list.bullet", id: "fm-nav-feed"),
            navigation(checkout, image: "cart", id: "fm-nav-checkout"),
            navigation(MoreViewController(), image: "ellipsis.circle", id: "fm-nav-more"),
        ]
        Autopilot.shared.tabs = self
    }

    private func navigation(_ root: UIViewController, image: String, id: String) -> UINavigationController {
        let navigation = UINavigationController(rootViewController: root)
        navigation.tabBarItem = UITabBarItem(title: FMText.tabs[id] ?? id, image: UIImage(systemName: image), tag: 0)
        navigation.tabBarItem.accessibilityIdentifier = id
        return navigation
    }

    func select(_ tab: Tab) {
        selectedIndex = tab.rawValue
    }
}
