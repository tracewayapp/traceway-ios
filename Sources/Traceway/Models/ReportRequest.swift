import Foundation

/// Top-level payload POSTed to `/api/report`.
struct ReportRequest {
    let collectionFrames: [CollectionFrame]
    let appVersion: String
    let serverName: String

    init(collectionFrames: [CollectionFrame], appVersion: String = "", serverName: String = "") {
        self.collectionFrames = collectionFrames
        self.appVersion = appVersion
        self.serverName = serverName
    }

    func toJSON() -> JSONValue {
        .object([
            ("collectionFrames", .array(collectionFrames.map { $0.toJSON() })),
            ("appVersion", .string(appVersion)),
            ("serverName", .string(serverName)),
        ])
    }

    /// Compact JSON string sent as the request body.
    func serialized() -> String {
        toJSON().serialize()
    }
}
