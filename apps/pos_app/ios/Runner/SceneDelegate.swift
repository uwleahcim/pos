import Flutter
import UIKit

/// Puts the app's screen on the engine the AppDelegate started at launch (the storyboard would make an engine
/// of its own, which a push-woken app must not have). Scene events still reach Flutter through the base class.
class SceneDelegate: FlutterSceneDelegate {
  func scene(
    _ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions
  ) {
    guard let windowScene = scene as? UIWindowScene,
      let app = UIApplication.shared.delegate as? AppDelegate
    else { return }
    let window = UIWindow(windowScene: windowScene)
    window.rootViewController = FlutterViewController(engine: app.engine, nibName: nil, bundle: nil)
    self.window = window
    window.makeKeyAndVisible()
  }
}
