import Foundation
import XCTest
import FieldmartCore

/// What `ci/run-one.sh` asks for, through `TEST_RUNNER_FM_*` variables
/// (xcodebuild passes them to the test process without the prefix).
struct RunConfig {
    var run: String
    var scenario: String
    var variant: String
    var evidence: Bool
    var app: String
    var out: URL
    var campaign: String
    var target: String?
    var extraArguments: [String]
    /// `paced` (the default): every character whose time has come in one
    /// `typeText` call; `chars`: one call per character; `chunk`: one per step.
    var typeMode: String
    /// `wait` (XCUITest waits for the app to be idle before each event, the
    /// default) or `skip`.
    var quiescence: String
    /// Real screenshots are scaled to `shotScale` × the logical size.
    var shotScale: CGFloat
    var gateway: String
    var journeyPath: String?
    var iterations: Int

    static func fromEnvironment() -> RunConfig {
        let env = ProcessInfo.processInfo.environment
        func value(_ key: String) -> String? {
            guard let raw = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
            return raw
        }
        let run = value("FM_RUN") ?? "ios-manual-\(Int(Date().timeIntervalSince1970))"
        // FM_OUT on the runner's disk; if the test runner cannot write there,
        // its own Documents/fm-out/<run>/ (ci/run-one.sh copies it out).
        let fallback = (FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory).appendingPathComponent("fm-out/\(run)", isDirectory: true)
        var out = value("FM_OUT").map { URL(fileURLWithPath: $0, isDirectory: true) } ?? fallback
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let probe = out.appendingPathComponent(".writable")
        if FileManager.default.createFile(atPath: probe.path, contents: Data()) {
            try? FileManager.default.removeItem(at: probe)
        } else {
            out = fallback
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        }
        return RunConfig(
            run: run,
            scenario: value("FM_SCENARIO") ?? "S0",
            variant: value("FM_VARIANT") ?? "core",
            evidence: value("FM_EVIDENCE") == "1",
            app: value("FM_APP") ?? "com.tracewayapp.fieldmart",
            out: out,
            campaign: value("FM_CAMPAIGN") ?? "manual",
            target: value("FM_TARGET"),
            extraArguments: (value("FM_EXTRA_ARGS") ?? "").split(separator: " ").map(String.init),
            typeMode: value("FM_TYPE_MODE") ?? "paced",
            quiescence: value("FM_QUIESCENCE") ?? "wait",
            shotScale: CGFloat(Double(value("FM_SHOT_SCALE") ?? "") ?? 2),
            gateway: value("FM_GATEWAY") ?? "http://127.0.0.1:18190",
            journeyPath: value("FM_JOURNEY"),
            iterations: Int(value("FM_ITERATIONS") ?? "") ?? 10
        )
    }

    var markersFile: URL { out.appendingPathComponent("markers.jsonl") }

    /// The app's launch arguments for this run.
    func launchArguments(scenarioSettings: [String: String]?) -> [String] {
        var arguments = [
            "-fmRun", run, "-fmVariant", variant, "-fmScenario", scenario,
            "-fmEvidence", evidence ? "1" : "0", "-fmMarkers", markersFile.path, "-fmCampaign", campaign,
        ]
        if let target = target { arguments += ["-fmTarget", target] }
        for (key, value) in (scenarioSettings ?? [:]).sorted(by: { $0.key < $1.key }) {
            arguments += ["-" + (key.hasPrefix("fm") ? key : "fm" + key.prefix(1).uppercased() + key.dropFirst()), value]
        }
        return arguments + extraArguments
    }

    func loadJourney() throws -> Journey {
        let url: URL
        if let path = journeyPath {
            url = URL(fileURLWithPath: path)
        } else if let bundled = Bundle(for: JourneyTests.self).url(forResource: "journey", withExtension: "json") {
            url = bundled
        } else {
            throw DriverError("journey.json is not in the UI test bundle")
        }
        return try Journey.load(Data(contentsOf: url))
    }
}

struct DriverError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// `driver.log`: one line per thing the driver did, with times.
final class DriverLog {
    private var lines: [String] = []
    private let started = FMClock.nowMs()
    private let url: URL

    init(url: URL) {
        self.url = url
    }

    func write(_ text: String) {
        let now = FMClock.nowMs()
        let line = "\(now) +\(now - started)ms \(text)"
        lines.append(line)
        NSLog("FMDRIVER %@", line)
        flush()
    }

    func flush() {
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

/// A JSON value written by hand (the outputs are small).
enum Out {
    static func string(_ value: String) -> String { Marker.quote(value) }

    static func strings(_ values: [String]?) -> String {
        "[" + (values ?? []).map(Marker.quote).joined(separator: ",") + "]"
    }

    static func number(_ value: CGFloat) -> String {
        let rounded = (Double(value) * 10).rounded() / 10
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
    }

    static func write(_ text: String, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}
