import UIKit
import Capacitor
import SwiftUI

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private(set) var importLifecycle: BJJImportLifecycleCoordinator?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let library: BJJNativeLibrary
        #if DEBUG
        library = BJJUITestFixture.library() ?? BJJNativeLibrary()
        #else
        library = BJJNativeLibrary()
        #endif
        importLifecycle = BJJImportLifecycleCoordinator(sceneID: session.persistentIdentifier, library: library)
        importLifecycle?.observe(scene.activationState, sceneID: session.persistentIdentifier)
        window = UIWindow(windowScene: windowScene)
        window?.rootViewController = UIHostingController(rootView: BJJNativeHome(library: library))
        window?.makeKeyAndVisible()

        if let url = connectionOptions.urlContexts.first?.url { BJJPackageInbox.receive(url) }

        SceneDelegateProxy.shared.scene(scene, willConnectTo: session, options: connectionOptions)
    }

    func sceneDidBecomeActive(_ scene: UIScene) { forwardImportLifecycle(scene, .foregroundActive) }
    func sceneWillResignActive(_ scene: UIScene) { forwardImportLifecycle(scene, .foregroundInactive) }
    func sceneDidEnterBackground(_ scene: UIScene) { forwardImportLifecycle(scene, .background) }
    func sceneWillEnterForeground(_ scene: UIScene) { forwardImportLifecycle(scene, .foregroundInactive) }
    private func forwardImportLifecycle(_ scene: UIScene, _ state: UIScene.ActivationState) {
        importLifecycle?.observe(state, sceneID: scene.session.persistentIdentifier)
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        if let url = URLContexts.first?.url { BJJPackageInbox.receive(url) }
        SceneDelegateProxy.shared.scene(scene, openURLContexts: URLContexts)
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        SceneDelegateProxy.shared.scene(scene, continue: userActivity)
    }
}

enum BJJImportSceneState: String { case unknown, active, foregroundInactive = "foreground_inactive", background }

@MainActor final class BJJImportLifecycleCoordinator {
    let sceneID: String
    let library: BJJNativeLibrary
    init(sceneID: String, library: BJJNativeLibrary) { self.sceneID = sceneID; self.library = library }
    func observe(_ state: UIScene.ActivationState, sceneID: String) {
        guard sceneID == self.sceneID else { return }
        let observed: BJJImportSceneState
        switch state {
        case .foregroundActive: observed = .active
        case .foregroundInactive: observed = .foregroundInactive
        case .background: observed = .background
        default: observed = .unknown
        }
        library.observeScene(observed, source: "ui_scene_delegate")
    }
}
