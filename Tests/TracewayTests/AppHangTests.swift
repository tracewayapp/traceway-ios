import Foundation
import XCTest
@testable import Traceway

/// CONTRACT §14.2 without a main thread to block: the watchdog's stalls, and
/// how the hang monitor keeps a hang on disk until it ends.
final class AppHangTests: XCTestCase {
    func testTheWatchdogReportsAStallWhileTheMainThreadIsStillBlocked() {
        var main: [() -> Void] = []
        let scheduler = ManualMetricsScheduler()
        var stalls: [(id: Int, waited: Int64)] = []
        var recovered: [(id: Int, blocked: Int64)] = []
        var hangs: [Int64] = []
        var excused = false
        let watchdog = HangWatchdog(
            clock: { scheduler.nowMs },
            postToMain: { main.append($0); return true },
            schedule: { delay, task in scheduler.schedule(afterMs: delay, task) },
            thresholdMs: 2000,
            intervalMs: 500,
            excused: { excused },
            stallThresholdMs: 1500,
            onStall: { stalls.append(($0, $1)) },
            onRecovered: { recovered.append(($0, $1)) },
            onHang: { hangs.append($0) }
        )
        watchdog.start()
        scheduler.advance(1000)
        XCTAssertTrue(stalls.isEmpty)
        scheduler.advance(500)
        XCTAssertEqual(stalls.map { $0.waited }, [1500], "the main thread is still blocked")
        scheduler.advance(500)
        XCTAssertEqual(stalls.map { $0.waited }, [1500, 2000])
        XCTAssertTrue(recovered.isEmpty)
        main.removeFirst()()
        XCTAssertEqual(recovered.map { $0.blocked }, [2000])
        XCTAssertEqual(Set(stalls.map { $0.id }), [recovered[0].id], "one probe, one hang")
        XCTAssertEqual(hangs, [2000], "the app.hang metric as before")

        // A short block is neither.
        scheduler.advance(500)
        main.removeFirst()()
        XCTAssertEqual(recovered.count, 1)

        // Under a debugger nothing is taken.
        excused = true
        scheduler.advance(500)
        scheduler.advance(3000)
        XCTAssertEqual(stalls.count, 2)
        watchdog.stop()
    }

    private func monitor(
        directory: URL?, now: Locked<Int64>, reports: Locked<[AppHangReport]>,
        stack: @escaping () -> [UInt]? = { [0x1000, 0x2000] }
    ) -> AppHangMonitor {
        let monitor = AppHangMonitor(
            thresholdMs: 2000,
            captureStack: stack,
            render: { "\n#00 x 0x\(String($0.first ?? 0, radix: 16)) ShopApp" },
            context: { (["app.screen.name": "/cart", "session.id": "s1"], ["service.version": "1.0"]) },
            nowMs: { now.value },
            report: { hang in reports.withValue { $0.append(hang) } }
        )
        monitor.setDirectory(directory)
        return monitor
    }

    func testAHangIsKeptOnDiskUntilItEndsThenReportedOnce() throws {
        let directory = temporaryDirectory()
        let file = directory.appendingPathComponent(AppHangMonitor.fileName)
        let now = Locked<Int64>(1_800_000_000_000)
        let reports = Locked<[AppHangReport]>([])
        let captures = Locked(0)
        let hangs = monitor(directory: directory, now: now, reports: reports, stack: {
            captures.withValue { $0 += 1 }
            return [0x1000, 0x2000]
        })
        hangs.stalled(id: 1, waitedMs: 2000)
        hangs.settle()
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        now.value += 1500
        hangs.stalled(id: 1, waitedMs: 3500)
        hangs.settle()
        XCTAssertEqual(captures.value, 1, "the stack is taken once per hang")
        // What a process killed now leaves for the next run.
        let onDisk = try XCTUnwrap(AppHangReport.decode(try JSON.parse(Data(contentsOf: file))))
        XCTAssertEqual(onDisk.blockedMs, 3500)
        XCTAssertEqual(onDisk.startedAtMs, 1_800_000_000_000 - 2000)
        XCTAssertTrue(onDisk.fatal)
        XCTAssertEqual(onDisk.message, "Main thread blocked for at least 3.5 s")

        hangs.recovered(id: 1, blockedMs: 3700)
        hangs.settle()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(reports.value.count, 1)
        let hang = try XCTUnwrap(reports.value.first)
        XCTAssertFalse(hang.fatal)
        XCTAssertEqual(hang.message, "Main thread blocked for 3.7 s")
        XCTAssertEqual(hang.stackTrace, "AppHang: Main thread blocked for 3.7 s\n#00 x 0x1000 ShopApp")
        XCTAssertEqual(hang.attributes["app.screen.name"], "/cart")
        XCTAssertEqual(hang.resource["service.version"], "1.0")

        // Another probe's end, or one that never stalled, reports nothing.
        hangs.recovered(id: 1, blockedMs: 9000)
        hangs.recovered(id: 2, blockedMs: 9000)
        hangs.settle()
        XCTAssertEqual(reports.value.count, 1)
        XCTAssertNil(AppHangMonitor.takeFatal(directory: directory))
    }

