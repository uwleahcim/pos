import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/cache.dart';
import 'package:pos_app/coursing.dart';
import 'package:pos_app/screens/order_screen.dart';
import 'package:pos_app/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'hub.dart';

/// The screens ask for the open orders, the floor and the open check every two seconds. A read that brings
/// nothing new must cost next to nothing: the hub says "the one you have" in a few bytes, the app hands the
/// screen the object it already holds, and the screen does not redraw.
void main() {
  Future<(Hub, PosApi, ReadCache)> device({bool names = true}) async {
    SharedPreferences.setMockInitialValues({});
    final settings = Settings(
      device: 't1',
      endpoints: const ['http://hub:8000'],
      prefs: await SharedPreferences.getInstance(),
    );
    final dir = await Directory.systemTemp.createTemp('pos_repeated_reads');
    addTearDown(() => dir.delete(recursive: true));
    final cache = await ReadCache.open(dir);
    final hub = Hub()
      ..namesAnswers = names
      ..check = fixture('check');
    return (hub, PosApi(settings, client: MockClient(hub.handle), cache: cache), cache);
  }

  test('a read with nothing new comes back as the very same object, without a body', () async {
    final (hub, api, _) = await device();
    hub.orders.add(table('o1', {'L1': line('Egg Roll')}));

    final first = await api.listOrders(status: 'open');
    final again = await api.listOrders(status: 'open');
    expect(first.single.lines.single.item, 'Egg Roll');
    expect(identical(first, again), isTrue);
    expect(hub.unchanged, 1);
    // a list asks for the orders without each line's choices and price
    expect(hub.requests, ['GET /orders?status=open&brief=true', 'GET /orders?status=open&brief=true']);

    final order = await api.order('o1');
    final check = await api.check('o1');
    expect(identical(await api.order('o1'), order), isTrue);
    expect(identical(await api.check('o1'), check), isTrue);
    final floor = await api.floor();
    expect(identical(await api.floor(), floor), isTrue);
    final (revision, menus) = await api.menus();
    final (revisionAgain, menusAgain) = await api.menus();
    expect(revisionAgain, revision);
    expect(identical(menus, menusAgain), isTrue);
    expect(hub.unchanged, 5);

    // something changed: the new answer, and from then on that one
    (hub.orders.single['lines'] as Map)['L2'] = line('Tsingtao');
    final changed = await api.listOrders(status: 'open');
    expect(identical(changed, first), isFalse);
    expect(changed.single.lines.map((l) => l.item), ['Egg Roll', 'Tsingtao']);
    expect(identical(await api.listOrders(status: 'open'), changed), isTrue);
    final orderNow = await api.order('o1');
    expect(identical(orderNow, order), isFalse);
    expect(orderNow.lines, hasLength(2));
  });

  test('a list of every order asks for a day of them, not the whole history', () async {
    final (hub, api, _) = await device();
    await api.listOrders(within: const Duration(hours: 24));
    expect(hub.requests.single, 'GET /orders?hours=24.0&brief=true');
  });

  test('a hub that does not name its answers is read in full every time, as before', () async {
    final (hub, api, _) = await device(names: false);
    hub.orders.add(table('o1', {'L1': line('Egg Roll')}));
    final first = await api.listOrders(status: 'open');
    final again = await api.listOrders(status: 'open');
    expect(identical(first, again), isFalse);
    expect(again.single.lines.single.item, 'Egg Roll');
    expect(hub.unchanged, 0);
  });

  test('a saved read is written when it changes, and only then', () async {
    final (hub, api, cache) = await device();
    await api.floor();
    final file = File('${cache.folder.path}/${ReadCache.fileName('floor')}');
    final index = File('${cache.folder.path}/index.json');
    final written = (file.lastModifiedSync(), index.lastModifiedSync(), file.readAsStringSync());
    expect(jsonDecode(written.$3), isA<Map<String, dynamic>>());
    await api.check('o1');
    expect(api.savedTaxes, isNotNull);
    final taxesWritten = index.lastModifiedSync();
    await Future<void>.delayed(const Duration(milliseconds: 1100)); // file times are whole seconds on some disks
    for (var i = 0; i < 5; i++) {
      await api.floor();
      await api.check('o1');
    }
    expect(hub.unchanged, 10);
    expect(file.lastModifiedSync(), written.$1);
    expect(index.lastModifiedSync(), taxesWritten);

    // nothing answers any more: the floor as it was last read
    final offline = PosApi(
      api.settings,
      client: MockClient((_) async => throw const SocketException('down')),
      cache: cache,
    );
    expect((await offline.floor()).tables, isNotEmpty);
  });

  test('a saved read counts as read when a backend confirms it, and the index follows within minutes', () async {
    final dir = await Directory.systemTemp.createTemp('pos_repeated_reads');
    addTearDown(() => dir.delete(recursive: true));
    var now = DateTime(2026, 11, 12, 9);
    final cache = await ReadCache.open(dir, now: () => now);
    await cache.putText('floor', '{"tables":[]}');
    final index = File('${dir.path}/index.json');
    final before = index.readAsStringSync();

    now = now.add(const Duration(minutes: 1));
    await cache.touch('floor');
    expect(cache.readAt('floor'), DateTime(2026, 11, 12, 9, 1));
    expect(index.readAsStringSync(), before); // not written for every confirmation
    await cache.touch('never-saved');
    expect(cache.has('never-saved'), isFalse);

    now = now.add(ReadCache.indexEvery);
    await cache.touch('floor');
    expect(index.readAsStringSync(), isNot(before));
    final again = await ReadCache.open(dir, now: () => now);
    expect(again.readAt('floor'), DateTime(2026, 11, 12, 9, 6));
    expect(await again.get('floor'), {'tables': <dynamic>[]});
  });

  test('only the most recently used answers are kept', () async {
    final (hub, api, _) = await device();
    for (var i = 0; i < 80; i++) {
      hub.orders.add(table('o$i', {'L1': line('Egg Roll')}));
    }
    final first = await api.order('o0');
    for (var i = 1; i < 80; i++) {
      await api.order('o$i');
    }
    expect(hub.unchanged, 0);
    final last = await api.order('o79');
    expect(hub.unchanged, 1); // still kept
    expect(last.orderId, 'o79');
    final firstAgain = await api.order('o0'); // long gone: read in full again, and right
    expect(hub.unchanged, 1);
    expect(identical(firstAgain, first), isFalse);
    expect(firstAgain.orderId, 'o0');
  });

  testWidgets('an open check that nobody touched is not redrawn by its polls', (tester) async {
    final t = await terminal(tester);
    t.hub.orders.add(table('o1', {'L1': line('Egg Roll', course: '1')}));
    await tester.pumpWidget(
      MaterialApp(
        home: OrderScreen(
          api: t.api,
          outbox: t.outbox,
          photos: t.photos,
          orderId: 'o1',
          coursing: Coursing.fromJson(t.hub.coursing),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Egg Roll'), findsWidgets);
    var redraws = 0;
    debugOnRebuildDirtyWidget = (element, _) {
      if (element.widget is OrderScreen) redraws += 1;
    };
    addTearDown(() => debugOnRebuildDirtyWidget = null);

    // three polls with nothing new: the hub says so, and the screen is left as it is
    final before = t.hub.unchanged;
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
    }
    expect(t.hub.unchanged, greaterThanOrEqualTo(before + 3));
    expect(redraws, 0);

    // another terminal adds a dish: the next poll shows it
    (t.hub.orders.single['lines'] as Map)['L2'] = line('Tsingtao', course: '1');
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(find.text('Tsingtao'), findsWidgets);
    expect(redraws, greaterThan(0));
    debugOnRebuildDirtyWidget = null;
    await stop(tester);
  });
}
