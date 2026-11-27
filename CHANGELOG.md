# Changelog

## 2.0.0-beta.1 — unreleased

Rebuilt on the official OpenTelemetry Swift SDK, at parity with the browser
SDK 2.x and the Flutter SDK 2.0 (without app performance metrics): OTLP logs
and spans, a ring buffer on the device, remote config over OpAMP, captures,
recording triggers, taps, and wireframe session replay.

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
  events stay on the device (2 MB / 10 minutes) and are uploaded when an
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
  text-shaped bars. Text fields are masked; `tracewayPrivacyMask` (UIKit) and
  `.tracewayPrivacyMask()` (SwiftUI) blank or blur views. Clips go to
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
  `refreshConfig`, `instanceId`, `sessionId`, `tracer`.

## 0.1.0

Errors and crashes over the `/api/report` protocol.
