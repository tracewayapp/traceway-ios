import Foundation
import XCTest
@testable import Traceway

/// A recorder whose every window has frames; it remembers the windows it was
/// asked for. With `gate` set, a clip waits for it, like a slow encoder.
final class ClipSource: ReplaySource {
    struct Capture {
        let clipId: String
        let since: Int64?
        let until: Int64?
    }

    private let fixtureEvents: [JSON]?

    init(events: [JSON]? = nil) { fixtureEvents = events }

    private let lock = NSLock()
    private var running = false
    private var _clears = 0
    private var _captures: [Capture] = []
    private var _gate: DispatchSemaphore?

    var isRunning: Bool { locked { running } }
    var clears: Int { locked { _clears } }
    var captures: [Capture] { locked { _captures } }
    var gate: DispatchSemaphore? {
        get { locked { _gate } }
        set { locked { _gate = newValue } }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    func start() { locked { running = true } }
    func stop() { locked { running = false } }
    func clearBuffer() { locked { _clears += 1 } }

    func hasFrames(sinceMs: Int64?, untilMs: Int64?) -> Bool {
        guard let since = sinceMs, let until = untilMs else { return true }
        return since < until
    }

    func captureRecording(clipId: String, sinceMs: Int64?, untilMs: Int64?) -> SessionRecordingPayload? {
        let gate: DispatchSemaphore? = locked {
            _captures.append(Capture(clipId: clipId, since: sinceMs, until: untilMs))
            return _gate
        }
        gate?.wait()
        let end = untilMs ?? 0
        let events: [JSON] = fixtureEvents ?? [["type": 2, "data": "AAECAw==", "timestamp": JSON(end)]]
        return SessionRecordingPayload(
            clipId: clipId,
            events: events,
            startedAtMs: sinceMs ?? end - 10_000,
            endedAtMs: end,
            approxBytes: fixtureEvents == nil ? 40 : JSON.array(events).encoded().utf8.count
        )
    }
}

final class ReplayControllerTests: XCTestCase {
    private let queue = DispatchQueue(label: "test.replay")
    private let http = FakeHTTP()
    private var index = 0
    private var session: String? = "s1"
    private var controllers: [ReplayController] = []

    override func tearDown() {
        for c in controllers { queue.sync { c.stop() } }
        controllers = []
        super.tearDown()
    }

    private func controller(
        _ clock: ManualClock = ManualClock(),
        segmentMs: Int = 8000,
        budget: CollectionBudget = CollectionBudget()
    ) -> ReplayController {
        let c = ReplayController(
            transport: RecordingsTransport(url: URL(string: "https://h/api/recordings")!, token: "tok", transport: http),
            queue: queue,
            sessionId: { self.session },
            nextSegmentIndex: {
                defer { self.index += 1 }
                return self.index
            },
            segmentMs: segmentMs,
            budget: budget,
            now: clock.now
        )
        controllers.append(c)
        return c
    }

    /// Runs `body` on the controller's queue, where the client calls it.
    private func onQueue<T>(_ body: () -> T) -> T { queue.sync(execute: body) }

    private func drain(_ c: ReplayController) -> Bool {
        completes { done in queue.async { c.drain(done) } }
    }

    private func uploaded() -> [[String: JSON]] { http.requests.flatMap(segments(of:)) }

    func testOverBudgetRasterClipUploadsItsLayoutWithinTheSessionByteBudget() throws {
        let data = Data(repeating: 0x61, count: 24 * 1024)
        let styles = (0..<4).map { i in
            VNode(element: 100 + i, tag: "style",
                  attributes: ["_cssText": WireframeImageEncoding.rule(cls: "p\(i)", mime: "image/png", data: data)],
                  children: [])
        }
        let root = VNode(element: screenNodeId, tag: "div", attributes: ["style": "width:320px;height:600px"],
                         children: styles + [VNode(text: 200, text: "Checkout")])
        let events: [JSON] = [["type": 2, "timestamp": 1, "data": ["node": serializeDocument(root)]]]
        let structuralBytes = JSON.array(events).encoded().utf8.count - 4 * 32 * 1024
        let c = controller(budget: CollectionBudget(maxBytes: structuralBytes + 1024))
        let source = ClipSource(events: events)
        onQueue {
            c.attach(source)
            c.apply(.buffer, maxAgeMs: 600_000)
            _ = c.flush(lookbackMs: 30_000, exceptionId: "checkout")
        }
        XCTAssertTrue(drain(c))
        let uploaded = try XCTUnwrap(uploaded().first)
        XCTAssertEqual(uploaded["exceptionId"], "checkout")
        let replay = try XCTUnwrap(uploaded["events"]?.array?.first)
        XCTAssertFalse(replay.encoded().contains("data:image/"))
        XCTAssertTrue(replay.encoded().contains("width:320px;height:600px"))
        XCTAssertTrue(replay.encoded().contains("Checkout"))
    }

