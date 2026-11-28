import XCTest
@testable import Traceway
#if canImport(UIKit)
import UIKit
#endif

/// The recorder's frame ring, pointers and clips, fed frames by hand. The
/// capture timer and UIKit's touches are covered on the Simulator.
final class WireframeRecorderTests: XCTestCase {
    private var clock: Int64 = 1_767_268_800_000

    private func screen(_ rows: [String], from shared: [VNode] = []) -> VNode {
        var children = shared
        for (i, row) in rows.enumerated() where i >= shared.count {
            children.append(VNode(element: 100 + 2 * i, tag: "div", attributes: ["class": "t", "style": "top:\(20 * i)px"],
                                  children: [VNode(text: 101 + 2 * i, text: row)]))
        }
        return VNode(element: screenNodeId, tag: "div", attributes: ["id": "tw", "style": "width:390px;height:844px"],
                     children: children)
    }

    private func recorder(maxFrames: Int = 50, fps: Int = 10) -> WireframeRecorder {
        let r = WireframeRecorder(maxFrames: maxFrames, fps: fps, now: { [unowned self] in self.clock })
        r.screenName = { "/home" }
        #if canImport(UIKit)
        // Only the frames a test pushes: no window of the host app.
        r.windows = { [] }
        #endif
        return r
    }

    private func frame(_ screen: VNode?, width: Double = 390, height: Double = 844, href: String? = "/home") -> WireframeFrame {
        WireframeFrame(screen: screen, width: width, height: height, timestampMs: clock, href: href)
    }

    func testRasterAllowanceIncludesItsExact128KiBBoundary() throws {
        let r = recorder()
        r.start()
        defer { r.stop() }
        for extra in [0, 1] {
            var styles: [VNode] = []
            // Four PNG data URLs: four 22-byte prefixes, three 32,744-byte
            // base64 payloads and one 32,752-byte payload total 131,072.
            for (i, size) in [24558, 24558, 24558, 24564 + extra].enumerated() {
                let css = WireframeImageEncoding.rule(cls: "p\(i)", mime: "image/png",
                                                      data: Data(repeating: 0, count: size))
                styles.append(VNode(element: 210 + i, tag: "style", attributes: ["_cssText": css], children: []))
            }
            r.push(frame(screen([], from: styles)))
            let clip = try XCTUnwrap(r.captureRecording(clipId: "boundary", sinceMs: clock, untilMs: clock + 1))
            XCTAssertEqual(JSON.array(clip.events).encoded().components(separatedBy: "data:image/png;base64,").count - 1,
                           extra == 0 ? 4 : 0)
            clock += 100
        }
    }

