import Foundation
import XCTest
@testable import Traceway

/// Replay images without UIKit: the policy (setting, option ceiling,
/// network), the encoding rules, the CSS a picture becomes and the
/// per-session allowance. What image views become is in
/// `UIKitWireframeTests`.
final class ReplayImagesTests: XCTestCase {
    // MARK: - Policy

    func testThePoliciesAreOrdered() {
        XCTAssertLessThan(TracewayImagePolicy.off, .wifi)
        XCTAssertLessThan(TracewayImagePolicy.wifi, .always)
        XCTAssertEqual(min(TracewayImagePolicy.always, .wifi), .wifi)
        XCTAssertEqual(TracewayImagePolicy.allCases.map(\.rawValue), ["off", "wifi", "always"])
    }

    func testThePolicyDecidesByTheConnectionAtCaptureTime() {
        XCTAssertFalse(TracewayImagePolicy.off.allowsCapture(unmetered: true))
        XCTAssertTrue(TracewayImagePolicy.wifi.allowsCapture(unmetered: true))
        XCTAssertFalse(TracewayImagePolicy.wifi.allowsCapture(unmetered: false))
        XCTAssertTrue(TracewayImagePolicy.always.allowsCapture(unmetered: false))
        // Cellular, a personal hotspot and Low Data Mode are metered.
        XCTAssertTrue(NetworkState.isUnmetered(satisfied: true, expensive: false, constrained: false))
        XCTAssertFalse(NetworkState.isUnmetered(satisfied: true, expensive: true, constrained: false))
        XCTAssertFalse(NetworkState.isUnmetered(satisfied: true, expensive: false, constrained: true))
        XCTAssertFalse(NetworkState.isUnmetered(satisfied: false, expensive: false, constrained: false))
    }

