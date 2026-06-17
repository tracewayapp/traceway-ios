# Traceway iOS SDK

Catch crashes and exceptions in your iOS app and report them to your
[Traceway](https://tracewayapp.com) backend. Pure Swift, zero third‑party
dependencies, distributed via Swift Package Manager.

> This SDK reports **errors and crashes only** - there is no session/video replay.
> It speaks the same `/api/report` wire format as the Traceway Android, Flutter
> and JS SDKs, so the same backend ingests it with no server changes.

## Requirements

- iOS 13.0+
- Swift 5.9+ / Xcode 15+

## Installation (Swift Package Manager)

In Xcode: **File → Add Package Dependencies…** and enter the repository URL, or
add it to your `Package.swift`:

```swift
.package(url: "https://github.com/tracewayapp/traceway-ios.git", from: "1.0.0"),
```

then add `"Traceway"` to your target's dependencies.

## Usage

Call `Traceway.start` as early as possible - ideally in your `App` initializer
(SwiftUI) or `application(_:didFinishLaunchingWithOptions:)` (UIKit). The
connection string format is `"{token}@{apiUrl}"`.

### SwiftUI

```swift
import SwiftUI
import Traceway

@main
struct MyApp: App {
    init() {
        Traceway.start(
            connectionString: "your-token@https://your-traceway/api/report",
            options: TracewayOptions(version: "1.0.0")
        )
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
```

### UIKit

```swift
import UIKit
import Traceway

@UIApplicationMain
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        Traceway.start(
            connectionString: "your-token@https://your-traceway/api/report",
            options: TracewayOptions(version: "1.0.0")
        )
        return true
    }
}
```

After `start`, the SDK automatically captures:

- **Uncaught `NSException`s** (Objective‑C / UIKit).
- **Fatal signals** - Swift runtime traps such as force‑unwrapping `nil`, array
  out‑of‑bounds, `fatalError()`, integer overflow (these surface as `SIGTRAP`,
  `SIGILL`, `SIGABRT`, `SIGSEGV`, …). Hard crashes are persisted to disk and
  uploaded on the **next launch**.

### Manual capture

```swift
do {
    try somethingThrowing()
} catch {
    Traceway.capture(error)
}

Traceway.capture(message: "Something noteworthy happened")
```

### Forcing a flush

```swift
Traceway.flush(timeout: 5) // seconds; nil = wait indefinitely
```

## Configuration

`TracewayOptions` mirrors the other Traceway SDKs:

| Option | Default | Description |
| --- | --- | --- |
| `sampleRate` | `1.0` | Fraction of exceptions to keep (0.0–1.0). |
| `debug` | `false` | Log SDK activity via `NSLog`. |
| `version` | `""` | App version, sent as `appVersion`. |
| `debounceMs` | `1500` | Delay before batching/uploading. |
| `retryDelayMs` | `10000` | Delay before retrying a failed upload. |
| `maxPendingExceptions` | `5` | In‑memory cap; oldest dropped when exceeded. |
| `persistToDisk` | `true` | Persist pending reports so they survive restarts. |
| `maxLocalFiles` | `5` | Max persisted report files. |
| `localFileMaxAgeHours` | `12` | Delete unsynced files older than this. |

## Testing crash capture

Hard crashes are intercepted with POSIX signal handlers. When the **debugger is
attached**, lldb intercepts these signals first, so your crash may not be
recorded. Test crash capture by running the app **without** the Xcode debugger
(e.g. launch it from the home screen after installing), then relaunch and watch
the report upload.

## Testing

```sh
swift test            # logic suite on the macOS host
./Scripts/test.sh     # + iOS Simulator XCTest + device-arch build check
```

CI (`.github/workflows/tests.yml`) runs the logic suite, the full XCTest suite
on the iOS Simulator, and - on manual dispatch - the suite on a **real iPhone**
via Firebase Test Lab. See [CI/README.md](CI/README.md) for details and the
required secrets.

## License

See [LICENSE](LICENSE).
