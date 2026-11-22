import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/floor.dart';
import 'package:pos_app/live.dart';
import 'package:pos_app/roster.dart';
import 'package:pos_app/screens/floor_view.dart';
import 'package:pos_app/screens/server_picker.dart';
import 'package:pos_app/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'floor_test.dart' show floorJson;
import 'hub.dart';
import 'table_servers_test.dart' show amy, holly, mike, pumpFloor, sentOne;

/// Whose turn the next table is (docs/table-servers.md): the mark in the seat dialog, the order of the
/// names, and the dialog a host keeps tonight's turn in.

Finder server(String id) => find.byKey(ValueKey('server:$id'));
Finder nextMark(String id) => find.byKey(ValueKey('turn-next:$id'));
Finder inTurn(String id) => find.byKey(ValueKey('turn:$id'));
final turnButton = find.byKey(const ValueKey('turn-edit'));

/// What the turn dialog says under [id]'s name.
bool says(String id, String words) => find.descendant(of: inTurn(id), matching: find.text(words)).evaluate().isNotEmpty;

/// The staff ids of the buttons [finder] finds, as they stand on the screen: row by row, left to right.
List<String> standing(WidgetTester tester, String prefix) {
  final found = <(Offset, String)>[];
  for (final element in find.byWidgetPredicate((w) => w.key is ValueKey<String>).evaluate()) {
    final key = (element.widget.key! as ValueKey<String>).value;
    if (!key.startsWith(prefix)) continue;
    found.add((tester.getTopLeft(find.byWidget(element.widget)), key.substring(prefix.length)));
  }
  found.sort((a, b) => a.$1.dy != b.$1.dy ? a.$1.dy.compareTo(b.$1.dy) : a.$1.dx.compareTo(b.$1.dx));
  return [for (final (_, id) in found) id];
}

Future<void> openSeat(WidgetTester tester, [String table = 'A8']) async {
  await tester.tap(find.text(table));
  await tester.pumpAndSettle();
}

