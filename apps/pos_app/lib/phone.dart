import 'dart:async';

import 'package:flutter/foundation.dart';

import 'call_screen.dart';

/// How this terminal reaches the PBX as a phone: one secure WebSocket to FreePBX and an extension of its own.
/// The display name is the device name, shown to the PBX as the caller name.
@immutable
class PhoneSettings {
  const PhoneSettings({
    this.enabled = false,
    this.server = '',
    this.port = 8089,
    this.extension = '',
    this.secret = '',
    this.displayName = '',
  });

  /// Tidies what was typed: no scheme, path, spaces or slashes around the server (a `:port` on it is taken as
  /// the port), no spaces around the rest.
  factory PhoneSettings.clean({
    required bool enabled,
    required String server,
    required String extension,
    required String secret,
    int port = 8089,
    String displayName = '',
  }) {
    var host = server.trim().replaceFirst(RegExp(r'^[a-z]+://', caseSensitive: false), '');
    host = host.replaceFirst(RegExp(r'/.*$'), '');
    final typedPort = RegExp(r':(\d+)$').firstMatch(host);
    if (typedPort != null) {
      port = int.parse(typedPort.group(1)!);
      host = host.substring(0, typedPort.start);
    }
    return PhoneSettings(
      enabled: enabled,
      server: host,
      port: port,
      extension: extension.trim(),
      secret: secret.trim(),
      displayName: displayName.trim(),
    );
  }

  final bool enabled;
  final String server;
  final int port;
  final String extension;
  final String secret;
  final String displayName;

  bool get complete => server.isNotEmpty && extension.isNotEmpty && secret.isNotEmpty;

  /// Switched on and filled in: the phone should be registered.
  bool get active => enabled && complete;

  /// Asterisk's WebSocket, served by its HTTP server over TLS.
  String get webSocketUrl => 'wss://$server:$port/ws';

  String get sipUri => 'sip:$extension@$server';

  PhoneSettings copyWith({
    bool? enabled,
    String? server,
    int? port,
    String? extension,
    String? secret,
    String? displayName,
  }) => PhoneSettings(
    enabled: enabled ?? this.enabled,
    server: server ?? this.server,
    port: port ?? this.port,
    extension: extension ?? this.extension,
    secret: secret ?? this.secret,
    displayName: displayName ?? this.displayName,
  );

  @override
  bool operator ==(Object other) =>
      other is PhoneSettings &&
      other.enabled == enabled &&
      other.server == server &&
      other.port == port &&
      other.extension == extension &&
      other.secret == secret &&
      other.displayName == displayName;

  @override
  int get hashCode => Object.hash(enabled, server, port, extension, secret, displayName);

  @override
  String toString() => 'PhoneSettings(${enabled ? 'on' : 'off'}, $extension@$server:$port as $displayName)';
}

/// A North American number as people read it, `781 555 1234`; anything else as the PBX sent it.
String formatPhoneNumber(String? raw) {
  final text = raw?.trim() ?? '';
  if (text.isEmpty) return 'Unknown number';
  if (!RegExp(r'^\+?[\d\s().-]+$').hasMatch(text)) return text;
  var digits = text.replaceAll(RegExp(r'\D'), '');
  if (digits.length == 11 && digits.startsWith('1')) digits = digits.substring(1);
  if (digits.length != 10) return text;
  return '${digits.substring(0, 3)} ${digits.substring(3, 6)} ${digits.substring(6)}';
}

/// Who is calling, as the PBX sent it: the number, and the name when the trunk gave one.
@immutable
class Caller {
  const Caller({this.number, this.name});

  final String? number;
  final String? name;

  /// The trunk's words for no name at all.
  static const _noName = {'unknown', 'anonymous', 'unavailable', 'restricted', 'private', 'withheld'};

  /// The name as an order's customer name: null when there is none, when it only repeats the number, or when it
  /// is the trunk's word for no name (Unknown, Anonymous, Unavailable, Restricted, Private, Withheld; Asterisk
  /// writes `<unknown>` for a trunk that sent none).
  String? get displayName {
    final text = (name ?? '').replaceAll(RegExp(r'^\s*<+|>+\s*$'), '').trim();
    if (text.isEmpty || _noName.contains(text.toLowerCase())) return null;
    final digits = text.replaceAll(RegExp(r'\D'), '');
    if (digits.isNotEmpty && digits == text.replaceAll(RegExp(r'[\s().+-]'), '')) {
      final own = (number ?? '').replaceAll(RegExp(r'\D'), '');
      if (own.endsWith(digits) || digits.endsWith(own)) return null;
    }
    return text;
  }

