import Foundation

/// Formats errors into the textual stack-trace shape the Traceway backend
/// parses: a first line `<Type>: <message>` followed by stack frames, one per
/// line. Mirrors the Android `StackTraceFormatter.kt` / Flutter `formatException`.
///
/// Swift `Error` values do not carry a captured stack trace, so callers pass an
/// explicit frame list — typically `Thread.callStackSymbols` captured at the
/// point of `capture(...)`.
enum StackTraceFormatter {

    /// Core formatter: `type`, optional `message`, then `frames`.
    static func format(type: String, message: String?, frames: [String]) -> String {
        var result = type
        if let message = message, !message.isEmpty {
            result += ": "
            result += message
        }
        if !frames.isEmpty {
            result += "\n"
            result += frames.joined(separator: "\n")
        }
        return trimTrailing(result)
    }

    /// Formats a caught Swift `Error`. `callStack` is usually
    /// `Thread.callStackSymbols` captured at the capture site.
    static func format(_ error: Error, callStack: [String]) -> String {
        let (type, message) = errorTypeAndMessage(error)
        return format(type: type, message: message, frames: callStack)
    }

    /// The `<Type>` / `<Type>: <message>` first line for a caught `Error`, with
    /// no frames. Used to build the iOS wire trace for server-side symbolication.
    static func errorHeader(_ error: Error) -> String {
        let (type, message) = errorTypeAndMessage(error)
        return format(type: type, message: message, frames: [])
    }

    private static func errorTypeAndMessage(_ error: Error) -> (String, String?) {
        // NSError (and ObjC-bridged errors) read best as domain + description.
        if isFoundationError(error) {
            let nsError = error as NSError
            return (nsError.domain, "\(nsError.localizedDescription) (code \(nsError.code))")
        }
        let typeName = String(reflecting: type(of: error))
        // `String(describing:)` prints enum cases with associated values for
        // Swift errors, which is far more useful than `localizedDescription`.
        let described = String(describing: error)
        let message = (described == typeName || described.isEmpty) ? nil : described
        return (typeName, message)
    }

    /// Formats an explicit `NSError` (domain/code/localizedDescription).
    static func format(_ error: NSError, callStack: [String]) -> String {
        let message = "\(error.localizedDescription) (code \(error.code))"
        return format(type: error.domain, message: message, frames: callStack)
    }

    // MARK: - Helpers

    /// Heuristic for "this is really an NSError instance" vs. a Swift error
    /// type that merely bridges to NSError. Bridged Swift errors live in the
    /// synthetic `*.error` / Swift-internal domains.
    private static func isFoundationError(_ error: Error) -> Bool {
        let typeName = String(reflecting: type(of: error))
        return typeName.contains("NSError")
    }

    private static func trimTrailing(_ s: String) -> String {
        var end = s.endIndex
        while end > s.startIndex {
            let prev = s.index(before: end)
            if s[prev].isWhitespace || s[prev].isNewline {
                end = prev
            } else {
                break
            }
        }
        return String(s[s.startIndex..<end])
    }
}
