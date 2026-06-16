import Foundation

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

    func serialized() -> String {
        toJSON().serialize()
    }
}
