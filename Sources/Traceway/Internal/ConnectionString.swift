import Foundation

/// An old connection string as the start arguments it stands for.
struct ParsedConnectionString: Equatable {
    let token: String
    /// The server, normalized: `https://host` (any `/api` or `/api/report`
    /// dropped, `https://` added when it had no scheme).
    let baseUrl: String
}

enum ConnectionStringError: Error, CustomStringConvertible {
    case noToken

    var description: String {
        switch self {
        case .noToken:
            return "the connection string is not YOUR_TOKEN@https://host; connection strings are deprecated, "
                + "pass the token: Traceway.initialize(token: \"YOUR_TOKEN\")"
        }
    }
}

/// Splits an old connection string, `token@https://host[/api[/report]]`,
/// the one way every Traceway SDK does: trimmed, split at the first `@` into
/// the token (trimmed, not empty) and the server's URL, which
/// `normalizeBaseUrl` turns into its base URL. Throws, never with the token
/// in the message, for a string without a token or with an unusable URL.
func parseConnectionString(_ connectionString: String) throws -> ParsedConnectionString {
    let trimmed = connectionString.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let at = trimmed.firstIndex(of: "@") else { throw ConnectionStringError.noToken }
    let token = trimmed[..<at].trimmingCharacters(in: .whitespacesAndNewlines)
    guard !token.isEmpty else { throw ConnectionStringError.noToken }
    let url = String(trimmed[trimmed.index(after: at)...])
    return ParsedConnectionString(token: token, baseUrl: try normalizeBaseUrl(url))
}
