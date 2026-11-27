import Foundation

/// The coarse device facts the server keeps as metric dimensions
/// (`backend/app/clientmetrics/dims.go`), as resource attributes:
/// `device.form_factor` (phone, tablet, desktop) and `device.class` (low,
/// mid, high). `os.major` comes from the device information. Nothing that
/// identifies a device.
enum DeviceDimensions {
    static func collect() -> [String: String] {
        var out: [String: String] = [:]
        if let deviceClass = deviceClass(totalBytes: Int64(clamping: ProcessInfo.processInfo.physicalMemory)) {
            out["device.class"] = deviceClass
        }
        if runsOnMac { out["device.form_factor"] = "desktop" }
        return out
    }

    /// From the RAM the system reports, a little under the nominal size, as
    /// the Android and Flutter SDKs do.
    static func deviceClass(totalBytes: Int64) -> String? {
        guard totalBytes > 0 else { return nil }
        let gb = Double(totalBytes) / (1024 * 1024 * 1024)
        return gb < 3 ? "low" : gb < 6 ? "mid" : "high"
    }

    /// An iPhone or iPad app running on a Mac (Apple silicon or Catalyst).
    static var runsOnMac: Bool {
        #if targetEnvironment(macCatalyst)
        return true
        #elseif os(iOS)
        if #available(iOS 14.0, *) { return ProcessInfo.processInfo.isiOSAppOnMac }
        return false
        #else
        return false
        #endif
    }
}
