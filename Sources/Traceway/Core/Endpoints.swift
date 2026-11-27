import Foundation

struct ConfigurationError: Error, CustomStringConvertible {
    let description: String
}

/// Every endpoint the SDK talks to on a Traceway server, derived from its
/// base URL (`baseUrl`).
struct TracewayEndpoints {
    /// Where the server is reachable, without a trailing slash.
    let base: String
    let logs: URL
    let traces: URL
    let metrics: URL
    let opamp: URL
    let recordings: URL

    /// True for the SDK's own requests, which must not be recorded as
    /// network telemetry.
    func isOwn(_ url: String) -> Bool {
        !base.isEmpty && (url.hasPrefix(base + "/api/otel/") || url.hasPrefix(recordings.absoluteString))
    }
}

/// Hosts a URL without a scheme reaches over plain `http://`: the machine
/// itself, or it seen from an Android emulator.
private let localHosts: Set<String> = ["localhost", "127.0.0.1", "10.0.2.2", "[::1]"]

/// A server URL as every Traceway SDK normalizes it, and whether a scheme
/// had to be added.
struct NormalizedBaseUrl: Equatable {
    let base: String
    let schemeAdded: Bool
}

/// The Traceway server's base URL by the rules every SDK shares: trimmed;
/// `https://` added when there is no scheme (`http://` for `localhost`,
/// `127.0.0.1`, `10.0.2.2` and `[::1]`); a query or fragment dropped, then
/// trailing slashes; a trailing `/api/report`, else `/api`, dropped, then
/// trailing slashes again. Any other path is kept, so a server under a
/// sub-path stays reachable. Lowercase scheme and host and no default port,
/// the form request URLs take (`isOwn` compares them). Throws, without
/// trapping on any input, when the result is not an HTTP(S) URL with a host.
func normalizeBaseUrlDetailed(_ raw: String) throws -> NormalizedBaseUrl {
    var url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    var schemeAdded = false
    if !url.isEmpty, !url.contains("://") {
        let authority = url.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        let host: Substring
        if authority.hasPrefix("["), let close = authority.firstIndex(of: "]") {
            host = authority[...close]
        } else {
            host = authority.prefix { $0 != ":" }
        }
        url = (localHosts.contains(host.lowercased()) ? "http://" : "https://") + url
        schemeAdded = true
    }
    if let hash = url.firstIndex(of: "#") { url = String(url[..<hash]) }
    if let query = url.firstIndex(of: "?") { url = String(url[..<query]) }
    guard var components = URLComponents(string: url),
          let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
          let host = components.host, !host.isEmpty, host.count <= 255,
          components.query == nil, components.fragment == nil
    else {
        throw ConfigurationError(description:
            "\"\(shortened(raw))\" is not a Traceway server URL; expected https://host, e.g. \(Traceway.defaultBaseUrl)")
    }
    var path = trimmingTrailingSlashes(components.percentEncodedPath)
    if path.hasSuffix("/api/report") {
        path.removeLast("/api/report".count)
    } else if path.hasSuffix("/api") {
        path.removeLast("/api".count)
    }
    components.percentEncodedPath = trimmingTrailingSlashes(path)
    components.scheme = scheme
    components.host = host.lowercased()
    if (scheme == "https" && components.port == 443) || (scheme == "http" && components.port == 80) {
        components.port = nil
    }
    guard let base = components.string else {
        throw ConfigurationError(description:
            "\"\(shortened(raw))\" is not a Traceway server URL; expected https://host, e.g. \(Traceway.defaultBaseUrl)")
    }
    return NormalizedBaseUrl(base: base, schemeAdded: schemeAdded)
}

/// `normalizeBaseUrlDetailed`'s base URL.
func normalizeBaseUrl(_ raw: String) throws -> String {
    try normalizeBaseUrlDetailed(raw).base
}

private func trimmingTrailingSlashes(_ text: String) -> String {
    var out = Substring(text)
    while out.hasSuffix("/") { out = out.dropLast() }
    return String(out)
}

/// A value the app passed, as a message may quote it: the first 120
/// characters, without control characters.
func shortened(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let clean = String(trimmed.unicodeScalars.prefix(120).map {
        CharacterSet.controlCharacters.contains($0) ? "?" : Character($0)
    })
    return trimmed.unicodeScalars.count > 120 ? clean + "…" : clean
}

/// Every endpoint of the server at `baseUrl`, normalized by
/// `normalizeBaseUrl` (a 2.0 URL ending in `/api` or `/api/report` works).
/// With `debug`, a URL that had no scheme says once which one it got.
func resolveEndpoints(_ baseUrl: String) throws -> TracewayEndpoints {
    let normalized = try normalizeBaseUrlDetailed(baseUrl)
    let base = normalized.base
    if normalized.schemeAdded {
        Log.debugOnce("baseUrl scheme", "baseUrl \"\(shortened(baseUrl))\" has no scheme; using \(base)")
    }
    guard let logs = URL(string: base + "/api/otel/v1/logs"),
          let traces = URL(string: base + "/api/otel/v1/traces"),
          let metrics = URL(string: base + "/api/otel/v1/metrics"),
          let opamp = URL(string: base + "/api/otel/v1/opamp"),
          let recordings = URL(string: base + "/api/recordings")
    else {
        throw ConfigurationError(description:
            "\"\(shortened(baseUrl))\" is not a Traceway server URL; expected https://host, e.g. \(Traceway.defaultBaseUrl)")
    }
    return TracewayEndpoints(
        base: base, logs: logs, traces: traces, metrics: metrics, opamp: opamp, recordings: recordings
    )
}

