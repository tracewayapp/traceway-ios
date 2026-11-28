import Foundation
import XCTest
@testable import Traceway

final class MetricsRecorderTests: XCTestCase {
    func testAPayloadCarriesTheDeviceDimensionsAndNothingThatIdentifies() throws {
        let r = makeRecorder()
        r.recorder.setDimension("plan", "pro")
        r.recorder.setDimension("arm", "b")
        r.recorder.setDimension("third", "ignored")
        r.recorder.setDimension("Bad-Key", "ignored")
        r.recorder.sessionStarted("session-a")
        r.recorder.flush()
        let resource = r.decoded.resource()
        XCTAssertEqual(resource["traceway.metrics"], .string("aggregated"))
        XCTAssertEqual(resource["traceway.sample_rate"], .double(1))
        guard case .string? = resource["traceway.batch_id"] else { return XCTFail("batch id") }
        guard case .int? = resource["traceway.sent_at"] else { return XCTFail("sent at") }
        XCTAssertEqual(resource["service.name"], .string("shop"))
        XCTAssertEqual(resource["os.major"], .string("18"))
        XCTAssertEqual(resource["device.form_factor"], .string("phone"))
        XCTAssertEqual(resource["custom.plan"], .string("pro"))
        XCTAssertEqual(resource["custom.arm"], .string("b"))
        XCTAssertNil(resource["custom.third"])
        XCTAssertNil(resource["service.instance.id"])
        XCTAssertNil(resource["device.model"])
        XCTAssertEqual(r.decoded.sums, ["app.session": 1])
        XCTAssertEqual(r.decoded.requests.first?.resources.first?.scopes.first?.name, "traceway-ios")

        // A removed dimension frees its place.
        r.recorder.setDimension("plan", nil)
        r.recorder.setDimension("third", "now")
        r.recorder.count("cart.add")
        r.recorder.flush()
        let next = r.decoded.resource(1)
        XCTAssertNil(next["custom.plan"])
        XCTAssertEqual(next["custom.third"], .string("now"))
    }

    func testASessionIsCountedOnceAndNotAgainWhenItResumes() {
        let r = makeRecorder()
        r.recorder.sessionStarted("session-a")
        r.recorder.sessionStarted("session-a")
        r.recorder.sessionStarted("session-b", resumed: true)
        r.recorder.flush()
        XCTAssertEqual(r.decoded.sums, ["app.session": 1])
    }

    func testASessionOutsideTheSampleRecordsNothingOneInsideStatesItsRate() {
        let outside = sessionFor(rate: 0.5, sampled: false)
        let out = makeRecorder(overlay: ["metrics": ["sampleRate": 0.5]], session: { outside })
        out.recorder.sessionStarted(outside)
        out.recorder.request("https://api.shop.test/x", ms: 120, failed: false)
        out.recorder.flush()
        XCTAssertTrue(out.bodies.value.isEmpty)

        let inside = sessionFor(rate: 0.5, sampled: true)
        let r = makeRecorder(overlay: ["metrics": ["sampleRate": 0.5]], session: { inside })
        r.recorder.sessionStarted(inside)
        r.recorder.flush()
        XCTAssertEqual(r.decoded.resource()["traceway.sample_rate"], .double(0.5))
    }

    func testRequestsByHostWithFailuresAsARatioAndAtMost20Hosts() {
        let r = makeRecorder()
        r.recorder.request("https://api.shop.test/a", ms: 100, failed: false, responseBytes: 2048)
        r.recorder.request("https://api.shop.test:8443/b", ms: 300, failed: true)
        for i in 0..<25 { r.recorder.request("https://h\(i).test/", ms: 10, failed: false) }
        r.recorder.flush()
        let sums = r.decoded.sums
        XCTAssertEqual(sums["app.request.failed.total|host=api.shop.test"], 1)
        XCTAssertNil(sums["app.request.failed|host=api.shop.test"], "zero counts are not sent")
        XCTAssertEqual(sums["app.request.failed|host=api.shop.test:8443"], 1)
        XCTAssertEqual(sums["app.request.failed.total|host=other"], 7)
        let histograms = r.decoded.histograms
        XCTAssertEqual(histograms["app.request.duration|host=api.shop.test"]?.count, 1)
        XCTAssertEqual(histograms["app.request.bytes|host=api.shop.test"]?.sum, 2048)
    }

