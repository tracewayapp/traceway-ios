import Foundation

/// Runs the screen recording according to the replay mode, like the browser
/// SDK runs rrweb:
///
/// - `off` stops recording and forgets the frames.
/// - `buffer` keeps the last frames in the recorder's ring and uploads a
///   clip only when a trigger or capture flushes it.
/// - `stream` (a capture or trigger that asks for replay, or a rule) uploads
///   the session as consecutive segments, one every `segmentMs`.
///
/// The session's segments never overlap: each starts where the previous one
/// uploaded for the session ended, so the dashboard plays them in a row.
/// Used on the client's queue; clips are assembled on a queue of their own.
final class ReplayController {
    let transport: RecordingsTransport
    let budget: CollectionBudget
    /// How long a streamed segment is. Must stay below the frame ring's
    /// length, or frames are evicted before they are uploaded.
    var segmentMs: Int

    private let queue: DispatchQueue
    private let sessionId: () -> String?
    private let nextSegmentIndex: () -> Int
    private let now: () -> Int64
    private let encoder = DispatchQueue(label: "app.traceway.replay", qos: .utility)

    private var source: ReplaySource?
    private(set) var mode: Mode = .off
    private var maxAgeMs: Int64 = 600_000
    private var encodings = 0
    private var segmentTimer: DispatchSourceTimer?
    /// The end of the last frames uploaded as part of the current session.
    private var sessionCursor: Int64?
    /// Counts `discardRecorded` calls: a clip asked for before the last one
    /// is dropped when it has been assembled.
    private var discards = 0
    /// Called on the client's queue when the budget turns a segment away.
    var onBudgetDrop: (() -> Void)?

    init(
        transport: RecordingsTransport,
        queue: DispatchQueue,
        sessionId: @escaping () -> String?,
        nextSegmentIndex: @escaping () -> Int,
        segmentMs: Int = 8000,
        budget: CollectionBudget = CollectionBudget(),
        now: @escaping () -> Int64 = Clock.nowMs
    ) {
        self.transport = transport
        self.queue = queue
        self.sessionId = sessionId
        self.nextSegmentIndex = nextSegmentIndex
        self.segmentMs = segmentMs
        self.budget = budget
        self.now = now
    }

    func attach(_ newSource: ReplaySource?) {
        if let previous = source, previous !== newSource { previous.stop() }
        if newSource == nil { stopTimer() }
        source = newSource
        sync()
    }

    /// `sessionSampled` is whether the session falls inside
    /// `replay.sessionSampleRate`; sessions outside it never stream.
    func apply(_ requested: Mode, maxAgeMs: Int64, sessionSampled: Bool = true) {
        self.maxAgeMs = maxAgeMs
        let effective: Mode = requested == .stream && !sessionSampled ? .buffer : requested
        let previous = mode
        if previous == .stream, effective != .stream {
            // What was recorded since the last segment still belongs to the
            // session that was streaming.
            cutSegment()
        }
        mode = effective
        if effective == .stream, previous != .stream {
            let nowMs = now()
            // Right after a lookback flush (a capture), streaming continues
            // where the flushed clip ended; otherwise it starts now.
            if let cursor = sessionCursor, nowMs - cursor <= 1000 {} else { sessionCursor = nowMs }
        }
        sync()
    }

