import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/floor.dart';
import 'package:pos_app/roster.dart';
import 'package:pos_app/screens/floor_view.dart';
import 'package:pos_app/screens/theme.dart';
import 'package:pos_app/seated.dart';
import 'package:pos_app/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'customers_test.dart' show tagsIn;
import 'floor_test.dart' show floorJson, roomy;
import 'hub.dart';
import 'table_moves_test.dart' show floorThatMoves, seated;
import 'table_tags_test.dart' show linda, omar, seatedBooking, seatedParty, seven;

/// Guests on the floor map (the Toast comparison, 2026-11-24): a table the host seated a party at, from its
/// reservation or from the waitlist, says on the map whose table it is, by the party's name, with a star
/// when a guest of it carries a tag in the guest list ("VIP"). The hub tells the map with the floor
/// (`seated` of `GET /floor`: by the id of each open check, its parties by name and tags); the number and
/// the note are not told, and the check itself carries none of it. A walk-in's table says nothing.

Finder key(String name) => find.byKey(ValueKey(name));

/// What a table says of who sits there ("Chen", "Omar +1"); null for a table that names nobody.
String? named(WidgetTester tester, String table) => key('table-guest:$table').evaluate().isEmpty
    ? null
    : tester.widget<Text>(find.descendant(of: key('table-guest:$table'), matching: find.byType(Text))).data;

bool starred(WidgetTester tester, String table) => key('table-guest-tagged:$table').evaluate().isNotEmpty;

/// Whether [part] of a table turned on its corner (a square at 45 degrees, as A7 is) lies inside the table's
/// own edge, not only inside the square the map keeps for it.
bool insideItsDiamond(WidgetTester tester, String table, Finder part) {
  final square = tester.getRect(key('table-look:$table'));
  final rect = tester.getRect(part);
  final reach = square.width / math.sqrt2;
  return [rect.topLeft, rect.topRight, rect.bottomLeft, rect.bottomRight].every((corner) {
    final from = corner - square.center;
    return from.dx.abs() + from.dy.abs() <= reach;
  });
}

const amyOnStaff = StaffMember(staffId: 's1', name: 'Amy', role: 'server', takesTables: true);

