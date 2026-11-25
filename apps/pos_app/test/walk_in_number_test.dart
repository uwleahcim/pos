import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/coursing.dart';
import 'package:pos_app/screens/guest_number_dialog.dart';
import 'package:pos_app/screens/order_screen.dart';

import 'catering_test.dart' show dataOf;
import 'counter_test.dart' show takeout;
import 'customers_test.dart' as customers show linda, lindaDigits;
import 'hub.dart';
import 'table_tags_test.dart' show a7, pumpCheck, said, seven, strip;
import 'tabs_test.dart' show tab;
import 'waitlist_test.dart' show key, tapKey;
import 'who_pays_test.dart' show pumpTable;

/// A walk-in's number at the table (the Toast comparison, 2026-11-25; docs/guest-list.md, "A walk-in's
/// number"): a guest with no reservation leaves a phone number, whoever serves the table types it on the
/// table's check, and the check is that guest's visit in the guest list, where they earn points like
/// anybody (docs/points.md). It is the check's own number, as a to-go order has one: `set_field {phone,
/// customer_name}` with who typed it. A bar tab takes one too, and keeps the name it is called by.

const walker = '7815550142';

/// Linda as the hub knows her at a table: her card, with the points a hub that counts them says.
Map<String, dynamic> lindaCard({Object? points = 240, List<String> tags = const []}) => {
  ...customers.linda(),
  'points': ?points,
  if (tags.isNotEmpty) 'tags': tags,
};

/// A7's check with Linda's number typed on it.
Map<String, dynamic> lindasCheck() => a7({'phone': '781 555 1234', 'customer_name': 'Linda Chen'});

Future<void> type(WidgetTester tester, String box, String text) async {
  await tester.enterText(key(box), text);
  await tester.pumpAndSettle();
}

/// Every `set_field` the hub was sent for the check, as its data.
List<Map<String, dynamic>> typedOn(Hub hub, [String id = 'o1']) => [
  for (final op in hub.opsFor(id))
    if (op['kind'] == 'set_field') (op['data'] as Map).cast<String, dynamic>(),
];

bool enabled(WidgetTester tester, String name) => tester.widget<ButtonStyleButton>(key(name)).onPressed != null;

