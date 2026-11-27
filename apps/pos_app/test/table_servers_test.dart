import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/camera.dart';
import 'package:pos_app/floor.dart';
import 'package:pos_app/local_order.dart';
import 'package:pos_app/outbox.dart';
import 'package:pos_app/queue_store.dart';
import 'package:pos_app/roster.dart';
import 'package:pos_app/screens/order_screen.dart';
import 'package:pos_app/screens/orders_screen.dart';
import 'package:pos_app/session.dart';
import 'package:pos_app/settings.dart';

import 'floor_test.dart' show floorJson;
import 'hub.dart';

/// The floor map of a terminal [who] is signed in at, on the pretend hub (A7 is Amy's, the rest are free).
Future<Terminal> pumpFloor(WidgetTester tester, Staff who, {void Function(Hub hub)? hub}) async {
  final t = await terminal(tester);
  t.session.staff = who;
  hub?.call(t.hub);
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
  await tester.pump();
  await tester.pump();
  return t;
}

const amy = Staff(staffId: 's1', name: 'Amy', role: 'server', method: 'pin');
const mike = Staff(staffId: 's3', name: 'Mike', role: 'manager', method: 'pin');
const holly = Staff(staffId: 's4', name: 'Holly', role: 'host', method: 'pin');

/// The one operation of [kind] the terminal sent, as (order id, data).
(String, Map<String, dynamic>) sentOne(Hub hub, String kind) {
  final (id, op) = hub.sent.where((s) => s.$2['kind'] == kind).single;
  return (id, (op['data'] as Map).cast<String, dynamic>());
}

Finder serverTag(String table) => find.byKey(ValueKey('table-server:$table'));

/// One room of the floor by itself, as a tap on its name above the map shows it. Its tables are drawn large
/// there and say whose each one is, which a small table has no room for on the map of the whole floor.
Future<void> showRoom(WidgetTester tester, String name) async {
  await tester.tap(find.widgetWithText(ChoiceChip, name));
  await tester.pumpAndSettle();
}