/// The map by itself at seven in the evening, on a hub that [setUp] prepared: A7 is seated (the check
/// `o1`, Amy's, four guests) and so is whatever [more] seats.
Future<Hub> pumpMap(
  WidgetTester tester, {
  void Function(Hub hub)? setUp,
  Map<String, List<Map<String, dynamic>>> more = const {},
  Size size = roomy,
  double textScale = 1,
  bool dark = false,
  StaffMember? me,
  bool mine = false,
}) async {
  final hub = Hub()
    ..clockNow = seven
    ..floor = floorThatMoves(more)
    ..bookings = []
    ..parties = [];
  setUp?.call(hub);
  final api = PosApi(
    Settings(device: 't1', endpoints: ['http://hub:8000']),
    client: MockClient(hub.handle),
  );
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(const SizedBox());
  await tester.pumpWidget(
    MaterialApp(
      theme: PosTheme.light(),
      darkTheme: PosTheme.dark(),
      themeMode: dark ? ThemeMode.dark : ThemeMode.light,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(
        body: FloorView(api: api, onTable: (plan, table) {}, now: () => seven, me: me, mine: mine),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return hub;
}

/// Linda (a VIP) booked a table and sits at A7, on the check `o1`.
void lindaAtA7(Hub hub) => hub
  ..ringTags = {
    linda: ['Catering client', 'VIP'],
  }
  ..bookings = [seatedBooking('b1', 'Linda P.', linda, 'o1', note: 'Window table, birthday')];

void main() {
  group('the plan', () {
    test('who sits at a table is read by its check, the first to sit first', () {
      final hub = Hub()
        ..floor = floorThatMoves({
          'B5': [seated('o2', 'Ben', 's2')],
        })
        ..ringTags = {
          linda: ['VIP'],
        }
        ..bookings = [seatedBooking('b1', 'Linda P.', linda, 'o1', note: 'Window table', seatedMs: seven + 60000)]
        ..parties = [
          seatedParty('p1', 'Omar', omar, 'o1'),
          seatedParty('p2', 'Wu', '', 'o9'), // seated with a check that is on no table of the floor
        ];
      final told = hub.floorSeated;
      expect(told, {
        'o1': [
          {'name': 'Omar', 'tags': <String>[]},
          {
            'name': 'Linda P.',
            'tags': ['VIP'],
          },
        ],
      });
      // by name and tags alone: no number and no note
      expect('$told', isNot(contains('781')));
      expect('$told', isNot(contains('Window')));

      final plan = FloorPlan.fromJson({...hub.floor!, 'seated': told});
      expect(plan.guestsAt('A7'), const [
        SeatedParty(name: 'Omar'),
        SeatedParty(name: 'Linda P.', tags: ['VIP']),
      ]);
      expect(plan.guestsAt('B5'), isEmpty); // a walk-in
      expect(plan.guestsAt('A8'), isEmpty); // a free table
      expect(plan.guestsOf(plan.checksAt('A7')), plan.guestsAt('A7'));
      // a check that moved to another table on this device takes its party with it
      expect(plan.withTables({'o1': 'A8'}, const {}).guestsAt('A8').map((party) => party.name), ['Omar', 'Linda P.']);
    });

    test('a hub older than it names nobody, and what it sends is read with care', () {
      expect(FloorPlan.fromJson(floorJson()).seated, isEmpty);
      expect(FloorPlan.fromJson(floorJson()).guestsAt('A7'), isEmpty);
      final plan = FloorPlan.fromJson({
        ...floorJson(),
        'seated': {
          'o1': [
            {
              'name': '  Chen  ',
              'tags': ['VIP', '', 7],
            },
            {'name': '', 'tags': <String>[]}, // nothing to show
            'not a party',
          ],
          'o2': 'not a list',
          'o3': <Object>[],
        },
      });
      expect(plan.seated, {
        'o1': const [
          SeatedParty(name: 'Chen', tags: ['VIP']),
        ],
      });
      expect(FloorPlan.fromJson({...floorJson(), 'seated': 'nobody'}).seated, isEmpty);
    });

    test('in words, for a screen reader', () {
      expect(
        guestsInWords(const [
          SeatedParty(name: 'Linda P.', tags: ['Catering client', 'VIP']),
          SeatedParty(name: 'Omar'),
        ]),
        'Linda P., tagged Catering client, VIP; Omar',
      );
      expect(guestsInWords(const [SeatedParty(name: 'Wu')]), 'Wu');
    });
  });

  group('on the map', () {
    testWidgets('a table seated from a reservation says whose it is, with a star for a tagged guest', (tester) async {
      await pumpMap(
        tester,
        setUp: lindaAtA7,
        more: {
          'B5': [seated('o2', 'Ben', 's2')],
        },
      );
      expect(named(tester, 'A7'), 'Linda P.');
      expect(starred(tester, 'A7'), isTrue);
      // the tags by name and the reservation's note are the check's to say, not the map's
      expect(find.text('VIP'), findsNothing);
      expect(find.textContaining('Window'), findsNothing);
      // a screen reader is told the tags too
      expect(
        tester.widget<Text>(find.descendant(of: key('table-guest:A7'), matching: find.byType(Text))).semanticsLabel,
        'seated here: Linda P., tagged Catering client, VIP',
      );
      // the table still says what it said: its server, its party and what it ran up
      expect(find.descendant(of: key('table-server:A7'), matching: find.text('Amy')), findsOne);
      expect(find.textContaining('4p'), findsOneWidget);
      expect(find.text('\$36.86'), findsOneWidget);
      // a walk-in's table and a free one name nobody
      expect((named(tester, 'B5'), starred(tester, 'B5')), (null, false));
      expect((named(tester, 'A8'), starred(tester, 'A8')), (null, false));
      await stop(tester);
    });

    testWidgets('a party from the waitlist is named the same way, and one nobody tagged has no star', (tester) async {
      await pumpMap(
        tester,
        setUp: (hub) => hub
          ..ringTags = {}
          ..parties = [seatedParty('p1', 'Omar', omar, 'o1', note: 'High chair')],
      );
      expect((named(tester, 'A7'), starred(tester, 'A7')), ('Omar', false));
      await stop(tester);
    });

    testWidgets('two parties at one table: the first by name, "+1", and a star if either carries a tag', (
      tester,
    ) async {
      await pumpMap(
        tester,
        setUp: (hub) => hub
          ..ringTags = {
            linda: ['VIP'],
          }
          ..parties = [seatedParty('p1', 'Omar', omar, 'o1')]
          ..bookings = [seatedBooking('b1', 'Linda P.', linda, 'o1', seatedMs: seven + 60000)],
      );
      expect((named(tester, 'A7'), starred(tester, 'A7')), ('Omar +1', true));
      expect(
        tester.widget<Text>(find.descendant(of: key('table-guest:A7'), matching: find.byType(Text))).semanticsLabel,
        'seated here: Omar; Linda P., tagged VIP',
      );
      await stop(tester);
    });

    testWidgets('a long name is cut, and makes the table\'s own name no smaller than a short one does', (tester) async {
      await pumpMap(tester, setUp: (hub) => hub..bookings = [seatedBooking('b1', 'Wu', '', 'o1')]);
      expect(named(tester, 'A7'), 'Wu');
      final short = tester.getSize(find.text('A7'));
      await stop(tester);
      await pumpMap(tester, setUp: (hub) => hub..bookings = [seatedBooking('b1', 'Papadopoulos-Chen', '', 'o1')]);
      expect(named(tester, 'A7'), 'Papadopo…');
      expect(tester.getSize(find.text('A7')), short);
      await stop(tester);
    });

    testWidgets('on a table turned on its corner the name stands in the middle, inside the table\'s own edge', (
      tester,
    ) async {
      await pumpMap(
        tester,
        setUp: (hub) => hub
          ..ringTags = {
            linda: ['VIP'],
          }
          ..bookings = [seatedBooking('b1', 'Papadopoulos-Chen', linda, 'o1')]
          ..parties = [seatedParty('p1', 'Omar', omar, 'o1', seatedMs: seven + 60000)],
      );
      expect((named(tester, 'A7'), starred(tester, 'A7')), ('Papadopo… +1', true));
      expect(insideItsDiamond(tester, 'A7', key('table-guest:A7')), isTrue);
      expect(insideItsDiamond(tester, 'A7', key('table-guest-tagged:A7')), isTrue);
      // it stands under the server's name and over the party's size and what the table ran up
      final name = tester.getRect(key('table-guest:A7'));
      expect(tester.getRect(key('table-server:A7')).bottom <= name.top + 0.5, isTrue);
      expect(name.bottom <= tester.getRect(find.textContaining('4p')).top + 0.5, isTrue);
      await stop(tester);
    });

    testWidgets('a table that is seated and booked again says both: who sits, and the time to come', (tester) async {
      await pumpMap(
        tester,
        setUp: (hub) {
          lindaAtA7(hub);
          hub.bookings!.add(Hub.booking('b2', 'Chen', 4, time: '19:30', table: 'A7', atMs: seven + 30 * 60000));
        },
      );
      expect(named(tester, 'A7'), 'Linda P.');
      expect(key('table-hold:A7'), findsOneWidget);
      expect(tester.takeException(), isNull);
      // the name stands over the booking, inside the table
      final table = tester.getRect(key('table-look:A7'));
      final name = tester.getRect(key('table-guest:A7'));
      expect(name.bottom <= tester.getRect(key('table-hold:A7')).top + 0.5, isTrue);
      expect(table.contains(name.topLeft) && table.contains(name.bottomRight), isTrue);
      await stop(tester);
    });

    testWidgets('a hub older than it: the map is as it was', (tester) async {
      final hub = await pumpMap(
        tester,
        setUp: (hub) {
          lindaAtA7(hub);
          hub.seatedOnFloor = false;
        },
      );
      expect((named(tester, 'A7'), starred(tester, 'A7')), (null, false));
      expect(find.descendant(of: key('table-server:A7'), matching: find.text('Amy')), findsOne);
      // it is told with the floor: the map asks nothing more of the hub for it
      expect(hub.seatedAsks, isEmpty);
      expect(hub.tableTagAsks, isEmpty);
      await stop(tester);
    });

    testWidgets('who sits is told with the floor: the map asks no other call for it', (tester) async {
      final hub = await pumpMap(tester, setUp: lindaAtA7);
      expect(named(tester, 'A7'), 'Linda P.');
      expect(hub.seatedAsks, isEmpty);
      expect(hub.tableTagAsks, isEmpty);
      expect(
        hub.requests.where((request) => request.contains('/customers') || request.contains('/reservations')),
        isEmpty,
      );
      await stop(tester);
    });

    testWidgets('"Mine", beside the map: each of my tables says whose it is and the tags by name', (tester) async {
      await pumpMap(
        tester,
        setUp: (hub) => hub
          ..ringTags = {
            linda: ['Catering client', 'VIP'],
            omar: ['Regular'],
          }
          ..bookings = [seatedBooking('b1', 'Linda P.', linda, 'o1')]
          ..parties = [
            seatedParty('p1', 'Omar', omar, 'o1', seatedMs: seven + 60000),
            seatedParty('p2', 'Wu', '', 'o3'),
          ],
        more: {
          'A4': [seated('o3', 'Amy', 's1')],
          'B5': [seated('o2', 'Ben', 's2')],
        },
        me: amyOnStaff,
        mine: true,
      );
      expect(key('my-tables'), findsOneWidget);
      final a7 = key('my-table-guests:A7');
      expect(find.descendant(of: a7, matching: find.text('Linda P.')), findsOne);
      expect(find.descendant(of: a7, matching: find.text('Omar')), findsOne);
      expect(tagsIn(tester, 'my-table-guests:A7'), ['Catering client', 'VIP', 'Regular']);
      // a party nobody tagged is named with no label, and a table of somebody else is not in the list
      expect(find.descendant(of: key('my-table-guests:A4'), matching: find.text('Wu')), findsOne);
      expect(tagsIn(tester, 'my-table-guests:A4'), isEmpty);
      expect(key('my-table-guests:B5'), findsNothing);
      expect(tester.takeException(), isNull);
      await stop(tester);
    });

    testWidgets('a walk-in of mine has no line for it in the list', (tester) async {
      await pumpMap(tester, me: amyOnStaff, mine: true);
      expect(key('my-table:A7'), findsOneWidget);
      expect(key('my-table-guests:A7'), findsNothing);
      await stop(tester);
    });

    testWidgets('on a small phone, in the dark and with large type: the table says less, and keeps the star and '
        'the booking as marks on its edge', (tester) async {
      for (final (dark, scale) in [(false, 1.0), (true, 1.0), (false, 1.5)]) {
        await pumpMap(
          tester,
          size: const Size(320, 568),
          dark: dark,
          textScale: scale,
          setUp: (hub) {
            hub
              ..ringTags = {
                linda: ['VIP'],
              }
              ..bookings = [
                seatedBooking('b1', 'Papadopoulos-Chen', linda, 'o1'),
                Hub.booking('b2', 'Chen', 4, time: '19:30', table: 'A7', atMs: seven + 30 * 60000),
              ]
              ..parties = [seatedParty('p1', 'Omar', omar, 'o1', seatedMs: seven + 60000)];
          },
        );
        expect(tester.takeException(), isNull, reason: 'dark $dark, type $scale');
        // The whole floor on a phone this small: a table has the room for its own name, inside its own
        // edge, and nothing else is squeezed in beside it (test/floor_readable_test.dart has the sizes).
        final name = tester.getRect(find.text('A7'));
        expect(insideItsDiamond(tester, 'A7', find.text('A7')), isTrue, reason: 'dark $dark, type $scale');
        expect(named(tester, 'A7'), isNull);
        expect(key('table-server:A7'), findsNothing);
        // Who sits there carries a tag, and the table is wanted at half past seven: both stay on the map, as
        // marks on the table's edge that leave its name alone.
        expect(starred(tester, 'A7'), isTrue);
        expect(key('table-hold:A7'), findsOneWidget);
        final table = tester.getRect(key('table-look:A7')).inflate(6);
        for (final part in ['table-guest-tagged:A7', 'table-hold:A7']) {
          final rect = tester.getRect(key(part));
          expect(table.contains(rect.topLeft) && table.contains(rect.bottomRight), isTrue, reason: '$part, $scale');
          expect(rect.overlaps(name.deflate(1.5)), isFalse, reason: '$part, $scale');
        }
        await stop(tester);
      }
    });
  });

  group('told by the hub', () {
    testWidgets('a party sits down, a tag is put on, a party is put back: the map follows at once', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final settings = Settings(
        device: 't1',
        endpoints: ['http://hub:8000'],
        prefs: await SharedPreferences.getInstance(),
      );
      final hub = Hub()
        ..clockNow = seven
        ..floor = floorThatMoves()
        ..ringTags = {}
        ..bookings = []
        ..parties = [];
      final live = LiveHub(hub);
      final api = PosApi(settings, client: live.client);
      tester.view
        ..physicalSize = roomy
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      api.live.start();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FloorView(api: api, onTable: (plan, table) {}, now: () => seven),
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
      expect(named(tester, 'A7'), isNull);

      Future<void> told() async {
        await tester.pump();
        await tester.pump(const Duration(seconds: 1)); // the map reads at most once a second
        await tester.pump();
      }

      // the host seats a party of the waitlist on A7's check: the hub says the list changed
      hub.parties!.add(seatedParty('p1', 'Omar', omar, 'o1'));
      live.changed(topics: ['waitlist']);
      await told();
      expect((named(tester, 'A7'), starred(tester, 'A7')), ('Omar', false));

      // a manager tags him in the guest list: the hub tells the book and the list to read again
      hub.ringTags![omar] = ['Regular'];
      live.changed(topics: ['reservations', 'waitlist']);
      await told();
      expect((named(tester, 'A7'), starred(tester, 'A7')), ('Omar', true));

      // he is put back on the list: nobody is named at the table
      hub.parties!.clear();
      live.changed(topics: ['waitlist']);
      await told();
      expect((named(tester, 'A7'), starred(tester, 'A7')), (null, false));

      await stop(tester);
      live.close();
      api.dispose();
      await tester.pump();
    });
  });
}
