import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/customers.dart';
import 'package:pos_app/phone.dart';
import 'package:pos_app/screens/order_screen.dart';

import 'counter_test.dart';
import 'phone_test.dart';

/// A customer per phone number (the Toast comparison, 2026-11-15): the to-go form shows who is at the number
/// the moment a call is answered or a number is typed, with the note kept about them and their past orders;
/// Same again starts the new order with a past order's dishes; the note shows on the order's screen.

const lindaDigits = '7815551234';
final day = DateTime(2026, 11, 15, 18, 0);
int ms(int year, int month, int d) => DateTime(year, month, d, 18, 30).millisecondsSinceEpoch;

/// Linda as the hub knows her: twelve orders since March of last year, a note, and her two latest orders.
Map<String, dynamic> linda({String note = 'no MSG, side door'}) => {
  'phone': lindaDigits,
  'known': true,
  'name': 'Linda Chen',
  'note': note,
  'orders': 12,
  'first_ms': ms(2025, 3, 9),
  'last_ms': ms(2026, 11, 3),
  'recent': [
    {
      'order_id': 'p2',
      'opened_ms': ms(2026, 11, 3),
      'order_no': 41,
      'status': 'closed',
      'channel': 'phone',
      'total': '42.80',
      'items': [
        {'qty': 2, 'item': "General Tso's Chicken (Qt)"},
        {'qty': 1, 'item': 'California roll'},
        {'qty': 1, 'item': 'California roll'},
      ],
    },
    {
      'order_id': 'p1',
      'opened_ms': ms(2026, 10, 20),
      'order_no': 17,
      'status': 'closed',
      'channel': 'phone',
      'total': '18.20',
      'items': [
        {'qty': 1, 'item': 'Egg roll'},
      ],
    },
  ],
};

const gtc = {
  'variant_id': 'GTC:qt',
  'entry_id': 'dinner:87',
  'selections': [
    {'group_id': 'rice', 'option_id': 'rice:brown'},
  ],
};
const roll = {'variant_id': 'CALROLL:roll', 'selections': <Object>[]};

/// What the hub answers for "same again" on Linda's latest order: the chicken costs a dollar more now, the
/// rolls are as they were, and the candle that was typed in is left off.
const againP2 = {
  'order_id': 'p2',
  'lines': [
    {
      'item': "General Tso's Chicken (Qt)",
      'qty': 2,
      'note': 'extra crispy',
      'request': gtc,
      'unit_price': '13.95',
      'was': '12.95',
    },
    {'item': 'California roll', 'qty': 1, 'note': '', 'request': roll, 'unit_price': '6.50', 'was': '6.50'},
  ],
  'missing': [
    {'item': 'Birthday candle', 'qty': 1, 'why': 'It was typed in, not picked from the menu.'},
  ],
};

String text(WidgetTester tester, String key) => tester.widget<TextField>(find.byKey(ValueKey(key))).controller!.text;

/// The form, opened from the To go button, with [phone] typed and the hub asked about it.
Future<void> typeNumber(WidgetTester tester, String phone) async {
  await tester.enterText(find.byKey(const ValueKey('takeout-phone')), phone);
  await tester.pump(const Duration(milliseconds: 500)); // the typing pauses
  await tester.pumpAndSettle();
}

Future<void> openForm(WidgetTester tester) async {
  await tester.tap(find.text('To go'));
  await tester.pumpAndSettle();
  expect(find.text('To-go order'), findsOneWidget);
}

