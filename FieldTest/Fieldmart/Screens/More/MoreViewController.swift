import SwiftUI
import UIKit
import FieldmartCore

/// More: a short list that leads to Diagnostics.
final class MoreViewController: UITableViewController {
    private let rows: [(title: String, id: String)] = [
        (FMText.More.diagnostics, "fm-more-diag"),
        (FMText.Search.title, "fm-more-search"),
    ]

    init() {
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = FMText.More.title
        tableView.accessibilityIdentifier = "fm-more-list"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "row")
        Autopilot.shared.tap("fm-more-diag") { [weak self] in self?.openDiagnostics() }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        fmScreenAppeared("more")
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        rows.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
        cell.textLabel?.text = rows[indexPath.row].title
        cell.accessoryType = .disclosureIndicator
        cell.accessibilityIdentifier = rows[indexPath.row].id
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch rows[indexPath.row].id {
        case "fm-more-diag": openDiagnostics()
        default: openSearch()
        }
    }

    private func openDiagnostics() {
        let host = UIHostingController(rootView: DiagnosticsView())
        host.title = FMText.Diag.title
        host.fmInstallBackButton()
        navigationController?.pushViewController(host, animated: true)
    }

    private func openSearch() {
        let search = SearchView(openProduct: { [weak self] id in
            self?.navigationController?.pushViewController(ProductViewController(productId: id), animated: true)
        })
        let host = UIHostingController(rootView: search)
        host.title = FMText.Search.title
        host.fmInstallBackButton()
        navigationController?.pushViewController(host, animated: true)
    }
}