  /// The number as a form shows it (`781 555 1234`), or nothing when the PBX sent none.
  String get formatted => number == null || number!.trim().isEmpty ? '' : formatPhoneNumber(number);

  @override
  bool operator ==(Object other) => other is Caller && other.number == number && other.name == name;

  @override
  int get hashCode => Object.hash(number, name);

  @override
  String toString() => 'Caller($number, $name)';
}

enum PhoneState { off, connecting, registered, failed, ringing, inCall }

/// One line on what the phone is doing, for the settings screen and the status details.
String phoneStatusLine(PhoneClient phone) {
  final s = phone.settings;
  return switch (phone.state) {
    PhoneState.off => 'Off. Switch on, fill in the PBX, extension and secret, then save',
    PhoneState.connecting => 'Connecting to ${s.server}${phone.problem == null ? '' : ' · ${phone.problem}'}',
    PhoneState.registered => 'Registered as ${s.extension} on ${s.server}',
    PhoneState.failed => 'Not registered: ${phone.problem}',
    PhoneState.ringing => 'Ringing · ${formatPhoneNumber(phone.callerNumber)}',
    PhoneState.inCall => 'On a call · ${formatPhoneNumber(phone.callerNumber)}',
  };
}

/// What the SIP stack tells the phone.
abstract interface class SipEvents {
  void registered();
  void registrationFailed(String reason);
  void disconnected(String reason);
  void incomingCall(String callId, {String? number, String? name});
  void callAccepted(String callId);
  void callEnded(String callId, String? reason);
}

/// What the phone asks of the SIP stack. The real one wraps sip_ua; tests use a fake.
abstract interface class SipStack {
  Future<void> start(PhoneSettings settings, SipEvents events);
  Future<void> stop();
  void answer(String callId);
  void hangUp(String callId);
  void decline(String callId);
  void setMuted(String callId, bool on);
  void setHeld(String callId, bool on);

  /// Plays these keys (`0`-`9`, `*`, `#`) to the other side, one after the other.
  void sendDtmf(String callId, String tones);

  /// Hands the call to another extension or number and leaves it (a blind transfer); the PBX then ends this
  /// side of the call.
  void transfer(String callId, String target);
}

/// Where a call stands on the hub (`GET /phones/calls/<id>`): a phone woken for it asks, so a call answered
/// on another phone, or given up by the caller, comes off its screen before the invite would have arrived.
enum CallProgress { ringing, answered, ended, unknown }

@immutable
class CallOnHub {
  const CallOnHub(this.progress, {this.answered = const []});

  factory CallOnHub.fromJson(Map<String, dynamic> json) => CallOnHub(
    switch (json['state']) {
      'ringing' => CallProgress.ringing,
      'answered' => CallProgress.answered,
      'ended' => CallProgress.ended,
      _ => CallProgress.unknown,
    },
    answered: [for (final e in json['answered'] as List? ?? const []) e.toString()],
  );

  final CallProgress progress;

  /// The extensions the call was answered on (a transfer adds one).
  final List<String> answered;
}

typedef CallLookup = Future<CallOnHub> Function(String callId);

/// The phone on this terminal: registration with the PBX and at most one call at a time. A second call while
/// one is on gets a busy answer; the PBX's ring group sends it to the other terminals.
///
/// With a [CallScreen], the device's own call screen takes part: a push that woke the device for a call
/// ([pushed]) rings there before the PBX's invite can arrive (the phone registers again meanwhile), and on a
/// platform whose screen owns Answer and End (iOS) the app's own buttons go through it, so the system's call
/// screen, the audio session and the SIP call agree.
class PhoneClient extends ChangeNotifier implements SipEvents {
  PhoneClient(
    this._stack, {
    DateTime Function()? clock,
    CallScreen? screen,
    this.callState,
    bool Function()? isForeground,
  }) : _clock = clock ?? DateTime.now,
       _screen = screen ?? NoCallScreen(),
       _isForeground = isForeground ?? (() => true);

  final SipStack _stack;
  final DateTime Function() _clock;
  final CallScreen _screen;

  /// Asks the hub where a call stands (`PosApi.callState`); without it a pushed call waits for its invite or
  /// the timeout alone.
  final CallLookup? callState;
  final bool Function() _isForeground;

