import Foundation

protocol ReportSender {
    func send(apiUrl: String, token: String, jsonBody: String) -> Bool
}
