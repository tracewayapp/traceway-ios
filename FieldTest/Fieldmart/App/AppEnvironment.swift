import QuartzCore
import UIKit
import FieldmartCore

/// Everything the screens share: launch settings, telemetry, the fixture
/// client, image loaders, the cart, markers and the probe. Main thread.
final class AppEnvironment {
    static let shared = AppEnvironment()

    let telemetry: Telemetry = TelemetryFactory.make()
    private(set) var settings = LaunchSettings()
    private(set) var client: FixtureClient!
    private(set) var images: ImageLoader!
    private(set) var freshImages: FreshImageLoader!
    private(set) var markers: MarkerWriter!
    let probe = Probe()
    let appLog = AppLog()
    let cart = Cart()
    private(set) var sdkStartMs: Double = 0
    private var readyWritten = false
    private var fullyWritten = false
    private var lastScreen: String?

    var urls: FixtureURLs { client.urls }

    /// `Fieldmart` or `FieldmartOff` and the SDK linked, for Diagnostics.
    var build: String {
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Fieldmart"
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        return "\(name) \(version) (\(telemetry.sdkName))"
    }

    /// Called from `didFinishLaunching` right after the SDK start.
    func bootstrap(settings: LaunchSettings, sdkStartMs: Double) {
        self.settings = settings
        self.sdkStartMs = sdkStartMs
        Autopilot.shared.prepare(settings: settings)
        markers = MarkerWriter(settings: settings)
        let processStart = ProcessStart.epochMs()
        if let start = processStart { markers.write(.processStart, epochMs: start) }
        markers.write(.sdkStarted, detail: String(Int(sdkStartMs.rounded())))
        probe.start(settings: settings, build: build, processStartEpochMs: processStart)
        let session = FixtureClient.makeSession()
        client = FixtureClient(urls: FixtureURLs(base: settings.fixturesBase), session: session)
        images = ImageLoader(session: session)
        freshImages = FreshImageLoader(session: session)
    }

    /// `FM_READY` on the first display refresh after the window is shown.
    func watchFirstFrame() {
        let watcher = FirstFrameWatcher { [weak self] in self?.ready() }
        watcher.start()
    }

    private func ready() {
        guard !readyWritten else { return }
        readyWritten = true
        markers.write(.ready)
        if let session = telemetry.sessionId { markers.write(.session, detail: session, epochMs: 0) }
        if settings.autopilot { Autopilot.shared.begin(settings: settings) }
    }

    /// Home's hero and first eight grid pictures are on screen.
    func fullyDrawn() {
        guard !fullyWritten else { return }
        fullyWritten = true
        markers.write(.fully)
    }

    /// A screen became visible: `FM_SCREEN <name>` and `FM log <n>`.
    func screenAppeared(_ name: String) {
        guard name != lastScreen else { return }
        lastScreen = name
        markers.write(.screen, detail: name)
        appLog.screenChanged()
        telemetry.screen(name)
    }
}

/// The items in the cart (Product's "Add to cart"; Home's badge).
final class Cart {
    static let changed = Notification.Name("FMCartChanged")
    private(set) var count = 0

    func add(_ quantity: Int) {
        count += quantity
        NotificationCenter.default.post(name: Cart.changed, object: nil)
    }

    func clear() {
        count = 0
        NotificationCenter.default.post(name: Cart.changed, object: nil)
    }
}

/// Calls `action` once, on the first display-link callback.
private final class FirstFrameWatcher: NSObject {
    private var link: CADisplayLink?
    private var action: (() -> Void)?
    private var keepAlive: FirstFrameWatcher?

    init(action: @escaping () -> Void) {
        self.action = action
    }

    func start() {
        keepAlive = self
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick() {
        link?.invalidate()
        link = nil
        let run = action
        action = nil
        keepAlive = nil
        run?()
    }
}

/// The `fm.target` attribute: the Simulator's device model and iOS version.
enum DeviceDescription {
    static var target: String {
        let environment = ProcessInfo.processInfo.environment
        let model = environment["SIMULATOR_DEVICE_NAME"] ?? environment["SIMULATOR_MODEL_IDENTIFIER"] ?? deviceModel
        let kind = environment["SIMULATOR_DEVICE_NAME"] != nil ? "ios-simulator" : "ios-device"
        return "\(kind) \(model) iOS \(UIDevice.current.systemVersion)"
    }

    private static var deviceModel: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
