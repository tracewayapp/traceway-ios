# Traceway iOS example app

A minimal SwiftUI app that exercises the Traceway capture paths: caught Swift
errors, `NSError`, messages, breadcrumbs (logs, actions, custom events, a
network request, screens), a privacy-masked view in the wireframe replay, and
the four hard-crash classes.

There is no checked-in `.xcodeproj` (to avoid drift). Create one in a minute:

## 1. Create the app target

1. Xcode → **File → New → Project… → iOS → App**.
   - Interface: **SwiftUI**, Language: **Swift**.
   - Save it inside this `Examples/` folder (e.g. `TracewayExample`).
2. Delete the generated `ContentView.swift` and the `…App.swift`, then **add**
   the two files in `Examples/TracewayExample/`
   (`TracewayExampleApp.swift`, `ContentView.swift`) to the target.

## 2. Add the SDK

**File → Add Package Dependencies… → Add Local…** and select the repository
root (the folder with `Package.swift`). Add the `Traceway` library to the app
target.

## 3. Point at a backend

Edit the connection string in `TracewayExampleApp.swift`. For a local round-trip,
start the mock server first:

```sh
python3 Examples/mock_server.py --save recordings/
# then use: demo-token@http://localhost:8080
```

The mock server answers the 2.x endpoints: it prints each OpAMP poll, decodes
OTLP logs and spans with `protoc --decode_raw` when protoc is installed, and
lists (and with `--save` writes) every replay upload. `--config settings.json`
serves a settings document as the remote config, the way a Data Collection
rule would, e.g. `{"signals": {"console": {"mode": "stream"}}}`.

> Pointing at `http://localhost` from the simulator works out of the box. On a
> physical device, use your Mac's LAN IP and allow the cleartext HTTP exception,
> or point at a real `https://…` server.

## 4. Run and verify

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
