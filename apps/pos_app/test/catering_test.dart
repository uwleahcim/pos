import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/check_history.dart';
import 'package:pos_app/local_order.dart';
import 'package:pos_app/orders_ahead.dart';
import 'package:pos_app/screens/order_screen.dart';
import 'package:pos_app/screens/orders_ahead_screen.dart';
import 'package:pos_app/screens/quotes_dialog.dart';
import 'package:pos_app/session.dart';
import 'package:pos_app/takeout.dart';
import 'package:pos_app/to_go_stages.dart';

import 'hub.dart';

/// Catering orders and the orders ahead (docs/catering.md): a to-go order for any later day, what its event
/// needs, a deposit with the rest still due, and the list of what was promised for a later time by day.
/// The hub reckons the money (backend/tests/orders/test_ahead.py); these tests are about what the screens
/// ask, say and send.

final _today = DateTime.now();

/// Five days from now at noon: a day the form reaches only off the calendar.
final eventAt = DateTime(_today.year, _today.month, _today.day + 5, 12);
final eventDay = dayName(eventAt);

const deposit = {
  'P1': {'method': 'elsewhere', 'amount': '20.00', 'by': 'Amy'},
};

/// Chen's catering order, number 12: two platters for thirty, delivered. [at] is when it is for.
Map<String, dynamic> chen({
  String id = 'c1',
  bool sent = false,
  Map<String, dynamic> payments = const {},
  String? due,
  String status = 'open',
  String stage = 'new',
  String channel = 'catering',
  DateTime? at,
}) => {
  'order_id': id,
  'status': status,
  'fields': {
    'order_type': 'takeout',
    'order_no': 12,
    'customer_name': 'Chen',
    'phone': '781 555 0101',
    'channel': channel,
    'stage': stage,
    'promised_at': (at ?? eventAt).millisecondsSinceEpoch,
    'quoted_minutes': 60,
    'for_later': true,
    if (channel == 'catering') ...{
      'event_guests': 30,
      'handover': 'delivery',
      'address': '12 Main St, Winchester',
      'event_note': 'Side door',
    },
  },
  'lines': {'L1': line('Pu Pu Platter', fired: sent)..['qty'] = 2},
  'fired': sent ? {'': '2026-11-16T18:00:00'} : <String, dynamic>{},
  'payments': payments,
  'due': ?due,
};

/// Two platters with the 7% rate: 65.01, with [paid] of it taken.
Map<String, dynamic> platters({String paid = '0.00'}) => {
  'lines': [
    {'line_id': 'L1', 'name': 'Pu Pu Platter', 'qty': 2, 'total': '60.76'},
  ],
  'subtotal': '60.76',
  'tax_rate_pct': '7.00',
  'tax': '4.25',
  'total': '65.01',
  'payments': [
    if (cents(paid) > 0) {'payment_id': 'P1', 'method': 'elsewhere', 'amount': paid, 'by': 'Amy'},
  ],
  'paid': paid,
  'due': money(6501 - cents(paid)),
};

/// Amy at [order], pushed over a page so a test sees whether the screen went back.
Future<Terminal> pumpOrder(
  WidgetTester tester,
  Map<String, dynamic> order, {
  String paid = '0.00',
  Size size = const Size(1100, 800),
}) async {
  final t = await terminal(tester);
  t.session.staff = const Staff(staffId: 's1', name: 'Amy', role: 'server', method: 'pin');
  t.hub.check = platters(paid: paid);
  t.hub.orders.add(order);
  tester.view.physicalSize = size;
  await tester.pumpWidget(
    const MaterialApp(
      home: Scaffold(body: Center(child: Text('next customer'))),
    ),
  );
  unawaited(
    tester
        .state<NavigatorState>(find.byType(Navigator))
        .push(
          MaterialPageRoute<void>(
            builder: (_) => OrderScreen(
              api: t.api,
              outbox: t.outbox,
              photos: t.photos,
              orderId: order['order_id'] as String,
              session: t.session,
            ),
          ),
        ),
  );
  await tester.pumpAndSettle();
  return t;
}

Future<void> tapKey(WidgetTester tester, String key) async {
  await tester.ensureVisible(find.byKey(ValueKey(key)));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ValueKey(key)));
  await tester.pumpAndSettle();
}

/// Picks [day] off the calendar behind "Another day", typed as a date.
Future<void> pickDay(WidgetTester tester, DateTime day) async {
  await tapKey(tester, 'day:other');
  await tester.tap(find.byTooltip('Switch to input'));
  await tester.pumpAndSettle();
  String two(int n) => n.toString().padLeft(2, '0');
  await tester.enterText(
    find.descendant(of: find.byType(DatePickerDialog), matching: find.byType(TextField)),
    '${two(day.month)}/${two(day.day)}/${day.year}',
  );
  await tester.tap(find.text('OK'));
  await tester.pumpAndSettle();
}