    func testRasterAllowanceCountsSnapshotsAddedNodesAndStyleUpdatesAcrossAClip() throws {
        let r = recorder()
        r.start()
        defer { r.stop() }
        let first = clock
        let bytes = Data(repeating: 0, count: 24 * 1024)
        let photo = WireframeImageEncoding.rule(cls: "p1", mime: "image/jpeg", data: bytes)
        let glyph = MaskPNG.css(cls: "g2", png: bytes)
        func style(_ id: Int, _ css: String) -> VNode {
            VNode(element: id, tag: "style", attributes: ["_cssText": css], children: [])
        }
        func content(_ styles: [VNode]) -> VNode {
            let title = VNode(element: 200, tag: "div", attributes: ["style": "width:91px;height:32px"],
                              children: [VNode(text: 201, text: "Pay ****")])
            return screen([], from: [title] + styles)
        }
        let initial = content([style(210, photo)])
        r.push(frame(initial))
        clock += 100
        r.push(frame(initial, width: 400)) // The same bytes in a second full snapshot.
        clock += 100
        r.push(frame(content([style(210, glyph)]), width: 400)) // An attribute update.
        clock += 100
        let last = clock
        r.push(frame(content([style(210, glyph), style(211, photo)]), width: 400)) // An added style node.
        r.pointerDown(pointer: 1, x: 12, y: 31, touch: true)
        r.pointerUp(pointer: 1, x: 12, y: 31, touch: true, tap: true)
        clock += 100

        let small = try XCTUnwrap(r.captureRecording(clipId: "small", sinceMs: first, untilMs: last))
        let original = JSON.array(small.events).encoded()
        XCTAssertEqual(original.components(separatedBy: photo).count - 1, 2)
        XCTAssertEqual(original.components(separatedBy: glyph).count - 1, 1)

        let large = try XCTUnwrap(r.captureRecording(clipId: "large", sinceMs: first, untilMs: clock))
        let layout = JSON.array(large.events).encoded()
        XCTAssertFalse(layout.contains("data:image/"))
        XCTAssertTrue(layout.contains("width:91px;height:32px"))
        XCTAssertEqual(large.approxBytes, layout.utf8.count)
        XCTAssertEqual(large.events.filter { $0["type"]?.int == 2 }.count, 2)
        XCTAssertEqual(large.events.filter { $0["data"]?["source"]?.int == 0 }.count, 2)
        XCTAssertEqual(large.events.filter { $0["data"]?["source"]?.int == 2 }.count, 3)
        XCTAssertEqual(replay(large.events).screen.texts(), ["Pay ****"])

        let next = try XCTUnwrap(r.captureRecording(clipId: "next", sinceMs: last, untilMs: clock))
        let fresh = JSON.array(next.events).encoded()
        XCTAssertTrue(fresh.contains(photo))
        XCTAssertTrue(fresh.contains(glyph))
    }

    func testAClipCarriesThePicturesItShowsNotEveryRuleThatStillLingers() throws {
        let r = recorder()
        r.start()
        defer { r.stop() }
        // A grid scrolled through 40 pictures in the last 30 s; six are on
        // screen. All 40 rules would take 320 KiB, past a segment's 128 KiB.
        let start = clock
        r.push(frame(gridScreen(shown: Array(34..<40), lingering: Array(0..<40))))
        clock += 250
        let clip = try XCTUnwrap(r.captureRecording(clipId: "grid", sinceMs: start, untilMs: clock))
        let encoded = JSON.array(clip.events).encoded()
        for n in 34..<40 { XCTAssertTrue(encoded.contains(gridRule(n)), "p\(n) is on screen") }
        for n in 0..<34 { XCTAssertFalse(encoded.contains(".im.p\(n){"), "p\(n) is not on screen") }
        let pictures = replay(clip.events).pictures()
        XCTAssertEqual(pictures.used, Set((34..<40).map { "p\($0)" }))
        XCTAssertEqual(pictures.drawn, pictures.used)
    }

