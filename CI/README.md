# Testing & CI

Three layers, matching `.github/workflows/tests.yml`:

| Layer | Where it runs | What it covers | Secrets |
| --- | --- | --- | --- |
| `swift test` | macOS host | Logic suite: wire format, gzip, connection string, disk store, client state machine, crash-record conversion | none |
| iOS Simulator XCTest | iOS Simulator | The same suite **+ on-device smoke tests** — real `UIScreen`/`UIDevice` attributes, live `Traceway.start`, gzip via device zlib | none |
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
| `TRACEWAY_DSN` | `token@https://…/api/report`. Baked into the test bundle's `Info.plist` at build time and read by `RealDeviceSmokeTests`. If unset, the device test sends to an unreachable endpoint and only asserts the SDK stays healthy. |

> **Why `Info.plist` and not an env var?** `gcloud firebase test ios run`
> cannot inject environment variables into the XCTest process, so the DSN is
> passed at build time via Info.plist variable substitution
> (`TRACEWAY_DSN=$(TRACEWAY_DSN)`), then read with
> `Bundle(for:).object(forInfoDictionaryKey: "TRACEWAY_DSN")`.

### Device models

Pick a model/version from `gcloud firebase test ios models list`. Override the
default with the **device** workflow input, e.g. `iphone15pro,version=17.5`.
