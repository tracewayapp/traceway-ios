import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// How the wireframe inlines a picture, the same on every Traceway SDK
/// that does (CONTRACT §14.5): the bitmap an image view shows (never a
/// screenshot of the window), downscaled to its displayed size at one pixel
/// per point with the longest side at most 384 pixels, encoded as JPEG at
/// quality 0.45 (PNG when it has see-through pixels and is at most 96
/// pixels), and dropped when it still takes more than 48 KiB at half that
/// size. Each picture is a CSS rule in a style node of its own:
/// `.im.p<N>{background:url(data:…) center/cover no-repeat}`; the node
/// showing it gets the classes `im p<N>` and an inline size and position for
/// its content mode.
enum WireframeImageEncoding {
    static let pixelsPerPoint = 1.0
    static let maxSide = 384
    static let maxPNGSide = 96
    static let jpegQuality = 0.45
    static let maxEncodedBytes = 48 * 1024
    /// Pictures one capture holds at most; a new one past it evicts the one
    /// shown longest ago.
    static let maxPictures = 128

    /// Which picture a new one replaces when `lastShownMs.count` pictures
    /// are held: none below `maxPictures`; else the one shown longest ago,
    /// but never one the frame being captured (`nowMs`) shows. Nil when
    /// there is room, or when every picture is on this frame.
    static func evictionIndex(lastShownMs: [Int64], nowMs: Int64, maxPictures: Int = maxPictures) -> Int? {
        guard lastShownMs.count >= maxPictures else { return nil }
        var oldest: Int?
        for (index, shown) in lastShownMs.enumerated() where shown < nowMs {
            if let current = oldest, lastShownMs[current] <= shown { continue }
            oldest = index
        }
        return oldest
    }

    /// The pixel size a picture shown at `displayed` points is encoded at:
    /// one pixel per point, never more pixels than the bitmap has, the
    /// longest side at most 384. Nil when there is nothing to draw.
    static func pixelSize(
        displayed: (width: Double, height: Double),
        source: (width: Double, height: Double)
    ) -> (width: Int, height: Int)? {
        guard displayed.width.isFinite, displayed.height.isFinite, displayed.width > 0, displayed.height > 0
        else { return nil }
        var w = displayed.width * pixelsPerPoint
        var h = displayed.height * pixelsPerPoint
        if source.width > 0, source.height > 0, w > source.width || h > source.height {
            let scale = min(source.width / w, source.height / h)
            w *= scale
            h *= scale
        }
        let longest = max(w, h)
        if longest > Double(maxSide) {
            let scale = Double(maxSide) / longest
            w *= scale
            h *= scale
        }
        return (max(1, Int(w.rounded())), max(1, Int(h.rounded())))
    }

    /// PNG keeps see-through pixels, at a size where that is cheap.
    static func usesPNG(hasAlpha: Bool, width: Int, height: Int) -> Bool {
        hasAlpha && max(width, height) <= maxPNGSide
    }

    /// The half size an encoding that came out too large is tried again at.
    static func retrySize(_ size: (width: Int, height: Int)) -> (width: Int, height: Int)? {
        guard size.width > 1 || size.height > 1 else { return nil }
        return (max(1, size.width / 2), max(1, size.height / 2))
    }

    /// The rule that draws picture `cls` over the `.im` placeholder.
    static func rule(cls: String, mime: String, data: Data) -> String {
        ".im.\(cls){background:url(data:\(mime);base64,\(data.base64EncodedString())) center/cover no-repeat}"
    }

    /// Where the picture sits in its node for a content mode: the rule's
    /// `center/cover` for aspect fill, `contain` for aspect fit, stretched
    /// for scale to fill, and at its own size elsewhere.
    static func placementCss(
        _ placement: ImagePlacement,
        image: (width: Double, height: Double),
        box: (width: Double, height: Double)
    ) -> String {
        switch placement {
        case .aspectFill:
            return ""
        case .aspectFit:
            return "background-size:contain;"
        case .fill:
            return "background-size:100% 100%;"
        default:
            let r = placement.rect(image: image, box: box)
            return "background-size:\(WireframeCSS.px(r.width)) \(WireframeCSS.px(r.height));"
                + "background-position:\(WireframeCSS.px(r.x)) \(WireframeCSS.px(r.y));"
        }
    }
}