    func testHostsAreLowercaseWithoutDefaultPortsOrCredentials() {
        XCTAssertEqual(MetricsRecorder.hostOf("https://API.Shop.test:443/x?y#z"), "api.shop.test")
        XCTAssertEqual(MetricsRecorder.hostOf("http://user:pw@api.shop.test:8080"), "api.shop.test:8080")
        XCTAssertEqual(MetricsRecorder.hostOf("http://api.shop.test:80/"), "api.shop.test")
        XCTAssertEqual(MetricsRecorder.hostOf("http://[::1]:3000/a"), "[::1]:3000")
        XCTAssertEqual(MetricsRecorder.hostOf("https://h.test/a b|c"), "h.test")
        XCTAssertNil(MetricsRecorder.hostOf("/relative/path"))
        XCTAssertNil(MetricsRecorder.hostOf("https:///nohost"))
    }

    func testUsersAndAffectedUsersOnceADayOnlyWithLastingStorage() throws {
        let scheduler = ManualMetricsScheduler(nowMs: 20_000 * 86_400_000)
        let r = makeRecorder(persistent: true, scheduler: scheduler)
        r.recorder.start()
        r.recorder.crash()
        r.recorder.crash()
        r.recorder.hang(2500, screen: "/cart")
        r.recorder.flush()
        r.recorder.stop()
        XCTAssertEqual(r.decoded.sums, [
            "app.user": 1,
            "app.user.affected|issue=crash": 1,
            "app.user.affected|issue=hang": 1,
            "app.crash": 2,
            "app.hang|screen=/cart": 1,
        ])
        let hang = try XCTUnwrap(r.decoded.histograms["app.hang.duration|screen=/cart"])
        XCTAssertEqual(hang.exemplars.map { $0.filteredAttributes }, [["session.id": .string("session-a")]])

        r.bodies.value = []
        r.recorder.crash()
        r.recorder.flush()
        XCTAssertEqual(r.decoded.sums, ["app.crash": 1])

        scheduler.nowMs += 86_400_000
        r.bodies.value = []
        r.recorder.crash()
        r.recorder.flush()
        XCTAssertEqual(r.decoded.sums, ["app.user": 1, "app.user.affected|issue=crash": 1, "app.crash": 1])

        // A new run reads the day it was counted from the store.
        r.store.flush()
        let reloaded = StateStore(directory: r.directory)
        reloaded.load()
        let bodies = r.bodies
        let next = MetricsRecorder(
            settings: r.control.settings.activeMetrics,
            sessionId: { "session-b" },
            installationId: { "install-1" },
            resource: { [:] },
            send: { body in bodies.withValue { $0.append(body) }; return 200 },
            store: { reloaded },
            scheduler: scheduler
        )
        r.bodies.value = []
        next.crash()
        next.flush()
        XCTAssertEqual(r.decoded.sums, ["app.crash": 1])

        let memory = makeRecorder()
        memory.recorder.crash()
        memory.recorder.flush()
        XCTAssertEqual(memory.decoded.sums, ["app.crash": 1])
    }

    func testAFailedUploadIsResentOnceRestampedAndMarkedAsARetry() {
        let r = makeRecorder(statuses: [503, 200, 200])
        r.recorder.sessionStarted("session-a")
        r.recorder.flush()
        XCTAssertEqual(r.bodies.value.count, 1)
        r.scheduler.nowMs += 60_000
        r.recorder.crash()
        r.recorder.flush()
        XCTAssertEqual(r.bodies.value.count, 3, "the new payload, then the retry")
        let retry = r.decoded.resource(2)
        XCTAssertEqual(retry["traceway.retry"], .bool(true))
        XCTAssertEqual(retry["traceway.sent_at"], .int(r.scheduler.nowMs))
        XCTAssertEqual(r.decoded.resource(0)["traceway.batch_id"], retry["traceway.batch_id"])
        XCTAssertEqual(Decoded([r.bodies.value[2]]).sums, ["app.session": 1])
        r.recorder.flush()
        XCTAssertEqual(r.bodies.value.count, 3, "never a third attempt")
    }

