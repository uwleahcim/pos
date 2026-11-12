import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What this device keeps from its last reads so it can still take orders when no backend answers (ADR 6,
/// capture-only mode): the menu, every dish's sizes and choices, the floor plan and the tax rates, each
/// with the time it was read. The backend stays the authority: a saved answer is used only when nothing
/// answers, and the status details show its age.
///
/// Each answer is a file of its own in a folder of the app's, with an index of what is saved and when. The
/// menu alone is a couple of hundred kilobytes and every dish's choices together over ten megabytes: far too
/// much for the preference store, which keeps everything in one plist or XML file and rewrites it whole on
/// every write (and did, once per dish, every time an order opened, before 2026-11-12). The dishes of a
/// menu revision are saved together ([saveItems]), and the revision is kept, so they are read from a backend
/// once per revision per device, not once per screen.
class ReadCache {
  ReadCache._(this.folder, this._now);

  /// The app's own cache, in its support folder.
  static Future<ReadCache> load() async =>
      open(Directory('${(await getApplicationSupportDirectory()).path}/read_cache'));

  /// The cache in [folder], made if it is not there. The index is read now, the answers on demand; the
  /// tax rates, which a check needs the moment it is drawn, are read now too ([peek]).
  static Future<ReadCache> open(Directory folder, {DateTime Function()? now}) async {
    final cache = ReadCache._(folder, now ?? DateTime.now);
    await cache._open();
    return cache;
  }

  /// The answers a screen needs without waiting on a file: kept in memory as well, for [peek].
  static const inMemory = {'taxes'};

  static const _indexName = 'index.json';

  final Directory folder;
  final DateTime Function() _now;
  final Map<String, DateTime> _at = {}; // what is saved, and when
  final Map<String, int> _itemsRevision = {}; // channel:locale -> the menu revision whose dishes are all saved
  final Map<String, String> _memory = {}; // the in-memory answers, as their JSON text
  Future<void> _writes = Future.value(); // index writes, one after another
  DateTime _indexAt = DateTime.fromMillisecondsSinceEpoch(0); // when the index was last written

  Future<void> _open() async {
    await folder.create(recursive: true);
    try {
      final index = jsonDecode(await _file(_indexName).readAsString()) as Map<String, dynamic>;
      for (final MapEntry(key: name, value: at) in (index['saved'] as Map<String, dynamic>? ?? const {}).entries) {
        _at[name] = DateTime.fromMillisecondsSinceEpoch(at as int);
      }
      for (final MapEntry(key: menu, value: revision)
          in (index['items_revision'] as Map<String, dynamic>? ?? const {}).entries) {
        _itemsRevision[menu] = revision as int;
      }
    } on FileSystemException {
      // nothing saved yet
    } on FormatException {
      // a write that did not finish: this device starts over, as it would with nothing saved
    }
    for (final name in inMemory) {
      if (!_at.containsKey(name)) continue;
      final text = await _read(name);
      if (text != null) _memory[name] = text;
    }
  }

  /// The saved answer under `name`, or null when there is none (or the file did not get written whole).
  Future<Map<String, dynamic>?> get(String name) async {
    if (!_at.containsKey(name)) return null;
    final text = _memory[name] ?? await _read(name);
    if (text == null) return null;
    try {
      return jsonDecode(text) as Map<String, dynamic>;
    } on FormatException {
      await _forget(name);
      return null;
    }
  }

  /// A saved answer kept in memory ([inMemory]), without waiting: the tax rates while a check is drawn.
  Map<String, dynamic>? peek(String name) {
    final text = _memory[name];
    return text == null ? null : jsonDecode(text) as Map<String, dynamic>;
  }

  bool has(String name) => _at.containsKey(name);

  /// When `name` was last saved.
  DateTime? readAt(String name) => _at[name];

  /// The names saved under a prefix, e.g. every size of one dish.
  Iterable<String> names(String prefix) => _at.keys.where((k) => k.startsWith(prefix));

  /// Saves an answer. One kept in memory that has not changed is not written again (the tax rates come with
  /// every check read, every two seconds while an order is open), so [readAt] says when the answer last changed.
  Future<void> put(String name, Map<String, dynamic> json) async {
    final text = jsonEncode(json);
    if (inMemory.contains(name)) {
      if (_memory[name] == text) return;
      _memory[name] = text;
    }
    await _write(fileName(name), text);
    _at[name] = _now();
    await _saveIndex();
  }

  /// Saves an answer as the JSON text it came as from a backend, so the menu (a couple of hundred kilobytes)
  /// is not encoded again on the UI thread just to be written. The text must be a JSON object: [get] decodes
  /// it. For the answers kept in memory use [put].
  Future<void> putText(String name, String text) async {
    assert(!inMemory.contains(name), 'put() keeps $name in memory');
    await _write(fileName(name), text);
    _at[name] = _now();
    await _saveIndex();
  }

  /// How long the index may run behind the times in memory: see [touch].
  static const indexEvery = Duration(minutes: 5);

  /// A backend just said the saved answer under `name` is still the one it would give: it counts as read
  /// now ([readAt], the age the status details show). The floor is confirmed every two seconds while its
  /// screen is up, so the time is kept in memory and the index written at most every [indexEvery]: a device
  /// that loses power may think its copies up to that much older than they are.
  Future<void> touch(String name) async {
    if (!_at.containsKey(name)) return;
    final now = _now();
    _at[name] = now;
    if (now.difference(_indexAt).abs() >= indexEvery) await _saveIndex();
  }

  /// Every dish of a menu at `revision`, already as JSON text (encoded off the UI thread), under the names
  /// [PosApi] reads them back by. Dishes saved for that menu and language before, and no longer on it, go.
  Future<void> saveItems(
    Map<String, String> encoded, {
    required int revision,
    String channel = 'pos',
    String locale = 'en',
  }) async {
    final stale = [
      for (final name in names('item:'))
        if (name.endsWith(':$locale') && !encoded.containsKey(name)) name,
    ];
    for (final MapEntry(key: name, value: text) in encoded.entries) {
      await _write(fileName(name), text);
    }
    final when = _now();
    for (final name in encoded.keys) {
      _at[name] = when;
    }
    for (final name in stale) {
      _at.remove(name);
      await _delete(name);
    }
    _itemsRevision['$channel:$locale'] = revision;
    await _saveIndex();
  }

  /// The menu revision whose dishes are all saved for this channel and language, or null for none yet.
  int? itemsRevision({String channel = 'pos', String locale = 'en'}) => _itemsRevision['$channel:$locale'];

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

  /// Removes what builds before 2026-11-12 saved in the preference store (`read:…` and `read_at:…`), one
  /// key at a time with a [pause] between, so the store, which rewrites itself on every change, shrinks back
  /// to the settings and the outbox without holding up the screen. How many keys went.
  static Future<int> forgetLegacy(SharedPreferences prefs, {Duration pause = const Duration(milliseconds: 50)}) async {
    final legacy = prefs.getKeys().where((k) => k.startsWith('read:') || k.startsWith('read_at:')).toList();
    for (final key in legacy) {
      await prefs.remove(key);
      if (pause > Duration.zero) await Future<void>.delayed(pause);
    }
    return legacy.length;
  }

  // Files ------------------------------------------------------------------------------------------------

  File _file(String fileName) => File('${folder.path}/$fileName');

  /// The file an answer is kept in: its name with every character outside letters, digits, `_` and `-`
  /// written as `%XX`, so `menu:pos:en` and `item:J55|dinner/sushi:en` are plain file names in one folder.
  static String fileName(String name) {
    final out = StringBuffer();
    for (final unit in utf8.encode(name)) {
      final c = String.fromCharCode(unit);
      final plain = (unit >= 0x30 && unit <= 0x39) || (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A);
      if (plain || c == '_' || c == '-') {
        out.write(c);
      } else {
        out.write('%${unit.toRadixString(16).padLeft(2, '0').toUpperCase()}');
      }
    }
    return '$out.json';
  }

  Future<String?> _read(String name) async {
    try {
      return await _file(fileName(name)).readAsString();
    } on FileSystemException {
      await _forget(name);
      return null;
    }
  }

  /// Written beside the file it replaces, then moved over it, so a crash leaves the old answer or none.
  Future<void> _write(String fileName, String text) async {
    final file = _file(fileName);
    final partial = File('${file.path}.part');
    await partial.writeAsString(text);
    await partial.rename(file.path);
  }

  Future<void> _delete(String name) async {
    try {
      await _file(fileName(name)).delete();
    } on FileSystemException {
      // already gone
    }
  }

  /// An answer that is not there after all (its file gone, or not written whole) is dropped from the index.
  Future<void> _forget(String name) {
    _at.remove(name);
    _memory.remove(name);
    return _saveIndex();
  }

  Future<void> _saveIndex() {
    final text = jsonEncode({
      'saved': {for (final MapEntry(key: name, value: at) in _at.entries) name: at.millisecondsSinceEpoch},
      'items_revision': _itemsRevision,
    });
    _indexAt = _now();
    return _writes = _writes.then((_) => _write(_indexName, text));
  }
}
