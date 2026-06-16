import Foundation

/// Pluggable transport. Implementations must **never throw** — they return
/// `true` only on a confirmed successful upload (HTTP 200). This keeps the
/// client's sync loop simple and lets tests inject a fake sender.
protocol ReportSender {
    func send(apiUrl: String, token: String, jsonBody: String) -> Bool
}