    func testAPermanentRejectionIsNotResent() {
        let r = makeRecorder(statuses: [400, 200])
        r.recorder.sessionStarted("session-a")
        r.recorder.flush()
        r.recorder.crash()
        r.recorder.flush()
        XCTAssertEqual(r.bodies.value.count, 2)
        XCTAssertNil(r.store.get("metricsPending"))
    }

    func testAPayloadSentAsTheAppLeavesIsStoredUntilItIsAnswered() {
        let r = makeRecorder(statuses: [0, 200, 200])
        r.recorder.sessionStarted("session-a")
        r.recorder.flush(final: true)
        XCTAssertEqual(r.store.get("metricsPending")?.array?.count, 1)
        r.recorder.crash()
        r.recorder.flush()
        XCTAssertEqual(r.decoded.resource(2)["traceway.retry"], .bool(true))
        XCTAssertNil(r.store.get("metricsPending"))
    }

    func testEveryPayloadIsInTheStoreWhileItIsSent() {
        // A process killed during the request resends it on the next start.
        let stored = Locked<Int?>(nil)
        var holder: Recorded?
        let r = makeRecorder(onSend: { _ in stored.value = holder?.store.get("metricsPending")?.array?.count })
        holder = r
        r.recorder.sessionStarted("session-a")
        r.recorder.flush()
        XCTAssertEqual(stored.value, 1)
        XCTAssertNil(r.store.get("metricsPending"))

        // The next run of the app finds it and sends it once more.
        let left = makeRecorder(statuses: [0])
        left.recorder.sessionStarted("session-a")
        left.recorder.flush()
        let bodies = left.bodies
        let next = MetricsRecorder(
            settings: left.control.settings.activeMetrics,
            sessionId: { "session-b" },
            installationId: { "i" },
            resource: { [:] },
            send: { body in bodies.withValue { $0.append(body) }; return 200 },
            store: { left.store },
            scheduler: left.scheduler,
            deferUntilStart: true
        )
        next.start()
        next.stop()
        XCTAssertEqual(left.bodies.value.count, 2)
        XCTAssertEqual(left.decoded.resource(1)["traceway.retry"], .bool(true))
        XCTAssertNil(left.store.get("metricsPending"))
    }

    func testPendingPayloadsAreFewSmallAndShortLived() {
        let scheduler = ManualMetricsScheduler()
        let store = StateStore(directory: nil)
        let pending = PendingMetrics(now: { scheduler.now() }, scope: "dest")
        for i in 0..<5 { pending.add(store, id: "p\(i)", body: Data(repeating: UInt8(i), count: 10)) }
        XCTAssertEqual(pending.key, "metricsPending:dest")
        XCTAssertEqual(store.get(pending.key)?.array?.count, 3)
        for id in ["x", "y", "z"] {
            pending.add(store, id: id, body: Data(repeating: id.utf8.first!, count: 30 * 1024))
        }
        let ids = store.get(pending.key)?.array?.compactMap { $0["id"]?.string }
        XCTAssertEqual(ids, ["y", "z"], "three large payloads do not fit: the oldest goes")
        let taken = pending.take(store, skip: ["z"])
        XCTAssertEqual(taken.map { $0.id }, ["y"])
        XCTAssertEqual(taken.first?.body.first, "y".utf8.first)
        XCTAssertEqual(taken.first?.body.count, 30 * 1024)
        XCTAssertEqual(store.get(pending.key)?.array?.count, 1)
        scheduler.nowMs += 25 * 60 * 60 * 1000
        XCTAssertTrue(pending.take(store, skip: []).isEmpty, "a day later it is gone")
    }

    func testASampleRateChangeUploadsWhatWasTakenUnderTheOldRate() {
        let r = makeRecorder()
        r.recorder.sessionStarted("session-a")
        r.apply(settingsDocument(["metrics": ["sampleRate": 0.99]]))
        r.recorder.flush()
        XCTAssertEqual(r.bodies.value.count, 1)
        XCTAssertEqual(r.decoded.resource()["traceway.sample_rate"], .double(1))

        r.apply(settingsDocument(["metrics": ["enabled": false]]))
        r.recorder.crash()
        r.recorder.flush()
        XCTAssertEqual(r.bodies.value.count, 1, "switched off sends nothing more")
    }

