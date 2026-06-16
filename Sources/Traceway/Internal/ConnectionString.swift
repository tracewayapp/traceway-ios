import Foundation

struct ParsedConnectionString: Equatable {
    let token: String
    let apiUrl: String
}

enum ConnectionStringError: Error, CustomStringConvertible {
    case missingAtSign
    case emptyComponent

    var description: String {
        switch self {
        case .missingAtSign:
            return "Invalid connection string: must be in format {token}@{apiUrl}"
        case .emptyComponent:
            return "Invalid connection string: token and apiUrl must not be empty"
        }
    }
}

func parseConnectionString(_ connectionString: String) throws -> ParsedConnectionString {
    guard let atIndex = connectionString.firstIndex(of: "@") else {
        throw ConnectionStringError.missingAtSign
    }
    let token = String(connectionString[connectionString.startIndex..<atIndex])
    let apiUrl = String(connectionString[connectionString.index(after: atIndex)...])
    guard !token.isEmpty, !apiUrl.isEmpty else {
        throw ConnectionStringError.emptyComponent
    }
    return ParsedConnectionString(token: token, apiUrl: apiUrl)
}
