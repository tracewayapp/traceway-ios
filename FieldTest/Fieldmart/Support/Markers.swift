import Foundation
import os
import FieldmartCore

/// Writes the marker lines of `02-APP-SPEC.md` §7 to the unified log
/// (subsystem `com.tracewayapp.fieldmart`, category `fm`) and, as JSON lines,
/// to `Documents/fm-markers/<run>.jsonl` and to the host file `fmMarkers`
/// names (the UI test driver reads T0 from there).
///
/// Markers are logged at the default (`notice`) level: the Simulator only
/// keeps `info` lines in memory, and `log show` must find these later.
final class MarkerWriter {
    static let subsystem = "com.tracewayapp.fieldmart"

    private let logger = Logger(subsystem: MarkerWriter.subsystem, category: "fm")
    private let lock = NSLock()
    private var handles: [FileHandle] = []
    private(set) var written: [Marker] = []

    init(settings: LaunchSettings) {
        if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let folder = documents.appendingPathComponent("fm-markers", isDirectory: true)
            if let handle = MarkerWriter.open(folder.appendingPathComponent(settings.run + ".jsonl")) {
                handles.append(handle)
            }
        }
        if let host = settings.markersPath {
            if let handle = MarkerWriter.open(URL(fileURLWithPath: host)) {
                handles.append(handle)
            } else {
                logger.error("FM cannot write markers to \(host, privacy: .public)")
            }
        }
    }

    static func open(_ url: URL) -> FileHandle? {
        let manager = FileManager.default
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: url.path) {
            guard manager.createFile(atPath: url.path, contents: nil) else { return nil }
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        _ = try? handle.seekToEnd()
        return handle
    }

    func write(_ marker: Marker) {
        let line = marker.line
        logger.notice("\(line, privacy: .public)")
        let data = Data((marker.jsonLine + "\n").utf8)
        lock.lock()
        written.append(marker)
        for handle in handles { try? handle.write(contentsOf: data) }
        lock.unlock()
    }

    func write(_ kind: Marker.Kind, detail: String? = nil, epochMs: Int64 = FMClock.nowMs()) {
        write(Marker(kind, epochMs: epochMs, detail: detail))
    }
}

/// The app's own log lines (`E-12`): `FM log <n>` once per screen change,
/// through `Logger` as an app would log.
final class AppLog {
    private let logger = Logger(subsystem: MarkerWriter.subsystem, category: "app")
    private var count = 0

    func screenChanged() {
        count += 1
        let n = count
        logger.info("FM log \(n)")
    }

    /// `fm-diag-logs`: 1,000 numbered lines of 50 characters each.
    func burst(lines: Int = 1000) {
        for index in 1...lines {
            let head = "FM burst \(String(repeating: "0", count: max(0, 4 - String(index).count)))\(index) "
            let line = head + String(repeating: "x", count: max(0, 50 - head.count))
            logger.info("\(line, privacy: .public)")
        }
    }
}