void main() {
  test('a server is named on a table by a first name, with an initial when there is more to the name', () {
    expect(shortName('Amy'), 'Amy');
    expect(shortName('Mike Wu'), 'Mike W');
    expect(shortName('  Mary  Jo   van Dyke '), 'Mary D');
    expect(shortName(''), '');
    expect(shortName(null), '');
  });

  test('the staff list says who takes tables and who gives them out, and what each has on the floor', () {
    final roster = Roster.fromJson({'staff': Hub().roster});
    expect(roster.servers.map((s) => s.name), ['Amy', 'Ben', 'Mike']);
    expect(
      (roster.assigns('s1'), roster.assigns('s3'), roster.assigns('s4'), roster.assigns(null)),
      (false, true, true, false),
    );
    expect(Roster.none.assigns('s4'), isFalse); // a hub older than the list: everyone seats their own

    final plan = FloorPlan.fromJson(floorJson());
    expect(ServerLoad.of(plan, roster.byId('s1')!).inWords, '1 table · 4 guests');
    expect(ServerLoad.of(plan, roster.byId('s2')!).inWords, 'No tables');
    // a check from a hub that names the server but sends no id still counts, by the name
    final named = FloorPlan.fromJson(
      floorJson()
        ..['status'] = {
          'B2': [
            {'order_id': 'o9', 'guests': 1, 'server': 'Ben'},
          ],
          'B3': [
            {'order_id': 'o8', 'guests': 2, 'server': 'Ben'},
          ],
        },
    );
    expect(ServerLoad.of(named, roster.byId('s2')!).inWords, '2 tables · 3 guests');
  });

  test('a table handed over on this device shows its new server before a hub has heard', () async {
    final settings = Settings(device: 't1', endpoints: ['http://hub:8000']);
    final api = PosApi(settings, client: MockClient((request) async => http.Response('', 503)));
    final outbox = Outbox(api, settings, store: MemoryStore());
    await outbox.add('o1', 'set_field', {'server': 'Ben', 'server_id': 's2', 'by': 'Holly', 'by_id': 's4'});
    await outbox.add('o1', 'set_field', {'guests': 5}); // some other change to the check is no hand-over
    expect(queuedServers(outbox), {'o1': ('Ben', 's2')});
    final plan = FloorPlan.fromJson(floorJson()).withServers(queuedServers(outbox));
    final a7 = plan.checksAt('A7').single;
    expect((a7.server, a7.serverId, a7.guests, a7.stage), ('Ben', 's2', 4, 'waiting'));
    await outbox.flush(); // nothing answers: it stays queued, and nothing is left running
    outbox.dispose();
    api.dispose();
  });

  testWidgets('a server takes a table by opening it: no question of whose it is', (tester) async {
    final t = await pumpFloor(tester, amy);
    await showRoom(tester, 'Main dining');
    expect(find.descendant(of: serverTag('A7'), matching: find.text('Amy')), findsOneWidget);
    expect(serverTag('A8'), findsNothing);

    await tester.tap(find.text('A8'));
    await tester.pumpAndSettle();
    expect(find.text('Seat A8'), findsOneWidget);
    expect(find.text('Server'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('seat')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    final (_, data) = sentOne(t.hub, 'create');
    expect((data['table'], data['server'], data['server_id']), ('A8', 'Amy', 's1'));
    expect(data.containsKey('by'), isFalse);
    expect(find.byType(OrderScreen), findsOneWidget); // and she is in her check
    await stop(tester);
  });

  testWidgets('the host seats a party for a server, and stays on the floor for the next one', (tester) async {
    final t = await pumpFloor(tester, holly);
    await tester.tap(find.text('A8'));
    await tester.pumpAndSettle();

    // Everyone who takes tables, each with what they have on the floor; the host is not one of them.
    expect(find.text('Server'), findsOneWidget);
    final amyTile = find.byKey(const ValueKey('server:s1'));
    expect(find.descendant(of: amyTile, matching: find.text('1 table · 4 guests')), findsOneWidget);
    expect(
      find.descendant(of: find.byKey(const ValueKey('server:s2')), matching: find.text('No tables')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('server:s3')), findsOneWidget);
    expect(find.byKey(const ValueKey('server:s4')), findsNothing);

    // Nobody is picked for the host: the party is not sat until she says whose table it is.
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('seat'))).onPressed, isNull);
    await tester.tap(find.byKey(const ValueKey('server:s2')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('seat')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    final (_, data) = sentOne(t.hub, 'create');
    expect((data['table'], data['guests'], data['order_type']), ('A8', 4, 'dine_in'));
    expect((data['server'], data['server_id']), ('Ben', 's2')); // the check is Ben's
    expect((data['by'], data['by_id']), ('Holly', 's4')); // and the log keeps who sat it
    expect(find.byType(OrderScreen), findsNothing); // she is still at the map
    expect(find.text("A8 is Ben's"), findsOneWidget);
    await stop(tester);
  });

  testWidgets('a manager who seats a party starts on their own name, and can give the table away', (tester) async {
    final t = await pumpFloor(tester, mike);
    await tester.tap(find.text('A8'));
    await tester.pumpAndSettle();
    // his own name is picked: Seat alone makes the table his, as it always did
    expect(
      find.descendant(of: find.byKey(const ValueKey('server:s3')), matching: find.byIcon(Icons.check_circle)),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('server:s1')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('seat')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    final (_, data) = sentOne(t.hub, 'create');
    expect((data['server'], data['server_id'], data['by'], data['by_id']), ('Amy', 's1', 'Mike', 's3'));
    expect(find.byType(OrderScreen), findsNothing);
    await stop(tester);
  });

  testWidgets('a manager who seats a party for himself is taken into the check', (tester) async {
    final t = await pumpFloor(tester, mike);
    await tester.tap(find.text('A8'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('seat')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    final (_, data) = sentOne(t.hub, 'create');
    expect((data['server'], data['server_id']), ('Mike', 's3'));
    expect(data.containsKey('by'), isFalse);
    expect(find.byType(OrderScreen), findsOneWidget);
    await stop(tester);
  });

  testWidgets('the host holds a seated table down and hands it to another server', (tester) async {
    final t = await pumpFloor(tester, holly);
    await tester.longPress(find.text('A7'));
    await tester.pumpAndSettle();
    expect(find.text('Who serves A7?'), findsOneWidget);
    // Amy has it now
    expect(
      find.descendant(of: find.byKey(const ValueKey('server:s1')), matching: find.byIcon(Icons.check_circle)),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('server:s2')));
    await tester.pumpAndSettle();

    final (order, data) = sentOne(t.hub, 'set_field');
    expect(order, 'o1');
    expect(data, {'server': 'Ben', 'server_id': 's2', 'by': 'Holly', 'by_id': 's4'});
    expect(find.text("A7 is Ben's now"), findsOneWidget);
    expect(find.byType(OrderScreen), findsNothing);

    // picking the server who already has it changes nothing
    t.hub.sent.clear();
    await tester.longPress(find.text('A7'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('server:s1')));
    await tester.pumpAndSettle();
    expect(t.hub.sent, isEmpty);
    await stop(tester);
  });

  testWidgets('a server holding a table down, or anyone holding a free one, hands nothing over', (tester) async {
    final t = await pumpFloor(tester, amy);
    await tester.longPress(find.text('A7'));
    await tester.pumpAndSettle();
    expect(find.text('Who serves A7?'), findsNothing);
    t.session.staff = holly;
    await tester.longPress(find.text('A8'));
    await tester.pumpAndSettle();
    expect(find.text('Who serves A8?'), findsNothing);
    expect(t.hub.sent, isEmpty);
    await stop(tester);
  });

  testWidgets('on a hub older than the staff list everyone seats their own tables', (tester) async {
    final t = await pumpFloor(tester, holly, hub: (hub) => hub.roster = null);
    await tester.tap(find.text('A8'));
    await tester.pumpAndSettle();
    expect(find.text('Server'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('seat')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    final (_, data) = sentOne(t.hub, 'create');
    expect((data['server'], data['server_id']), ('Holly', 's4'));
    await stop(tester);
  });
}
