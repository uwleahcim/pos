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

enum PhoneState { off, connecting, registered, failed, ringing, inCall }

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
  DateTime? _answeredAt;

  PhoneSettings get settings => _settings;
  PhoneState get state => _state;

  /// Why the phone is not registered, from the PBX or the network; null when all is well.
  String? get problem => _problem;
  String? get callerNumber => _callerNumber;
  String? get callerName => _callerName;
  bool get muted => _muted;
  DateTime? get answeredAt => _answeredAt;
  bool get running => _started;
  bool get onCall => _state == PhoneState.ringing || _state == PhoneState.inCall;
  Duration? get callDuration => _answeredAt == null ? null : _clock().difference(_answeredAt!);

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

  void answer() {
    if (_state == PhoneState.ringing && _callId != null) _stack.answer(_callId!);
  }

  void decline() {
    if (_state == PhoneState.ringing && _callId != null) _stack.decline(_callId!);
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
    _answeredAt = null;
    _state = PhoneState.ringing;
    notifyListeners();
  }

  @override
  void callAccepted(String callId) {
    if (callId != _callId || _state == PhoneState.inCall) return;
    _state = PhoneState.inCall;
    _answeredAt = _clock();
    notifyListeners();
  }

  @override
  void callEnded(String callId, String? reason) {
    if (callId != _callId) return;
    _clearCall();
    if (_started) _state = _problem == null ? PhoneState.registered : PhoneState.connecting;
    notifyListeners();
  }

  void _clearCall() {
    _callId = null;
    _callerNumber = null;
    _callerName = null;
    _muted = false;
    _answeredAt = null;
  }
}