    func testAHangWhoseProcessDiedComesBackOnceAsFatal() throws {
        let directory = temporaryDirectory()
        let reports = Locked<[AppHangReport]>([])
        let hangs = monitor(directory: directory, now: Locked(1_800_000_000_000), reports: reports)
        hangs.stalled(id: 7, waitedMs: 12_345)
        hangs.settle()
        let fatal = try XCTUnwrap(AppHangMonitor.takeFatal(directory: directory))
        XCTAssertTrue(fatal.fatal)
        XCTAssertEqual(fatal.message, "Main thread blocked for at least 12.3 s")
        XCTAssertEqual(fatal.attributes["session.id"], "s1")
        XCTAssertNil(AppHangMonitor.takeFatal(directory: directory), "taken once")
        XCTAssertTrue(reports.value.isEmpty)

        // A file nobody can read is removed, not kept for every start.
        let file = directory.appendingPathComponent(AppHangMonitor.fileName)
        for garbage in ["{", #"{"v":1}"#, #"{"v":2,"trace":"x","blockedMs":1,"startedAtMs":1}"#, "[]"] {
            try Data(garbage.utf8).write(to: file)
            XCTAssertNil(AppHangMonitor.takeFatal(directory: directory), garbage)
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        }
        XCTAssertNil(AppHangMonitor.takeFatal(directory: nil))
    }

    func testACancelledHangOrOneWithoutAStackIsNeverReported() {
        let directory = temporaryDirectory()
        let reports = Locked<[AppHangReport]>([])
        let hangs = monitor(directory: directory, now: Locked(1_800_000_000_000), reports: reports)
        hangs.stalled(id: 1, waitedMs: 2500)
        hangs.cancel()
        hangs.recovered(id: 1, blockedMs: 3000)
        hangs.settle()
        XCTAssertTrue(reports.value.isEmpty)
        XCTAssertNil(AppHangMonitor.takeFatal(directory: directory))

        for stack in [nil, []] as [[UInt]?] {
            let none = monitor(directory: directory, now: Locked(1_800_000_000_000), reports: reports, stack: { stack })
            none.stalled(id: 1, waitedMs: 2500)
            none.recovered(id: 1, blockedMs: 3000)
            none.settle()
        }
        XCTAssertTrue(reports.value.isEmpty)
        XCTAssertNil(AppHangMonitor.takeFatal(directory: directory))
    }

    func testTheMessageReadsAsTheDashboardParsesIt() {
        XCTAssertEqual(AppHangReport.message(blockedMs: 3240), "Main thread blocked for 3.2 s")
        XCTAssertEqual(AppHangReport.message(blockedMs: 2000), "Main thread blocked for 2.0 s")
        XCTAssertEqual(AppHangReport.message(blockedMs: 125_000), "Main thread blocked for 125.0 s")
        XCTAssertEqual(AppHangReport.message(blockedMs: 12_345, fatal: true), "Main thread blocked for at least 12.3 s")
        XCTAssertEqual(AppHangReport.message(blockedMs: -5), "Main thread blocked for 0.0 s")
    }

    func testTheThresholdOptionIsHeldToWhatTheWatchdogMeasures() {
        XCTAssertEqual(TracewayOptions().appHangThresholdMs, 2000)
        XCTAssertTrue(TracewayOptions().captureAppHangs)
        XCTAssertTrue(TracewayOptions().captureExitReasons)
        XCTAssertFalse(TracewayOptions().captureStdout)
        XCTAssertEqual(TracewayOptions(appHangThresholdMs: 2000).effectiveAppHangThresholdMs, 2000)
        XCTAssertEqual(TracewayOptions(appHangThresholdMs: 10).effectiveAppHangThresholdMs, 250)
        XCTAssertEqual(TracewayOptions(appHangThresholdMs: .min).effectiveAppHangThresholdMs, 250)
        XCTAssertEqual(TracewayOptions(appHangThresholdMs: .max).effectiveAppHangThresholdMs, 60_000)
    }
}
