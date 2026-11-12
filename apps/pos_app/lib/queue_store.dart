import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

/// Where a queue (the outbox, the audit photos) keeps what it holds between runs of the app.
///
/// Both queues send from the front and add at the back, and both must cost the same per tap however long
/// they are: a terminal that takes orders through a whole service with no backend (ADR 6) queues a couple of
/// thousand operations. Builds before 2026-11-12 kept each queue as one list in the preference store, which
/// encoded and rewrote the whole list on every tap: 13 ms of the UI thread per tap at 2,000 operations on a
/// fast machine, a multiple on a tablet, and megabytes rewritten once photos were waiting too.
abstract interface class QueueStore {
  /// What was kept, oldest first.
  Future<List<Map<String, dynamic>>> load();

  /// Items joined the back of the queue, as one batch: after a crash all of them are there, or none.
  Future<void> add(List<Map<String, dynamic>> items);

  /// Items left the queue (sent, refused, or pushed out by newer ones); [empty] says nothing is left.
  Future<void> remove(List<Map<String, dynamic>> items, {required bool empty});

  /// The queue is exactly [items] from now on.
  Future<void> replace(List<Map<String, dynamic>> items);
}

/// Keeps nothing between runs: for tests, and for a queue that may forget.
class MemoryStore implements QueueStore {
  final items = <Map<String, dynamic>>[];

  @override
  Future<List<Map<String, dynamic>>> load() async => [...items];

  @override
  Future<void> add(List<Map<String, dynamic>> added) async => items.addAll(added);

  @override
  Future<void> remove(List<Map<String, dynamic>> removed, {required bool empty}) async =>
      items.removeWhere((item) => removed.any((r) => identical(r, item)));

  @override
  Future<void> replace(List<Map<String, dynamic>> all) async => items
    ..clear()
    ..addAll(all);
}

/// A queue of small items in one file that is only ever added to: a line per batch added (a JSON list), a
/// line per batch removed (`-` and the ids that went), and the file is cut back to nothing whenever the queue
/// empties, which with a backend answering is after every tap. Adding and removing therefore cost the size
/// of what is added or removed, never the size of the queue.
///
/// A line counts once its newline is on disk. A crash or a full disk in the middle of a write leaves a line
/// without one: it is ignored when the file is read, and every record starts on a new line, so what is
/// written next is never glued to it. Removals name ids, not positions, so a record that went missing cannot
/// make a later removal take the wrong items.
class JournalStore implements QueueStore {
  JournalStore(this.file, {required this.id});

  final File file;

  /// The field that names an item (`op_id`).
  final String id;

  Future<void> _writes = Future.value(); // one write after another, in the order they were asked for
  bool _made = false; // the folder is there

  @override
  Future<List<Map<String, dynamic>>> load() => _next(() async {
    final List<int> bytes;
    try {
      bytes = await file.readAsBytes();
    } on FileSystemException {
      return <Map<String, dynamic>>[]; // nothing kept yet
    }
    final text = utf8.decode(bytes, allowMalformed: true);
    final items = read(text, id);
    // A last line cut short is dropped for good, so the queue read now is the queue read next time too.
    if (text.isNotEmpty && !text.endsWith('\n')) await _rewrite(items);
    return items;
  });

  /// The queue a journal's text describes.
  static List<Map<String, dynamic>> read(String text, String id) {
    final items = <Map<String, dynamic>>[];
    final whole = text.lastIndexOf('\n'); // what follows the last newline did not get written whole
    for (final line in const LineSplitter().convert(whole < 0 ? '' : text.substring(0, whole))) {
      if (line.isEmpty) continue;
      try {
        if (line.startsWith('-')) {
          final gone = (jsonDecode(line.substring(1)) as List).toSet();
          items.removeWhere((item) => gone.contains(item[id]));
        } else {
          items.addAll((jsonDecode(line) as List).map((item) => (item as Map).cast<String, dynamic>()));
        }
      } on FormatException {
        // a line that is not a record: left out
      } on TypeError {
        // the same
      }
    }
    return items;
  }

  @override
  Future<void> add(List<Map<String, dynamic>> items) =>
      items.isEmpty ? Future.value() : _append('\n${jsonEncode(items)}\n');

  @override
  Future<void> remove(List<Map<String, dynamic>> items, {required bool empty}) {
    if (empty) {
      // Nothing left: the file starts over. Cut short, it is whole or empty; whole, the items are sent once
      // more, which a backend ignores.
      return _next(() async {
        await _make();
        await file.writeAsString('', flush: true);
      });
    }
    if (items.isEmpty) return Future.value();
    return _append('\n-${jsonEncode([for (final item in items) item[id]])}\n');
  }

  @override
  Future<void> replace(List<Map<String, dynamic>> items) => _next(() => _rewrite(items));

