import 'dart:async';

import 'package:flutter/foundation.dart';

import 'api.dart';
import 'desk_phone.dart';
import 'settings.dart';

/// Watches the hub for calls answered on the desk phones linked to this device, for as long as the app runs:
/// every second while a phone is linked, every ten seconds while none is (a manager's link takes effect
/// within that), through whichever backend answers. Each call is reported once, by the id the hub gives it;
/// the newest one not yet handled waits for the orders screen to [take] it, which it does on each change of
/// [calls] and when it comes up (someone signing in just after the phone was picked up), as long as the
/// call is fresh. A hub that does not answer is simply asked again later: the status icon already says so.
class DeskPhoneWatcher extends ChangeNotifier {
  DeskPhoneWatcher(this.api, this.settings, {DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final PosApi api;
  final Settings settings;
  final DateTime Function() _clock;

  /// How often the hub is asked, with a phone linked to this device and without.
  static const linkedEvery = Duration(seconds: 1);
  static const unlinkedEvery = Duration(seconds: 10);

  /// How long after the phone was picked up its call still opens something: later it is stale (the call is
  /// over, or was handled without the screen).
  static const freshFor = Duration(seconds: 45);

  Timer? _timer;
  bool _polling = false;
  DateTime? _lastPoll;
  bool _linked = false;
  final _seen = <String>{};
  final _seenInOrder = <String>[];
  DeskPhoneCall? _pending;
  int _calls = 0;

  /// Whether the hub links any desk phone to this device.
  bool get linked => _linked;

  /// How many calls have been seen; the orders screen takes the newest on each change.
  int get calls => _calls;

  /// The newest call not yet taken, fresh or not.
  DeskPhoneCall? get pending => _pending;

  /// Starts asking the hub; nothing happens until the device is set up.
  void start() {
    _timer ??= Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    _tick();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// The call waiting for a screen, if it is still fresh; taken once.
  DeskPhoneCall? take() {
    final call = _pending;
    _pending = null;
    if (call == null || _clock().difference(call.answeredAt) > freshFor) return null;
    return call;
  }

  void _tick() {
    if (!settings.isConfigured || _polling) return;
    final last = _lastPoll;
    final every = _linked ? linkedEvery : unlinkedEvery;
    if (last == null || _clock().difference(last) >= every) unawaited(poll());
  }

  /// Asks the hub once for this device's calls.
  Future<void> poll() async {
    if (_polling) return;
    _polling = true;
    _lastPoll = _clock();
    try {
      final answered = await api.answeredCalls(device: settings.device, clock: _clock);
      _linked = answered.linked;
      var changed = false;
      for (final call in answered.calls) {
        if (!_seen.add(call.id)) continue;
        _remember(call.id);
        _pending = call;
        _calls++;
        changed = true;
      }
      if (changed) notifyListeners();
    } on ApiException {
      // nothing answers, or the hub refused: the status icon shows the outage; the next tick asks again
    } finally {
      _polling = false;
    }
  }

  /// The ids seen, bounded: the hub lists a call for two minutes, so a few hundred is plenty.
  void _remember(String id) {
    _seenInOrder.add(id);
    while (_seenInOrder.length > 500) {
      _seen.remove(_seenInOrder.removeAt(0));
    }
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}
