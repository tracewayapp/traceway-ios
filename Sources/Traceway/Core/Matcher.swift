import Foundation

/// Resolves a matcher key such as `event.name` or
/// `attributes.http.response.status_code` to a value.
typealias FieldLookup = (String) -> JSON?

/// One record or app event as triggers see it.
struct ObservedEvent {
    var timeMs: Int64
    var lookup: FieldLookup
    /// Set for the tap and hover events the app feeds in directly (`click`
    /// or `hover`). They answer almost no field, so only a step that names
    /// this event type may match them: a negated condition would otherwise
    /// match every tap.
    var sequence: String? = nil
    /// For taps and hovers: whether a selector matches the view under the
    /// pointer or one of its ancestors.
    var targetMatches: ((String) -> Bool)? = nil
}

/// Lookup key of the tap and hover events the app feeds to triggers: the
/// action (`click` or `hover`).
let keyPointerAction = "browser.action"

/// Text conditions look at most at this much of a value (UTF-16 code units),
/// so a huge log line cannot stall the app.
private let maxMatchText = 4096

private func absent(_ value: JSON?) -> Bool {
    guard let value = value else { return true }
    return value.isNull
}

/// [text] cut to `count` UTF-16 code units, as Dart's `substring` does.
func truncatedUTF16(_ text: String, _ count: Int) -> String {
    guard text.utf16.count > count else { return text }
    return String(decoding: Array(text.utf16.prefix(count)), as: UTF16.self)
}

private func asNumber(_ value: JSON?) -> Double? {
    guard let value = value else { return nil }
    if let n = value.number { return n }
    if let s = value.string {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // Dart's `double.tryParse` reads no hex floats.
        if trimmed.isEmpty || trimmed.contains(where: { $0 == "x" || $0 == "X" || $0 == "p" || $0 == "P" }) {
            return nil
        }
        if let n = Double(trimmed), n.isFinite { return n }
    }
    return nil
}

private func same(_ actual: JSON?, _ expected: JSON?) -> Bool {
    if absent(actual) && absent(expected) { return true }
    guard let actual = actual, !actual.isNull else { return false }
    if let expected = expected, actual == expected { return true }
    let a = asNumber(actual)
    let e = asNumber(expected)
    if let a = a, let e = e { return a == e }
    guard let expected = expected, !expected.isNull else { return false }
    return actual.text == expected.text
}

