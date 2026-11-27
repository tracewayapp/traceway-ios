import Foundation
import XCTest
#if !os(iOS)
import OpenTelemetryApi
import OpenTelemetrySdk
#endif
@testable import Traceway

/// IOS2-6: the async `run` of an interaction, across suspension points. On
/// Apple platforms OpenTelemetry keeps the active span in an `os_activity`
/// scope, which belongs to a thread, while the code after an `await` may
/// resume on another; on Linux it is a task-local. The records made after
/// the `await` must still belong to the interaction, and nothing may stay
/// active once `run` returns. Runs on Linux, the macOS host and the iOS
/// Simulator (the span checks, which need OpenTelemetry's types, everywhere
/// but the Simulator).
final class TracewayInteractionAsyncTests: XCTestCase {
    private var server: FakeServer!

    override func setUp() {
        super.setUp()
        TracewayClient.resetForTesting()
        server = FakeServer()
    }

    override func tearDown() {
        TracewayClient.resetForTesting()
        super.tearDown()
    }

    private func bytes(hex: String) -> Data {
        var out = Data()
        var index = hex.startIndex
        while index < hex.endIndex, let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) {
            if let byte = UInt8(hex[index..<next], radix: 16) { out.append(byte) }
            index = next
        }
        return out
    }

    /// The OTLP logs request that carried `marker` (protobuf keeps strings
    /// as their UTF-8 bytes).
    private func request(with marker: String) -> Data? {
        let needle = Data(marker.utf8)
        for request in server.requests(to: "/api/otel/v1/logs") {
            var body = request.body
            if request.headers["Content-Encoding"] == "gzip", let plain = Gzip.decompress(body) { body = plain }
            if body.range(of: needle) != nil { return body }
        }
        return nil
    }

    func testRecordsAfterAnAwaitInAnAsyncRunCarryTheInteraction() async throws {
        let client = try TracewayClient.start(
            token: "token", baseUrl: "https://traceway.example.com",
            options: TracewayOptions(remoteConfig: false, exportDelayMs: 50),
            overrides: TracewayTestOverrides(transport: server, deviceAttributes: ["os.name": "ios"])
        )
        let checkout = Traceway.startInteraction("checkout")
        let traceId = try XCTUnwrap(checkout.traceId)
        try await checkout.run {
            await Task.yield()
            try await Task.sleep(nanoseconds: 50_000_000)
            Traceway.captureMessage("after-the-await")
        }
        checkout.end()
        client.flush(timeout: 5)
        XCTAssertTrue(eventually { self.request(with: "after-the-await") != nil })
        let inside = try XCTUnwrap(request(with: "after-the-await"))
        XCTAssertNotNil(inside.range(of: bytes(hex: traceId)),
                        "a message captured after an await in run carries the interaction's trace")

        // Once run has returned, nothing of it stays active: not on the main
        // thread, not on the threads the task ran on.
        await MainActor.run { Traceway.captureMessage("on-main-after-run") }
        await Task.detached { Traceway.captureMessage("detached-after-run") }.value
        client.flush(timeout: 5)
        XCTAssertTrue(eventually {
            self.request(with: "on-main-after-run") != nil && self.request(with: "detached-after-run") != nil
        })
        for marker in ["on-main-after-run", "detached-after-run"] {
            let body = try XCTUnwrap(request(with: marker))
            if body.range(of: Data("after-the-await".utf8)) == nil {
                XCTAssertNil(body.range(of: bytes(hex: traceId)), "\(marker) belongs to no interaction")
            }
        }
    }

    #if !os(iOS)
    /// Spans made after an `await` are children of the interaction, and
    /// none made after `run` returned is.
    func testSpansAfterAnAwaitAreChildrenAndNothingStaysActive() async throws {
        let spans = MemorySpanExporter()
        let client = try TracewayClient.start(
            token: "token", baseUrl: "https://traceway.example.com",
            options: TracewayOptions(recordAllSessions: true, remoteConfig: false, exportDelayMs: 50),
            overrides: TracewayTestOverrides(logExporter: MemoryLogExporter(), spanExporter: spans,
                                             transport: server, deviceAttributes: ["os.name": "ios"])
        )
        let checkout = Traceway.startInteraction("checkout")
        let spanId = try XCTUnwrap(checkout.spanId)
        try await checkout.run {
            Traceway.tracer?.spanBuilder(spanName: "before-the-await").startSpan().end()
            await Task.yield()
            try await Task.sleep(nanoseconds: 50_000_000)
            Traceway.tracer?.spanBuilder(spanName: "after-the-await").startSpan().end()
        }
        checkout.end()
        let activeOnMain = await MainActor.run { () -> Bool in
            Traceway.tracer?.spanBuilder(spanName: "on-main-after-run").startSpan().end()
            return OpenTelemetry.instance.contextProvider.activeSpan != nil
        }
        XCTAssertFalse(activeOnMain, "no span stays active on the main thread")
        await Task.detached { Traceway.tracer?.spanBuilder(spanName: "detached-after-run").startSpan().end() }.value
        client.flush(timeout: 5)
        XCTAssertTrue(eventually { spans.spans.contains { $0.name == "detached-after-run" } })
        func parent(_ name: String) -> String? {
            spans.spans.first { $0.name == name }?.parentSpanId?.hexString
        }
        XCTAssertEqual(parent("before-the-await"), spanId)
        XCTAssertEqual(parent("after-the-await"), spanId, "a span after an await is the interaction's child")
        XCTAssertNil(parent("on-main-after-run"))
        XCTAssertNil(parent("detached-after-run"))
    }
    #endif
}
