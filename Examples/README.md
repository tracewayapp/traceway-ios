# Traceway iOS example app

A minimal SwiftUI app that exercises every Traceway capture path: caught Swift
errors, `NSError`, messages, and the four hard-crash classes.

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
python3 Examples/mock_server.py
# then use: demo-token@http://localhost:8080/api/report
```

The mock server decompresses the gzip body and prints the exact JSON the SDK
sent, plus the `Authorization` header.

> Pointing at `http://localhost` from the simulator works out of the box. On a
> physical device, use your Mac's LAN IP and allow the cleartext HTTP exception,
> or point at a real `https://…/api/report`.

## 4. Run and verify

- **Managed paths** (Swift error / NSError / message): tap a button, then tap
  **Flush now**. The report appears in the mock server immediately.
- **Hard crashes** (force-unwrap, out-of-bounds, `fatalError`, NSException):
  the app dies. **Relaunch it** — the report uploads from disk on the next
  launch.

> ⚠️ Run hard-crash tests **without the Xcode debugger attached** — lldb
> intercepts `SIGSEGV`/`SIGTRAP` before the SDK's handler runs. Launch the app
> from the home screen (install once via Xcode, then stop the debugger and tap
> the icon), or use **Debug → Detach**.
