import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'queue_store.dart';
import 'settings.dart';

/// A hybrid logical clock stamp, written the way the backend reads it: `wall_ms-counter-node`.
class Hlc {
  Hlc({required String node, int Function()? now}) : this.lazy(node: () => node, now: now);

  /// The node is read on every stamp, so a device renamed in settings stamps with its new name at once.
  Hlc.lazy({required this._node, int Function()? now}) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

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
///
/// The disk is [store]: on a device a [JournalStore], where a tap costs the same whether three operations
/// are waiting or three thousand (a service taken with no backend at all, ADR 6).
class Outbox extends ChangeNotifier {
  Outbox(this.api, this.settings, {required this.store, Random? random, int Function()? now})
    : _random = random ?? Random(),
      _clock = Hlc.lazy(node: () => settings.device, now: now);

  /// Where builds before 2026-11-12 kept the queue in the preference store, and what names an operation.
  static const legacyKey = 'outbox';
  static const idField = 'op_id';

  final PosApi api;
  final Settings settings;
  final QueueStore store;
  final Random _random;
  final Hlc _clock;
  final List<Map<String, dynamic>> _pending = [];
  final List<(int, Map<String, dynamic>)> _accepted = []; // (acceptance number, op) until a read shows it
  int _acceptances = 0;
  Future<void>? _inflight;
  Timer? _retry;

  int get pending => _pending.length;
  List<Map<String, dynamic>> get pendingOps => List.unmodifiable(_pending);

  /// Takes up the queue as the last run left it. With [legacy], the preference store, a queue a build before
  /// 2026-11-12 left there is taken over first and removed from it.
  Future<void> restore({SharedPreferences? legacy}) async {
    _pending.addAll(await restoreQueue(store, legacy: legacy, key: legacyKey, id: idField));
    if (_pending.isNotEmpty) unawaited(flush());
  }

  String newId() {
    final rand = _random.nextInt(1 << 30).toRadixString(36);
    return '${settings.device}${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}$rand';
  }

  /// Stamps and queues one operation, then tries to send everything queued. Returns the op id.
  Future<String> add(String orderId, String kind, [Map<String, dynamic> data = const {}]) async =>
      (await addAll(orderId, [(kind, data)])).single;

  /// Stamps and queues several operations that belong together (a change: void, add, fire), so they reach
  /// the backend in one batch and the kitchen gets one ticket. Returns the op ids.
  Future<List<String>> addAll(String orderId, List<(String, Map<String, dynamic>)> ops) async {
    final added = <Map<String, dynamic>>[];
    // Taken while no backend answered (ADR 6): the backend heads the kitchen ticket "late" and the day's
    // report lists it.
    final offline = api.connection.value.capturing;
    for (final (kind, data) in ops) {
      added.add({
        'op_id': newId(),
        'order_id': orderId,
        'hlc': _clock.next(),
        'device': settings.device,
        'kind': kind,
        'data': offline ? {...data, 'offline': true} : data,
      });
    }
    final ids = [for (final op in added) op['op_id'] as String];
    _pending.addAll(added);
    await store.add(added);
    notifyListeners();
    unawaited(flush());
    return ids;
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
        final result = await api.appendOps(orderId, batch);
        if (result.refused.isNotEmpty) lastRefusal = result.refused.values.first;
        _acceptances++;
        for (final op in batch) {
          if (!result.refused.containsKey(op['op_id'])) _accepted.add((_acceptances, op));
        }
      } on ApiException catch (err) {
        if (err.status != null && err.status! < 500) {
          // The backend read it and refused it; keeping it would block everything behind it.
          _pending.removeRange(0, batch.length);
          await store.remove(batch, empty: _pending.isEmpty);
          notifyListeners();
          lastRefusal = err.message;
          continue;
        }
        _retry = Timer(const Duration(seconds: 3), flush);
        return;
      }
      _pending.removeRange(0, batch.length);
      await store.remove(batch, empty: _pending.isEmpty);
      notifyListeners();
    }
  }

  /// This device's operations on one order that a read from the backend may not show yet: everything still
  /// queued, and what was accepted after the last read began. A screen lays them over what it read.
  List<Map<String, dynamic>> localOps(String orderId) => [
    for (final (_, op) in _accepted)
      if (op['order_id'] == orderId) op,
    for (final op in _pending)
      if (op['order_id'] == orderId) op,
  ];

  /// Call before reading an order; pass the result to [seen] once the read is back.
  int get readMark => _acceptances;

  /// A read that began at [mark] shows every operation accepted before it, so those stop being local.
  /// Whether any did: the screen then shows the order without them laid on top, so it has to redraw.
  bool seen(String orderId, int mark) {
    final before = _accepted.length;
    _accepted.removeWhere((entry) => entry.$1 <= mark && entry.$2['order_id'] == orderId);
    return _accepted.length != before;
  }

  /// Why the backend last refused an operation, until the operator dismisses it.
  String? lastRefusal;

  void clearRefusal() {
    lastRefusal = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _retry?.cancel();
    super.dispose();
  }
}
