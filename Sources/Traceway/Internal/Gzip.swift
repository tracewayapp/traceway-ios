import Foundation
#if canImport(zlib)
import zlib

enum Gzip {

    static func compress(_ data: Data) -> Data? {
        deflate(data, windowBits: 15 + 16, level: Z_DEFAULT_COMPRESSION)
    }

    /// The zlib stream (RFC 1950) of `data`, as PNG image data holds it.
    static func zlibStream(_ data: Data) -> Data? {
        deflate(data, windowBits: 15, level: 9)
    }

    /// CRC-32 of `bytes`, as gzip and PNG use it.
    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        bytes.withUnsafeBufferPointer { buffer in
            UInt32(zlib.crc32(0, buffer.baseAddress, uInt(buffer.count)))
        }
    }

    private static func deflate(_ data: Data, windowBits: Int32, level: Int32) -> Data? {
        var stream = z_stream()
        let memLevel: Int32 = 8

        let initStatus = deflateInit2_(
            &stream,
            level,
            Z_DEFLATED,
            windowBits,
            memLevel,
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initStatus == Z_OK else { return nil }
        defer { deflateEnd(&stream) }

        var input = [UInt8](data)
        var output = Data()
        let chunkSize = 16_384
        var outBuffer = [UInt8](repeating: 0, count: chunkSize)

        return input.withUnsafeMutableBufferPointer { inPtr -> Data? in
            stream.next_in = inPtr.baseAddress
            stream.avail_in = uInt(inPtr.count)

            while true {
                let status: Int32 = outBuffer.withUnsafeMutableBufferPointer { outPtr in
                    stream.next_out = outPtr.baseAddress
                    stream.avail_out = uInt(outPtr.count)
                    let s = zlib.deflate(&stream, Z_FINISH)
                    let produced = outPtr.count - Int(stream.avail_out)
                    if produced > 0, let base = outPtr.baseAddress {
                        output.append(base, count: produced)
                    }
                    return s
                }
                if status == Z_STREAM_END { break }
                if status < 0 { return nil }
            }
            return output
        }
    }

    static func decompress(_ data: Data) -> Data? {
        guard !data.isEmpty else { return Data() }
        var stream = z_stream()
        let windowBits: Int32 = 15 + 32

        let initStatus = inflateInit2_(
            &stream,
            windowBits,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initStatus == Z_OK else { return nil }
        defer { inflateEnd(&stream) }

        var input = [UInt8](data)
        var output = Data()
        let chunkSize = 16_384
        var outBuffer = [UInt8](repeating: 0, count: chunkSize)

        return input.withUnsafeMutableBufferPointer { inPtr -> Data? in
            stream.next_in = inPtr.baseAddress
            stream.avail_in = uInt(inPtr.count)

            while true {
                let status: Int32 = outBuffer.withUnsafeMutableBufferPointer { outPtr in
                    stream.next_out = outPtr.baseAddress
                    stream.avail_out = uInt(outPtr.count)
                    let s = inflate(&stream, Z_NO_FLUSH)
                    let produced = outPtr.count - Int(stream.avail_out)
                    if produced > 0, let base = outPtr.baseAddress {
                        output.append(base, count: produced)
                    }
                    return s
                }
                if status == Z_STREAM_END { break }
                if status < 0 { return nil }
                if status == Z_OK, stream.avail_in == 0 { break }
            }
            return output
        }
    }
}
#else
/// Without zlib (Linux test hosts) bodies are sent uncompressed.
enum Gzip {
    static func compress(_ data: Data) -> Data? { nil }
    static func decompress(_ data: Data) -> Data? { nil }
    /// Stored (uncompressed) deflate blocks in a zlib stream: valid, only
    /// bigger.
    static func zlibStream(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        var out: [UInt8] = [0x78, 0x01]
        var at = 0
        repeat {
            let n = min(65_535, bytes.count - at)
            let last: UInt8 = at + n >= bytes.count ? 1 : 0
            out += [last, UInt8(n & 0xff), UInt8(n >> 8), UInt8(~n & 0xff), UInt8((~n >> 8) & 0xff)]
            out += bytes[at..<(at + n)]
            at += n
        } while at < bytes.count
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in bytes {
            a = (a + UInt32(byte)) % 65_521
            b = (b + a) % 65_521
        }
        let adler = b << 16 | a
        out += [UInt8(adler >> 24), UInt8((adler >> 16) & 0xff), UInt8((adler >> 8) & 0xff), UInt8(adler & 0xff)]
        return Data(out)
    }

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in bytes {
            c ^= UInt32(b)
            for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        }
        return c ^ 0xFFFF_FFFF
    }
}
#endif