#if canImport(UIKit)
/// The pictures the app's image views and image layers show, encoded for
/// the replay (see `WireframeImageEncoding`). A picture is looked up by its
/// bitmap and the size it is shown at, so the same photo in many cells is
/// encoded and sent once. Encoding runs off the main thread: the frame that
/// first shows a picture draws the placeholder, a later one the picture.
/// At most `maxPictures` are held; a new one past that evicts the one shown
/// longest ago (its style leaves the page; it is encoded again if it comes
/// back), never one the current frame shows. Every encoded byte counts against the session's image
/// allowance in `budget`; past it, and when a new session starts, pictures
/// are encoded (and counted) again or stay placeholders. Main thread only.
final class WireframeImages {
    final class Picture {
        let cls: String
        /// The rule that draws it once encoded; nil while it is encoded,
        /// or for good when it was too large or over the allowance.
        var css: String?
        /// The style node holding `css` in the replay.
        var styleId: Int?
        /// When a frame last showed it.
        var lastShownMs: Int64 = 0
        fileprivate var evicted = false

        init(cls: String) { self.cls = cls }
    }

    static let maxPictures = WireframeImageEncoding.maxPictures
    /// Encodes waiting or under way. Each holds its full-size bitmap until
    /// it runs, which the app may have let go already: a picture beyond
    /// this is a placeholder for now and is encoded once there is room.
    static let maxPendingEncodes = 4
    /// How long a picture's rule stays on the page after it left the
    /// screen, so a picture that comes back does not send it again.
    static let lingerMs: Int64 = 30_000

    /// Counts the encoded bytes per session; nil counts nothing.
    var budget: CollectionBudget?
    private(set) var all: [Picture] = []
    private var next = 0
    private var session: String?
    private(set) var pendingEncodes = 0
    private let byImage = NSMapTable<UIImage, Sizes>.weakToStrongObjects()
    private let byLayer = NSMapTable<CALayer, LayerPicture>.weakToStrongObjects()
    private let encoder = DispatchQueue(label: "app.traceway.images", qos: .utility)

    private final class Sizes {
        var bySize: [String: Picture] = [:]
    }

    private final class LayerPicture {
        let contents: ObjectIdentifier
        let size: String
        let picture: Picture

        init(contents: ObjectIdentifier, size: String, picture: Picture) {
            self.contents = contents
            self.size = size
            self.picture = picture
        }
    }

    /// The picture of `image` shown at `displayed` points (the size its
    /// content mode draws it at), encoded now if it is new; nil when no
    /// more pictures fit.
    func picture(_ image: UIImage, displayed: CGSize, nowMs: Int64) -> Picture? {
        followSession()
        let key = WireframeImages.sizeKey(displayed)
        let sizes: Sizes
        if let existing = byImage.object(forKey: image) {
            sizes = existing
        } else {
            sizes = Sizes()
            byImage.setObject(sizes, forKey: image)
        }
        if let known = sizes.bySize[key], !known.evicted {
            known.lastShownMs = nowMs
            return known
        }
        guard pendingEncodes < WireframeImages.maxPendingEncodes, let picture = add(nowMs) else { return nil }
        sizes.bySize[key] = picture
        encode(image, hasAlpha: image.cgImage.map(WireframeImages.hasAlpha) ?? false,
               source: (Double(image.size.width * image.scale), Double(image.size.height * image.scale)),
               displayed: displayed, into: picture)
        return picture
    }

    /// The picture a layer shows as its contents, at `displayed` points.
    func picture(_ layer: CALayer, contents: CGImage, displayed: CGSize, nowMs: Int64) -> Picture? {
        followSession()
        let key = WireframeImages.sizeKey(displayed)
        if let known = byLayer.object(forKey: layer), known.contents == ObjectIdentifier(contents),
           known.size == key, !known.picture.evicted {
            known.picture.lastShownMs = nowMs
            return known.picture
        }
        guard pendingEncodes < WireframeImages.maxPendingEncodes, let picture = add(nowMs) else { return nil }
        // The layer holds its contents, so their identifier is not reused
        // while the entry stands for them.
        byLayer.setObject(LayerPicture(contents: ObjectIdentifier(contents), size: key, picture: picture), forKey: layer)
        encode(UIImage(cgImage: contents), hasAlpha: WireframeImages.hasAlpha(contents),
               source: (Double(contents.width), Double(contents.height)), displayed: displayed, into: picture)
        return picture
    }

