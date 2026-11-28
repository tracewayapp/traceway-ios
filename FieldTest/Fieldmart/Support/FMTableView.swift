import UIKit

/// A `UITableView` whose accessibility (what UI automation and VoiceOver see)
/// holds only what is on screen: the table header and footer, the visible
/// section headers and the visible cells.
///
/// UIKit otherwise offers every row of a table to accessibility and creates a
/// cell for each one it is asked about, so one UI-automation query of the
/// 10,000-row feed took minutes and timed out (first smoke run). The SDK does
/// not use accessibility for UIKit views, so the replay is not affected; every
/// variant, `off` included, uses this table.
final class FMTableView: UITableView {
    private func onScreenElements() -> [Any] {
        var elements: [Any] = []
        if let header = tableHeaderView { elements.append(header) }
        let sections = Set((indexPathsForVisibleRows ?? []).map { $0.section })
        for section in sections.sorted() {
            if let header = headerView(forSection: section) { elements.append(header) }
        }
        let cells = visibleCells.sorted { $0.frame.minY < $1.frame.minY }
        elements.append(contentsOf: cells)
        if let footer = tableFooterView { elements.append(footer) }
        return elements
    }

    override func accessibilityElementCount() -> Int {
        onScreenElements().count
    }

    override func accessibilityElement(at index: Int) -> Any? {
        let elements = onScreenElements()
        return index >= 0 && index < elements.count ? elements[index] : nil
    }

    override func index(ofAccessibilityElement element: Any) -> Int {
        onScreenElements().firstIndex { ($0 as AnyObject) === (element as AnyObject) } ?? NSNotFound
    }

    override var accessibilityElements: [Any]? {
        get { onScreenElements() }
        set {}
    }

    /// The children UI automation asks for (private name of the
    /// accessibility runtime; the public methods above cover VoiceOver).
    @objc(_accessibilityUserTestingChildren)
    func fmUserTestingChildren() -> NSArray {
        onScreenElements() as NSArray
    }
}
