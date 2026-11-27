# Traceway iOS SDK

Error tracking, session context and session replay for iOS apps, built on the
official [OpenTelemetry Swift](https://github.com/open-telemetry/opentelemetry-swift)
SDK. Exceptions and crashes arrive with their stack traces, the breadcrumbs
that led up to them and, with `screenCapture: true`, a wireframe replay of the
last seconds on screen.
What is collected is controlled from the Traceway dashboard over
[OpAMP](https://opentelemetry.io/docs/specs/opamp/), per app version, user or
device, without a release.

> **2.0 is a beta.** It speaks OTLP and OpAMP and needs a Traceway server that
> accepts iOS projects on those endpoints. On an older server stay on 0.1.x. See
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
  never a screenshot. The pictures image views show can be included, on
  Wi-Fi only or always, set from the dashboard
- **Taps that name the view**: every tap is recorded with a CSS-like selector
  (`UIButton#pay`, `UIButton[text="Delete"]`) that click steps of recording
  triggers match
- **Issues with their screen**: exceptions and messages carry the screen, its
  route template, the screen before it and the window size
- **Interactions**: a span for one user action (`checkout`) that the requests
  and issues inside it belong to
- **App performance metrics**: app start, screen display times, slow and
  frozen frames, hangs, crashes, memory and requests as OTLP metrics, with the
  Android and Flutter SDKs' names, plus metrics of your own
- Network requests as client spans with the official URLSession
  instrumentation, and W3C `traceparent` propagation to your backend
- Sessions, with the breadcrumb timeline of each one
- **Any OpenTelemetry backend**: send logs, spans and metrics to an OpenTelemetry
  Collector, Grafana, Honeycomb or any OTLP/HTTP receiver, next to Traceway or
  without it
- Telemetry that failed to send is kept on disk and retried; issues are written
  to disk before they are sent

## Requirements

- iOS 13.0+
- Xcode 26.4+ (Swift 6.3). The OpenTelemetry Swift packages need Swift 6, and
  the `swift-log` release SwiftPM resolves for them needs the Swift 6.3
  compiler.

## Installation

With the Swift Package Manager:

```swift
.package(url: "https://github.com/tracewayapp/traceway-ios.git", from: "2.0.0-beta.1"),
```

SwiftPM only offers a prerelease to a requirement that names one. The package
identity is `traceway-ios` and the library product is `Traceway`, so a target
needs the explicit form:

```swift
.target(
    name: "MyApp",
    dependencies: [.product(name: "Traceway", package: "traceway-ios")]
),
```

The package brings in
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
        Traceway.initialize(
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
too. An invalid one does not take the app down: `initialize` returns nil, logs why,
and the app runs without the SDK.

## Manual capture

### Errors and messages

```swift
do {
    try checkout()
} catch {
    Traceway.captureException(error, attributes: ["order": order.id])
}

Traceway.captureMessage("User completed checkout")
```

Both are issues (signals `errors` and `messages`) and stream at once. Each
carries the screen it happened on: `app.screen.name`, `app.screen.route` (see
[Naming screens](#naming-screens)), `app.screen.previous`,
`app.screen.duration_ms` (how long the screen had been shown) and `viewport`
(the window size in points, `390x844`). An exception carries the stack of the
caller.

Network noise is not reported: `TracewayOptions.defaultIgnoreErrors` drops URL
errors -1001 (timed out), -1003 (host not found), -1004 (cannot connect),
-1005 (connection lost) and -1009 (offline), "The network connection was
lost", "The Internet connection appears to be offline", and anything matching
`/timeout/i`, `/status code (of )?4\d{2}/` or `/failed: 4\d{2}/`. Patterns
match the first line `Type: message` (an `NSError` is
`NSURLErrorDomain: The request timed out. (code -1001)`), never the stack.
`ignoreErrors` replaces the list; `beforeCapture` sees every issue and drops
it by returning false:

```swift
TracewayOptions(
    ignoreErrors: TracewayOptions.defaultIgnoreErrors + ["CancellationError", .regex(#"^Shop\.Retry"#)],
    beforeCapture: { captured in
        // captured.error, .type, .message, .isMessage, .attributes, .stackTrace
        captured.attributes["app.screen.name"] != "/debug"
    }
)
```

A string matches as a substring, `.regex` with search semantics. A
`beforeCapture` that throws keeps the issue (and logs why with `debug`). Crashes
(uncaught `NSException`s and the fatal signals the signal handler recorded) end
the process, are always reported and pass through neither.

### Logs

```swift
Traceway.log("Loaded 12 items")
Traceway.log("Cache miss", level: .warn, attributes: ["cache": "images"])
```

A log line is an OpenTelemetry log record without an event name (signal
`console`), with the severity of its `TracewayLogLevel` (`trace`, `debug`,
`info`, `warn`, `error`, `fatal`), `log.source: api` and your attributes. The
console's `minSeverity` setting (`info` by default) drops lines below it.

### Actions and events

```swift
// A named product event; triggers can match it by name.
Traceway.track("checkout_failed", attributes: ["reason": "card_declined"])

// A breadcrumb for the session timeline.
Traceway.recordAction(category: "cart", name: "add_item", data: ["sku": "SKU-123"])
```

`track` values that are strings, booleans and numbers keep their type.
`recordAction` sends `traceway.action.category`, `traceway.action.name` and
`traceway.action.data` (the data as JSON).

### Attributes and users

```swift
// Attached to every later record, and usable to target this user from the
// dashboard.
Traceway.setAttribute("user.id", user.id)
Traceway.setAttributes(["plan": "pro", "cohort": "beta"])
Traceway.removeAttribute("cohort")
Traceway.clearAttributes()

// Send what is ready now.
Traceway.flush(timeout: 5)
```

There is no `setUser`: `user.id` is an attribute like any other. At most 64
attributes are kept. `Traceway.instanceId` (`service.instance.id`) and
`Traceway.currentSessionId` (`session.id`) name this installation and session.

### Interactions

```swift
let checkout = Traceway.startInteraction("checkout", attributes: ["cart.items": cart.count])
do {
    try checkout.run { try api.placeOrder(cart) }
} catch {
    checkout.captureException(error)
}
checkout.end()
```

An interaction is a span (`traceway.interaction: true`, signal `custom`).
Requests started in its `run` are its child spans, and the exceptions,
messages and logs recorded there carry its trace and span id. An exception
captured through it, or `end(failed: true)`, marks it failed. One started
inside another's `run` is its child; `traceId` and `spanId` name it. Before
`initialize` it records nothing and `run` still runs its code.

For spans of your own, `Traceway.tracer` is the SDK's OpenTelemetry tracer.
If your app has not set up OpenTelemetry itself, Traceway's providers are also
registered as the global ones (`OpenTelemetry.instance`), so instrumentation
that uses them joins the session.

## How collection works

Every record belongs to a *signal*, and each signal has a mode:

| Mode | Meaning |
|------|---------|
| `stream` | sent as soon as it is produced |
| `buffer` | kept in a ring buffer on the device (2 MiB / 10 minutes by default) until a trigger or a capture uploads it |
| `off` | dropped |

| Signal | Source | Default |
|--------|--------|---------|
| `errors` | crashes, uncaught `NSException`s, `Traceway.captureException` | stream |
| `messages` | `Traceway.captureMessage` | stream |
| `console` | `Traceway.log` | buffer |
| `network` | URLSession requests (client spans) | buffer |
| `navigation` | view controllers appearing, `Traceway.recordNavigation`, `.tracewayScreen` | buffer |
| `userActions` | taps (`browser.user_action.click`) | buffer |
| `custom` | `Traceway.recordAction`, `Traceway.track`, interactions, your own spans | buffer |
| replay | wireframe screen recording | buffer |

The built-in trigger fires on every exception: it uploads the buffered
breadcrumbs of the last 10 minutes and the replay of the last 30 seconds, at
most the frames the replay ring holds (`maxBufferFrames`). An app that never
throws sends only its session and control records (`session.start`,
`session.end`, `traceway.session.update`, `traceway.config.applied`) and its
metrics. Clips are rationed to one per 5
seconds and 20 per session; breadcrumbs are still sent for the exceptions in
between. Identical errors within a second collapse into one, and at most 60
errors a minute are sent; the next one carries `traceway.error.suppressed_count`.

`recordAllSessions: true` streams every breadcrumb signal and the replay
instead. The signal names, modes, triggers and limits are the browser and
Flutter SDKs', so one rule can target all of them.

When the SDK drops data (the session's replay budget is used up, errors were
suppressed, replay segments failed to upload) it sends a
`traceway.collection.health` record with the counts, at most once a second at
first and backing off to once every five minutes; the session's first one
also updates the session.

## Remote config

The SDK polls the server over OpAMP (plain HTTP, protobuf): at start, at the
interval the server sets (5 minutes by default, 60 seconds while a capture
targets the device), when the app returns to the foreground, and about 2
seconds after `Traceway.setAttribute` or a new session.
It applies the collection settings defined under **Project → Data Collection**:
signal modes and sample rates, buffer sizes, replay settings, extra triggers
and on-demand captures of one user or device.

- The `capture*` options (`captureMetrics` included), `screenCapture`,
  `replayImages` and `sessions` are **ceilings**: remote settings can lower
  what is collected but never raise it. With `captureNetwork: false` no rule
  can turn network capture on, and without `screenCapture: true` nothing is
  recorded. `sampleRate`, `baselineSampleRate` and `recordAllSessions` are
  defaults a rule can change either way.
- The last applied settings are cached, so they are in effect from the first
  moment of the next start.
- `remoteConfig: false` never polls; standalone (no connection string) the SDK
  never polls either.

### Local config

`collection:` takes the same settings document a rule holds and lays it over
the built-in defaults. With `remoteConfig: true` the server's rules apply on
top of it; with `remoteConfig: false` it is the whole policy.

```swift
Traceway.initialize(
    connectionString: "...",
    options: TracewayOptions(
        screenCapture: true,
        collection: [
            "signals": ["network": ["mode": "stream"]],
            "replay": ["images": "always"],
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
        ],
        remoteConfig: false
    )
)
```

Values must be JSON types (strings, numbers, booleans, arrays and
dictionaries). A document that is not an object, or names another
`schemaVersion`, is ignored with a console warning, and the defaults apply; in
a valid one, unknown fields and malformed values are skipped one by one.

## Captures

A capture uploads what the device holds from its lookback window and then
streams the selected signals, and the replay when it asks for it, until it
ends. Records sent while a capture from the dashboard runs carry its id
(`traceway.capture.ids`).

- **From the dashboard**: the Capture button on a session or issue targets one
  installation (`service.instance.id`, see `Traceway.instanceId`), user
  (`user.id`) or session. The device starts it at its next poll.
- **From a trigger** (`{"type": "capture", ...}`): started on the device the
  moment the trigger fires. It survives app restarts until it ends; firing
  again only extends it.

While a capture streams replay, the recording leaves as consecutive segments
of up to 10 seconds that each start with a full snapshot. An exception during a streaming capture
still gets a clip of its own.

### Recording triggers

Journeys of taps, screens and logs:

| Step | Matches |
|------|---------|
| `{"event": {"type": "click", "value": "<selector>"}}` | a tap on a view the selector matches, or inside one |
| `{"event": {"type": "navigation", "value": "/orders/{id}"}}` | arriving at a screen; `{id}` is one non-empty segment |
| `{"event": {"type": "log", "value": "Profile loaded", "mode": "contains"}}` | a `Traceway.log` line or a `captureMessage` (`exact` by default) |

Hover steps never match on iOS. Steps match in order, each within its
`withinSeconds` of the previous one; progress survives an app restart within
the session.

### Naming views

A click step takes a selector in CSS syntax. When a finger lifts, the SDK finds
the view it touched (the view UIKit's hit-testing returns and, below it, the
topmost visible subview under the finger, since labels and image views do not
take touches) and runs the selector over that view and its superviews up to the
window. A tap matches when the view under the finger or any superview matches,
the way a browser click matches its target or an ancestor. A tap lifts within
10 points of where it went down and before UIKit's long-press duration of
0.5 seconds.

| Selector | Matches a view that |
|----------|---------------------|
| `UIButton`, `CheckoutButton` | is of that class: module and generic arguments left out (`Shop.CheckoutButton<Int>` is `CheckoutButton`), any case; `*` is any view |
| `#pay` | has `accessibilityIdentifier` `pay` |
| `.button` | has that role, from its accessibility traits or its class: `button`, `link`, `header`, `image` (also any `UIImageView`), `textField` (`UITextField`, `UITextView`, the search field trait), `slider` (`UISlider`, the adjustable trait), `toggle` (`UISwitch`, iOS 17's toggle button trait), `selected` |
| `[key="42"]` | has `tag` 42 |
| `[identifier="pay"]` | has that `accessibilityIdentifier` |
| `[label="Delete"]` | has that `accessibilityLabel`: its own, else the first one directly below it while each view down there has a single subview (an icon button's image view) |
| `[text="Pay"]` | shows that text: a label's text or a button's title, else that of up to three labels under it joined by a space; never what is typed into a text field or text view |
| `[type="_Private"]` | is of a class that cannot be written as a tag |

```swift
payButton.accessibilityIdentifier = "pay"     // #pay, UIButton#pay
deleteButton.accessibilityLabel = "Delete"    // UIButton[label="Delete"]
payButton.setTitle("Pay now", for: .normal)   // UIButton[text="Pay now"]
cartView.accessibilityIdentifier = "cart"     // #cart UIButton: a button inside it
```

- Attribute values take `=`, `^=` (starts with), `$=` (ends with), `*=`
  (contains), `~=` (one of its words) and `|=`. Quote a value that is not a
  plain name.
- A selector is at most 256 characters and cannot contain `:`, `,` or `\`,
  also inside a quoted value (the dashboard refuses it): pseudo-classes and
  selector lists are not available.
- Combinators are descendant (space), child (`>`), adjacent (`+`) and general
  (`~`) sibling, over the view hierarchy (siblings are subviews of the same
  superview, in order). A `UIButton` holds its title in a label and, with a
  configuration, background views: use `#cart UIButton`, not `>`, across them.
- Text-based selectors break when the copy changes or the app is localized;
  `accessibilityIdentifier`s, the handles UI tests already use, are stable.
- **SwiftUI** controls have no views of their own: a tap on a SwiftUI button
  finds the hosting view, and `.accessibilityIdentifier` on a SwiftUI view is
  not read. Target SwiftUI journeys with navigation steps (`.tracewayScreen`)
  and log steps. `UIViewRepresentable` views are views like any other.
- `captureUserActions: false` turns taps, and click steps, off.

Every tap is recorded as `browser.user_action.click` with the selector of the
view that handled it (`browser.css_selector`), shown in a session's **Actions**:
copy it into a click step as it is, since the SDK only records a selector it
checked against the tapped view. The view that handled the tap is the nearest
control above the finger (a `UIControl`, a table or collection view cell, or a
view with its own tap or long-press recognizer; a view controller's root view
does not count), else the nearest label or image view, else the view under the
finger. Its selector is the first of these that exists and matches: an
`accessibilityIdentifier` (its own, a wrapper's up to six levels above, or one
inside it), its `tag`, the text it shows (up to 40 characters), its label, a
role, the class with the nearest identified superview in front
(`#cart UIButton`), and the class alone. The record also carries
`browser.tag_name`, `app.widget.name`, `app.widget.id`, `app.widget.text`,
`app.widget.label`, `app.screen.coordinate.x`, `app.screen.coordinate.y` and
`app.screen.name`. Text and labels inside a privacy mask or a secure text field
are never sent.

### Naming screens

A view controller that appears is recorded as `/` and its class name
(`/CheckoutViewController`); a hosting controller as its SwiftUI root view
(`/ContentView`). Containers (navigation, tab, split and page controllers),
child view controllers and the system's own controllers are not screens.
SwiftUI navigation and routers report their screens themselves:

```swift
CheckoutView()
    .tracewayScreen("/checkout")

// or anywhere, with the route template when the router knows it:
Traceway.recordNavigation("/orders/\(order.id)", action: "push", from: "/orders", route: "/orders/{id}")

// the route template of the current screen, until the next screen:
Traceway.setRoute("/orders/{id}")
```

`route` is the template the path was made from: passing it is the same as
calling `setRoute(_:)` right after the navigation.

A navigation is a `browser.navigation` record with `url.full`,
`navigation.action` (`push` or `pop`), `browser.navigation.type`,
`navigation.to`, `navigation.from`, `app.screen.name` and, while a route
template is set, `app.screen.route`. Issues carry the route too, and metrics
group the screen's display times, frames and hangs by it.

## Session replay

```swift
TracewayOptions(screenCapture: true)
```

### Wireframe

The replay is a wireframe only: no screenshot and no video of the screen is
ever recorded. Up to `fps` times a second (4 by default) the SDK walks the
app's windows and turns what they show into HTML: views with their background
colors, gradients, corners, borders, shadows, opacity, clipping, transforms
and scroll positions; labels with their font size, weight, style and color,
alignment, line breaking and rich text runs; buttons, text fields and text
views; switches, sliders, segmented controls, steppers, progress views, page
controls and activity indicators drawn from their state; shape and text
layers. SF Symbols and template images keep their shape (monochrome symbols
in their tint, palette and multicolor symbols in their own colors). iOS 26's
Liquid Glass bars, buttons, alerts and sheets are drawn as frosted shapes.
What changes from one frame to the next becomes an rrweb mutation, so the
dashboard replays the session with the same player as a browser session,
taps and drags included. A frame is kept only when the screen changed.

- **Small and cheap.** No screen pixels are read: a segment is a few
  kilobytes of JSON, plus the pictures when they are included.
- **Not pixel-exact.** Text is drawn in the browser's system font, images are
  placeholders unless pictures are included, views that draw themselves
  (`draw(_:)`) are dashed outlines, and web views, maps, video, camera and
  Metal views are labeled placeholders.
- **SwiftUI** draws most of its content without views of its own. Its colors,
  shapes, gradients and symbols are recorded from its layers, and the UIKit
  controls it hosts as UIKit. Its text is readable only through accessibility,
  which iOS fills in while an assistive technology (VoiceOver, Voice Control,
  Switch Control) runs; otherwise each `Text` is a neutral bar where its lines
  are, the way masked text would be.
- **Privacy.** Text typed into fields is replaced with `*` unless remote
  settings set `replay.maskAllInputs: false`; secure fields always show
  bullets. The keyboard is a plain box, never its keys.

How well each kind of view converts is checked on every CI run by the
wireframe gallery (see [Testing](#testing)). [Docs/Wireframe.md](Docs/Wireframe.md)
describes the pipeline, node ids, stylesheet and limits.

Clips follow the same rules as breadcrumbs: the last `maxBufferFrames` frames
stay on the device, an exception uploads the clip of the last 30 seconds, and
captures stream the session as segments. A session uploads at most 50 MiB and
10,000 rrweb events of replay.

### Images

The pictures `UIImageView`s show, and the image layers SwiftUI uses for
photos, can be part of the replay. Never a screenshot of the window: only the
bitmap the view shows, downscaled to its displayed size (1.5 pixels per
point, at most 512 pixels a side), as JPEG at quality 0.6 (PNG for small
see-through images), at most 96 KiB each and 4 MiB per session. A picture
seen for the first time is encoded off the main thread: the frame that first
shows it has the placeholder, a later one the picture. The same picture in
many cells is sent once.

| `replay.images` (setting) | Pictures |
|---|---|
| `off` | never: images are placeholders |
| `wifi` (default) | on an unmetered connection: not cellular, a personal hotspot or Low Data Mode |
| `always` | on any connection |

Set it in a rule's Signals tab on the dashboard, or in `collection`
(`"replay": ["images": "always"]`). `TracewayOptions.replayImages` (`.always`
by default) is the ceiling: `.off` keeps every image a placeholder whatever
the rules say. The connection is checked for each frame. Images under a
traceway mask are never included. Session events carry `traceway.replay.images`
(the policy at session start) and `traceway.replay.image_bytes`.

### Privacy masks

```swift
// UIKit
cardNumberLabel.tracewayMask = .blank()          // a black box, nothing inside recorded
profileView.tracewayMask = .blur                 // layout kept, text as *, images as placeholders

// UIKit, without code (or in Interface Builder's Identity inspector)
balanceView.accessibilityIdentifier = "traceway-mask"    // as .blur
pinView.accessibilityIdentifier = "traceway-blank"       // as .blank()

// SwiftUI
Text(card.number).tracewayMask(.blank(color: .gray))
ProfileView().tracewayMask()                     // .blur
```

A masked view's text and label are also left out of recorded taps, and a
`traceway-mask` or `traceway-blank` identifier is not reported as the view's
id. These are the markers the other Traceway SDKs read as a CSS class, an
Android view tag and a Flutter key. SwiftUI's `accessibilityIdentifier` is not
readable from the view hierarchy, so SwiftUI masks with `.tracewayMask(_:)`.
`tracewayPrivacyMask` (the property and the modifier) still works and is
deprecated.

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

## App performance metrics

The SDK measures the app on the device and uploads the numbers as OTLP
metrics to `/api/otel/v1/metrics`: base-2 exponential histograms and counters
(delta temporality), one small payload every five minutes and when the app
goes to the background. Nothing is sent per observation, and no user, device
or session id is a dimension. The names, dimensions and thresholds are the
Android and Flutter SDKs', so the same dashboards and SLOs work for all three.

| Metric | What it measures |
|--------|------------------|
| `app.start.duration` (`start_type` `cold` / `warm` / `hot`) | Cold: from the process start (`kinfo_proc`; from `Traceway.initialize` when iOS prewarmed the process) to the first frame drawn while the app is active, only when the process was launched to show its UI. Warm: the first return of a process launched in the background, or a return that reconnects a scene. Hot: from any other return to the foreground to the next frame |
| `app.screen.ttid` (`screen`) | Time to initial display: from the moment a view controller begins to load (`viewDidLoad`, or `viewWillAppear` for a view loaded before) to the first frame after `viewDidAppear`; from the call for `recordNavigation` and `.tracewayScreen` |
| `app.screen.ttfd` (`screen`) | Time to full display: from the same start until the app calls `Traceway.reportFullyDisplayed()` |
| `app.frames.slow`, `app.frames.frozen` (with `.total`, by `screen`) | A `CADisplayLink` in the foreground: slow when a frame took more than one and a half frame durations at the display's rate, frozen at 700 ms or more |
| `app.hang`, `app.hang.duration` | The main thread ran nothing for 2 s or more while the app was in the foreground; not while a debugger is attached unless `reportHangsInDebug` is set |
| `app.crash` | Uncaught `NSException`s, and fatal signals counted at the next start |
| `app.session`, `app.user`, `app.user.affected` (`issue`) | Sessions; users counted once a day per installation, and once a day per problem they met (`crash`, `hang`, `slow_start`, `frozen_frames`, `failed_request`), so no id leaves the device |
| `app.memory.peak` | The process's peak physical footprint (`task_vm_info`, what the system's memory limit counts), once per session |
| `app.request.duration`, `app.request.bytes`, `app.request.failed` (`host`) | Every URLSession request the SDK records (up to 20 hosts, then `other`) |

A start counts the user as affected (`slow_start`) at 5 s cold, 2 s warm and
1.5 s hot. Screens are route templates when the app
[names them](#naming-screens), else paths with ids folded (`/orders/8841` →
`/orders/:id`); past 200 series in a payload the screen folds to `other`.
Resource dimensions are the app version, environment, OS and its major
version, form factor (`phone`, `tablet`, `desktop` for an iOS app on a Mac)
and a coarse device class from the RAM (`low` under 3 GB, `mid` under 6 GB,
`high`).

```swift
// The screen has what it loads: ends its time to full display.
Traceway.reportFullyDisplayed()

// App-defined metrics, charted like the built-in ones.
Traceway.metric("checkout.duration", value: 1234, dimensions: ["plan": "pro"])
Traceway.count("cart.add")
Traceway.setMetricDimension("experiment", "b") // `custom.experiment` on every metric
```

Custom names are `[a-z][a-z0-9_.]`, up to 63 characters, outside `app.`,
`browser.`, `traceway.` and `custom.`, with at most two dimensions.
`metricDimensions` (up to two) sets `custom.<key>` from the start.

A payload is kept on the device until the server answered it, and one that
failed or was cut off by the app ending is sent once more (marked
`traceway.retry`) after the next upload that works or at the next start;
the server drops a copy it already has. Bodies stay under 60 KB (a larger
payload is split); a 400, 401, 403, 413 or 422 is not retried.

`captureMetrics: false` turns it all off. A rule's `metrics` section switches
metrics off (`enabled`), samples sessions (`sampleRate`; counts are weighted
back by the server) or changes the upload interval (`flushSeconds`, 30–3600),
and a plan's `limits.metrics: "off"` turns them off for the organization.
With `telemetry`, metrics go to the receiver's `/v1/metrics` (or its
`metrics` endpoint) instead of Traceway.

## Setups

### Everything on Traceway

```swift
Traceway.initialize(
    connectionString: "your-token@https://traceway.example.com",
    options: TracewayOptions(serviceName: "shop-app", environment: "production")
)
```

### Issues and replays on Traceway, other telemetry elsewhere

```swift
Traceway.initialize(
    connectionString: "your-token@https://traceway.example.com",
    options: TracewayOptions(
        collection: ["signals": ["network": ["mode": "stream"]]],
        telemetry: TracewayTelemetry(
            url: "https://collector.example.com/otlp",
            headers: ["x-ingest-key": "app-ingest-key"]
        )
    )
)
```

The shared `url` gets `/v1/logs`, `/v1/traces` and `/v1/metrics` appended; a
`TracewayTelemetryEndpoint(url:headers:)` per signal (`logs`, `traces`,
`metrics`) is a complete URL, used as given; a blank `url` is unset.
Exceptions, messages and the SDK's session and control records still go to
Traceway, and only there, as do OpAMP and replays; ordinary logs, spans and
metrics go to the receiver. Both sides carry `session.id`. The Traceway token
is never sent to the receiver. Any key built into the app can be read out of
it: use an ingestion key that can only write.

### Standalone, without a Traceway server

```swift
Traceway.initialize(
    connectionString: nil,
    options: TracewayOptions(
        telemetry: TracewayTelemetry(url: "https://collector.example.com/otlp")
    )
)
```

`telemetry` must then have a `url` or all three signal endpoints. Remote config,
replay uploads and session records are off; exceptions are OTLP log records
with the event name `exception`, sent to your collector.

## Options

In the order of `TracewayOptions(...)`, the same order as the other Traceway
mobile SDKs.

| Option | Default | Description |
|--------|---------|-------------|
| `sampleRate` | `1.0` | Share of exceptions and messages that are reported |
| `debug` | `false` | Log SDK activity with `NSLog` |
| `version` | bundle version | Sent as `service.version` |
| `serviceName` | bundle identifier | Sent as `service.name` |
| `environment` | — | Sent as `deployment.environment.name` |
| `attributes` | `[:]` | Attributes attached to every record |
| `screenCapture` | `false` | Record a wireframe replay |
| `replayImages` | `.always` | Most the replay may do with pictures: `.off`, `.wifi`, `.always` (see [Images](#images)) |
| `fps` | `4` | Most wireframe frames captured per second (1–15) |
| `maxBufferFrames` | `150` | Frames in the replay ring; the upper bound of every clip |
| `persistToDisk` | `true` | Keep state and undelivered telemetry on disk; record hard crashes |
| `captureLogs` | `true` | Record `Traceway.log` |
| `captureNetwork` | `true` | Record URLSession requests |
| `captureNavigation` | `true` | Record screens |
| `captureUserActions` | `true` | Record taps and feed them to recording triggers |
| `captureMetrics` | `true` | Measure and upload app performance metrics (see [App performance metrics](#app-performance-metrics)) |
| `metricDimensions` | `[:]` | Up to two app-defined dimensions on every metric (`custom.<key>`) |
| `recordAllSessions` | `false` | Stream breadcrumbs and replay all the time |
| `collection` | — | Local collection settings (see [Local config](#local-config)) |
| `sessions` | `true` | Send session records (`session.start` / `session.end`) |
| `baselineSampleRate` | `0` | Share of sessions whose breadcrumbs stream continuously |
| `remoteConfig` | `true` | Poll for collection settings over OpAMP |
| `exportDelayMs` | `1000` | How long finished records wait to be sent as one batch |
| `telemetry` | — | Another OTLP/HTTP receiver (see [Setups](#setups)) |
| `propagateTraceHeaderUrls` | `[]` | URL prefixes whose requests carry `traceparent` |
| `ignoreErrors` | `nil` (`defaultIgnoreErrors`) | Issues not reported, matched against `Type: message` (see [Errors and messages](#errors-and-messages)) |
| `beforeCapture` | `nil` | Sees every exception and message; returning false drops it |
| `reportHangsInDebug` | `false` | Report hangs (`app.hang`) while a debugger is attached too |

## Crashes and symbolication

After `initialize`, the SDK records:

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

## What gets captured automatically

| What | Record | Signal |
|------|--------|--------|
| Uncaught `NSException`s, fatal signals | `exception` (`traceway.crash: true`) | `errors` |
| View controllers appearing | `browser.navigation` | `navigation` |
| Taps | `browser.user_action.click` | `userActions` |
| URLSession requests | client spans | `network` |
| Sessions | `session.start`, `traceway.session.update`, `session.end` | the `sessions` option (on by default; off standalone) |
| Remote config, triggers, captures, dropped data | `traceway.config.applied`, `traceway.trigger.fired`, `traceway.capture.started`, `traceway.collection.health` | always sent |
| The screen, with `screenCapture: true` | wireframe replay clips and segments | replay |
| App start, screens, frames, hangs, crashes, sessions, users, memory, requests | `app.*` OTLP metrics (see [App performance metrics](#app-performance-metrics)) | `metrics` settings |

Every record carries `session.id`; the resource carries `service.name`,
`service.version`, `service.instance.id`, `os.*`, `device.*` (model,
manufacturer, locale, form factor, physical or simulator), `screen.resolution`
and `screen.density`.

## Platform support

| Platform | Support |
|----------|---------|
| iOS 13+ (UIKit, SwiftUI) | everything above |
| iPadOS | as iOS; a trackpad pointer is replayed as a mouse |
| macOS, Linux | builds and runs the platform-neutral parts (tests, the e2e harness); no UIKit hooks, replay, URLSession instrumentation, or start, frame and hang measurements |

### Platform differences

The API has the names of the browser, Android and Flutter SDKs. Where iOS differs, it is for these reasons:

- **Start**: `Traceway.initialize(connectionString:options:)`, because Swift keeps `Traceway.init(…)` for initializers. The browser and Android call it `init`, Flutter `run`. It returns the `TracewayClient`, or nil when the settings are invalid (logged, not thrown); a nil connection string starts standalone. `Traceway.start` is a deprecated alias.
- **Masks** belong to views: the `UIView.tracewayMask` property and the SwiftUI modifier `.tracewayMask(_:)`. The marker that needs no code is the `accessibilityIdentifier` (`traceway-mask`, `traceway-blank`), where the browser uses CSS classes, Android `android:tag` / `testTag` and Flutter a `ValueKey`; it works for UIKit views only. `TracewayMaskMode.blank(color:)` takes a `UIColor`.
- **Seconds**: `flush(timeout:)` waits at most `timeout` seconds (`TimeInterval`, the Swift idiom), where the browser, Android and Flutter take milliseconds.
- **Properties**: `Traceway.instanceId` and `Traceway.currentSessionId` are static properties (`getInstanceId()` and `currentSessionId()` in the browser, `getInstanceId()` on Android and Flutter).
- **Errors carry no stack of their own**: `captureException(_:attributes:)` records the stack of the caller; an `NSException` is reported with its own when uncaught.
- **Navigation**: view controllers are reported without code; SwiftUI navigation and routers use `.tracewayScreen(_:)` or `recordNavigation(_:action:from:route:)` (arguments by label).
- **Requests**: every `URLSession` request is recorded by opentelemetry-swift's `URLSessionInstrumentation`, with no interceptor to add (Android has `TracewayOkHttpInterceptor`).
- **SwiftUI text** shows as its words in replays only while an assistive technology runs (iOS fills in the accessibility elements then); otherwise each text is a neutral bar where it is drawn.
- **Replay**: wireframes only (no video), as on Android.

## Migrating from 1.x

- **Server**: 2.0 sends OTLP to `/api/otel/v1/logs`, `/api/otel/v1/traces` and
  `/api/otel/v1/metrics`, polls `/api/otel/v1/opamp` and uploads replays to
  `/api/recordings`. There is no fallback to the 1.x `/api/report` protocol.
- **Connection string**: unchanged; the bare server URL works too. It is now
  optional (standalone mode).
- **Unsent 1.x reports** younger than 12 hours, and crashes 1.x recorded, are
  sent once over OTLP on the first 2.0 start.
- **Removed options**: `debounceMs`, `retryDelayMs`, `maxPendingExceptions`,
  `maxLocalFiles`, `localFileMaxAgeHours`.
- **API**: `Traceway.initialize(connectionString:options:)` starts the SDK;
  `Traceway.start` still works and is deprecated. `flush(timeout:)` is unchanged.
  `capture(_:)`, `capture(error:)` and `capture(message:)` still work and are
  deprecated in favor of `captureException(_:attributes:)` and
  `captureMessage(_:attributes:)`; `sessionId` in favor of
  `currentSessionId`; `log(_:severity:)` and `TracewayLogSeverity` in favor of
  `log(_:level:attributes:)` and `TracewayLogLevel`. New: `track`, `log`,
  `recordAction`, `recordNavigation`, `setRoute`, `startInteraction`,
  `setAttribute(s)`, `removeAttribute`, `clearAttributes`,
  `reportFullyDisplayed`, `metric`, `count`, `setMetricDimension`, `shutdown`,
  `refreshConfig`, `instanceId`, `currentSessionId`, `tracer`, privacy masks
  and `.tracewayScreen`.
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

- **Wireframe components.** `UIKitWireframeTests` and `SwiftUIWireframeTests`
  hold one test per wireframe topic shared with the Android SDK (48 topics,
  from boxes and corners to SwiftUI inside UIKit): what each kind of view
  becomes, where its node is against the view's frame in the window, what is
  masked, and that the frames replay through a strict model of rrweb's
  replayer.
- **Wireframe gallery.** `WireframeGalleryTests` records the 28 gallery
  scenarios shared with the Android SDK (`layout`, `positioning`,
  `transforms`, `clipping`, `stacks`, `constraints`, `text`, `rich-text`,
  `buttons`, `controls`, `forms`, `keyboard`, `images`, `images-off`,
  `lists`, `grids`, `carousel`, `navigation`, `tabs`, `dialogs`, `sheets`,
  `menus`, `privacy`, `declarative`, `native`, `motion`, `rtl`, `dark-mode`;
  70 checkpoints) on the iOS Simulator with the real recorder while it
  scrolls, taps, types, presents and navigates. At every checkpoint it saves
  the app's own picture and the window frames of the labelled views.
  `python3 CI/wireframe/run.py --gh-run <run id>` then checks the recording
  (structure, every mutation, texts, secrets), renders every checkpoint in
  rrweb-player and compares it with the app's picture and the committed
  baseline, and holds every label's replayed box within 1.5 pt (position)
  and 2 pt (size) of its native frame. With `--dashboard` it uploads the run
  as a session to a running Traceway and checks the dashboard's own player
  the same way. See [CI/README.md](CI/README.md#wireframe-gallery).
- **End to end.** `python3 CI/e2e/run.py --base http://127.0.0.1:8082 --email
  .. --password ..` runs the real client (on macOS or Linux) against a running
  Traceway with an iOS project and checks through the dashboard API what the
  server holds after each phase: buffered breadcrumbs, the exception with its
  breadcrumbs, tap selector, request span, session and replay, a recording
  trigger, a capture from the dashboard, a remote rule built from a recorded
  selector, and a session that survives a kill with an earlier crash reported.
  `--gallery DIR` replays a wireframe gallery as the app's screen.

## Links

- [Docs/Wireframe.md](Docs/Wireframe.md): how the wireframe replay works
- [CHANGELOG.md](CHANGELOG.md)
- [CI/README.md](CI/README.md): test layers, running them locally, the
  wireframe gallery, the e2e harness
- [Scripts/upload_symbols.sh](Scripts/upload_symbols.sh): dSYM upload
- [Traceway documentation](https://docs.tracewayapp.com), [Traceway](https://tracewayapp.com)

## License

See [LICENSE](LICENSE).
