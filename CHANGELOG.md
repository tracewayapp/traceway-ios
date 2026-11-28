# Changelog

## Unreleased

- **Sessions the app was killed in are ended, with their counts.** Going to
  the background and `Traceway.flush` send `traceway.session.update` with the
  collection counters (`traceway.collection.*`, `traceway.replay.image_bytes`),
  unless nothing changed since the session's last event, and keep them with
  the session on disk with its memory peak. The next start after such a
  session expired sends its `session.end` first: at the time the app left
  the foreground (or its last activity), with the counters, attributes and
  app version the session had. Sessions ended by `shutdown`, and sessions
  older than a day, are not ended again. Before, a killed app's session kept
  the zero counts of its `session.start`.
- **Replay pictures on scrolling screens.** A clip carries the picture and
  glyph rules of what it shows instead of every rule still lingering from
  the last 30 seconds, and a streamed segment that would pass its 128 KiB of
  data URLs ends at that frame, the next one starting there with its own
  allowance. Before, every segment of a scrolled picture grid passed the
  allowance and was sent as layout only, so its pictures were placeholders.

## 2.1.0 — unreleased

Rebuilt on the official OpenTelemetry Swift SDK, at parity with the browser,
Flutter and Android SDKs 2.1: OTLP logs, spans and metrics, a ring buffer on
the device, remote config over OpAMP, captures, recording triggers, taps,
wireframe session replay and app performance metrics. The SDK leaves beta with
this release.

- **Start with a token**: `Traceway.initialize(token:baseUrl:options:)`;
  `baseUrl` defaults to `https://cloud.tracewayapp.com`
  (`Traceway.defaultBaseUrl`), so Traceway Cloud apps pass only the token, as
  the dashboard's Connection page shows it (`Traceway.xcconfig`, `Info.plist`,
  `TracewayToken`). A blank token or `baseUrl` counts as none; no token runs
  standalone (`Traceway.initialize(options:)`). `initialize(connectionString:options:)`
  and `start` are deprecated; every form of an old connection string still
  works, with one warning per process.
- **One reading of a server URL**, the same as the other SDKs: whitespace
  trimmed, `https://` added without a scheme (`http://` for local hosts), a
  query or fragment and trailing slashes dropped, then `/api/report` or `/api`.
  `token@cloud.tracewayapp.com`, `token@localhost:8082` and a token with spaces
  around it no longer keep the SDK off or get a 401, and a URL with a query no
  longer sends everything to `/api/report?…`. No request ever goes to
  `/api/report`.
- **The console says why nothing arrives**: once per process and without
  `debug`, a call before `initialize`, a rejected token (HTTP 401) and a
  server without OTLP for iOS (HTTP 404); warnings such as a bad
  `ignoreErrors` pattern regardless of `debug`. With `debug`: what the SDK
  does at start, issues dropped by `ignoreErrors`, `beforeCapture`, sampling
  or the rate limit, `screenCapture` off standalone, a second `initialize`.
- **Traceway no longer becomes the global OpenTelemetry provider**, as on
  Android, Flutter and the browser; use `Traceway.tracer`.
- **A failed interaction is sent with its exception**, as on the other SDKs,
  so the issue links to its trace (it waited in the buffer).
- **SwiftUI**: `.tracewayIdentifier(_:)` names a view for taps and click steps
  (`#pay`); `.tracewayScreen(_:route:)` records `pop` when a screen comes back,
  takes the route template, and wins over hosting controllers, which are no
  longer screens once a view is named this way.
- **Swift 6**: the public types are `Sendable`, `beforeCapture` is
  `@Sendable` (called on the thread that captured the issue), and the async
  `run` of an interaction stays on the caller's actor; README snippets compile
  in Swift 6 language mode without `@preconcurrency`.
- **Privacy manifest**: `PrivacyInfo.xcprivacy` declares no tracking, the
  file timestamp (`C617.1`) and boot time (`35F9.1`) APIs, and the data
  collected; the README lists it for the App Privacy details.
- **Unified-log reads are bounded** while they run (the newest 1,000 lines,
  16 KiB each), exceptions captured during a read share it, and an exception
  waits at most 0.5 s for it.
- **dSYM upload script**: Xcode warnings (`warning: traceway: …`) for a
  missing token, no dSYM or a failed upload with its HTTP status;
  `TRACEWAY_UPLOAD_DEBUG=YES` uploads Debug builds; `TRACEWAY_URL` is read by
  the same rules (Traceway Cloud when unset). The README walks through the
  build phase, User Script Sandboxing and Debug dSYMs.
