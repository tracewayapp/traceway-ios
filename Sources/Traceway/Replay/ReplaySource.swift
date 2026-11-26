import Foundation

/// One screen-recording clip: the rrweb events of a wireframe recording,
/// each a JSON object with `type`, `data` and `timestamp`.
struct RecordingClip {
    /// Names the clip while it is assembled; not sent.
    var clipId: String
    var events: [JSON]
    /// Wall-clock time of the first frame in this recording.
    var startedAtMs: Int64?
    var endedAtMs: Int64?
    /// About how many bytes the events take as JSON, when the recorder
    /// measured it.
    var approxBytes: Int?
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
    /// `untilMs`. The frames are chosen when this is called.
    func captureRecording(clipId: String, sinceMs: Int64?, untilMs: Int64?) -> RecordingClip?
}
