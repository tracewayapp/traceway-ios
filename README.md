# Traceway iOS SDK

Error tracking, session context and session replay for iOS apps, built on the
official [OpenTelemetry Swift](https://github.com/open-telemetry/opentelemetry-swift)
SDK. Exceptions and crashes arrive with their stack traces, the breadcrumbs
that led up to them and a wireframe replay of the last seconds on screen.
What is collected is controlled from the Traceway dashboard over
[OpAMP](https://opentelemetry.io/docs/specs/opamp/), per app version, user or
device, without a release.

> **2.0 is a beta.** It speaks OTLP and OpAMP and needs a Traceway server that
> accepts iOS projects on those endpoints. On an older server stay on 1.x. See
> [Migrating from 1.x](#migrating-from-1x).

## Features

- Uncaught `NSException`s and fatal signals (Swift traps, `fatalError`, bad
  memory access), symbolicated server-side from your uploaded dSYMs
- **OpenTelemetry inside**: every record is an OpenTelemetry log record or span
  made with `opentelemetry-swift`, and leaves through its OTLP/HTTP exporters
- **Ring buffer**: logs, requests, navigation, taps and custom events stay on
  the device and are uploaded only when something goes wrong
- **Remote config over OpAMP**: signal modes, sample rates, triggers and
  captures from the project's **Data Collection** page; or the same settings
  in the app with `collection:`
- **Captures on demand**, from the dashboard or from a recording trigger on the
  device (a journey of taps, screens and log lines)
- **Wireframe session replay**: the view hierarchy recorded as an HTML
  wireframe and replayed in the dashboard's rrweb player; small, cheap, and
  never a screenshot
- **Taps that name the view**: every tap is recorded with a CSS-like selector
  (`UIButton#pay`, `UIButton[text="Delete"]`) that click steps of recording
  triggers match
- Network requests as client spans with the official URLSession
  instrumentation, and W3C `traceparent` propagation to your backend
- Sessions, with the breadcrumb timeline of each one
- **Any OpenTelemetry backend**: send logs and spans to an OpenTelemetry
  Collector, Grafana, Honeycomb or any OTLP/HTTP receiver, next to Traceway or
  without it
- Telemetry that failed to send is kept on disk and retried; issues are written
  to disk before they are sent

## Requirements

- iOS 13.0+
- Xcode 26.4+ (Swift 6.3). The OpenTelemetry Swift packages need Swift 6, and
  the `swift-log` release SwiftPM resolves for them needs the Swift 6.3
  compiler.

## Installation (Swift Package Manager)

```swift
.package(url: "https://github.com/tracewayapp/traceway-ios.git", from: "2.0.0-beta.1"),
```

then add `"Traceway"` to your target's dependencies. The package brings in
`opentelemetry-swift-core`, `opentelemetry-swift` and `swift-protobuf`;
SwiftPM also resolves (but does not build) the gRPC and NIO packages
`opentelemetry-swift` declares.

## Quick start

Start the SDK as early as possible: in your `App` initializer (SwiftUI) or
`application(_:didFinishLaunchingWithOptions:)` (UIKit).

```swift
import SwiftUI
import Traceway

@main
struct MyApp: App {
    init() {
        Traceway.start(
            connectionString: "your-token@https://traceway.example.com",
            options: TracewayOptions(screenCapture: true)
        )
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
```

The connection string is the project token and the server URL, as the
project's Connection page shows it. The 1.x form ending in `/api/report` works
too. An invalid one does not take the app down: `start` returns nil, logs why,
and the app runs without the SDK.

## Manual capture

```swift
do {
    try checkout()
} catch {
    Traceway.capture(error, attributes: ["order": order.id])
}

Traceway.capture(message: "User completed checkout")

// A named product event; triggers can match it by name.
Traceway.track("checkout_failed", attributes: ["reason": "card_declined"])

// Breadcrumbs for the session timeline.
Traceway.log("Loaded 12 items")
Traceway.recordAction(category: "cart", name: "add_item", data: ["sku": "SKU-123"])

// Attached to every later record, and usable to target this user from the
// dashboard.
Traceway.setAttribute("user.id", user.id)

// Send what is ready now.
Traceway.flush(timeout: 5)
```

For spans of your own, `Traceway.tracer` is the SDK's OpenTelemetry tracer.
If your app has not set up OpenTelemetry itself, Traceway's providers are also
registered as the global ones (`OpenTelemetry.instance`), so instrumentation
that uses them joins the session.

## How collection works

Every record belongs to a *signal*, and each signal has a mode:

| Mode | Meaning |
|------|---------|
| `stream` | sent as soon as it is produced |
| `buffer` | kept in a ring buffer on the device (2 MB / 10 minutes by default) until a trigger flushes it |
| `off` | dropped |

| Signal | Source | Default |
|--------|--------|---------|
| `errors` | crashes, uncaught `NSException`s, `Traceway.capture` | stream |
| `messages` | `Traceway.capture(message:)` | stream |
| `console` | `Traceway.log` | buffer |
| `network` | URLSession requests (client spans) | buffer |
| `navigation` | view controllers appearing, `Traceway.recordNavigation`, `.tracewayScreen` | buffer |
| `userActions` | taps (`browser.user_action.click`) | buffer |
| `custom` | `Traceway.recordAction`, `Traceway.track`, your own spans | buffer |
| replay | wireframe screen recording | buffer |

The built-in trigger fires on every exception: it uploads the buffered
breadcrumbs of the last 10 minutes and the replay clip. An app that never
throws sends only its session start and end. Clips are rationed to one per 5
seconds and 20 per session; breadcrumbs are still sent for the exceptions in
between.

`recordAllSessions: true` streams every breadcrumb signal and the replay
instead. The signal names, modes, triggers and limits are the browser and
Flutter SDKs', so one rule can target all of them.

## Remote config

The SDK polls the server over OpAMP (plain HTTP, protobuf): at start, every 5
minutes by default (the server sets the interval), when the app returns to the
foreground, and about 2 seconds after `Traceway.setAttribute` or a new session.
It applies the collection settings defined under **Project → Data Collection**:
signal modes and sample rates, buffer sizes, extra triggers and on-demand
captures of one user or device.

- The `capture*` options, `screenCapture` and `sessions` are **ceilings**:
  remote settings can lower what is collected but never raise it. With
  `captureNetwork: false` no rule can turn network capture on, and without
  `screenCapture: true` nothing is recorded. `sampleRate`,
  `baselineSampleRate` and `recordAllSessions` are defaults a rule can change
  either way.
- The last applied settings are cached, so they are in effect from the first
  moment of the next start.
- `remoteConfig: false` never polls; standalone (no connection string) the SDK
  never polls either.

### Local config

`collection:` takes the same settings document a rule holds and lays it over
the built-in defaults. With `remoteConfig: true` the server's rules apply on
top of it; with `remoteConfig: false` it is the whole policy.

```swift
Traceway.start(
    connectionString: "...",
    options: TracewayOptions(
        screenCapture: true,
        remoteConfig: false,
        collection: [
            "signals": ["network": ["mode": "stream"]],
            "buffer": ["maxAgeSeconds": 300],
            "triggers": [[
                "id": "checkout-failed-twice",
                "steps": [[
                    "match": ["key": "event.name", "op": "eq", "value": "checkout_failed"],
                    "count": 2, "periodSeconds": 60,
                ]],
                "actions": [[
                    "type": "capture", "durationSeconds": 300, "lookbackSeconds": 120, "replay": true,
                ]],
            ]],
        ]
    )
)
```

An invalid document is ignored with a console warning, and the defaults apply.

## Captures

A capture uploads what the device holds from its lookback window and then
streams the selected signals, and the replay when it asks for it, until it
ends. Records sent under a capture carry its id (`traceway.capture.ids`).

- **From the dashboard**: the Capture button on a session or issue targets one
  installation (`service.instance.id`, see `Traceway.instanceId`), user
  (`user.id`) or session. The device starts it at its next poll.
- **From a trigger** (`{"type": "capture", ...}`): started on the device the
  moment the trigger fires. It survives app restarts until it ends; firing
  again only extends it.

While a capture streams replay, the recording leaves as consecutive segments
that each start with a full snapshot. An exception during a streaming capture
still gets a clip of its own.

### Recording triggers: journeys of taps, screens and logs

| Step | Matches |
|------|---------|
| `{"event": {"type": "click", "value": "<selector>"}}` | a tap on a view the selector matches, or inside one |
| `{"event": {"type": "navigation", "value": "/orders/{id}"}}` | arriving at a screen; `{id}` is one non-empty segment |
| `{"event": {"type": "log", "value": "Profile loaded", "mode": "contains"}}` | a `Traceway.log` line or a `capture(message:)` (`exact` by default) |

Hover steps never match on iOS. Steps match in order, each within its
`withinSeconds` of the previous one; progress survives an app restart within
the session.

#### Naming views

Click selectors run over the view under the finger and its superviews, with
the CSS subset the dashboard validates:

| Selector | Matches a view that |
|----------|---------------------|
| `UIButton`, `CheckoutButton` | is of that class (module and generic arguments left out, any case) |
| `#pay` | has `accessibilityIdentifier` `pay` |
| `.button` | has that role from its accessibility traits or class: `button`, `link`, `header`, `image`, `textField`, `slider`, `toggle`, `selected` |
| `[label="Delete"]` | has that `accessibilityLabel` |
| `[text="Pay"]` | shows that text: a label's, a button's title, or the labels under it; never what is typed into a field |
| `[key="42"]` | has that `tag` |
| `[type="_Private"]` | is of a class that cannot be written as a tag |

Attribute values take `=`, `^=`, `$=`, `*=`, `~=` and `|=`; combinators are
descendant (space), child (`>`), adjacent (`+`) and general (`~`) sibling. A
tap matches when the view under the finger or any superview does.

Every tap is recorded as `browser.user_action.click` with the selector of the
control that handled it (`browser.css_selector`), shown on the session
timeline: an identifier first (`UIButton#pay`), then the shown text, the
label, and the class alone. `accessibilityIdentifier`s (the ones UI tests use)
are the most stable choice. Text inside a privacy mask is never sent.

#### Naming screens

A view controller that appears is recorded as `/` and its class name
(`/CheckoutViewController`); a hosting controller as its SwiftUI root view
(`/ContentView`). Containers (navigation, tab, split and page controllers),
child view controllers and the system's own controllers are not screens.
SwiftUI navigation and routers report their screens themselves:

```swift
CheckoutView()
    .tracewayScreen("/checkout")

// or anywhere:
Traceway.recordNavigation("/orders/\(order.id)")
```

## Session replay

```swift
TracewayOptions(screenCapture: true)
```

Instead of pictures, the SDK records the view hierarchy. Up to `fps` times a
second (4 by default) it walks the app's windows and turns what they show into
HTML: views with their background colors, corners, borders, shadows,
opacity, clipping, transforms and scroll positions, labels with their font
size, weight and color, text fields, switches, sliders, progress views and
activity indicators drawn from their state. What changes from one frame to the
next becomes an rrweb mutation, so the dashboard replays the session with the
same player as a browser session, taps and drags included. A frame is kept
only when the screen changed.

- **Small and cheap.** No pixels are read or encoded: a segment is a few
  kilobytes of JSON.
- **Not pixel-exact.** Text is drawn in the browser's system font, template
  and SF Symbol images are tinted icons, other images are placeholders, views
  that draw themselves (`draw(_:)`) are dashed outlines, and web views, maps,
  video and Metal views are labeled placeholders.
- **SwiftUI** draws most of its content without views of its own. Its colored
  and rounded shapes are recorded from layers, and its text from the hosting
  view's accessibility elements; images are placeholders. Coverage is not as
  complete as UIKit's.
- **Privacy.** Text typed into fields is replaced with `*` unless remote
  settings set `replay.maskAllInputs: false`; secure fields always are. The
  keyboard is a plain box, never its keys.

Clips follow the same rules as breadcrumbs: the last `maxBufferFrames` frames
stay on the device, an exception uploads the clip of the last 30 seconds, and
captures stream the session as segments.

### Privacy masks

```swift
// UIKit
cardNumberLabel.tracewayPrivacyMask = .blank()          // a black box, nothing inside recorded
profileView.tracewayPrivacyMask = .blur                 // layout kept, text as *, images as placeholders

// SwiftUI
Text(card.number).tracewayPrivacyMask(.blank(color: .gray))
ProfileView().tracewayPrivacyMask()                     // .blur
```

A masked view's text is also left out of recorded taps.

## Network requests

Every URLSession request is recorded as a client span by the official
`URLSessionInstrumentation` of opentelemetry-swift, with the stable HTTP
semantic conventions (`http.request.method`, `url.full`,
`http.response.status_code`, `error.type`). The SDK's own requests are never
recorded.

`propagateTraceHeaderUrls` lists URL prefixes whose requests carry a W3C
`traceparent` header naming the request's span, so your backend's spans join
the app's trace in Traceway or any OpenTelemetry backend:

```swift
TracewayOptions(propagateTraceHeaderUrls: ["https://api.example.com/"])
```

It is empty by default, because a header a server does not expect can break a
strict CORS or request-signature check.

## Setups

### Everything on Traceway

```swift
Traceway.start(
    connectionString: "your-token@https://traceway.example.com",
    options: TracewayOptions(serviceName: "shop-app", environment: "production")
)
```

### Issues and replays on Traceway, other telemetry elsewhere

```swift
Traceway.start(
    connectionString: "your-token@https://traceway.example.com",
    options: TracewayOptions(
        telemetry: TracewayTelemetry(
            url: "https://collector.example.com/otlp",
            headers: ["x-ingest-key": "app-ingest-key"]
        ),
        collection: ["signals": ["network": ["mode": "stream"]]]
    )
)
```

The shared `url` gets `/v1/logs` and `/v1/traces` appended; a
`TracewayTelemetryEndpoint(url:headers:)` per signal is a complete URL, used as
given. Exceptions, messages and the SDK's session and control records still go
to Traceway, and only there, as do OpAMP and replays; ordinary logs and spans
go to the receiver. Both sides carry `session.id`. The Traceway token is never
sent to the receiver. Any key built into the app can be read out of it: use an
ingestion key that can only write.

### Standalone, without a Traceway server

```swift
Traceway.start(
    connectionString: nil,
    options: TracewayOptions(
        telemetry: TracewayTelemetry(url: "https://collector.example.com/otlp")
    )
)
```

`telemetry` must then have a `url` or both signal endpoints. Remote config,
replay uploads and session records are off; exceptions are OTLP log records
with the event name `exception`, sent to your collector.

## Options

| Option | Default | Description |
|--------|---------|-------------|
| `sampleRate` | `1.0` | Share of exceptions and messages that are reported |
| `debug` | `false` | Log SDK activity with `NSLog` |
| `version` | bundle version | Sent as `service.version` |
| `serviceName` | bundle identifier | Sent as `service.name` |
| `environment` | — | Sent as `deployment.environment.name` |
| `attributes` | `[:]` | Attributes attached to every record |
| `screenCapture` | `false` | Record a wireframe replay |
| `fps` | `4` | Most wireframe frames captured per second (1–15) |
| `maxBufferFrames` | `150` | Frames in the replay ring; the upper bound of every clip |
| `persistToDisk` | `true` | Keep state and undelivered telemetry on disk; record hard crashes |
| `captureLogs` | `true` | Record `Traceway.log` |
| `captureNetwork` | `true` | Record URLSession requests |
| `captureNavigation` | `true` | Record screens |
| `captureUserActions` | `true` | Record taps and feed them to recording triggers |
| `recordAllSessions` | `false` | Stream breadcrumbs and replay all the time |
| `baselineSampleRate` | `0` | Share of sessions whose breadcrumbs stream continuously |
| `sessions` | `true` | Send session records (`session.start` / `session.end`) |
| `remoteConfig` | `true` | Poll for collection settings over OpAMP |
| `collection` | — | Local collection settings (see [Local config](#local-config)) |
| `exportDelayMs` | `1000` | How long finished records wait to be sent as one batch |
| `propagateTraceHeaderUrls` | `[]` | URL prefixes whose requests carry `traceparent` |
| `telemetry` | — | Another OTLP/HTTP receiver (see [Setups](#setups)) |

## Crashes

After `start`, the SDK records:

- **Uncaught `NSException`s**, on the crashing thread: written to disk and sent
  for up to two seconds before the app ends.
- **Fatal signals** (`SIGTRAP`, `SIGILL`, `SIGABRT`, `SIGSEGV`, `SIGBUS`,
  `SIGFPE`): written to disk by an async-signal-safe handler and reported on
  the **next launch**, with the session they happened in.

Stack traces carry the binary images' UUIDs and offsets; the server
symbolicates them against the dSYMs you upload with
[`Scripts/upload_symbols.sh`](Scripts/upload_symbols.sh).

When the **debugger is attached**, lldb catches these signals first, so test
crash capture without it: install from Xcode, stop, and launch the app from
the home screen, then relaunch after the crash.

## Migrating from 1.x

- **Server**: 2.0 sends OTLP to `/api/otel/v1/logs` and `/api/otel/v1/traces`,
  polls `/api/otel/v1/opamp` and uploads replays to `/api/recordings`. There is
  no fallback to the 1.x `/api/report` protocol.
- **Connection string**: unchanged; the bare server URL works too. It is now
  optional (standalone mode).
- **Unsent 1.x reports** younger than 12 hours, and crashes 1.x recorded, are
  sent once over OTLP on the first 2.0 start.
- **Removed options**: `debounceMs`, `retryDelayMs`, `maxPendingExceptions`,
  `maxLocalFiles`, `localFileMaxAgeHours`.
- **API**: `Traceway.start`, `capture(_:)`, `capture(error:)`,
  `capture(message:)` and `flush(timeout:)` are unchanged. New:
  `track`, `log`, `recordAction`, `recordNavigation`, `setAttribute(s)`,
  `removeAttribute`, `clearAttributes`, `shutdown`, `refreshConfig`,
  `instanceId`, `sessionId`, `tracer`, privacy masks and `.tracewayScreen`.
- **Issues regroup once**: 2.0 reports exceptions as OpenTelemetry `exception`
  events (`exception.type`, `exception.message`, `exception.stacktrace`).

## Testing

```sh
swift test            # every platform-neutral suite, on macOS or Linux
./Scripts/test.sh     # + the iOS Simulator XCTest run and a device-arch build
```

CI (`.github/workflows/tests.yml`) runs the suite on Linux and macOS, the
XCTest suite on the iOS Simulator, and, on manual dispatch, on a real iPhone
via Firebase Test Lab. See [CI/README.md](CI/README.md).

## License

See [LICENSE](LICENSE).
