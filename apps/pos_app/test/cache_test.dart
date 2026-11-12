import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/cache.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The saved reads live in files of their own (ADR 6), not in the preference store: the menu is a couple of
/// hundred kilobytes and every dish's choices together over ten megabytes, and the store rewrites itself whole
/// on every write.
void main() {
  Future<Directory> folder() async {
    final dir = await Directory.systemTemp.createTemp('pos_read_cache');
    addTearDown(() => dir.delete(recursive: true));
    return dir;
  }

  test('answers are files that survive a restart, each with the time it was read', () async {
    final dir = await folder();
    var now = DateTime(2026, 11, 12, 9);
    final cache = await ReadCache.open(dir, now: () => now);
    expect(cache.hasMenu, isFalse);
    expect(cache.menuAt, isNull);
    expect(await cache.get('floor'), isNull);

    await cache.put('menu:pos:en', {'menus': [], 'revision': 3});
    now = now.add(const Duration(minutes: 1));
    await cache.put('item:J55|dinner/sushi:en', {'item': 'J55'}); // a name with every odd character
    await cache.put('taxes', {'tax_rate_pct': '7.00'});
    expect(cache.hasMenu, isTrue);
    expect(cache.menuAt, DateTime(2026, 11, 12, 9));
    expect(cache.readAt('item:J55|dinner/sushi:en'), DateTime(2026, 11, 12, 9, 1));
    expect(cache.names('item:J55|'), ['item:J55|dinner/sushi:en']);
    expect(cache.has('taxes'), isTrue);
    expect(await cache.get('item:J55|dinner/sushi:en'), {'item': 'J55'});
    expect(await cache.get('menu:pos:en'), {'menus': [], 'revision': 3});
    // the tax rates are wanted without waiting, while a check is drawn
    expect(cache.peek('taxes'), {'tax_rate_pct': '7.00'});
    expect(cache.peek('menu:pos:en'), isNull);
    // every answer is a file directly in the folder, whatever its name
    final files = dir.listSync().whereType<File>().map((f) => f.uri.pathSegments.last).toList();
    expect(files.where((f) => f != 'index.json'), hasLength(3));
    expect(dir.listSync().whereType<Directory>(), isEmpty);

    final again = await ReadCache.open(dir, now: () => now); // the app starts over
    expect(again.hasMenu, isTrue);
    expect(again.menuAt, DateTime(2026, 11, 12, 9));
    expect(again.readAt('item:J55|dinner/sushi:en'), DateTime(2026, 11, 12, 9, 1));
    expect(await again.get('menu:pos:en'), {'menus': [], 'revision': 3});
    expect(again.peek('taxes'), {'tax_rate_pct': '7.00'}); // read when the cache opened

    // the same answer again is not written again
    final stamp = File('${dir.path}/index.json').lastModifiedSync();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    now = now.add(const Duration(minutes: 1));
    await again.put('taxes', {'tax_rate_pct': '7.00'});
    expect(File('${dir.path}/index.json').lastModifiedSync(), stamp);
    expect(again.readAt('taxes'), DateTime(2026, 11, 12, 9, 1));
  });

  test("a menu revision's dishes are saved together, once, and the dishes of the last one go", () async {
    final dir = await folder();
    final cache = await ReadCache.open(dir);
    expect(cache.itemsRevision(), isNull);
    await cache.put('item:OLD|dinner:1:en', {'item': 'OLD'});
    await cache.put('item:GTC|dinner:87:zh', {'item': 'GTC'}); // another language stays
    await cache.saveItems({
      'item:GTC|dinner:87:en': '{"item":"GTC"}',
      'item:C5|dinner:5:en': '{"item":"C5"}',
    }, revision: 3);
    expect(cache.itemsRevision(), 3);
    expect(cache.itemsRevision(locale: 'zh'), isNull);
    expect(cache.names('item:').toList()..sort(), [
      'item:C5|dinner:5:en',
      'item:GTC|dinner:87:en',
      'item:GTC|dinner:87:zh',
    ]);
    expect(await cache.get('item:OLD|dinner:1:en'), isNull);
    expect(await cache.get('item:GTC|dinner:87:en'), {'item': 'GTC'});
    expect(dir.listSync().whereType<File>().map((f) => f.uri.pathSegments.last), isNot(contains(contains('OLD'))));

    final again = await ReadCache.open(dir);
    expect(again.itemsRevision(), 3);
    expect(await again.get('item:C5|dinner:5:en'), {'item': 'C5'});
  });

  test('a file that did not get written whole counts as missing', () async {
    final dir = await folder();
    final cache = await ReadCache.open(dir);
    await cache.put('floor', {'tables': []});
    final file = dir.listSync().whereType<File>().firstWhere((f) => !f.path.endsWith('index.json'));
    file.writeAsStringSync('{"tables": [');
    expect(await cache.get('floor'), isNull);
    expect(cache.has('floor'), isFalse);
  });

  test('the copies older builds kept in the preference store are removed, and nothing else', () async {
    SharedPreferences.setMockInitialValues({
      'read:menu:pos:en': '{"menus":[]}',
      'read_at:menu:pos:en': 1,
      'read:item:GTC|dinner:87:en': '{"item":"GTC"}',
      'read_at:item:GTC|dinner:87:en': 2,
      'outbox': <String>['{"op_id":"x"}'],
      'device': 't1',
    });
    final prefs = await SharedPreferences.getInstance();
    expect(await ReadCache.forgetLegacy(prefs, pause: Duration.zero), 4);
    expect(prefs.getKeys(), {'outbox', 'device'});
    expect(await ReadCache.forgetLegacy(prefs, pause: Duration.zero), 0);
  });
}
