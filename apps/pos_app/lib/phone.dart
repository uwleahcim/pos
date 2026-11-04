import 'package:flutter/foundation.dart';

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
  static const _noName = {'unknown', 'anonymous', 'unavailable', 'restricted', 'private'};

  /// The name as an order's customer name: null when there is none, when it only repeats the number, or when it
  /// is the trunk's word for no name (Unknown, Anonymous, Unavailable, Restricted, Private).
  String? get displayName {
    final text = name?.trim() ?? '';
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

/// The phone on this terminal: registration with the PBX and at most one call at a time. A second call while
/// one is on gets a busy answer; the PBX's ring group sends it to the other terminals.
class PhoneClient extends ChangeNotifier implements SipEvents {
  PhoneClient(this._stack, {DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final SipStack _stack;
  final DateTime Function() _clock;

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

  /// How long after a call ends its caller is still the one to start an order for.
  static const recentFor = Duration(minutes: 10);

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

  /// The call's caller while one rings or is on.
  Caller? get caller => _callId == null ? null : Caller(number: _callerNumber, name: _callerName);

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
    _clearCall();
    _problem = null;
    _state = PhoneState.connecting;
    notifyListeners();
    await _stack.start(settings, this);
  }

  Future<void> stop() async {
    final wasRunning = _started;
    _started = false;
    _clearCall();
    _problem = null;
    _state = PhoneState.off;
    if (wasRunning) await _stack.stop();
    notifyListeners();
  }

  /// Listeners hear about the answer before the stack starts on it, so the ring is told to stop before the call's
  /// audio is set up (on iOS the two share one audio session).
  void answer() {
    if (_state != PhoneState.ringing || _callId == null || _answering) return;
    _answering = true;
    notifyListeners();
    _stack.answer(_callId!);
  }

  void decline() {
    if (_state == PhoneState.ringing && _callId != null && !_answering) _stack.decline(_callId!);
  }

  void hangUp() {
    if (_state == PhoneState.inCall && _callId != null) _stack.hangUp(_callId!);
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
    if (!_started || onCall) {
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
    notifyListeners();
  }

  @override
  void callAccepted(String callId) {
    if (callId != _callId || _state == PhoneState.inCall) return;
    _state = PhoneState.inCall;
    _answering = false;
    _answeredAt = _clock();
    _answers++;
    notifyListeners();
  }

  @override
  void callEnded(String callId, String? reason) {
    if (callId != _callId) return;
    _recent = caller;
    _recentAt = _clock();
    _clearCall();
    if (_started) _state = _problem == null ? PhoneState.registered : PhoneState.connecting;
    notifyListeners();
  }

  void _clearCall() {
    _callId = null;
    _callerNumber = null;
    _callerName = null;
    _muted = false;
    _held = false;
    _answering = false;
    _typed = '';
    _answeredAt = null;
  }
}
