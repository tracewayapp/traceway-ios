import Foundation
#if canImport(Darwin)
import Darwin
#endif
#if canImport(MachO)
import MachO
#endif

enum BinaryImages {

    struct LoadedImage {
        let loadAddr: UInt
        let size: UInt
        let uuid: String
        let name: String
    }

    private static var snapshot: [LoadedImage]?

    static func capture() -> [LoadedImage] {
        if let snapshot = snapshot { return snapshot }
        var images: [LoadedImage] = []
        #if canImport(Darwin)
        let count = _dyld_image_count()
        for i in 0..<count {
            guard let header = _dyld_get_image_header(i) else { continue }
            let loadAddr = UInt(bitPattern: header)
            var uuid = ""
            var textSize: UInt = 0
            readHeader(header, uuid: &uuid, textVMSize: &textSize)
            if uuid.isEmpty { continue }
            let name = imageName(_dyld_get_image_name(i))
            images.append(LoadedImage(loadAddr: loadAddr, size: textSize, uuid: uuid, name: name))
        }
        #endif
        snapshot = images
        return images
    }

    static func currentArch() -> String {
        #if canImport(Darwin)
        if let header = _dyld_get_image_header(0) {
            let mh = UnsafeRawPointer(header).assumingMemoryBound(to: mach_header_64.self)
            switch mh.pointee.cputype {
            case CPU_TYPE_ARM64: return "arm64"
            case CPU_TYPE_X86_64: return "x64"
            case CPU_TYPE_ARM: return "arm"
            case CPU_TYPE_X86: return "ia32"
            default: break
            }
        }
        #endif
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x64"
        #else
        return ""
        #endif
    }

    static func encodeBlob(_ images: [LoadedImage]) -> [UInt8] {
        var text = ""
        for img in images {
            text += String(img.loadAddr, radix: 16)
            text += " "
            text += String(img.size, radix: 16)
            text += " "
            text += img.uuid
            text += " "
            text += img.name.replacingOccurrences(of: "\n", with: " ")
            text += "\n"
        }
        return Array(text.utf8)
    }

    static func parseImageLine(_ line: Substring) -> LoadedImage? {
        let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
        guard parts.count >= 3,
              let loadAddr = UInt(parts[0], radix: 16),
              let size = UInt(parts[1], radix: 16)
        else { return nil }
        let name = parts.count >= 4 ? String(parts[3]) : ""
        return LoadedImage(loadAddr: loadAddr, size: size, uuid: String(parts[2]), name: name)
    }

    static func map(address: UInt, images: [LoadedImage]) -> (image: LoadedImage, offset: UInt)? {
        for img in images {
            if address >= img.loadAddr && address < img.loadAddr &+ img.size {
                return (img, address &- img.loadAddr)
            }
        }
        return nil
    }

    #if canImport(Darwin)
    private static let lcSegment64: UInt32 = 0x19
    private static let lcUUID: UInt32 = 0x1b

    private static func readHeader(
        _ header: UnsafePointer<mach_header>, uuid: inout String, textVMSize: inout UInt
    ) {
        let mh = UnsafeRawPointer(header).assumingMemoryBound(to: mach_header_64.self)
        let ncmds = mh.pointee.ncmds
        var cmd = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
        for _ in 0..<ncmds {
            let lc = cmd.assumingMemoryBound(to: load_command.self).pointee
            if lc.cmdsize == 0 { break }
            switch lc.cmd {
            case lcSegment64:
                let seg = cmd.assumingMemoryBound(to: segment_command_64.self)
                if segmentName(seg.pointee.segname) == "__TEXT" {
                    textVMSize = UInt(seg.pointee.vmsize)
                }
            case lcUUID:
                let uc = cmd.assumingMemoryBound(to: uuid_command.self)
                uuid = uuidHex(uc.pointee.uuid)
            default:
                break
            }
            cmd = cmd.advanced(by: Int(lc.cmdsize))
        }
    }

    private static func segmentName(_ tuple: (Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8)) -> String {
        var bytes = tuple
        return withUnsafeBytes(of: &bytes) { raw in
            let buf = raw.bindMemory(to: UInt8.self)
            var s = ""
            for b in buf {
                if b == 0 { break }
                s.append(Character(UnicodeScalar(b)))
            }
            return s
        }
    }

    private static func uuidHex(_ tuple: uuid_t) -> String {
        var bytes = tuple
        return withUnsafeBytes(of: &bytes) { raw in
            let buf = raw.bindMemory(to: UInt8.self)
            var s = ""
            s.reserveCapacity(32)
            for b in buf {
                s += String(format: "%02x", b)
            }
            return s
        }
    }
    #endif

    private static func imageName(_ cstr: UnsafePointer<CChar>?) -> String {
        guard let cstr = cstr else { return "<unknown>" }
        let full = String(cString: cstr)
        return (full as NSString).lastPathComponent
    }
}
