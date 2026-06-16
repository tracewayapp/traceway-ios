import Foundation

struct DefaultReportSender: ReportSender {

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config)
    }

    func send(apiUrl: String, token: String, jsonBody: String) -> Bool {
        guard let url = URL(string: apiUrl) else { return false }
        guard let body = Gzip.compress(Data(jsonBody.utf8)) else { return false }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = body

        let semaphore = DispatchSemaphore(value: 0)
        var success = false
        var statusCode = -1
        var transportError: String?
        let task = session.dataTask(with: request) { _, response, error in
            if let http = response as? HTTPURLResponse {
                statusCode = http.statusCode
                success = http.statusCode == 200
            }
            if let error = error { transportError = "\(error)" }
            semaphore.signal()
        }
        task.resume()

        _ = semaphore.wait(timeout: .now() + 35)
        Log.debug("POST \(apiUrl) -> status=\(statusCode) error=\(transportError ?? "none")")
        return success
    }
}
