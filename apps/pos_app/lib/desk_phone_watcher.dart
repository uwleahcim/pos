import 'dart:async';

import 'package:flutter/foundation.dart';

import 'api.dart';
import 'desk_phone.dart';
import 'settings.dart';

/// Watches the hub for calls answered on the desk phones linked to this device, for as long as the app runs.
/// One request waits at the hub at all times: the hub answers it the moment one of the device's phones picks
/// up (or after [holdFor] with nothing new) and the next request follows at once, so a pick-up reaches the
/// screen within a fraction of a second instead of on the next poll. Each answer carries the hub's cursor,
/// which the next request brings back so the hub knows what the screen has. A hub from before held requests
/// answers at once and is asked again a second later, never in a tight loop; so is a hub that does not answer
/// (the status icon already says so). Each call is reported once, by the id the hub gives it; the newest one
/// not yet handled waits for the orders screen to [take] it, which it does on each change of [calls] and when
/// it comes up (someone signing in just after the phone was picked up), as long as the call is fresh.
class DeskPhoneWatcher extends ChangeNotifier {
  DeskPhoneWatcher(this.api, this.settings, {DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final PosApi api;
  final Settings settings;
  final DateTime Function() _clock;

  /// How long the hub may hold a request with nothing new: short enough that a hub which dies mid-request is
  /// given up on soon (the request times out a few seconds after), long enough that waiting costs nothing.
  static const holdFor = Duration(seconds: 15);

  /// The least time between two requests, for when the hub answers at once: an older hub, nothing answering,
  /// a device not set up yet.
  static const atLeastEvery = Duration(seconds: 1);

  /// How long after the phone was picked up its call still opens something: later it is stale (the call is
  /// over, or was handled without the screen).
  static const freshFor = Duration(seconds: 45);

  bool _running = false;
  bool _disposed = false;
  Completer<void>? _sleeping;
  Timer? _alarm;
  int _inFlight = 0;
  bool _linked = false;
  int _cursor = 0;
  final _seen = <String>{};
  final _seenInOrder = <String>[];
  DeskPhoneCall? _pending;
  int _calls = 0;

  /// Whether the hub links any desk phone to this device; listeners hear when it changes.
  bool get linked => _linked;

  /// How many calls have been seen; the orders screen takes the newest on each change.
  int get calls => _calls;

  /// The newest call not yet taken, fresh or not.
  DeskPhoneCall? get pending => _pending;

  /// Keeps a request waiting at the hub from now on; nothing is asked until the device is set up.
  void start() {
    if (_running) return;
    _running = true;
    unawaited(_run());
  }

  /// Stops asking; a request already waiting at the hub is left to come back on its own.
  void stop() {
    _running = false;
    _alarm?.cancel();
    _alarm = null;
    final sleeping = _sleeping;
    if (sleeping != null && !sleeping.isCompleted) sleeping.complete();
  }

  /// The app is back (brought up by a tap on a pick-up's notification, or in front again after a sleep): the
  /// hub is asked now, beside a request that may still be held there over a dead connection.
  void wakeUp() {
    if (!_running || !settings.isConfigured) return;
    final sleeping = _sleeping;
    if (sleeping != null && !sleeping.isCompleted) sleeping.complete();
    unawaited(poll(again: true));
  }

  /// The call waiting for a screen, if it is still fresh; taken once.
  DeskPhoneCall? take() {
    final call = _pending;
    _pending = null;
    if (call == null || _clock().difference(call.answeredAt) > freshFor) return null;
    return call;
  }

  Future<void> _run() async {
    while (_running) {
      final started = _clock();
      if (settings.isConfigured) await poll(hold: holdFor);
      final spent = _clock().difference(started);
      if (_running && spent < atLeastEvery) await _sleep(atLeastEvery - spent);
    }
  }

  Future<void> _sleep(Duration length) {
    final sleeping = _sleeping = Completer<void>();
    _alarm = Timer(length, () {
      if (!sleeping.isCompleted) sleeping.complete();
    });
    return sleeping.future;
  }

  /// Asks the hub once for this device's calls, from the cursor of its last answer; with [hold], the hub
  /// keeps the request until there is a newer call (or that long). One request at a time, unless [again]:
  /// a second one beside a request that may be lost (the connection died while the hub held it).
  Future<void> poll({Duration hold = Duration.zero, bool again = false}) async {
    if (_inFlight > 0 && !again) return;
    _inFlight++;
    try {
      final answered = await api.answeredCalls(device: settings.device, after: _cursor, hold: hold, clock: _clock);
      var changed = answered.linked != _linked;
      _linked = answered.linked;
      _cursor = answered.cursor;
      for (final call in answered.calls) {
        if (!_seen.add(call.id)) continue;
        _remember(call.id);
        _pending = call;
        _calls++;
        changed = true;
      }
      if (changed && !_disposed) notifyListeners();
    } on ApiException {
      // nothing answers, or the hub refused: the status icon shows the outage; the next request asks again
    } finally {
      _inFlight--;
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
    _disposed = true;
    stop();
    super.dispose();
  }
}