    func testAClipReplaysToTheLastScreenTouchesIncluded() {
        let r = recorder()
        r.start()
        let start = clock
        var shown = screen(["row 0"])
        r.push(frame(shown))
        for i in 1...3 {
            clock += 500
            shown = screen((0...i).map { "row \($0)" }, from: shown.children)
            r.push(frame(shown))
        }
        r.pointerDown(pointer: 1, x: 10.4, y: 20.6, touch: true)
        r.pointerUp(pointer: 1, x: 10.4, y: 20.6, touch: true, tap: true)
        XCTAssertEqual(r.bufferedFrameCount, 4)
        clock += 2000
        let end = clock

        let clip = r.captureRecording(clipId: "c", sinceMs: start, untilMs: end)!
        let events = clip.events
        XCTAssertEqual(events.map { $0["type"]!.int! }, [4, 2, 3, 3, 3, 3, 3, 3, 5])
        XCTAssertEqual(events[0]["data"], ["href": "/home", "width": 390, "height": 844])
        let times = events.map { $0["timestamp"]!.int! }
        XCTAssertEqual(times, times.sorted())
        XCTAssertEqual(Int64(times.first!), start)
        XCTAssertEqual(Int64(times.last!), end)
        XCTAssertEqual(events.last!["data"], ["tag": "traceway.end", "payload": [:]])
        XCTAssertEqual(clip.startedAtMs, start)
        XCTAssertEqual(clip.endedAtMs, end)
        XCTAssertEqual(clip.approxBytes, JSON.array(events).encoded().utf8.count)
        XCTAssertGreaterThan(clip.approxBytes, 1000)

        // Touches: start, end and a click, on the screen node.
        let touches = events.filter { $0["data"]?["source"]?.int == 2 }.map { $0["data"]! }
        XCTAssertEqual(touches.map { $0["type"]!.int! }, [7, 9, 2])
        XCTAssertEqual(touches[0], ["source": 2, "type": 7, "id": JSON(screenNodeId), "x": 10, "y": 21, "pointerType": 2])

        let mirror = Mirror()
        mirror.play(events)
        XCTAssertEqual(mirror.screen.texts(), ["row 0", "row 1", "row 2", "row 3"])
        // Unchanged rows are shared, so a mutation only adds the new row.
        let mutations = events.filter { $0["data"]?["source"]?.int == 0 }
        XCTAssertEqual(mutations.map { $0["data"]!["adds"]!.array!.count }, [2, 2, 2])

        // A window that starts after the last change still shows the screen.
        let later = end - 1000
        XCTAssertTrue(r.hasFrames(sinceMs: later, untilMs: end))
        let tail = r.captureRecording(clipId: "t", sinceMs: later, untilMs: end)!
        XCTAssertEqual(tail.events.map { $0["type"]!.int! }, [4, 2, 5])
        XCTAssertEqual(tail.startedAtMs, later)
        let tailMirror = Mirror()
        tailMirror.play(tail.events)
        XCTAssertEqual(tailMirror.screen.texts(), ["row 0", "row 1", "row 2", "row 3"])

        // Nothing is on screen once the app is away.
        r.pushBlank()
        clock += 5000
        XCTAssertFalse(r.hasFrames(sinceMs: clock - 1000, untilMs: clock))
        XCTAssertNil(r.captureRecording(clipId: "x", sinceMs: clock - 1000, untilMs: clock))
    }

    func testIdenticalFramesAreSkippedAndTheRingIsBounded() {
        let r = recorder(maxFrames: 3)
        let shown = screen(["a"])
        r.push(frame(shown))
        clock += 100
        r.push(frame(shown))
        XCTAssertEqual(r.bufferedFrameCount, 1)
        // The same screen at another size is a new frame.
        r.push(frame(shown, width: 844, height: 390))
        XCTAssertEqual(r.bufferedFrameCount, 2)
        for i in 0..<5 {
            clock += 100
            r.push(frame(screen(["b\(i)"])))
        }
        XCTAssertEqual(r.bufferedFrameCount, 3)
        r.clearBuffer()
        XCTAssertEqual(r.bufferedFrameCount, 0)
    }

    func testAClipOfAFullRingStartsAtTheOldestFrameKeptAndEndsAtTheNewest() {
        let r = recorder(maxFrames: 5)
        let start = clock
        for i in 0..<10 {
            clock += 100
            r.push(frame(screen((0...(i % 3)).map { "frame \(i) row \($0)" })))
        }
        XCTAssertEqual(r.bufferedFrameCount, 5)
        clock += 100
        let clip = r.captureRecording(clipId: "c", sinceMs: start, untilMs: clock)!
        // Frames 0 to 4 left the ring: the clip starts at frame 5.
        XCTAssertEqual(clip.startedAtMs, start + 600)
        let first = Mirror()
        first.play(Array(clip.events.prefix(2)))
        XCTAssertEqual(first.screen.texts(), ["frame 5 row 0", "frame 5 row 1", "frame 5 row 2"])
        let mirror = Mirror()
        mirror.play(clip.events)
        XCTAssertEqual(mirror.screen.texts(), ["frame 9 row 0"])
    }

