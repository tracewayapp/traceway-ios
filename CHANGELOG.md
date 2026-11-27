# Changelog

## 2.0.0-beta.1 — unreleased

Rebuilt on the official OpenTelemetry Swift SDK, at parity with the browser
SDK 2.x and the Flutter and Android SDKs 2.0: OTLP logs, spans and metrics, a
ring buffer on the device, remote config over OpAMP, captures, recording
triggers, taps, wireframe session replay and app performance metrics.

- **Breaking**: requires a server with OTLP/OpAMP support for iOS projects; the
  1.x `/api/report` protocol is gone. Options `debounceMs`, `retryDelayMs`,
  `maxPendingExceptions`, `maxLocalFiles` and `localFileMaxAgeHours` were
  removed. Requires Xcode 26.4 (Swift 6.3) or later.
- **OpenTelemetry**: records are made with `opentelemetry-swift-core` 2.6
  (`LoggerProviderSdk`, `TracerProviderSdk`) and sent by the
  `OtlpHttpLogExporter` / `OtlpHttpTraceExporter` of `opentelemetry-swift` 2.6
  as gzipped protobuf. When the app has not set up OpenTelemetry itself,
  Traceway's providers become the global ones. `Traceway.tracer` is the SDK's
  tracer.
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
  read with `kinfo_proc`, or from `Traceway.start` when iOS prewarmed the
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
  Traceway or standalone without a connection string.
- **Outbox**: batches that fail for a reason that may pass are kept on disk per
  destination (24 hours, 200 batches) and sent again later.
- Unsent 1.x reports and crash records are sent once over OTLP on the first
  start.
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
  - `Traceway.initialize(connectionString:options:)` starts the SDK (the
    other SDKs' `init`, which Swift keeps for initializers); `start` is a
    deprecated alias.
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
  downscaled to their displayed size (1.5 px per point, at most 512 px), JPEG
  at 0.6 (PNG when small and see-through), at most 96 KiB each and 4 MiB per
  session, encoded off the main thread, sent once per bitmap and size, never
  under a privacy mask. `wifi` means unmetered (`NWPathMonitor`: not
  cellular, a hotspot or Low Data Mode), decided for each frame. Session
  events carry `traceway.replay.images` and `traceway.replay.image_bytes`.
- **Wireframe**: the shared stylesheet is byte for byte the Android and
  Flutter SDKs' (Apple's font stack is now inline on the screen node).
  `WireframeRoots` finds the windows, the SwiftUI converters live in
  `WireframeSwiftUICapture.swift`, `CollectionBudget` in a file of its own,
  and the recorder hands the controller a `SessionRecordingPayload` (it was
  `RecordingClip`). [Docs/Wireframe.md](Docs/Wireframe.md) describes the
  pipeline.

## 0.1.0

Errors and crashes over the `/api/report` protocol.