  PhoneSettings _settings = const PhoneSettings();
  bool _started = false;
  PhoneState _state = PhoneState.off;
  String? _problem;
  String? _callId;
  String? _callerNumber;
  String? _callerName;
  bool _muted = false;
  bool _held = false;
  bool _answering = false;
  String _typed = '';
  DateTime? _answeredAt;
  Caller? _recent;
  DateTime? _recentAt;
  int _orderRequests = 0;
  int _answers = 0;
  String? _pushedId; // the id a push carried (the PBX's), while the device's screen shows the call
  bool _screenOwns = false; // the device's screen shows the call and owns Answer and End (iOS)
  bool _screenRings = false; // the device's own screen rings for this call: the app's ringer stays quiet
  bool _screenAnswered = false; // answered on the device's screen before the PBX's invite arrived
  bool _test = false; // a test call the hub sent by hand: nothing is coming behind it
  Timer? _expect; // gives a pushed call up when its invite never comes
  Timer? _check; // asks the hub where a pushed call stands
  Timer? _grace; // a push on a registered, foreground phone: the invite should follow, else register anew
  final _declined = <String, DateTime>{}; // numbers declined on the screen lately: their late invite is turned away
  DateTime? _pausedAt;

  /// How long after a call ends its caller is still the one to start an order for.
  static const recentFor = Duration(minutes: 10);

  /// How long a pushed call waits for the PBX's invite: a ring group rings again after thirty seconds, so a
  /// phone that woke too late for one pass still gets the next.
  static const expectFor = Duration(seconds: 45);

  /// How often a pushed call asks the hub where it stands while the invite is on its way.
  static const checkEvery = Duration(seconds: 2);

  /// How long a number declined on the device's screen is turned away: the same call's invite, coming late.
  static const declinedFor = Duration(minutes: 2);

  /// A push on a phone that believes itself registered, in the foreground: this long for the invite to show
  /// the registration is live; else the phone registers anew.
  static const graceFor = Duration(seconds: 3);

  /// A pause (the app in the background) longer than this: the connection is taken for dead on resume.
  static const pausedLong = Duration(seconds: 15);

  /// A test call rings this long and then goes away by itself.
  static const testRingsFor = Duration(seconds: 8);

  PhoneSettings get settings => _settings;
  PhoneState get state => _state;

  /// Why the phone is not registered, from the PBX or the network; null when all is well.
  String? get problem => _problem;

  /// Switched on but not registered for a reason: refused, or the connection dropped. Shown in the status bar.
  bool get inTrouble =>
      _settings.enabled && (_state == PhoneState.failed || (_state == PhoneState.connecting && _problem != null));
  String? get callerNumber => _callerNumber;
  String? get callerName => _callerName;
  bool get muted => _muted;

  /// The caller is on hold, hearing the PBX's music.
  bool get held => _held;

  /// What was typed on the keypad and not used yet: the tones to send, or whom to transfer to.
  String get typed => _typed;

  /// Answer was tapped and the PBX has not confirmed the call yet: the ring stops and the banner's buttons wait.
  bool get answering => _answering;
  DateTime? get answeredAt => _answeredAt;
  bool get running => _started;
  bool get onCall => _state == PhoneState.ringing || _state == PhoneState.inCall;
  Duration? get callDuration => _answeredAt == null ? null : _clock().difference(_answeredAt!);

  /// The id of the call a push woke the device for, while it rings or waits for its invite; null otherwise.
  String? get pushedId => _pushedId;

  /// The device's own call screen rings for this call (the system's on iOS): the app's ringer keeps quiet.
  bool get screenRings => _screenRings;

  /// A test call from the hub (`hubctl push test <device> voip`): it rings and goes away by itself.
  bool get testCall => _test;

  /// The call's caller while one rings or is on.
  Caller? get caller => _callId == null && _pushedId == null ? null : Caller(number: _callerNumber, name: _callerName);

  /// The last call's caller for [recentFor] after it ended: the order often starts after the hang-up.
  Caller? get recentCaller {
    final at = _recentAt;
    if (_recent == null || at == null || _clock().difference(at) > recentFor) return null;
    return _recent;
  }

  /// Whom a to-go order started now is for: the caller on the line, else the one who just hung up.
  Caller? get callerForOrder => caller ?? recentCaller;

  /// How many times To go was tapped on a call; the orders screen opens the order form on each change.
  int get orderRequests => _orderRequests;