    func testASizeChangeOrABlankFrameStartsANewSnapshot() {
        let r = recorder()
        let start = clock
        r.push(frame(screen(["portrait"])))
        clock += 100
        r.push(frame(screen(["landscape"]), width: 844, height: 390))
        clock += 100
        r.pushBlank()
        clock += 100
        r.push(frame(screen(["back"])))
        clock += 100
        let clip = r.captureRecording(clipId: "c", sinceMs: start, untilMs: clock)!
        // Each change of size, and the away screen and the return from it, is
        // a meta event and a full snapshot.
        XCTAssertEqual(clip.events.map { $0["type"]!.int! }, [4, 2, 4, 2, 4, 2, 4, 2, 5])
        XCTAssertEqual(clip.events[2]["data"]!["width"], 844)
        let away = Mirror()
        away.play(Array(clip.events.prefix(6)))
        XCTAssertEqual(away.screen.texts(), ["App in the background"])
        let mirror = Mirror()
        mirror.play(clip.events)
        XCTAssertEqual(mirror.screen.texts(), ["back"])
        // A blank frame repeats only once.
        r.pushBlank()
        r.pushBlank()
        XCTAssertEqual(r.bufferedFrameCount, 5)
    }

    func testAClipStartsAtTheFirstFrameInsideItsWindow() {
        let r = recorder()
        XCTAssertFalse(r.hasFrames(sinceMs: nil, untilMs: nil))
        XCTAssertNil(r.captureRecording(clipId: "none", sinceMs: nil, untilMs: nil))
        clock += 1000
        let first = clock
        r.push(frame(screen(["a"])))
        // From before anything was recorded: the clip starts at the first frame.
        let clip = r.captureRecording(clipId: "c", sinceMs: first - 5000, untilMs: first + 10)!
        XCTAssertEqual(clip.startedAtMs, first)
        XCTAssertFalse(r.hasFrames(sinceMs: first + 10, untilMs: first + 10))
        XCTAssertFalse(r.hasFrames(sinceMs: first - 5000, untilMs: first))
        XCTAssertTrue(r.hasFrames(sinceMs: first - 5000, untilMs: first + 1))
        // A clip whose end is the moment of its only frame ends at once.
        XCTAssertNil(r.captureRecording(clipId: "e", sinceMs: first - 10, untilMs: first))
    }

    func testAnEmptyOrInvertedWindowHasNoClip() {
        let r = recorder()
        r.push(frame(screen(["a"])))
        let first = clock
        clock += 1000
        r.push(frame(screen(["b"])))
        clock += 1000
        XCTAssertNotNil(r.captureRecording(clipId: "ok", sinceMs: first + 500, untilMs: first + 1500))
        // A frame shows at both ends, yet the window holds no time.
        XCTAssertNil(r.captureRecording(clipId: "empty", sinceMs: first + 500, untilMs: first + 500))
        XCTAssertNil(r.captureRecording(clipId: "inverted", sinceMs: first + 1500, untilMs: first + 500))
        // Without an end the window runs to now: a start after now is inverted too.
        XCTAssertNil(r.captureRecording(clipId: "future", sinceMs: clock + 1000, untilMs: nil))
        XCTAssertFalse(r.hasFrames(sinceMs: first + 1500, untilMs: first + 500))
    }

    func testAClipWithoutAnEndRunsToNowAndOneWithoutAStartFromTheFirstFrame() {
        let r = recorder()
        let first = clock
        r.push(frame(screen(["a"]), href: nil))
        clock += 1500
        let clip = r.captureRecording(clipId: "c", sinceMs: nil, untilMs: nil)!
        XCTAssertEqual(clip.startedAtMs, first)
        XCTAssertEqual(clip.endedAtMs, clock)
        XCTAssertEqual(clip.clipId, "c")
        XCTAssertEqual(clip.events.first?["data"]?["href"], "/", "a frame without a screen name replays at /")
        XCTAssertEqual(clip.events.map { $0["type"]!.int! }, [4, 2, 5])
        XCTAssertEqual(clip.events[1]["data"]?["initialOffset"], ["left": 0, "top": 0])
        XCTAssertTrue(r.hasFrames(sinceMs: nil, untilMs: nil))
    }

