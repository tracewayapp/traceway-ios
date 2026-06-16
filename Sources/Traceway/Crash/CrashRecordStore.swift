import Foundation
#if canImport(Darwin)
import Darwin
#endif

enum CrashRecordStore {

    static let directoryName = "traceway_crashes"
    private static let magic = "TRACEWAY_SIGNAL_V1"
    private static let framesMarker = "---FRAMES---"
    private static let imagesMarker = "---IMAGES---"

    static func directory(base: URL) -> URL {
        base.appendingPathComponent(directoryName)
    }

    static func crashFilePath(dir: URL) -> String {
        dir.appendingPathComponent("crash-\(getpid()).tw").path
    }

    static func buildMetadata(attributes: [String: String], appVersion: String) -> [UInt8] {
        var text = "appVersion=\(sanitize(appVersion))\n"
        var emitted = Set<String>()
        for key in DeviceInfoCollector.attributeKeyOrder {
            if let value = attributes[key] {
                text += "attr.\(key)=\(sanitize(value))\n"
                emitted.insert(key)
            }
        }
        for (key, value) in attributes where !emitted.contains(key) {
            text += "attr.\(key)=\(sanitize(value))\n"
        }
        return Array(text.utf8)
    }

    static func buildImagesSection(arch: String, images: [BinaryImages.LoadedImage]) -> [UInt8] {
        var bytes = Array("arch=\(sanitize(arch))\n\(imagesMarker)\n".utf8)
        bytes.append(contentsOf: BinaryImages.encodeBlob(images))
        return bytes
    }

    static func convertPending(dir: URL) -> [ExceptionStackTrace] {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return [] }

        var result: [ExceptionStackTrace] = []
        for file in files where file.pathExtension == "tw" {
            if let record = parse(file: file) {
                result.append(record)
            }
            try? fileManager.removeItem(at: file)
        }
        return result
    }

    static func parse(file: URL) -> ExceptionStackTrace? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        return parse(text: text)
    }

    private enum Section { case header, images, frames }

    static func parse(text: String) -> ExceptionStackTrace? {
        var lines = text.components(separatedBy: "\n")
        guard lines.first == magic else { return nil }
        lines.removeFirst()

        var signo = 0
        var timeSec: Int64 = 0
        var arch = ""
        var attributes: [String: String] = [:]
        var imageLines: [Substring] = []
        var frames: [String] = []
        var section = Section.header

        for line in lines {
            switch section {
            case .frames:
                if !line.isEmpty { frames.append(line) }
            case .images:
                if line == framesMarker { section = .frames }
                else if !line.isEmpty { imageLines.append(Substring(line)) }
            case .header:
                if line == imagesMarker {
                    section = .images
                } else if line == framesMarker {
                    section = .frames
                } else if line.hasPrefix("signal=") {
                    signo = Int(line.dropFirst("signal=".count)) ?? 0
                } else if line.hasPrefix("time=") {
                    timeSec = Int64(line.dropFirst("time=".count)) ?? 0
                } else if line.hasPrefix("arch=") {
                    arch = String(line.dropFirst("arch=".count))
                } else if line.hasPrefix("attr.") {
                    let rest = line.dropFirst("attr.".count)
                    if let eq = rest.firstIndex(of: "=") {
                        let key = String(rest[rest.startIndex..<eq])
                        let value = String(rest[rest.index(after: eq)...])
                        attributes[key] = value
                    }
                }
            }
        }

        let header = "Fatal Signal \(signalName(Int32(signo))) (\(signo))"
        let stackTrace: String
        if imageLines.isEmpty {

            stackTrace = StackTraceFormatter.format(type: header, message: nil, frames: frames)
        } else {
            let images = imageLines.compactMap { BinaryImages.parseImageLine($0) }
            let addresses = frames.compactMap { parseHexAddress($0) }
            stackTrace = renderWireTrace(header: header, arch: arch, images: images, addresses: addresses)
        }
        return ExceptionStackTrace(
            stackTrace: stackTrace,
            recordedAtMs: timeSec > 0 ? timeSec * 1000 : ISO8601.nowMillis(),
            attributes: attributes.isEmpty ? nil : attributes,
            isMessage: false
        )
    }

    static func renderWireTrace(header: String, arch: String, images: [BinaryImages.LoadedImage], addresses: [UInt]) -> String {
        let archToken = arch.isEmpty ? BinaryImages.currentArch() : arch

        var out = header
        out += "\n*** *** *** *** *** *** *** *** *** *** *** *** *** *** *** ***"
        out += "\nos: ios arch: \(archToken)"

        for (index, addr) in addresses.enumerated() {
            let label = String(format: "#%02d", index)
            if let (img, offset) = BinaryImages.map(address: addr, images: images) {
                out += "\n\(label) \(img.uuid) 0x\(String(offset, radix: 16)) \(img.name)"
            } else {
                out += "\n\(label) \(String(repeating: "0", count: 32)) 0x\(String(addr, radix: 16)) <unknown>"
            }
        }
        return out
    }

    private static func parseHexAddress(_ line: String) -> UInt? {
        var s = Substring(line.trimmingCharacters(in: .whitespaces))
        if s.hasPrefix("0x") || s.hasPrefix("0X") { s = s.dropFirst(2) }
        return UInt(s, radix: 16)
    }

    static func signalName(_ signo: Int32) -> String {
        switch signo {
        case SIGABRT: return "SIGABRT"
        case SIGBUS: return "SIGBUS"
        case SIGFPE: return "SIGFPE"
        case SIGILL: return "SIGILL"
        case SIGSEGV: return "SIGSEGV"
        case SIGTRAP: return "SIGTRAP"
        default: return "SIG\(signo)"
        }
    }

    private static func sanitize(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
}
