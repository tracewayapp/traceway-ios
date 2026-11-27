import Foundation
import XCTest
@testable import Traceway

final class MetricsHistogramTests: XCTestCase {
    func testBucketsMatchTheServerAtEveryBoundary() {
        // Go: int32(math.Ceil(math.Log2(v)*8)) - 1
        let expected: [(Double, Int)] = [
            (1, -1), (2, 7), (8, 23), (16, 31), (1024, 79), (0.5, -9),
            (3, 12), (100, 53), (16.7, 32), (2500, 90), (1e9, 239),
        ]
        for (value, index) in expected { XCTAssertEqual(bucketIndex(value), index, "\(value)") }
        // Every power of two is a boundary, where log(x) / ln2 can be off by one.
        for k in -20...40 { XCTAssertEqual(bucketIndex(pow(2, Double(k))), 8 * k - 1, "2^\(k)") }
    }

    func testRecordsCountSumMinMaxAndZerosAndRefusesWhatItCannotHold() {
        var h = Histogram()
        for v in [0, 1.5, 100, 100] { XCTAssertTrue(h.record(v)) }
        XCTAssertFalse(h.record(-1))
        XCTAssertFalse(h.record(.nan))
        XCTAssertFalse(h.record(.infinity))
        XCTAssertEqual(h.count, 4)
        XCTAssertEqual(h.sum, 201.5)
        XCTAssertEqual(h.min, 0)
        XCTAssertEqual(h.max, 100)
        XCTAssertEqual(h.zeroCount, 1)
        XCTAssertEqual(h.buckets, [bucketIndex(1.5): 1, bucketIndex(100): 2])
    }
}

final class MetricsAggregatorTests: XCTestCase {
    func testCellsPerNameAndDimensionsAndDrainHandsThemOverOnce() throws {
        let a = MetricAggregator()
        a.observe("app.screen.ttid", 100, dims: ["screen": "/a"], unit: "ms")
        a.observe("app.screen.ttid", 300, dims: ["screen": "/a"], unit: "ms")
        a.observe("app.screen.ttid", 50, dims: ["screen": "/b"], unit: "ms")
        a.count("app.session")
        a.ratio("app.frames.slow", part: 3, total: 10)
        a.ratio("app.frames.slow", part: 5, total: 2) // part above total is clamped
        let batch = try XCTUnwrap(a.drain())
        XCTAssertEqual(batch.histograms.map { $0.histogram.count }, [2, 1])
        var sums: [String: Double] = [:]
        for sum in batch.sums { sums[sum.name] = sum.value }
        XCTAssertEqual(sums, ["app.session": 1, "app.frames.slow.total": 12, "app.frames.slow": 5])
        XCTAssertNil(a.drain())
    }

    func testPastTheCellLimitTheScreenFoldsToOtherThenCellsDrop() throws {
        let a = MetricAggregator(maxCells: 2)
        a.count("a")
        a.count("b")
        a.observe("app.screen.ttid", 1, dims: ["screen": "/x"])
        a.observe("app.screen.ttid", 2, dims: ["screen": "/y"])
        a.count("c")
        let batch = try XCTUnwrap(a.drain())
        XCTAssertEqual(batch.histograms.count, 1)
        XCTAssertEqual(batch.histograms.first?.dims, ["screen": "other"])
        XCTAssertEqual(batch.histograms.first?.histogram.count, 2)
        XCTAssertEqual(a.dropped, 1)
    }

    func testKeepsTheThreeHighestExemplars() throws {
        let a = MetricAggregator()
        for v in [5.0, 1, 9, 3, 7] { a.observe("app.hang.duration", v, exemplarSession: "s\(v)") }
        let exemplars = try XCTUnwrap(a.drain()?.histograms.first?.exemplars)
        XCTAssertEqual(Set(exemplars.map { $0.value }), [5, 9, 7])
    }
}