    private static func sizeKey(_ size: CGSize) -> String {
        "\(Int(saturating: Double(size.width * 10).rounded()))x\(Int(saturating: Double(size.height * 10).rounded()))"
    }

    private static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }

    /// A new session counts its own image bytes: pictures encoded for the
    /// last one are encoded again when shown.
    private func followSession() {
        guard let budget = budget else { return }
        let current = budget.currentSession
        guard current != session else { return }
        session = current
        for picture in all { picture.evicted = true }
        all.removeAll()
    }

    private func add(_ nowMs: Int64) -> Picture? {
        if all.count >= WireframeImages.maxPictures {
            guard let oldest = WireframeImageEncoding.evictionIndex(
                lastShownMs: all.map { $0.lastShownMs }, nowMs: nowMs, maxPictures: WireframeImages.maxPictures
            ), oldest < all.count else { return nil }
            all[oldest].evicted = true
            all.remove(at: oldest)
        }
        let picture = Picture(cls: "p\(next)")
        next += 1
        picture.lastShownMs = nowMs
        all.append(picture)
        return picture
    }

    private func encode(
        _ image: UIImage, hasAlpha: Bool, source: (width: Double, height: Double), displayed: CGSize,
        into picture: Picture
    ) {
        guard let size = WireframeImageEncoding.pixelSize(
            displayed: (Double(displayed.width), Double(displayed.height)), source: source
        ) else { return }
        // Formats read the screen; they are made here, on the main thread.
        let opaque = WireframeImages.format(opaque: true)
        let clear = WireframeImages.format(opaque: false)
        let cls = picture.cls
        pendingEncodes += 1
        encoder.async { [weak self] in
            let encoded = WireframeImages.encoded(image, size: size, hasAlpha: hasAlpha, opaque: opaque, clear: clear)
            DispatchQueue.main.async {
                self?.pendingEncodes -= 1
                guard let encoded = encoded, !picture.evicted else { return }
                if let budget = self?.budget, !budget.admitImage(bytes: encoded.data.count) { return }
                picture.css = WireframeImageEncoding.rule(cls: cls, mime: encoded.mime, data: encoded.data)
            }
        }
    }

    private static func format(opaque: Bool) -> UIGraphicsImageRendererFormat {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = opaque
        return format
    }

    /// The picture as JPEG or PNG data, at `size` or else at half of it;
    /// nil when both are too large.
    private static func encoded(
        _ image: UIImage, size: (width: Int, height: Int), hasAlpha: Bool,
        opaque: UIGraphicsImageRendererFormat, clear: UIGraphicsImageRendererFormat
    ) -> (mime: String, data: Data)? {
        var attempt: (width: Int, height: Int)? = size
        for _ in 0..<2 {
            guard let current = attempt else { return nil }
            let png = WireframeImageEncoding.usesPNG(hasAlpha: hasAlpha, width: current.width, height: current.height)
            let rect = CGRect(x: 0, y: 0, width: current.width, height: current.height)
            let renderer = UIGraphicsImageRenderer(size: rect.size, format: png ? clear : opaque)
            // Only the image is drawn, never anything around it.
            let data: Data
            if png {
                data = renderer.pngData { _ in image.draw(in: rect) }
            } else {
                data = renderer.jpegData(withCompressionQuality: CGFloat(WireframeImageEncoding.jpegQuality)) { context in
                    if hasAlpha {
                        UIColor.white.setFill()
                        context.fill(rect)
                    }
                    image.draw(in: rect)
                }
            }
            if data.count <= WireframeImageEncoding.maxEncodedBytes {
                return (png ? "image/png" : "image/jpeg", data)
            }
            attempt = WireframeImageEncoding.retrySize(current)
        }
        return nil
    }
}
#endif