- `TracewayOptions`: `reportHangsInDebug` comes after `appHangThresholdMs`, in
  Android's order.
- Route templates are written `/orders/:id` in every doc, as on the other
  SDKs.
- **An issue leaves before the breadcrumbs it flushes**, as in the browser
  SDK: it is the first record of the first flushed request, or, written to
  the outbox first, a request of its own that is sent ahead of them. A server
  that admits only so many log records per address never spends them on the
  breadcrumbs alone.
- **`os.version` is the bare version** (`17.4`, no longer `iOS 17.4`), as on
  Android, so rules can compare it as a version or a number; `os.name` names
  the platform.
- **Issues of an earlier run** (a fatal signal found on disk, a MetricKit
  crash or watchdog termination, a hang the app died in) carry
  `traceway.previous_run: true`, as on Android. One without a session of its
  own is no longer given the session of the run that reports it; none gets
  that run's capture ids, a trigger of that run or a replay clip of it; the
  breadcrumbs the earlier run left on disk are still sent with them.
- **Replay privacy**: a SwiftUI `.tracewayMask()` covers its content where an
  animation shows it (a push, a pop, a sheet), not only where it ends up;
  touches on the system keyboard are recorded neither in the replay nor as
  taps; and when remote settings turn `replay.maskAllInputs` back on or make
  `replay.images` stricter, the frames recorded before and the clips made of
  them that have not been sent are dropped, and the screen is captured again
  at once.
- `recordNavigation(_:action: "remove")` leaves the current screen as it is,
  as on the other SDKs: the record has an empty `url.full` and no
  `navigation.to`.
- A crash, and an issue of an earlier run, is never dropped by the limit on
  repeated errors (the same error within a second, 60 a minute).
- A hang still under way when the app goes to the background is dropped with
  its file; it was reported as a fatal hang at the next start.
- What the app logged while the console signal was off is not read from the
  unified log when the signal comes back on.
- Stopping the `captureStdout` tee leaves a descriptor the app has redirected
  itself since as the app set it.

- **Breaking**: requires a server with OTLP/OpAMP support for iOS projects; the
  0.1.x `/api/report` protocol is gone. Options `debounceMs`, `retryDelayMs`,
  `maxPendingExceptions`, `maxLocalFiles` and `localFileMaxAgeHours` were
  removed. Requires Xcode 26.4 (Swift 6.3) or later.
- **OpenTelemetry**: records are made with `opentelemetry-swift-core` 2.6
  (`LoggerProviderSdk`, `TracerProviderSdk`) and sent by the
  `OtlpHttpLogExporter` / `OtlpHttpTraceExporter` of `opentelemetry-swift` 2.6
  as gzipped protobuf. `Traceway.tracer` is the SDK's tracer; the global
  OpenTelemetry stays the app's.
- **Exceptions** are OpenTelemetry `exception` log events (`exception.type`,
  `exception.message`, `exception.stacktrace` with the binary-image wire trace
  the server symbolicates, `traceway.exception.id`). Messages are
  `traceway.message` events. Uncaught `NSException`s and fatal signals are
  recorded as before; a signal crash is reported on the next start with the
  session it happened in. Issues are written to disk (OTLP protobuf) before
  they are sent.
- **Ring buffer**: logs (`Traceway.log`), requests, navigation, taps and custom
  events stay on the device (2 MiB / 10 minutes) and are uploaded when an
  exception, a trigger or a capture asks for them. It is saved when the app
  goes to the background and restored when the same session goes on after a
  restart.
- **Remote config over OpAMP** (plain HTTP, protobuf): signal modes, sample
  rates, buffer sizes, triggers and on-demand captures from the dashboard; the
  last config is cached for the next start. Init options are ceilings.
  `TracewayOptions.collection` takes the same document locally.
- **Recording triggers** with the browser SDK's sequence engine: `click` steps
  (CSS-like selectors over the view hierarchy), `navigation` and `log` steps,
  counts and windows, progress kept across restarts within a session.
- **Taps** are recorded as `browser.user_action.click` with a selector naming
  the view (`UIButton#pay`), plus `app.widget.*` and `app.screen.*` attributes.
- **Screens**: view controllers that appear are recorded as
  `browser.navigation`; SwiftUI views report theirs with `.tracewayScreen`.
