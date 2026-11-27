import Foundation

struct ConfigurationError: Error, CustomStringConvertible {
    let description: String
}

/// Every endpoint the SDK talks to on a Traceway server, derived from the
/// URL half of the connection string.
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

/// Accepts the bare server URL as well as the 1.x form that ended in
/// `/api/report`, so existing connection strings keep working.
func resolveEndpoints(_ apiUrl: String) throws -> TracewayEndpoints {
    var trimmed = apiUrl.trimmingCharacters(in: .whitespacesAndNewlines)
    while trimmed.hasSuffix("/") { trimmed.removeLast() }
    if trimmed.hasSuffix("/api/report") { trimmed.removeLast("/api/report".count) }
    if trimmed.hasSuffix("/api") { trimmed.removeLast("/api".count) }
    guard var components = URLComponents(string: trimmed),
          let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
          let host = components.host, !host.isEmpty
    else {
        throw ConfigurationError(description: "Invalid connection string: \(apiUrl) is not an HTTP(S) URL")
    }
    // In the form request URLs take (lowercase scheme and host), so isOwn
    // recognises the SDK's own requests.
    components.scheme = scheme
    components.host = host.lowercased()
    if (scheme == "https" && components.port == 443) || (scheme == "http" && components.port == 80) {
        components.port = nil
    }
    guard let base = components.string,
          let logs = URL(string: base + "/api/otel/v1/logs"),
          let traces = URL(string: base + "/api/otel/v1/traces"),
          let metrics = URL(string: base + "/api/otel/v1/metrics"),
          let opamp = URL(string: base + "/api/otel/v1/opamp"),
          let recordings = URL(string: base + "/api/recordings")
    else {
        throw ConfigurationError(description: "Invalid connection string: \(apiUrl)")
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