    func testAPayloadOverTheBodyLimitIsSplitNothingLost() {
        let r = makeRecorder()
        // Every bucket from 2^-12 to 2^50: about 500 buckets a cell.
        for i in 0..<150 {
            for k in -96..<400 { r.recorder.aggregator.observe("custom_\(i)", pow(2, (Double(k) + 0.5) / 8)) }
        }
        r.recorder.flush()
        XCTAssertGreaterThan(r.bodies.value.count, 1)
        XCTAssertTrue(r.bodies.value.allSatisfy { $0.count <= maxMetricsBodyBytes })
        XCTAssertEqual(r.decoded.histograms.count, 150)
        XCTAssertEqual(r.decoded.histograms.values.reduce(0) { $0 + $1.count }, 150 * 496)
    }

    func testWhatIsObservedBeforeTheStartWaitsForTheFirstSession() {
        let session = Locked<String?>(nil)
        let r = makeRecorder(session: { session.value }, deferUntilStart: true)
        // The first frame and an earlier run's crash come before the SDK started.
        r.recorder.appStart(850, type: startCold, slow: false)
        r.recorder.screenDisplayed("/", ms: 40)
        r.recorder.crash()
        XCTAssertEqual(r.recorder.aggregator.size, 0)
        session.value = "session-a"
        r.recorder.sessionStarted("session-a")
        r.recorder.start()
        r.recorder.flush()
        r.recorder.stop()
        XCTAssertEqual(r.bodies.value.count, 1)
        XCTAssertEqual(r.decoded.sums, ["app.session": 1, "app.crash": 1])
        XCTAssertEqual(Set(r.decoded.histograms.keys), ["app.start.duration|start_type=cold", "app.screen.ttid|screen=/"])
    }

    func testCustomMetricsKeepToTheirNamesAndTwoDimensions() {
        let r = makeRecorder()
        r.recorder.metric("checkout.duration", 420, dims: ["plan": "pro", "b": 1, "c": 2])
        r.recorder.metric("app.start.duration", 1)
        r.recorder.metric("Bad Name", 1)
        r.recorder.metric(String(repeating: "a", count: 64), 1)
        r.recorder.count("cart.add", 2)
        r.recorder.flush()
        XCTAssertEqual(Array(r.decoded.histograms.keys), ["checkout.duration|b=1,c=2"])
        XCTAssertEqual(r.decoded.sums, ["cart.add": 2])
        XCTAssertTrue(MetricsRecorder.isCustomName(String(repeating: "a", count: 63)))
        XCTAssertFalse(MetricsRecorder.isCustomName("custom.x"))
        XCTAssertFalse(MetricsRecorder.isCustomName("1abc"))
    }

    func testTheTimerUploadsEveryFlushIntervalUntilStopped() {
        let r = makeRecorder(overlay: ["metrics": ["flushSeconds": 60]])
        r.recorder.start()
        r.recorder.crash()
        r.scheduler.advance(59_000)
        XCTAssertTrue(r.bodies.value.isEmpty)
        r.scheduler.advance(1_000)
        XCTAssertEqual(r.bodies.value.count, 1)
        r.recorder.crash()
        r.scheduler.advance(60_000)
        XCTAssertEqual(r.bodies.value.count, 2)
        r.recorder.stop()
        r.recorder.crash()
        r.scheduler.advance(120_000)
        XCTAssertEqual(r.bodies.value.count, 2)
        XCTAssertEqual(r.scheduler.pendingTimers, 0)
    }

    func testANewFlushIntervalTakesEffectAtOnce() {
        let r = makeRecorder()
        r.recorder.start()
        r.apply(settingsDocument(["metrics": ["flushSeconds": 30]]))
        r.recorder.crash()
        r.scheduler.advance(30_000)
        XCTAssertEqual(r.bodies.value.count, 1)
        r.recorder.stop()
    }

    func testUploadsRunOnTheUploadQueueAndCanBeAwaited() {
        let r = makeRecorder(scheduler: ManualMetricsScheduler(ioInline: false))
        r.recorder.crash()
        r.recorder.flush()
        XCTAssertTrue(r.bodies.value.isEmpty)
        XCTAssertFalse(r.recorder.awaitUploads(timeoutMs: 10))
        r.scheduler.runIo()
        XCTAssertEqual(r.bodies.value.count, 1)
        XCTAssertTrue(r.recorder.awaitUploads(timeoutMs: 0))
    }