void main() {
  group('the way in', () {
    testWidgets("a table's check has it under the Allergy chip, in a word, and the seats keep their line", (
      tester,
    ) async {
      await pumpCheck(tester);
      expect(find.descendant(of: key('guest-chip'), matching: find.text('Guest')), findsOneWidget);
      final guest = tester.getRect(key('guest-chip')), allergy = tester.getRect(key('allergy-chip'));
      // under Allergy, in front of the courses
      expect(guest.top >= allergy.bottom, isTrue);
      expect(guest.left, allergy.left);
      expect(guest.right < tester.getRect(find.text('Course  ')).left + 1, isTrue);
      // the seats begin where they did, right after Allergy: a big table loses no seat to it
      expect(tester.getRect(find.text('Seat  ')).left, allergy.right + 10);
      // a walk-in with no number: the strip is not there, as it never was
      expect(key(strip), findsNothing);
      await stop(tester);
    });

    testWidgets('a menu with no courses has one line: it is beside the Allergy chip, before the seats', (tester) async {
      final t = await terminal(tester);
      t.hub
        ..clockNow = seven
        ..orders.add(a7());
      await tester.pumpWidget(
        MaterialApp(
          home: OrderScreen(
            api: t.api,
            outbox: t.outbox,
            photos: t.photos,
            orderId: 'o1',
            staffName: 'Amy',
            coursing: const Coursing(enabled: false),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final guest = tester.getRect(key('guest-chip')), allergy = tester.getRect(key('allergy-chip'));
      expect(guest.left > allergy.right, isTrue);
      expect(guest.right < tester.getRect(find.text('Seat  ')).left + 1, isTrue);
      expect(guest.center.dy, closeTo(allergy.center.dy, 1));
      await stop(tester);
    });

    testWidgets('a to-go order has none: its number is its customer, typed on the form', (tester) async {
      await pumpCheck(
        tester,
        order: takeout('o1', no: 12, name: 'Linda', channel: 'phone'),
      );
      expect(key('guest-chip'), findsNothing);
      await stop(tester);
    });

    testWidgets('a closed check has none, and says the guest it has without a way to change it', (tester) async {
      await pumpCheck(
        tester,
        hub: (hub) => hub.customers[customers.lindaDigits] = lindaCard(),
        order: {...lindasCheck(), 'status': 'closed'},
      );
      expect(key('guest-chip'), findsNothing);
      expect(said(tester, 'check-guest-name'), 'Linda Chen');
      expect(find.descendant(of: key('check-guest'), matching: find.byIcon(Icons.edit_outlined)), findsNothing);
      await tester.tap(key('check-guest'));
      await tester.pumpAndSettle();
      expect(find.byType(GuestNumberDialog), findsNothing);
      await stop(tester);
    });
  });

  group('typing it', () {
    testWidgets('the number and the name go on the check with who typed them, and the check says the guest', (
      tester,
    ) async {
      final t = await pumpCheck(tester);
      await tapKey(tester, 'guest-chip');
      expect(find.text("Guest's number"), findsOneWidget);
      expect(said(tester, 'guest-number-why'), contains('Table A7'));
      expect(key('guest-number-off'), findsNothing); // nothing to take off yet
      expect(enabled(tester, 'guest-number-save'), isFalse);
      await type(tester, 'guest-number-phone', '781 555 0142');
      await type(tester, 'guest-number-name', '  Dana   Whitfield ');
      await tapKey(tester, 'guest-number-save');
      expect(find.byType(GuestNumberDialog), findsNothing);
      expect(typedOn(t.hub), [
        {'phone': '781 555 0142', 'customer_name': 'Dana Whitfield', 'by': 'Amy'},
      ]);
      // the strip under the bar says whose check it is; no number is shown on the screen
      expect(said(tester, 'check-guest-name'), 'Dana Whitfield');
      expect(find.textContaining('0142'), findsNothing);
      // nothing else was sent for it: no dish, no discount, no payment
      expect(t.hub.opsFor('o1').map((op) => op['kind']), ['set_field']);
      await stop(tester);
    });

    testWidgets('under seven digits is no number: it says so and cannot be saved', (tester) async {
      final t = await pumpCheck(tester);
      await tapKey(tester, 'guest-chip');
      await type(tester, 'guest-number-phone', '555 01');
      expect(find.text('At least 7 digits'), findsOneWidget);
      expect(enabled(tester, 'guest-number-save'), isFalse);
      await type(tester, 'guest-number-phone', '555 0142');
      expect(find.text('At least 7 digits'), findsNothing);
      expect(enabled(tester, 'guest-number-save'), isTrue);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(typedOn(t.hub), isEmpty);
      await stop(tester);
    });

    testWidgets('the hub says who is at the number: the name, how often they came, their points and tags', (
      tester,
    ) async {
      final t = await pumpCheck(tester, hub: (hub) => hub.customers[customers.lindaDigits] = lindaCard(tags: ['VIP']));
      await tapKey(tester, 'guest-chip');
      expect(key('guest-number-summary'), findsNothing);
      await type(tester, 'guest-number-phone', '(781) 555-1234');
      expect(said(tester, 'guest-number-summary'), startsWith('12 orders since Mar 2025'));
      expect(said(tester, 'guest-number-points'), 'They have 240 points');
      expect(key('guest-number-tag:VIP'), findsOneWidget);
      // the name she ordered under is filled in, to be saved with the number
      expect(tester.widget<TextField>(key('guest-number-name')).controller!.text, 'Linda Chen');
      await tapKey(tester, 'guest-number-save');
      expect(typedOn(t.hub).single, {'phone': '(781) 555-1234', 'customer_name': 'Linda Chen', 'by': 'Amy'});
      // and the check says her with what she has, her tag beside her
      expect(said(tester, 'check-guest-name'), 'Linda Chen');
      expect(find.descendant(of: key('check-guest-points'), matching: find.text('240 pts')), findsOneWidget);
      expect(key('customer-tag:VIP'), findsOneWidget);
      expect(find.text('Customer note: no MSG, side door'), findsOneWidget);
      await stop(tester);
    });

    testWidgets('a name that was typed is not written over by the one the hub knows', (tester) async {
      final t = await pumpCheck(tester, hub: (hub) => hub.customers[customers.lindaDigits] = lindaCard());
      await tapKey(tester, 'guest-chip');
      await type(tester, 'guest-number-name', 'Lin');
      await type(tester, 'guest-number-phone', '781 555 1234');
      expect(said(tester, 'guest-number-points'), 'They have 240 points');
      expect(tester.widget<TextField>(key('guest-number-name')).controller!.text, 'Lin');
      await tapKey(tester, 'guest-number-save');
      expect(typedOn(t.hub).single['customer_name'], 'Lin');
      await stop(tester);
    });

    testWidgets('a guest with no points yet says so, and where no rate was set nothing is said of points', (
      tester,
    ) async {
      await pumpCheck(tester, hub: (hub) => hub.customers[customers.lindaDigits] = lindaCard(points: 0));
      await tapKey(tester, 'guest-chip');
      await type(tester, 'guest-number-phone', '781 555 1234');
      expect(said(tester, 'guest-number-points'), 'No points yet');
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await stop(tester);

      await pumpCheck(
        tester,
        hub: (hub) => hub.customers[customers.lindaDigits] = lindaCard(points: null),
        order: lindasCheck(),
      );
      expect(said(tester, 'check-guest-name'), 'Linda Chen');
      expect(key('check-guest-points'), findsNothing);
      await tapKey(tester, 'check-guest');
      expect(key('guest-number-summary'), findsOneWidget);
      expect(key('guest-number-points'), findsNothing);
      expect(find.textContaining('point'), findsNothing);
      await stop(tester);
    });

    testWidgets('a number the hub knows nothing of, or no hub answering: it is kept all the same', (tester) async {
      final t = await pumpCheck(tester);
      await tapKey(tester, 'guest-chip');
      await type(tester, 'guest-number-phone', '781 555 0142');
      expect(key('guest-number-summary'), findsNothing);
      await tapKey(tester, 'guest-number-save');
      expect(typedOn(t.hub).single, {'phone': '781 555 0142', 'by': 'Amy'});
      // no name was given: the strip calls them the guest
      expect(said(tester, 'check-guest-name'), 'Guest');
      expect(key('check-guest-points'), findsNothing);
      await stop(tester);
    });
  });

  group('changing it', () {
    testWidgets('a tap on the guest opens the number as it is; another number takes its place', (tester) async {
      final t = await pumpCheck(
        tester,
        hub: (hub) => hub.customers[customers.lindaDigits] = lindaCard(),
        order: lindasCheck(),
      );
      expect(find.descendant(of: key('check-guest'), matching: find.byIcon(Icons.edit_outlined)), findsOneWidget);
      await tapKey(tester, 'check-guest');
      expect(tester.widget<TextField>(key('guest-number-phone')).controller!.text, '781 555 1234');
      expect(tester.widget<TextField>(key('guest-number-name')).controller!.text, 'Linda Chen');
      expect(said(tester, 'guest-number-points'), 'They have 240 points');
      // saved as it is: nothing is sent
      await tapKey(tester, 'guest-number-save');
      expect(typedOn(t.hub), isEmpty);
      // the wrong guest: it was Dana's table
      await tapKey(tester, 'guest-chip');
      await type(tester, 'guest-number-phone', '781 555 0142');
      await type(tester, 'guest-number-name', 'Dana');
      await tapKey(tester, 'guest-number-save');
      expect(typedOn(t.hub).single, {'phone': '781 555 0142', 'customer_name': 'Dana', 'by': 'Amy'});
      expect(said(tester, 'check-guest-name'), 'Dana');
      // Linda's points and her note are not said of Dana
      expect(key('check-guest-points'), findsNothing);
      expect(find.textContaining('Customer note'), findsNothing);
      await stop(tester);
    });

    testWidgets('taken off, the check has no number and no name, and the strip is gone', (tester) async {
      final t = await pumpCheck(
        tester,
        hub: (hub) => hub.customers[customers.lindaDigits] = lindaCard(),
        order: lindasCheck(),
      );
      await tapKey(tester, 'check-guest');
      await tapKey(tester, 'guest-number-off');
      expect(typedOn(t.hub).single, {'phone': null, 'customer_name': null, 'by': 'Amy'});
      expect(key(strip), findsNothing);
      expect(find.descendant(of: key('guest-chip'), matching: find.byIcon(Icons.person_add_alt_1_outlined)), findsOne);
      await stop(tester);
    });

    testWidgets('with the number typed, a table of two parties is not asked who pays: the number does', (tester) async {
      await pumpTable(tester);
      expect(key('seated-who-pays'), findsOneWidget);
      await stop(tester);
      await pumpTable(tester, order: a7({'phone': '781 555 0142', 'customer_name': 'Dana'}));
      expect(key('seated-who-pays'), findsNothing);
      expect(said(tester, 'check-guest-name'), 'Dana');
      expect(said(tester, 'seated-name:0'), 'Linda P.');
      expect(key('seated-payer:0'), findsOneWidget); // a tap on a name still says that party pays
      await stop(tester);
    });
  });

  group('a bar tab', () {
    testWidgets('takes the number alone and keeps the name it is called by', (tester) async {
      final t = await pumpCheck(tester, order: tab('o1', 'Dana'));
      await tapKey(tester, 'guest-chip');
      expect(said(tester, 'guest-number-why'), contains('this tab'));
      expect(key('guest-number-name'), findsNothing);
      await type(tester, 'guest-number-phone', '781 555 0142');
      await tapKey(tester, 'guest-number-save');
      expect(typedOn(t.hub).single, {'phone': '781 555 0142', 'by': 'Amy'});
      expect(said(tester, 'check-guest-name'), 'Guest');
      // taken off again, the tab is still Dana's
      await tapKey(tester, 'check-guest');
      await tapKey(tester, 'guest-number-off');
      expect(typedOn(t.hub).last, {'phone': null, 'by': 'Amy'});
      expect(dataOf(t.hub, 'set_field', 'o1').containsKey('customer_name'), isFalse);
      await stop(tester);
    });

    testWidgets('a number the hub knows: the box and the tab say whose it is, and the tab keeps its name', (
      tester,
    ) async {
      final t = await pumpCheck(
        tester,
        hub: (hub) => hub.customers[customers.lindaDigits] = lindaCard(),
        order: tab('o1', 'Blue jacket'),
      );
      await tapKey(tester, 'guest-chip');
      await type(tester, 'guest-number-phone', '781 555 1234');
      expect(said(tester, 'guest-number-known'), 'Linda Chen'); // there is no name box to say it in
      expect(said(tester, 'guest-number-points'), 'They have 240 points');
      await tapKey(tester, 'guest-number-save');
      expect(typedOn(t.hub).single, {'phone': '781 555 1234', 'by': 'Amy'});
      expect(said(tester, 'check-guest-name'), 'Linda Chen');
      expect(find.text("Blue jacket's tab"), findsOneWidget);
      await stop(tester);
    });
  });

  group('a small phone with large type', () {
    testWidgets('the way in is the sign alone and the seats stay in reach; the box keeps its buttons', (tester) async {
      final t = await pumpCheck(
        tester,
        hub: (hub) => hub.customers[customers.lindaDigits] = lindaCard(tags: ['VIP', 'Catering client']),
        size: const Size(320, 568),
        textScale: 1.3,
      );
      // the menu is the tab a phone opens on; the bar with the seats is there
      expect(find.descendant(of: key('guest-chip'), matching: find.text('Guest')), findsNothing);
      expect(find.descendant(of: key('guest-chip'), matching: find.byIcon(Icons.person_add_alt_1_outlined)), findsOne);
      expect(tester.getRect(find.text('Seat  ')).left < 320, isTrue);
      await tapKey(tester, 'guest-chip');
      await type(tester, 'guest-number-phone', '781 555 1234');
      expect(said(tester, 'guest-number-points'), 'They have 240 points');
      expect(tester.takeException(), isNull);
      for (final name in ['guest-number-save', 'guest-number-phone', 'guest-number-name']) {
        final box = tester.getRect(key(name));
        expect(box.left >= 0 && box.right <= 320, isTrue, reason: name);
      }
      await tapKey(tester, 'guest-number-save');
      expect(typedOn(t.hub).single['phone'], '781 555 1234');
      expect(said(tester, 'check-guest-name'), 'Linda Chen');
      expect(tester.takeException(), isNull);
      // a quarter of the screen at most, as the strip always was
      expect(tester.getSize(key(strip)).height <= 568 / 4, isTrue);
      await stop(tester);
    });
  });
}
