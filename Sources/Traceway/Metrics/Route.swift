import Foundation

private let maxRouteSegments = 6
private let maxRouteLength = 64
private let idSegment = ":id"

private func isDigit(_ c: Unicode.Scalar) -> Bool { c >= "0" && c <= "9" }

private func isHex(_ c: Unicode.Scalar) -> Bool {
    isDigit(c) || (c >= "a" && c <= "f") || (c >= "A" && c <= "F")
}

private func isTokenCharacter(_ c: Unicode.Scalar) -> Bool {
    isDigit(c) || (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || "_-=.~".unicodeScalars.contains(c)
}

private func isUUID(_ s: [Unicode.Scalar]) -> Bool {
    guard s.count == 36 else { return false }
    for (i, c) in s.enumerated() {
        if i == 8 || i == 13 || i == 18 || i == 23 {
            if c != "-" { return false }
        } else if !isHex(c) {
            return false
        }
    }
    return true
}

/// A percent-encoded ASCII character (a space, a slash, a brace) is a value
/// somebody typed, never a route literal. Encoded UTF-8 bytes (`%C3%A9`)
/// stay.
private func hasEncodedASCII(_ s: [Unicode.Scalar]) -> Bool {
    guard s.count >= 3 else { return false }
    for i in 0..<(s.count - 2) where s[i] == "%" && s[i + 1] >= "0" && s[i + 1] <= "7" && isHex(s[i + 2]) {
        return true
    }
    return false
}

private func isId(_ segment: String) -> Bool {
    let s = Array(segment.unicodeScalars)
    if !s.isEmpty && s.allSatisfy(isDigit) { return true }
    if isUUID(s) || hasEncodedASCII(s) { return true }
    guard s.contains(where: isDigit) else { return false }
    return (s.count >= 8 && s.allSatisfy(isHex)) || (s.count >= 20 && s.allSatisfy(isTokenCharacter))
}

/// Where the query string or fragment begins, or nil. In a route template a
/// `?` ends an optional parameter (`/:lang?/about`) and is kept.
private func queryStart(_ path: [Character]) -> Int? {
    for (i, c) in path.enumerated() {
        if c == "#" { return i }
        guard c == "?" else { continue }
        var segment = 0
        if i > 0, let slash = path[..<i].lastIndex(of: "/") { segment = slash + 1 }
        let optionalParam = path[segment] == ":" && i + 1 < path.count && path[i + 1] == "/"
        if !optionalParam { return i }
    }
    return nil
}

private func utf16Count(_ s: String) -> Int { s.utf16.count }

/// Turns a route path into something close to its template, so
/// `/orders/8841` and `/orders/8842` are one series: segments that are
/// numbers, UUIDs, long hex or token strings, or that carry a
/// percent-encoded ASCII character become `:id`. The same rules as the
/// browser, Flutter and Android SDKs and the server
/// (`backend/app/clientmetrics/route.go`).
func normalizePath(_ path: String) -> String {
    let chars = Array(path)
    var clean = String(queryStart(chars).map { chars[..<$0] } ?? chars[...])
    while clean.hasSuffix("/") { clean.removeLast() }
    if clean.isEmpty { return "/" }
    let segments = clean.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    var truncated = segments.count > maxRouteSegments
    var kept = segments.prefix(maxRouteSegments).map { isId($0) ? idSegment : $0 }
    var out = "/" + kept.joined(separator: "/")
    while kept.count > 1 && utf16Count(out) + (truncated ? 2 : 0) > maxRouteLength {
        kept.removeLast()
        truncated = true
        out = "/" + kept.joined(separator: "/")
    }
    if truncated { out += "/*" }
    guard utf16Count(out) > maxRouteLength else { return out }
    return String(decoding: Array(out.utf16.prefix(maxRouteLength)), as: UTF16.self)
}