    func testPointerEventsMapToRrwebAndMovesAreThrottled() {
        let r = recorder()
        // Not recording: pointers are not kept.
        r.pointerDown(pointer: 1, x: 1, y: 1, touch: true)
        r.start()
        let start = clock
        r.push(frame(screen(["a"])))
        r.pointerDown(pointer: 1, x: 1, y: 2, touch: true)
        clock += 10
        r.pointerMove(pointer: 1, x: 3, y: 4, touch: true)
        clock += 10
        r.pointerMove(pointer: 1, x: 5, y: 6, touch: true) // within 50 ms: dropped
        clock += 60
        r.pointerMove(pointer: 1, x: 7, y: 8, touch: true)
        r.pointerUp(pointer: 1, x: 7, y: 8, touch: true, tap: false)
        clock += 10
        r.pointerDown(pointer: 2, x: 9, y: 9, touch: false)
        r.pointerMove(pointer: 2, x: 10, y: 10, touch: false)
        r.pointerUp(pointer: 2, x: 10, y: 10, touch: false, tap: true)
        r.pointerDown(pointer: 3, x: 1, y: 1, touch: true)
        r.pointerCancel(pointer: 3, x: 1, y: 1, touch: true)
        clock += 10
        let events = r.captureRecording(clipId: "c", sinceMs: start, untilMs: clock)!.events
        let input = events.filter { $0["type"]?.int == 3 }.map { $0["data"]! }
        func describe(_ d: JSON) -> String {
            let source = d["source"]!.int!
            if source == 2 { return "i\(d["type"]!.int!)p\(d["pointerType"]!.int!)" }
            let p = d["positions"]!.array![0]
            return "m\(source)@\(p["x"]!.int!),\(p["y"]!.int!)"
        }
        XCTAssertEqual(input.map(describe), [
            "i7p2", "m6@3,4", "m6@7,8", "i9p2",
            "i1p0", "m1@10,10", "i0p0", "i2p0",
            "i7p2", "i10p2",
        ])
        XCTAssertEqual(input[1]["positions"]!.array![0]["id"]?.int, screenNodeId)
        r.stop()
        XCTAssertFalse(r.isRunning)
        // Stopping leaves the screen blank from then on.
        clock += 100
        XCTAssertFalse(r.hasFrames(sinceMs: clock - 10, untilMs: clock))
    }

    func testMovesAreThinnedToOnePerPointerEvery50Ms() {
        let r = recorder()
        r.start()
        let start = clock
        r.push(frame(screen(["a"])))
        r.pointerDown(pointer: 1, x: 0, y: 0, touch: true)
        r.pointerDown(pointer: 2, x: 100, y: 0, touch: true)
        for i in 0..<20 {
            r.pointerMove(pointer: 1, x: Double(i), y: Double(i * 2), touch: true)
            r.pointerMove(pointer: 2, x: Double(100 + i), y: 0, touch: true)
            clock += 10
        }
        r.pointerUp(pointer: 1, x: 20, y: 40, touch: true, tap: false)
        r.pointerUp(pointer: 2, x: 120, y: 0, touch: true, tap: false)
        let events = r.captureRecording(clipId: "c", sinceMs: start, untilMs: clock + 1)!.events
        let moves = events.filter { $0["type"]?.int == 3 && $0["data"]?["source"]?.int == 6 }
            .map { $0["data"]!["positions"]!.array![0] }
        // 200 ms of moves every 10 ms: one every 50 ms for each finger, the
        // other finger's moves in between do not count.
        let first = moves.filter { $0["x"]!.int! < 100 }
        let second = moves.filter { $0["x"]!.int! >= 100 }
        XCTAssertEqual(first.count, 4)
        XCTAssertEqual(second.count, 4)
        XCTAssertEqual(first[1], ["x": 5, "y": 10, "id": JSON(screenNodeId), "timeOffset": 0])
        XCTAssertEqual(second.map { $0["x"]!.int! }, [100, 105, 110, 115])
    }

