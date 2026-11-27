import Foundation

/// What `TracewayOptions.beforeCapture` sees of an exception or a message
/// before it is recorded.
public struct TracewayCapturedError {
    /// The error captured, or nil for a message.
    public let error: Error?
    /// The error's type (`NSURLErrorDomain`, `Shop.CheckoutError`); nil for
    /// a message.
    public let type: String?
    /// The error's text, or the message.
    public let message: String
    /// A message from `captureMessage`, not an exception.
    public let isMessage: Bool
    /// The attributes it will carry: the caller's and the screen it
    /// happened on.
    public let attributes: [String: String]
    /// The stack trace sent with an exception (binary images and offsets,
    /// symbolicated by the server); nil for a message.
    public let stackTrace: String?
}

/// One entry of `TracewayOptions.ignoreErrors`: text the first line
/// `Type: message` contains (a string literal), or a regular expression
/// found anywhere in it.
public struct TracewayErrorPattern: ExpressibleByStringLiteral {
    private let test: (String) -> Bool

    private init(_ test: @escaping (String) -> Bool) {
        self.test = test
    }

    public init(stringLiteral value: String) {
        self = .contains(value)
    }

    /// Matches a line that contains `text`.
    public static func contains(_ text: String) -> TracewayErrorPattern {
        TracewayErrorPattern { $0.contains(text) }
    }

    /// Matches a line in which `expression` finds a match.
    public static func regex(_ expression: NSRegularExpression) -> TracewayErrorPattern {
        TracewayErrorPattern { line in
            expression.firstMatch(in: line, options: [], range: NSRange(line.startIndex..<line.endIndex, in: line)) != nil
        }
    }

    /// Matches a line in which the regular expression `pattern` finds a
    /// match. A pattern that does not compile matches nothing.
    public static func regex(_ pattern: String, options: NSRegularExpression.Options = []) -> TracewayErrorPattern {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else {
            Log.warn("ignoreErrors: \(pattern) is not a regular expression")
            return TracewayErrorPattern { _ in false }
        }
        return regex(expression)
    }

    func matches(_ line: String) -> Bool { test(line) }
}

/// The line `ignoreErrors` patterns are matched against: `Type: message`
/// (the type left out when the message starts with it), first line only.
/// Matching the stack would let a function named like a pattern silence
/// every error that passes through it.
func ignoreLine(type: String?, message: String) -> String {
    let line: String
    if let type = type, !type.isEmpty {
        line = message.isEmpty ? type : (message.hasPrefix(type) ? message : "\(type): \(message)")
    } else {
        line = message
    }
    return line.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
}
