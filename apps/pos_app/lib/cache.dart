import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// What this device keeps from its last reads so it can still take orders when no backend answers (ADR 6,
/// capture-only mode): the menu, every dish's sizes and choices, the floor plan and the tax rates, each
/// with the time it was read. The backend stays the authority: a saved answer is used only when nothing
/// answers, and the status details show its age.
class ReadCache {
  ReadCache(this._prefs, {DateTime Function()? now}) : _now = now ?? DateTime.now {
    for (final key in _prefs.getKeys()) {
      if (!key.startsWith(_atPrefix)) continue;
      final at = _prefs.getInt(key);
      if (at != null) _at[key.substring(_atPrefix.length)] = DateTime.fromMillisecondsSinceEpoch(at);
    }
  }

  static Future<ReadCache> load() async => ReadCache(await SharedPreferences.getInstance());

  static const _prefix = 'read:';
  static const _atPrefix = 'read_at:';

  final SharedPreferences _prefs;
  final DateTime Function() _now;
  final Map<String, DateTime> _at = {}; // what is saved, and when

  /// The saved answer under `name`, or null when there is none.
  Map<String, dynamic>? get(String name) {
    final raw = _prefs.getString('$_prefix$name');
    return raw == null ? null : jsonDecode(raw) as Map<String, dynamic>;
  }

  bool has(String name) => _at.containsKey(name);

  /// When `name` was last saved.
  DateTime? readAt(String name) => _at[name];

  /// The names saved under a prefix, e.g. every size of one dish.
  Iterable<String> names(String prefix) => _at.keys.where((k) => k.startsWith(prefix));

  Future<void> put(String name, Map<String, dynamic> json) async {
    final when = _now();
    _at[name] = when;
    await _prefs.setString('$_prefix$name', jsonEncode(json));
    await _prefs.setInt('$_atPrefix$name', when.millisecondsSinceEpoch);
  }

  Future<void> putAll(Map<String, Map<String, dynamic>> entries) async {
    for (final MapEntry(key: name, value: json) in entries.entries) {
      await put(name, json);
    }
  }

  /// A menu is saved: this device can take orders against it while nothing answers.
  bool get hasMenu => names('menu:').isNotEmpty;

  /// When the menu was last read from a backend (the oldest of the saved menus, to be safe).
  DateTime? get menuAt {
    DateTime? oldest;
    for (final name in names('menu:')) {
      final at = _at[name]!;
      if (oldest == null || at.isBefore(oldest)) oldest = at;
    }
    return oldest;
  }
}
