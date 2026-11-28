import UIKit
import FieldmartCore

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Launch arguments (`-fmRun x -fmVariant stream-img …`) arrive in
        // UserDefaults' argument domain.
        let settings = LaunchSettings(lookup: { UserDefaults.standard.string(forKey: $0) })
        // The SDK starts first, as its docs show (the `off` build: a no-op).
        let sdkStartMs = AppEnvironment.shared.telemetry.start(settings)
        AppEnvironment.shared.bootstrap(settings: settings, sdkStartMs: sdkStartMs)
        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = RootTabBarController()
        window.tintColor = Palette.accent
        self.window = window
        window.makeKeyAndVisible()
        AppEnvironment.shared.watchFirstFrame()
    }
}
