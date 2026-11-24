import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/camera.dart';
import 'package:pos_app/check_search.dart';
import 'package:pos_app/local_order.dart';
import 'package:pos_app/outbox.dart';
import 'package:pos_app/photos.dart';
import 'package:pos_app/queue_store.dart';
import 'package:pos_app/screens/orders_screen.dart';
import 'package:pos_app/session.dart';
import 'package:pos_app/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'check_search_test.dart' show check;
import 'counter_test.dart' as counter;
import 'hub.dart';
import 'quote_times_test.dart' show inMinutes, quoted;

/// Finding a check by the guest's name (the Toast comparison, 2026-11-24): the check of a table the host
/// seated a party at, from its reservation or the waitlist, says the party's name in the list of checks,
/// and the search box finds the check by it. The hub tells the list the names (`seated` on a check of
/// `GET /orders?brief=true`); nothing of it is on the check.

/// A table's check as a list gives it, with the names of the parties the hub says were seated on it.
Map<String, dynamic> seatedCheck(
  String id,
  String tableName, {
  List<Object?>? seated,
  String status = 'open',
  String? server,
  String? tabName,
  int? openedMs,
}) {
  final order = check(table(id, const {}), status: status, server: server, tableName: tableName, openedMs: openedMs);
  return {
    ...order,
    'fields': <String, dynamic>{...order['fields'] as Map<String, dynamic>, 'customer_name': ?tabName},
    'seated': ?seated,
  };
}

/// Chen at A7 from the book; Omar and then Wu at B12; three parties at C3; a walk-in at A1; Linda's tab,
/// which sat down at B2; and Linda Chen's phone order.
List<Map<String, dynamic>> tonight() => [
  seatedCheck('t1', 'A7', seated: ['Chen'], server: 'Amy'),
  seatedCheck('t2', 'B12', seated: ['Omar', 'Wu'], server: 'Ben'),
  seatedCheck('t3', 'C3', seated: ['Garcia', 'Okafor', 'Silva'], server: 'Amy'),
  seatedCheck('t4', 'A1', server: 'Ben'),
  seatedCheck('t5', 'B2', tabName: 'Linda', server: 'Ben'),
  check(
    quoted('o1', no: 41, name: 'Linda Chen', channel: 'phone'),
    phone: '(781) 555-1234',
    server: 'Amy',
  ),
];

/// The Patels sat at D4 earlier and paid.
List<Map<String, dynamic>> earlier() => [
  seatedCheck('c1', 'D4', seated: ['Patel'], status: 'closed', server: 'Amy', openedMs: inMinutes(-200)),
];

Finder key(String name) => find.byKey(ValueKey(name));