  /// How many calls this terminal has picked up; the orders screen opens the caller's order on each change.
  int get answers => _answers;

  /// The id the device's screen knows the call by: the push's, else the SIP stack's.
  String? get _screenId => _pushedId ?? _callId;

  /// To go tapped on the call banner or strip: asks whatever screen listens to start an order for the caller.
  void startOrder() {
    _orderRequests++;
    notifyListeners();
  }

  /// Registers with these settings, or stops when they are off or incomplete. Applying the same settings
  /// again changes nothing, so a saved settings screen does not drop a registration.
  Future<void> apply(PhoneSettings settings) async {
    if (settings == _settings && settings.active == _started) return;
    _settings = settings;
    if (!settings.active) {
      await stop();
      return;
    }
    if (_started) await _stack.stop();
    _started = true;
    _dropCall(reason: 'failed');
    _problem = null;
    _state = PhoneState.connecting;
    notifyListeners();
    await _stack.start(settings, this);
  }

  Future<void> stop() async {
    final wasRunning = _started;
    _started = false;
    _dropCall(reason: 'failed');
    _problem = null;
    _state = PhoneState.off;
    if (wasRunning) await _stack.stop();
    notifyListeners();
  }

  /// The connection is started over: the same settings, a fresh socket and registration. For a phone that
  /// was suspended (iOS) and still believes in a socket that is dead. A call that is on is left alone.
  Future<void> _restart() async {
    if (!_started || _callId != null) return;
    await _stack.stop();
    if (!_started) return;
    _problem = null;
    if (!onCall) _state = PhoneState.connecting;
    notifyListeners();
    await _stack.start(_settings, this);
  }

  /// The app went to the background (the screen locked, another app in front).
  void paused() => _pausedAt = _clock();

  /// The app is in front again: after a long pause the connection is taken for dead and started over, so the
  /// phone is registered again at once rather than when the dead socket times out.
  void resumed() {
    final at = _pausedAt;
    _pausedAt = null;
    if (!_started || onCall || at == null || _clock().difference(at) < pausedLong) return;
    unawaited(_restart());
  }

  /// Listeners hear about the answer before the stack starts on it, so the ring is told to stop before the call's
  /// audio is set up (on iOS the two share one audio session). When the device's screen owns the call, the
  /// screen is asked and the stack hears from it ([screenAnswered]).
  void answer() {
    if (_state != PhoneState.ringing || _answering) return;
    final screenId = _screenId;
    if (_screenOwns && screenId != null) {
      _answering = true;
      notifyListeners();
      _screen.answer(screenId);
      return;
    }
    if (_callId == null) return;
    _answering = true;
    notifyListeners();
    _stack.answer(_callId!);
  }

  void decline() {
    if (_state != PhoneState.ringing || _answering) return;
    final screenId = _screenId;
    if (_screenOwns && screenId != null) {
      _screen.end(screenId);
      return;
    }
    if (_callId != null) _stack.decline(_callId!);
  }

  void hangUp() {
    if (_state != PhoneState.inCall || _callId == null) return;
    if (_screenOwns && _screenId != null) {
      _screen.end(_screenId!);
      return;
    }
    _stack.hangUp(_callId!);
  }

  void toggleMute() {
    if (_state != PhoneState.inCall || _callId == null) return;
    _muted = !_muted;
    _stack.setMuted(_callId!, _muted);
    notifyListeners();
  }

  void toggleHold() {
    if (_state != PhoneState.inCall || _callId == null) return;
    _held = !_held;
    _stack.setHeld(_callId!, _held);
    notifyListeners();
  }

  static final _keys = RegExp(r'^[0-9*#]$');

  /// One keypad key; anything that is not one is ignored.
  void type(String key) {
    if (_state != PhoneState.inCall || !_keys.hasMatch(key)) return;
    _typed += key;
    notifyListeners();
  }

  void backspace() {
    if (_typed.isEmpty) return;
    _typed = _typed.substring(0, _typed.length - 1);
    notifyListeners();
  }

  /// Plays what was typed to the other side (a menu, a voicemail box), and clears it.
  void sendTones() {
    if (_state != PhoneState.inCall || _callId == null || _typed.isEmpty) return;
    _stack.sendDtmf(_callId!, _typed);
    _typed = '';
    notifyListeners();
  }

