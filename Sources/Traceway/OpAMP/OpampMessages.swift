import Foundation

// The OpAMP messages this SDK sends and reads (opamp-spec opamp.proto), with
// a hand-written codec for the fields it uses. Unknown fields are skipped.

/// AgentCapabilities from the OpAMP spec.
enum AgentCapabilities {
    static let reportsStatus: UInt64 = 0x1
    static let acceptsRemoteConfig: UInt64 = 0x2
    static let reportsRemoteConfig: UInt64 = 0x1000
    static let reportsHeartbeat: UInt64 = 0x2000
}

/// ServerToAgentFlags_ReportFullState.
let serverFlagReportFullState: UInt64 = 0x1

enum RemoteConfigStatuses {
    static let unset: UInt64 = 0
    static let applied: UInt64 = 1
    static let applying: UInt64 = 2
    static let failed: UInt64 = 3
}

enum ServerErrorTypes {
    static let unknown: UInt64 = 0
    static let badRequest: UInt64 = 1
    static let unavailable: UInt64 = 2
}

/// Attributes in the order they were added: the encoding follows it, so a
/// description built the same way always encodes to the same bytes. A
/// dictionary literal keeps its written order; a dictionary is taken in key
/// order.
struct OpampAttributes: ExpressibleByDictionaryLiteral, Equatable {
    private(set) var entries: [(key: String, value: JSON)] = []

    init() {}

    init(dictionaryLiteral elements: (String, JSON)...) {
        for (key, value) in elements { self[key] = value }
    }

    init(_ dictionary: [String: JSON]) {
        for key in dictionary.keys.sorted() { self[key] = dictionary[key] }
    }

    var isEmpty: Bool { entries.isEmpty }
    var count: Int { entries.count }

    /// Setting an existing key keeps its place; nil removes it.
    subscript(key: String) -> JSON? {
        get { entries.first(where: { $0.key == key })?.value }
        set {
            let index = entries.firstIndex(where: { $0.key == key })
            switch (index, newValue) {
            case let (i?, value?): entries[i].value = value
            case let (i?, nil): entries.remove(at: i)
            case let (nil, value?): entries.append((key, value))
            case (nil, nil): break
            }
        }
    }

    static func == (a: OpampAttributes, b: OpampAttributes) -> Bool {
        a.entries.count == b.entries.count
            && zip(a.entries, b.entries).allSatisfy { $0.key == $1.key && $0.value == $1.value }
    }
}

struct AgentDescription: Equatable {
    /// Values are strings, booleans, numbers or arrays of strings.
    var identifying: OpampAttributes
    var nonIdentifying: OpampAttributes
}

struct RemoteConfigStatus: Equatable {
    var lastRemoteConfigHash: [UInt8]
    var status: UInt64
    var errorMessage: String?
}

struct AgentToServer {
    var instanceUid: [UInt8]
    var sequenceNum: UInt64
    var agentDescription: AgentDescription?
    var capabilities: UInt64
    var remoteConfigStatus: RemoteConfigStatus?
    var customCapabilities: [String] = []
}

struct AgentConfigObject: Equatable {
    var body: [UInt8] = []
    var contentType: String = ""
}

struct RemoteConfig: Equatable {
    var configMap: [String: AgentConfigObject] = [:]
    var configHash: [UInt8] = []
}

struct ServerErrorResponse: Equatable {
    var type: UInt64 = ServerErrorTypes.unknown
    var message: String = ""
    var retryAfterMs: Int64?
}

struct ServerToAgent: Equatable {
    var instanceUid: [UInt8]?
    var errorResponse: ServerErrorResponse?
    var remoteConfig: RemoteConfig?
    var heartbeatIntervalSeconds: UInt64?
    var flags: UInt64 = 0
    var capabilities: UInt64 = 0
    var newInstanceUid: [UInt8]?
}

// MARK: - Encoding

private func writeAnyValue(_ w: ProtoWriter, _ value: JSON) {
    switch value {
    case .string(let s):
        w.string(1, s, always: true)
    case .bool(let b):
        w.uint(2, b ? 1 : 0, always: true)
    case .number(let n):
        if n.isFinite, n >= 0, n == n.rounded(), n <= 9_007_199_254_740_992 {
            w.uint(3, UInt64(n), always: true)
        } else {
            w.float64(4, n)
        }
    case .array(let items):
        w.message(5, always: true) { array in
            for item in items {
                array.message(1, always: true) { v in v.string(1, item.text, always: true) }
            }
        }
    case .null, .object:
        w.string(1, value.text, always: true)
    }
}

private func writeAttributes(_ w: ProtoWriter, _ field: Int, _ attrs: OpampAttributes) {
    for (key, value) in attrs.entries {
        w.message(field) { kv in
            kv.string(1, key)
            kv.message(2, always: true) { v in writeAnyValue(v, value) }
        }
    }
}

func encodeAgentToServer(_ msg: AgentToServer) -> [UInt8] {
    let w = ProtoWriter()
    w.bytes(1, msg.instanceUid)
    w.uint(2, msg.sequenceNum)
    if let description = msg.agentDescription {
        // Written even without attributes, as opamp-go marshals a present
        // description.
        w.message(3, always: true) { d in
            writeAttributes(d, 1, description.identifying)
            writeAttributes(d, 2, description.nonIdentifying)
        }
    }
    w.uint(4, msg.capabilities)
    if let status = msg.remoteConfigStatus {
        w.message(7) { s in
            s.bytes(1, status.lastRemoteConfigHash)
            s.uint(2, status.status)
            if let error = status.errorMessage, !error.isEmpty { s.string(3, error) }
        }
    }
    if !msg.customCapabilities.isEmpty {
        w.message(12) { c in
            for capability in msg.customCapabilities { c.string(1, capability) }
        }
    }
    return w.buffer
}

