import XCTest
@testable import Traceway

/// The PNGs icon glyphs are drawn with and where an image sits in its view.
final class WireframeGlyphTests: XCTestCase {
    /// A 3 x 2 bitmap: opaque, half covered and empty pixels.
    private let rgba: [UInt8] = [
        0, 0, 0, 255, 0, 0, 0, 128, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 255, 0, 0, 0, 255,
    ]

    func testTheMaskIsA4BitGrayPNG() throws {
        let png = try XCTUnwrap(MaskPNG.encode(rgba: rgba, width: 3, height: 2))
        let bytes = [UInt8](png)
        XCTAssertEqual(Array(bytes[0..<8]), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        // IHDR: 3 x 2, 4 bits, grayscale.
        XCTAssertEqual(Array(bytes[12..<16]), Array("IHDR".utf8))
        XCTAssertEqual(Array(bytes[16..<24]), [0, 0, 0, 3, 0, 0, 0, 2])
        XCTAssertEqual(bytes[24], 4)
        XCTAssertEqual(bytes[25], 0)
        // The IHDR's CRC is over its type and data.
        let crc = Gzip.crc32(Array(bytes[12..<29]))
        XCTAssertEqual(Array(bytes[29..<33]), [UInt8(crc >> 24), UInt8((crc >> 16) & 0xff), UInt8((crc >> 8) & 0xff), UInt8(crc & 0xff)])
        XCTAssertEqual(Array(bytes.suffix(8).prefix(4)), Array("IEND".utf8))
    }

    func testTheMaskRowsHoldTheCoverage() throws {
        let png = try XCTUnwrap(MaskPNG.encode(rgba: rgba, width: 3, height: 2))
        let bytes = [UInt8](png)
        // The IDAT chunk follows the 25-byte IHDR chunk.
        let length = Int(bytes[33]) << 24 | Int(bytes[34]) << 16 | Int(bytes[35]) << 8 | Int(bytes[36])
        XCTAssertEqual(Array(bytes[37..<41]), Array("IDAT".utf8))
        let stream = Data(bytes[41..<(41 + length)])
        let raw: [UInt8]
        #if canImport(zlib)
        raw = [UInt8](try XCTUnwrap(inflateZlib(stream)))
        #else
        // Stored blocks: a 2-byte header and a 5-byte block header.
        raw = Array([UInt8](stream)[7..<(7 + 6)])
        #endif
        // Each row: no filter, then two pixels a byte (the last padded).
        XCTAssertEqual(raw, [0, 0xF8, 0x00, 0, 0x0F, 0xF0])
    }

    #if canImport(zlib)
    private func inflateZlib(_ data: Data) -> Data? {
        // Gzip.decompress reads zlib streams too (window bits 15 + 32).
        Gzip.decompress(data)
    }
    #endif

    func testTheRuleMasksTheIconSquare() {
        let css = MaskPNG.css(cls: "g3", png: Data([1, 2, 3]))
        XCTAssertEqual(css, ".ic.g3::before{inset:0;border-radius:0;opacity:1;mask:url(data:image/png;base64,AQID) 0 0/100% 100% no-repeat luminance}")
    }

    func testUnusableBitmapsAreNotEncoded() {
        XCTAssertNil(MaskPNG.encode(rgba: rgba, width: 0, height: 2))
        XCTAssertNil(MaskPNG.encode(rgba: rgba, width: 3, height: -1))
        XCTAssertNil(MaskPNG.encode(rgba: Array(rgba.prefix(20)), width: 3, height: 2), "fewer pixels than the size")
        XCTAssertNil(MaskPNG.encodeColor(rgba: [], width: 1, height: 1))
        XCTAssertNil(MaskPNG.encodeColor(rgba: [0, 0, 0, 255], width: 0, height: 0))
        XCTAssertNotNil(MaskPNG.encode(rgba: rgba + [9, 9, 9, 9], width: 3, height: 2), "extra bytes are ignored")
    }

    func testContentModesPlaceTheImage() {
        let image = (width: 20.0, height: 10.0), box = (width: 40.0, height: 40.0)
        XCTAssertEqual(ImagePlacement.fill.rect(image: image, box: box), WireframeRect(x: 0, y: 0, width: 40, height: 40))
        XCTAssertEqual(ImagePlacement.aspectFit.rect(image: image, box: box), WireframeRect(x: 0, y: 10, width: 40, height: 20))
        XCTAssertEqual(ImagePlacement.aspectFill.rect(image: image, box: box), WireframeRect(x: -20, y: 0, width: 80, height: 40))
        XCTAssertEqual(ImagePlacement.center.rect(image: image, box: box), WireframeRect(x: 10, y: 15, width: 20, height: 10))
        XCTAssertEqual(ImagePlacement.bottomRight.rect(image: image, box: box), WireframeRect(x: 20, y: 30, width: 20, height: 10))
        XCTAssertEqual(ImagePlacement.top.rect(image: image, box: box), WireframeRect(x: 10, y: 0, width: 20, height: 10))
    }

    func testTheRemainingContentModesAndAnImageWithoutASize() {
        let image = (width: 20.0, height: 10.0), box = (width: 40.0, height: 40.0)
        XCTAssertEqual(ImagePlacement.left.rect(image: image, box: box), WireframeRect(x: 0, y: 15, width: 20, height: 10))
        XCTAssertEqual(ImagePlacement.right.rect(image: image, box: box), WireframeRect(x: 20, y: 15, width: 20, height: 10))
        XCTAssertEqual(ImagePlacement.bottom.rect(image: image, box: box), WireframeRect(x: 10, y: 30, width: 20, height: 10))
        XCTAssertEqual(ImagePlacement.topLeft.rect(image: image, box: box), WireframeRect(x: 0, y: 0, width: 20, height: 10))
        XCTAssertEqual(ImagePlacement.topRight.rect(image: image, box: box), WireframeRect(x: 20, y: 0, width: 20, height: 10))
        XCTAssertEqual(ImagePlacement.bottomLeft.rect(image: image, box: box), WireframeRect(x: 0, y: 30, width: 20, height: 10))
        // An image larger than its view overflows it, centered.
        XCTAssertEqual(ImagePlacement.center.rect(image: (width: 60, height: 60), box: box),
                       WireframeRect(x: -10, y: -10, width: 60, height: 60))
        // Without a size the image covers the view, whatever the mode.
        XCTAssertEqual(ImagePlacement.center.rect(image: (width: 0, height: 10), box: box),
                       WireframeRect(x: 0, y: 0, width: 40, height: 40))
    }
}

final class WireframeColorGlyphTests: XCTestCase {
    func testOnlyChromaticBitmapsAreColored() {
        // Premultiplied: black, half-covered gray, white.
        XCTAssertFalse(MaskPNG.isColored(rgba: [0, 0, 0, 255, 64, 64, 64, 128, 255, 255, 255, 255]))
        // An orange pixel.
        XCTAssertTrue(MaskPNG.isColored(rgba: [255, 140, 0, 255]))
        // Barely covered pixels do not count.
        XCTAssertFalse(MaskPNG.isColored(rgba: [40, 0, 0, 40]))
    }

    func testTheColorPictureIsAnRGBAPNGWithStraightAlpha() throws {
        let png = [UInt8](try XCTUnwrap(MaskPNG.encodeColor(rgba: [128, 0, 0, 128], width: 1, height: 1)))
        XCTAssertEqual(Array(png[16..<26]), [0, 0, 0, 1, 0, 0, 0, 1, 8, 6])
        #if !canImport(zlib)
        // Stored block: filter byte, then the pixel unpremultiplied.
        XCTAssertEqual(Array(png[41 + 7..<41 + 12]), [0, 255, 0, 0, 128])
        #endif
    }

    func testTheColorRuleDrawsTheSymbolsOwnColors() {
        let css = MaskPNG.colorCss(cls: "g7", png: Data([1, 2, 3]))
        XCTAssertEqual(css, ".ic.g7::before{inset:0;border-radius:0;opacity:1;background:url(data:image/png;base64,AQID) 0 0/100% 100% no-repeat}")
        XCTAssertFalse(css.contains("mask:"), "a colored symbol is not tinted")
    }
}