    func testOnlyTouchesInsideTheClipAreReplayed() {
        let r = recorder()
        r.start()
        r.push(frame(screen(["a"])))
        r.pointerDown(pointer: 1, x: 1, y: 1, touch: true)
        r.pointerUp(pointer: 1, x: 1, y: 1, touch: true, tap: true)
        clock += 1000
        let since = clock
        r.pointerDown(pointer: 2, x: 2, y: 2, touch: true)
        clock += 100
        let until = clock
        r.pointerUp(pointer: 2, x: 2, y: 2, touch: true, tap: true)
        let events = r.captureRecording(clipId: "c", sinceMs: since, untilMs: until)!.events
        let touches = events.filter { $0["data"]?["source"]?.int == 2 }.map { $0["data"]! }
        // The tap before the clip is left out; the finger that lifts after it
        // ends is still down when the replay ends.
        XCTAssertEqual(touches.map { $0["type"]!.int! }, [7])
        XCTAssertEqual(touches[0]["x"], 2)
        XCTAssertEqual(events.last?["timestamp"]?.int.map(Int64.init), until)
    }

    #if canImport(UIKit)
    func testTouchesOnTheKeyboardAreNotRecorded() {
        let r = recorder()
        r.start()
        defer { r.stop() }
        let start = clock
        r.push(frame(screen(["a"])))
        let bounds = CGRect(x: 0, y: 0, width: 390, height: 844)
        let onApp = FakeTouch(window: UIWindow(frame: bounds), at: CGPoint(x: 30, y: 40))
        let onKey = FakeTouch(window: FakeUIKeyboardWindow(frame: bounds), at: CGPoint(x: 200, y: 700))
        for phase in [UITouch.Phase.began, .ended] {
            onApp.fakePhase = phase
            onKey.fakePhase = phase
            r.handle(FakeEvent([onApp, onKey]))
            clock += 10
        }
        let events = r.captureRecording(clipId: "c", sinceMs: start, untilMs: clock + 1)!.events
        let touches = events.filter { $0["data"]?["source"]?.int == 2 }.map { $0["data"]! }
        // The tap on the app: down, up and its click. Nothing of the key.
        XCTAssertEqual(touches.map { $0["type"]!.int! }, [7, 9, 2])
        XCTAssertTrue(touches.allSatisfy { $0["x"]?.int == 30 && $0["y"]?.int == 40 }, "\(touches)")
    }
    #endif

    func testMaskAllInputsIsOnByDefault() {
        let r = recorder()
        XCTAssertTrue(r.maskAllInputs)
        r.maskAllInputs = false
        XCTAssertFalse(r.maskAllInputs)
    }

    func testImagesAreOffUntilTheSettingsAllowThem() {
        let r = recorder()
        XCTAssertEqual(r.imagePolicy, .off)
        r.imagePolicy = .wifi
        XCTAssertEqual(r.imagePolicy, .wifi)
    }

    func testTurningInputMaskingOnDropsWhatWasRecordedWithoutIt() {
        let r = recorder()
        r.maskAllInputs = false
        r.start()
        defer { r.stop() }
        let start = clock
        r.push(frame(screen(["4242 4242"])))
        r.pointerDown(pointer: 1, x: 1, y: 1, touch: true)
        clock += 100
        r.maskAllInputs = false
        XCTAssertEqual(r.bufferedFrameCount, 1, "nothing changed")
        r.maskAllInputs = true
        XCTAssertEqual(r.bufferedFrameCount, 0, "the frames held show what was typed")
        XCTAssertNil(r.captureRecording(clipId: "c", sinceMs: start, untilMs: clock + 1))
        // Loosening drops nothing.
        r.push(frame(screen(["**** ****"])))
        r.maskAllInputs = false
        XCTAssertEqual(r.bufferedFrameCount, 1)
    }

