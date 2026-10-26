import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'settings.dart';

/// A hybrid logical clock stamp, written the way the backend reads it: `wall_ms-counter-node`.
class Hlc {
  Hlc({required String node, int Function()? now}) : this.lazy(node: () => node, now: now);

  /// The node is read on every stamp, so a device renamed in settings stamps with its new name at once.
  Hlc.lazy({required String Function() this._node, int Function()? now})
    : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final String Function() _node;
  String get node => _node();
  final int Function() _now;
  int _wall = 0;
  int _counter = 0;

  String next() {
    final now = _now();
    if (now > _wall) {
      _wall = now;
      _counter = 0;
    } else {
      _counter += 1;
    }
    return '${_wall.toString().padLeft(13, '0')}-${_counter.toString().padLeft(4, '0')}-$node';
  }
}

/// Operations this device has stamped but the backend has not yet accepted.
///
/// Each op is written to disk before it is sent and removed only when a backend accepts it, so a crash or an
/// outage never loses an operator's tap. Sending the same op twice is harmless: the backend ignores duplicates.
class Outbox extends ChangeNotifier {
  Outbox(this.api, this.settings, {this._prefs, Random? random, int Function()? now})
    : _random = random ?? Random(),
      _clock = Hlc.lazy(node: () => settings.device, now: now);

  static const _key = 'outbox';

  final PosApi api;
  final Settings settings;
  final SharedPreferences? _prefs;
  final Random _random;
  final Hlc _clock;
  final List<Map<String, dynamic>> _pending = [];
  Future<void>? _inflight;
  Timer? _retry;

  int get pending => _pending.length;
  List<Map<String, dynamic>> get pendingOps => List.unmodifiable(_pending);

  Future<void> restore() async {
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    final stored = prefs.getStringList(_key) ?? const [];
    _pending.addAll(stored.map((s) => jsonDecode(s) as Map<String, dynamic>));
    if (_pending.isNotEmpty) unawaited(flush());
  }

  String newId() {
    final rand = _random.nextInt(1 << 30).toRadixString(36);
    return '${settings.device}${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}$rand';
  }

  /// Stamps and queues one operation, then tries to send everything queued. Returns the op id.
  Future<String> add(String orderId, String kind, [Map<String, dynamic> data = const {}]) async {
    final op = {
      'op_id': newId(),
      'order_id': orderId,
      'hlc': _clock.next(),
      'device': settings.device,
      'kind': kind,
      'data': data,
    };
    _pending.add(op);
    await _persist();
    notifyListeners();
    unawaited(flush());
    return op['op_id'] as String;
  }

  /// Sends queued operations in order, one order at a time, stopping at the first failure to reach a backend.
  Future<void> flush() {
    return _inflight ??= _flush().whenComplete(() => _inflight = null);
  }

  Future<void> _flush() async {
    _retry?.cancel();
    while (_pending.isNotEmpty) {
      final orderId = _pending.first['order_id'] as String;
      final batch = _pending.takeWhile((op) => op['order_id'] == orderId).toList();
      try {
        await api.appendOps(orderId, batch);
      } on ApiException catch (err) {
        if (err.status != null && err.status! < 500) {
          // The backend read it and refused it; keeping it would block everything behind it.
          _pending.removeRange(0, batch.length);
          await _persist();
          notifyListeners();
          lastRefusal = err.message;
          continue;
        }
        _retry = Timer(const Duration(seconds: 3), flush);
        return;
      }
      _pending.removeRange(0, batch.length);
      await _persist();
      notifyListeners();
    }
  }

  String? lastRefusal;

  Future<void> _persist() async {
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    await prefs.setStringList(_key, _pending.map(jsonEncode).toList());
  }

  @override
  void dispose() {
    _retry?.cancel();
    super.dispose();
  }
}
