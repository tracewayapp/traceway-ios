# Testing & CI

Four layers, matching `.github/workflows/tests.yml`:

| Layer | Where it runs | What it covers | Secrets |
| --- | --- | --- | --- |
| `swift test` | Linux (`swift:6.3`) | The platform-neutral suite: settings merge and ceilings, triggers, ring buffer, OpAMP codec and client, routing, outbox, sessions, replay upload, wireframe DOM, diff and clip assembly, selectors, and the client end to end against in-memory exporters and a fake server | none |
| `swift test` + iOS build | macOS host | The same suite on Apple's Foundation, plus a compile of the UIKit code for device and simulator | none |
| iOS Simulator XCTest | iOS Simulator | The same suite **+ UIKit tests**: what each kind of view becomes in the wireframe (`UIKitWireframeTests`), the wireframe gallery (`WireframeGalleryTests`, uploaded as the `wireframe-gallery` artifact), real `UIScreen`/`UIDevice` attributes, live `Traceway.start`, gzip via device zlib. The OpenTelemetry-typed client suite is left out here (the hosted bundle cannot link the host app's OpenTelemetry symbols); it runs on macOS and Linux | none |
| Firebase Test Lab | **real iPhone** | The full bundle on physical hardware, optionally reporting to a real backend | Apple + GCP |

## Run locally

```sh
./Scripts/test.sh          # everything runnable without signing
./Scripts/test.sh swift    # swift build + swift test only
./Scripts/test.sh sim      # iOS Simulator XCTest only
./Scripts/test.sh device   # device-arch build-for-testing compile check
```

The simulator and device layers use an Xcode project generated from
[`project.yml`](../project.yml) via [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`). The generated `TracewayCI.xcodeproj` is git-ignored —
regenerate it any time with `xcodegen generate`. It defines a small host app
(reusing `Examples/TracewayExample`) and a unit-test target that compiles both
`Tests/TracewayTests` and `CI/DeviceTests`.

## Wireframe gallery

`WireframeGalleryTests` shows the 28 gallery scenarios of the SDK parity
contract (the Android SDK's gallery has the same names) in a window of its
own, records them with the real `WireframeRecorder` on its timer at 4 fps
while the scenarios scroll, tap, type, present and navigate, and at every
checkpoint saves the window's own picture and the window frames of its
labelled views. In the test it checks the recording the way rrweb's replayer
applies it (a Meta event and a full snapshot first, time order, every
mutation applying to the page as it is), the texts each checkpoint must show
and hide, that pictures are inlined only where `replay.images` allows them,
and that no secret appears anywhere. `WIREFRAME_GALLERY_ONLY=lists,menus`
runs some scenarios.

| # | Scenario | Checkpoints | What it shows |
| --- | --- | --- | --- |
| 1 | `layout` | 2 | fills, borders (all sides, one side), uniform and per-corner radii, shadows, linear and radial gradients, opacity, shape and text layers, hidden and alpha-0 views |
| 2 | `positioning` | 2 | a 3×3 Auto Layout alignment grid, margins × padding, 4 nested offsets, a child half outside its parent, a translation, overlaps ordered by `zPosition` and by subview order |
| 3 | `transforms` | 2 | rotations of 15, 45, 90 and 180°, scales 0.5 and 2 about the center and about the top left corner, rotate + scale, nested rotation, mirrored |
| 4 | `clipping` | 2 | clipping on and off, a rounded and a capsule clip, clips inside a scrolled view |
| 5 | `stacks` | 2 | `UIStackView` axes × `fill`, `fillEqually`, `equalSpacing` × alignments; a hidden arranged view |
| 6 | `constraints` | 2 | centering, multipliers, aspect ratio, leading and trailing pins, a chain; constraints changed |
| 7 | `text` | 2 | sizes, weights, italic, monospace, alignments, wrapping, truncation, line spacing, two lines at most |
| 8 | `rich-text` | 2 | attributed runs: colors, bold, underline, strike, background, sizes, a link |
| 9 | `buttons` | 2 | system and configuration buttons, disabled, icon-only, image and title, Liquid Glass; a tap counter |
| 10 | `controls` | 2 | switches, a toggle button, segmented control, slider, progress, spinner, stepper, page dots, date picker |
| 11 | `forms` | 3 | text field border styles, side views, secure entry, a label over a field, text views; focused, typed into |
| 12 | `keyboard` | 3 | a focused field with the system keyboard (a neutral box), typed into, dismissed |
| 13 | `images` | 2 | photos in fill, fit, center and crop, symbols, a template image, under `replay.images = always` (pictures inlined) |
| 14 | `images-off` | 2 | the same screen under `replay.images = off` (placeholders) |
| 15 | `lists` | 4 | an inset grouped `UITableView` with sections: top, middle, bottom, top again |
| 16 | `grids` | 3 | a three-column `UICollectionView`, scrolled twice |
| 17 | `carousel` | 4 | a horizontal strip in a vertical collection view, scrolled both ways |
| 18 | `navigation` | 3 | `UINavigationController` with a large title: push, pop |
| 19 | `tabs` | 3 | `UITabBarController`, three tabs |
| 20 | `dialogs` | 4 | the page, an alert and an action sheet over it, dismissed |
| 21 | `sheets` | 3 | a page sheet at its medium detent, at large, dismissed |
| 22 | `menus` | 2 | a popover over its anchor (`.none` adaptive style), dismissed |
| 23 | `privacy` | 2 | blank and blur masks over text and an image, a secure field; secrets never recorded |
| 24 | `declarative` | 3 | a SwiftUI screen: texts, shapes, a gradient, a toggle, a button, a mask, rows; state changed, scrolled |
| 25 | `native` | 2 | web view, map and video placeholders, a view that draws itself |
| 26 | `motion` | 3 | an animation at its start, in flight (`minMutations`) and at its end |
| 27 | `rtl` | 2 | right-to-left layout: mirrored stacks, natural alignment, a field and a switch |
| 28 | `dark-mode` | 2 | dynamic colors in the dark appearance, then light |

It writes to `WIREFRAME_GALLERY_OUT` (`TEST_RUNNER_WIREFRAME_GALLERY_OUT` for
`xcodebuild`; `.build/wireframe-gallery` by default; CI uploads it as the
`wireframe-gallery` artifact of the Simulator job):

- `events.json`: the rrweb events of the whole run;
- `run.json`: `platform` (`ios`), `device`, `os`, `width` and `height` (window
  points), `density` (the screen scale), `secrets`, and per checkpoint `name`,
  `scenario`, `at`, `shows`, `hides`, `ignore` (areas left out of picture
  comparisons, such as a spinner or the keyboard), `minMutations` and `boxes`:
  `{text, x, y, w, h}` for every visible label whose text is unique on the
  screen, its frame converted to the window (a transformed label's
  axis-aligned bounds), and for an empty text field its placeholder where the
  field draws text. Text under a privacy mask, typed text, text views, SwiftUI
  text and the titles of controls the wireframe draws from their state
  (segmented controls, steppers) are left out, and so is a checkpoint taken
  mid-animation;
- `app/<checkpoint>.png`: the window drawn by UIKit (`drawHierarchy`);
- `tree/<checkpoint>.txt`: the window's layer tree, for diagnosing a
  conversion.

### Checking a gallery

`CI/wireframe/` (`run.py`, `replay.mjs`, `compare.js`, `dashboard.mjs`) is the
gallery checker shared with the Android SDK, whose `tools/wireframe/` holds
byte-identical copies. It reads the gallery format of both SDKs: `run.json`
(`platform`, `device`, `os`, `width`, `height`, `density`, `secrets`, and
`checkpoints` with `shows`, `hides`, `ignore`, `minMutations` and `boxes`; a
run without `platform` counts as iOS), `events.json`, `app/<checkpoint>.png`.

```sh
python3 CI/wireframe/run.py --gh-run <run id>                 # a CI run's wireframe-gallery artifact (needs gh)
python3 CI/wireframe/run.py --dir .build/wireframe-gallery     # a gallery on disk
python3 CI/wireframe/run.py --dir … --only 'lists*,dialogs'    # some checkpoints or scenarios
```

Per run it checks the event structure, every mutation through a strict model of
rrweb's replayer, each checkpoint's `shows`/`hides`/`minMutations` and that no
secret appears, and then renders every checkpoint in rrweb-player at 1:1
(`replay.mjs`) to check:

- **visual**: the rendering against the app's picture (SSIM, edge alignment and
  colour, floors `--floor-ssim 0.5`, `--floor-edges 0.3`, `--floor-color 0.6`)
  and against the baseline rendering (a metric may not fall by more than
  `--tolerance` 0.03; at most `--max-change` 0.2% of the pixels may change);
- **geometry**: each `boxes` entry `{text, x, y, w, h}` (the native frame in
  window points) against the `getBoundingClientRect` of the replayed element
  whose own text is `text`, within 1.5 pt of position and 2 pt of size
  (`--geometry-position`, `--geometry-size`). The deltas are in `report.html`
  and `visual.json`. Until the gallery writes `boxes`, `--boxes-from-tree`
  takes the frames of the visible, uniquely labelled `UILabel`s of
  `tree/<checkpoint>.txt`;
- **size**: the bytes each scenario recorded, at most 1.5 × the baseline + 20 KB.

It needs Node with Playwright (`--playwright`, default
`~/Work/workspace/js-client/node_modules/playwright`), Chromium (`--chromium`)
and rrweb-player (`--rrweb-player`, by default the dashboard's copy in
`../traceway/frontend/node_modules`). Open `report.html` in `--out`
(`~/.cache/tw-wireframe/ios` by default).
`--update-baseline` accepts a run into `CI/wireframe/baseline/<platform>-<width>x<height>/`:
the replay renderings and their fidelity numbers. Renderings depend on the fonts
and the Chromium build of the machine that runs `run.py`; the committed
`ios-440x956` baseline (the iPhone 17 Pro Max simulator) was rendered on Linux
with Chromium. A simulator of another size has no baseline and is only held to
the fidelity floors.

### The gallery in the dashboard

`--dashboard` plays the run in the real dashboard. Given a running Traceway
(`--traceway`, the backend; `--dashboard`, the dashboard origin, the same when the
backend serves its embedded dashboard) with the seeded `iOS App` project of
`traceway/examples/devtesting-embedded` (`--project`, `--token`, `--email`,
`--password` override it), `dashboard.mjs`:

1. moves the events in time so the run ends a few seconds ago, opens a session
   with an OTLP/HTTP JSON `session.start` log (scope `traceway-ios`
   `2.0.0-beta.1`, `session.id`, `traceway.session.started_at`), uploads the
   events with `POST /api/recordings` (gzip, one segment per Meta + full snapshot,
   increasing `segmentIndex`) and ends the session with `session.end`;
2. waits until the session reports its recording, logs into the dashboard and
   opens the session page;
3. seeks the page's player to each checkpoint by clicking that checkpoint's row
   in the session's Actions tab (each segment carries a custom action
   `wireframe-gallery/<checkpoint>` at the checkpoint's time; clicking an action
   seeks the player to it), screenshots the replay iframe at the device scale that
   undoes the player's scale, and reads the iframe's texts and boxes.

Each checkpoint then has to show no rrweb missing-node errors, its `shows` and
none of its `hides`, its `boxes` within the geometry tolerance, the same texts
and the same element layout (every element's box within 0.5 px) as the
standalone rrweb-player rendering, and a picture that agrees with it
(SSIM ≥ `--dashboard-floor` 0.85, at most `--dashboard-max-change` 5% of the
pixels different; the dashboard scales the replay, so text is drawn at another
size). The results are columns of the same `report.html`.

```sh
# devtesting-embedded on spare ports in a fresh directory, and the dashboard from traceway/frontend:
mkdir -p ~/tw-e2e && (cd ../traceway/examples/devtesting-embedded && go build -o ~/tw-e2e/devtesting .)
(cd ~/tw-e2e && DEVTESTING_APP_PORT=18180 DEVTESTING_TRACEWAY_PORT=18182 ./devtesting) &
(cd ../traceway/frontend && TRACEWAY_API_PROXY=http://127.0.0.1:18182 npx vite dev --port 15183) &
python3 CI/wireframe/run.py --gh-run <run id> --dashboard http://127.0.0.1:15183 --traceway http://127.0.0.1:18182
```

## End to end against Traceway

`CI/e2e/run.py` drives the real client (`E2EScriptTests`, run on macOS or
Linux) against a running Traceway that has an iOS project and asserts through
the dashboard API what the server holds after each phase: buffered
breadcrumbs, the exception with its breadcrumbs, tap selector, request span,
session and wireframe clip, a recording trigger from local settings, a capture
started and cancelled from the dashboard, a remote rule built from the
selector the server recorded, and a session that survives a kill, with the
earlier run's crash reported and symbolicated by the server.

```sh
python3 CI/e2e/run.py --base http://127.0.0.1:8082 --email you@example.com --password … \
    [--gallery ~/.cache/tw-wireframe/ios]
```

## Firebase Test Lab (real-device)

This mirrors the Flutter pipeline. It only runs on **manual dispatch**:
Actions → **Tests** → *Run workflow* → check **Run Firebase Test Lab tests**.
PRs (and forks without secrets) skip it.

The job builds a **signed** `build-for-testing` bundle, zips
`Debug-iphoneos` + the `.xctestrun`, and submits it with
`gcloud firebase test ios run --device model=…`.

### Required repository secrets

Apple signing (same ones the Flutter repo uses — a **wildcard** provisioning
profile covering `com.tracewayapp.*`, or change `bundleIdPrefix` in
`project.yml` to match yours):

| Secret | Description |
| --- | --- |
| `APPLE_CERTIFICATE_P12` | base64 of your Apple Development `.p12` |
| `APPLE_CERTIFICATE_PASSWORD` | password for the `.p12` |
| `APPLE_PROVISIONING_PROFILE` | base64 of a `.mobileprovision` for `com.tracewayapp.*` |
| `APPLE_PROVISIONING_PROFILE_NAME` | the profile's **Name** (for `PROVISIONING_PROFILE_SPECIFIER`) |
| `APPLE_TEAM_ID` | your 10-char Apple Team ID |
| `KEYCHAIN_PASSWORD` | any throwaway password for the temp keychain |

GCP / Firebase Test Lab:

| Secret | Description |
| --- | --- |
| `GCP_WORKLOAD_IDENTITY_PROVIDER` | Workload Identity provider resource name |
| `GCP_SERVICE_ACCOUNT` | service account email with Test Lab access |
| `GCP_PROJECT_ID` | Firebase/GCP project id |
| `GCS_BUCKET` | bucket for test results |

Optional:

| Secret | Description |
| --- | --- |
| `TRACEWAY_DSN` | `token@https://…`. Baked into the test bundle's `Info.plist` at build time and read by `RealDeviceSmokeTests`. If unset, the device test sends to an unreachable endpoint and only asserts the SDK stays healthy. |

> **Why `Info.plist` and not an env var?** `gcloud firebase test ios run`
> cannot inject environment variables into the XCTest process, so the DSN is
> passed at build time via Info.plist variable substitution
> (`TRACEWAY_DSN=$(TRACEWAY_DSN)`), then read with
> `Bundle(for:).object(forInfoDictionaryKey: "TRACEWAY_DSN")`.

### Device models

Pick a model/version from `gcloud firebase test ios models list`. Override the
default with the **device** workflow input, e.g. `iphone15pro,version=17.5`.