    func testAStricterImagePolicyDropsWhatWasRecordedUnderTheLooserOne() {
        let r = recorder()
        r.start()
        defer { r.stop() }
        r.imagePolicy = .wifi
        r.push(frame(screen(["a"])))
        clock += 100
        r.imagePolicy = .always
        r.imagePolicy = .always
        XCTAssertEqual(r.bufferedFrameCount, 1, "a looser policy drops nothing")
        r.imagePolicy = .wifi
        XCTAssertEqual(r.bufferedFrameCount, 0, "always to wifi")
        r.push(frame(screen(["b"])))
        clock += 100
        r.imagePolicy = .off
        XCTAssertEqual(r.bufferedFrameCount, 0, "wifi to off")
        r.imagePolicy = .always
        r.push(frame(screen(["c"])))
        clock += 100
        r.imagePolicy = .off
        XCTAssertEqual(r.bufferedFrameCount, 0, "always to off")
        XCTAssertNil(r.captureRecording(clipId: "c", sinceMs: nil, untilMs: clock + 1))
    }

    func testTheFrameRateAndTheRingAreClamped() {
        XCTAssertEqual(WireframeRecorder(fps: 0).fps, 1)
        XCTAssertEqual(WireframeRecorder(fps: 60).fps, 15)
        XCTAssertEqual(WireframeRecorder().fps, 4)
        let tiny = recorder(maxFrames: 0)
        for i in 0..<4 {
            clock += 100
            tiny.push(frame(screen(["\(i)"])))
        }
        XCTAssertEqual(tiny.bufferedFrameCount, 2, "a ring holds at least two frames")
        tiny.start()
        tiny.start()
        XCTAssertTrue(tiny.isRunning)
        tiny.stop()
        tiny.stop()
        XCTAssertFalse(tiny.isRunning)
    }

    func testATapLiftsNearWhereItStartedBeforeTheLongPressDuration() {
        // The tap record and the replay's click use the same rule.
        XCTAssertTrue(TapGesture.isTap(dx: 6, dy: 8, durationMs: 499))
        XCTAssertFalse(TapGesture.isTap(dx: 6, dy: 8, durationMs: 500), "UIKit's long press")
        XCTAssertFalse(TapGesture.isTap(dx: 8, dy: 8, durationMs: 100), "moved more than 10 points")
        XCTAssertEqual(TapGesture.maxDurationMs, 500)
    }

    func testTheAwayScreenIsWithinReservedIds() {
        let away = WireframeRecorder.awayScreen(390, 844)
        XCTAssertEqual(away.id, screenNodeId)
        XCTAssertTrue(allNodes(away).allSatisfy { $0.id < firstCapturedNodeId })
        XCTAssertEqual(away.attributes["id"], "tw")
        XCTAssertEqual(away.children.map(\.id), [awayScreenTextBoxId])
        XCTAssertEqual(away.children[0].children.map(\.id), [awayScreenTextId])
        XCTAssertEqual(allTexts(away), ["App in the background"])
    }
}

#if canImport(UIKit)
/// A window of a keyboard class by its name, as `ClassInfo` tells them.
final class FakeUIKeyboardWindow: UIWindow {}

/// A touch in `window` at `at`, in the phase a test gives it.
final class FakeTouch: UITouch {
    private let touched: UIWindow
    private let at: CGPoint
    var fakePhase: UITouch.Phase = .began

    init(window: UIWindow, at: CGPoint) {
        self.touched = window
        self.at = at
        super.init()
    }

    override var window: UIWindow? { touched }
    override var phase: UITouch.Phase { fakePhase }
    override var type: UITouch.TouchType { .direct }
    override func location(in view: UIView?) -> CGPoint { at }
}

final class FakeEvent: UIEvent {
    private let fakeTouches: Set<UITouch>

    init(_ touches: Set<UITouch>) {
        self.fakeTouches = touches
        super.init()
    }

    override var type: UIEvent.EventType { .touches }
    override var allTouches: Set<UITouch>? { fakeTouches }
}
#endif
