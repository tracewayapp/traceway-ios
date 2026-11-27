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

`WireframeGalleryTests` shows a gallery of UIKit and SwiftUI screens in a
window of its own, records it with the real `WireframeRecorder` on its timer
while scenarios scroll, tap, type, present and navigate, and at every
checkpoint saves the window's own picture. In the test it checks the recording
the way rrweb's replayer applies it (a Meta event and a full snapshot first,
time order, every mutation applying to the page as it is), the texts each
checkpoint must show and hide, and that no secret appears anywhere. It writes
`events.json`, `run.json`, `app/<checkpoint>.png` and `tree/<checkpoint>.txt`
(the window's layer tree, for diagnosing a conversion) to
`WIREFRAME_GALLERY_OUT` (`TEST_RUNNER_WIREFRAME_GALLERY_OUT` for
`xcodebuild`; `.build/wireframe-gallery` by default).

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
python3 CI/wireframe/run.py --dir … --only 'table*,alerts'     # some checkpoints or scenarios
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
(SSIM ≥ `--dashboard-floor` 0.9, at most `--dashboard-max-change` 5% of the
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
