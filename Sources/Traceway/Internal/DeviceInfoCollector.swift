import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(Darwin)
import Darwin
#endif

/// Collects the device/runtime attributes merged into every captured exception.
/// Keys mirror the Android SDK, adapted to iOS. All values are strings.
///
/// `collectSync` is cheap and runs at init; `collectAsync` does the one
/// potentially-slow lookup (the IP address) on a background queue.
enum DeviceInfoCollector {

    /// Canonical attribute order, used so serialized `attributes` are
    /// deterministic across runs (helps golden tests and diffing).
    static let attributeKeyOrder = [
        "os.name", "os.version", "device.model", "device.manufacturer",
        "device.brand", "device.systemVersion", "device.isPhysical",
        "device.locale", "runtime.version", "screen.resolution",
        "screen.density", "device.ip",
    ]

    static func collectSync() -> [String: String] {
        var info: [String: String] = [:]
        info["os.name"] = "ios"
        let version = systemVersion()
        info["os.version"] = "iOS \(version)"
        info["device.systemVersion"] = "iOS \(version)"
        info["device.model"] = hardwareModel()
        info["device.manufacturer"] = "Apple"
        info["device.brand"] = "Apple"
        info["device.isPhysical"] = isPhysicalDevice() ? "true" : "false"
        info["device.locale"] = normalizedLocale()
        info["runtime.version"] = swiftRuntimeVersion()

        let screen = screenInfo()
        if let resolution = screen.resolution { info["screen.resolution"] = resolution }
        if let density = screen.density { info["screen.density"] = density }

        return info
    }

    static func collectAsync() -> [String: String] {
        var info: [String: String] = [:]
        if let ip = firstNonLoopbackIPv4() { info["device.ip"] = ip }
        return info
    }

    // MARK: - Pieces

    private static func systemVersion() -> String {
        #if canImport(UIKit)
        return UIDevice.current.systemVersion
        #else
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        #endif
    }

    static func hardwareModel() -> String {
        #if targetEnvironment(simulator)
        if let id = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return id
        }
        #endif
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        guard size > 0 else { return "" }
        var machine = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &machine, &size, nil, 0)
        return String(cString: machine)
    }

    private static func isPhysicalDevice() -> Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return true
        #endif
    }

    private static func normalizedLocale() -> String {
        let identifier = Locale.current.identifier
        if identifier.isEmpty { return "en_US" }
        // Apple already uses underscores; normalize any stray hyphens.
        return identifier.replacingOccurrences(of: "-", with: "_")
    }

    private static func swiftRuntimeVersion() -> String {
        #if swift(>=6.0)
        return "Swift 6"
        #elseif swift(>=5.10)
        return "Swift 5.10"
        #elseif swift(>=5.9)
        return "Swift 5.9"
        #else
        return "Swift"
        #endif
    }

    private static func screenInfo() -> (resolution: String?, density: String?) {
        #if canImport(UIKit)
        let read: () -> (String?, String?) = {
            let screen = UIScreen.main
            let scale = screen.scale
            let bounds = screen.bounds
            let width = Int((bounds.width * scale).rounded())
            let height = Int((bounds.height * scale).rounded())
            return ("\(width)x\(height)", String(format: "%.1f", scale))
        }
        if Thread.isMainThread {
            return read()
        } else {
            return DispatchQueue.main.sync(execute: read)
        }
        #else
        return (nil, nil)
        #endif
    }

    /// First non-loopback IPv4 address across all up interfaces (best-effort).
    private static func firstNonLoopbackIPv4() -> String? {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return nil }
        defer { freeifaddrs(ifaddrPtr) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ptr = cursor {
            let interface = ptr.pointee
            let flags = Int32(interface.ifa_flags)
            if let addr = interface.ifa_addr,
               (flags & IFF_UP) == IFF_UP,
               (flags & IFF_LOOPBACK) == 0,
               addr.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let result = getnameinfo(
                    addr,
                    socklen_t(addr.pointee.sa_len),
                    &host, socklen_t(host.count),
                    nil, 0,
                    NI_NUMERICHOST
                )
                if result == 0 {
                    let ip = String(cString: host)
                    if !ip.isEmpty, ip != "127.0.0.1" {
                        return ip
                    }
                }
            }
            cursor = interface.ifa_next
        }
        return nil
    }
}
