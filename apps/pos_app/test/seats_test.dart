import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/coursing.dart';
import 'package:pos_app/screens/order_screen.dart';
import 'package:pos_app/screens/split_screen.dart';
import 'package:pos_app/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'coursing_test.dart' show pumpLocation;
import 'hub.dart';
import 'location_rows.dart';

/// Seats at a table are the location's to turn off (the owner, 2026-11-27: "In addition to Course the
/// dishes, allow an option to toggle seats for a table"). **Seat numbers** stands under the courses on
/// Location settings, on as it always was. Off, a table's order offers no seats: every dish is the table's,
/// the party's size stands where the seats were (they were where it was set), an allergy is the table's and
/// a check is not split by seat. A dish that is on a seat all the same keeps saying so.

const seatsSwitch = ValueKey('seats-enabled');
const partySize = ValueKey('party-size');

/// The order screen of table A1, a party of two, at a location whose tables have [seats] or not.
Future<Terminal> pumpTable(
  WidgetTester tester, {
  bool seats = false,
  Map<String, dynamic> lines = const {},
  Size? screen,
}) async {
  final t = await terminal(tester);
  if (screen != null) tester.view.physicalSize = screen;
  t.hub.orders.add(table('o1', {...lines}));
  await tester.pumpWidget(
    MaterialApp(
      home: OrderScreen(
        api: t.api,
        outbox: t.outbox,
        photos: t.photos,
        orderId: 'o1',
        session: t.session,
        seats: seats,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return t;
}

Future<void> tap(WidgetTester tester, Finder finder) async {
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// An egg roll from the menu's appetizers.
Future<void> addEggRoll(WidgetTester tester) async {
  await tap(tester, find.byKey(const ValueKey('s:dinner/apps')));
  await tap(tester, find.byKey(const ValueKey('e:dinner:1:EGGROLL')));
}

Map<String, dynamic> lastOp(Terminal t) => t.hub.opsFor('o1').last;
Map<String, dynamic> dataOf(Map<String, dynamic> op) => (op['data'] as Map).cast<String, dynamic>();

bool on(WidgetTester tester) => tester.widget<SwitchListTile>(find.byKey(seatsSwitch)).value;

void main() {
  group('on Location settings', () {
    testWidgets('seat numbers are on to start; a manager turns them off, and on again, with the one Save', (
      tester,
    ) async {
      final t = await pumpLocation(tester);
      await bringUp(tester, 'seats-enabled');
      expect(on(tester), isTrue);
      expect(find.text('Each dish is rung in for a seat, or for the whole table'), findsOneWidget);
      // under the courses, on their card: the two halves of how a table's order is taken
      expect(
        tester.getTopLeft(find.byKey(seatsSwitch)).dy,
        greaterThan(tester.getBottomLeft(find.byKey(const ValueKey('course-add'))).dy),
      );
      expect(saveWaiting(tester), isNull);

      await tap(tester, find.byKey(seatsSwitch));
      expect(on(tester), isFalse);
      expect(
        find.text('Every dish is for the table; the order screen shows no seats, only the size of the party'),
        findsOneWidget,
      );
      expect((t.hub.seats, t.hub.seatsAuth), (true, null), reason: 'nothing is sent before Save');
      expect(saveWaiting(tester), 'Not saved: seats');

      await saveLocation(tester);
      expect((t.hub.seats, t.hub.seatsAuth), (false, 'Bearer tok-admin'));
      expect(find.text('Seats saved'), findsOneWidget);
      expect(saveWaiting(tester), isNull);
      expect(on(tester), isFalse);
      expect(t.hub.coursing['enabled'], isTrue); // the courses are their own switch

      // put back as it was, it waits no longer; flipped and saved, the seats are back
      await tap(tester, find.byKey(seatsSwitch));
      expect(saveWaiting(tester), 'Not saved: seats');
      await tap(tester, find.byKey(seatsSwitch));
      expect(saveWaiting(tester), isNull);
      await tap(tester, find.byKey(seatsSwitch));
      await tester.pump(const Duration(seconds: 5)); // the first "saved" has gone
      await saveLocation(tester);
      expect(t.hub.seats, isTrue);
      await stop(tester);
    });

    testWidgets('the courses and the seats are kept by the same Save, each by itself', (tester) async {
      final t = await pumpLocation(tester);
      await tap(tester, find.byKey(const ValueKey('coursing-enabled')));
      await bringUp(tester, 'seats-enabled');
      await tap(tester, find.byKey(seatsSwitch));
      expect(saveWaiting(tester), 'Not saved: courses, seats');
      await saveLocation(tester);
      expect((t.hub.coursing['enabled'], t.hub.seats), (false, false));
      expect(find.text('Courses and seats saved'), findsOneWidget);
      await stop(tester);
    });

    testWidgets('a hub older than the setting has seats and no switch to flip', (tester) async {
      await pumpLocation(tester, setUp: (hub) => hub.seats = null);
      await bringUp(tester, 'seats-enabled');
      expect(on(tester), isTrue);
      expect(tester.widget<SwitchListTile>(find.byKey(seatsSwitch)).onChanged, isNull);
      expect(find.text('The hub has not answered about the seats (an older hub: update it)'), findsOneWidget);
      await stop(tester);
    });
  });

  group('the setting reaches the order screen', () {
    testWidgets('an order opened after the seats were turned off has none', (tester) async {
      final t = await pumpOrders(tester, [
        table('o1', {'L1': line('Egg roll')}),
      ]);
      t.hub.seats = false;
      await tap(tester, find.text('Table A1'));
      expect(find.byType(OrderScreen), findsOneWidget);
      expect(find.text('Seat  '), findsNothing);
      expect(find.text('Course  '), findsOneWidget); // the courses are their own switch
      expect(tester.widget<Text>(find.byKey(partySize)).data, '2');
      await stop(tester);
    });

    testWidgets('a hub older than the setting, and one that does not answer, leave the seats as they were', (
      tester,
    ) async {
      final t = await pumpOrders(tester, [
        table('o1', {'L1': line('Egg roll')}),
      ]);
      t.hub.seats = null;
      await tap(tester, find.text('Table A1'));
      expect(find.text('Seat  '), findsOneWidget);
      expect(find.byKey(partySize), findsNothing);
      await stop(tester);
    });

    test('the terminal reads it as on from a hub that has no such setting', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final hub = Hub()..seats = null;
      final api = PosApi(
        Settings(device: 't1', endpoints: ['http://hub:8000'], prefs: prefs),
        client: MockClient(hub.handle),
      );
      expect((await api.seats(), await api.seatsSetting()), (true, null));
      hub.seats = false;
      expect((await api.seats(), await api.seatsSetting()), (false, false));
      expect(await api.saveSeats('tok', enabled: true), isTrue);
      expect((hub.seats, hub.seatsAuth), (true, 'Bearer tok'));
    });
  });

  group('a table with no seats', () {
    testWidgets('the bar has no seats: a dish is rung in for the table, and says no seat on the check', (tester) async {
      final t = await pumpTable(tester);
      expect(find.text('Seat  '), findsNothing);
      expect(find.widgetWithText(ChoiceChip, 'Table'), findsNothing);
      expect(find.byTooltip('Add a seat'), findsNothing);
      expect(find.text('Party  '), findsOneWidget);
      expect(find.text('Course  '), findsOneWidget);

      await addEggRoll(tester);
      final added = lastOp(t);
      expect(added['kind'], 'add_line');
      expect(dataOf(added).containsKey('seat'), isFalse);
      expect(dataOf(added)['course'], '1');
      // the quantity stands alone in its box: no "table" under it, and no seat
      final box = find.byKey(ValueKey('qty-${dataOf(added)['line_id']}'));
      expect(
        [for (final text in tester.widgetList<Text>(find.descendant(of: box, matching: find.byType(Text)))) text.data],
        ['1×'],
      );
      expect(find.text('table'), findsNothing);
      expect(find.textContaining('seat '), findsNothing);
      await stop(tester);
    });

    testWidgets('with the seats on, the same check says "table" and the seat, as it always did', (tester) async {
      await pumpTable(
        tester,
        seats: true,
        lines: {
          'L1': line('Egg roll'),
          'L2': {...line('Hot tea'), 'seat': null},
        },
      );
      expect(find.text('Seat  '), findsOneWidget);
      expect(find.byKey(partySize), findsNothing);
      expect(find.text('seat 1'), findsOneWidget);
      expect(find.text('table'), findsOneWidget);
      await stop(tester);
    });

    testWidgets('the party\'s size stands where the seats were, one guest more or fewer by a tap', (tester) async {
      final t = await pumpTable(tester);
      expect(tester.widget<Text>(find.byKey(partySize)).data, '2');

      await tap(tester, find.byTooltip('One guest more'));
      expect(lastOp(t)['kind'], 'set_field');
      expect(dataOf(lastOp(t)), {'guests': 3});
      expect(tester.widget<Text>(find.byKey(partySize)).data, '3');

      await tap(tester, find.byTooltip('One guest fewer'));
      await tap(tester, find.byTooltip('One guest fewer'));
      expect(dataOf(lastOp(t)), {'guests': 1});
      expect(tester.widget<Text>(find.byKey(partySize)).data, '1');
      await stop(tester);
    });

    testWidgets('a dish rung in on a seat before the switch keeps saying so, and holds no guest at the table', (
      tester,
    ) async {
      final t = await pumpTable(
        tester,
        lines: {
          'L1': {...line('Egg roll'), 'seat': 4},
          'L2': {...line('Hot tea'), 'seat': null},
        },
      );
      expect(find.text('seat 4'), findsOneWidget);
      expect(find.text('table'), findsNothing); // the tea is the table's, like every dish here
      // the party is the two the order says, not the four a seat would make it, and can shrink past the dish
      expect(tester.widget<Text>(find.byKey(partySize)).data, '2');
      await tap(tester, find.byTooltip('One guest fewer'));
      expect(dataOf(lastOp(t)), {'guests': 1});
      expect(find.textContaining('still has'), findsNothing);
      await stop(tester);
    });

    testWidgets('with coursing off as well the bar is the allergy, the guest and the party, on one line', (
      tester,
    ) async {
      final t = await terminal(tester);
      t.hub.orders.add(table('o1', const {}));
      await tester.pumpWidget(
        MaterialApp(
          home: OrderScreen(
            api: t.api,
            outbox: t.outbox,
            photos: t.photos,
            orderId: 'o1',
            session: t.session,
            coursing: const Coursing(enabled: false),
            seats: false,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Course  '), findsNothing);
      final allergy = tester.getCenter(find.byKey(const ValueKey('allergy-chip')));
      final guest = tester.getCenter(find.byKey(const ValueKey('guest-chip')));
      final party = tester.getCenter(find.byKey(partySize));
      expect((guest.dy - allergy.dy).abs(), lessThan(2));
      expect((party.dy - allergy.dy).abs(), lessThan(2));
      expect(allergy.dx < guest.dx && guest.dx < party.dx, isTrue);
      await stop(tester);
    });

    testWidgets('on a tablet the guest chip stays on the first line, which has the room now', (tester) async {
      await pumpTable(tester, screen: const Size(1100, 800));
      final guest = tester.getCenter(find.byKey(const ValueKey('guest-chip')));
      final party = tester.getCenter(find.byKey(partySize));
      final course = tester.getCenter(find.text('Course  '));
      expect((guest.dy - party.dy).abs(), lessThan(2));
      expect(course.dy, greaterThan(party.dy + 10)); // the courses keep a line of their own
      await stop(tester);
    });

    testWidgets('on a phone the bar is one line: the courses first, in reach, and the party after them', (
      tester,
    ) async {
      final t = await pumpTable(tester, screen: const Size(360, 640));
      final party = tester.getCenter(find.byKey(partySize));
      final course = tester.getCenter(find.text('Course  '));
      expect((course.dy - party.dy).abs(), lessThan(2));
      // a course is picked for every dish: the courses start on the screen with nothing scrolled, and the
      // party's size, which is changed now and then, comes after the last of them
      expect(tester.getTopRight(find.text('Course  ')).dx, lessThan(360));
      expect(party.dx, greaterThan(tester.getCenter(find.widgetWithText(ChoiceChip, 'Dessert')).dx));
      expect(tester.takeException(), isNull);

      // the party's size is a swipe of the line away
      await tester.ensureVisible(find.byTooltip('One guest more'));
      await tap(tester, find.byTooltip('One guest more'));
      expect(dataOf(lastOp(t)), {'guests': 3});
      await stop(tester);
    });

    testWidgets('an allergy is the table\'s: nothing asks whose it is', (tester) async {
      final t = await pumpTable(tester);
      await tap(tester, find.byKey(const ValueKey('allergy-chip')));
      expect(find.text('The whole table cannot have'), findsOneWidget);
      expect(find.byKey(const ValueKey('allergy-who:0')), findsNothing);
      expect(find.byKey(const ValueKey('allergy-who:1')), findsNothing);
      await tap(tester, find.byKey(const ValueKey('allergen:peanut')));
      await tap(tester, find.byKey(const ValueKey('allergy-save')));
      final told = lastOp(t);
      expect(told['kind'], 'allergy');
      expect(dataOf(told).containsKey('seat'), isFalse);
      expect(dataOf(told)['allergens'], ['peanut']);
      expect(find.text('ALLERGY  Table: Peanuts'), findsOneWidget);
      await stop(tester);
    });

    testWidgets('an allergy noted for a seat before the switch can still be changed and taken off', (tester) async {
      final t = await terminal(tester);
      t.hub.orders.add({
        ...table('o1', const {}),
        'allergies': [
          {
            'seat': 2,
            'allergens': ['sesame'],
            'note': '',
          },
        ],
      });
      await tester.pumpWidget(
        MaterialApp(
          home: OrderScreen(
            api: t.api,
            outbox: t.outbox,
            photos: t.photos,
            orderId: 'o1',
            session: t.session,
            seats: false,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('ALLERGY  Seat 2: Sesame'), findsOneWidget); // never out of sight
      await tap(tester, find.byKey(const ValueKey('allergy-chip')));
      expect(find.byKey(const ValueKey('allergy-who:0')), findsOneWidget);
      await tap(tester, find.byKey(const ValueKey('allergy-who:2')));
      expect(find.text('Seat 2 cannot have'), findsOneWidget);
      await tap(tester, find.byKey(const ValueKey('allergen:sesame')));
      await tap(tester, find.byKey(const ValueKey('allergy-save')));
      expect(dataOf(lastOp(t)), containsPair('seat', 2));
      expect(dataOf(lastOp(t))['allergens'], isEmpty);
      await stop(tester);
    });
  });

  group('splitting the check of a table with no seats', () {
    Order order({int? seat}) => Order(
      orderId: 'o1',
      status: 'open',
      fields: const {'table': '5', 'guests': 2},
      lines: [
        Line(lineId: 'L1', item: 'Tea', qty: 1, seat: seat, status: 'active'),
        const Line(lineId: 'L2', item: 'Duck', qty: 1, status: 'active'),
      ],
      fired: const {},
    );

    Future<void> pumpSplit(WidgetTester tester, Order order, {required bool bySeat}) async {
      tester.view
        ..physicalSize = const Size(390, 800)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: SplitScreen(
            changes: ChangeNotifier(),
            read: () => SplitView(order: order, check: null, billing: false),
            onOps: (ops) async {},
            onBill: (check) async {},
            bySeat: bySeat,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('By seat is not offered, and nothing says to ring dishes in on seats', (tester) async {
      await pumpSplit(tester, order(), bySeat: false);
      expect(find.byKey(const ValueKey('split-by-seat')), findsNothing);
      expect(find.byKey(const ValueKey('split-evenly')), findsOneWidget);
      expect(find.byKey(const ValueKey('split-one')), findsOneWidget);
      expect(find.textContaining('By seat needs'), findsNothing);
      expect(find.textContaining('Tap dishes to pick them'), findsOneWidget);
    });

    testWidgets('with dishes on seats all the same, By seat is still there', (tester) async {
      await pumpSplit(tester, order(seat: 1), bySeat: false);
      expect(find.byKey(const ValueKey('split-by-seat')), findsOneWidget);
    });

    testWidgets('with the seats on it is offered as before, waiting for dishes on seats', (tester) async {
      await pumpSplit(tester, order(), bySeat: true);
      expect(find.byKey(const ValueKey('split-by-seat')), findsOneWidget);
      expect(find.textContaining('By seat needs dishes rung in on seats.'), findsOneWidget);
    });
  });
}
