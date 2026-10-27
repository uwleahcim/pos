import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What this device remembers: its name and where the backend is. Nothing else lives on a terminal.
class Settings extends ChangeNotifier {
  Settings({required this.device, required List<String> endpoints, this.printRelay = false, this._prefs})
    : _endpoints = List.of(endpoints);

  static Future<Settings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final device = prefs.getString('device') ?? '';
    final endpoints = prefs.getStringList('endpoints') ?? const [];
    final relay = prefs.getBool('print_relay') ?? false;
    return Settings(device: device, endpoints: endpoints, printRelay: relay, prefs: prefs);
  }

  final SharedPreferences? _prefs;

  /// Node id for clock stamps and op ids: letters and digits only, no dashes (the stamp uses them).
  String device;
  List<String> _endpoints;

  /// Print relay: this terminal writes queued print jobs to the printers when the hub cannot.
  bool printRelay;

  /// Backend addresses in failover order: hub, standby hub, cloud.
  List<String> get endpoints => List.unmodifiable(_endpoints);

  bool get isConfigured => device.isNotEmpty && _endpoints.isNotEmpty;

  Future<void> save({required String device, required List<String> endpoints, bool? printRelay}) async {
    this.device = normalizeDevice(device);
    _endpoints = endpoints.map((e) => e.trim()).where((e) => e.isNotEmpty).map(_normalizeUrl).toList();
    this.printRelay = printRelay ?? this.printRelay;
    await _prefs?.setString('device', this.device);
    await _prefs?.setStringList('endpoints', _endpoints);
    await _prefs?.setBool('print_relay', this.printRelay);
    notifyListeners();
  }

  static String normalizeDevice(String raw) {
    final cleaned = raw.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
    return cleaned.isEmpty ? 'dev${Random().nextInt(9000) + 1000}' : cleaned;
  }

  static String _normalizeUrl(String raw) {
    var url = raw;
    if (!url.startsWith('http://') && !url.startsWith('https://')) url = 'http://$url';
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }
}