- **App performance metrics** (`captureMetrics`, on by default), with the
  Android and Flutter SDKs' names, dimensions and thresholds:
  `app.start.duration` (`start_type` cold / warm / hot, from the process start
  read with `kinfo_proc`, or from `Traceway.initialize` when iOS prewarmed the
  process), `app.screen.ttid` and `app.screen.ttfd`
  (`Traceway.reportFullyDisplayed()`), `app.frames.slow` and
  `app.frames.frozen` from a `CADisplayLink` (frozen at 700 ms), `app.hang` and
  `app.hang.duration` (main thread blocked 2 s in the foreground; not under a
  debugger unless `reportHangsInDebug`), `app.crash`, `app.session`,
  `app.user` and `app.user.affected`, `app.memory.peak` (`task_vm_info`
  physical footprint) and `app.request.duration` / `.bytes` / `.failed` by host
  from the URLSession spans. Delta exponential histograms (scale 3) and
  monotonic sums, gzipped OTLP protobuf to `/api/otel/v1/metrics` every
  `metrics.flushSeconds` (300 s) and on background; at most 200 series per
  payload and 60 KB per body; one resend of a payload that got no answer.
  `Traceway.metric`, `Traceway.count` and `Traceway.setMetricDimension` (or
  `metricDimensions`) add the app's own. Remote `metrics.enabled`,
  `metrics.sampleRate`, `metrics.flushSeconds` and `limits.metrics` apply.
  `TracewayTelemetry` gains a `metrics` endpoint; standalone needs a `url` or
  all three endpoints, and a blank `url` counts as unset.
- **Network**: URLSession requests are client spans from the official
  `URLSessionInstrumentation` (stable HTTP semantic conventions);
  `propagateTraceHeaderUrls` adds W3C `traceparent` headers.
- **Wireframe session replay** (`screenCapture: true`): the view hierarchy
  becomes an HTML document replayed by the dashboard's rrweb player, the same
  format as the Flutter SDK's wireframe recorder: boxes, gradients and shape
  layers, labels with rich text runs, buttons, fields, switches, sliders,
  segmented controls, steppers, progress views, page controls and spinners,
  SF Symbols and template images as their shapes (palette and multicolor
  symbols in their colors), and iOS 26's Liquid Glass as frosted shapes.
  SwiftUI text shows as its words while an assistive technology runs, else as
  text-shaped bars. Text fields are masked; `tracewayMask` (UIKit),
  `.tracewayMask()` (SwiftUI) and the `accessibilityIdentifier` markers
  `traceway-mask` / `traceway-blank` blur or blank views. Clips go to
  `/api/recordings`, linked to their exception; captures stream segments.
- **Tests**: a wireframe gallery of UIKit and SwiftUI screens recorded on the
  iOS Simulator and compared with the app's own pictures in rrweb-player
  (`CI/wireframe`), UIKit conversion tests, and an end-to-end check against a
  running Traceway (`CI/e2e`).
- **Sessions**: `session.start`, `traceway.session.update` and `session.end`,
  15 minutes of inactivity or one hour at most; a restart within the window
  continues the session.
- **Other OpenTelemetry backends** with `TracewayOptions.telemetry`, next to
  Traceway or standalone without a token.
- **Outbox**: batches that fail for a reason that may pass are kept on disk per
  destination (24 hours, 200 batches) and sent again later.
- Crash and fatal hang recovery uses destination-specific files. Older
  diagnostics without a destination are discarded when persistence is enabled.
- New API: `track`, `log`, `recordAction`, `recordNavigation`,
  `setAttribute(s)`, `removeAttribute`, `clearAttributes`, `shutdown`,
  `refreshConfig`, `instanceId`, `currentSessionId`, `tracer`.
