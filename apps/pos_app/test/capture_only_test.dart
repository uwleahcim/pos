import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/cache.dart';
import 'package:pos_app/floor.dart';
import 'package:pos_app/local_order.dart';
import 'package:pos_app/menu.dart';
import 'package:pos_app/outbox.dart';
import 'package:pos_app/screens/menu_panel.dart';
import 'package:pos_app/screens/status_bar.dart';
import 'package:pos_app/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// ADR 6: with every backend gone, a screen keeps taking orders against what it read last.

Map<String, dynamic> fixture(String name) =>
    jsonDecode(File('test/fixtures/$name.json').readAsStringSync()) as Map<String, dynamic>;

/// A pretend hub and cloud serving the fixtures; any address can be switched off.
class FakeBackends {
  final Set<String> down = {};
  final List<Map<String, dynamic>> ops = [];
  final List<String> requests = []; // the path of every read that reached a backend
  int revision = 3; // the menu's revision; a save moves it

  int reads(String path) => requests.where((p) => p == path).length;

  http.Client client() => MockClient((request) async {
    final base = '${request.url.scheme}://${request.url.host}:${request.url.port}';
    if (down.contains(base)) throw http.ClientException('connection refused', request.url);
    if (request.method == 'GET') requests.add(request.url.path);
    if (request.method == 'POST' && request.url.path.endsWith('/ops')) {
      final batch = (jsonDecode(request.body) as List).cast<Map<String, dynamic>>();
      ops.addAll(batch);
      return http.Response(
        jsonEncode({
          'accepted': [for (final op in batch) op['op_id']],
          'cursor': 1,
        }),
        202,
      );
    }
    final body = switch (request.url.path) {
      '/menu' => fixture('menu')..['revision'] = revision,
      '/menu/revision' => {'revision': revision},
      '/menu/items/GTC' => fixture('item_gtc'),
      '/menu/items' => {
        'revision': revision,
        'items': [
          {...fixture('item_gtc'), 'entry_id': 'dinner:87'},
        ],
      },
      '/menu/price' => {'name': "General Tso's Chicken (Pint)", 'unit_price': '13.95', 'problems': []},
      '/floor' => fixture('floor'),
      '/orders/o1/check' => fixture('check'),
      _ => null,
    };
    if (body == null) return http.Response('{"detail":"no such thing"}', 404);
    return http.Response.bytes(utf8.encode(jsonEncode(body)), 200);
  });
}

/// A terminal: its settings, a pretend hub and cloud, its outbox and its saved reads, in [folder] (a new
/// one by default; the folder of an earlier terminal makes this one the same device after a restart).
Future<(FakeBackends, PosApi, Outbox, ReadCache)> harness({
  List<String> endpoints = const ['http://hub:8000'],
  Directory? folder,
  FakeBackends? backends,
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final settings = Settings(device: 't1', endpoints: endpoints, prefs: prefs);
  backends ??= FakeBackends();
  if (folder == null) {
    folder = await Directory.systemTemp.createTemp('pos_read_cache');
    final made = folder;
    addTearDown(() => made.delete(recursive: true));
  }
  final cache = await ReadCache.open(folder);
  final api = PosApi(settings, client: backends.client(), timeout: const Duration(milliseconds: 200), cache: cache);
  final outbox = Outbox(api, settings, prefs: prefs);
  return (backends, api, outbox, cache);
}

/// Lets real work (files, a worker isolate) finish: a pause, then a frame, until [done] or a few seconds pass.
Future<void> settle(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 200 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await tester.pump();
  }
  expect(done(), isTrue);
}