/// Picks the time behind the Time button, typed.
Future<void> pickTime(WidgetTester tester, String hour, String minute, String half) async {
  await tapKey(tester, 'takeout-time');
  await tester.tap(find.byTooltip('Switch to text input mode'));
  await tester.pumpAndSettle();
  final fields = find.descendant(of: find.byType(Dialog).last, matching: find.byType(TextField));
  await tester.enterText(fields.at(0), hour);
  await tester.enterText(fields.at(1), minute);
  await tester.tap(find.text(half));
  await tester.tap(find.text('OK'));
  await tester.pumpAndSettle();
}

bool enabled(WidgetTester tester, String key) =>
    tester.widget<ButtonStyleButton>(find.byKey(ValueKey(key))).onPressed != null;

List<String> kinds(Hub hub, [String id = 'c1']) => [for (final op in hub.opsFor(id)) op['kind'] as String];
Map<String, dynamic> dataOf(Hub hub, String kind, [String id = 'c1']) =>
    (hub.opsFor(id).firstWhere((op) => op['kind'] == kind)['data'] as Map).cast<String, dynamic>();

/// The list as the hub of backend/tests/orders/test_ahead.py answers it on Monday the 16th: Lee's phone
/// order for tonight, not sent; Chen's catering for Saturday on a deposit, and Park's, paid in full.
Map<String, dynamic> week() {
  int at(int day, int hour) => DateTime(2026, 11, day, hour).millisecondsSinceEpoch;
  return {
    'today': '2026-11-16',
    'days': [
      {
        'day': '2026-11-16',
        'count': 1,
        'guests': 0,
        'unsent': 1,
        'total': '10.71',
        'paid': '0.00',
        'due': '10.71',
        'orders': [
          {
            'order_id': 'p1',
            'order_no': 3,
            'customer_name': 'Lee',
            'phone': '',
            'channel': 'phone',
            'promised_ms': at(16, 19),
            'quoted_minutes': 20,
            'guests': null,
            'handover': null,
            'address': '',
            'event_note': '',
            'status': 'open',
            'stage': 'new',
            'dishes': 1,
            'unsent': 1,
            'items': [
              {'name': 'Chicken wings', 'qty': 1},
            ],
            'total': '10.71',
            'paid': '0.00',
            'due': '10.71',
          },
        ],
      },
      {
        'day': '2026-11-21',
        'count': 2,
        'guests': 38,
        'unsent': 0,
        'total': '83.15',
        'paid': '38.14',
        'due': '45.01',
        'orders': [
          {
            'order_id': 'c1',
            'order_no': 12,
            'customer_name': 'Chen',
            'phone': '781 555 0101',
            'channel': 'catering',
            'promised_ms': at(21, 12),
            'quoted_minutes': 60,
            'guests': 30,
            'handover': 'delivery',
            'address': '12 Main St, Winchester',
            'event_note': 'Side door',
            'status': 'open',
            'stage': 'new',
            'dishes': 5,
            'unsent': 0,
            'items': [
              {'name': 'Pu Pu Platter', 'qty': 2},
              {'name': 'Chicken wings', 'qty': 3},
            ],
            'total': '65.01',
            'paid': '20.00',
            'due': '45.01',
          },
          {
            'order_id': 'c2',
            'order_no': 13,
            'customer_name': 'Park',
            'phone': '',
            'channel': 'catering',
            'promised_ms': at(21, 18),
            'quoted_minutes': 60,
            'guests': 8,
            'handover': 'pickup',
            'address': '',
            'event_note': '',
            'status': 'closed',
            'stage': 'new',
            'dishes': 1,
            'unsent': 0,
            'items': [
              {'name': 'Pu Pu Platter', 'qty': 1},
            ],
            'total': '18.14',
            'paid': '18.14',
            'due': '0.00',
          },
        ],
      },
    ],
  };
}

String said(WidgetTester tester, String key) => tester.widget<Text>(find.byKey(ValueKey(key))).data!;

