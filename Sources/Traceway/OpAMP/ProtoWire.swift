import Foundation

// The protobuf wire format, only as much as OpAMP needs: varints,
// length-delimited fields and fixed 64-bit doubles.

enum ProtoWireType {
    static let varint = 0
    static let fixed64 = 1
    static let length = 2
    static let fixed32 = 5
}

struct ProtoFormatError: Error, CustomStringConvertible {
    let description: String
}

final class ProtoWriter {
    private(set) var buffer: [UInt8] = []

    func varint(_ value: UInt64) {
        var v = value
        while v >= 0x80 {
            buffer.append(UInt8(v & 0x7f) | 0x80)
            v >>= 7
        }
        buffer.append(UInt8(v))
    }

    func tag(_ field: Int, _ wireType: Int) {
        varint(UInt64(field) << 3 | UInt64(wireType))
    }

    /// Writes a varint field; zero is the proto3 default and is omitted unless
    /// `always` is set (needed inside a oneof, where presence matters).
    func uint(_ field: Int, _ value: UInt64, always: Bool = false) {
        if value == 0 && !always { return }
        tag(field, ProtoWireType.varint)
        varint(value)
    }

    func bytes(_ field: Int, _ value: [UInt8]) {
        if value.isEmpty { return }
        tag(field, ProtoWireType.length)
        varint(UInt64(value.count))
        buffer.append(contentsOf: value)
    }

    func string(_ field: Int, _ value: String, always: Bool = false) {
        let encoded = Array(value.utf8)
        if encoded.isEmpty && always {
            tag(field, ProtoWireType.length)
            varint(0)
            return
        }
        bytes(field, encoded)
    }

    func float64(_ field: Int, _ value: Double) {
        tag(field, ProtoWireType.fixed64)
        var bits = value.bitPattern.littleEndian
        withUnsafeBytes(of: &bits) { buffer.append(contentsOf: $0) }
    }

    /// Writes a nested message. An empty message is still written when
    /// `always` is set.
    func message(_ field: Int, always: Bool = false, _ build: (ProtoWriter) -> Void) {
        let inner = ProtoWriter()
        build(inner)
        let encoded = inner.buffer
        if encoded.isEmpty && !always { return }
        tag(field, ProtoWireType.length)
        varint(UInt64(encoded.count))
        buffer.append(contentsOf: encoded)
    }
}

final class ProtoReader {
    private let buf: [UInt8]
    private var pos: Int

    init(_ buf: [UInt8]) {
        self.buf = buf
        pos = 0
    }

    var done: Bool { pos >= buf.count }

    func varint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard pos < buf.count else { throw ProtoFormatError(description: "truncated varint") }
            let byte = buf[pos]
            pos += 1
            if shift < 64 { result |= UInt64(byte & 0x7f) << shift }
            if byte < 0x80 { return result }
            shift += 7
            if shift >= 70 { throw ProtoFormatError(description: "varint too long") }
        }
    }

    func tag() throws -> (field: Int, wireType: Int) {
        let value = try varint()
        return (Int(truncatingIfNeeded: value >> 3), Int(value & 7))
    }

    func bytes() throws -> [UInt8] {
        let length = try varint()
        guard length <= UInt64(buf.count - pos) else {
            throw ProtoFormatError(description: "truncated field")
        }
        let end = pos + Int(length)
        let out = Array(buf[pos..<end])
        pos = end
        return out
    }

    func string() throws -> String {
        String(decoding: try bytes(), as: UTF8.self)
    }

    func skip(_ wireType: Int) throws {
        switch wireType {
        case ProtoWireType.varint: _ = try varint()
        case ProtoWireType.fixed64: try advance(8)
        case ProtoWireType.length: _ = try bytes()
        case ProtoWireType.fixed32: try advance(4)
        default: throw ProtoFormatError(description: "unsupported wire type \(wireType)")
        }
    }

    private func advance(_ length: Int) throws {
        guard pos + length <= buf.count else { throw ProtoFormatError(description: "truncated field") }
        pos += length
    }
}

/// Walks the fields of a message. `handle` returns false for a field it did
/// not consume, which is then skipped.
func eachProtoField(
    _ buf: [UInt8],
    _ handle: (_ field: Int, _ wireType: Int, _ reader: ProtoReader) throws -> Bool
) throws {
    let reader = ProtoReader(buf)
    while !reader.done {
        let (field, wireType) = try reader.tag()
        if try !handle(field, wireType, reader) { try reader.skip(wireType) }
    }
}
