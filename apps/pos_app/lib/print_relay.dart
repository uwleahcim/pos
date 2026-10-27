import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'api.dart';
import 'settings.dart';

/// Writes a print job's bytes to a printer on the LAN. Replaceable in tests.
typedef RawSender = Future<void> Function(String address, Uint8List data);

/// Open the raw port, send, half-close, drain the printer's status bytes, close: a reset would lose the job.
Future<void> sendRaw(String address, Uint8List data, {Duration timeout = const Duration(seconds: 4)}) async {
  final parts = address.split(':');
  final host = parts.first;
  final port = parts.length > 1 ? int.parse(parts[1]) : 9100;
  final socket = await Socket.connect(host, port, timeout: timeout);
  try {
    socket.add(data);
    await socket.flush();
    await socket.close(); // our side is done writing; the printer may still answer
    await socket.drain<void>().timeout(const Duration(seconds: 2), onTimeout: () {});
  } finally {
    socket.destroy();
  }
}

/// The relay path: when the backend cannot reach a printer itself (the cloud never can, a hub when the
/// printer's path is down), this terminal claims queued jobs for the printers it knows and prints them.
///
/// It polls while enabled; a job that fails goes back to the queue at once for another relay.
class PrintRelay extends ChangeNotifier {
  PrintRelay(this.api, this.settings, {RawSender? send, this.interval = const Duration(seconds: 2)})
    : _send = send ?? sendRaw;

  final PosApi api;
  final Settings settings;
  final RawSender _send;
  final Duration interval;

  Timer? _timer;
  bool _busy = false;
  List<String> _printers = const [];
  DateTime _printersAt = DateTime.fromMillisecondsSinceEpoch(0);

  int printed = 0;
  int failed = 0;
  String? lastError;
  bool get running => _timer != null;

  /// Follow the setting: start polling when relay mode is on, stop when it is off.
  void bind() {
    settings.addListener(_sync);
    _sync();
  }

  void _sync() {
    if (settings.printRelay && _timer == null) {
      _timer = Timer.periodic(interval, (_) => unawaited(poll()));
      notifyListeners();
    } else if (!settings.printRelay && _timer != null) {
      _timer!.cancel();
      _timer = null;
      notifyListeners();
    }
  }

  /// One round: refresh the printer list now and then, claim one job, print it, report. Never throws.
  Future<bool> poll() async {
    if (_busy) return false;
    _busy = true;
    try {
      if (DateTime.now().difference(_printersAt) > const Duration(minutes: 1)) {
        _printers = (await api.printers()).map((p) => p['address'] as String).toList();
        _printersAt = DateTime.now();
      }
      if (_printers.isEmpty) return false;
      final job = await api.claimPrintJob(relay: settings.device, printers: _printers);
      if (job == null) return false;
      final jobId = job['job_id'] as String;
      try {
        await _send(job['printer'] as String, base64Decode(job['data_b64'] as String));
      } catch (err) {
        failed += 1;
        lastError = '$err';
        await api.printJobFailed(jobId, by: settings.device, error: '$err');
        notifyListeners();
        return false;
      }
      await api.printJobDone(jobId, by: settings.device);
      printed += 1;
      lastError = null;
      notifyListeners();
      return true;
    } catch (err) {
      lastError = '$err';
      notifyListeners();
      return false;
    } finally {
      _busy = false;
    }
  }

  @override
  void dispose() {
    settings.removeListener(_sync);
    _timer?.cancel();
    super.dispose();
  }
}
