import AVFoundation
import CallKit
import Flutter
import PushKit
import UIKit
import UserNotifications

/// The app runs its Flutter engine from launch, with no screen attached, so a VoIP push can wake it into the
/// background and the phone can register with the PBX before anything shows; the scene (SceneDelegate) puts a
/// view on the same engine when the app is brought up. The device's part in calls lives in `CallScreen`.
@main
@objc class AppDelegate: FlutterAppDelegate {
  private(set) var engine: FlutterEngine!
  private(set) var calls: CallScreen!

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let engine = FlutterEngine(name: "pos")
    engine.run()
    GeneratedPluginRegistrant.register(with: engine)
    self.engine = engine
    let ok = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    calls = CallScreen(messenger: engine.binaryMessenger)
    calls.start()
    return ok
  }

  override func application(
    _ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    calls.alertToken(deviceToken)
    super.application(application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
  }

  override func application(
    _ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    NSLog("POS: no notification token: \(error)")
    super.application(application, didFailToRegisterForRemoteNotificationsWithError: error)
  }
}

/// The system's call screen (CallKit), the VoIP push that wakes the app (PushKit) and the notifications, on
/// one method channel with the app's phone (lib/call_screen.dart): the app reports a call it received over
/// SIP, asks the screen to answer or end a call the screen owns, and hears what the person did on it; a push
/// reports its call to CallKit here first, as iOS requires, and then tells the app, which registers and waits
/// for the PBX's invite. Events that arrive before the app's side listens are kept and sent when it does.
class CallScreen: NSObject, PKPushRegistryDelegate, CXProviderDelegate, UNUserNotificationCenterDelegate {
  private struct Call {
    let id: String
    let uuid: UUID
    var answerWaits = false  // answered; the app is told once the audio session is up
  }

