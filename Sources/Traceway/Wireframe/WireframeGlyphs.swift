import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// A PNG of how much each pixel of an RGBA bitmap is covered (its alpha),
/// as 4-bit gray: white where the shape is, black where it is not. Used as
/// a luminance mask, so one small picture serves every color the shape
/// takes. The same encoding as the Flutter SDK's icon glyphs.
enum MaskPNG {
    static func encode(rgba: [UInt8], width: Int, height: Int) -> Data? {
        guard width > 0, height > 0, rgba.count >= width * height * 4 else { return nil }
        let rowBytes = (width + 1) / 2
        var raw = [UInt8](repeating: 0, count: height * (rowBytes + 1))
        var o = 0
        for y in 0..<height {
            raw[o] = 0 // no filter
            o += 1
            var x = 0
            while x < width {
                let a = rgba[(y * width + x) * 4 + 3] >> 4
                let b: UInt8 = x + 1 < width ? rgba[(y * width + x + 1) * 4 + 3] >> 4 : 0
                raw[o] = a << 4 | b
                o += 1
                x += 2
            }
        }
        guard let pixels = Gzip.zlibStream(Data(raw)) else { return nil }
        // 4 bits per pixel, grayscale.
        return png(width: width, height: height, colorType: 0, depth: 4, pixels: pixels)
    }

    /// The rule that draws icons of class `cls` with the mask `png`: the
    /// `.ic` square becomes the shape, in the icon's color.
    static func css(cls: String, png: Data) -> String {
        ".ic.\(cls)::before{inset:0;border-radius:0;opacity:1;mask:url(data:image/png;base64,"
            + png.base64EncodedString() + ") 0 0/100% 100% no-repeat luminance}"
    }

    /// The rule that draws icons of class `cls` as the colored picture
    /// `png`, for symbols that carry their own colors.
    static func colorCss(cls: String, png: Data) -> String {
        ".ic.\(cls)::before{inset:0;border-radius:0;opacity:1;background:url(data:image/png;base64,"
            + png.base64EncodedString() + ") 0 0/100% 100% no-repeat}"
    }

    /// An 8-bit RGBA PNG of a bitmap with premultiplied alpha.
    static func encodeColor(rgba: [UInt8], width: Int, height: Int) -> Data? {
        guard width > 0, height > 0, rgba.count >= width * height * 4 else { return nil }
        var raw = [UInt8](repeating: 0, count: height * (width * 4 + 1))
        var o = 0
        for y in 0..<height {
            raw[o] = 0
            o += 1
            for x in 0..<width {
                let i = (y * width + x) * 4
                let a = rgba[i + 3]
                for c in 0..<3 {
                    let v = rgba[i + c]
                    raw[o + c] = a == 0 ? 0 : UInt8(min(255, (Int(v) * 255 + Int(a) / 2) / Int(a)))
                }
                raw[o + 3] = a
                o += 4
            }
        }
        guard let pixels = Gzip.zlibStream(Data(raw)) else { return nil }
        return png(width: width, height: height, colorType: 6, depth: 8, pixels: pixels)
    }

    /// Whether a bitmap (premultiplied RGBA) draws in colors, not one gray:
    /// a symbol with a palette or multicolor rendering. A monochrome symbol
    /// draws in black or the label color, which the view's tint replaces.
    static func isColored(rgba: [UInt8]) -> Bool {
        var i = 0
        while i + 3 < rgba.count {
            let a = Int(rgba[i + 3])
            if a > 64 {
                let r = Int(rgba[i]) * 255 / a, g = Int(rgba[i + 1]) * 255 / a, b = Int(rgba[i + 2]) * 255 / a
                if max(r, g, b) - min(r, g, b) > 40 { return true }
            }
            i += 4
        }
        return false
    }

    private static func png(width: Int, height: Int, colorType: UInt8, depth: UInt8, pixels: Data) -> Data {
        var out: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        func be32(_ v: UInt32) -> [UInt8] {
            [UInt8(v >> 24), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
        }
        func chunk(_ type: String, _ data: [UInt8]) {
            let body = Array(type.utf8) + data
            out += be32(UInt32(data.count)) + body + be32(Gzip.crc32(body))
        }
        chunk("IHDR", be32(UInt32(width)) + be32(UInt32(height)) + [depth, colorType, 0, 0, 0])
        chunk("IDAT", [UInt8](pixels))
        chunk("IEND", [])
        return Data(out)
    }
}

/// How UIKit's content modes place an image of `image` size in a box of
/// `box` size.
enum ImagePlacement: Equatable {
    case fill, aspectFit, aspectFill, center, top, bottom, left, right
    case topLeft, topRight, bottomLeft, bottomRight