    func testACaptureFlushWithoutAnExceptionIsPartOfTheSession() {
        let c = controller()
        let flushed = onQueue { () -> Bool in
            c.attach(ClipSource())
            c.apply(.buffer, maxAgeMs: 600_000)
            return c.flush(lookbackMs: 30_000, exceptionId: nil)
        }
        XCTAssertTrue(flushed)
        XCTAssertTrue(drain(c))
        XCTAssertEqual(uploaded().count, 1)
        let segment = uploaded().first
        XCTAssertEqual(segment?["sessionId"], "s1")
        XCTAssertEqual(segment?["segmentIndex"], 0)
        XCTAssertNil(segment?["exceptionId"])
    }

    func testWithoutASessionOrAnExceptionThereIsNothingToAttachTo() {
        session = nil
        let source = ClipSource()
        let c = controller()
        let flushed = onQueue { () -> [Bool] in
            c.attach(source)
            c.apply(.buffer, maxAgeMs: 600_000)
            return [c.flush(lookbackMs: 30_000, exceptionId: nil), c.flush(lookbackMs: 30_000, exceptionId: "")]
        }
        XCTAssertEqual(flushed, [false, false])
        XCTAssertTrue(drain(c))
        XCTAssertTrue(source.captures.isEmpty)
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testTheWindowIsTheSmallerOfTheLookbackAndTheBufferAge() {
        let clock = ManualClock()
        let source = ClipSource()
        let c = controller(clock)
        XCTAssertTrue(onQueue { () -> Bool in
            c.attach(source)
            c.apply(.buffer, maxAgeMs: 4000)
            return c.flush(lookbackMs: 30_000, exceptionId: "e1")
        })
        XCTAssertTrue(drain(c))
        XCTAssertEqual(source.captures.count, 1)
        XCTAssertEqual(source.captures.first?.until, clock.now())
        XCTAssertEqual(source.captures.first?.since, clock.now() - 4000)
        XCTAssertEqual(uploaded().first?["exceptionId"], "e1")
    }

    func testClipsOfOneSessionNeverOverlapAndEveryExceptionGetsItsWindow() {
        let clock = ManualClock()
        let source = ClipSource()
        let c = controller(clock)
        onQueue {
            c.attach(source)
            c.apply(.buffer, maxAgeMs: 600_000)
            _ = c.flush(lookbackMs: 30_000, exceptionId: "e1")
        }
        let first = clock.now()
        clock.advance(5000)
        onQueue { _ = c.flush(lookbackMs: 30_000, exceptionId: "e2") }
        XCTAssertTrue(drain(c))
        let now = clock.now()
        var windows: [String: [Int64?]] = [:]
        for capture in source.captures { windows[capture.clipId] = [capture.since, capture.until] }
        XCTAssertEqual(windows["e2"], [now - 30_000, now])
        XCTAssertEqual(windows["s1_1"], [first, now])
        XCTAssertEqual(uploaded().filter { $0["sessionId"] == "s1" }.map { $0["segmentIndex"] }, [0, 1])
        let clip = uploaded().filter { $0["exceptionId"] == "e2" }
        XCTAssertEqual(clip.count, 1)
        XCTAssertNil(clip.first?["sessionId"])
    }

    func testStreamUploadsConsecutiveSegmentsThatStartWhereTheLastEnded() {
        let clock = ManualClock()
        let source = ClipSource()
        // The timer ticks every 20 ms; segments are as long as the clock moved.
        let c = controller(clock, segmentMs: 20)
        onQueue {
            c.attach(source)
            c.apply(.buffer, maxAgeMs: 600_000)
            // A capture: its lookback first, then streaming from there.
            _ = c.flush(lookbackMs: 30_000, exceptionId: nil)
        }
        let flushedUntil = clock.now()
        onQueue { c.apply(.stream, maxAgeMs: 600_000) }
        XCTAssertEqual(onQueue { c.mode }, .stream)
        for cut in 2...4 {
            clock.advance(8000)
            XCTAssertTrue(eventually { source.captures.count == cut }, "segment \(cut)")
        }
        clock.advance(2000)
        onQueue { c.apply(.buffer, maxAgeMs: 600_000) }
        XCTAssertTrue(drain(c))
        let windows = source.captures.map { [$0.since, $0.until] }
        XCTAssertEqual(windows.count, 5)
        XCTAssertEqual(windows[1][0], flushedUntil)
        for i in 1..<windows.count { XCTAssertEqual(windows[i - 1][1], windows[i][0], "segment \(i)") }
        XCTAssertEqual(windows.last?[1], clock.now())
        let segments = uploaded()
        XCTAssertTrue(segments.allSatisfy { $0["sessionId"] == "s1" && $0["exceptionId"] == nil })
        XCTAssertEqual(segments.compactMap { $0["segmentIndex"]?.int }, Array(0..<segments.count))
        // Back to buffering: no timer is left.
        clock.advance(60_000)
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(source.captures.count, 5)
    }

    func testAnExceptionWhileStreamingGetsItsOwnClipOutsideTheSession() {
        let clock = ManualClock()
        let source = ClipSource()
        let c = controller(clock)
        onQueue {
            c.attach(source)
            c.apply(.stream, maxAgeMs: 600_000)
        }
        clock.advance(3000)
        XCTAssertTrue(onQueue { c.flush(lookbackMs: 30_000, exceptionId: "e1") })
        XCTAssertTrue(drain(c))
        XCTAssertEqual(uploaded().count, 1)
        XCTAssertEqual(uploaded().first?["exceptionId"], "e1")
        XCTAssertNil(uploaded().first?["sessionId"])
        XCTAssertEqual(source.captures.first?.since, clock.now() - 30_000)
    }

    func testASlowEncoderMakesTheNextSegmentLongerNotAQueue() {
        let clock = ManualClock()
        let source = ClipSource()
        let gate = DispatchSemaphore(value: 0)
        source.gate = gate
        let c = controller(clock, segmentMs: 20)
        onQueue {
            c.attach(source)
            c.apply(.stream, maxAgeMs: 600_000)
        }
        clock.advance(8000)
        XCTAssertTrue(eventually { source.captures.count == 1 })
        // One clip at a time: the timed cuts wait for the first one.
        for _ in 0..<4 {
            clock.advance(8000)
            Thread.sleep(forTimeInterval: 0.06)
        }
        XCTAssertEqual(source.captures.count, 1)
        source.gate = nil
        gate.signal()
        XCTAssertTrue(eventually { source.captures.count == 2 })
        let windows = source.captures.map { [$0.since!, $0.until!] }
        XCTAssertEqual(windows[0][1], windows[1][0])
        XCTAssertGreaterThan(windows[1][1] - windows[1][0], 30_000)
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(source.captures.count, 2)
    }

    func testASessionThatIsNotSampledForReplayKeepsBuffering() {
        let c = controller()
        onQueue { c.apply(.stream, maxAgeMs: 600_000, sessionSampled: false) }
        XCTAssertEqual(onQueue { c.mode }, .buffer)
    }

    func testTheLastStreamedSegmentBelongsToTheSessionThatEnded() {
        let clock = ManualClock()
        let c = controller(clock)
        onQueue {
            c.attach(ClipSource())
            c.apply(.stream, maxAgeMs: 600_000)
        }
        clock.advance(4000)
        onQueue {
            session = nil
            c.onSessionEnd("s1")
        }
        XCTAssertTrue(drain(c))
        XCTAssertEqual(uploaded().map { $0["sessionId"] }, ["s1"])
    }

    func testASessionStopsUploadingOnceItsBudgetIsUsed() {
        let clock = ManualClock()
        var drops = 0
        // 256 bytes of overhead and 40 of events: two segments fit in 600.
        let c = controller(clock, budget: CollectionBudget(maxBytes: 600))
        onQueue {
            c.onBudgetDrop = { drops += 1 }
            c.attach(ClipSource())
            c.apply(.buffer, maxAgeMs: 600_000)
        }
        for i in 0..<4 {
            onQueue { _ = c.flush(lookbackMs: 30_000, exceptionId: "e\(i)") }
            clock.advance(60_000)
            XCTAssertTrue(drain(c))
        }
        XCTAssertEqual(uploaded().count, 2)
        XCTAssertEqual(onQueue { drops }, 2)
        let snapshot = c.budget.snapshot("s1")
        XCTAssertEqual(snapshot["traceway.collection.events"], 2)
        XCTAssertEqual(snapshot["traceway.collection.dropped"], 2)
        XCTAssertEqual(c.budget.snapshot("s2")["traceway.collection.events"], 0)
    }

    func testOffStopsTheSourceClearsFramesAndRefusesToFlush() {
        let source = ClipSource()
        let c = controller()
        onQueue {
            c.attach(source)
            c.apply(.buffer, maxAgeMs: 600_000)
        }
        XCTAssertTrue(source.isRunning)
        onQueue { c.apply(.off, maxAgeMs: 600_000) }
        XCTAssertFalse(source.isRunning)
        XCTAssertGreaterThan(source.clears, 0)
        XCTAssertFalse(onQueue { c.flush(lookbackMs: 30_000, exceptionId: "e1") })
        XCTAssertTrue(drain(c))
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testAClipBeingAssembledWhenMaskingGotStricterIsNotUploaded() {
        let source = ClipSource()
        let gate = DispatchSemaphore(value: 0)
        source.gate = gate
        let c = controller()
        XCTAssertTrue(onQueue { () -> Bool in
            c.attach(source)
            c.apply(.buffer, maxAgeMs: 600_000)
            return c.flush(lookbackMs: 30_000, exceptionId: "e1")
        })
        XCTAssertTrue(eventually { source.captures.count == 1 }, "the clip is being assembled")
        onQueue { c.discardRecorded() }
        source.gate = nil
        gate.signal()
        XCTAssertTrue(drain(c))
        XCTAssertTrue(http.requests.isEmpty, "made of frames recorded before the change")
        // What is recorded from then on goes up as before.
        XCTAssertTrue(onQueue { c.flush(lookbackMs: 30_000, exceptionId: "e2") })
        XCTAssertTrue(drain(c))
        XCTAssertEqual(uploaded().map { $0["exceptionId"] }, ["e2"])
    }

    func testClipsWaitingToBeSentWhenMaskingGotStricterAreDropped() {
        let answer = DispatchSemaphore(value: 0)
        http.handler = { _ in
            answer.wait()
            return HTTPResult(statusCode: 200)
        }
        session = nil
        let clock = ManualClock()
        let c = controller(clock)
        onQueue {
            c.attach(ClipSource())
            c.apply(.buffer, maxAgeMs: 600_000)
            _ = c.flush(lookbackMs: 30_000, exceptionId: "e1")
        }
        XCTAssertTrue(eventually { self.http.requests.count == 1 }, "the first clip is with the network")
        clock.advance(1000)
        onQueue { _ = c.flush(lookbackMs: 30_000, exceptionId: "e2") }
        XCTAssertTrue(eventually { c.transport.pending == 1 }, "the second waits behind it")
        onQueue { c.discardRecorded() }
        answer.signal()
        XCTAssertTrue(drain(c))
        XCTAssertEqual(uploaded().map { $0["exceptionId"] }, ["e1"])
        XCTAssertEqual(c.transport.pending, 0)
    }

    func testClipsAreAssembledOffTheClientQueue() {
        let source = ClipSource()
        let gate = DispatchSemaphore(value: 0)
        source.gate = gate
        let c = controller()
        XCTAssertTrue(onQueue { () -> Bool in
            c.attach(source)
            c.apply(.buffer, maxAgeMs: 600_000)
            return c.flush(lookbackMs: 30_000, exceptionId: "e1")
        })
        let drained = DispatchSemaphore(value: 0)
        queue.async { c.drain { drained.signal() } }
        // The client's queue is free while the clip is assembled.
        XCTAssertEqual(onQueue { c.mode }, .buffer)
        XCTAssertEqual(drained.wait(timeout: .now() + 0.1), .timedOut)
        XCTAssertTrue(http.requests.isEmpty)
        source.gate = nil
        gate.signal()
        XCTAssertEqual(drained.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(uploaded().map { $0["exceptionId"] }, ["e1"])
    }

    func testAnExceptionClipOutsideTheSessionCountsAgainstItsBudget() {
        let clock = ManualClock()
        let c = controller(clock)
        onQueue {
            c.attach(ClipSource())
            c.apply(.stream, maxAgeMs: 600_000)
        }
        clock.advance(1000)
        XCTAssertTrue(onQueue { c.flush(lookbackMs: 30_000, exceptionId: "e1") })
        XCTAssertTrue(drain(c))
        XCTAssertNil(uploaded().first?["sessionId"])
        XCTAssertEqual(c.budget.snapshot("s1")["traceway.collection.events"], 1)
        XCTAssertEqual(c.budget.snapshot("s1")["traceway.collection.bytes"], 296)
    }

    func testAStreamingSessionUploadsWhatItHasWhenTheAppIsPaused() {
        let clock = ManualClock()
        let source = ClipSource()
        let c = controller(clock)
        onQueue {
            c.attach(source)
            c.apply(.stream, maxAgeMs: 600_000)
        }
        let started = clock.now()
        clock.advance(2500)
        onQueue { c.onPaused() }
        XCTAssertTrue(drain(c))
        XCTAssertEqual(source.captures.map { [$0.since, $0.until] }, [[started, started + 2500]])
        XCTAssertEqual(uploaded().map { $0["sessionId"] }, ["s1"])
        // A new session streams from its own start.
        clock.advance(1000)
        onQueue {
            c.onSessionStart()
            c.onPaused()
        }
        XCTAssertTrue(drain(c))
        XCTAssertEqual(source.captures.count, 1)
    }

    /// The field test's Home grid (ios-002): a fling every 2.5 s brings six
    /// new pictures. One segment's worth of them is more than its 128 KiB,
    /// but what is on screen at any time is far less. Every segment keeps
    /// the pictures it shows.
    func testAScrollingPictureGridKeepsItsPicturesInEverySegment() throws {
        let clock = ManualClock()
        let recorder = WireframeRecorder(maxFrames: 150, fps: 4, now: clock.now)
        #if canImport(UIKit)
        recorder.windows = { [] }
        #endif
        let c = controller(clock, segmentMs: 600_000)
        onQueue {
            c.attach(recorder)
            c.apply(.stream, maxAgeMs: 600_000)
        }
        var lingering: [Int] = []
        var everShown = Set<String>()
        for fling in 0..<4 {
            let shown = Array(fling * 6..<fling * 6 + 6)
            lingering += shown
            everShown.formUnion(shown.map { "p\($0)" })
            for _ in 0..<10 {
                recorder.push(WireframeFrame(screen: gridScreen(shown: shown, lingering: lingering), width: 390,
                                             height: 844, timestampMs: clock.now(), href: "/home"))
                clock.advance(250)
            }
        }
        onQueue { c.onPaused() }
        XCTAssertTrue(drain(c))

        let segments = uploaded()
        XCTAssertGreaterThan(segments.count, 1, "10 s of this grid do not fit one segment's allowance")
        var drawn = Set<String>()
        for (i, segment) in segments.enumerated() {
            let events = try XCTUnwrap(segment["events"]?.array)
            XCTAssertTrue(JSON.array(events).encoded().contains("data:image/jpeg"), "segment \(i) keeps its pictures")
            let pictures = replay(events).pictures()
            XCTAssertFalse(pictures.used.isEmpty)
            XCTAssertEqual(pictures.drawn.intersection(pictures.used), pictures.used, "segment \(i)")
            drawn.formUnion(pictures.drawn)
            if i > 0 { XCTAssertEqual(segment["startedAt"], segments[i - 1]["endedAt"], "segment \(i) starts where \(i - 1) ended") }
        }
        XCTAssertEqual(drawn, everShown)
        XCTAssertEqual(segments.compactMap { $0["segmentIndex"]?.int }, Array(0..<segments.count))
    }

    func testAttachingAnotherRecorderStopsThePreviousOne() {
        let first = ClipSource()
        let second = ClipSource()
        let c = controller()
        onQueue {
            c.attach(first)
            c.apply(.buffer, maxAgeMs: 600_000)
        }
        XCTAssertTrue(first.isRunning)
        onQueue { c.attach(second) }
        XCTAssertFalse(first.isRunning)
        XCTAssertTrue(second.isRunning)
        onQueue { c.attach(nil) }
        XCTAssertFalse(onQueue { c.flush(lookbackMs: 30_000, exceptionId: "e1") })
    }
}