  /// Hands the call to the extension or number typed and clears it; the call ends here when the PBX takes it.
  void transfer() {
    if (_state != PhoneState.inCall || _callId == null || _typed.isEmpty) return;
    _stack.transfer(_callId!, _typed);
    _typed = '';
    notifyListeners();
  }

  // --- the device's screen -----------------------------------------------------------------------------------

  /// A push woke the device for a call: the device's screen rings for it already (iOS reports it to the
  /// system's call screen before telling the app). The phone rings along, quietly, and makes sure it is
  /// registered so the PBX's invite can arrive; [incomingCall] then attaches the invite to this call. A [test]
  /// call has nothing behind it: it rings for [testRingsFor] and goes away, at once when answered.
  void pushed(String id, {String? number, String? name, bool test = false}) {
    if (!test && !_started) {
      _screen.ended(id, reason: 'failed'); // the phone is off here: nothing will come for it
      return;
    }
    if (_declinedLately(number)) {
      _screen.ended(id, reason: 'declinedElsewhere');
      return;
    }
    if (onCall) {
      // busy with another call (the ring group has the other phones), or the push of a call known already;
      // a push for the very call the invite brought first never gets here: the device keeps that to itself
      if (_pushedId != id) _screen.ended(id, reason: 'unanswered');
      return;
    }
    final was = _state;
    _clearCall();
    _pushedId = id;
    _callerNumber = number;
    _callerName = name;
    _test = test;
    _screenOwns = true;
    _screenRings = true;
    _state = PhoneState.ringing;
    if (test) {
      _expect = Timer(testRingsFor, () => _giveUp(reason: 'unanswered'));
    } else {
      _expect = Timer(expectFor, () => _giveUp(reason: 'unanswered'));
      _check = Timer.periodic(checkEvery, (_) => unawaited(_checkCall()));
      _freshen(was);
    }
    notifyListeners();
  }

  /// Answer on the device's screen: the SIP call is answered, or will be the moment its invite arrives.
  void screenAnswered(String id) {
    if (id != _screenId || _state != PhoneState.ringing) return;
    if (_test) {
      _giveUp(reason: 'remoteEnded');
      return;
    }
    _answering = true;
    if (_callId == null) {
      _screenAnswered = true;
    } else {
      _stack.answer(_callId!);
    }
    notifyListeners();
  }

  /// Decline or End on the device's screen.
  void screenEnded(String id) {
    if (id != _screenId) return;
    if (_state == PhoneState.inCall) {
      if (_callId != null) _stack.hangUp(_callId!);
      return;
    }
    if (_state != PhoneState.ringing) return;
    if (_pushedId != null) _rememberDeclined(_callerNumber);
    if (_callId != null) {
      _stack.decline(_callId!);
      return;
    }
    _giveUp(reason: 'declinedElsewhere', tell: false);
  }

  /// Mute on the device's screen.
  void screenMuted(String id, bool on) {
    if (id != _screenId || _state != PhoneState.inCall || _callId == null || _muted == on) return;
    _muted = on;
    _stack.setMuted(_callId!, on);
    notifyListeners();
  }

  /// The device's screen will not show the call after all: the app rings and acts for it itself. A pushed
  /// call without a screen has nobody to answer it before its invite: it waits for the invite as any call.
  void screenGone(String id) {
    if (id != _screenId || !onCall) return;
    _screenOwns = false;
    _screenRings = false;
    notifyListeners();
  }

  /// The push promises an invite; it can only arrive over a live registration. A phone registered and in the
  /// foreground is given [graceFor] for the invite before it registers anew (a push sent while the invite was
  /// already on its way: both at once); a phone that was in the background or suspended, or whose connection
  /// dropped, registers anew at once; one connecting already is left to it.
  void _freshen(PhoneState was) {
    if (!_started || _callId != null) return;
    if (was == PhoneState.connecting && _problem == null) return;
    final trusted = was == PhoneState.registered && _isForeground() && _pausedAt == null;
    if (!trusted) {
      unawaited(_restart());
      return;
    }
    _grace = Timer(graceFor, () {
      if (_pushedId != null && _callId == null) unawaited(_restart());
    });
  }

  Future<void> _checkCall() async {
    final id = _pushedId;
    final lookup = callState;
    if (id == null || lookup == null || _callId != null) return;
    CallOnHub found;
    try {
      found = await lookup(id);
    } catch (_) {
      return; // nothing answers: the invite, or the timeout, decides
    }
    if (_pushedId != id || _callId != null) return;
    if (found.progress == CallProgress.ended) {
      _giveUp(reason: 'remoteEnded');
    } else if (found.progress == CallProgress.answered && !found.answered.contains(_settings.extension)) {
      _giveUp(reason: 'answeredElsewhere');
    }
  }

