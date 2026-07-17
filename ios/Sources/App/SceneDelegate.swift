import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var services: AppServices?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let services = AppServices()
        self.services = services

        let window = UIWindow(windowScene: windowScene)
        // Dark-first: the terminal canvas is dark regardless of system setting,
        // so the chrome (rail, drawer, sheets) must match.
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = MainViewController(services: services)
        window.makeKeyAndVisible()
        self.window = window

        handle(urlContexts: connectionOptions.urlContexts)
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        handle(urlContexts: URLContexts)
    }

    private func handle(urlContexts: Set<UIOpenURLContext>) {
        for context in urlContexts where services?.handlePairingURL(context.url) == true {
            // Pairing UI (scanner / paste sheet) is now stale; drop it.
            window?.rootViewController?.presentedViewController?.dismiss(animated: true)
            return
        }
    }
}
