import Flutter
import UIKit

/// Puts the app's screen on the engine the AppDelegate started at launch (the storyboard would make an engine
/// of its own, which a push-woken app must not have), then lets Flutter's own scene delegate do its part, as it
/// does for a storyboard's window: scene events and the connection's options reach the engine and the plugins.
class SceneDelegate: FlutterSceneDelegate {
  override func scene(
    _ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions
  ) {
    if let windowScene = scene as? UIWindowScene, let app = UIApplication.shared.delegate as? AppDelegate {
      let window = UIWindow(windowScene: windowScene)
      window.rootViewController = FlutterViewController(engine: app.engine, nibName: nil, bundle: nil)
      self.window = window
      window.makeKeyAndVisible()
    }
    super.scene(scene, willConnectTo: session, options: connectionOptions)
  }
}