private let versionPattern = try! NSRegularExpression(pattern: #"^v?(\d+(?:\.\d+)*)"#)
private let comparatorPattern = try! NSRegularExpression(pattern: #"^(>=|<=|>|<|==|=|!=)?(.+)$"#)

private func firstGroups(_ regex: NSRegularExpression, _ text: String) -> [String?]? {
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = regex.firstMatch(in: text, options: [], range: range) else { return nil }
    return (0..<match.numberOfRanges).map { i in
        let r = match.range(at: i)
        guard r.location != NSNotFound, let swiftRange = Range(r, in: text) else { return nil }
        return String(text[swiftRange])
    }
}

private func versionParts(_ version: String) -> [Int]? {
    let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let groups = firstGroups(versionPattern, trimmed), let digits = groups[1] else { return nil }
    var parts: [Int] = []
    for part in digits.split(separator: ".", omittingEmptySubsequences: false) {
        guard let n = Int(part) else { return nil }
        parts.append(n)
    }
    return parts
}

/// -1, 0 or 1, or nil when either side is not a version.
func compareVersions(_ a: String, _ b: String) -> Int? {
    guard let pa = versionParts(a), let pb = versionParts(b) else { return nil }
    for i in 0..<max(pa.count, pb.count) {
        let x = i < pa.count ? pa[i] : 0
        let y = i < pb.count ? pb[i] : 0
        if x != y { return x < y ? -1 : 1 }
    }
    return 0
}

/// Checks a version against a constraint such as `>=2.1 <3` (comparators
/// separated by spaces or commas, all must hold).
func satisfiesVersion(_ version: String, _ constraint: String) -> Bool {
    let comparators = constraint
        .split(whereSeparator: { $0 == "," || $0.isWhitespace })
        .map(String.init)
        .filter { !$0.isEmpty }
    if comparators.isEmpty { return false }
    for comparator in comparators {
        guard let groups = firstGroups(comparatorPattern, comparator), let target = groups[2],
              let cmp = compareVersions(version, target)
        else { return false }
        let ok: Bool
        switch groups[1] {
        case ">=": ok = cmp >= 0
        case "<=": ok = cmp <= 0
        case ">": ok = cmp > 0
        case "<": ok = cmp < 0
        case "!=": ok = cmp != 0
        default: ok = cmp == 0
        }
        if !ok { return false }
    }
    return true
}

private func matchText(_ value: JSON) -> String {
    truncatedUTF16(value.text, maxMatchText)
}

/// Case-insensitive wildcard match: `*` is any run of characters, `?` one
/// character, everything else literal. Greedy with a single backtrack
/// point, so it runs in O(text × pattern) at worst.
func globMatch(_ value: String, _ pattern: String) -> Bool {
    let t = Array(value.lowercased().utf16)
    let p = Array(pattern.lowercased().utf16)
    let star = UInt16(UInt8(ascii: "*"))
    let question = UInt16(UInt8(ascii: "?"))
    var ti = 0, pi = 0, starAt = -1, mark = 0
    while ti < t.count {
        if pi < p.count && (p[pi] == question || p[pi] == t[ti]) {
            ti += 1
            pi += 1
        } else if pi < p.count && p[pi] == star {
            starAt = pi
            pi += 1
            mark = ti
        } else if starAt >= 0 {
            pi = starAt + 1
            mark += 1
            ti = mark
        } else {
            return false
        }
    }
    while pi < p.count && p[pi] == star { pi += 1 }
    return pi == p.count
}

private func evaluate(_ condition: Condition, _ lookup: FieldLookup) -> Bool {
    let actual = lookup(condition.key)
    let present: Bool = {
        guard let actual = actual, !actual.isNull else { return false }
        return actual != .string("")
    }()
    let value = condition.value.flatMap { $0.isNull ? nil : $0 }
    switch condition.op {
    case "exists":
        return present
    case "not_exists":
        return !present
    case "eq":
        return same(actual, value)
    case "neq":
        return !same(actual, value)
    case "in":
        return (condition.values ?? []).contains { same(actual, $0) }
    case "not_in":
        return !(condition.values ?? []).contains { same(actual, $0) }
    case "contains":
        guard present, let actual = actual, let value = value else { return false }
        return matchText(actual).contains(value.text)
    case "icontains":
        guard present, let actual = actual, let value = value else { return false }
        return matchText(actual).lowercased().contains(value.text.lowercased())
    case "starts_with":
        guard present, let actual = actual, let value = value else { return false }
        return matchText(actual).hasPrefix(value.text)
    case "glob":
        guard present, let actual = actual, let value = value else { return false }
        return globMatch(matchText(actual), value.text)
    case "gt", "gte", "lt", "lte":
        guard let a = asNumber(actual), let e = asNumber(value) else { return false }
        switch condition.op {
        case "gt": return a > e
        case "gte": return a >= e
        case "lt": return a < e
        default: return a <= e
        }
    case "version":
        guard present, let actual = actual, let value = value else { return false }
        return satisfiesVersion(actual.text, value.text)
    default:
        return false
    }
}

private let routeParameter = try! NSRegularExpression(pattern: #"^\{[A-Za-z_][A-Za-z0-9_]*\}$"#)

private func isRouteParameter(_ part: String) -> Bool {
    let range = NSRange(part.startIndex..<part.endIndex, in: part)
    return routeParameter.firstMatch(in: part, options: [], range: range) != nil
}

private func decoded(_ segment: String) -> String {
    segment.removingPercentEncoding ?? segment
}

/// Characters a URI path keeps as they are; everything else is
/// percent-encoded as UTF-8, as Dart's `Uri` does.
private let pathAllowed: Set<UInt8> = Set(
    Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~!$&'()*+,;=:@/".utf8)
)

private let unreserved: Set<UInt8> = Set(
    Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~".utf8)
)

private func isHex(_ c: UInt8) -> Bool {
    (c >= 48 && c <= 57) || (c >= 65 && c <= 70) || (c >= 97 && c <= 102)
}

private func encodePath(_ path: String) -> String {
    let bytes = Array(path.utf8)
    var out = ""
    var i = 0
    while i < bytes.count {
        let b = bytes[i]
        if b == UInt8(ascii: "%"), i + 2 < bytes.count, isHex(bytes[i + 1]), isHex(bytes[i + 2]) {
            // An escape of an unreserved character is decoded, any other one
            // has its hex digits uppercased, as Dart normalizes them.
            let value = UInt8(String(UnicodeScalar(bytes[i + 1])) + String(UnicodeScalar(bytes[i + 2])), radix: 16)!
            if unreserved.contains(value) {
                out.unicodeScalars.append(UnicodeScalar(value))
            } else {
                out += String(format: "%%%02X", value)
            }
            i += 3
            continue
        }
        if pathAllowed.contains(b) {
            out.unicodeScalars.append(UnicodeScalar(b))
        } else {
            out += String(format: "%%%02X", b)
        }
        i += 1
    }
    return out
}

/// RFC 3986 remove_dot_segments.
private func removeDotSegments(_ path: String) -> String {
    var input = path
    var output: [String] = []
    let absolute = input.hasPrefix("/")
    if absolute { input.removeFirst() }
    let segments = input.components(separatedBy: "/")
    for (index, segment) in segments.enumerated() {
        let isLast = index == segments.count - 1
        switch segment {
        case ".":
            if isLast { output.append("") }
        case "..":
            if !output.isEmpty {
                output.removeLast()
                // A rootless path that loses its first segment keeps the
                // slash that followed it, as RFC 3986 does.
                if output.isEmpty && !absolute { output.append("") }
            }
            if isLast { output.append("") }
        default:
            output.append(segment)
        }
    }
    let joined = output.joined(separator: "/")
    return absolute ? "/" + joined : joined
}

/// The path part of a navigation target such as `/users/42?tab=1`, resolved
/// against `https://traceway.invalid/` as the browser SDK reads
/// `location.pathname`.
func pathOf(_ url: JSON?) -> String? {
    guard let url = url, !url.isNull else { return nil }
    let text = url.text
    if text.isEmpty { return nil }
    // Dart reads a backslash as a slash, as browsers do for http(s) URLs.
    var rest = Substring(text.replacingOccurrences(of: "\\", with: "/"))
    // Up to the query or fragment.
    if let cut = rest.firstIndex(where: { $0 == "?" || $0 == "#" }) {
        rest = rest[rest.startIndex..<cut]
    }
    var hasAuthority = false
    // A colon before the first slash ends a scheme: letters first, then
    // letters, digits, `+`, `-` or `.`; with any other scheme the text is
    // not a URL.
    if let colon = rest.firstIndex(of: ":"), rest.firstIndex(of: "/").map({ colon < $0 }) ?? true {
        let scheme = rest[rest.startIndex..<colon]
        guard let first = scheme.first, first.isASCII, first.isLetter, scheme.allSatisfy({
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == ".")
        }) else { return nil }
        rest = rest[rest.index(after: colon)...]
        if rest.hasPrefix("//") {
            rest = rest.dropFirst(2)
            let slash = rest.firstIndex(of: "/") ?? rest.endIndex
            rest = rest[slash...]
        }
        var path = String(rest)
        if scheme.lowercased() == "file" && !path.hasPrefix("/") { path = "/" + path }
        return removeDotSegments(encodePath(path))
    }
    if rest.hasPrefix("//") {
        rest = rest.dropFirst(2)
        let slash = rest.firstIndex(of: "/") ?? rest.endIndex
        rest = rest[slash...]
        hasAuthority = true
    }
    var path = String(rest)
    if !hasAuthority && !path.hasPrefix("/") {
        // Relative to the base's path, `/`.
        path = "/" + path
    }
    if path.isEmpty && !hasAuthority { path = "/" }
    return removeDotSegments(encodePath(path))
}

/// `/users/{id}` matches exactly one non-empty segment in that place; other
/// segments compare as written or percent-decoded, case-sensitively.
func matchesRoute(_ pattern: String, _ path: String) -> Bool {
    let expected = pattern.components(separatedBy: "/")
    let actual = path.components(separatedBy: "/")
    guard expected.count == actual.count else { return false }
    for (part, segment) in zip(expected, actual) {
        if isRouteParameter(part) {
            if segment.isEmpty { return false }
        } else if part != segment && part != decoded(segment) {
            return false
        }
    }
    return true
}

private func matchesEvent(_ matcher: EventMatcher, _ event: ObservedEvent) -> Bool {
    let lookup = event.lookup
    switch matcher.type {
    case "click", "hover":
        guard lookup(keyPointerAction)?.string == matcher.type, let test = event.targetMatches else {
            return false
        }
        return test(matcher.value)
    case "log":
        let name = lookup("event.name")?.string
        let signal = lookup("signal")?.string
        if name != "browser.console" && name != "traceway.message" && signal != "console"
            && signal != "messages"
        {
            return false
        }
        var body = ""
        if let raw = lookup("body"), !raw.isNull { body = raw.text }
        body = truncatedUTF16(body, maxMatchText)
        return matcher.mode == "contains" ? body.contains(matcher.value) : body == matcher.value
    case "navigation":
        guard lookup("event.name")?.string == "browser.navigation",
              let path = pathOf(lookup("attributes.url.full"))
        else { return false }
        return matchesRoute(matcher.value, path)
    default:
        return false
    }
}

func matches(_ matcher: Matcher, _ event: ObservedEvent) -> Bool {
    switch matcher {
    case .event(let e): return matchesEvent(e, event)
    case .condition(let c): return evaluate(c, event.lookup)
    case .all(let items): return items.allSatisfy { matches($0, event) }
    case .any(let items): return items.contains { matches($0, event) }
    case .not(let inner): return !matches(inner, event)
    }
}
