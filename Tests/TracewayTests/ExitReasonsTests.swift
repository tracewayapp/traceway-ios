import Foundation
import XCTest
@testable import Traceway

private final class FixtureToken {}

/// A MetricKit payload of `Resources/MetricKit`, as `jsonRepresentation()`
/// gives it.
func metricKitFixture(_ name: String) throws -> Data {
    #if SWIFT_PACKAGE
    let bundled = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "MetricKit")
    #else
    let bundle = Bundle(for: FixtureToken.self)
    let bundled = bundle.url(forResource: name, withExtension: "json", subdirectory: "MetricKit")
        ?? bundle.url(forResource: name, withExtension: "json")
    #endif
    let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Resources/MetricKit/\(name).json")
    let url = try XCTUnwrap(bundled ?? (FileManager.default.fileExists(atPath: source.path) ? source : nil),
                            "fixture \(name)")
    return try Data(contentsOf: url)
}

/// CONTRACT §14.1 without a device: MetricKit's JSON, which crashes are the
/// SDK's own already, and the next-launch out-of-memory heuristic.
final class ExitReasonsTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC") ?? TimeZone.current

    // MARK: - MetricKit payloads

    func testAMetricKitSignalCrashIsReadFromItsCrashedThread() throws {
        let crashes = MetricKitDiagnostics.parseCrashes(try metricKitFixture("crash-signal"), timeZone: utc)
        XCTAssertEqual(crashes.count, 1)
        let crash = try XCTUnwrap(crashes.first)
        XCTAssertEqual(crash.signal, 11)
        XCTAssertEqual(crash.exceptionType, 1)
        XCTAssertEqual(crash.signals, [11])
        XCTAssertFalse(crash.isWatchdogTermination)
        XCTAssertEqual(crash.appVersion, "1.4.0")
        XCTAssertEqual(crash.appBuild, "42")
        XCTAssertEqual(crash.deviceType, "iPhone15,2")
        XCTAssertEqual(crash.osVersion.flatMap(MetricKitDiagnostics.osVersionNumber), "17.2")
        XCTAssertEqual(crash.begin, Date(timeIntervalSince1970: 1_795_171_740))
        // The attributed thread (the second), innermost first.
        XCTAssertEqual(crash.frames.map { $0.binaryName }, ["ShopApp", "ShopApp", "UIKitCore"])
        XCTAssertEqual(crash.frames.first?.uuid, "70b89f2716343580a69557cdb41d7743")
        XCTAssertEqual(crash.frames.first?.offset, 165_304)
        XCTAssertEqual(crash.issueType, "NativeCrash")
        XCTAssertEqual(crash.issueMessage, "SIGSEGV (EXC_BAD_ACCESS)")
        XCTAssertEqual(crash.stackTrace, """
        NativeCrash: SIGSEGV (EXC_BAD_ACCESS)
        *** *** *** *** *** *** *** *** *** *** *** *** *** *** *** ***
        os: ios arch: arm64
        #00 70b89f2716343580a69557cdb41d7743 0x285b8 ShopApp
        #01 70b89f2716343580a69557cdb41d7743 0x27100 ShopApp
        #02 a1b2c3d4e5f60718293a4b5c6d7e8f90 0x800 UIKitCore
        """)
    }

    func testAWatchdogTerminationIsItsOwnIssueType() throws {
        let crash = try XCTUnwrap(MetricKitDiagnostics.parseCrashes(try metricKitFixture("watchdog"), timeZone: utc).first)
        XCTAssertTrue(crash.isWatchdogTermination)
        XCTAssertEqual(crash.signal, 9)
        XCTAssertEqual(crash.issueType, "WatchdogTermination")
        XCTAssertEqual(crash.issueMessage,
                       "The system ended the app for not responding in time (Namespace SPRINGBOARD, Code 0x8badf00d)")
        XCTAssertTrue(crash.stackTrace.hasPrefix("WatchdogTermination: The system ended the app"))
        XCTAssertTrue(crash.stackTrace.contains("#01 70b89f2716343580a69557cdb41d7743 0x55e10 ShopApp"))
    }

    func testAnUncaughtObjectiveCExceptionNamesItselfInTheMessage() throws {
        let crash = try XCTUnwrap(MetricKitDiagnostics.parseCrashes(try metricKitFixture("objc-exception"),
                                                                    timeZone: utc).first)
        XCTAssertEqual(crash.exceptionName, "NSInvalidArgumentException")
        XCTAssertEqual(crash.issueType, "NativeCrash")
        XCTAssertEqual(crash.issueMessage, "SIGABRT (EXC_CRASH), uncaught NSInvalidArgumentException: "
            + "-[NSNull length]: unrecognized selector sent to instance 0x1f2e3d4c0")
        XCTAssertEqual(crash.signals, [6])
        // The window spans the minute the payload names.
        XCTAssertEqual(crash.end.timeIntervalSince(crash.begin), 60)
    }

    func testThePayloadsOwnDatesWinOverItsText() throws {
        let begin = Date(timeIntervalSince1970: 1_800_000_000)
        let crash = try XCTUnwrap(MetricKitDiagnostics.parseCrashes(
            try metricKitFixture("crash-signal"), begin: begin, end: begin.addingTimeInterval(5)
        ).first)
        XCTAssertEqual(crash.begin, begin)
        XCTAssertEqual(crash.end, begin.addingTimeInterval(5))
        XCTAssertEqual(MetricKitDiagnostics.timestamp("2026-11-20 10:49:00 +0100", timeZone: utc),
                       Date(timeIntervalSince1970: 1_795_168_140))
    }

    func testPayloadsTheParserCannotUseGiveNothing() {
        for text in ["", "{", "[]", "null", #"{"crashDiagnostics":[]}"#,
                     #"{"crashDiagnostics":[{"callStackTree":"x"}]}"#,
                     #"{"timeStampBegin":"not a date","crashDiagnostics":[{}]}"#] {
            XCTAssertTrue(MetricKitDiagnostics.parseCrashes(Data(text.utf8)).isEmpty, text)
        }
        // Wrong types and absurd numbers are left out, not trusted.
        let odd = #"""
        {"timeStampBegin":"2026-11-20 10:49:00","crashDiagnostics":[{"diagnosticMetaData":{"signal":"11",
        "exceptionType":1e300,"terminationReason":7},"callStackTree":{"callStacks":[{"callStackRootFrames":[
        {"binaryUUID":"not-a-uuid","offsetIntoBinaryTextSegment":-5,"address":1e300,"binaryName":3}]}]}}]}
        """#
        let crash = MetricKitDiagnostics.parseCrashes(Data(odd.utf8), timeZone: utc).first
        XCTAssertNil(crash?.signal)
        XCTAssertNil(crash?.exceptionType)
        XCTAssertEqual(crash?.frames, [MetricKitFrame(uuid: nil, offset: nil, address: nil, binaryName: nil)])
        XCTAssertTrue(crash?.stackTrace.contains("#00 00000000000000000000000000000000 0x0 <unknown>") == true)
        // A long stack is read without recursion, and one deeper than any
        // real one is cut.
        var nested = #"{"binaryName":"x"}"#
        for _ in 0..<199 { nested = #"{"binaryName":"x","subFrames":[\#(nested)]}"# }
        let long = #"{"timeStampBegin":"2026-11-20 10:49:00","crashDiagnostics":[{"callStackTree":{"callStacks":[{"callStackRootFrames":[\#(nested)]}]}}]}"#
        XCTAssertEqual(MetricKitDiagnostics.parseCrashes(Data(long.utf8), timeZone: utc).first?.frames.count, 200)
        var frame: JSON = ["binaryName": "x"]
        for _ in 0..<600 { frame = ["binaryName": "x", "subFrames": [frame]] }
        let tree: [String: JSON] = ["callStacks": [["callStackRootFrames": [frame]]]]
        XCTAssertEqual(MetricKitDiagnostics.crashedThreadFrames(tree).count, MetricKitDiagnostics.maxFrames)
    }

    // MARK: - The SDK's own records win

    func testACrashTheSignalHandlerRecordedIsNotReportedAgain() throws {
        let crash = try XCTUnwrap(MetricKitDiagnostics.parseCrashes(try metricKitFixture("crash-signal"),
                                                                    timeZone: utc).first)
        let at = millisecondsSaturating(crash.begin.timeIntervalSince1970)
        func recorded(_ signal: Int, _ offsetMs: Int64, _ kind: ExitLedgerEntry.Kind = .signal) -> Bool {
            ExitReasons.recordedInProcess(crash, ledger: [ExitLedgerEntry(kind: kind, signal: signal, ms: at + offsetMs)])
        }
        XCTAssertTrue(recorded(11, 30_000))
        XCTAssertTrue(recorded(11, -59_000), "within a minute of the window")
        XCTAssertFalse(recorded(11, 61_000))
        XCTAssertFalse(recorded(11, -61_000))
        XCTAssertFalse(recorded(6, 0), "another signal is another crash")
        XCTAssertFalse(recorded(0, 0, .hang), "a hang is not a crash")
        XCTAssertFalse(ExitReasons.recordedInProcess(crash, ledger: []))

        // An uncaught NSException is recorded as the SIGABRT that follows it.
        let objc = try XCTUnwrap(MetricKitDiagnostics.parseCrashes(try metricKitFixture("objc-exception"),
                                                                   timeZone: utc).first)
        let objcAt = millisecondsSaturating(objc.begin.timeIntervalSince1970) + 45_000
        XCTAssertTrue(ExitReasons.recordedInProcess(objc, ledger: [ExitLedgerEntry(kind: .exception, signal: 6, ms: objcAt)]))

        // Without a signal, the Mach exception says which ones it would be.
        var noSignal = crash
        noSignal.signal = nil
        XCTAssertEqual(noSignal.signals, [11, 10])
        noSignal.exceptionType = 6
        XCTAssertEqual(noSignal.signals, [5], "a Swift trap is EXC_BREAKPOINT, SIGTRAP")
    }

    func testAWatchdogAfterAReportedFatalHangIsNotASecondIssue() throws {
        let crash = try XCTUnwrap(MetricKitDiagnostics.parseCrashes(try metricKitFixture("watchdog"), timeZone: utc).first)
        let at = millisecondsSaturating(crash.end.timeIntervalSince1970)
        XCTAssertTrue(ExitReasons.fatalHangReported(crash, ledger: [ExitLedgerEntry(kind: .hang, signal: 0, ms: at - 20_000)]))
        XCTAssertFalse(ExitReasons.fatalHangReported(crash, ledger: [ExitLedgerEntry(kind: .hang, signal: 0, ms: at - 3_600_000)]))
        XCTAssertFalse(ExitReasons.fatalHangReported(crash, ledger: [ExitLedgerEntry(kind: .signal, signal: 9, ms: at)]))
    }

    func testTheLedgerKeepsTheNewestWeekAndAtMost32() {
        let now: Int64 = 1_800_000_000_000
        var ledger: [ExitLedgerEntry] = [ExitLedgerEntry(kind: .signal, signal: 11, ms: now - 9 * 86_400_000)]
        for i in 0..<40 {
            ledger = ExitReasons.appending(ExitLedgerEntry(kind: .signal, signal: 11, ms: now - Int64(40 - i)),
                                           to: ledger, nowMs: now)
        }
        XCTAssertEqual(ledger.count, ExitReasons.maxLedgerEntries)
        XCTAssertEqual(ledger.last?.ms, now - 1)
        XCTAssertTrue(ledger.allSatisfy { $0.ms > now - 86_400_000 })
        let decoded = ExitReasons.ledger(.array(ledger.map { $0.encoded() } + ["garbage", ["kind": "nope", "ms": 1]]))
        XCTAssertEqual(decoded, ledger)
    }

    // MARK: - The next-launch heuristic

    private func run(_ change: (inout RunRecord) -> Void = { _ in }) -> RunRecord {
        var record = RunRecord(startedAtMs: 1_800_000_000_000, appVersion: "1.4.0", appBuild: "42",
                               osVersion: "17.2", bootTimeSec: 1_799_000_000, foreground: true,
                               debugger: false, sessionId: "s1")
        change(&record)
        return record
    }

    func testTheOutOfMemoryHeuristicNeedsEveryCondition() {
        let current = run { $0.startedAtMs += 60_000; $0.foreground = false; $0.bootTimeSec = 1_799_000_002 }
        func oom(_ previous: RunRecord?, exited: Bool = false, crashed: Bool = false) -> Bool {
            ExitReasons.likelyOutOfMemory(previous: previous, current: current, exited: exited, crashRecorded: crashed)
        }
        XCTAssertTrue(oom(run()))
        XCTAssertFalse(oom(nil), "no last run")
        XCTAssertFalse(oom(run { $0.foreground = false }), "it was in the background")
        XCTAssertFalse(oom(run(), crashed: true), "a crash was recorded")
        XCTAssertFalse(oom(run { $0.shutdown = true }), "it shut the SDK down")
        XCTAssertFalse(oom(run { $0.terminated = true }), "it was told it terminates")
        XCTAssertFalse(oom(run(), exited: true), "it called exit")
        XCTAssertFalse(oom(run { $0.debugger = true }), "a debugger was attached")
        XCTAssertFalse(oom(run { $0.appVersion = "1.3.9" }), "the app was updated")
        XCTAssertFalse(oom(run { $0.appBuild = "41" }), "the build changed")
        XCTAssertFalse(oom(run { $0.osVersion = "17.1" }), "the OS was updated")
        XCTAssertFalse(oom(run { $0.bootTimeSec = 1_798_000_000 }), "the device restarted")
        XCTAssertTrue(oom(run { $0.bootTimeSec = nil }), "an unknown boot does not decide")
    }

    func testARunRecordSurvivesItsEncoding() throws {
        let record = run { $0.shutdown = true; $0.sessionId = nil }
        XCTAssertEqual(RunRecord.decode(record.encoded()), record)
        XCTAssertNil(RunRecord.decode(["v": 2, "startedAtMs": 1]))
        XCTAssertNil(RunRecord.decode("garbage"))
        XCTAssertNil(RunRecord.decode(nil))
    }

    func testTheExitMarkerIsLeftByTheExitHandlerAndTakenOnce() throws {
        let directory = temporaryDirectory()
        XCTAssertFalse(ExitMarker.take(directory: directory))
        ExitMarker.install(directory: directory)
        ExitMarker.runHandlerForTesting()
        XCTAssertTrue(ExitMarker.take(directory: directory))
        XCTAssertFalse(ExitMarker.take(directory: directory))
        XCTAssertFalse(ExitMarker.take(directory: nil))
        XCTAssertNotNil(ExitReasons.bootTimeSec())
    }
}