    func testASendWithoutAnAnswerKeepsThePayload() {
        let store = StateStore(directory: nil)
        let recorder = MetricsRecorder(
            settings: MetricsSettings(),
            sessionId: { "session-a" },
            installationId: { "i" },
            resource: { [:] },
            send: { _ in 0 },
            store: { store },
            scheduler: ManualMetricsScheduler()
        )
        recorder.crash()
        recorder.flush()
        XCTAssertEqual(store.get("metricsPending")?.array?.count, 1)
    }

    func testRecordingFromManyThreadsLosesNothing() {
        let r = makeRecorder()
        DispatchQueue.concurrentPerform(iterations: 8) { t in
            for i in 0..<500 {
                r.recorder.request("https://h\(i % 5).test/", ms: Double(i), failed: i % 2 == 0)
                r.recorder.frames(screen: "/s\(t)", total: 10, slow: 1, frozen: 0)
                if i % 100 == 0 { r.recorder.flush() }
            }
        }
        r.recorder.flush()
        let sums = r.decoded.sums
        XCTAssertEqual((0..<5).reduce(0) { $0 + (sums["app.request.failed.total|host=h\($1).test"] ?? 0) }, 4000)
        XCTAssertEqual((0..<5).reduce(0) { $0 + (sums["app.request.failed|host=h\($1).test"] ?? 0) }, 2000)
        XCTAssertEqual((0..<8).reduce(0) { $0 + (sums["app.frames.slow.total|screen=/s\($1)"] ?? 0) }, 40_000)
        // Every payload has its own points: count all of them, not one per key.
        let durations = r.decoded.metrics.filter { $0.name == metricRequestDuration }.flatMap { $0.histogramPoints }
        XCTAssertEqual(durations.reduce(0) { $0 + $1.count }, 4000)
    }

    func testASessionThatEndedWhileTheAppWasNotRunningReportsItsPeakMemory() throws {
        let r = makeRecorder()
        let peak = Locked<Int64>(1000)
        let peaks = MemoryPeaks(recorder: r.recorder, store: { r.store }, storageScope: "dest",
                                readPeak: { peak.value })
        // An earlier run went to the background in "killed-session" and never came back.
        r.store.set("metricsMemory:dest", ["s": "killed-session", "b": 123_456_789])
        peaks.settle("session-a")
        XCTAssertNil(r.store.get("metricsMemory:dest"))
        r.recorder.flush()
        let memory = try XCTUnwrap(r.decoded.histograms["app.memory.peak"])
        XCTAssertEqual(memory.count, 1)
        XCTAssertEqual(memory.sum, 123_456_789)

        // Going to the background keeps this session's peak for later.
        peaks.remember("session-a")
        XCTAssertEqual(r.store.get("metricsMemory:dest"), ["s": "session-a", "b": 1000])
        peaks.settle("session-a")
        XCTAssertNotNil(r.store.get("metricsMemory:dest"), "the current session is not settled")
        peak.value = 500
        r.bodies.value = []
        peaks.ended("session-a")
        r.recorder.flush()
        XCTAssertEqual(r.decoded.histograms["app.memory.peak"]?.sum, 1000,
                       "the highest of this run and the remembered one")
        XCTAssertNil(r.store.get("metricsMemory:dest"))
    }

    func testTheMemoryPeakIsReadFromThePlatform() {
        let status = "Name:\tapp\nVmPeak:\t 999 kB\nVmHWM:\t  204800 kB\nVmRSS:\t 1000 kB\n"
        XCTAssertEqual(MemoryPeaks.parseVmHwmBytes(status), 204_800 * 1024)
        XCTAssertEqual(MemoryPeaks.parseVmHwmBytes("Name:\tapp\n"), 0)
        XCTAssertEqual(MemoryPeaks.parseVmHwmBytes("VmHWM:\tlots kB\n"), 0)
        // This test process holds at least a few megabytes.
        XCTAssertGreaterThan(MemoryPeaks.readPeakBytes(), 1 << 20)
    }
}
