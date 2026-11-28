# Traceway iOS example app

A minimal SwiftUI app that exercises the Traceway capture paths: caught Swift
errors, `NSError`, messages, breadcrumbs (logs, actions, custom events, a
network request, screens), a privacy-masked view in the wireframe replay, and
the four hard-crash classes.

## 1. Open the project

The repository's `project.yml` defines the app (target `TracewayExample`), and
[XcodeGen](https://github.com/yonaskolb/XcodeGen) turns it into a project, as
CI does:

```sh
brew install xcodegen
xcodegen generate
open TracewayCI.xcodeproj    # scheme TracewayExample
```

<details>
<summary>Without XcodeGen</summary>

1. Xcode → **File → New → Project… → iOS → App** (SwiftUI, Swift), saved inside
   this `Examples/` folder.
2. Replace its `ContentView.swift` and `…App.swift` with the two files in
   `Examples/TracewayExample/`.
3. **File → Add Package Dependencies… → Add Local…**, select the repository root
   (the folder with `Package.swift`) and add the `Traceway` library to the app
   target.
4. Set `Examples/TracewayExample/Example.xcconfig` as the target's configuration
   file (Project → Info → Configurations) and add the two Info.plist keys of
   step 2.

</details>

## 2. Point it at Traceway

The app starts the SDK the way the project's Connection page shows it: the
token is a build setting in `Traceway.xcconfig`, which `Info.plist` hands to the
app (`TracewayToken = $(TRACEWAY_TOKEN)`, `TracewayURL = $(TRACEWAY_URL)`), and
`TracewayExampleApp.swift` reads it:

```swift
let info = Bundle.main.infoDictionary
Traceway.initialize(
    token: info?["TracewayToken"] as? String ?? "",
    baseUrl: info?["TracewayURL"] as? String ?? "",
    options: TracewayOptions(debug: true, version: "1.0.0", screenCapture: true)
)
```

Create `Examples/TracewayExample/Traceway.xcconfig` (git-ignored; the committed
`Example.xcconfig` includes it) with the token from the Connection page:

```
TRACEWAY_TOKEN = YOUR_TOKEN
```

That sends to Traceway Cloud (`https://cloud.tracewayapp.com`). For a
self-hosted server add `TRACEWAY_URL = https:/$()/traceway.mycompany.com` (in an
`.xcconfig`, `//` starts a comment; `$()` expands to nothing). Without a token
the app runs and the console says why the SDK is off.

### Or a local mock server

For a round trip without a Traceway account, start the mock server and point
the app at it:

```sh
python3 Examples/mock_server.py --save recordings/
```

```
TRACEWAY_TOKEN = demo-token
TRACEWAY_URL = http:/$()/localhost:8080
```

The mock server answers the 2.x endpoints: it prints each OpAMP poll, decodes
OTLP logs and spans with `protoc --decode_raw` when protoc is installed, and
lists (and with `--save` writes) every replay upload. `--config settings.json`
serves a settings document as the remote config, the way a Data Collection
rule would, e.g. `{"signals": {"console": {"mode": "stream"}}}`.

> Pointing at `http://localhost` from the simulator works out of the box. On a
> physical device, use your Mac's LAN IP and allow the cleartext HTTP exception,
> or point at a real `https://…` server.

## 3. Run and verify

- **Issues** (Swift error / NSError / message): tap a button. The exception
  arrives right away, with the breadcrumbs recorded before it and a replay
  clip at `/api/recordings`.
- **Breadcrumbs** stay on the device until an issue (or a trigger) asks for
  them; with `--config` you can stream them instead.
- **Hard crashes** (force-unwrap, out-of-bounds, `fatalError`, NSException):
  the app dies. **Relaunch it** — the report uploads from disk on the next
  launch.

> ⚠️ Run hard-crash tests **without the Xcode debugger attached** — lldb
> intercepts `SIGSEGV`/`SIGTRAP` before the SDK's handler runs. Launch the app
> from the home screen (install once via Xcode, then stop the debugger and tap
> the icon), or use **Debug → Detach**.