- **Same API and wire format as the Android and Flutter SDKs**:
  - `Traceway.captureException(_:attributes:)` and
    `captureMessage(_:attributes:)`; `capture(_:)`, `capture(error:)` and
    `capture(message:)` are deprecated aliases. `currentSessionId` replaces
    the deprecated `sessionId`.
  - `log(_:level:attributes:)` with `TracewayLogLevel` (`TracewayLogSeverity`
    is a deprecated alias, `log(_:severity:)` a deprecated method). A log
    line has no event name any more (it was `browser.console`) and no
    `log.severity` attribute: its severity is the record's, and it carries
    `log.source: api` and the caller's attributes.
  - `Traceway.initialize(token:baseUrl:options:)` starts the SDK (the
    other SDKs' `init`, which Swift keeps for initializers).
  - `recordNavigation(_:action:from:route:)` and `setRoute(_:)`: navigation
    records and issues carry `app.screen.route` while a route template is
    set.
  - Masks are traceway masks: `UIView.tracewayMask` and `.tracewayMask(_:)`;
    `tracewayPrivacyMask` (both) is a deprecated alias.
  - Exceptions and messages carry the screen they happened on:
    `app.screen.name`, `app.screen.route`, `app.screen.previous`,
    `app.screen.duration_ms` and `viewport` (`<width>x<height>` in points).
  - `startInteraction(_:attributes:)` returns a `TracewayInteraction`
    (`traceId`, `spanId`, `run`, `setAttribute`, `captureException`,
    `end(failed:)`): a span the requests, issues and logs inside it belong to.
  - Options `ignoreErrors` (`TracewayErrorPattern`: a substring or a regular
    expression matched against `Type: message`; default
    `TracewayOptions.defaultIgnoreErrors`: URL errors -1001, -1003, -1004,
    -1005 and -1009, lost connections, timeouts and 4xx answers) and
    `beforeCapture` (`TracewayCapturedError`; returning false drops the
    issue, a callback that throws keeps it).
  - **Breaking**: `TracewayOptions` takes its arguments in the order the
    other mobile SDKs use (`collection` before `sessions`,
    `baselineSampleRate` and `remoteConfig`; `telemetry` before
    `propagateTraceHeaderUrls`).
  - A tap is a finger lifted within 10 points before UIKit's long-press
    duration (0.5 s), for the tap record and the replay's click alike (it was
    1 s and 600 ms).
  - `traceway.collection.health` reports dropped data (the session's replay
    budget, suppressed errors, failed replay uploads), backing off from one
    second to five minutes; session events carry
    `traceway.error.suppressed_total`.
- **Replay images**: with the setting `replay.images` (`off`, `wifi` by
  default, `always`) and the option `replayImages` as its ceiling, the
  wireframe includes the pictures image views and SwiftUI image layers show:
  downscaled to their displayed size (one pixel per point), JPEG at 0.45 up
  to 384 px, PNG up to 192 px for see-through pictures, at most 48 KiB each
  and 4 MiB per session, encoded off the main thread and shared by bitmap
  and display size. A clip or segment with more than 128 KiB of serialized
  raster data URLs uploads as layout only. Repeated URLs count each time,
  and each new segment has its own allowance. Privacy masks exclude pictures. `wifi` means unmetered (`NWPathMonitor`: not
  cellular, a hotspot or Low Data Mode), decided for each frame. Session
  events carry `traceway.replay.images` and `traceway.replay.image_bytes`.
- **Wireframe**: the shared stylesheet is byte for byte the Android and
  Flutter SDKs' (Apple's font stack is now inline on the screen node).
  `WireframeRoots` finds the windows, the SwiftUI converters live in
  `WireframeSwiftUICapture.swift`, `CollectionBudget` in a file of its own,
  and the recorder hands the controller a `SessionRecordingPayload` (it was
  `RecordingClip`). [Docs/Wireframe.md](Docs/Wireframe.md) describes the
  pipeline.
- **Crash safety** (new in 2.1.0): the SDK never takes the app down. One
  `guarded` helper contains what throws in the app's control flow (hooks,
  observers, the app's callbacks), and the sources keep no traps: no `try!`,
  force unwraps or unchecked conversions of numbers from the server, files or
  the app, and values are checked before Foundation calls that raise.
  `CrashSafetyTests` scans the sources for them and calls every public API
  before `initialize`, after `shutdown`, twice, at once and with garbage, with
  faults in the network, the settings, triggers and callbacks.
- A remote rule's `withinSeconds` is held to a day like every other duration;
  an absurd one trapped on the next record and at every start after.
- An absurd `Retry-After` (OpAMP, recordings) is held to a day instead of
  trapping.
- A corrupt crash file is removed before it is read and its values are
  checked: it caused a crash at every launch.
- `TracewayOptions.collection` with values that are not JSON (a `Date`, NaN)
  is ignored instead of raising an Objective-C exception at launch.
- Two `initialize` calls at once share one client (each started one on the
  same files); `initialize` while a `shutdown` runs starts a new client
  instead of returning the stopping one; concurrent `shutdown`s join the
  first; `shutdown` waits at most 10 seconds.
