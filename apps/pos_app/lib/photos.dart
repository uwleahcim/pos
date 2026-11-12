import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'camera.dart';
import 'queue_store.dart';
import 'session.dart';
import 'settings.dart';

/// The photo taken with each major action: captured at once, sent when a backend answers.
///
/// Kept on disk like the outbox, capped so a long outage cannot fill the device. A photo that never gets
/// taken (no camera, permission refused) is simply absent; the action itself is never blocked by it.
///
/// The disk is [store]: on a device a [FolderStore], a file per photo. In the preference store, where builds
/// before 2026-11-12 kept them, every photo taken or sent rewrote all the waiting ones (megabytes in an
/// outage), and so did every tap that touched the outbox beside them.
class PhotoQueue extends ChangeNotifier {
  PhotoQueue(this.api, this.settings, this.camera, this.session, {required this.store, this.keep = 50});

  /// Where builds before 2026-11-12 kept the queue in the preference store, and what names a photo.
  static const legacyKey = 'photos';
  static const idField = 'photo_id';

  final PosApi api;
  final Settings settings;
  final EventCamera camera;
  final Session session;
  final QueueStore store;
  final int keep;
  final List<Map<String, dynamic>> _pending = [];
  Future<void>? _inflight;
  Timer? _retry;
  int taken = 0;

  int get pending => _pending.length;

  /// Takes up the queue as the last run left it. With [legacy], the preference store, photos a build before
  /// 2026-11-12 left there are taken over first and removed from it.
  Future<void> restore({SharedPreferences? legacy}) async {
    _pending.addAll(await restoreQueue(store, legacy: legacy, key: legacyKey, id: idField));
    if (_pending.isNotEmpty) unawaited(flush());
  }

  /// Snap the operator and queue the picture against `opId`. Never throws, never waits on the network.
  Future<void> capture(String event, {String? opId}) async {
    final bytes = await camera.snap();
    if (bytes == null) return;
    taken += 1;
    final photo = <String, dynamic>{
      'photo_id': '${settings.device}${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}',
      'device': settings.device,
      'event': event,
      'op_id': opId,
      'staff_id': session.staff?.staffId,
      'taken_at': DateTime.now().millisecondsSinceEpoch / 1000,
      'jpeg_b64': base64Encode(bytes),
    };
    _pending.add(photo);
    final pushedOut = <Map<String, dynamic>>[];
    while (_pending.length > keep) {
      pushedOut.add(_pending.removeAt(0));
    }
    await store.add([photo]);
    if (pushedOut.isNotEmpty) await store.remove(pushedOut, empty: false);
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
      // By what it is, not where it was: a photo taken meanwhile may have pushed this one out already.
      _pending.remove(photo);
      await store.remove([photo], empty: _pending.isEmpty);
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _retry?.cancel();
    super.dispose();
  }
}
