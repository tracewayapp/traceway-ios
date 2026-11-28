import Foundation

/// The fixed texts Fieldmart shows, verbatim from `shared/labels.json`
/// (the journey's checkpoints expect them on screen; `LabelsTests` checks
/// every one against the shared file). The UI test driver uses some of them
/// too: a menu item or a tab is found by its label when the system does not
/// expose its id.
public enum FMText {
    public static let appName = "Fieldmart"

    /// The tab bar's titles by automation id; `Back`.
    public static let tabs = [
        "fm-nav-home": "Home", "fm-nav-markets": "Markets", "fm-nav-feed": "Feed",
        "fm-nav-checkout": "Checkout", "fm-nav-more": "More",
    ]
    public static let back = "Back"

    public enum Home {
        public static let search = "Search Fieldmart"
        public static let deals = "Today's deals"
        public static let grid = "Popular now"
        public static let new = "New"
        public static let sale = "Sale"
        /// `({n})` after the rating.
        public static func reviews(_ n: Int) -> String { "(\(n))" }
    }

    public enum Product {
        public static func galleryCounter(_ i: Int, of total: Int) -> String { "\(i) / \(total)" }
        public static let readMore = "Read more"
        public static let readLess = "Show less"
        public static let size = "Size"
        public static let colour = "Colour"
        public static func quantity(_ n: Int) -> String { "Qty \(n)" }
        public static func stock(_ n: Int) -> String { "In stock: \(n)" }
        public static let reviews = "Reviews"
        public static let helpful = "Helpful"
        public static let add = "Add to cart"
        public static let added = "Added to cart"
    }

    public enum Markets {
        public static let title = "Markets"
        public static func polls(_ n: Int) -> String { "Polls \(n)" }
        public static let timeframes = ["1H", "1D", "1W", "1M", "1Y"]
        public static let watchlist = "Watchlist"
        public static let orderBook = "Order book"
        public static let openBook = "Order book"
        public static let bids = "Bids"
        public static let asks = "Asks"
        public static let close = "Close"
    }

    public enum Feed {
        public static let title = "Activity"
        public static let jumpEnd = "Jump to end"
        public static let jumpStart = "Jump to start"
        public static let goTo = "Go to row"
        public static let go = "Go"
        public static let refresh = "Refresh"
        public static func header(_ n: Int) -> String { "Week \(n)" }
    }

    public enum Checkout {
        public static let title = "Checkout"
        public static let sections = ["Contact", "Delivery", "Payment", "Review"]
        public static let name = "Full name"
        public static let email = "Email"
        public static let phone = "Phone"
        public static let account = "Create account"
        public static let password = "Password"
        public static let address = "Address"
        public static let city = "City"
        public static let postcode = "Postcode"
        public static let country = "Country"
        public static let countryPicker = "Choose country"
        public static let date = "Delivery date"
        public static let datePicker = "Choose delivery date"
        public static let window = "Delivery window"
        public static let windows = ["Morning", "Afternoon", "Evening"]
        public static let door = "Leave at door"
        public static let gift = "Gift wrap"
        public static let giftNote = "Gift note"
        public static let card = "Card number"
        public static let expiry = "Expiry"
        public static let cvv = "CVV"
        public static let cardName = "Name on card"
        public static let saveCard = "Save card"
        public static let tip = "Tip"
        public static func tipValue(_ n: Int) -> String { "\(n)%" }
        public static let promo = "Promo code"
        public static let summary = "Order summary"
        public static let loyalty = "Loyalty number"
        public static let terms = "Terms and conditions"
        public static let agree = "I agree"
        public static let menu = "Delivery instructions"
        public static let menuItems = ["Ring the bell", "Call on arrival", "Leave with a neighbour", "No instructions"]
        public static let edit = "Edit items"
        public static let done = "Done"
        public static let rating = "How was checkout?"
        public static let notes = "Notes"
        public static let place = "Place order"
        public static let success = "Order placed"
        public static func successDetail(_ order: String) -> String { "Your order number is \(order)" }
    }

    public enum Search {
        public static let title = "Search"
        public static let field = "Search products"
        public static let recent = "Recent searches"
        public static let empty = "No results"
    }

    public enum More {
        public static let title = "More"
        public static let diagnostics = "Diagnostics"
    }

    public enum Diag {
        public static let title = "Diagnostics"
        public static let run = "Run"
        public static let variant = "Variant"
        public static let scenario = "Scenario"
        public static let build = "Build"
        public static let session = "Session"
        public static let buttons = [
            "fm-diag-handled": "Report handled error",
            "fm-diag-unhandled": "Throw unhandled error",
            "fm-diag-reject": "Unhandled rejection",
            "fm-diag-hang": "Block main thread",
            "fm-diag-logs": "Write 1,000 log lines",
            "fm-diag-http500": "Request returning 500",
            "fm-diag-slow": "Slow request",
            "fm-diag-event": "Send custom event",
            "fm-diag-message": "Send message",
        ]
    }

    // Shortcuts the driver and older code use.
    public static var menuItems: [String] { Checkout.menuItems }
    public static var windows: [String] { Checkout.windows }

    /// The three items of "Edit items" and their prices (app data, not labels).
    public static let editItems = ["Trail bottle", "Camp mug", "Wool socks"]
    public static let editItemPrices = [1_850, 1_450, 1_299]

    /// The loyalty number shown with the mask marker (a sentinel).
    public static let loyaltyNumber = "LOY-88442211"

    /// Used until `/fx/api/countries` answers.
    public static let fallbackCountries = ["Norway", "Portugal", "Spain", "Sweden"]
}
