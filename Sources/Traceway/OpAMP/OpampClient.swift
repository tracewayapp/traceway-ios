import Foundation

/// Result of applying a remote config; a nil `errorMessage` means applied.
struct ApplyResult: Equatable {
    var errorMessage: String?

    static let applied = ApplyResult(errorMessage: nil)

    static func failed(_ message: String) -> ApplyResult {
        ApplyResult(errorMessage: message)
    }

    var isApplied: Bool { errorMessage == nil }
}

/// An OpAMP client for the plain-HTTP transport: it polls, applies the
/// remote config the server offers and reports the result on the next poll.
/// Polling follows the server's heartbeat interval, backs off on errors and
/// honours Retry-After; a 413 is not retried and a 401/403/404/405/501 stops
/// the client.
///
/// Every method must be called on `queue`, and every callback runs there.
final class OpampClient {
    private static let maxBackoffMs: Int64 = 30 * 60_000
    private static let firstBackoffMs: Int64 = 30_000
    private static let stopCodes: Set<Int> = [401, 403, 404, 405, 501]

    /// The server's OpAMP endpoint, e.g. https://host/api/otel/v1/opamp.
    let endpoint: URL
    let headers: [String: String]
    let capabilities: UInt64
    let customCapabilities: [String]
    let requestTimeout: TimeInterval

    /// Read on every poll: the client sends its full state each time, so a
    /// stateless server can answer.
    private let describe: () -> AgentDescription
    private let onRemoteConfig: (RemoteConfig) -> ApplyResult
    private let onInstanceUidChange: (([UInt8]) -> Void)?
    /// Called once with the HTTP status when the server rejects the client
    /// for good (bad credentials or no OpAMP support).
    private let onStopped: ((Int) -> Void)?
    private let transport: HTTPTransport
    private let queue: DispatchQueue

    private let minIntervalMs: Int64
    private var uid: [UInt8]
    private var sequenceNum: UInt64 = 0
    private var status: RemoteConfigStatus?
    private var intervalMs: Int64
    private var backoffMs: Int64 = 0
    private var timer: DispatchWorkItem?
    private var inFlight = false
    /// Completions waiting for the exchange under way.
    private var waiters: [() -> Void] = []
    private var stopped = true

    init(
        endpoint: URL,
        headers: [String: String],
        instanceUid: [UInt8],
        capabilities: UInt64,
        customCapabilities: [String],
        describe: @escaping () -> AgentDescription,
        onRemoteConfig: @escaping (RemoteConfig) -> ApplyResult,
        appliedConfigHash: [UInt8]? = nil,
        onInstanceUidChange: (([UInt8]) -> Void)? = nil,
        onStopped: ((Int) -> Void)? = nil,
        defaultPollIntervalMs: Int64 = 300_000,
        minPollIntervalMs: Int64 = 30_000,
        transport: HTTPTransport,
        queue: DispatchQueue,
        requestTimeout: TimeInterval = 10
    ) {
        self.endpoint = endpoint
        self.headers = headers
        uid = instanceUid
        self.capabilities = capabilities
        self.customCapabilities = customCapabilities
        self.describe = describe
        self.onRemoteConfig = onRemoteConfig
        self.onInstanceUidChange = onInstanceUidChange
        self.onStopped = onStopped
        minIntervalMs = minPollIntervalMs
        intervalMs = max(defaultPollIntervalMs, minPollIntervalMs)
        self.transport = transport
        self.queue = queue
        self.requestTimeout = requestTimeout
        if let hash = appliedConfigHash, !hash.isEmpty {
            status = RemoteConfigStatus(lastRemoteConfigHash: hash, status: RemoteConfigStatuses.applied)
        }
    }

    var pollIntervalMs: Int64 { intervalMs }
    var isRunning: Bool { !stopped }
    var instanceUid: [UInt8] { uid }

    func start() {
        guard stopped else { return }
        stopped = false
        poll()
    }

    func stop() {
        stopped = true
        timer?.cancel()
        timer = nil
    }

    /// Polls now unless a poll is running or the client is backing off after
    /// an error. `completion` runs when the poll under way (or this one) is
    /// done, or right away when nothing is sent.
    func poll(completion: (() -> Void)? = nil) {
        if stopped {
            completion?()
            return
        }
        if inFlight {
            if let completion = completion { waiters.append(completion) }
            return
        }
        if backoffMs > 0 && timer != nil {
            completion?()
            return
        }
        timer?.cancel()
        timer = nil
        inFlight = true
        if let completion = completion { waiters.append(completion) }
        exchange()
    }