void main() {
  test('with every backend down, the saved menu, dishes, floor and tax rates still serve', () async {
    final (backends, api, _, cache) = await harness();
    ConnectionLevel level() => api.connection.value.levelWith(api.settings.endpoints);

    // Nothing saved yet: an outage leaves the screen with nothing to work from.
    backends.down.add('http://hub:8000');
    await expectLater(api.menus(), throwsA(isA<ApiException>()));
    expect(level(), ConnectionLevel.lost);
    expect(api.connection.value.capturing, isFalse);

    backends.down.clear();
    final (revision, menus) = await api.menus();
    expect(revision, 3);
    expect(await api.prefetchItems(revision: revision), 1);
    await api.floor();
    await api.check('o1');
    expect(level(), ConnectionLevel.usual);
    expect(cache.hasMenu, isTrue);

    backends.down.add('http://hub:8000');
    final (again, saved) = await api.menus();
    expect(again, 3);
    expect(saved.map((m) => m.menu), menus.map((m) => m.menu));
    expect(api.connection.value.capturing, isTrue);
    expect(level(), ConnectionLevel.capturing);
    final detail = await api.item('GTC', entryId: 'dinner:87'); // saved by the prefetch
    expect(detail.groups.map((g) => g.groupId), ['spice', 'rice', 'addons']);
    expect((await api.item('GTC')).item, 'GTC'); // never read without an entry: any saved size of the dish
    await expectLater(api.item('WINGS'), throwsA(isA<ApiException>())); // never saved at all
    expect((await api.floor()).checksAt('A7'), hasLength(1)); // the last picture of the floor
    expect(api.savedTaxes!.taxLines.map((t) => t.ratePct), ['6.25', '0.75']);
    expect((api.savedTaxes!.estimated, api.savedTaxes!.taxRatePct), (true, '7.00'));
    expect(cache.menuAt, isNotNull);
  });

  test('operations stamped while capturing only carry the offline flag, the rest do not', () async {
    final (backends, api, outbox, _) = await harness();
    await api.menus();
    await outbox.add('o1', 'create', {'table': 'A7'});
    await outbox.flush();
    expect(backends.ops.single['data'], {'table': 'A7'});

    backends.down.add('http://hub:8000');
    await expectLater(api.menuRevision(), throwsA(isA<ApiException>())); // the poll that notices
    expect(api.connection.value.capturing, isTrue);
    await outbox.add('o1', 'add_line', {'line_id': 'L1', 'item': 'Egg roll', 'qty': 1});
    await outbox.flush();
    expect(outbox.pendingOps.single['data'], {'line_id': 'L1', 'item': 'Egg roll', 'qty': 1, 'offline': true});

    backends.down.clear();
    await outbox.flush();
    expect(outbox.pending, 0);
    expect(backends.ops.last['data']['offline'], isTrue);
    expect(api.connection.value.capturing, isFalse);
  });

  test('a check opened with no backend works its tax from the saved rates and prices dishes from the menu', () async {
    final (_, api, _, _) = await harness();
    await api.check('o1'); // the rates come with every check read
    final order = withLocalOps(const Order.empty('o2'), [
      {
        'order_id': 'o2',
        'kind': 'create',
        'data': {'table': 'B2'},
      },
      {
        'order_id': 'o2',
        'kind': 'add_line',
        'data': {'line_id': 'L1', 'item': 'GTC', 'qty': 2},
      },
    ]);
    final check = estimateCheck(api.savedTaxes, order, {'L1': const LocalLine(unitPrice: '13.95')});
    expect((check.estimated, check.subtotal, check.tax, check.total), (true, '27.90', '1.95', '29.85'));

    final gtc = ItemDetail.fromJson(fixture('item_gtc'));
    final request = LineRequest(
      variantId: 'GTC:quart',
      entryId: 'dinner:87',
      selections: {
        'rice': ['rice:brown'],
        'addons': ['addons:shrimp', 'addons:sauce'],
      },
      prefixes: {'addons:shrimp': 'no'},
    );
    final priced = localPrice('GTC (Quart)', gtc.variants, gtc, request);
    // 24.95 + 1.00 brown rice + 0.50 sauce; the shrimp marked "no" costs nothing, as on the hub
    expect((priced.unitPrice, priced.estimated, priced.ok), ('26.45', true, true));
    final missing = localPrice('GTC', gtc.variants, gtc, LineRequest(variantId: 'GTC:pint'));
    expect(missing.problems, ['Choose ${gtc.groups[1].name.toLowerCase()}']);
  });

  test('checks opened offline are listed and on the floor until a backend has them', () async {
    final (backends, _, outbox, _) = await harness();
    backends.down.add('http://hub:8000');
    await outbox.add('o3', 'create', {'table': 'B2', 'guests': 3, 'server': 'Amy'});
    await outbox.addAll('o3', [
      ('add_line', {'line_id': 'L1', 'item': 'Egg roll', 'qty': 2, 'course': '1'}),
      ('fire', {'course': '1'}),
    ]);
    await outbox.add('o4', 'add_line', {'line_id': 'L1', 'item': 'Tea'}); // the backend has o4 already
    await outbox.flush();
    final queued = queuedOrders(outbox);
    expect(queued.map((o) => o.orderId), ['o3']);
    expect(queued.single.activeLines.single.qty, 2);
    final checks = queuedChecks(outbox);
    final b2 = checks['B2']!.single;
    expect((b2.orderId, b2.guests, b2.server, b2.items), ('o3', 3, 'Amy', 2));
    expect(b2.fired, ['1']);
    expect(b2.held, isEmpty);
    expect((b2.stage, b2.openedMs == null), ('fired', false));
    final plan = FloorPlan.fromJson(fixture('floor')).withChecks(checks);
    expect(plan.checksAt('B2').single.orderId, 'o3');
    expect(plan.checksAt('A7'), hasLength(1));
  });

  testWidgets('the status icon goes amber on a backup and red with the banner and the card when nothing answers', (
    tester,
  ) async {
    // files are real work: the harness and the read that saves the menu run as such
    final (backends, api, outbox, _) = (await tester.runAsync(() async {
      final made = await harness(endpoints: ['http://hub:8000', 'http://cloud:8000']);
      await made.$2.menus(); // saved while the hub answers
      return made;
    }))!;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(
            actions: [StatusIcon(api: api, outbox: outbox)],
          ),
          body: Column(
            children: [CaptureBanner(api: api, outbox: outbox)],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.cloud_done_outlined), findsOneWidget);
    expect(find.byKey(const ValueKey('capture-banner')), findsNothing);

    backends.down.add('http://hub:8000');
    await api.menuRevision(); // the cloud answers
    await tester.pumpAndSettle();
    expect(api.connection.value.endpoint, 'http://cloud:8000');
    expect(find.byIcon(Icons.cloud_sync_outlined), findsOneWidget);
    expect(find.byKey(const ValueKey('capture-banner')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('status')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('runbook:backup')), findsOneWidget);
    expect(find.textContaining('On a backup: http://cloud:8000'), findsOneWidget);
    Navigator.of(tester.element(find.byKey(const ValueKey('runbook:backup')))).pop();
    await tester.pumpAndSettle();

    backends.down.add('http://cloud:8000');
    await expectLater(api.menuRevision(), throwsA(isA<ApiException>()));
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: find.byKey(const ValueKey('status')), matching: find.byIcon(Icons.cloud_off)),
      findsOneWidget,
    );
    expect(find.text('Taking orders only: nothing prints, cash only, prices are estimates'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('capture-banner')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('runbook:capturing')), findsOneWidget);
    expect(find.text('Hubs and internet down: taking orders only'), findsOneWidget);
    expect(find.textContaining('Menu saved just now'), findsOneWidget);
    expect(find.textContaining('Tax rates not saved yet'), findsOneWidget);
    expect(find.textContaining('Nothing prints: tell the kitchen by hand.'), findsOneWidget);
  });

  testWidgets('the item sheet prices a dish from the saved menu when nothing answers and still adds it', (
    tester,
  ) async {
    final (backends, api, _, _) = (await tester.runAsync(() async {
      final made = await harness();
      await made.$2.menus();
      await made.$2.prefetchItems(revision: 3);
      return made;
    }))!;
    backends.down.add('http://hub:8000');
    await expectLater(api.menuRevision(), throwsA(isA<ApiException>()));

    final chefs = ((fixture('menu')['menus'] as List)[0]['sections'] as List)[1] as Map<String, dynamic>;
    final entry = MenuEntry.fromJson((chefs['entries'] as List)[0] as Map<String, dynamic>);
    ChosenLine? result;
    await tester.binding.setSurfaceSize(const Size(1000, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => result = await showDialog<ChosenLine>(
              context: context,
              builder: (_) => ItemSheet(api: api, entry: entry),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    // the sheet reads the saved dish from its file: real work again
    await tester.runAsync(() async {
      await tester.tap(find.text('open'));
      await settle(tester, () => find.byKey(const ValueKey('price-estimated')).evaluate().isNotEmpty);
      expect(find.text('\$13.95'), findsOneWidget); // the pint with its free defaults
      await tester.tap(find.text('Add'));
      await settle(tester, () => result != null);
    });
    expect(result!.unitPrice, '13.95');
    expect(result!.request.selections['rice'], ['rice:white']);
  });
  test('every dish is saved once per menu revision: another screen, or a restart, downloads nothing', () async {
    final (backends, api, _, cache) = await harness();
    final prefs = await SharedPreferences.getInstance();
    await api.menus();
    expect(await api.prefetchItems(revision: 3), 1);
    expect(cache.itemsRevision(), 3);
    expect(await api.prefetchItems(revision: 3), 0);
    expect(backends.reads('/menu/items'), 1);
    // nothing of it lands in the preference store, which rewrites itself whole on every write
    expect(prefs.getKeys().where((k) => k.startsWith('read')), isEmpty);

    // the app starts over on the same device: the dishes are still there
    final (_, restarted, _, again) = await harness(folder: cache.folder, backends: backends);
    expect(again.itemsRevision(), 3);
    expect(await restarted.prefetchItems(revision: 3), 0);
    expect(backends.reads('/menu/items'), 1);
    expect((await restarted.item('GTC', entryId: 'dinner:87')).item, 'GTC');

    // a manager saved the menu: the dishes are read again, once, however many screens ask at the same time
    backends.revision = 4;
    final both = await Future.wait([restarted.prefetchItems(revision: 4), restarted.prefetchItems(revision: 4)]);
    expect(both, [1, 1]);
    expect(backends.reads('/menu/items'), 2);
    expect(again.itemsRevision(), 4);
  });

  testWidgets('opening the menu twice reads the menu twice and the dishes once', (tester) async {
    await tester.runAsync(() async {
      final (backends, api, _, _) = await harness();
      Widget panel() => MaterialApp(
        home: Scaffold(
          body: MenuPanel(api: api, onChosen: (_) {}),
        ),
      );
      await tester.pumpWidget(panel());
      await settle(tester, () => backends.reads('/menu/items') == 1);
      expect(backends.reads('/menu'), 1);
      await tester.pumpWidget(const SizedBox()); // the order screen closes
      await tester.pumpWidget(panel()); // and the next order opens
      await settle(tester, () => backends.reads('/menu') == 2);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(backends.reads('/menu/items'), 1);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