  /// A pushed call is over without its invite: answered elsewhere, given up, declined here, or never came.
  void _giveUp({required String reason, bool tell = true}) {
    final id = _pushedId;
    _clearCall();
    _state = !_started ? PhoneState.off : (_problem == null ? PhoneState.registered : PhoneState.connecting);
    if (id != null && tell) _screen.ended(id, reason: reason);
    notifyListeners();
  }

  void _rememberDeclined(String? number) {
    final digits = _digits(number);
    if (digits.isNotEmpty) _declined[digits] = _clock();
  }

  bool _declinedLately(String? number) {
    final now = _clock();
    _declined.removeWhere((_, at) => now.difference(at) > declinedFor);
    final digits = _digits(number);
    return digits.isNotEmpty && _declined.keys.any((d) => d.endsWith(digits) || digits.endsWith(d));
  }

  static String _digits(String? number) => (number ?? '').replaceAll(RegExp(r'\D'), '');

  // --- the SIP stack ----------------------------------------------------------------------------------------

  @override
  void registered() {
    if (!_started || onCall) return;
    _state = PhoneState.registered;
    _problem = null;
    notifyListeners();
  }

  @override
  void registrationFailed(String reason) {
    if (!_started) return;
    _problem = reason;
    if (!onCall) _state = PhoneState.failed;
    notifyListeners();
  }

  @override
  void disconnected(String reason) {
    if (!_started) return;
    _problem = reason;
    if (!onCall) _state = PhoneState.connecting;
    notifyListeners();
  }

  @override
  void incomingCall(String callId, {String? number, String? name}) {
    if (!_started || _declinedLately(number)) {
      _stack.decline(callId);
      return;
    }
    if (_pushedId != null && _callId == null && !_test) {
      // the invite the push promised: the call the screen shows gets its SIP side
      _callId = callId;
      _callerNumber ??= number;
      _callerName ??= name;
      _cancelTimers();
      if (_screenAnswered) {
        _screenAnswered = false;
        _answering = true;
        _stack.answer(callId);
      }
      notifyListeners();
      return;
    }
    if (onCall) {
      _stack.decline(callId);
      return;
    }
    _callId = callId;
    _callerNumber = number;
    _callerName = name;
    _muted = false;
    _answering = false;
    _answeredAt = null;
    _state = PhoneState.ringing;
    _screenOwns = _screen.routesActions; // the system's call screen shows it and rings for it on iOS
    _screenRings = _screenOwns;
    _screen.incoming(callId, number: number, name: name);
    notifyListeners();
  }

  @override
  void callAccepted(String callId) {
    if (callId != _callId || _state == PhoneState.inCall) return;
    _state = PhoneState.inCall;
    _answering = false;
    _screenAnswered = false;
    _answeredAt = _clock();
    _answers++;
    _screen.connected(_screenId!);
    notifyListeners();
  }

  @override
  void callEnded(String callId, String? reason) {
    if (callId != _callId) return;
    _recent = caller;
    _recentAt = _clock();
    final screenId = _screenId!;
    final wasOn = _answeredAt != null;
    _clearCall();
    if (_started) _state = _problem == null ? PhoneState.registered : PhoneState.connecting;
    _screen.ended(screenId, reason: wasOn ? 'remoteEnded' : 'unanswered');
    notifyListeners();
  }

  /// A call the device's screen shows is dropped with it (the phone switched off, or started over).
  void _dropCall({required String reason}) {
    final screenId = _screenId;
    _clearCall();
    if (screenId != null) _screen.ended(screenId, reason: reason);
  }

  void _clearCall() {
    _cancelTimers();
    _callId = null;
    _pushedId = null;
    _callerNumber = null;
    _callerName = null;
    _muted = false;
    _held = false;
    _answering = false;
    _screenOwns = false;
    _screenRings = false;
    _screenAnswered = false;
    _test = false;
    _typed = '';
    _answeredAt = null;
  }

  void _cancelTimers() {
    _expect?.cancel();
    _check?.cancel();
    _grace?.cancel();
    _expect = _check = _grace = null;
  }

  @override
  void dispose() {
    _cancelTimers();
    super.dispose();
  }
}
