import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/camera.dart';
import 'package:pos_app/outbox.dart';
import 'package:pos_app/photos.dart';
import 'package:pos_app/queue_store.dart';
import 'package:pos_app/session.dart';
import 'package:pos_app/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The taps and the audit photos not sent yet are kept in files that cost the same to add to and take from
/// however many are waiting: a whole service taken with no backend (ADR 6) is a couple of thousand
/// operations, and the preference store they used to be in rewrote all of them on every tap.
class OneShotCamera extends EventCamera {
  @override
  bool get ready => true;
  @override
  String? get error => null;
  @override
  Widget preview() => const SizedBox();
  @override
  Future<Uint8List?> snap() async => Uint8List.fromList([0xff, 0xd8, 0xff, 0xd9]);
}

void main() {
  Future<Directory> folder() async {
    final dir = await Directory.systemTemp.createTemp('pos_queue');
    addTearDown(() => dir.delete(recursive: true));
    return dir;
  }

  Map<String, dynamic> op(String id, [String order = 'o1']) => {
    'op_id': id,
    'order_id': order,
    'kind': 'add_line',
    'data': {'item': 'Crab Rangoon é 蟹角', 'qty': 1},
  };

  group('the journal', () {
    test('keeps the queue across a restart, in order, and nothing once it is empty', () async {
      final file = File('${(await folder()).path}/deep/outbox.log'); // the folder is made on the way
      JournalStore journal() => JournalStore(file, id: 'op_id');
      final store = journal();
      expect(await store.load(), isEmpty);
      final a = op('a'), b = op('b'), c = op('c'), d = op('d');
      await store.add([a, b]);
      await store.add([c]);
      expect(await journal().load(), [a, b, c]);
      await store.remove([a, b], empty: false);
      await store.add([d]);
      expect(await journal().load(), [c, d]);
      await store.remove([c, d], empty: true);
      expect(file.readAsStringSync(), isEmpty);
      expect(await journal().load(), isEmpty);
      await store.replace([d, a]);
      expect(await journal().load(), [d, a]);
      await store.add(const []); // nothing to add, nothing written
      await store.remove(const [], empty: false);
      expect(await journal().load(), [d, a]);
    });

    test('adding to a long queue writes the new operations only', () async {
      final file = File('${(await folder()).path}/outbox.log');
      final store = JournalStore(file, id: 'op_id');
      final waiting = [for (var i = 0; i < 3000; i++) op('w$i', 'o${i ~/ 12}')];
      await store.replace(waiting);
      final before = file.readAsBytesSync();
      final one = op('new');
      await store.add([one]);
      final after = file.readAsBytesSync();
      expect(after.length - before.length, utf8.encode(jsonEncode([one])).length + 2); // its line, nothing else
      expect(after.sublist(0, before.length), before);
      await store.remove([waiting.first], empty: false);
      expect(file.lengthSync() - after.length, lessThan(40)); // which one went, not what is left
      final back = await JournalStore(file, id: 'op_id').load();
      expect(back, hasLength(3000));
      expect(back.first['op_id'], 'w1');
      expect(back.last, one);
    });

    test('cut short anywhere, the file still reads as a queue it once was', () async {
      final dir = await folder();
      final file = File('${dir.path}/outbox.log');
      final store = JournalStore(file, id: 'op_id');
      final a = op('a'), b = op('b'), c = op('c'), d = op('d'), e = op('e');
      // the queue after each record, as the journal is written
      final states = <List<Map<String, dynamic>>>[[]];
      await store.add([a, b]);
      states.add([a, b]);
      await store.add([c]);
      states.add([a, b, c]);
      await store.remove([a], empty: false);
      states.add([b, c]);
      await store.add([d, e]);
      states.add([b, c, d, e]);
      await store.remove([b, c], empty: false);
      states.add([d, e]);
      final whole = file.readAsBytesSync();
      final extra = op('later');
      final seen = <int>{};
      for (var cut = 0; cut <= whole.length; cut++) {
        final torn = File('${dir.path}/torn-$cut.log')..writeAsBytesSync(whole.sublist(0, cut));
        final read = await JournalStore(torn, id: 'op_id').load();
        final at = states.indexWhere((s) => jsonEncode(s) == jsonEncode(read));
        expect(at, isNot(-1), reason: 'cut at $cut read as ${read.map((o) => o['op_id'])}');
        seen.add(at);
        // what is written next starts clean, and a second read sees the first read's queue plus that
        final again = JournalStore(torn, id: 'op_id');
        await again.add([extra]);
        expect(await JournalStore(torn, id: 'op_id').load(), [...read, extra], reason: 'cut at $cut');
        torn.deleteSync();
      }
      expect(seen, {0, 1, 2, 3, 4, 5}); // every state of the queue, and never one it was not in
    });

    test('a line that is not a record is left out, and a removal still takes the right operations', () {
      final a = op('a'), b = op('b'), c = op('c');
      final text = [
        jsonEncode([a]),
        '{"not": "a batch"}',
        'garbage',
        jsonEncode([b, c]),
        '-${jsonEncode(['a', 'missing'])}',
        '-not json',
        '',
      ].join('\n');
      expect(JournalStore.read(text, 'op_id'), [b, c]);
      expect(JournalStore.read('', 'op_id'), isEmpty);
      expect(JournalStore.read('${jsonEncode([a])}\n${jsonEncode([b])}', 'op_id'), [a]); // no newline: not whole
    });

    test('a write that fails does not stop the ones after it', () async {
      final dir = await folder();
      final blocked = Directory('${dir.path}/outbox.log')..createSync(); // a folder where the file should be
      final store = JournalStore(File(blocked.path), id: 'op_id');
      await expectLater(store.add([op('a')]), throwsA(isA<FileSystemException>()));
      blocked.deleteSync();
      await store.add([op('b')]);
      expect((await store.load()).map((o) => o['op_id']), ['b']);
    });
  });

  group('the folder', () {
    test('keeps each item in a file of its own, in the order they were added', () async {
      final dir = await folder();
      FolderStore photos() => FolderStore(dir, id: 'photo_id');
      Map<String, dynamic> photo(String id) => {'photo_id': id, 'jpeg_b64': 'A' * 2000};
      final store = photos();
      expect(await store.load(), isEmpty);
      final a = photo('a'), b = photo('b'), c = photo('c');
      await store.add([a]);
      await store.add([b, c]);
      expect(dir.listSync(), hasLength(3));
      expect(await photos().load(), [a, b, c]);

      final untouched = {for (final f in dir.listSync().whereType<File>()) f.path: f.lastModifiedSync()};
      await store.remove([a], empty: false);
      expect(dir.listSync(), hasLength(2));
      for (final f in dir.listSync().whereType<File>()) {
        expect(f.lastModifiedSync(), untouched[f.path]); // the others were not rewritten
      }

      // after a restart the numbering goes on, so a new photo still comes last
      final restarted = photos();
      expect(await restarted.load(), [b, c]);
      final d = photo('d');
      await restarted.add([d]);
      await restarted.remove([b], empty: false);
      expect(await photos().load(), [c, d]);
      await restarted.replace([a]);
      expect(await photos().load(), [a]);
      await restarted.remove([a], empty: true);
      expect(dir.listSync(), isEmpty);
    });

    test('a file that did not get written whole is dropped', () async {
      final dir = await folder();
      final store = FolderStore(dir, id: 'photo_id');
      await store.add([
        {'photo_id': 'a'},
        {'photo_id': 'b'},
      ]);
      final files = dir.listSync().whereType<File>().toList()..sort((x, y) => x.path.compareTo(y.path));
      files.first.writeAsStringSync('{"photo_id": "a", "jpeg');
      File('${dir.path}/000000000009.json.part').writeAsStringSync('{"photo');
      File('${dir.path}/notes.txt').writeAsStringSync('not ours');
      final again = FolderStore(dir, id: 'photo_id');
      expect((await again.load()).map((p) => p['photo_id']), ['b']);
      expect(dir.listSync().map((f) => f.uri.pathSegments.last).toSet(), {'000000000002.json', 'notes.txt'});
    });
  });

  group('a queue an older build kept in the preference store', () {
    test('is taken over once, in front of what the files hold, and removed from the store', () async {
      SharedPreferences.setMockInitialValues({
        'outbox': [jsonEncode(op('old1')), 'not json', jsonEncode(op('both')), jsonEncode(op('old2'))],
        'device': 't1',
      });
      final prefs = await SharedPreferences.getInstance();
      final store = MemoryStore()..items.addAll([op('both'), op('new')]);
      final queue = await restoreQueue(store, legacy: prefs, key: 'outbox', id: 'op_id');
      expect(queue.map((o) => o['op_id']), ['old1', 'old2', 'both', 'new']);
      expect(store.items.map((o) => o['op_id']), ['old1', 'old2', 'both', 'new']);
      expect(prefs.getKeys(), {'device'});
      // the next start finds nothing to take over
      expect((await restoreQueue(store, legacy: prefs, key: 'outbox', id: 'op_id')).length, 4);
      expect((await restoreQueue(store, legacy: null, key: 'outbox', id: 'op_id')).length, 4);
    });
  });

  group('audit photos', () {
    Future<(PhotoQueue, List<String>, Directory, void Function(bool))> queue({int keep = 50}) async {
      SharedPreferences.setMockInitialValues({});
      final settings = Settings(
        device: 'mac1',
        endpoints: const ['http://hub1:8000'],
        prefs: await SharedPreferences.getInstance(),
      );
      var up = false;
      final sent = <String>[];
      final client = MockClient((request) async {
        if (!up) throw http.ClientException('connection refused', request.url);
        sent.add((jsonDecode(request.body) as Map)['op_id'] as String);
        return http.Response('{}', 202);
      });
      final api = PosApi(settings, client: client, timeout: const Duration(milliseconds: 200));
      final dir = await folder();
      final photos = PhotoQueue(
        api,
        settings,
        OneShotCamera(),
        Session(api),
        store: FolderStore(dir, id: PhotoQueue.idField),
        keep: keep,
      );
      addTearDown(photos.dispose);
      return (photos, sent, dir, (bool now) => up = now);
    }

    test('only the newest are kept through a long outage, on disk as in memory', () async {
      final (photos, sent, dir, backend) = await queue(keep: 3);
      for (var i = 0; i < 5; i++) {
        await photos.capture('fire', opId: 'op$i');
        await photos.flush();
      }
      expect(photos.pending, 3);
      expect(dir.listSync(), hasLength(3));
      final kept = await FolderStore(dir, id: PhotoQueue.idField).load();
      expect(kept.map((p) => p['op_id']), ['op2', 'op3', 'op4']);
      backend(true);
      await photos.flush();
      expect(sent, ['op2', 'op3', 'op4']);
      expect(dir.listSync(), isEmpty);
    });

    test('photos an older build kept in the preference store are sent first', () async {
      final (photos, sent, dir, backend) = await queue();
      SharedPreferences.setMockInitialValues({
        'photos': [
          jsonEncode({'photo_id': 'p0', 'op_id': 'before', 'jpeg_b64': '/9j/2Q=='}),
        ],
      });
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      await photos.restore(legacy: prefs);
      await photos.flush();
      expect(prefs.getKeys(), isEmpty);
      expect(dir.listSync(), hasLength(1));
      await photos.capture('close', opId: 'after');
      backend(true);
      await photos.flush();
      expect(sent, ['before', 'after']);
    });
  });

  test('an outbox that waited through an outage costs the same per tap as an empty one', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = Settings(device: 't1', endpoints: const [], prefs: await SharedPreferences.getInstance());
    final file = File('${(await folder()).path}/outbox.log');
    final outbox = Outbox(PosApi(settings), settings, store: JournalStore(file, id: Outbox.idField));
    addTearDown(outbox.dispose);
    for (var i = 0; i < 300; i++) {
      await outbox.add('o${i ~/ 10}', 'add_line', {'line_id': 'L$i', 'item': 'Egg Roll', 'qty': 1});
    }
    final before = file.lengthSync();
    await outbox.add('o30', 'fire', {'course': '*'});
    expect(file.lengthSync() - before, lessThan(400)); // one operation's worth, not three hundred and one
    final restarted = Outbox(PosApi(settings), settings, store: JournalStore(file, id: Outbox.idField));
    addTearDown(restarted.dispose);
    await restarted.restore();
    expect(restarted.pendingOps, outbox.pendingOps);
  });
}