void main() {
  group('the words and the figures', () {
    test('what an event needs is read off the order and written back, an address only for a delivery', () {
      final event = EventDetails.of((chen()['fields'] as Map).cast<String, dynamic>());
      expect(
        (event.guests, event.handover, event.address, event.note),
        (30, 'delivery', '12 Main St, Winchester', 'Side door'),
      );
      expect(event.words, '30 guests · Delivery · 12 Main St, Winchester · Side door');
      expect(event.toFields(), {
        'event_guests': 30,
        'handover': 'delivery',
        'address': '12 Main St, Winchester',
        'event_note': 'Side door',
      });
      // picked up: the address is not kept, and what is empty is written empty, so it is gone from the order
      const pickup = EventDetails(guests: 1, address: '12 Main St');
      expect(pickup.words, '1 guest · Pickup');
      expect(pickup.toFields(), {'event_guests': 1, 'handover': 'pickup', 'address': '', 'event_note': ''});
      expect(pickup, const EventDetails(guests: 1));
      // an order with none of it reads as a pickup with nothing said; a head count is not a table's guests
      final none = EventDetails.of(const {'guests': 4, 'handover': 'drone', 'event_guests': 0});
      expect((none.guests, none.handover, none.words), (null, 'pickup', 'Pickup'));
      expect(oneLine('  12 Main St,\n  Winchester '), '12 Main St, Winchester');
    });

    test('a day is said as a customer names it', () {
      final monday = DateTime(2026, 11, 16, 17);
      int at(int day, int hour, [int minute = 0]) => DateTime(2026, 11, day, hour, minute).millisecondsSinceEpoch;
      expect(dayName(DateTime(2026, 11, 21)), 'Sat 21 Nov');
      expect(whenFor(at(16, 19), monday), '19:00');
      expect(whenFor(at(17, 12), monday), 'tomorrow 12:00');
      expect(whenFor(at(21, 12), monday), 'Sat 21 Nov 12:00');
      expect(whenFor(at(15, 12), monday), 'Sun 15 Nov 12:00'); // a day that is over
      expect(whenFor(at(17, 0, 30), DateTime(2026, 11, 16, 23, 50)), 'tomorrow 00:30');
      expect(dayAhead(DateTime(2027, 1, 1), DateTime(2026, 12, 31, 23)), 'tomorrow');
    });

    test('catering has a lead of its own and may always go with money still to collect', () {
      const quotes = Quotes(payAtPickup: []);
      expect((quotes.baseFor('catering'), quotes.minutesFor('catering', at: DateTime(2026, 11, 16))), (60, 60));
      expect((quotes.mayPayAtPickup('catering'), quotes.mayPayAtPickup('counter')), (true, false));
      // a hub from before catering had a lead says nothing of it; one that does is believed
      final old = Quotes.fromJson({
        'minutes': {'counter': 15, 'phone': 20},
      });
      expect((old.baseFor('catering'), old.baseFor('online')), (60, 15));
      final set = Quotes.fromJson({
        'minutes': {'catering': 120},
      });
      expect(set.baseFor('catering'), 120);
      expect(handChannels, ['counter', 'phone', 'catering']);
    });

    test('a list says what is left to pay once a deposit was taken', () {
      Order of(Map<String, dynamic> json) => Order.fromJson(json);
      final partPaid = of(chen(payments: deposit, due: '45.01'));
      expect((owes(partPaid), moneyWords(partPaid)), (true, '\$45.01 due'));
      final paidUp = of(chen(payments: deposit, due: '0.00'));
      expect((owes(paidUp), moneyWords(paidUp)), (false, 'paid'));
      final nothing = of(chen());
      expect((owes(nothing), moneyWords(nothing)), (true, 'pay at pickup'));
      // a hub older than deposits says no figure: paid is whether anything was, as before
      final older = of(chen(payments: deposit));
      expect((older.due, owes(older), moneyWords(older)), (null, false, 'paid'));
      expect(inChip(ToGoChip.unpaid, partPaid, DateTime.now()), isTrue);
      expect(inChip(ToGoChip.unpaid, paidUp, DateTime.now()), isFalse);
      // money taken on this screen that the hub has not counted yet comes off what its list said
      Map<String, dynamic> pay(String amount) => {
        'kind': 'pay',
        'data': {'payment_id': 'P9', 'method': 'cash', 'amount': amount},
      };
      expect(withLocalOps(partPaid, [pay('40.00')]).due, '5.01');
      expect(withLocalOps(partPaid, [pay('45.01')]).due, '0.00');
      expect(withLocalOps(nothing, [pay('5.00')]).due, isNull);
    });

    test('the orders ahead are read by day, each day named from the hub\'s own today', () {
      final list = OrdersAhead.fromJson(week());
      expect((list.today, list.count, list.days.length), ('2026-11-16', 3, 2));
      expect([for (final day in list.days) list.heading(day)], ['Today', 'Sat 21 Nov']);
      expect(list.heading(const AheadDay(day: '2026-11-17')), 'Tomorrow');
      expect(list.heading(const AheadDay(day: '2026-11-14')), 'Sat 14 Nov · not closed');
      final saturday = list.days.last;
      expect((saturday.guests, saturday.total, saturday.paid, saturday.due), (38, '83.15', '38.14', '45.01'));
      final chen = saturday.orders.first;
      expect((chen.isCatering, chen.eventWords), (true, '30 guests · Delivery · 12 Main St, Winchester · Side door'));
      expect((chen.total, chen.paid, chen.due, chen.unsent), ('65.01', '20.00', '45.01', 0));
      expect(chen.dishWords(), '2 Pu Pu Platter, 3 Chicken wings');
      expect(chen.dishWords(most: 1), '2 Pu Pu Platter, and 1 more');
      final lee = list.days.first.orders.single;
      expect((lee.isCatering, lee.eventWords, lee.unsent), (false, '', 1)); // a phone order has no event
      expect(const OrdersAhead().days, isEmpty);
    });

    test('the history says a change to the event in words', () {
      String title(String field, String was, String now) => wordsOf(
        HistoryStep.fromJson({'op_id': 'x', 'what': 'field', 'field': field, 'was': was, 'now': now}),
        time: (ms) => '$ms',
      ).title;
      expect(title('event_guests', '30', '40'), 'Guests for the event changed from 30 to 40');
      expect(title('handover', 'delivery', 'pickup'), 'Set for pickup');
      expect(title('address', '', '12 Main St'), 'Address set to 12 Main St');
      expect(title('event_note', 'Side door', ''), 'Note for the event taken off (was Side door)');
      final opened = wordsOf(
        HistoryStep.fromJson({
          'op_id': 'x',
          'what': 'opened',
          'fields': {'order_type': 'takeout', 'channel': 'catering', 'event_guests': 30, 'handover': 'delivery'},
        }),
        time: (ms) => '$ms',
      );
      expect(opened.under, contains('30 guests · Delivery'));
    });
  });

  group('the form', () {
    testWidgets('a catering order names its day and time and says what the event needs', (tester) async {
      final t = await pumpOrders(tester, const []);
      await tester.tap(find.text('To go'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('takeout-name')), 'Chen');
      await tester.enterText(find.byKey(const ValueKey('takeout-phone')), '781 555 0101');
      expect(find.byKey(const ValueKey('event-fields')), findsNothing);
      await tapKey(tester, 'channel:catering');
      // it always names its time: the switch has nothing to ask, and the quote is the ticket's lead
      expect(find.byKey(const ValueKey('takeout-later')), findsNothing);
      expect(said(tester, 'takeout-quote'), 'The kitchen gets its ticket 60 min before its time.');
      expect(find.text('Pick the time it is for.'), findsOneWidget);
      expect(enabled(tester, 'takeout-start'), isFalse);

      await pickDay(tester, eventAt);
      expect(find.text(eventDay), findsOneWidget); // the chip says the day picked
      await pickTime(tester, '12', '00', 'PM');
      expect(enabled(tester, 'takeout-start'), isTrue); // the event's details are not required

      await tester.enterText(find.byKey(const ValueKey('event-guests')), '30');
      expect(find.byKey(const ValueKey('event-address')), findsNothing); // a pickup has no address
      await tapKey(tester, 'handover:delivery');
      await tester.enterText(find.byKey(const ValueKey('event-address')), ' 12 Main St,  Winchester ');
      await tester.enterText(find.byKey(const ValueKey('event-note')), 'Side door');
      await tapKey(tester, 'takeout-start');

      final (_, create) = t.hub.sent.single;
      final data = create['data'] as Map<String, dynamic>;
      expect((data['order_type'], data['channel'], data['customer_name']), ('takeout', 'catering', 'Chen'));
      expect((data['for_later'], data['quoted_minutes']), (true, 60));
      expect(data['promised_at'], eventAt.millisecondsSinceEpoch);
      expect(
        (data['event_guests'], data['handover'], data['address'], data['event_note']),
        (30, 'delivery', '12 Main St, Winchester', 'Side door'),
      );
      expect(data.containsKey('guests'), isFalse); // not a table's covers
      await stop(tester);
    });

    testWidgets('with only a name and a time it is a pickup with nothing else said', (tester) async {
      final t = await pumpOrders(tester, const []);
      await tester.tap(find.text('To go'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('takeout-name')), 'Park');
      await tapKey(tester, 'channel:catering');
      await tapKey(tester, 'day:tomorrow');
      await pickTime(tester, '6', '30', 'PM');
      await tapKey(tester, 'takeout-start');
      final data = t.hub.sent.single.$2['data'] as Map<String, dynamic>;
      expect((data['channel'], data['handover'], data['for_later']), ('catering', 'pickup', true));
      for (final field in ['event_guests', 'address', 'event_note']) {
        expect(data.containsKey(field), isFalse, reason: field);
      }
      final promised = DateTime.fromMillisecondsSinceEpoch(data['promised_at'] as int);
      final tomorrow = DateTime(_today.year, _today.month, _today.day + 1);
      expect((promised.month, promised.day, promised.hour, promised.minute), (tomorrow.month, tomorrow.day, 18, 30));
      await stop(tester);
    });

    testWidgets('any to-go order can be for another day; it carries nothing of an event', (tester) async {
      final t = await pumpOrders(tester, const []);
      await tester.tap(find.text('To go'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('takeout-name')), 'Linda');
      await tapKey(tester, 'channel:phone');
      await tapKey(tester, 'takeout-later');
      expect(find.byKey(const ValueKey('event-fields')), findsNothing);
      await pickDay(tester, eventAt);
      await pickTime(tester, '12', '00', 'PM');
      await tapKey(tester, 'takeout-start');
      final data = t.hub.sent.single.$2['data'] as Map<String, dynamic>;
      expect((data['channel'], data['for_later'], data['quoted_minutes']), ('phone', true, 20));
      expect(data['promised_at'], eventAt.millisecondsSinceEpoch);
      for (final field in ['event_guests', 'handover', 'address', 'event_note']) {
        expect(data.containsKey(field), isFalse, reason: field);
      }
      await stop(tester);
    });
  });

  group('a deposit and the rest', () {
    testWidgets('a deposit is taken as a catering order is sent; the dialog says what stays due', (tester) async {
      final t = await pumpOrder(tester, chen());
      expect(find.text('#12 Chen · $eventDay 12:00'), findsOneWidget); // the title says the day
      await tester.tap(find.widgetWithText(TextButton, 'Pay & send'));
      await tester.pumpAndSettle();
      expect(find.text('Due \$65.01'), findsOneWidget);
      expect(tester.widget<TextField>(find.byKey(const ValueKey('pay-amount'))).controller!.text, '65.01');
      expect(find.text('Later'), findsOneWidget); // it may always go with money still to collect
      expect(find.textContaining('A deposit'), findsNothing); // the whole of it, until less is typed

      for (final wrong in ['0', '70', 'abc']) {
        await tester.enterText(find.byKey(const ValueKey('pay-amount')), wrong);
        await tester.pumpAndSettle();
        expect(find.text('From 0.01 to 65.01'), findsOneWidget, reason: wrong);
        expect(enabled(tester, 'pay-send'), isFalse, reason: wrong);
      }
      await tester.enterText(find.byKey(const ValueKey('pay-amount')), '20');
      await tester.pumpAndSettle();
      expect(find.text('A deposit: \$45.01 stays due'), findsOneWidget);
      // the cash is counted against what is taken, not against the whole check
      expect(find.text('Change \$0.00'), findsOneWidget);
      await tapKey(tester, 'tender:50.00');
      expect(find.text('Change \$30.00'), findsOneWidget);
      await tapKey(tester, 'pay-send');

      expect(kinds(t.hub), ['pay', 'fire']);
      final pay = dataOf(t.hub, 'pay');
      expect((pay['method'], pay['amount'], pay['tendered'], pay['by']), ('cash', '20.00', '50.00', 'Amy'));
      expect(find.byKey(const ValueKey('change-due')), findsOneWidget);
      expect(find.text('Change \$30.00'), findsOneWidget);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(find.text('next customer'), findsOneWidget);
      await stop(tester);
    });

    testWidgets('it can be sent with nothing taken, and a deposit taken before it is sent', (tester) async {
      final t = await pumpOrder(tester, chen());
      // money alone, on an order for later that nobody sent yet
      expect(find.byKey(const ValueKey('due')), findsOneWidget);
      await tapKey(tester, 'pay');
      expect(find.byKey(const ValueKey('pay:later')), findsNothing); // Pay takes money: there is no "later"
      expect(find.descendant(of: find.byKey(const ValueKey('pay-send')), matching: find.text('Pay')), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('pay-amount')), '20.00');
      await tapKey(tester, 'pay:elsewhere');
      await tester.enterText(find.byKey(const ValueKey('pay-note')), 'card machine');
      await tapKey(tester, 'pay-send');
      expect(kinds(t.hub), ['pay']); // and nothing went to the kitchen
      final pay = dataOf(t.hub, 'pay');
      expect((pay['method'], pay['amount'], pay['note']), ('elsewhere', '20.00', 'card machine'));
      expect(pay.containsKey('tendered'), isFalse);
      expect(find.text('next customer'), findsNothing); // the screen stays on the order

      // then sent with nothing more taken
      t.hub.sent.clear();
      await tester.tap(find.widgetWithText(TextButton, 'Pay & send'));
      await tester.pumpAndSettle();
      await tapKey(tester, 'pay:later');
      expect(find.text('Nothing taken now: it is paid when the order is handed over.'), findsOneWidget);
      expect(find.byKey(const ValueKey('pay-amount')), findsNothing);
      await tapKey(tester, 'pay-send');
      expect(kinds(t.hub), ['fire']);
      expect(find.text('next customer'), findsOneWidget);
      await stop(tester);
    });

    testWidgets('what is still due is paid on an order the kitchen has, and only that happens', (tester) async {
      final t = await pumpOrder(tester, chen(sent: true, payments: deposit), paid: '20.00');
      expect(find.widgetWithText(TextButton, 'Pay & send'), findsNothing); // nothing left to send
      expect(find.text('Paid elsewhere'), findsOneWidget);
      expect(find.text('−20.00'), findsOneWidget);
      await tapKey(tester, 'pay');
      expect(find.text('Due \$45.01'), findsOneWidget);
      await tapKey(tester, 'pay-send'); // cash, exact
      expect(kinds(t.hub), ['pay']);
      final pay = dataOf(t.hub, 'pay');
      expect((pay['method'], pay['amount'], pay['tendered']), ('cash', '45.01', '45.01'));
      expect(find.byKey(const ValueKey('change-due')), findsNothing); // no change to give
      expect(find.text('next customer'), findsNothing);
      await stop(tester);
    });

    testWidgets('a phone order that pays at pickup can be paid there; a counter order still pays as it is sent', (
      tester,
    ) async {
      // sent, nothing paid: the foot says what is due, with the button
      await pumpOrder(tester, chen(channel: 'phone', sent: true, at: DateTime.now().add(const Duration(minutes: 30))));
      expect(find.byKey(const ValueKey('pay')), findsOneWidget);
      expect(find.byKey(const ValueKey('due')), findsOneWidget);
      await stop(tester);

      // a counter order for now, not sent: "Pay & send" is the one way, and it takes the whole
      final counter = chen(channel: 'counter');
      (counter['fields'] as Map).remove('for_later');
      final t = await pumpOrder(tester, counter);
      expect(find.byKey(const ValueKey('pay')), findsNothing);
      expect(find.byKey(const ValueKey('due')), findsNothing);
      expect(find.byKey(const ValueKey('when-strip')), findsNothing);
      await tester.tap(find.widgetWithText(TextButton, 'Pay & send'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('pay-amount')), findsNothing);
      expect(find.byKey(const ValueKey('pay:later')), findsNothing);
      await tapKey(tester, 'pay-send');
      expect(dataOf(t.hub, 'pay')['amount'], '65.01');
      await stop(tester);
    });

    testWidgets('a paid-up or closed order has no Pay button', (tester) async {
      const both = {
        ...deposit,
        'P2': {'method': 'cash', 'amount': '45.01', 'by': 'Amy'},
      };
      await pumpOrder(tester, chen(sent: true, payments: both), paid: '65.01');
      expect(find.byKey(const ValueKey('pay')), findsNothing);
      expect(find.byKey(const ValueKey('due')), findsOneWidget); // it still says nothing is due
      await stop(tester);
      await pumpOrder(
        tester,
        chen(sent: true, payments: deposit, status: 'closed'),
        paid: '20.00',
      );
      expect(find.byKey(const ValueKey('pay')), findsNothing);
      await stop(tester);
    });
  });

  group('the order for later on its own screen', () {
    testWidgets('a line under the bar says the day and the event; a tap changes them', (tester) async {
      final t = await pumpOrder(tester, chen());
      expect(
        find.text('For $eventDay 12:00 · 30 guests · Delivery · 12 Main St, Winchester · Side door'),
        findsOneWidget,
      );
      await tapKey(tester, 'when-strip');
      expect(find.text('The event'), findsOneWidget);
      expect(tester.widget<TextField>(find.byKey(const ValueKey('event-guests'))).controller!.text, '30');
      expect(
        tester.widget<TextField>(find.byKey(const ValueKey('event-address'))).controller!.text,
        '12 Main St, Winchester',
      );

      // saved as it stands: nothing is written
      await tapKey(tester, 'when-save');
      expect(t.hub.opsFor('c1'), isEmpty);

      await tapKey(tester, 'when-strip');
      await tester.enterText(find.byKey(const ValueKey('event-guests')), '40');
      await tapKey(tester, 'handover:pickup');
      expect(find.byKey(const ValueKey('event-address')), findsNothing);
      await tapKey(tester, 'when-save');
      // only what changed, with who changed it
      expect(kinds(t.hub), ['set_field']);
      expect(dataOf(t.hub, 'set_field'), {
        'event_guests': 40,
        'handover': 'pickup',
        'address': '',
        'by': 'Amy',
        'by_id': 's1',
      });
      await stop(tester);
    });

    testWidgets('the day and the time of any order for later can be changed, not to a time that has passed', (
      tester,
    ) async {
      final t = await pumpOrder(tester, chen(channel: 'phone'));
      expect(find.text('For $eventDay 12:00'), findsOneWidget); // no event on a phone order
      await tapKey(tester, 'when-strip');
      expect(find.text('When it is for'), findsOneWidget);
      expect(find.byKey(const ValueKey('event-fields')), findsNothing);
      await tapKey(tester, 'day:tomorrow');
      await pickTime(tester, '1', '15', 'PM');
      await tapKey(tester, 'when-save');
      final data = dataOf(t.hub, 'set_field');
      expect(data.keys.toSet(), {'promised_at', 'by', 'by_id'});
      final promised = DateTime.fromMillisecondsSinceEpoch(data['promised_at'] as int);
      final tomorrow = DateTime(_today.year, _today.month, _today.day + 1);
      expect((promised.month, promised.day, promised.hour, promised.minute), (tomorrow.month, tomorrow.day, 13, 15));

      // today at a minute past midnight has always passed
      await tapKey(tester, 'when-strip');
      await tapKey(tester, 'day:today');
      await pickTime(tester, '12', '00', 'AM');
      expect(find.byKey(const ValueKey('when-past')), findsOneWidget);
      expect(enabled(tester, 'when-save'), isFalse);
      await stop(tester);
    });

    testWidgets('a closed order still says its day, and is not changed by a tap', (tester) async {
      final t = await pumpOrder(
        tester,
        chen(sent: true, payments: deposit, status: 'closed'),
        paid: '65.01',
      );
      expect(find.byKey(const ValueKey('when-strip')), findsOneWidget);
      await tapKey(tester, 'when-strip');
      expect(find.text('The event'), findsNothing);
      expect(t.hub.opsFor('c1'), isEmpty);
      await stop(tester);
    });

    testWidgets('the line and the dialog fit a small phone with large type', (tester) async {
      await pumpOrder(tester, chen(), size: const Size(320, 568));
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('when-strip')), findsOneWidget);
      await tapKey(tester, 'when-strip');
      expect(find.text('The event'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await stop(tester);
    });
  });

  group('the list of checks', () {
    final soon = DateTime.now().add(const Duration(minutes: 10));

    testWidgets('it says the day an order is for and what is left to pay', (tester) async {
      await pumpOrders(tester, [
        chen(sent: true, payments: deposit, due: '45.01'),
        chen(id: 'c2', sent: true, payments: deposit, due: '0.00', at: soon),
        chen(id: 'c3', channel: 'phone'),
      ]);
      expect(find.text('2 items · open · fired · for $eventDay 12:00 · \$45.01 due'), findsOneWidget);
      expect(
        find.text('2 items · open · fired · for ${whenFor(soon.millisecondsSinceEpoch, DateTime.now())} · paid'),
        findsOneWidget,
      );
      expect(find.text('2 items · open · for $eventDay 12:00 · pay at pickup'), findsOneWidget);
      // the part-paid one and the unpaid one still owe; the paid-up one does not
      expect(
        tester
            .widget<Text>(find.descendant(of: find.byKey(const ValueKey('chip:unpaid')), matching: find.byType(Text)))
            .textSpan!
            .toPlainText(),
        'Unpaid 2',
      );
      await stop(tester);
    });

    testWidgets('picked up asks for the rest of a part-paid order, and closes the check either way', (tester) async {
      final t = await pumpOrders(tester, [chen(sent: true, payments: deposit, due: '45.01', stage: 'ready', at: soon)]);
      await tapKey(tester, 'picked-up-c1');
      expect(find.text('Due \$45.01'), findsOneWidget);
      expect(find.byKey(const ValueKey('pay-amount')), findsNothing); // the rest, whole
      expect(find.widgetWithText(FilledButton, 'Pay & hand over'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(t.hub.opsFor('c1'), isEmpty); // called off: nothing was handed over

      await tapKey(tester, 'picked-up-c1');
      await tapKey(tester, 'tender:50.00');
      await tapKey(tester, 'pay-send');
      expect(kinds(t.hub), ['pay', 'set_field', 'close']);
      final pay = dataOf(t.hub, 'pay');
      expect((pay['method'], pay['amount'], pay['tendered'], pay['by']), ('cash', '45.01', '50.00', 'Mike'));
      expect(dataOf(t.hub, 'set_field'), {'stage': 'picked_up'});
      expect(find.text('Change \$4.99'), findsOneWidget);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      await stop(tester);
    });

    testWidgets('"Not now" hands a part-paid order over with the rest still due', (tester) async {
      final t = await pumpOrders(tester, [chen(sent: true, payments: deposit, due: '45.01', stage: 'ready', at: soon)]);
      await tapKey(tester, 'picked-up-c1');
      await tapKey(tester, 'pay:later');
      expect(find.text('Nothing taken: the check closes with what is due still to pay.'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Hand over'), findsOneWidget);
      await tapKey(tester, 'pay-send');
      expect(kinds(t.hub), ['set_field', 'close']);
      await stop(tester);
    });

    testWidgets('an order nothing was paid on, or one paid up, is picked up with one tap as before', (tester) async {
      final t = await pumpOrders(tester, [
        chen(sent: true, stage: 'ready', at: soon),
        chen(id: 'c2', sent: true, payments: deposit, due: '0.00', stage: 'ready', at: soon),
      ]);
      await tapKey(tester, 'picked-up-c1');
      expect(find.textContaining('Due'), findsNothing);
      expect(kinds(t.hub), ['set_field', 'close']);
      await tapKey(tester, 'picked-up-c2');
      expect(kinds(t.hub, 'c2'), ['set_field', 'close']);
      await stop(tester);
    });
  });

  group('Orders ahead', () {
    Future<Terminal> pumpAhead(WidgetTester tester, Map<String, dynamic>? ahead, {Size? size}) async {
      final t = await terminal(tester);
      t.hub.ahead = ahead;
      t.hub.check = platters(paid: '20.00');
      t.hub.orders.add(chen(sent: true, payments: deposit, due: '45.01'));
      if (size != null) tester.view.physicalSize = size;
      await pumpOrdersOn(tester, t);
      return t;
    }

    testWidgets('each day lists its orders with the money on each, and adds them up', (tester) async {
      await pumpAhead(tester, week());
      await tester.tap(find.byTooltip('Orders ahead'));
      await tester.pumpAndSettle();
      expect(find.text('Orders ahead'), findsOneWidget);
      expect(find.text('Today'), findsOneWidget);
      expect(find.text('Sat 21 Nov'), findsOneWidget);
      expect(find.text('1 order'), findsOneWidget);
      expect(find.text('2 orders · 38 guests'), findsOneWidget);
      // a day nothing was paid on says its total alone
      expect(said(tester, 'ahead-day-money:2026-11-16'), 'Total \$10.71');
      expect(said(tester, 'ahead-day-money:2026-11-21'), 'Total \$83.15 · paid \$38.14 · due \$45.01');

      Finder inCard(String id, Finder what) => find.descendant(of: find.byKey(ValueKey('ahead:$id')), matching: what);
      expect(inCard('c1', find.text('12:00')), findsOneWidget);
      expect(inCard('c1', find.text('Chen · catering · #12')), findsOneWidget);
      expect(inCard('c1', find.text('\$65.01')), findsOneWidget);
      expect(said(tester, 'ahead-event:c1'), '30 guests · Delivery · 12 Main St, Winchester · Side door');
      expect(inCard('c1', find.text('2 Pu Pu Platter, 3 Chicken wings · 781 555 0101')), findsOneWidget);
      expect(said(tester, 'ahead-money:c1'), 'Paid \$20.00 · due \$45.01');
      expect(find.byKey(const ValueKey('ahead-unsent:c1')), findsNothing);
      // nobody sent tonight's phone order: it says so, since no ticket will print for it
      expect(inCard('p1', find.text('Not sent')), findsOneWidget);
      expect(said(tester, 'ahead-money:p1'), 'Nothing paid');
      expect(find.byKey(const ValueKey('ahead-event:p1')), findsNothing);
      expect(said(tester, 'ahead-money:c2'), 'Paid');
      expect(said(tester, 'ahead-event:c2'), '8 guests · Pickup');
      await stop(tester);
    });

    testWidgets('a tap opens the order, and the list is read again on the way back', (tester) async {
      final t = await pumpAhead(tester, week());
      await tester.tap(find.byTooltip('Orders ahead'));
      await tester.pumpAndSettle();
      int reads() => t.hub.requests.where((r) => r == 'GET /orders/ahead').length;
      final before = reads();
      await tester.tap(find.byKey(const ValueKey('ahead:c1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('when-strip')), findsOneWidget); // the order's own screen
      expect(find.textContaining('#12 Chen'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('Orders ahead'), findsOneWidget);
      expect(reads(), greaterThan(before));
      await stop(tester);
    });

    testWidgets('some dishes added later and not sent are counted', (tester) async {
      final list = week();
      final chenRow = ((list['days'] as List)[1]['orders'] as List)[0] as Map<String, dynamic>;
      chenRow['unsent'] = 2;
      await pumpAhead(tester, list);
      await tester.tap(find.byTooltip('Orders ahead'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: find.byKey(const ValueKey('ahead-unsent:c1')), matching: find.text('2 not sent')),
        findsOneWidget,
      );
      await stop(tester);
    });

    testWidgets('with nothing ahead it says so; a hub older than the list says to update it', (tester) async {
      await pumpAhead(tester, {'today': '2026-11-16', 'days': <Object>[]});
      await tester.tap(find.byTooltip('Orders ahead'));
      await tester.pumpAndSettle();
      expect(find.text('No orders are waiting for a later time.'), findsOneWidget);
      await stop(tester);

      await pumpAhead(tester, null);
      await tester.tap(find.byTooltip('Orders ahead'));
      await tester.pumpAndSettle();
      expect(find.text('This hub does not list the orders ahead yet. Update the hub.'), findsOneWidget);
      await stop(tester);
    });

    testWidgets('with the hub away it keeps its last picture and says it may be behind', (tester) async {
      final t = await terminal(tester);
      t.hub.ahead = week();
      await tester.pumpWidget(
        MaterialApp(
          home: OrdersAheadScreen(api: t.api, onOpen: (_) async {}),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('ahead:c1')), findsOneWidget);
      t.hub.down = true;
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('ahead-away')), findsOneWidget);
      expect(find.byKey(const ValueKey('ahead:c1')), findsOneWidget);
      t.hub.down = false;
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('ahead-away')), findsNothing);
      await stop(tester);
    });

    testWidgets('on a phone the way in is in the menu, and the list fits a small one with large type', (tester) async {
      await pumpAhead(tester, week(), size: const Size(320, 568));
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Orders ahead'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('ahead:p1')), findsOneWidget);
      await tester.scrollUntilVisible(find.byKey(const ValueKey('ahead:c2')), 200);
      expect(tester.takeException(), isNull);
      await stop(tester);
    });
  });

  group('the catering lead', () {
    testWidgets('a manager sets it with the quote times', (tester) async {
      final t = await terminal(tester);
      Quotes? saved;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async => saved = await showDialog<Quotes>(
                  context: context,
                  builder: (_) => QuotesDialog(api: t.api, token: 'tok', quotes: Quotes.fromJson(t.hub.quotes)),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      // a hub that never heard of it starts at the hour; catering has no "pay at pickup" tick, it always may
      expect(tester.widget<TextField>(find.byKey(const ValueKey('quote:catering'))).controller!.text, '60');
      expect(find.byKey(const ValueKey('pickup:catering')), findsNothing);
      await tester.enterText(find.byKey(const ValueKey('quote:catering')), '90');
      await tapKey(tester, 'quotes-save');
      expect((t.hub.quotes['minutes'] as Map)['catering'], 90);
      expect(saved?.baseFor('catering'), 90);
    });
  });
}