  /// Written beside the file, then moved over it: a crash leaves the old queue or the new one.
  Future<void> _rewrite(List<Map<String, dynamic>> items) async {
    await _make();
    final partial = File('${file.path}.part');
    await partial.writeAsString(items.isEmpty ? '' : '${jsonEncode(items)}\n', flush: true);
    await partial.rename(file.path);
  }

  Future<void> _append(String text) => _next(() async {
    await _make();
    await file.writeAsString(text, mode: FileMode.append, flush: true);
  });

  Future<void> _make() async {
    if (_made) return;
    await file.parent.create(recursive: true);
    _made = true;
  }

  /// Runs [write] after the writes before it, whether or not they failed.
  Future<T> _next<T>(Future<T> Function() write) {
    final done = _writes.then((_) => write());
    _writes = done.then<void>((_) {}, onError: (_) {});
    return done;
  }
}

/// A queue of large items (a photo each), one file per item in a folder of its own, numbered in the order
/// they were added: adding writes one file, removing deletes one, and nothing else is touched.
class FolderStore implements QueueStore {
  FolderStore(this.folder, {required this.id});

  final Directory folder;

  /// The field that names an item (`photo_id`).
  final String id;

  final Map<Object?, String> _files = {}; // item id -> its file's name
  int _last = 0; // the highest number given out
  Future<void> _writes = Future.value();

  static final _name = RegExp(r'^(\d+)\.json$');

  @override
  Future<List<Map<String, dynamic>>> load() => _next(() async {
    await folder.create(recursive: true);
    final names = <(int, String)>[];
    await for (final entry in folder.list()) {
      final name = entry.uri.pathSegments.last;
      final match = _name.firstMatch(name);
      if (entry is! File) continue;
      if (match == null) {
        if (name.endsWith('.part')) await _delete(name); // a write that did not finish
        continue;
      }
      names.add((int.parse(match.group(1)!), name));
    }
    names.sort((a, b) => a.$1.compareTo(b.$1));
    final items = <Map<String, dynamic>>[];
    _files.clear();
    for (final (number, name) in names) {
      if (number > _last) _last = number;
      try {
        final item = (jsonDecode(await File('${folder.path}/$name').readAsString()) as Map).cast<String, dynamic>();
        _files[item[id]] = name;
        items.add(item);
      } on FormatException {
        await _delete(name);
      } on FileSystemException {
        await _delete(name);
      } on TypeError {
        await _delete(name);
      }
    }
    return items;
  });

  @override
  Future<void> add(List<Map<String, dynamic>> items) => _next(() async {
    if (items.isEmpty) return;
    await folder.create(recursive: true);
    for (final item in items) {
      final name = '${(++_last).toString().padLeft(12, '0')}.json';
      final partial = File('${folder.path}/$name.part');
      await partial.writeAsString(jsonEncode(item), flush: true);
      await partial.rename('${folder.path}/$name');
      _files[item[id]] = name;
    }
  });

  @override
  Future<void> remove(List<Map<String, dynamic>> items, {required bool empty}) => _next(() async {
    for (final item in items) {
      final name = _files.remove(item[id]);
      if (name != null) await _delete(name);
    }
  });

  @override
  Future<void> replace(List<Map<String, dynamic>> items) async {
    await _next(() async {
      for (final name in _files.values.toList()) {
        await _delete(name);
      }
      _files.clear();
    });
    await add(items);
  }

  Future<void> _delete(String name) async {
    try {
      await File('${folder.path}/$name').delete();
    } on FileSystemException {
      // already gone
    }
  }

  Future<T> _next<T>(Future<T> Function() write) {
    final done = _writes.then((_) => write());
    _writes = done.then<void>((_) {}, onError: (_) {});
    return done;
  }
}

/// The queue [store] holds, with what a build before 2026-11-12 left in the preference store under [key] (a
/// list of JSON strings) taken over first: those items go in front of the store's own (they are older), each
/// once by [id], and the key is removed. Safe to run on every start, and to be cut short: the store is
/// written before the key is removed, and an item found in both places is taken once.
Future<List<Map<String, dynamic>>> restoreQueue(
  QueueStore store, {
  required SharedPreferences? legacy,
  required String key,
  required String id,
}) async {
  final kept = await store.load();
  final texts = legacy?.getStringList(key);
  if (legacy == null || texts == null) return kept;
  final known = {for (final item in kept) item[id]};
  final old = <Map<String, dynamic>>[];
  for (final text in texts) {
    try {
      final item = (jsonDecode(text) as Map).cast<String, dynamic>();
      if (known.add(item[id])) old.add(item);
    } on FormatException {
      // not an item: nothing to keep
    } on TypeError {
      // the same
    }
  }
  final all = [...old, ...kept];
  if (old.isNotEmpty) await store.replace(all);
  await legacy.remove(key);
  return all;
}