void main() {
  test('the list is told whose check it is, and a check is found by that name', () {
    final orders = {
      for (final json in [...tonight(), ...earlier()]) json['order_id'] as String: Order.fromJson(json),
    };
    Set<String> found(String words) => {
      for (final order in orders.values)
        if (checkMatches(order, words)) order.orderId,
    };
    expect(orders['t1']!.seated, ['Chen']);
    expect(orders['t2']!.seated, ['Omar', 'Wu']);
    expect(orders['t4']!.seated, isEmpty); // a walk-in: nobody was seated on it from the book or the list
    expect(found('chen'), {'t1', 'o1'}); // the party at A7, and the phone order under that name
    expect(found('CHEN a7'), {'t1'}); // with the table, in any order and whatever the capitals
    expect(found('amy chen'), {'t1', 'o1'}); // with the server's name
    expect(found('wu'), {'t2'}); // the party that joined the table
    expect(found('omar wu'), {'t2'});
    expect(found('silva'), {'t3'}); // the third party, which the row counts and does not name
    expect(found('patel'), {'c1'}); // a closed check still says whose it was
    expect(found('table chen'), {'t1'});
    expect(found('linda'), {'t5', 'o1'}); // a tab that sat down was found by its name already
    expect(found('zebra'), <String>{});
    // an older hub says no names: the check is found by its table and its server as before
    final before = Order.fromJson(seatedCheck('t9', 'A7', server: 'Amy'));
    expect(before.seated, isEmpty);
    expect(before.tableNames, isEmpty);
    expect((checkMatches(before, 'chen'), checkMatches(before, 'a7 amy')), (false, true));
  });

  test('the names are read tidily, each once, the name on the check first', () {
    final untidy = Order.fromJson(seatedCheck('t1', 'A7', seated: ['  Chen ', '', 7, null, 'Wu'], tabName: 'chen'));
    expect(untidy.seated, ['Chen', 'Wu']); // what is no name is left out
    expect(untidy.tableNames, ['chen', 'Wu']); // the tab's name and the party's are one name, said once
    expect(Order.fromJson({...seatedCheck('t2', 'A8'), 'seated': 'Chen'}).seated, isEmpty); // not a list: nobody
    expect(const Order.empty('t3').seated, isEmpty);
    // a to-go order has no table for anybody to be seated at
    expect(Order.fromJson(quoted('o1', name: 'Linda')).tableNames, ['Linda']);
  });

  test('a dish rung in on this screen leaves the names where they were', () {
    final order = Order.fromJson(seatedCheck('t1', 'A7', seated: ['Chen']));
    final rung = withLocalOps(order, [
      {
        'kind': 'add_line',
        'data': {'line_id': 'L1', 'item': 'Egg Roll', 'qty': 1},
      },
    ]);
    expect(rung.lines.length, 1);
    expect(rung.seated, ['Chen']);
  });

  testWidgets('a seated table\'s check says whose it is in the list of checks', (tester) async {
    await counter.pumpOrders(tester, tonight());
    expect(find.text('Table A7 · Chen'), findsOneWidget);
    expect(find.text('Table B12 · Omar, Wu'), findsOneWidget); // the first to sit first
    expect(find.text('Table C3 · Garcia, Okafor +1'), findsOneWidget); // two by name, the rest as a count
    expect(find.text('Table A1'), findsOneWidget); // a walk-in's check says its table alone
    expect(find.text('Table B2 · Linda'), findsOneWidget); // a tab that sat down keeps its name
    expect(find.text('Linda Chen · phone'), findsOneWidget); // a to-go order's row is as it was
    await stop(tester);
  });

  testWidgets('the search box finds a table\'s check by the party\'s name, an open one and a closed one', (
    tester,
  ) async {
    final past = earlier(); // read once: its times are counted from now
    await counter.pumpOrders(tester, tonight(), role: 'server', before: (hub) async => hub.past.addAll(past));
    expect(find.text('Table D4 · Patel'), findsNothing); // closed: not on the list of open checks
    await tester.tap(key('find-open'));
    await tester.pumpAndSettle();

    await tester.enterText(key('find-check'), 'chen');
    await tester.pumpAndSettle();
    expect(find.text('Table A7 · Chen'), findsOneWidget);
    expect(find.text('Linda Chen · phone'), findsOneWidget);
    expect(find.text('Table B12 · Omar, Wu'), findsNothing);
    expect(find.text('Table A1'), findsNothing);

    await tester.enterText(key('find-check'), 'wu');
    await tester.pumpAndSettle();
    expect(find.text('Table B12 · Omar, Wu'), findsOneWidget);
    expect(find.text('Table A7 · Chen'), findsNothing);

    await tester.enterText(key('find-check'), 'silva'); // behind the "+1"
    await tester.pumpAndSettle();
    expect(find.text('Table C3 · Garcia, Okafor +1'), findsOneWidget);

    await tester.enterText(key('find-check'), 'patel');
    await tester.pumpAndSettle();
    expect(find.text('Table D4 · Patel'), findsOneWidget);
    expect(find.textContaining('· closed'), findsOneWidget);

    await tester.enterText(key('find-check'), 'patel a7');
    await tester.pumpAndSettle();
    expect(find.text('No check matches.'), findsOneWidget);
    await stop(tester);
  });

  testWidgets('a party sits down on a listed check: the hub says the book changed and the row names it', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final settings = Settings(
      device: 't1',
      endpoints: ['http://hub:8000'],
      prefs: await SharedPreferences.getInstance(),
    );
    final hub = Hub()..orders.add(seatedCheck('t1', 'A7'));
    final live = LiveHub(hub);
    final api = PosApi(settings, client: live.client);
    final session = Session(api)..staff = const Staff(staffId: 's4', name: 'Holly', role: 'host', method: 'pin');
    final outbox = Outbox(api, settings, store: MemoryStore());
    final photos = PhotoQueue(api, settings, NoCamera(), session, store: MemoryStore());
    tester.view
      ..physicalSize = const Size(1100, 800)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    api.live.start();
    await tester.pumpWidget(
      MaterialApp(
        home: OrdersScreen(
          api: api,
          outbox: outbox,
          settings: settings,
          session: session,
          camera: NoCamera(),
          photos: photos,
        ),
      ),
    );
    await tester.pumpAndSettle();
    live.hello();
    live.beats();
    await tester.pumpAndSettle();
    expect(api.live.isLive, isTrue);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    await tester.tap(find.byTooltip('List of checks'));
    await tester.pumpAndSettle();
    expect(find.text('Table A7'), findsOneWidget);
    int lists() => hub.requests.where((r) => r == 'GET /orders' || r.startsWith('GET /orders?')).length;

    // the host seats the Chens' reservation on this check: no order changed, the book did
    hub.orders.single['seated'] = ['Chen'];
    var asked = lists();
    live.changed(topics: ['reservations']);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1)); // told reads are a second apart at the least
    await tester.pumpAndSettle();
    expect(lists(), asked + 1);
    expect(find.text('Table A7 · Chen'), findsOneWidget);

    // a party of the waitlist joins the table
    hub.orders.single['seated'] = ['Chen', 'Omar'];
    asked = lists();
    live.changed(topics: ['waitlist']);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(lists(), asked + 1);
    expect(find.text('Table A7 · Chen, Omar'), findsOneWidget);

    // news of something else reads no list of checks
    asked = lists();
    live.changed(topics: ['notes']);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(lists(), asked);

    await stop(tester);
    live.close();
    api.dispose();
    await tester.pump();
  });

  group('on a phone', () {
    for (final (name, size, type) in const [
      ('a phone', Size(390, 844), 1.0),
      ('a small phone with large type', Size(320, 568), 1.3),
    ]) {
      testWidgets('a long name stays on the row of $name', (tester) async {
        tester.platformDispatcher.textScaleFactorTestValue = type;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final t = await counter.terminal(tester, role: 'server');
        tester.view.physicalSize = size;
        t.hub.orders.addAll([
          seatedCheck('t1', 'B12', seated: ['Bartholomew-Fitzgerald', 'Okonkwo-Hernandez', 'Wu'], server: 'Amy'),
          seatedCheck('t2', 'A7', seated: ['Chen'], server: 'Ben'),
        ]);
        await tester.pumpWidget(
          MaterialApp(
            home: OrdersScreen(
              api: t.api,
              outbox: t.outbox,
              settings: t.settings,
              session: t.session,
              camera: NoCamera(),
              photos: t.photos,
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('List of checks'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final long = find.text('Table B12 · Bartholomew-Fitzgerald, Okonkwo-Hernandez +1');
        expect(long, findsOneWidget);
        final screen = tester.getRect(find.byType(Scaffold).first);
        for (final words in [long, find.text('Table A7 · Chen')]) {
          final rect = tester.getRect(words);
          expect(rect.left >= screen.left && rect.right <= screen.right, isTrue, reason: '$rect');
        }
        // and it is found from there
        await tester.tap(key('find-open'));
        await tester.pumpAndSettle();
        await tester.enterText(key('find-check'), 'okonkwo');
        await tester.pumpAndSettle();
        expect(long, findsOneWidget);
        expect(find.text('Table A7 · Chen'), findsNothing);
        expect(tester.takeException(), isNull);
        await stop(tester);
      });
    }
  });
}
