import Foundation
import zlib

enum Gzip {

    static func compress(_ data: Data) -> Data? {
        var stream = z_stream()
        let windowBits: Int32 = 15 + 16
        let memLevel: Int32 = 8

        let initStatus = deflateInit2_(
            &stream,
            Z_DEFAULT_COMPRESSION,
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
                    let s = deflate(&stream, Z_FINISH)
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