    func testTheSettingParsesAndKeepsWifiByDefault() throws {
        XCTAssertEqual(defaultSettings().replayImages, .wifi)
        XCTAssertEqual(applyOverlay(defaultSettings(), try parseSettingsDocument(#"{"replay":{"images":"always"}}"#)).replayImages, .always)
        XCTAssertEqual(applyOverlay(defaultSettings(), try parseSettingsDocument(#"{"replay":{"images":"off"}}"#)).replayImages, .off)
        for bad in [#""sometimes""#, "true", "1", #""WIFI""#] {
            let merged = applyOverlay(defaultSettings(), try parseSettingsDocument(#"{"replay":{"images":\#(bad)}}"#))
            XCTAssertEqual(merged.replayImages, .wifi, bad)
        }
    }

    func testTheEffectivePolicyIsTheLowerOfSettingAndOption() throws {
        func effective(option: TracewayImagePolicy, screenCapture: Bool = true, remote: String) throws -> TracewayImagePolicy {
            let control = ControlState(
                defaults: defaultSettings(),
                ceilings: ceilingsFrom(screenCapture: screenCapture, replayImages: option)
            )
            control.applyRemote(try parseSettingsDocument(remote))
            return control.settings.replayImages
        }
        XCTAssertEqual(try effective(option: .always, remote: "{}"), .wifi)
        XCTAssertEqual(try effective(option: .always, remote: #"{"replay":{"images":"always"}}"#), .always)
        XCTAssertEqual(try effective(option: .wifi, remote: #"{"replay":{"images":"always"}}"#), .wifi)
        XCTAssertEqual(try effective(option: .off, remote: #"{"replay":{"images":"always"}}"#), .off)
        XCTAssertEqual(try effective(option: .always, screenCapture: false, remote: #"{"replay":{"images":"always"}}"#), .off)
        // A plan without replay has no pictures either.
        XCTAssertEqual(try effective(option: .always, remote: #"{"replay":{"images":"always"},"limits":{"replay":"off"}}"#), .off)
    }

    // MARK: - Encoding

    /// CONTRACT §14.5: one pixel per point, at most 384 a side.
    func testPicturesAreEncodedAtTheirDisplayedSize() {
        func size(_ w: Double, _ h: Double, source: (Double, Double)) -> [Int]? {
            WireframeImageEncoding.pixelSize(displayed: (w, h), source: source).map { [$0.width, $0.height] }
        }
        XCTAssertEqual(WireframeImageEncoding.pixelsPerPoint, 1)
        XCTAssertEqual(size(100, 80, source: (4000, 3000)), [100, 80], "one pixel per point")
        XCTAssertEqual(size(400, 300, source: (4000, 3000)), [384, 288], "the longest side is at most 384")
        XCTAssertEqual(size(300, 600, source: (4000, 4000)), [192, 384])
        XCTAssertEqual(size(100, 100, source: (60, 60)), [60, 60], "never more pixels than the bitmap has")
        XCTAssertNil(size(0, 100, source: (60, 60)))
        XCTAssertNil(size(.infinity, 100, source: (60, 60)))
    }

    func testPNGOnlyForSmallSeeThroughPictures() {
        XCTAssertTrue(WireframeImageEncoding.usesPNG(hasAlpha: true, width: 96, height: 40))
        XCTAssertFalse(WireframeImageEncoding.usesPNG(hasAlpha: true, width: 97, height: 40))
        XCTAssertFalse(WireframeImageEncoding.usesPNG(hasAlpha: false, width: 32, height: 32))
        XCTAssertEqual(WireframeImageEncoding.jpegQuality, 0.45)
        XCTAssertEqual(WireframeImageEncoding.maxEncodedBytes, 48 * 1024)
        XCTAssertEqual(WireframeImageEncoding.retrySize((width: 300, height: 201)).map { [$0.width, $0.height] }, [150, 100])
        XCTAssertNil(WireframeImageEncoding.retrySize((width: 1, height: 1)))
    }

    /// At most 128 pictures per capture; a new one evicts the one shown
    /// longest ago, never one on the frame being captured, so a full
    /// screen of pictures never stops new ones for good.
    func testANewPicturePastTheLimitEvictsTheOneShownLongestAgo() {
        XCTAssertEqual(WireframeImageEncoding.maxPictures, 128)
        XCTAssertNil(WireframeImageEncoding.evictionIndex(lastShownMs: Array(repeating: 0, count: 127), nowMs: 10))
        var shown = (0..<128).map { Int64(1000 + $0) }
        shown[40] = 5
        XCTAssertEqual(WireframeImageEncoding.evictionIndex(lastShownMs: shown, nowMs: 2000), 40)
        // Pictures on this frame stay; the oldest of the others goes.
        XCTAssertEqual(WireframeImageEncoding.evictionIndex(lastShownMs: [7, 3, 7, 5], nowMs: 7, maxPictures: 4), 1)
        XCTAssertNil(WireframeImageEncoding.evictionIndex(lastShownMs: [7, 7], nowMs: 7, maxPictures: 2),
                     "every picture is on this frame: the new one waits")
        // Shown long ago (past the 30 s linger) or a moment ago, the oldest goes.
        XCTAssertEqual(WireframeImageEncoding.evictionIndex(lastShownMs: [90_000, 99_999], nowMs: 100_000,
                                                            maxPictures: 2), 0)
    }

    func testThePictureIsARuleOverThePlaceholder() {
        XCTAssertEqual(
            WireframeImageEncoding.rule(cls: "p3", mime: "image/jpeg", data: Data([1, 2, 3])),
            ".im.p3{background:url(data:image/jpeg;base64,AQID) center/cover no-repeat}"
        )
    }

    func testThePlacementFollowsTheContentMode() {
        func css(_ placement: ImagePlacement) -> String {
            WireframeImageEncoding.placementCss(placement, image: (50, 20), box: (100, 100))
        }
        XCTAssertEqual(css(.aspectFill), "", "the rule's center/cover")
        XCTAssertEqual(css(.aspectFit), "background-size:contain;")
        XCTAssertEqual(css(.fill), "background-size:100% 100%;")
        XCTAssertEqual(css(.center), "background-size:50px 20px;background-position:25px 40px;")
        XCTAssertEqual(css(.topLeft), "background-size:50px 20px;background-position:0px 0px;")
        XCTAssertEqual(css(.bottomRight), "background-size:50px 20px;background-position:50px 80px;")
    }

    // MARK: - Allowance

    func testTheImageAllowanceIsPerSessionAndKeptWithTheReplayBudget() throws {
        let dir = temporaryDirectory()
        var store = StateStore(directory: dir, destination: "d")
        var budget = CollectionBudget(maxImageBytes: 100, store: store)
        XCTAssertFalse(budget.admitImage(bytes: 10), "nothing is counted without a session")
        budget.use("s1")
        XCTAssertTrue(budget.admitImage(bytes: 60))
        XCTAssertFalse(budget.admitImage(bytes: 50), "past the allowance pictures stay placeholders")
        XCTAssertTrue(budget.admitImage(bytes: 40))
        XCTAssertTrue(budget.admit("s1", bytes: 500, events: 3))
        XCTAssertEqual(budget.snapshot("s1")["traceway.replay.image_bytes"], 100)
        XCTAssertEqual(budget.snapshot("s1")["traceway.collection.events"], 3)
        store.flush()

        // A restart within the session goes on from what was used.
        store = StateStore(directory: dir, destination: "d")
        store.load()
        budget = CollectionBudget(maxImageBytes: 100, store: store)
        budget.use("s1")
        XCTAssertEqual(budget.currentSession, "s1")
        XCTAssertFalse(budget.admitImage(bytes: 1))
        XCTAssertEqual(budget.snapshot("s1")["traceway.collection.bytes"], 500)

        budget.use("s2")
        XCTAssertTrue(budget.admitImage(bytes: 100), "a new session has its own allowance")
        XCTAssertEqual(CollectionBudget().maxImageBytes, 4 * 1024 * 1024)
        XCTAssertEqual(CollectionBudget().maxEvents, 10_000)
    }
}