    private func sync() {
        if mode != .stream { stopTimer() }
        guard let source = source else { return }
        if mode == .off {
            if source.isRunning { source.stop() }
            source.clearBuffer()
            transport.discard()
            sessionCursor = nil
            return
        }
        if !source.isRunning { source.start() }
        if mode == .stream, segmentTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            let interval = DispatchTimeInterval.milliseconds(segmentMs)
            timer.schedule(deadline: .now() + interval, repeating: interval)
            timer.setEventHandler { [weak self] in self?.cutSegment(timed: true) }
            timer.resume()
            segmentTimer = timer
        }
    }

    private func stopTimer() {
        segmentTimer?.cancel()
        segmentTimer = nil
    }

    /// Masking or the image policy became stricter, and the recorder dropped
    /// its frames: the clips made of them that have not been handed to the
    /// network yet, still being assembled or waiting to be sent, go too.
    func discardRecorded() {
        discards += 1
        transport.discard()
    }

    /// Uploads the frames of the last `lookbackMs`. With `exceptionId` the
    /// clip is that exception's; without, it is part of the session (a
    /// capture's lookback). Returns false when no clip can be made.
    func flush(lookbackMs: Int64, exceptionId: String?) -> Bool {
        guard mode != .off, let source = source else { return false }
        let until = now()
        let since = until - min(lookbackMs, maxAgeMs)
        let hasException = !(exceptionId ?? "").isEmpty

        if mode == .stream {
            if !hasException {
                // The session already streams; a capture's lookback adds nothing.
                cutSegment()
                return true
            }
            // The exception gets a clip of its own, outside the session,
            // whose segments are streamed anyway.
            guard source.hasFrames(sinceMs: since, untilMs: until) else { return false }
            encode(sinceMs: since, untilMs: until, exceptionId: exceptionId)
            return true
        }

        let session = sessionId()
        if session == nil, !hasException { return false }
        var from = since
        if session != nil, let cursor = sessionCursor, cursor > from { from = cursor }
        var clipped = false
        if hasException, from != since {
            // Part of the window already went up with the session: the
            // exception still gets a clip of the whole window, outside it.
            guard source.hasFrames(sinceMs: since, untilMs: until) else { return false }
            encode(sinceMs: since, untilMs: until, exceptionId: exceptionId)
            clipped = true
        }
        guard source.hasFrames(sinceMs: from, untilMs: until) else { return clipped }
        if let session = session, !hasException || clipped {
            encodeSegments(sinceMs: from, untilMs: until, session: session)
        } else {
            encode(
                sinceMs: from,
                untilMs: until,
                exceptionId: hasException && !clipped ? exceptionId : nil,
                session: session,
                index: session == nil ? nil : nextSegmentIndex()
            )
        }
        if session != nil { sessionCursor = until }
        return true
    }

    /// Streams what was recorded since the last segment of the session.
    /// `session` overrides the current session, for the one that just
    /// ended. A `timed` cut waits while an earlier clip is still being
    /// assembled, so a slow device does not pile clips up in memory.
    private func cutSegment(session: String? = nil, timed: Bool = false) {
        guard let source = source, let id = session ?? sessionId(), mode == .stream else { return }
        if timed, encodings > 0 { return }
        let until = now()
        let since = sessionCursor ?? until - Int64(segmentMs)
        sessionCursor = until
        guard since < until, source.hasFrames(sinceMs: since, untilMs: until) else { return }
        encodeSegments(sinceMs: since, untilMs: until, session: id)
    }

    /// The session's frames from `sinceMs` to `untilMs` as consecutive
    /// segments: one, or more where one would carry more pictures than a
    /// segment allows (it would lose all of them).
    private func encodeSegments(sinceMs: Int64, untilMs: Int64, session: String) {
        var from = sinceMs
        for cut in (source?.rasterCuts(sinceMs: sinceMs, untilMs: untilMs) ?? []) + [untilMs] where cut > from && cut <= untilMs {
            encode(sinceMs: from, untilMs: cut, session: session, index: nextSegmentIndex())
            from = cut
        }
    }

    private func encode(
        sinceMs: Int64,
        untilMs: Int64,
        exceptionId: String? = nil,
        session: String? = nil,
        index: Int? = nil
    ) {
        guard let source = source else { return }
        let clipId = exceptionId ?? "\(session ?? "")_\(index ?? 0)"
        // An exception's clip outside the session still counts against the
        // budget of the session it happened in.
        let budgetSession = session ?? sessionId()
        let discards = self.discards
        encodings += 1
        encoder.async { [weak self] in
            let clip = source.captureRecording(clipId: clipId, sinceMs: sinceMs, untilMs: untilMs)
            guard let self = self else { return }
            self.queue.async {
                self.encodings -= 1
                guard let clip = clip, !clip.events.isEmpty, self.mode != .off, discards == self.discards else { return }
                let segment = RecordingSegment(
                    exceptionId: exceptionId,
                    sessionId: session,
                    segmentIndex: index,
                    events: clip.events,
                    startedAtMs: clip.startedAtMs,
                    endedAtMs: clip.endedAtMs,
                    approxBytes: clip.approxBytes
                )
                guard self.budget.admit(budgetSession, bytes: 256 + segment.bytes, events: clip.events.count) else {
                    self.onBudgetDrop?()
                    return
                }
                self.transport.send([segment])
            }
        }
    }

    /// The session ended: a streaming one uploads its last segment under
    /// the session it belongs to.
    func onSessionEnd(_ endedSessionId: String) {
        cutSegment(session: endedSessionId)
        sessionCursor = nil
    }

    func onSessionStart() {
        sessionCursor = mode == .stream ? now() : nil
    }

    /// The app went to the background and may be killed there: a streaming
    /// session uploads what it has.
    func onPaused() { cutSegment() }

    /// Runs `completion` on the client's queue once the clips asked for so
    /// far are assembled and counted against the budget, without waiting
    /// for their upload.
    func afterEncodes(_ completion: @escaping () -> Void) {
        let done = Unchecked(completion)
        encoder.async { [queue] in queue.async { done.value() } }
    }

    /// Waits (off the client's queue) for clips being assembled and for
    /// their upload, then runs `completion` on the client's queue.
    func drain(_ completion: @escaping () -> Void) {
        encoder.async { [weak self] in
            guard let self = self else { return }
            // Clips assembled so far have been handed back to the client's
            // queue; once that has run, they are with the transport.
            let done = Unchecked(completion)
            self.queue.async {
                self.transport.flush { self.queue.async { done.value() } }
            }
        }
    }

    func stop() {
        stopTimer()
        source?.stop()
    }
}