    /// Polls with the current description even if a poll is under way, e.g.
    /// right after a targeting attribute changed.
    func refresh(completion: (() -> Void)? = nil) {
        if inFlight {
            waiters.append { [weak self] in
                guard let self = self else {
                    completion?()
                    return
                }
                self.poll(completion: completion)
            }
            return
        }
        poll(completion: completion)
    }

    private func finishExchange() {
        inFlight = false
        let done = waiters
        waiters = []
        for waiter in done { waiter() }
    }

    private func schedule(_ delayMs: Int64) {
        guard !stopped else { return }
        timer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.timer = nil
            self.poll()
        }
        timer = work
        queue.asyncAfter(deadline: .now() + .milliseconds(Int(max(0, delayMs))), execute: work)
    }

    private func exchange() {
        let message = AgentToServer(
            instanceUid: uid,
            sequenceNum: sequenceNum,
            agentDescription: describe(),
            capabilities: capabilities,
            remoteConfigStatus: status,
            customCapabilities: customCapabilities
        )
        sequenceNum += 1
        let body = Data(encodeAgentToServer(message))
        var requestHeaders = headers
        requestHeaders["Content-Type"] = "application/x-protobuf"
        requestHeaders["OpAMP-Instance-UID"] = Ids.uuidString(uid)

        // The transport's own timeout should end the request; this one makes
        // sure a transport that never answers cannot stall polling.
        var answered = false
        let answer: (HTTPResult) -> Void = { [weak self] result in
            guard let self = self, !answered else { return }
            answered = true
            self.handleResponse(result)
            self.finishExchange()
        }
        queue.asyncAfter(deadline: .now() + requestTimeout + 1) { answer(.noAnswer) }
        transport.post(
            url: endpoint,
            headers: requestHeaders,
            body: body,
            timeout: requestTimeout
        ) { [queue] result in
            queue.async { answer(result) }
        }
    }

    private func handleResponse(_ response: HTTPResult) {
        let code = response.statusCode
        if code == 0 {
            backOff(nil)
            return
        }
        if OpampClient.stopCodes.contains(code) {
            stop()
            onStopped?(code)
            return
        }
        if code == 413 {
            backoffMs = 0
            schedule(intervalMs)
            return
        }
        let message = try? decodeServerToAgent(Array(response.body))
        if code == 429 || code >= 500 || message?.errorResponse?.type == ServerErrorTypes.unavailable {
            backOff(response.retryAfterMs ?? message?.errorResponse?.retryAfterMs)
            return
        }
        guard (200..<300).contains(code), let decoded = message else {
            backOff(nil)
            return
        }
        guard !stopped else { return }
        backoffMs = 0
        handle(decoded)
    }

    private func handle(_ message: ServerToAgent) {
        if let newUid = message.newInstanceUid, newUid.count == 16 {
            uid = newUid
            onInstanceUidChange?(newUid)
        }
        if let heartbeat = message.heartbeatIntervalSeconds, heartbeat > 0 {
            let next = Int64(clamping: heartbeat) &* 1000
            intervalMs = max(next, minIntervalMs)
        }

        var reportNow = false
        if let config = message.remoteConfig,
           !OpampClient.sameBytes(config.configHash, status?.lastRemoteConfigHash) {
            let result = onRemoteConfig(config)
            status = RemoteConfigStatus(
                lastRemoteConfigHash: config.configHash,
                status: result.isApplied ? RemoteConfigStatuses.applied : RemoteConfigStatuses.failed,
                errorMessage: result.errorMessage
            )
            reportNow = true
        }
        // The server answers a poll it cannot evaluate with ReportFullState;
        // this client always sends its full state, so it only needs to poll
        // again. A freshly applied config is reported straight away for the
        // same reason.
        if reportNow || message.flags & serverFlagReportFullState != 0 {
            schedule(0)
            return
        }
        schedule(intervalMs)
    }

    private func backOff(_ retryAfterMs: Int64?) {
        if let requested = retryAfterMs {
            backoffMs = requested
        } else if backoffMs > 0 {
            backoffMs = min(backoffMs * 2, OpampClient.maxBackoffMs)
        } else {
            backoffMs = OpampClient.firstBackoffMs
        }
        schedule(max(backoffMs, 1000))
    }

    private static func sameBytes(_ a: [UInt8]?, _ b: [UInt8]?) -> Bool {
        guard let a = a, let b = b else { return false }
        return a == b
    }
}
