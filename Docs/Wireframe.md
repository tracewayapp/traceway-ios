# Wireframe session replay

How the iOS SDK records the screen for session replay. The Android and
Flutter SDKs document theirs under the same headings in `docs/wireframe.md`.

## Overview

With `screenCapture: true` the SDK records the screen as a wireframe: up to
`fps` times a second (4 by default, at most 15) it walks the app's windows on
the main thread and turns what they show into an HTML document. What changes
from one frame to the next becomes an rrweb mutation, so the dashboard
replays an iOS session with the same rrweb player as a browser session.

The replay is a wireframe only: no screenshot of a window and no video is
ever recorded. The only pixels in a recording are the shapes of SF Symbols
and template images, and, when the images policy allows it, the bitmaps that
image views show (see [Images](#images)).

| File (`Sources/Traceway/`) | Type | Role |
|---|---|---|
| `Wireframe/WireframeRecorder.swift` | `WireframeRecorder`, `WireframeFrame`, `WireframePointer` | timer, frame ring, touches, clip to rrweb events |
| `Wireframe/WireframeRoots.swift` | `WireframeRoots` | the windows to record and the one frames are measured in |
| `Wireframe/WireframeCapture.swift` | `WireframeCapture` | tree walk and the per-kind converters |
| `Wireframe/WireframeSwiftUICapture.swift` | extension of `WireframeCapture` | SwiftUI text, drawings and image layers |
| `Wireframe/VNode.swift` | `VNode`, `serializeDocument`, `wireframeCss` | node model, document skeleton, shared stylesheet |
| `Wireframe/WireframeCSS.swift` | `WireframeCSS`, `WireframeAffine`, `WireframeRect` | inline style builders and geometry |
| `Wireframe/WireframeDiff.swift` | `diffScreens` | the rrweb mutation between two frames |
| `Wireframe/WireframeGlyphs.swift` | `WireframeGlyphs`, `MaskPNG` | icon shapes as PNG mask rules |
| `Wireframe/WireframeImages.swift` | `WireframeImages`, `WireframeImageEncoding` | pictures of image views |
| `Replay/ReplaySource.swift` | `ReplaySource`, `SessionRecordingPayload` | what the replay controller needs from a recorder |
| `Replay/ReplayController.swift` | `ReplayController` | replay mode, clips and segments |
| `Replay/RecordingsTransport.swift` | `RecordingsTransport`, `RecordingSegment` | upload to `/api/recordings` |
| `Replay/CollectionBudget.swift` | `CollectionBudget` | per-session bytes, events and image bytes |
| `Replay/TracewayMask.swift` | `TracewayMaskMode` | blank and blur masks |
| `Internal/NetworkState.swift` | `NetworkState` | whether the connection is unmetered |

## Pipeline

roots → walk → convert → VNodes (stable ids, shared unchanged subtrees) →
CSS → diff → rrweb events

1. **Roots**: `WireframeRoots.visibleWindows()` takes the windows of the
   foreground scene (active, else inactive), drops hidden, transparent,
   zero-width and keyboard windows, and sorts them by window level, then by
   order. Frames are in the coordinate space of the key window (else the
   first normal-level one).
2. **Walk**: `visit` goes through each window's views and the layers no view
   owns, in paint order, reading presentation layers (so animations are
   recorded). Hidden views, opacity below 0.01 and anything outside the clips
   above are left out. At most 3,000 nodes and 128 levels deep.
3. **Convert**: each kind of view has a converter (below). Layout-only views
   get no node: they are folded into the geometry of their children. Only
   views that paint, clip, fade, scroll or draw themselves become nodes, so
   nodes nest the way they paint and CSS clips, rounds and fades their
   content as Core Animation does.
4. **VNodes**: a view keeps its node id from frame to frame (an id stored on
   the object), and a node that did not change is the previous frame's very
   object. An unchanged frame is the same object as the last one and is not
   kept; a diff skips every shared subtree.
5. **CSS**: geometry is inline (`left`/`top`/`width`/`height`, or a
   `transform: matrix(...)` with `transform-origin: 0 0`), lengths rounded to
   0.1 px, borders as inset box shadows. Classes come from the shared
   stylesheet.
6. **Diff**: `diffScreens` compares two frames: changed attributes (removed
   ones as `null`), changed texts, and children reordered by their longest
   increasing run; added nodes parent first, siblings last to first.
7. **rrweb events**: a clip is a Meta event, a FullSnapshot, the mutations
   and pointer events in time order, and a trailing `traceway.end` custom
   event.

## Node ids

| Id | Node |
|---|---|
| 1 | document |
| 2 | doctype |
| 3 | `html` |
| 4 | `head` |
| 5 | `meta charset` |
| 6 | `style` with `wireframeCss` |
| 7 | `body` |
| 8 | the screen, `div#tw` |
| 9, 10 | the away screen's text box and text ("App in the background") |
| 12, 14 | the keyboard box and its text "Keyboard" (13 is reserved for a label box) |
| 16 | the first captured node; every view's id is 16 or more |

## Stylesheet

`wireframeCss` (in `VNode.swift`) is byte for byte the stylesheet of the
Android and Flutter SDKs; `WireframeStylesheetTests` compares it with the
shared copy in `Tests/TracewayTests/Resources/wireframe.css`. Change it only
together with every copy. Its classes:

| Class | Meaning |
|---|---|
| `#tw` | the screen |
| `.t` | text (wraps) |
| `.n` | one line (no wrap, flex-aligned) |
| `.e` | a line cut with an ellipsis |
| `.k` | text inside a field |
| `.im` | image placeholder: a gray box with two diagonals |
| `.ic` | an icon: a rounded square in `currentColor`, or a glyph's shape |
| `.cp` | a view that draws itself: a dashed outline |
| `.mk` | masked area (unused on iOS) |
| `.sk`, `.sk.sm` | SwiftUI text without accessibility: bars where its lines are |
| `.pv` | a native view placeholder with its label |

The body font in the stylesheet is Roboto; iOS sets Apple's system font
stack inline on the screen node: `font-family:-apple-system,
BlinkMacSystemFont,"SF Pro Text","Helvetica Neue",Helvetica,Arial,sans-serif`.

Icon glyphs (`.ic.g<N>::before{...}`) and pictures (`.im.p<N>{...}`) are
rules of their own, each in a `style` node at the top of the screen node.

## What each kind of view becomes

The converters inside `WireframeCapture` use the same names as the other
SDKs'.

| Converter | Views | Result |
|---|---|---|
| `text` | `UILabel` | font size, weight, italic, monospace, color, alignment, RTL; one line `t n`, cut `t n e`, wrapped `t`; attributed runs as up to 50 `<span>`s (color, background, underline, strikethrough, links) |
| `field` | `UITextField`, `UITextView` | border style, placeholder in its color, typed text masked, secure text as bullets, text and editing rects, side views |
| `image` | `UIImageView` | symbols and template images as their shape (`.ic` + glyph, tinted; palette and multicolor symbols in their colors); a stretchable background with subviews as a box; any other image a picture or the `.im` placeholder; subviews kept over it |
| `toggle` | `UISwitch` | track and knob from `isOn` and tint colors, iOS 26's wider track |
| `slider` | `UISlider` | track rect split at the thumb, thumb |
| `progress` | `UIProgressView`, `UIActivityIndicatorView` | a bar of `progress`%; a dotted ring |
| `segmented` | `UISegmentedControl` | track, raised selected segment, titles or icons, up to 20 segments |
| `nativePlaceholder` | `WKWebView`, `SFSafariViewController`, `MKMapView`, `AVPlayerLayer`, `AVCaptureVideoPreviewLayer`, Metal, SceneKit, SpriteKit, `PDFView`, remote views | `.pv` with "Web view", "Map", "Video", "Camera", "Native view" or "Document" |
| `customDrawing` | app views that override `draw(_:)` | a dashed `.cp` outline |
| `keyboard` | the system keyboard | a neutral box with "Keyboard" (ids 12–14) |
| `group` | any other view | its box (background, corners, border, shadow, opacity, clip, gradient or shape layer class), or folded into its children |
| `scroll` | `UIScrollView` and any view with shifted bounds | a content node moved by `left`/`top` inside the clip |
| `stepper` | `UIStepper` | track, minus and plus, faded at the limits |
| `pageControl` | `UIPageControl` | 7 px dots, the current one in its tint |
| `visualEffect` | `UIVisualEffectView` | blur as a tinted `backdrop-filter`; Liquid Glass as a lighter frost with a rim |
| `glass` | iOS 26 `CASDFElementLayer` | a frosted shape, a capsule up to 80 pt, else 26 px corners |
| `swiftUIText`, `swiftUIDrawing` | SwiftUI text layers and drawing views | text from accessibility, else `.sk` bars |

Layers no view owns: `CAGradientLayer` (axial, radial, conic), `CAShapeLayer`
(bounding box, round when not a rectangle, stroke as inset shadow),
`CATextLayer` (text), image layers (small see-through ones as a gray glyph,
others a picture or the placeholder). Layers with a `dest` compositing filter
cut out and are not painted. A window dim (`UIDimmingView`) is a plain view
with a translucent background and converts as a `group`.

## Images

Whether the pictures image views show are recorded is the effective images
policy: the lower of the remote setting `replay.images` (`off`, `wifi` or
`always`, default `wifi`) and the option `TracewayOptions.replayImages`
(default `.always`). Without replay (no `screenCapture`, a plan with
`limits.replay = off`) it is `off`.

- **`wifi`** means unmetered: `NWPathMonitor` reports a satisfied path that
  is neither expensive (cellular, personal hotspot) nor constrained (Low Data
  Mode). Until the first path arrives the connection counts as metered.
- The policy is **decided at capture time**: a frame captured on Wi-Fi keeps
  its pictures; frames captured while the policy does not allow pictures
  draw the `.im` placeholder and carry no picture rule.
- **What is captured**: `UIImageView.image` (the highlighted image when
  highlighted) and the contents of image layers (SwiftUI `Image`,
  `ImageLayer`) that are not icons. Never a screenshot. Never under a blank
  or blur mask. Symbols and template images stay glyphs.
- **Encoding** (`WireframeImageEncoding`): the bitmap is drawn alone with
  `UIGraphicsImageRenderer` at its displayed size × 1 (one pixel per
  point), never more pixels than it has. An opaque picture is a JPEG at
  quality 0.45, the longest side at most 384; one with see-through pixels is
  always a PNG (a JPEG would replay it as a black or white box), the longest
  side at most 192. An encoding over 48 KiB is tried once more at half size,
  then dropped.
  Encoding runs off the main thread: the first frame shows the placeholder,
  a later one the picture.
- **DOM**: one `style` node per picture in the screen node,
  `.im.p<N>{background:url(data:image/jpeg;base64,…) center/cover no-repeat}`;
  the image node gets `class="im p<N>"` and an inline `background-size` /
  `background-position` for its content mode (`contain` for aspect fit,
  `100% 100%` for scale to fill, its own size and offset for the others;
  aspect fill uses the rule's `cover`).
- **Dedup and limits**: a picture is found again by its bitmap (the
  `UIImage`, or the layer and its contents) and displayed size, so the same
  photo in many cells shares one style rule. At most 128 pictures are held; a new
  one past that evicts the one shown longest ago (never one on the frame
  being captured), whose rule leaves the page. A rule lingers 30 s after its
  picture left the screen.
- **Budget**: at most 4 MiB of encoded image data per session, counted in
  `CollectionBudget` and saved with the replay budget; past it, pictures stay
  placeholders. A new session encodes and counts its pictures again.
  Each independently playable clip or segment also allows 128 KiB of serialized
  raster data URLs, including PNG glyph masks. Their UTF-8 byte count includes
  the prefix, base64 data and repeated appearances in snapshots and mutations.
  An over-budget segment uses the base wireframe styles throughout, preserving
  its layout, text, masked placeholders, timing and input events.
- **Reported**: session events carry `traceway.replay.images` (the policy at
  session start) and `traceway.replay.image_bytes`.

## Privacy

- `tracewayMask = .blank(color:)`: a box of that color; nothing inside
  is recorded.
- `.blur`: layout kept, text replaced by `*` (whitespace kept), images as
  placeholders, symbols not drawn.
- An `accessibilityIdentifier` of `traceway-mask` masks a UIKit view like
  `.blur`, `traceway-blank` like `.blank()` (black); neither is reported as an
  id in taps.
- SwiftUI's `.tracewayMask()` puts a marker view over its content;
  text and images inside the marker's rectangle are masked the same way.
- Text typed into fields and editable text views is masked unless the
  setting `replay.maskAllInputs` is `false`; secure fields are always
  bullets. The keyboard is a neutral box, never its keys.
- Masked text is also left out of recorded taps.

## Scrolling

A scroll view (and any view whose bounds origin is not zero) gets a content
node of its own with `left:-x;top:-y`: scrolling changes one attribute per
frame, not every child. The timer runs in the `.common` run loop mode, so it
keeps capturing while a finger drags a scroll view. Scroll indicators are left
out.

## Windows, dialogs and the keyboard

Every visible window is walked into the same screen node in level order, so
alerts, action sheets, sheets and popovers in their own windows paint over the
app as on the device. iOS 26 puts many views in `_UIMultiLayer` wrapper
layers and some subview layers beside their view's layer; both are followed.
The keyboard window is never walked: `keyboardWillChangeFrame` gives the
keyboard's frame, drawn as the "Keyboard" box (light `#d1d3d9`, dark
`#2c2c2e`). In the background the replay shows the away screen ("App in the
background", ids 9 and 10).

## Pointers

Touches reach the recorder from the swizzled `UIApplication.sendEvent`, before
the app handles them. All pointer events target the screen node (id 8):

| Touch | rrweb |
|---|---|
| down | MouseInteraction (source 2) TouchStart (7) |
| move | TouchMove (source 6) `positions`, at most one per 50 ms per finger |
| up | TouchEnd (9) |
| tap | TouchEnd (9) and Click (2) |
| cancel | TouchCancel (10) |

A pointer (iPad trackpad) uses MouseDown (1), MouseUp (0) and MouseMove
(source 1). A tap lifts within 10 points of where it went down and before
UIKit's long-press duration of 0.5 s; the `browser.user_action.click` record
and the rrweb Click use the same rule (`TapGesture`). The ring holds the last
4,000 pointer events.

## Clips and segments

`ReplayController` runs the recorder by the replay mode:

- `off`: not recording; frames are forgotten.
- `buffer` (default): the last `maxBufferFrames` frames stay on the device;
  a trigger or capture flushes a clip (the default exception trigger: the
  last 30 seconds).
- `stream` (a capture, a trigger asking for replay, `recordAllSessions`, a
  rule): the session leaves as consecutive segments of up to 10 s (shorter
  when the frame ring is), each starting where the last one ended.

Every clip and segment starts with a Meta event (`href`, `width`, `height` in
points) and a FullSnapshot with `initialOffset {0, 0}` of the screen as it
was then; a size change or the away screen starts a new pair. Clips are
assembled on a queue of their own and uploaded as
`{"segments":[{events, exceptionId?, sessionId?, segmentIndex?, startedAt?, endedAt?}]}`,
gzipped, to `/api/recordings`; an exception's clip carries its
`traceway.exception.id`.

## Limits

| Limit | Value |
|---|---|
| frames per second | `fps`, 1–15 (default 4); a frame is kept only when the screen changed |
| frame ring | `maxBufferFrames` (default 150) |
| nodes per frame / depth | 3,000 / 128 |
| rich text runs per label | 50 |
| glyphs per recorder | 300, at most 512 px a side; a rule lingers 10 s |
| pictures per recorder | 128, the one shown longest ago evicted first; a rule lingers 30 s |
| picture size | 384 px longest side (JPEG), 192 px with transparency (PNG), 48 KiB encoded |
| inline raster data per playable clip or segment | 128 KiB of serialized data URLs |
| image data per session | 4 MiB |
| replay per session | 50 MiB and 10,000 rrweb events (`CollectionBudget`) |
| upload queue | 10 MiB, retries after 5 s, 30 s and 120 s |
| SwiftUI text | read at most once a second per hosting view, 400 elements, 200 texts |

## Testing

- `WireframeDiffTests.swift`, `WireframeCssTests.swift`,
  `WireframeRecorderTests.swift`, `WireframeGlyphsTests.swift` and
  `WireframeStylesheetTests.swift` (every platform): the diff replayed by a
  strict rrweb mirror, node serialization, CSS builders, the recorder's clips
  and pointers, glyph PNGs, the shared stylesheet and the fixed ids.
- `ReplayImagesTests.swift` (every platform): the images policy, encoding
  sizes, the picture rule and placements, the per-session allowance.
- `UIKitWireframeTests.swift` (iOS Simulator): what each kind of view becomes,
  masks, scrolling, alerts, the keyboard, SwiftUI, and pictures (off and
  metered stay placeholders, `always` inlines a JPEG, masks stay placeholders,
  one picture per bitmap and size).
- `WireframeGalleryTests.swift` (iOS Simulator): real screens recorded by the
  real recorder while a driver taps, types, scrolls and navigates;
  `CI/wireframe/run.py` renders each checkpoint in rrweb-player and compares
  it with the app's own picture. See [CI/README.md](../CI/README.md).
