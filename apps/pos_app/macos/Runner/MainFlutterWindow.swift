import Cocoa
import FlutterMacOS
import IOKit.pwr_mgt

class MainFlutterWindow: NSWindow {
  private var calls: CallScreen?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    calls = CallScreen(messenger: flutterViewController.engine.binaryMessenger, window: self)

    super.awakeFromNib()
  }
}

/// The Mac's part in calls, for the app's phone (lib/call_screen.dart): while the phone is on or a desk phone is
/// linked, the Mac is kept from going to sleep by itself (a Mac put to sleep by hand stays asleep: nothing can
/// wake it); for a call or a desk-phone pick-up the display is lit and the app brought to the front. The app
/// rings and answers itself, as on Android.
class CallScreen {
  private let channel: FlutterMethodChannel
  private weak var window: NSWindow?
  private var awake: NSObjectProtocol?

  init(messenger: FlutterBinaryMessenger, window: NSWindow) {
    self.window = window
    channel = FlutterMethodChannel(name: "org.chinasky.pos/calls", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in self?.handle(call, result: result) }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "keepAwake":
      keepAwake(args["on"] as? Bool ?? false)
      result(nil)
    case "incoming", "wake":
      light()
      result(nil)
    case "answer", "end":
      // the app acts itself on a Mac
      channel.invokeMethod(call.method, arguments: ["id": args["id"] as? String ?? ""])
      result(nil)
    case "ready", "connected", "ended", "prepare":
      result(nil)
    case "readiness":
      result([String: Bool]())
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func keepAwake(_ on: Bool) {
    if on {
      if awake == nil {
        awake = ProcessInfo.processInfo.beginActivity(
          options: [.idleSystemSleepDisabled], reason: "The POS phone is on: calls must ring")
      }
    } else if let token = awake {
      ProcessInfo.processInfo.endActivity(token)
      awake = nil
    }
  }

  /// Lights a display that went dark, and brings the app to the front.
  private func light() {
    var id: IOPMAssertionID = 0
    IOPMAssertionDeclareUserActivity("POS call" as CFString, kIOPMUserActiveLocal, &id)
    NSApp.activate(ignoringOtherApps: true)
    window?.makeKeyAndOrderFront(nil)
  }
}