/// Where one OTLP signal is sent, and with which headers.
struct OtlpDestination {
    let url: URL
    let headers: [String: String]
    /// Not Traceway: a receiver from `TracewayTelemetry`.
    var external = false

    /// Identifies the destination, credentials included, for state kept per
    /// destination (queued batches, the saved buffer), so a changed receiver
    /// is never sent what was meant for the previous one. A hash, so no
    /// credential is written to disk in the clear.
    var key: String {
        var parts = [external ? "collector" : "traceway", url.absoluteString]
        for name in headers.keys.map({ $0.lowercased() }).sorted() {
            let value = headers.first(where: { $0.key.lowercased() == name })?.value ?? ""
            parts.append(name)
            parts.append(value)
        }
        return Ids.fingerprint64(JSON(parts).encoded())
    }
}

/// The destination of every OTLP signal: Traceway's, or the receiver the
/// app configured with `TracewayTelemetry`.
struct TelemetryRoutes {
    let logs: OtlpDestination
    let traces: OtlpDestination
    let metrics: OtlpDestination
    /// Traceway's log endpoint, for exceptions, messages and the SDK's
    /// control records when ordinary logs go elsewhere. Nil standalone.
    let traceway: OtlpDestination?

    var bufferDestination: String {
        Ids.fingerprint64(JSON([traceway?.key ?? "", logs.key, traces.key]).encoded())
    }

    func diagnosticDirectory(in state: URL) -> URL {
        // A recovered crash can emit both an issue and a crash metric.
        let destination = Ids.fingerprint64(JSON([bufferDestination, metrics.key]).encoded())
        return state.appendingPathComponent("diagnostics").appendingPathComponent(destination)
    }

    /// Whether logs go somewhere other than Traceway while Traceway still
    /// receives issues and session records.
    var splitsLogs: Bool { logs.external && traceway != nil }

    /// True for requests to an external destination of the SDK.
    func isOwn(_ url: String) -> Bool {
        (logs.external && url.hasPrefix(logs.url.absoluteString))
            || (traces.external && url.hasPrefix(traces.url.absoluteString))
            || (metrics.external && url.hasPrefix(metrics.url.absoluteString))
    }

    /// `endpoints` and `token` are nil when the SDK runs standalone; then
    /// `telemetry` must name a destination for every signal.
    static func resolve(
        endpoints: TracewayEndpoints?,
        token: String?,
        telemetry: TracewayTelemetry?
    ) throws -> TelemetryRoutes {
        var auth: [String: String] = [:]
        if let token = token { auth["Authorization"] = "Bearer \(token)" }

        func route(_ kind: String, _ endpoint: TracewayTelemetryEndpoint?, _ tracewayURL: URL?) throws -> OtlpDestination {
            // A blank url is unset, as in the browser and Android SDKs.
            let base = telemetry?.url.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            if endpoint == nil, base == nil {
                guard let tracewayURL = tracewayURL else {
                    throw ConfigurationError(description:
                        "TracewayTelemetry has no destination for \(kind): standalone telemetry needs a url or all three signal endpoints")
                }
                return OtlpDestination(url: tracewayURL, headers: auth)
            }
            var headers = telemetry?.headers ?? [:]
            for (name, value) in endpoint?.headers ?? [:] { headers[name] = value }
            if let endpoint = endpoint {
                return OtlpDestination(url: try checkedURL(endpoint.url), headers: headers, external: true)
            }
            guard let base = base else {
                throw ConfigurationError(description: "TracewayTelemetry has no destination for \(kind)")
            }
            var text = try checkedURL(base).absoluteString
            while text.hasSuffix("/") { text.removeLast() }
            guard let url = URL(string: "\(text)/v1/\(kind)") else {
                throw ConfigurationError(description: "TracewayTelemetry url is invalid: \(base)")
            }
            return OtlpDestination(url: url, headers: headers, external: true)
        }

        return TelemetryRoutes(
            logs: try route("logs", telemetry?.logs, endpoints?.logs),
            traces: try route("traces", telemetry?.traces, endpoints?.traces),
            metrics: try route("metrics", telemetry?.metrics, endpoints?.metrics),
            traceway: endpoints.map { OtlpDestination(url: $0.logs, headers: auth) }
        )
    }

    static func checkedURL(_ raw: String) throws -> URL {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              let url = components.url
        else {
            throw ConfigurationError(description:
                "TracewayTelemetry url must be an HTTP(S) URL without credentials, query, or fragment: \(raw)")
        }
        return url
    }
}