final class MetricsOtlpTests: XCTestCase {
    func testDeltaExponentialHistogramsAndMonotonicSums() throws {
        let a = MetricAggregator(now: { 1_700_000_000_000 })
        a.observe("app.start.duration", 1200, dims: ["start_type": "cold"], unit: "ms", exemplarSession: "sess")
        a.observe("app.start.duration", 1300, dims: ["start_type": "cold"], unit: "ms")
        a.count("app.session", 2)
        let body = encodeMetrics(try XCTUnwrap(a.drain()), resource: ["service.name": .string("shop"), "n": .int(1)],
                                 scopeName: "traceway-ios", scopeVersion: "9")
        let request = try OtlpDecoder.request(body)
        XCTAssertEqual(request.resources.count, 1)
        let rm = request.resources[0]
        XCTAssertEqual(rm.attributes, ["service.name": .string("shop"), "n": .int(1)])
        XCTAssertEqual(rm.scopes.count, 1)
        let scope = rm.scopes[0]
        XCTAssertEqual(scope.name, "traceway-ios")
        XCTAssertEqual(scope.version, "9")
        let histogram = try XCTUnwrap(scope.metrics.first { $0.name == "app.start.duration" })
        XCTAssertEqual(histogram.unit, "ms")
        XCTAssertEqual(histogram.temporality, temporalityDelta)
        XCTAssertEqual(histogram.histogramPoints.count, 1)
        let point = histogram.histogramPoints[0]
        XCTAssertEqual(point.scale, histogramScale)
        XCTAssertEqual(point.count, 2)
        XCTAssertEqual(point.sum, 2500)
        XCTAssertEqual(point.min, 1200)
        XCTAssertEqual(point.max, 1300)
        XCTAssertEqual(Int(point.offset), bucketIndex(1200))
        XCTAssertEqual(point.bucketCounts.reduce(0, +), 2)
        XCTAssertEqual(point.timeNanos, 1_700_000_000_000 * 1_000_000)
        XCTAssertEqual(point.attributes, ["start_type": .string("cold")])
        XCTAssertEqual(point.exemplars.count, 1)
        XCTAssertEqual(point.exemplars.first?.filteredAttributes, ["session.id": .string("sess")])
        XCTAssertEqual(point.exemplars.first?.value, 1200)
        let sum = try XCTUnwrap(scope.metrics.first { $0.kind == "sum" })
        XCTAssertTrue(sum.monotonic)
        XCTAssertEqual(sum.temporality, temporalityDelta)
        XCTAssertEqual(sum.sumPoints.map { $0.value }, [2])
    }

    func testAHistogramOfOnlyZerosHasNoBuckets() throws {
        let a = MetricAggregator()
        a.observe("checkout.duration", 0)
        let body = encodeMetrics(try XCTUnwrap(a.drain()), resource: [:], scopeName: "s", scopeVersion: "v")
        let point = try XCTUnwrap(Decoded([body]).histograms.values.first)
        XCTAssertEqual(point.count, 1)
        XCTAssertEqual(point.zeroCount, 1)
        XCTAssertTrue(point.bucketCounts.isEmpty)
    }

    func testAResendIsRestampedAndMarkedAndKeepsEverythingElse() throws {
        let a = MetricAggregator()
        a.count("app.crash")
        let original = encodeMetrics(
            try XCTUnwrap(a.drain()),
            resource: ["traceway.batch_id": .string("b1"), attrSentAt: .int(1000), "traceway.sample_rate": .double(0.5)],
            scopeName: "s", scopeVersion: "v"
        )
        let once = try XCTUnwrap(restampForRetry(original, sentAtMs: 5000))
        let twice = try XCTUnwrap(restampForRetry(once, sentAtMs: 9000))
        for (body, sentAt) in [(once, Int64(5000)), (twice, Int64(9000))] {
            let decoded = Decoded([body])
            let resource = decoded.resource()
            XCTAssertEqual(resource["traceway.batch_id"], .string("b1"))
            XCTAssertEqual(resource["traceway.sample_rate"], .double(0.5))
            XCTAssertEqual(resource[attrSentAt], .int(sentAt))
            XCTAssertEqual(resource[attrRetry], .bool(true))
            XCTAssertEqual(resource.count, 4)
            XCTAssertEqual(decoded.sums, ["app.crash": 1])
        }
        XCTAssertNil(restampForRetry(Data([0x0a, 0x7f]), sentAtMs: 1))
    }
}

final class MetricsRouteTests: XCTestCase {
    func testRoutePathsNormalizeLikeTheServer() {
        // The table of backend/app/clientmetrics/route_test.go.
        let table: [(String, String)] = [
            ("/", "/"),
            ("", "/"),
            ("/orders/8841", "/orders/:id"),
            ("/orders/8841/", "/orders/:id"),
            ("/orders/8841?x=1#y", "/orders/:id"),
            ("/u/3f2b8c1e-9a4d-4c7e-8b1a-2d3e4f5a6b7c/edit", "/u/:id/edit"),
            ("/commit/9fceb02d0ae598e9", "/commit/:id"),
            ("/reset/dGhpcyBpcyBhIHRva2VuIHZhbHVl0", "/reset/:id"),
            ("/products/blue-suede-shoes", "/products/blue-suede-shoes"),
            ("/deadbeef", "/deadbeef"),
            ("/a/b/c/d/e/f/g/h", "/a/b/c/d/e/f/*"),
            ("/search/hello%20world", "/search/:id"),
            ("/endpoints/POST%20%2Ftasks%2F%7BtaskId%7D/9fceb02d0ae598e9", "/endpoints/:id/:id"),
            ("/caf%C3%A9/menu", "/caf%C3%A9/menu"),
            ("/:lang?/about", "/:lang?/about"),
            ("/:locale(en|fr)?/products/:slug", "/:locale(en|fr)?/products/:slug"),
            ("/users/:id?", "/users/:id"),
            ("/orders/8841?/next", "/orders/:id"),
            ("/products/:slug()", "/products/:slug()"),
            ("/docs/:slug(.*)*", "/docs/:slug(.*)*"),
            ("/docs/:slug*", "/docs/:slug*"),
            ("/posts/$postId", "/posts/$postId"),
            ("/posts/[id]", "/posts/[id]"),
            ("/CheckoutViewController", "/CheckoutViewController"),
        ]
        for (input, want) in table { XCTAssertEqual(normalizePath(input), want, input) }
        let long = normalizePath("/" + String(repeating: "segment-that-is-long/", count: 8))
        XCTAssertLessThanOrEqual(long.count, 64)
        XCTAssertTrue(long.hasSuffix("/*"))
    }
}

