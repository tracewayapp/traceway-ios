import Foundation

/// Photos and glyphs each occupy a separate rrweb style node. Both full
/// snapshots and mutations serialize its rule in an `_cssText` attribute.
/// Emptying only that rule leaves the base wireframe styles, node IDs,
/// geometry, mask placeholders and interactions intact.
enum WireframeRasterBudget {
    static let maxBytes = 128 * 1024

    static func layoutOnlyIfNeeded(_ events: [JSON]) -> [JSON]? {
        var remaining = maxBytes
        guard events.contains(where: { exceeds($0, remaining: &remaining) }) else { return nil }
        return events.map(withoutRaster)
    }

    private static func exceeds(_ value: JSON, remaining: inout Int) -> Bool {
        switch value {
        case .array(let items):
            return items.contains { exceeds($0, remaining: &remaining) }
        case .object(let fields):
            if let css = fields["_cssText"]?.string {
                let size = rasterBytes(in: css)
                if size > remaining { return true }
                remaining -= size
            }
            return fields.values.contains { exceeds($0, remaining: &remaining) }
        default:
            return false
        }
    }

    private static func withoutRaster(_ value: JSON) -> JSON {
        switch value {
        case .array(let items):
            return .array(items.map(withoutRaster))
        case .object(let fields):
            var layout = fields.mapValues(withoutRaster)
            if let css = fields["_cssText"]?.string, rasterBytes(in: css) > 0 {
                layout["_cssText"] = .string("")
            }
            return .object(layout)
        default:
            return value
        }
    }

    /// Data URL bytes as they appear in the uncompressed recording, including
    /// the media type, base64 prefix and padding. The SDK generates unquoted
    /// JPEG and PNG URLs; their ASCII bytes are unchanged by JSON encoding.
    private static func rasterBytes(in css: String) -> Int {
        var remaining = css[...]
        var bytes = 0
        while let marker = remaining.range(of: "url(data:image/"),
              let end = remaining[marker.upperBound...].firstIndex(of: ")") {
            let start = remaining.index(marker.lowerBound, offsetBy: 4)
            let url = remaining[start..<end]
            if url.hasPrefix("data:image/jpeg;base64,") || url.hasPrefix("data:image/png;base64,") {
                bytes += url.utf8.count
            }
            remaining = remaining[remaining.index(after: end)...]
        }
        return bytes
    }
}
