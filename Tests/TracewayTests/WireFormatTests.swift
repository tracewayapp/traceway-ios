import XCTest
@testable import Traceway

final class WireFormatTests: XCTestCase {

    func testReportRequestShape() {
        let request = ReportRequest(
            collectionFrames: [CollectionFrame(stackTraces: [])],
            appVersion: "9.9.9",
            serverName: "srv-1"
        )
        let expected = #"{"collectionFrames":[{"stackTraces":[],"metrics":[],"traces":[]}],"appVersion":"9.9.9","serverName":"srv-1"}"#
        XCTAssertEqual(request.serialized(), expected)
    }

    func testCollectionFrameOmitsSessionRecordingsAndEmitsEmptyArrays() {
        let frame = CollectionFrame(stackTraces: [])
        let json = frame.toJSON().serialize()
        XCTAssertFalse(json.contains("sessionRecordings"), "sessionRecordings must be absent")
        XCTAssertEqual(json, #"{"stackTraces":[],"metrics":[],"traces":[]}"#)
    }

    func testExceptionStackTraceJsonShape() {
        let exception = ExceptionStackTrace(
            stackTrace: "java.lang.IllegalStateException: boom\n  at X",
            recordedAtMs: 1_700_000_000_000,
            attributes: ["device.model": "Pixel 8"],
            isMessage: false,
            sessionRecordingId: "rec-id"
        )

        let expected = #"{"traceId":null,"isTask":false,"stackTrace":"java.lang.IllegalStateException: boom\n  at X","recordedAt":"2023-11-14T22:13:20.000Z","attributes":{"device.model":"Pixel 8"},"isMessage":false,"sessionRecordingId":"rec-id","distributedTraceId":null}"#
        XCTAssertEqual(exception.toJSON().serialize(), expected)
    }

    func testNullIdsAreEmittedAsLiteralNull() {
        let exception = ExceptionStackTrace(stackTrace: "boom", recordedAtMs: 0)
        let json = exception.toJSON().serialize()
        XCTAssertTrue(json.contains("\"traceId\":null"))
        XCTAssertTrue(json.contains("\"sessionRecordingId\":null"))
        XCTAssertTrue(json.contains("\"distributedTraceId\":null"))
        XCTAssertTrue(json.contains("\"attributes\":{}"))
    }

    func testAttributesAreSerializedInDeterministicSortedOrder() {
        let exception = ExceptionStackTrace(
            stackTrace: "boom",
            recordedAtMs: 0,
            attributes: ["b": "2", "a": "1", "c": "3"]
        )
        let json = exception.toJSON().serialize()
        XCTAssertTrue(json.contains(#""attributes":{"a":"1","b":"2","c":"3"}"#))
    }

    func testStringEscaping() {
        let exception = ExceptionStackTrace(
            stackTrace: "tab\tquote\"backslash\\",
            recordedAtMs: 0
        )
        let json = exception.toJSON().serialize()
        XCTAssertTrue(json.contains(#"tab\tquote\"backslash\\"#))
    }
}