    func rect(image: (width: Double, height: Double), box: (width: Double, height: Double)) -> WireframeRect {
        let (iw, ih) = image, (bw, bh) = box
        guard iw > 0, ih > 0 else { return WireframeRect(x: 0, y: 0, width: bw, height: bh) }
        switch self {
        case .fill:
            return WireframeRect(x: 0, y: 0, width: bw, height: bh)
        case .aspectFit, .aspectFill:
            let sx = bw / iw, sy = bh / ih
            let s = self == .aspectFit ? min(sx, sy) : max(sx, sy)
            let w = iw * s, h = ih * s
            return WireframeRect(x: (bw - w) / 2, y: (bh - h) / 2, width: w, height: h)
        default:
            let x: Double
            switch self {
            case .left, .topLeft, .bottomLeft: x = 0
            case .right, .topRight, .bottomRight: x = bw - iw
            default: x = (bw - iw) / 2
            }
            let y: Double
            switch self {
            case .top, .topLeft, .topRight: y = 0
            case .bottom, .bottomLeft, .bottomRight: y = bh - ih
            default: y = (bh - ih) / 2
            }
            return WireframeRect(x: x, y: y, width: iw, height: ih)
        }
    }
}

#if canImport(UIKit)
/// Pictures of the symbols and template images the app shows, so the
/// replay draws each icon's shape instead of a square. An icon's pixels are
/// the system's or the app's artwork, never what a user typed or took: the
/// first time an image shows at a size it is drawn once into a small mask
/// (its coverage only, 1.5 pixels per point), and every frame that shows it
/// carries the mask as a CSS rule. Main thread only.
final class WireframeGlyphs {
    final class Glyph {
        let cls: String
        let css: String?
        /// The style node holding `css` in the replay.
        var styleId: Int?
        /// When a frame last showed it.
        var lastShownMs: Int64 = 0

        init(cls: String, css: String?) {
            self.cls = cls
            self.css = css
        }
    }

    private final class Sizes {
        var bySize: [String: Glyph] = [:]
    }

    let pixelRatio: CGFloat
    let maxGlyphs: Int
    private(set) var all: [Glyph] = []
    private let byImage = NSMapTable<UIImage, Sizes>.weakToStrongObjects()
    private var next = 0

    init(pixelRatio: CGFloat = 1.5, maxGlyphs: Int = 300) {
        self.pixelRatio = pixelRatio
        self.maxGlyphs = maxGlyphs
    }

    /// The glyph of `image` shown in a box of `size` the way `contentMode`
    /// places it, drawn now if it is new; nil once too many were drawn.
    /// With `color`, a symbol that draws in colors of its own (palette,
    /// multicolor, hierarchical, or `.alwaysOriginal`) is kept in them;
    /// otherwise only its shape is, shown in the view's tint.
    func lookup(_ image: UIImage, size: CGSize, contentMode: UIView.ContentMode, color: Bool) -> Glyph? {
        let key = "\(Int((size.width * 10).rounded()))x\(Int((size.height * 10).rounded()))|\(contentMode.rawValue)|\(color)"
        let sizes: Sizes
        if let existing = byImage.object(forKey: image) {
            sizes = existing
        } else {
            sizes = Sizes()
            byImage.setObject(sizes, forKey: image)
        }
        if let glyph = sizes.bySize[key] { return glyph }
        guard all.count < maxGlyphs else { return nil }
        let cls = "g\(next)"
        next += 1
        let glyph = Glyph(cls: cls, css: draw(image, size: size, contentMode: contentMode, color: color, cls: cls))
        sizes.bySize[key] = glyph
        all.append(glyph)
        return glyph
    }

    private var byPicture: [ObjectIdentifier: (picture: CGImage, glyph: Glyph)] = [:]

    /// The glyph of a picture a layer shows (stretched over the layer, the
    /// default `contentsGravity`), shape only; nil once too many were drawn.
    func lookup(_ picture: CGImage, size: CGSize) -> Glyph? {
        let key = ObjectIdentifier(picture)
        if let known = byPicture[key], known.picture === picture { return known.glyph }
        guard all.count < maxGlyphs else { return nil }
        let cls = "g\(next)"
        next += 1
        let glyph = Glyph(cls: cls, css: draw(UIImage(cgImage: picture), size: size, contentMode: .scaleToFill,
                                              color: false, cls: cls))
        // The picture is held, so its identifier is not reused while known.
        byPicture[key] = (picture, glyph)
        all.append(glyph)
        return glyph
    }

    /// How a content mode places an image in its view.
    static func placement(_ mode: UIView.ContentMode) -> ImagePlacement {
        switch mode {
        case .scaleToFill, .redraw: return .fill
        case .scaleAspectFit: return .aspectFit
        case .scaleAspectFill: return .aspectFill
        case .top: return .top
        case .bottom: return .bottom
        case .left: return .left
        case .right: return .right
        case .topLeft: return .topLeft
        case .topRight: return .topRight
        case .bottomLeft: return .bottomLeft
        case .bottomRight: return .bottomRight
        default: return .center
        }
    }

    private func draw(_ image: UIImage, size: CGSize, contentMode: UIView.ContentMode, color: Bool, cls: String) -> String? {
        let w = Int((size.width * pixelRatio).rounded(.up))
        let h = Int((size.height * pixelRatio).rounded(.up))
        guard w > 0, h > 0, w <= 512, h <= 512 else { return nil }
        let place = WireframeGlyphs.placement(contentMode).rect(
            image: (Double(image.size.width), Double(image.size.height)),
            box: (Double(size.width), Double(size.height))
        )
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            // UIKit draws top down.
            context.translateBy(x: 0, y: CGFloat(h))
            context.scaleBy(x: pixelRatio, y: -pixelRatio)
            UIGraphicsPushContext(context)
            image.draw(in: CGRect(x: place.x, y: place.y, width: place.width, height: place.height))
            UIGraphicsPopContext()
            return true
        }
        guard drawn else { return nil }
        if color && (image.renderingMode == .alwaysOriginal || MaskPNG.isColored(rgba: pixels)) {
            return MaskPNG.encodeColor(rgba: pixels, width: w, height: h).map { MaskPNG.colorCss(cls: cls, png: $0) }
        }
        return MaskPNG.encode(rgba: pixels, width: w, height: h).map { MaskPNG.css(cls: cls, png: $0) }
    }
}
#endif
