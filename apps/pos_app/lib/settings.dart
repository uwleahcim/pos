import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'phone.dart';

/// What this device remembers: its name, where the backend is and, when it is a phone, its PBX extension.
/// Nothing else lives on a terminal.
class Settings extends ChangeNotifier {
  Settings({
    required this.device,
    required List<String> endpoints,
    this.printRelay = false,
    this.billPrinter = '',
    int lockMinutes = 0,
    this.signOutAfterSend = false,
    this._phone = const PhoneSettings(),
    this._prefs,
  }) : _endpoints = List.of(endpoints),
       lockMinutes = cleanLockMinutes(lockMinutes);

  static Future<Settings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final device = prefs.getString('device') ?? '';
    final endpoints = prefs.getStringList('endpoints') ?? const [];
    final relay = prefs.getBool('print_relay') ?? false;
    final phone = PhoneSettings(
      enabled: prefs.getBool('phone_enabled') ?? false,
      server: prefs.getString('phone_server') ?? '',
      port: prefs.getInt('phone_port') ?? 8089,
      extension: prefs.getString('phone_extension') ?? '',
      secret: prefs.getString('phone_secret') ?? '',
    );
    return Settings(
      device: device,
      endpoints: endpoints,
      printRelay: relay,
      billPrinter: prefs.getString('bill_printer') ?? '',
      lockMinutes: prefs.getInt('lock_minutes') ?? 0,
      signOutAfterSend: prefs.getBool('sign_out_after_send') ?? false,
      phone: phone,
      prefs: prefs,
    );
  }

  final SharedPreferences? _prefs;

  /// Node id for clock stamps and op ids: letters and digits only, no dashes (the stamp uses them).
  String device;
  List<String> _endpoints;

  /// Print relay: this terminal writes queued print jobs to the printers when the hub cannot.
  bool printRelay;

  /// The printer this screen's bills come out of, by its id on the hub: the one beside it (the bar's own, the
  /// host stand's). Empty for wherever the location's bills print.
  String billPrinter;

  /// The minutes this screen may go untouched before it locks itself and asks who is there (a PIN, a face,
  /// a tag); 0 for never, which is how a device starts. What was open stays as it was, under the lock.
  int lockMinutes;

  /// The minutes offered, from the shortest; a screen can also never lock (0).
  static const lockChoices = [1, 2, 3, 5, 10, 15, 30];

  /// A number of minutes as the device keeps it: none below zero, none past a working day.
  static int cleanLockMinutes(int minutes) => minutes.clamp(0, 720);

  /// Back to sign-in after sending: on a screen several people share, leaving a check that dishes were
  /// just sent from signs the person out, so the next one signs in. Off is how a device starts: leaving a
  /// check goes back to the tables, still signed in.
  bool signOutAfterSend;

  PhoneSettings _phone;

  /// The phone: FreePBX address, extension and secret, with this device's name as the name the PBX shows.
  PhoneSettings get phone => _phone.copyWith(displayName: device);

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

  Future<void> saveBillPrinter(String? id) async {
    billPrinter = id ?? '';
    if (billPrinter.isEmpty) {
      await _prefs?.remove('bill_printer');
    } else {
      await _prefs?.setString('bill_printer', billPrinter);
    }
    notifyListeners();
  }

  Future<void> saveLockMinutes(int minutes) async {
    lockMinutes = cleanLockMinutes(minutes);
    if (lockMinutes == 0) {
      await _prefs?.remove('lock_minutes');
    } else {
      await _prefs?.setInt('lock_minutes', lockMinutes);
    }
    notifyListeners();
  }

  Future<void> saveSignOutAfterSend(bool on) async {
    signOutAfterSend = on;
    if (on) {
      await _prefs?.setBool('sign_out_after_send', true);
    } else {
      await _prefs?.remove('sign_out_after_send');
    }
    notifyListeners();
  }

  Future<void> savePhone(PhoneSettings phone) async {
    _phone = phone;
    await _prefs?.setBool('phone_enabled', phone.enabled);
    await _prefs?.setString('phone_server', phone.server);
    await _prefs?.setInt('phone_port', phone.port);
    await _prefs?.setString('phone_extension', phone.extension);
    await _prefs?.setString('phone_secret', phone.secret);
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