  private let channel: FlutterMethodChannel
  private let provider: CXProvider
  private let controller = CXCallController()
  private var registry: PKPushRegistry?
  private var calls: [UUID: Call] = [:]
  private var ready = false
  private var pending: [(String, [String: Any])] = []
  private var voipToken: String?
  private var alertTokenHex: String?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "org.chinasky.pos/calls", binaryMessenger: messenger)
    let config = CXProviderConfiguration()
    config.supportsVideo = false
    config.maximumCallGroups = 1
    config.maximumCallsPerCallGroup = 1
    config.supportedHandleTypes = [.phoneNumber, .generic]
    config.includesCallsInRecents = false
    provider = CXProvider(configuration: config)
    super.init()
    provider.setDelegate(self, queue: nil)
    channel.setMethodCallHandler { [weak self] call, result in self?.handle(call, result: result) }
  }

  /// Asks for the tokens and the notification permission; call once at launch.
  func start() {
    let registry = PKPushRegistry(queue: .main)
    registry.delegate = self
    registry.desiredPushTypes = [.voIP]
    self.registry = registry
    UNUserNotificationCenter.current().delegate = self
    UIApplication.shared.registerForRemoteNotifications()
  }

  func alertToken(_ data: Data) {
    alertTokenHex = data.map { String(format: "%02x", $0) }.joined()
    send("token", ["kind": "alert", "token": alertTokenHex!])
  }

  // MARK: - from the app

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    let id = args["id"] as? String ?? ""
    switch call.method {
    case "ready":
      ready = true
      if let token = voipToken { send("token", ["kind": "voip", "token": token]) }
      if let token = alertTokenHex { send("token", ["kind": "alert", "token": token]) }
      let queued = pending
      pending = []
      for (method, arguments) in queued { send(method, arguments) }
      result(nil)
    case "keepAwake":
      // nothing keeps a locked iPhone's app alive; a screen the app is on can stay lit for calls
      UIApplication.shared.isIdleTimerDisabled = args["on"] as? Bool ?? false
      result(nil)
    case "incoming":
      report(id: id, number: args["number"] as? String ?? "", name: args["name"] as? String ?? "") { shown in
        if !shown { self.send("gone", ["id": id]) }
      }
      result(nil)
    case "answer":
      guard let found = calls.values.first(where: { $0.id == id }) else {
        send("answer", ["id": id])  // not the screen's call: the app goes ahead itself
        return result(nil)
      }
      request(CXAnswerCallAction(call: found.uuid)) { ok in if !ok { self.send("answer", ["id": id]) } }
      result(nil)
    case "end":
      guard let found = calls.values.first(where: { $0.id == id }) else {
        send("end", ["id": id])
        return result(nil)
      }
      request(CXEndCallAction(call: found.uuid)) { ok in if !ok { self.send("end", ["id": id]) } }
      result(nil)
    case "connected":
      result(nil)  // CallKit shows the call as on from the answer
    case "ended":
      if let found = calls.values.first(where: { $0.id == id }) {
        calls.removeValue(forKey: found.uuid)
        provider.reportCall(with: found.uuid, endedAt: nil, reason: endReason(args["reason"] as? String ?? ""))
      }
      result(nil)
    case "wake":
      notify(title: args["title"] as? String ?? "", body: args["body"] as? String ?? "", kind: "pop")
      result(nil)
    case "readiness":
      UNUserNotificationCenter.current().getNotificationSettings { settings in
        let allowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        DispatchQueue.main.async { result(["notifications": allowed]) }
      }
    case "prepare":
      UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in
        DispatchQueue.main.async {
          UIApplication.shared.registerForRemoteNotifications()
          result(nil)
        }
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - to the app

  private func send(_ method: String, _ arguments: [String: Any]) {
    guard ready else {
      pending.append((method, arguments))
      return
    }
    channel.invokeMethod(method, arguments: arguments)
  }

  // MARK: - CallKit

  /// Reports a call to the system's call screen; `done` says whether it shows (Focus can keep it from showing,
  /// and so can a second call: the screen takes one at a time).
  private func report(id: String, number: String, name: String, done: @escaping (Bool) -> Void) {
    let uuid = UUID()
    let update = CXCallUpdate()
    if !number.isEmpty {
      update.remoteHandle = CXHandle(type: .phoneNumber, value: number)
    } else {
      update.remoteHandle = CXHandle(type: .generic, value: name.isEmpty ? "Restaurant line" : name)
    }
    update.localizedCallerName = name.isEmpty ? (number.isEmpty ? "Restaurant line" : pretty(number)) : name
    update.hasVideo = false
    update.supportsHolding = false
    update.supportsGrouping = false
    update.supportsUngrouping = false
    update.supportsDTMF = false
    configureAudioSession()
    provider.reportNewIncomingCall(with: uuid, update: update) { error in
      DispatchQueue.main.async {
        if let error = error {
          NSLog("POS: the call screen did not take call \(id): \(error)")
          done(false)
        } else {
          self.calls[uuid] = Call(id: id, uuid: uuid)
          done(true)
        }
      }
    }
  }

  private func request(_ action: CXCallAction, done: @escaping (Bool) -> Void) {
    controller.request(CXTransaction(action: action)) { error in
      DispatchQueue.main.async {
        if let error = error { NSLog("POS: call action refused: \(error)") }
        done(error == nil)
      }
    }
  }

  private func configureAudioSession() {
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .allowBluetoothA2DP])
    } catch {
      NSLog("POS: audio session category: \(error)")
    }
  }

  private func endReason(_ reason: String) -> CXCallEndedReason {
    switch reason {
    case "remoteEnded": return .remoteEnded
    case "unanswered": return .unanswered
    case "answeredElsewhere": return .answeredElsewhere
    case "declinedElsewhere": return .declinedElsewhere
    default: return .failed
    }
  }

  func providerDidReset(_ provider: CXProvider) {
    for call in calls.values { send("end", ["id": call.id]) }
    calls = [:]
  }

  func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
    guard var call = calls[action.callUUID] else { return action.fail() }
    configureAudioSession()
    call.answerWaits = true
    calls[action.callUUID] = call
    action.fulfill()
    // The app answers the SIP call once the system has the audio session up (didActivate); not long after
    // regardless, in case that never comes.
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.answerNow(action.callUUID) }
  }

  private func answerNow(_ uuid: UUID) {
    guard var call = calls[uuid], call.answerWaits else { return }
    call.answerWaits = false
    calls[uuid] = call
    send("answer", ["id": call.id])
  }

  func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
    for uuid in calls.keys { answerNow(uuid) }
  }

  func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {}

  func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
    if let call = calls.removeValue(forKey: action.callUUID) { send("end", ["id": call.id]) }
    action.fulfill()
  }

  func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
    if let call = calls[action.callUUID] { send("mute", ["id": call.id, "on": action.isMuted]) }
    action.fulfill()
  }

  func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
    action.fulfill()
  }

  // MARK: - PushKit

  func pushRegistry(_ registry: PKPushRegistry, didUpdate credentials: PKPushCredentials, for type: PKPushType) {
    guard type == .voIP else { return }
    voipToken = credentials.token.map { String(format: "%02x", $0) }.joined()
    send("token", ["kind": "voip", "token": voipToken!])
  }

  func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
    guard type == .voIP else { return }
    voipToken = nil
    send("token", ["kind": "voip", "token": ""])
  }

  func pushRegistry(
    _ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType,
    completion: @escaping () -> Void
  ) {
    guard type == .voIP else { return completion() }
    let data = payload.dictionaryPayload
    let kind = data["kind"] as? String ?? "ring"
    let id = data["call"] as? String ?? UUID().uuidString
    let number = data["number"] as? String ?? ""
    let name = data["name"] as? String ?? ""
    let test = kind == "test"
    // A push while the screen shows a call already (this call's invite got here first, the same call pushed
    // again, or another call is on): reported, as every VoIP push must be, and taken down at once.
    if !calls.isEmpty {
      let uuid = UUID()
      provider.reportNewIncomingCall(with: uuid, update: CXCallUpdate()) { _ in
        self.provider.reportCall(with: uuid, endedAt: nil, reason: .unanswered)
        completion()
      }
      return
    }
    report(id: id, number: number, name: name) { shown in
      if shown { self.send("pushed", ["id": id, "number": number, "name": name, "test": test]) }
      completion()
    }
  }

  // MARK: - notifications

  private func notify(title: String, body: String, kind: String) {
    guard UIApplication.shared.applicationState != .active else { return }  // the app shows it itself
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = .default
    content.threadIdentifier = "desk-phone"
    content.userInfo = ["kind": kind]
    if #available(iOS 15.0, *) { content.interruptionLevel = .timeSensitive }
    let request = UNNotificationRequest(identifier: "pop-\(Date().timeIntervalSince1970)", content: content, trigger: nil)
    UNUserNotificationCenter.current().add(request) { error in
      if let error = error { NSLog("POS: notification: \(error)") }
    }
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    // A pick-up while the app is in front opens the order by itself; anything else shows.
    let kind = notification.request.content.userInfo["kind"] as? String ?? ""
    if kind == "pop" && UIApplication.shared.applicationState == .active {
      completionHandler([])
    } else {
      completionHandler([.banner, .sound])
    }
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    send("opened", [:])
    completionHandler()
  }

  private func pretty(_ number: String) -> String {
    var digits = number.filter { $0.isNumber }
    if digits.count == 11 && digits.hasPrefix("1") { digits.removeFirst() }
    guard digits.count == 10 else { return number }
    let d = Array(digits)
    return "(\(String(d[0...2]))) \(String(d[3...5]))-\(String(d[6...9]))"
  }
}
