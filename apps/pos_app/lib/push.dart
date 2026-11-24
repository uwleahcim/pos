import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';

import 'api.dart';
import 'call_screen.dart';
import 'settings.dart';

/// Keeps the hub's registry of this screen's push tokens right, so the hub can wake it: the `voip` token
/// (iOS) while the phone is on here, with the extension it registers as, so the hub marks that extension on
/// the PBX and pushes when it rings; the `alert` token for a desk-phone pick-up. Tokens come from the device's
/// screen as the system hands them out ([CallScreenEvents.pushToken]); the hub hears on every change, on
/// every change of the settings, and every [refresh] (a hub restored from the other one keeps the registry
/// in its database, but a laptop's is memory). Android and Mac screens have no tokens: nothing is sent and
/// nothing is needed, the app stays alive by itself there.
class PushRegistrar extends ChangeNotifier {
  PushRegistrar(
    this.api,
    this.settings, {
    String? platform,
    this.refresh = const Duration(minutes: 15),
    DateTime Function()? clock,
  }) : platform = platform ?? _platform(),
       _clock = clock ?? DateTime.now;

  final PosApi api;
  final Settings settings;

  /// `ios`, `android` or `macos`, as the hub lists it.
  final String platform;
  final Duration refresh;
  final DateTime Function() _clock;

  final _tokens = <String, String>{}; // kind: token, as the device gave them
  final _registered = <String, _Registered>{}; // kind: what the hub has for it
  bool? _configured; // the hub has a key to push with, as of its last answer
  String? _lastError;
  DateTime? _lastOk;
  Timer? _timer;
  bool _started = false;
  Future<void>? _running;
  bool _again = false;

  /// Whether the hub said it has an Apple key; null before it answered.
  bool? get configured => _configured;

  /// What went wrong with the hub the last time; null when the last registration went through.
  String? get lastError => _lastError;

  /// The tokens the device gave, by kind (`voip`, `alert`).
  Map<String, String> get tokens => Map.unmodifiable(_tokens);

  /// Whether the hub holds a `voip` token for this screen's phone: a locked phone can be woken for a call.
  bool get wakesForCalls => _registered['voip'] != null && _lastError == null;

  /// Whether the hub holds an `alert` token for this screen: a locked screen hears of a desk-phone pick-up.
  bool get wakesForPops => _registered['alert'] != null && _lastError == null;

  /// One line for the settings screen on where this stands, or null when nothing applies (no tokens on this
  /// platform, no phone and no push expected).
  String? get line {
    if (platform != 'ios') return null;
    if (_tokens.isEmpty) return 'Waiting for the push token from iOS (a real device, signed with push on)';
    if (_lastError != null) return 'Push not registered with the hub: $_lastError';
    if (_registered.isEmpty) return 'Registering the push token with the hub…';
    final key = switch (_configured) {
      true => '',
      false => ' · the hub has no Apple key yet (Location, Keys and connections)',
      null => '',
    };
    final what = [
      if (wakesForCalls) 'calls to ${_registered['voip']!.extension}',
      if (wakesForPops) 'desk-phone pick-ups',
    ].join(' and ');
    return what.isEmpty ? 'The hub holds no token for this screen$key' : 'Woken when locked for $what$key';
  }

  /// Starts following the settings and the clock; tokens come in through [token].
  void start() {
    if (_started) return;
    _started = true;
    settings.addListener(_onSettings);
    _timer = Timer.periodic(refresh, (_) => unawaited(sync()));
    unawaited(sync());
  }

  void stop() {
    if (!_started) return;
    _started = false;
    settings.removeListener(_onSettings);
    _timer?.cancel();
    _timer = null;
  }

  /// A token from the device: kept, and sent to the hub; an empty one is a revoked token, taken off the hub.
  void token(String kind, String token) {
    final clean = token.trim().toLowerCase();
    if (clean.isEmpty) {
      _tokens.remove(kind);
    } else if (_tokens[kind] == clean) {
      return;
    } else {
      _tokens[kind] = clean;
    }
    notifyListeners();
    unawaited(sync());
  }

  void _onSettings() => unawaited(sync());

  /// What the hub should hold for each kind right now: the `voip` token only while the phone is on here,
  /// with its extension; the `alert` token always.
  Map<String, _Registered> get _wanted {
    final phone = settings.phone;
    return {
      for (final e in _tokens.entries)
        if (e.key != 'voip' || phone.active)
          e.key: _Registered(e.value, settings.device, e.key == 'voip' ? phone.extension : ''),
    };
  }

  /// Brings the hub's registry in line with what the device gave and the settings say. One at a time; a
  /// change during one is taken up right after, before the returned future completes.
  Future<void> sync() {
    if (!settings.isConfigured) return Future.value();
    final running = _running;
    if (running != null) {
      _again = true;
      return running;
    }
    return _running = _syncAll().whenComplete(() => _running = null);
  }

  Future<void> _syncAll() async {
    do {
      _again = false;
      await _syncOnce();
    } while (_again);
  }

  Future<void> _syncOnce() async {
    final wanted = _wanted;
    String? error;
    for (final kind in _registered.keys.toList()) {
      final had = _registered[kind]!;
      final want = wanted[kind];
      if (want != null && want.token == had.token) continue;
      try {
        await api.unregisterPush(had.token);
        _registered.remove(kind);
      } on ApiException catch (err) {
        error = '$err';
      }
    }
    for (final e in wanted.entries) {
      try {
        final answer = await api.registerPush(
          device: e.value.device,
          platform: platform,
          kind: e.key,
          token: e.value.token,
          extension: e.value.extension,
        );
        _registered[e.key] = e.value;
        _configured = answer['configured'] as bool?;
      } on ApiException catch (err) {
        error = '$err';
      }
    }
    _lastError = error;
    if (error == null) _lastOk = _clock();
    notifyListeners();
  }

  /// When the hub last took a registration.
  DateTime? get lastOk => _lastOk;

  static String _platform() {
    if (kIsWeb) return 'web';
    if (Platform.isIOS) return 'ios';
    if (Platform.isAndroid) return 'android';
    if (Platform.isMacOS) return 'macos';
    return Platform.operatingSystem;
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}

@immutable
class _Registered {
  const _Registered(this.token, this.device, this.extension);
  final String token;
  final String device;
  final String extension;

  @override
  bool operator ==(Object other) =>
      other is _Registered && other.token == token && other.device == device && other.extension == extension;

  @override
  int get hashCode => Object.hash(token, device, extension);
}