/// Encodes the parts of a ServerToAgent this client reads; for mock servers
/// in tests.
func encodeServerToAgent(
    instanceUid: [UInt8]? = nil,
    remoteConfig: RemoteConfig? = nil,
    heartbeatIntervalSeconds: UInt64? = nil,
    flags: UInt64 = 0,
    capabilities: UInt64 = 0,
    newInstanceUid: [UInt8]? = nil
) -> [UInt8] {
    let w = ProtoWriter()
    if let uid = instanceUid { w.bytes(1, uid) }
    if let config = remoteConfig {
        w.message(3) { rc in
            rc.message(1) { map in
                for key in config.configMap.keys.sorted() {
                    let object = config.configMap[key]!
                    map.message(1) { entry in
                        entry.string(1, key)
                        entry.message(2, always: true) { o in
                            o.bytes(1, object.body)
                            o.string(2, object.contentType)
                        }
                    }
                }
            }
            rc.bytes(2, config.configHash)
        }
    }
    if let heartbeat = heartbeatIntervalSeconds, heartbeat > 0 {
        w.message(4) { cs in cs.message(2) { o in o.uint(4, heartbeat) } }
    }
    w.uint(6, flags)
    w.uint(7, capabilities)
    if let uid = newInstanceUid {
        w.message(8) { id in id.bytes(1, uid) }
    }
    return w.buffer
}

// MARK: - Decoding

private func decodeConfigObject(_ buf: [UInt8]) throws -> AgentConfigObject {
    var object = AgentConfigObject()
    try eachProtoField(buf) { field, wireType, r in
        guard wireType == ProtoWireType.length else { return false }
        switch field {
        case 1: object.body = try r.bytes()
        case 2: object.contentType = try r.string()
        default: return false
        }
        return true
    }
    return object
}

private func decodeRemoteConfig(_ buf: [UInt8]) throws -> RemoteConfig {
    var config = RemoteConfig()
    try eachProtoField(buf) { field, wireType, r in
        guard wireType == ProtoWireType.length else { return false }
        if field == 2 {
            config.configHash = try r.bytes()
            return true
        }
        guard field == 1 else { return false }
        try eachProtoField(try r.bytes()) { mapField, mapWire, mapReader in
            guard mapField == 1, mapWire == ProtoWireType.length else { return false }
            var key = ""
            var value = AgentConfigObject()
            try eachProtoField(try mapReader.bytes()) { entryField, entryWire, entryReader in
                guard entryWire == ProtoWireType.length else { return false }
                switch entryField {
                case 1: key = try entryReader.string()
                case 2: value = try decodeConfigObject(try entryReader.bytes())
                default: return false
                }
                return true
            }
            config.configMap[key] = value
            return true
        }
        return true
    }
    return config
}

/// Throws `ProtoFormatError` for a message that is cut off or malformed.
func decodeServerToAgent(_ buf: [UInt8]) throws -> ServerToAgent {
    var msg = ServerToAgent()
    try eachProtoField(buf) { field, wireType, r in
        switch field {
        case 1:
            guard wireType == ProtoWireType.length else { return false }
            msg.instanceUid = try r.bytes()
            return true
        case 2:
            guard wireType == ProtoWireType.length else { return false }
            var error = ServerErrorResponse()
            try eachProtoField(try r.bytes()) { f, w, er in
                if f == 1 && w == ProtoWireType.varint {
                    error.type = try er.varint()
                } else if f == 2 && w == ProtoWireType.length {
                    error.message = try er.string()
                } else if f == 3 && w == ProtoWireType.length {
                    try eachProtoField(try er.bytes()) { rf, rw, rr in
                        guard rf == 1, rw == ProtoWireType.varint else { return false }
                        error.retryAfterMs = Int64(clamping: try rr.varint() / 1_000_000)
                        return true
                    }
                } else {
                    return false
                }
                return true
            }
            msg.errorResponse = error
            return true
        case 3:
            guard wireType == ProtoWireType.length else { return false }
            msg.remoteConfig = try decodeRemoteConfig(try r.bytes())
            return true
        case 4:
            guard wireType == ProtoWireType.length else { return false }
            try eachProtoField(try r.bytes()) { f, w, cr in
                guard f == 2, w == ProtoWireType.length else { return false }
                try eachProtoField(try cr.bytes()) { of, ow, or in
                    guard of == 4, ow == ProtoWireType.varint else { return false }
                    msg.heartbeatIntervalSeconds = try or.varint()
                    return true
                }
                return true
            }
            return true
        case 6:
            guard wireType == ProtoWireType.varint else { return false }
            msg.flags = try r.varint()
            return true
        case 7:
            guard wireType == ProtoWireType.varint else { return false }
            msg.capabilities = try r.varint()
            return true
        case 8:
            guard wireType == ProtoWireType.length else { return false }
            try eachProtoField(try r.bytes()) { f, w, ir in
                guard f == 1, w == ProtoWireType.length else { return false }
                msg.newInstanceUid = try ir.bytes()
                return true
            }
            return true
        default:
            return false
        }
    }
    return msg
}