void main() {
  group('what the hub knows of a customer', () {
    test('a number is matched by its digits, without the 1 in front', () {
      expect(phoneDigits('+1 (781) 555-1234'), lindaDigits);
      expect(phoneDigits('781.555.1234'), lindaDigits);
      expect(phoneDigits('12'), '12');
      expect(phoneDigits(null), '');
    });

    test('the card reads how often they ordered, since when, and what they had', () {
      final card = CustomerCard.fromJson(linda());
      expect((card.known, card.name, card.note, card.orders), (true, 'Linda Chen', 'no MSG, side door', 12));
      expect(card.summary(day), '12 orders since Mar 2025, the last on 3 Nov');
      expect(card.recent.map((o) => o.orderId), ['p2', 'p1']);
      // the same dish rung twice is counted together
      expect(card.recent.first.dishes, "2 General Tso's Chicken (Qt), 2 California roll");
      expect(card.recent.last.dishes, 'Egg roll');

      final once = CustomerCard.fromJson({
        ...linda(),
        'orders': 1,
        'first_ms': ms(2026, 11, 14),
        'last_ms': ms(2026, 11, 14),
      });
      expect(once.summary(day), '1 order, yesterday');
      final never = CustomerCard.fromJson({'phone': '7815550155', 'known': false});
      expect(never.summary(day), 'No orders from this number yet');
      expect(never.recent, isEmpty);
    });

    test('a day is said as people say it', () {
      expect(dayLabel(ms(2026, 11, 15), day), 'today');
      expect(dayLabel(ms(2026, 11, 14), day), 'yesterday');
      expect(dayLabel(ms(2026, 11, 3), day), '3 Nov');
      expect(dayLabel(ms(2025, 12, 31), day), '31 Dec 2025');
    });

    test('same again says what went on, which prices moved and what was left off', () {
      final again = Again.fromJson(againP2);
      expect(again.lines.map((l) => (l.item, l.qty, l.priceMoved)), [
        ("General Tso's Chicken (Qt)", 2, true),
        ('California roll', 1, false),
      ]);
      expect(
        again.said,
        'Same again: 3 dishes added. '
        "General Tso's Chicken (Qt) is \$13.95 now, was \$12.95. "
        'NOT added: Birthday candle. It was typed in, not picked from the menu.',
      );
      expect(again.needsTelling, isTrue);

      final plain = Again.fromJson({
        'lines': [(againP2['lines'] as List)[1]],
        'missing': <Object>[],
      });
      expect((plain.said, plain.needsTelling), ('Same again: 1 dish added.', false));
      final none = Again.fromJson({
        'lines': <Object>[],
        'missing': [
          {'item': 'California roll', 'qty': 2, 'why': 'It is sold out today.'},
        ],
      });
      expect(none.said, 'Nothing was added. NOT added: 2 California roll. It is sold out today.');

      // choices kept in a shape this app cannot draw: the dish is left off and named, not put on the check
      final old = Again.fromJson({
        'lines': [
          {
            'item': 'Old dish',
            'qty': 1,
            'request': {
              'variant_id': 'OLD:1',
              'selections': [
                {'group_id': 'x'},
              ],
            },
          },
        ],
      });
      expect(old.lines, isEmpty);
      expect(old.said, 'Nothing was added. NOT added: Old dish. Its choices could not be read. Ring it in by hand.');
    });
  });

  group('on the to-go form', () {
    late FakeStack stack;
    late PhoneClient phone;

    setUp(() async {
      stack = FakeStack();
      phone = PhoneClient(stack, clock: () => day);
      await phone.apply(active);
      stack.events!.registered();
    });

    testWidgets('a caller the restaurant knows is on screen the moment the call is answered', (tester) async {
      final t = await pumpOrders(
        tester,
        const [],
        phone: phone,
        before: (hub) async => hub.customers[lindaDigits] = linda(),
      );
      stack.events!.incomingCall('c1', number: '+17815551234', name: 'WIRELESS CALLER');
      await tester.pump();
      phone.answer();
      stack.events!.callAccepted('c1');
      await tester.pumpAndSettle();

      expect(find.text('To-go order'), findsOneWidget);
      expect(t.hub.customersAsked, [lindaDigits]);
      expect(text(tester, 'takeout-name'), 'Linda Chen'); // the name on her orders, not the trunk's
      expect(text(tester, 'takeout-phone'), '781 555 1234');
      expect(find.byKey(const ValueKey('customer-card')), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('customer-summary'))).data,
        startsWith('12 orders since Mar 2025'),
      );
      expect(text(tester, 'customer-note'), 'no MSG, side door');
      expect(find.byKey(const ValueKey('customer-note-save')), findsNothing); // nothing changed, nothing to save
      expect(find.text("2 General Tso's Chicken (Qt), 2 California roll"), findsOneWidget);
      expect(find.textContaining('\$42.80'), findsOneWidget);
      expect(find.text('Egg roll'), findsOneWidget);
      expect(find.text('Same again'), findsNWidgets(2));
      await stop(tester);
    });

    testWidgets('Same again starts the order with those dishes and says what changed', (tester) async {
      final t = await pumpOrders(
        tester,
        const [],
        before: (hub) async {
          hub.customers[lindaDigits] = linda();
          hub.again['p2'] = againP2;
        },
      );
      await openForm(tester);
      await typeNumber(tester, '781 555 1234');
      expect(text(tester, 'takeout-name'), 'Linda Chen'); // nothing was typed there: hers fills it

      await tester.ensureVisible(find.byKey(const ValueKey('again:p2')));
      await tester.tap(find.byKey(const ValueKey('again:p2')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();

      final kinds = [for (final (_, op) in t.hub.sent) op['kind']];
      expect(kinds, ['create', 'add_line', 'add_line']);
      final ops = [for (final (_, op) in t.hub.sent) op['data'] as Map<String, dynamic>];
      expect(
        (ops[0]['customer_name'], ops[0]['phone'], ops[0]['order_type']),
        ('Linda Chen', '781 555 1234', 'takeout'),
      );
      expect(ops[1]['item'], "General Tso's Chicken (Qt)");
      expect(ops[1]['qty'], 2);
      expect(ops[1]['note'], 'extra crispy');
      expect(ops[1]['request'], gtc); // the dish and its choices as they were
      expect((ops[1]['course'], ops[1]['by'], ops[1]['by_id']), ('1', 'Mike', 's3'));
      expect((ops[2]['item'], ops[2]['qty']), ('California roll', 1));
      expect(ops[2]['request'], roll);
      expect(ops[2].containsKey('note'), isFalse);
      expect({for (final (id, _) in t.hub.sent) id}, hasLength(1)); // all on the one new order
      expect(t.hub.notesKept, isEmpty); // the note was not touched

      final said = tester.widget<Text>(
        find.descendant(of: find.byKey(const ValueKey('again-said')), matching: find.byType(Text)),
      );
      expect(said.data, contains('Same again: 3 dishes added.'));
      expect(said.data, contains('is \$13.95 now, was \$12.95.'));
      expect(said.data, contains('NOT added: Birthday candle.'));
      expect(find.textContaining('Linda Chen'), findsWidgets); // the check is open
      expect(find.text('To-go order'), findsNothing);
      expect(find.textContaining("General Tso's Chicken (Qt)"), findsWidgets); // with the dishes on it
      await stop(tester);
    });

    testWidgets('a past order that cannot be read starts an empty order and says so', (tester) async {
      final t = await pumpOrders(tester, const [], before: (hub) async => hub.customers[lindaDigits] = linda());
      await openForm(tester);
      await typeNumber(tester, '781 555 1234');
      await tester.ensureVisible(find.byKey(const ValueKey('again:p1')));
      await tester.tap(find.byKey(const ValueKey('again:p1'))); // the hub lists no such order now
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();
      expect([for (final (_, op) in t.hub.sent) op['kind']], ['create']);
      expect(find.text('The past order could not be read. Nothing was added.'), findsOneWidget);
      await stop(tester);
    });

    testWidgets('a note is written for a new number, kept at once by the tick, and read back', (tester) async {
      final t = await pumpOrders(tester, const []);
      await openForm(tester);
      expect(find.byKey(const ValueKey('customer-card')), findsNothing); // no number, nobody to know
      await typeNumber(tester, '781 55');
      expect(find.byKey(const ValueKey('customer-card')), findsNothing); // half a number
      expect(t.hub.customersAsked, isEmpty);
      await typeNumber(tester, '781 555 0155');
      expect(t.hub.customersAsked, ['7815550155']);
      expect(find.text('No orders from this number yet'), findsOneWidget);
      expect(find.text('Same again'), findsNothing);

      await tester.enterText(find.byKey(const ValueKey('customer-note')), '  calls ahead   for 12 ');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('customer-note-save')));
      await tester.pumpAndSettle();
      expect(t.hub.notesKept, [('7815550155', 'calls ahead for 12', 'Mike')]); // on one line, with who wrote it
      expect(find.byKey(const ValueKey('customer-note-save')), findsNothing);
      await tester.tap(find.text('Cancel')); // no order: the note is kept all the same
      await tester.pumpAndSettle();
      expect(t.hub.sent, isEmpty);

      await openForm(tester);
      await typeNumber(tester, '(781) 555-0155');
      expect(text(tester, 'customer-note'), 'calls ahead for 12');
      await stop(tester);
    });

    testWidgets('a note changed on the form is kept when the order starts', (tester) async {
      final t = await pumpOrders(tester, const [], before: (hub) async => hub.customers[lindaDigits] = linda());
      await openForm(tester);
      await tester.enterText(find.byKey(const ValueKey('takeout-name')), 'Bob');
      await typeNumber(tester, '781 555 1234');
      expect(text(tester, 'takeout-name'), 'Bob'); // a name that was typed is left alone
      await tester.enterText(find.byKey(const ValueKey('customer-note')), 'no MSG, back door');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('takeout-start')));
      await tester.pumpAndSettle();
      expect(t.hub.notesKept, [(lindaDigits, 'no MSG, back door', 'Mike')]);
      expect([for (final (_, op) in t.hub.sent) op['kind']], ['create']);
      await stop(tester);
    });

    testWidgets('a note the hub will not keep is said, and the order starts all the same', (tester) async {
      final t = await pumpOrders(tester, const [], before: (hub) async => hub.customers[lindaDigits] = linda());
      await openForm(tester);
      await typeNumber(tester, '781 555 1234');
      t.hub.notesRefused = true;
      await tester.enterText(find.byKey(const ValueKey('customer-note')), 'side door only');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('customer-note-save')));
      await tester.pumpAndSettle();
      expect(find.text('Not saved. Try again.'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('takeout-start')));
      await tester.pumpAndSettle();
      expect(find.text('The note about the customer was not saved.'), findsOneWidget);
      expect([for (final (_, op) in t.hub.sent) op['kind']], ['create']);
      await stop(tester);
    });

    testWidgets('a hub older than customers leaves the form as it was', (tester) async {
      final t = await pumpOrders(tester, const [], before: (hub) async => hub.customersOld = true);
      await openForm(tester);
      await typeNumber(tester, '781 555 1234');
      expect(find.byKey(const ValueKey('customer-card')), findsNothing);
      await tester.enterText(find.byKey(const ValueKey('takeout-name')), 'Linda');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('takeout-start')));
      await tester.pumpAndSettle();
      expect([for (final (_, op) in t.hub.sent) op['kind']], ['create']);
      expect(t.hub.notesKept, isEmpty);
      await stop(tester);
    });
  });

  group('on the order', () {
    Future<Terminal> pumpToGo(WidgetTester tester, {String? phone, Map<String, dynamic>? customer}) async {
      final t = await terminal(tester);
      final order = takeout('o5', no: 12, name: 'Linda', channel: 'phone');
      if (phone != null) (order['fields'] as Map<String, dynamic>)['phone'] = phone;
      t.hub.orders.add(order);
      if (customer != null) t.hub.customers[customer['phone'] as String] = customer;
      await tester.pumpWidget(
        MaterialApp(
          home: OrderScreen(api: t.api, outbox: t.outbox, photos: t.photos, orderId: 'o5', staffName: 'Amy'),
        ),
      );
      await tester.pumpAndSettle();
      return t;
    }

    testWidgets('the note about the customer is on the screen of their order', (tester) async {
      final t = await pumpToGo(tester, phone: '781 555 1234', customer: linda());
      expect(t.hub.customersAsked, [lindaDigits]);
      expect(find.byKey(const ValueKey('customer-note-strip')), findsOneWidget);
      expect(find.text('Customer note: no MSG, side door'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5)); // the order is read again and again: the customer once
      await tester.pump();
      expect(t.hub.customersAsked, [lindaDigits]);
      await stop(tester);
    });

    testWidgets('no note, no number: no strip', (tester) async {
      var t = await pumpToGo(
        tester,
        phone: '781 555 1234',
        customer: linda(note: ''),
      );
      expect(find.byKey(const ValueKey('customer-note-strip')), findsNothing);
      await stop(tester);
      t = await pumpToGo(tester);
      expect(find.byKey(const ValueKey('customer-note-strip')), findsNothing);
      expect(t.hub.customersAsked, isEmpty); // an order without a number asks nothing
      await stop(tester);
    });
  });
}