final class MetricsSettingsTests: XCTestCase {
    func testMetricsSettingsMergeClampAndObeyTheKillSwitchAndLimits() {
        var control = ControlState(defaults: defaultSettings(), ceilings: ceilingsFrom())
        XCTAssertEqual(control.settings.activeMetrics?.sampleRate, 1)
        XCTAssertEqual(control.settings.activeMetrics?.flushSeconds, 300)
        control.applyRemote(settingsDocument(["metrics": ["sampleRate": 0.25, "flushSeconds": 5]]))
        XCTAssertEqual(control.settings.activeMetrics?.sampleRate, 0.25)
        XCTAssertEqual(control.settings.activeMetrics?.flushSeconds, minMetricsFlushSeconds)
        control.applyRemote(settingsDocument(["metrics": ["flushSeconds": 99_999]]))
        XCTAssertEqual(control.settings.activeMetrics?.flushSeconds, maxMetricsFlushSeconds)
        control.applyRemote(settingsDocument(["metrics": ["enabled": false]]))
        XCTAssertNil(control.settings.activeMetrics)
        control.applyRemote(settingsDocument(["enabled": false]))
        XCTAssertNil(control.settings.activeMetrics)
        control.applyRemote(settingsDocument(["limits": ["metrics": "off"], "metrics": ["enabled": true]]))
        XCTAssertNil(control.settings.activeMetrics)

        control = ControlState(defaults: defaultSettings(), ceilings: ceilingsFrom(captureMetrics: false))
        control.applyRemote(settingsDocument(["metrics": ["enabled": true]]))
        XCTAssertNil(control.settings.activeMetrics)
    }

    func testALocalCollectionDocumentSetsTheMetricsDefaults() throws {
        let local = try parseSettingsDocument(#"{"metrics":{"sampleRate":0.5,"flushSeconds":60,"enabled":"yes"}}"#)
        let settings = applyOverlay(defaultSettings(), local)
        XCTAssertEqual(settings.metrics, MetricsSettings(enabled: true, sampleRate: 0.5, flushSeconds: 60))
    }
}

final class MetricsCatalogTests: XCTestCase {
    func testEveryMetricTheSdkSendsIsOneTheServerKnows() {
        // backend/app/clientmetrics/catalog.go
        let catalog: Set<String> = [
            "app.start.duration", "app.screen.ttid", "app.screen.ttfd",
            "app.frames.slow", "app.frames.slow.total", "app.frames.frozen",
            "app.frames.frozen.total", "app.hang", "app.hang.duration", "app.crash",
            "app.session", "app.user", "app.user.affected", "app.memory.peak",
            "app.request.duration", "app.request.bytes", "app.request.failed",
            "app.request.failed.total",
        ]
        let names: Set<String> = [
            metricAppStart, metricScreenTTID, metricScreenTTFD,
            metricFramesSlow, "\(metricFramesSlow).total", metricFramesFrozen, "\(metricFramesFrozen).total",
            metricHang, metricHangDuration, metricCrash, metricSession, metricUser, metricUserAffected,
            metricMemoryPeak, metricRequestDuration, metricRequestBytes, metricRequestFailed,
            "\(metricRequestFailed).total",
        ]
        XCTAssertTrue(names.isSubset(of: catalog))
        // start_type and issue values the catalog accepts.
        XCTAssertTrue(Set([startCold, startWarm, startHot]).isSubset(of: ["cold", "warm", "hot"]))
        XCTAssertTrue(Set(UserIssue.allCases.map { $0.rawValue })
            .isSubset(of: ["crash", "anr", "hang", "oom", "slow_start", "frozen_frames", "failed_request"]))
    }

    func testDeviceDimensionsUseTheServersClosedSets() {
        let gb: Int64 = 1024 * 1024 * 1024
        XCTAssertEqual(DeviceDimensions.deviceClass(totalBytes: 2 * gb + gb / 2), "low")
        XCTAssertEqual(DeviceDimensions.deviceClass(totalBytes: 5 * gb), "mid")
        XCTAssertEqual(DeviceDimensions.deviceClass(totalBytes: 8 * gb), "high")
        XCTAssertNil(DeviceDimensions.deviceClass(totalBytes: 0))
        XCTAssertTrue(["low", "mid", "high"].contains(DeviceDimensions.collect()["device.class"] ?? ""))
        XCTAssertTrue(Set(["os.major", "device.form_factor", "device.class"]).isSubset(of: Set(metricResourceKeys)))
    }
}
