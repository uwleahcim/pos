import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'camera.dart';
import 'session.dart';
import 'settings.dart';

/// The photo taken with each major action: captured at once, sent when a backend answers.
///
/// Kept on disk like the outbox, capped so a long outage cannot fill the device. A photo that never gets
/// taken (no camera, permission refused) is simply absent; the action itself is never blocked by it.
class PhotoQueue extends ChangeNotifier {
  PhotoQueue(this.api, this.settings, this.camera, this.session, {this._prefs, this.keep = 50});

  static const _key = 'photos';

  final PosApi api;
  final Settings settings;
  final EventCamera camera;
  final Session session;
  final SharedPreferences? _prefs;
  final int keep;
  final List<Map<String, dynamic>> _pending = [];
  Future<void>? _inflight;
  Timer? _retry;
  int taken = 0;

  int get pending => _pending.length;

  Future<void> restore() async {
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    _pending.addAll((prefs.getStringList(_key) ?? const []).map((s) => jsonDecode(s) as Map<String, dynamic>));
    if (_pending.isNotEmpty) unawaited(flush());
  }

  /// Snap the operator and queue the picture against `opId`. Never throws, never waits on the network.
  Future<void> capture(String event, {String? opId}) async {
    final bytes = await camera.snap();
    if (bytes == null) return;
    taken += 1;
    _pending.add({
      'photo_id': '${settings.device}${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}',
      'device': settings.device,
      'event': event,
      'op_id': opId,
      'staff_id': session.staff?.staffId,
      'taken_at': DateTime.now().millisecondsSinceEpoch / 1000,
      'jpeg_b64': base64Encode(bytes),
    });
    while (_pending.length > keep) {
      _pending.removeAt(0);
    }
    await _persist();
    notifyListeners();
    unawaited(flush());
  }

  Future<void> flush() => _inflight ??= _flush().whenComplete(() => _inflight = null);

  Future<void> _flush() async {
    _retry?.cancel();
    while (_pending.isNotEmpty) {
      final photo = _pending.first;
      try {
        await api.putPhoto(photo);
      } on ApiException catch (err) {
        if (err.status == null || err.status! >= 500) {
          _retry = Timer(const Duration(seconds: 5), flush);
          return;
        }
        // Refused (too large, not a JPEG): drop it, nothing to retry.
      }
      _pending.removeAt(0);
      await _persist();
      notifyListeners();
    }
  }

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