void main() {
  test('the floor carries tonight\'s turn, and a hub older than the turn carries none', () {
    expect(FloorPlan.fromJson(floorJson()).turn, isNull);
    expect(FloorPlan.fromJson(floorJson()..['turn'] = []).turn, isEmpty);
    final plan = FloorPlan.fromJson(floorJson()..['turn'] = ['s5', 's1']);
    expect(plan.turn, ['s5', 's1']);
    // the turn stays with the plan when a table handed over on this device is drawn before a hub heard
    expect(plan.withServers({'o1': ('Ben', 's2')}).turn, ['s5', 's1']);
  });

  test('the people in the turn stand first, in their order, and the others as the hub lists them', () {
    final servers = Roster.fromJson({'staff': Hub().roster}).servers; // Amy, Ben, Mike
    List<String> names(List<String> turn) => [for (final s in inTurnFirst(servers, turn)) s.name];
    expect(names([]), ['Amy', 'Ben', 'Mike']);
    expect(names(['s3']), ['Mike', 'Amy', 'Ben']);
    expect(names(['s2', 's1']), ['Ben', 'Amy', 'Mike']);
    expect(names(['gone', 's2']), ['Ben', 'Amy', 'Mike']); // somebody the staff list no longer has
  });

  test('a place in the turn is said in a word', () {
    expect(
      [
        for (final place in [1, 2, 3, 4, 11, 12, 13, 21, 22, 23, 101, 111]) placeInTurn(place),
      ],
      ['Next', '2nd', '3rd', '4th', '11th', '12th', '13th', '21st', '22nd', '23rd', '101st', '111th'],
    );
  });

  test('the feed says that the turn changed, and no order is read for it', () {
    expect(const LiveChange(floor: true).toString(), 'LiveChange(floor)');
    expect(const LiveChange(floor: true).anyOrder, isFalse);
  });

  testWidgets('the host sees whose turn it is, and the names stand in the order of the turn', (tester) async {
    final t = await pumpFloor(tester, holly, hub: (hub) => hub.turn = ['s2', 's1']);
    await openSeat(tester);
    expect(standing(tester, 'server:'), ['s2', 's1', 's3']); // Ben, then Amy; Mike is not in it
    expect(nextMark('s2'), findsOneWidget);
    expect(find.descendant(of: server('s2'), matching: find.text('Next')), findsOneWidget);
    expect(find.byType(NextMark), findsOneWidget);

    // It marks and does not pick: the party is sat for whoever the host taps, and passing Ben over is hers.
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('seat'))).onPressed, isNull);
    await tester.tap(server('s1'));
    await tester.pump();
    expect(nextMark('s2'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('seat')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    final (_, data) = sentOne(t.hub, 'create');
    expect((data['server'], data['server_id'], data['by_id']), ('Amy', 's1', 's4'));
    expect(t.hub.turnSaid, isEmpty);
    await stop(tester);
  });

  testWidgets('with nobody said to be on, nothing is marked and the host can say who is', (tester) async {
    final t = await pumpFloor(tester, holly, hub: (hub) => hub.turn = []);
    await openSeat(tester);
    expect(standing(tester, 'server:'), ['s1', 's2', 's3']);
    expect(find.byType(NextMark), findsNothing);
    expect(find.descendant(of: turnButton, matching: find.text("Tonight's turn")), findsOneWidget);

    await tester.tap(turnButton);
    await tester.pumpAndSettle();
    expect(standing(tester, 'turn:'), ['s1', 's2', 's3']);
    expect((says('s1', 'Not in it'), says('s2', 'Not in it'), says('s3', 'Not in it')), (true, true, true));
    expect(find.byKey(const ValueKey('turn-help')), findsOneWidget);

    await tester.tap(inTurn('s2'));
    await tester.pumpAndSettle();
    expect(t.hub.turnSaid.single, {'staff_id': 's4', 'server_id': 's2', 'on': true});
    expect((says('s2', 'Next'), says('s1', 'Not in it')), (true, true));
    expect(standing(tester, 'turn:'), ['s2', 's1', 's3']);
    await tester.tap(inTurn('s1'));
    await tester.pumpAndSettle();
    expect((says('s2', 'Next'), says('s1', '2nd'), says('s3', 'Not in it')), (true, true, true));

    await tester.tap(find.byKey(const ValueKey('turn-done')));
    await tester.pumpAndSettle();
    // back where the party is being sat, with the turn as the hub answered it
    expect(find.text('Seat A8'), findsOneWidget);
    expect(standing(tester, 'server:'), ['s2', 's1', 's3']);
    expect(nextMark('s2'), findsOneWidget);
    await stop(tester);
  });

  testWidgets('somebody cut for the night is taken out with a tap, and the next one is next', (tester) async {
    final t = await pumpFloor(tester, mike, hub: (hub) => hub.turn = ['s1', 's2']);
    await openSeat(tester);
    expect(nextMark('s1'), findsOneWidget);
    await tester.tap(turnButton); // a manager gives tables out too
    await tester.pumpAndSettle();
    expect((says('s1', 'Next'), says('s2', '2nd')), (true, true));
    await tester.tap(inTurn('s1'));
    await tester.pumpAndSettle();
    expect(t.hub.turnSaid.single, {'staff_id': 's3', 'server_id': 's1', 'on': false});
    expect((says('s1', 'Not in it'), says('s2', 'Next')), (true, true));
    // tapping outside closes it like Done: what the hub answered is already on the seat dialog
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.text("Tonight's turn"), findsOneWidget); // only the button's own words
    expect(nextMark('s2'), findsOneWidget);
    expect(nextMark('s1'), findsNothing);
    await stop(tester);
  });

  testWidgets('a word the hub refuses changes nothing and says why', (tester) async {
    final t = await pumpFloor(
      tester,
      holly,
      hub: (hub) => hub
        ..turn = ['s1']
        ..refuseTurn = 'Whoever gives tables out says who is in the turn.',
    );
    await openSeat(tester);
    await tester.tap(turnButton);
    await tester.pumpAndSettle();
    await tester.tap(inTurn('s2'));
    await tester.pumpAndSettle();
    expect(find.text('Whoever gives tables out says who is in the turn.'), findsOneWidget);
    expect(find.byKey(const ValueKey('turn-problem')), findsOneWidget);
    expect((says('s1', 'Next'), says('s2', 'Not in it')), (true, true));

    // with the hub gone the turn stays as it is: it is kept there, not on this screen
    t.hub
      ..refuseTurn = null
      ..down = true;
    await tester.tap(inTurn('s2'));
    await tester.pumpAndSettle(const Duration(seconds: 3));
    expect(find.text('The hub cannot be reached, and the turn is kept there. Try again in a moment.'), findsOneWidget);
    expect(says('s2', 'Not in it'), isTrue);
    expect(t.hub.turnSaid, isEmpty);

    t.hub.down = false;
    await tester.tap(inTurn('s2'));
    await tester.pumpAndSettle(const Duration(seconds: 3));
    expect(find.byKey(const ValueKey('turn-problem')), findsNothing);
    expect(says('s2', '2nd'), isTrue);
    await stop(tester);
  });

  testWidgets('a hub older than the turn seats a party as it always did', (tester) async {
    await pumpFloor(tester, holly);
    await openSeat(tester);
    expect(find.text('Server'), findsOneWidget);
    expect(turnButton, findsNothing);
    expect(find.byType(NextMark), findsNothing);
    expect(standing(tester, 'server:'), ['s1', 's2', 's3']);
    await stop(tester);
  });

  testWidgets('a server who opens her own table is asked nothing about the turn', (tester) async {
    await pumpFloor(tester, amy, hub: (hub) => hub.turn = ['s1', 's2']);
    await openSeat(tester);
    expect(find.text('Seat A8'), findsOneWidget);
    expect(find.text('Server'), findsNothing);
    expect(turnButton, findsNothing);
    expect(find.byType(NextMark), findsNothing);
    await stop(tester);
  });

  testWidgets('handing a seated table over is nobody\'s turn', (tester) async {
    await pumpFloor(tester, holly, hub: (hub) => hub.turn = ['s2', 's1']);
    await tester.longPress(find.text('A7'));
    await tester.pumpAndSettle();
    expect(find.text('Who serves A7?'), findsOneWidget);
    expect(find.byType(NextMark), findsNothing);
    expect(standing(tester, 'server:'), ['s1', 's2', 's3']);
    await stop(tester);
  });

  testWidgets('on a small phone the names, the mark and the turn dialog all fit', (tester) async {
    await pumpFloor(
      tester,
      holly,
      hub: (hub) => hub
        ..roster = [
          ...hub.roster!,
          {'staff_id': 's5', 'name': 'Bartholomew', 'role': 'server', 'takes_tables': true, 'assigns_tables': false},
          {'staff_id': 's6', 'name': 'Dan', 'role': 'server', 'takes_tables': true, 'assigns_tables': false},
        ]
        ..turn = ['s5', 's1', 's6'],
    );
    tester.view
      ..physicalSize = const Size(320, 568)
      ..devicePixelRatio = 1;
    await tester.pumpAndSettle();
    await openSeat(tester);
    expect(tester.takeException(), isNull);
    expect(nextMark('s5'), findsOneWidget);
    expect(standing(tester, 'server:').take(3), ['s5', 's1', 's6']);
    await tester.tap(turnButton);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect((says('s5', 'Next'), says('s1', '2nd'), says('s6', '3rd')), (true, true, true));
    await stop(tester);
  });

  testWidgets('the floor map reads the turn again when the hub says it changed', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final settings = Settings(
      device: 't1',
      endpoints: ['http://hub:8000'],
      prefs: await SharedPreferences.getInstance(),
    );
    final hub = Hub()
      ..floor = floorJson()
      ..turn = [];
    final live = LiveHub(hub);
    final api = PosApi(settings, client: live.client);
    tester.view
      ..physicalSize = const Size(1200, 900)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    api.live.start();
    FloorPlan? tapped;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FloorView(api: api, onTable: (plan, table) => tapped = plan),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    live.hello();
    live.beats();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(api.live.isLive, isTrue);
    await tester.tap(find.text('A8'));
    expect(tapped!.turn, isEmpty);

    hub.turn = ['s1']; // a host at another screen put Amy in, or she clocked in
    live.changed(topics: ['floor']);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1)); // told reads are a second apart at the least
    await tester.pump();
    await tester.pump();
    await tester.tap(find.text('A8'));
    expect(tapped!.turn, ['s1']);

    await stop(tester);
    live.close();
    api.dispose();
  });
}
