import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The device's own part in a call, for when the app cannot do it alone: on an iPhone or iPad the system's
/// call screen (CallKit), which rings on the lock screen and is what the push that wakes the app reports to;
/// on Android the service that keeps the app alive with the screen off and the notification that lights the
/// screen for a call; on a Mac the hold that keeps it from sleeping. The app's phone talks to it by call id
/// and hears back what the person did on it ([CallScreenEvents]). A [NoCallScreen] stands in where there is
/// nothing of the kind, and in tests.
abstract interface class CallScreen {
  /// Whether the device's screen owns Answer and End for a call it shows: on iOS the system's call screen does,
  /// so the app asks it ([answer], [end]) and acts on the SIP call when it hears back; elsewhere the app acts
  /// at once and only tells the screen ([connected], [ended]).
  bool get routesActions;

  /// Keep the device awake and the app alive for calls: the phone is on, or a desk phone is linked to this
  /// screen. On Android this runs the foreground service; on a Mac it holds off sleep; on iOS nothing can.
  void keepAwake(bool on);

  /// A call the SIP stack received rings: show it the device's way (the system's call screen on iOS, the
  /// full-screen notification on Android, the lit display on a Mac).
  void incoming(String id, {String? number, String? name});

  /// Answer tapped in the app for a call the device's screen owns: the screen answers and reports back.
  void answer(String id);

  /// Decline or Hang up tapped in the app for a call the device's screen owns: the screen ends it and reports back.
  void end(String id);

  /// The call is on (the PBX confirmed): the screen shows it as a call in progress.
  void connected(String id);

  /// The call is over, or never came: `remoteEnded`, `unanswered`, `answeredElsewhere`, `declinedElsewhere`,
  /// `failed`. The screen takes it down.
  void ended(String id, {required String reason});

  /// A desk phone linked to this screen picked up: light the screen and bring the app up, or say so in a
  /// notification when the platform allows no more.
  void wake({required String title, required String body});

  /// What the platform still needs from the person for calls with the screen off, each true when granted:
  /// Android's `notifications`, `fullScreen` and `battery`; nothing elsewhere.
  Future<Map<String, bool>> readiness();

  /// Asks for whatever [readiness] found missing, with the system's own dialogs.
  Future<void> prepare();

  /// Who hears what the person does on the screen, and the tokens it is given.
  set events(CallScreenEvents? events);

  /// The app listens now: the screen sends what it has (tokens, a call a push brought before the app was up).
  void ready();
}

/// What the device's screen tells the app.
abstract interface class CallScreenEvents {
  /// A push token: `voip` (iOS, for calls) or `alert` (for notifications), as hex; empty when revoked.
  void pushToken(String kind, String token);

  /// A push woke the device for a call (or a `test` call the hub sent by hand): the screen already rings for
  /// it; the PBX's invite follows once the phone is registered again.
  void pushed(String id, {String? number, String? name, bool test = false});

  /// Answer on the device's screen.
  void screenAnswered(String id);

  /// Decline or End on the device's screen.
  void screenEnded(String id);

  /// Mute toggled on the device's screen.
  void screenMuted(String id, bool on);

  /// The device's screen will not show this call after all (a Focus mode kept it off, another call has the
  /// screen): the app rings and acts for it itself.
  void screenGone(String id);

  /// The app was brought up by a tap on a notification (a desk-phone pick-up): the hub has something waiting.
  void opened();
}

/// Nothing of the kind on this platform, and in tests: the app rings and shows calls by itself.
class NoCallScreen implements CallScreen {
  @override
  bool get routesActions => false;
  @override
  void keepAwake(bool on) {}
  @override
  void incoming(String id, {String? number, String? name}) {}
  @override
  void answer(String id) {}
  @override
  void end(String id) {}
  @override
  void connected(String id) {}
  @override
  void ended(String id, {required String reason}) {}
  @override
  void wake({required String title, required String body}) {}
  @override
  Future<Map<String, bool>> readiness() async => const {};
  @override
  Future<void> prepare() async {}
  @override
  set events(CallScreenEvents? events) {}
  @override
  void ready() {}
}

/// The device's screen over a method channel to the native side (ios/Runner, android/.../PhoneService,
/// macos/Runner), which keeps what the app cannot: the push registry, CallKit, the foreground service, the
/// sleep hold. A call that fails on the native side is logged, never thrown: the SIP call goes on regardless.
class NativeCallScreen implements CallScreen {
  NativeCallScreen({MethodChannel? channel, bool? routesActions})
    : _channel = channel ?? const MethodChannel('org.chinasky.pos/calls'),
      routesActions = routesActions ?? Platform.isIOS {
    _channel.setMethodCallHandler(_fromNative);
  }

  /// The screen for this platform: native on iOS, Android and macOS, nothing elsewhere (and when the
  /// platform has no native side, as in tests).
  static CallScreen forPlatform() {
    if (kIsWeb) return NoCallScreen();
    if (Platform.isIOS || Platform.isAndroid || Platform.isMacOS) return NativeCallScreen();
    return NoCallScreen();
  }

  final MethodChannel _channel;
  CallScreenEvents? _events;

  @override
  final bool routesActions;

  @override
  set events(CallScreenEvents? events) => _events = events;

  @override
  void ready() => _call('ready');

  @override
  void keepAwake(bool on) => _call('keepAwake', {'on': on});

  @override
  void incoming(String id, {String? number, String? name}) =>
      _call('incoming', {'id': id, 'number': number ?? '', 'name': name ?? ''});

  @override
  void answer(String id) => _call('answer', {'id': id});

  @override
  void end(String id) => _call('end', {'id': id});

  @override
  void connected(String id) => _call('connected', {'id': id});

  @override
  void ended(String id, {required String reason}) => _call('ended', {'id': id, 'reason': reason});

  @override
  void wake({required String title, required String body}) => _call('wake', {'title': title, 'body': body});

  @override
  Future<Map<String, bool>> readiness() async {
    try {
      final found = await _channel.invokeMapMethod<String, Object?>('readiness');
      return {for (final e in (found ?? const {}).entries) e.key: e.value == true};
    } on PlatformException catch (err) {
      debugPrint('call screen readiness: $err');
      return const {};
    } on MissingPluginException {
      return const {};
    }
  }

  @override
  Future<void> prepare() async {
    try {
      await _channel.invokeMethod<void>('prepare');
    } on PlatformException catch (err) {
      debugPrint('call screen prepare: $err');
    } on MissingPluginException {
      // no native side
    }
  }

  void _call(String method, [Map<String, Object?>? args]) {
    unawaited(
      _channel.invokeMethod<void>(method, args).catchError((Object err) {
        debugPrint('call screen $method: $err');
      }),
    );
  }

  Future<Object?> _fromNative(MethodCall call) async {
    final events = _events;
    if (events == null) return null;
    final args = call.arguments is Map ? (call.arguments as Map).cast<String, Object?>() : const <String, Object?>{};
    String text(String key) => (args[key] as String?) ?? '';
    switch (call.method) {
      case 'token':
        events.pushToken(text('kind'), text('token'));
      case 'pushed':
        events.pushed(
          text('id'),
          number: text('number').isEmpty ? null : text('number'),
          name: text('name').isEmpty ? null : text('name'),
          test: args['test'] == true,
        );
      case 'answer':
        events.screenAnswered(text('id'));
      case 'end':
        events.screenEnded(text('id'));
      case 'mute':
        events.screenMuted(text('id'), args['on'] == true);
      case 'gone':
        events.screenGone(text('id'));
      case 'opened':
        events.opened();
    }
    return null;
  }
}
