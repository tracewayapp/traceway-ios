import Foundation

/// One screen-recording clip a recorder hands the replay controller: the
/// rrweb events of a wireframe recording, each a JSON object with `type`,
/// `data` and `timestamp`. The controller wraps it in a `RecordingSegment`
/// for upload.
struct SessionRecordingPayload {
    /// Names the clip while it is assembled; not sent.
    let clipId: String
    let events: [JSON]
    /// Wall-clock time of the first frame in this recording.
    let startedAtMs: Int64?
    let endedAtMs: Int64?
    /// The recorder's size estimate, or the measured size of the emitted layout.
    let approxBytes: Int

    init(clipId: String, events: [JSON], startedAtMs: Int64?, endedAtMs: Int64?, approxBytes: Int? = nil) {
        self.clipId = clipId
        self.startedAtMs = startedAtMs
        self.endedAtMs = endedAtMs
        if let layout = WireframeRasterBudget.layoutOnlyIfNeeded(events) {
            self.events = layout
            self.approxBytes = JSON.array(layout).encoded().utf8.count
        } else {
            self.events = events
            self.approxBytes = approxBytes ?? JSON.array(events).encoded().utf8.count
        }
    }
}

/// What the replay controller needs from a screen recorder; lets tests stand
/// in for the wireframe recorder. Every method is called on the client's
/// queue; a recorder that needs the main thread hops there itself.
protocol ReplaySource: AnyObject {
    var isRunning: Bool { get }
    func start()
    func stop()
    func clearBuffer()

    /// Whether any frame was captured at or after `sinceMs` and before
    /// `untilMs`.
    func hasFrames(sinceMs: Int64?, untilMs: Int64?) -> Bool

    /// Makes one clip of what was on screen at or after `sinceMs` and before
    /// `untilMs` (now when nil). The frames are chosen when this is called.
    /// Nil when nothing was on screen then, or when the window is empty or
    /// inverted (`sinceMs` at or after its end).
    func captureRecording(clipId: String, sinceMs: Int64?, untilMs: Int64?) -> SessionRecordingPayload?

    /// Where the session's frames from `sinceMs` to `untilMs` have to be
    /// cut into segments of their own, so that each keeps its pictures
    /// within the 128 KiB of data URLs a segment allows
    /// (`WireframeRasterBudget`): the start of each segment after the
    /// first, in order. Empty when one segment holds them.
    func rasterCuts(sinceMs: Int64, untilMs: Int64) -> [Int64]
}

extension ReplaySource {
    func rasterCuts(sinceMs: Int64, untilMs: Int64) -> [Int64] { [] }
}