- `flush()` waits at most 10 seconds by default, as on Android (it waited
  without a limit).
- `initialize` off the main thread no longer deadlocks while the main thread
  waits for it: the screen size is not read with `main.sync`.
- The background task of the flush on backgrounding always ends, also when
  the SDK shut down in between; iOS kills an app whose task outlives its time.
- The swizzled `sendEvent:`, `viewDidLoad`, `viewWillAppear:` and
  `viewDidAppear:` call the implementation they replace with its own selector,
  so other libraries' hooks that rely on `_cmd` keep working.
- Crash handlers keep the handlers installed before them. The `NSException`
  handler is installed once per process: an uncaught `NSException` still
  reaches the previous handler after a restart of the SDK. Signal handlers
  belong to the running client (with `persistToDisk`): shutdown stops
  recording and restores the previous signal actions where Traceway still
  owns them, and a fatal signal reaches the previous handler with its own
  `siginfo` and context. The stack walk cannot fault on a smashed stack, the
  main thread gets its own signal stack, and crash metadata updates reuse two
  buffers instead of leaking one each.
- URLSession spans record for the client started after a `shutdown`.
- A trigger that streams on every record extends its stream instead of
  adding one per record.
- The wireframe keeps at most 2,000 characters of text per node, and at most
  four pictures wait to be encoded.
- A `beforeCapture` that reports to Traceway itself no longer recurses: a
  capture made inside it skips the callback.
- A crash from an earlier run is reported under that run's app and OS
  version, and without `traceway.session.started_at`.
- Timestamps the app sets that no clock reaches, and absurd view sizes, no
  longer trap; `maxBufferFrames` is held to 10,000 and `exportDelayMs` to a
  minute.
- **Exit reasons** (new in 2.1.0, option `captureExitReasons`, on by
  default): a MetricKit subscriber (iOS 14+) reports the crashes its
  `MXCrashDiagnostic`s describe that the signal and `NSException` handlers did
  not record (same signal within a minute) as `NativeCrash` issues with the
  crashed thread's frames, under the run's app and OS version, plus
  `app.crash`; watchdog terminations (`0x8badf00d`) become
  `WatchdogTermination` issues and `app.anr`. The parser reads
  `jsonRepresentation()`. At the next start a run that ended in the
  foreground with no crash, shutdown, `exit` or `willTerminate`, no debugger
  and the same app, build, OS and boot counts one `app.oom` (a heuristic,
  never an issue). The signal handler keeps a thread's own alternate stack
  and gives the main thread and the starting thread a 64 KiB one, so stack
  overflows are recorded.
- **App hangs as issues** (new in 2.1.0, options `captureAppHangs`, on, and
  `appHangThresholdMs`, 2000): the hang watchdog suspends the main thread
  once it has been blocked that long, takes its stack (`thread_get_state`, a
  checked frame-pointer walk of at most 128 frames, nothing allocated while it
  is suspended) and reports one `AppHang` issue, `Main thread blocked for
  3.2 s`, with the screen, when it answers again. A hang that ended the app is
  reported at the next start with `app.hang.fatal: true`. Not in the
  background, not under a debugger. With `captureMetrics: false` the watchdog
  runs for the issues alone.
- **Log capture** (new in 2.1.0): on iOS 15+ the app's `NSLog`, `os_log` and `Logger`
  lines are read from `OSLogStore(scope: .currentProcessIdentifier)` every 10
  seconds and before an exception is recorded (`log.source: oslog`); option
  `captureStdout` (off) tees standard output and error into console lines
  (`log.source: stdout` / `stderr`), writing every byte to the original
  descriptor first and never holding the writer up. The remote
  `signals.console` mode, `minSeverity` and `sampleRate` apply as to
  `Traceway.log`.
- **Replay images are smaller** (new in 2.1.0): one pixel per point; opaque pictures
  JPEG at 0.45 up to 384 px a side, see-through ones always PNG (never a JPEG,
  which replayed them as a black or white box) up to 192 px; at most 48 KiB
  after one retry at half size; up to 128 pictures per capture, and a
  new one past that evicts the one shown longest ago instead of waiting.
- `flush()` on the main thread waits at most 2 seconds whatever its timeout,
  as on Android.
- `app.user.affected` counts `anr` and `oom`.

## 0.1.0

Errors and crashes over the `/api/report` protocol.
