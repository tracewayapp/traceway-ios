import Foundation

/// The token + endpoint parsed out of a Traceway connection string.
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

/// Parses a connection string of the form `"{token}@{apiUrl}"`.
///
/// The split happens on the **first** `@` only — the `apiUrl` may itself
/// contain `@` (e.g. `https://user@example.com/api`). Both components must be
/// non-empty. This mirrors the Android `ConnectionString.kt` parser byte-for-byte.
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
