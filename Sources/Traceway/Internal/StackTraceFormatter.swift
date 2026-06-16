import Foundation

enum StackTraceFormatter {

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

    static func format(_ error: Error, callStack: [String]) -> String {
        let (type, message) = errorTypeAndMessage(error)
        return format(type: type, message: message, frames: callStack)
    }

    static func errorHeader(_ error: Error) -> String {
        let (type, message) = errorTypeAndMessage(error)
        return format(type: type, message: message, frames: [])
    }

    private static func errorTypeAndMessage(_ error: Error) -> (String, String?) {

        if isFoundationError(error) {
            let nsError = error as NSError
            return (nsError.domain, "\(nsError.localizedDescription) (code \(nsError.code))")
        }
        let typeName = String(reflecting: type(of: error))

        let described = String(describing: error)
        let message = (described == typeName || described.isEmpty) ? nil : described
        return (typeName, message)
    }

    static func format(_ error: NSError, callStack: [String]) -> String {
        let message = "\(error.localizedDescription) (code \(error.code))"
        return format(type: error.domain, message: message, frames: callStack)
    }

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
