import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/kitchen_screen.dart';
import 'package:pos_app/online_orders.dart';
import 'package:pos_app/takeout.dart';
import 'package:pos_app/to_go_stages.dart';

import 'check_history_test.dart' as history;
import 'counter_test.dart' show promised, pumpOrder, pumpOrders, stop, takeout;
import 'kitchen_screen_test.dart' as kitchen;

/// Online orders on the screens (docs/online-orders.md, "On the screens"): an order the hub took from the
/// website says so in the list of checks and on its own screen, with how the customer chose to pay there;
/// what the website took reads "Paid online"; and what the customer wrote for the whole order stands on the
/// order's screen and heads the ticket on a kitchen screen, as it heads the paper.

const noOnions = 'No onions in anything, please';

/// The payment the hub records for an order that was paid on the website.
Map<String, dynamic> paidOnTheWebsite(String id) => {
  '$id:paid': {'method': 'elsewhere', 'amount': '10.71', 'note': 'Paid online', 'by': 'Online order'},
};

/// An order as the hub replays one it took from the website: on the channel Online, sent to the kitchen,
/// with what the hub keeps of where it came from. Paid there unless [payment] says how it will be.
Map<String, dynamic> website(
  String id, {
  int no = 21,
  String name = 'Linda',
  String payment = 'ONLINE',
  bool recorded = true,
  bool delivery = false,
  String note = '',
  Map<String, dynamic>? payments,
}) {
  final order = takeout(
    id,
    no: no,
    name: name,
    channel: 'online',
    fired: true,
    payments: payments ?? (payment == 'ONLINE' && recorded ? paidOnTheWebsite(id) : const {}),
  );
  return {
    ...order,
    'fields': {
      ...order['fields'] as Map<String, dynamic>,
      if (delivery) ...{'handover': 'delivery', 'address': '12 Elm St, Winchester'},
      if (note.isNotEmpty) 'note': note,
      'online': {
        'source': 'gloriafood',
        'id': '101',
        'type': delivery ? 'delivery' : 'pickup',
        'payment': payment,
        'total': '10.71',
      },
    },
  };
}

Order read(Map<String, dynamic> json) => Order.fromJson(json);

void main() {
  group('what an order says of the website', () {
    test('an order the hub took from the website carries where it came from; one rung in does not', () {
      final online = read(website('o1', note: '  No onions\n in anything,   please ')).online!;
      expect(
        (online.sourceName, online.id, online.type, online.payment, online.total),
        ('GloriaFood', '101', 'pickup', 'ONLINE', '10.71'),
      );
      expect(read(website('o1', note: '  No onions\n in anything,   please ')).note, noOnions);
      expect(onlineFacts(online), ['Order 101 on GloriaFood · pickup', 'Charged on the website: \$10.71']);

      // rung in on a screen under the channel Online: it did not come by itself
      final rung = read(takeout('o2', channel: 'online'));
      expect((rung.online, rung.note), (null, ''));
      expect(paysHow(rung), isNull);
      // a hub that says something else under the name is not believed
      expect(
        read({
          ...takeout('o3'),
          'fields': <String, dynamic>{'online': 'yes'},
        }).online,
        isNull,
      );
      // what the website did not say is left out, and nothing breaks
      const bare = OnlineOrder(source: 'gloriafood');
      expect(onlineFacts(bare), ['on GloriaFood']);
      expect(onlineFacts(const OnlineOrder()), isEmpty);
    });

    test('its money is said as the customer chose it on the website', () {
      String words(Map<String, dynamic> json) => moneyWords(read(json));
      expect(words(website('o1')), 'paid online');
      expect(words(website('o1', payment: 'CASH')), 'pays cash at pickup');
      expect(words(website('o1', payment: 'CASH', delivery: true)), 'pays cash at the door');
      expect(words(website('o1', payment: 'CARD')), 'pays by card at pickup');
      expect(words(website('o1', payment: 'CARD', delivery: true)), 'pays by card at the door');
      expect(words(website('o1', payment: 'CARD_PHONE')), 'pays by card over the phone');
      // the website took money the hub recorded none of (paid in more than one way there)
      expect(words(website('o1', recorded: false)), 'check GloriaFood for what was paid online');
      // a way of paying this build does not know, and none at all: as any to-go order
      expect(words(website('o1', payment: 'GIFT')), 'pay at pickup');
      expect(words(website('o1', payment: '', delivery: true)), 'pay at the door');

      // paid at the counter since: it is paid, and nobody is told it was paid online
      const cash = {
        'P1': {'method': 'cash', 'amount': '10.71', 'tendered': '20.00', 'by': 'Amy'},
      };
      expect(words(website('o1', payment: 'CASH', payments: cash)), 'paid');
      // a list of checks says what is still due on it, whatever was chosen
      expect(words({...website('o1', payment: 'CASH', payments: cash), 'due': '4.00'}), '\$4.00 due');
      // an order rung in on a screen reads as it always did
      expect(words(takeout('o2', channel: 'online')), 'pay at pickup');
      expect(words(takeout('o2', payments: cash)), 'paid');
    });

    test('only the hub\'s own payment reads Paid online', () {
      final paid = read(website('o1')).payments.single;
      expect(paidOnline(paid), isTrue);
      expect(
        paidOnline(const Payment(paymentId: 'P1', method: 'elsewhere', amount: '5.00', note: 'by phone')),
        isFalse,
      );
      expect(paidOnline(const Payment(paymentId: 'P1', method: 'cash', amount: '5.00', note: 'Paid online')), isFalse);
      expect(paidAs('elsewhere', 'Paid online'), 'Paid online');
      expect(paidAs('elsewhere', 'by phone'), 'Paid elsewhere');
      expect(paidAs('cash', ''), 'Cash');
    });

    test('a check\'s history says Paid online once, not as a note too', () {
      List<String> said(Map<String, dynamic> data) => history.words('paid', data);

      expect(said({'method': 'elsewhere', 'amount': '31.00', 'note': 'Paid online'}), [
        'Payment of \$31.00',
        'Paid online',
      ]);
      expect(said({'method': 'elsewhere', 'amount': '31.00', 'note': 'by phone'}), [
        'Payment of \$31.00',
        'Paid elsewhere',
        'Note: by phone',
      ]);
    });
  });

  group('the list of checks', () {
    testWidgets('marks an order from the website and says how it is paid', (tester) async {
      await pumpOrders(tester, [
        website('o1'),
        website('o2', no: 22, name: 'Wei', payment: 'CARD', delivery: true),
        takeout('o3', no: 23, name: 'Sam', channel: 'online'), // rung in by hand
      ]);
      expect(find.byKey(const ValueKey('online-o1')), findsOneWidget);
      expect(find.byKey(const ValueKey('online-o2')), findsOneWidget);
      expect(find.byKey(const ValueKey('online-o3')), findsNothing);
      expect(tester.widget<Icon>(find.byKey(const ValueKey('online-o1'))).semanticLabel, 'From the website');
      expect(find.text('Linda · online'), findsOneWidget);
      expect(find.text('2 items · open · fired · ready ${clockTime(promised)} · paid online'), findsOneWidget);
      expect(find.textContaining('pays by card at the door'), findsOneWidget);
      expect(find.textContaining('pay at pickup'), findsOneWidget); // Sam's, as before
      await stop(tester);
    });
  });

  group('the order\'s own screen', () {
    testWidgets('says it came from the website, Paid online, and what the customer wrote', (tester) async {
      await pumpOrder(tester, website('o1', note: noOnions), paid: true);
      expect(find.byKey(const ValueKey('online-strip')), findsOneWidget);
      expect(find.text('From the website · paid online'), findsOneWidget);
      expect(find.text('Customer wrote: $noOnions'), findsOneWidget);
      // the money the website took, in words, where it read "Paid elsewhere"
      expect(
        find.descendant(of: find.byKey(const ValueKey('paid-o1:paid')), matching: find.text('Paid online')),
        findsOneWidget,
      );
      expect(find.textContaining('Paid elsewhere'), findsNothing);

      // a tap: the whole of it, to read
      await tester.tap(find.byKey(const ValueKey('online-strip')));
      await tester.pumpAndSettle();
      Finder shown(String text) =>
          find.descendant(of: find.byKey(const ValueKey('online-about')), matching: find.text(text));
      expect(shown('From the website'), findsOneWidget);
      expect(shown('Order 101 on GloriaFood · pickup'), findsOneWidget);
      expect(shown('Charged on the website: \$10.71'), findsOneWidget);
      expect(shown('Paid online'), findsOneWidget);
      expect(shown(noOnions), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Close'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('online-about')), findsNothing);
      expect(find.byKey(const ValueKey('online-strip')), findsOneWidget); // still on the order
      await stop(tester);
    });

    testWidgets('one to pay for at the counter says how the customer chose to', (tester) async {
      await pumpOrder(tester, website('o1', payment: 'CASH'));
      expect(find.text('From the website · pays cash at pickup'), findsOneWidget);
      expect(find.byKey(const ValueKey('order-note')), findsNothing); // the customer wrote nothing
      await stop(tester);
    });

    testWidgets('an order rung in on a screen has no such strip', (tester) async {
      await pumpOrder(tester, takeout('o2', channel: 'online'));
      expect(find.byKey(const ValueKey('online-strip')), findsNothing);
      await stop(tester);
    });

    testWidgets('a long note takes two lines on a phone, and a tap shows every word', (tester) async {
      final long = List.filled(12, 'No onions, no scallions, sauce on the side.').join(' ');
      await pumpOrder(tester, website('o1', payment: 'CARD', delivery: true, note: long));
      tester.view.physicalSize = const Size(360, 740);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final note = find.byKey(const ValueKey('order-note'));
      expect(tester.widget<Text>(note).maxLines, 2);
      expect(tester.getSize(find.byKey(const ValueKey('online-strip'))).height, lessThan(70));
      expect(find.text('From the website · pays by card at the door'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('online-strip')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(tester.widget<Text>(find.byKey(const ValueKey('order-note-whole'))).data, long);
      expect(find.text('Order 101 on GloriaFood · delivery'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Close'));
      await tester.pumpAndSettle();
      await stop(tester);
    });
  });

  group('a kitchen screen', () {
    Map<String, dynamic> noted(String note) => {
      ...kitchen.ticket(
        'o9',
        4,
        [kitchen.dish('a', 'Beef Lo Mein'), kitchen.dish('b', 'Kung Pao Shrimp')],
        orderNo: 21,
        customer: 'Linda',
        channel: 'online',
      ),
      'note': note,
    };

    test('a ticket reads the customer\'s note on one line, and has none where the hub sends none', () {
      final read = kitchen.board([
        noted('No onions\n in anything,  please'),
        kitchen.ticket('o1', 2, [kitchen.dish('a', 'Soup')], table: '12'),
      ]);
      expect([for (final t in read.tickets) t.note], [noOnions, '']);
      expect(read.tickets.first.detail, startsWith('Online'));
      expect(KitchenTicket.fromJson(const {'id': 'x', 'note': 7}).note, '7');
    });

    testWidgets('heads the ticket with what the customer wrote, before the dishes, and keeps it', (tester) async {
      final t = await kitchen.pumpScreen(
        tester,
        kitchen: [
          noted(noOnions),
          kitchen.ticket('o1', 2, [kitchen.dish('a', 'Soup')], table: '12'),
        ],
      );
      Finder bar(String orderId) => find.byWidgetPredicate((w) => '${w.key}'.contains('kitchen-note:$orderId:'));
      expect(bar('o9'), findsOneWidget);
      expect(bar('o1'), findsNothing);
      // under the head and before the first dish, as the paper has it
      expect(kitchen.words(tester, 'o9'), [
        '#21 Linda',
        'Online',
        '4 min',
        'Customer\'s note · $noOnions',
        '1 × Beef Lo Mein',
        '1 × Kung Pao Shrimp',
        'Done',
      ]);

      // a dish marked made: the note stays on the ticket for the dish still to make
      await tester.tap(kitchen.row('o9', 'a'));
      await tester.pump();
      await tester.pump();
      expect(kitchen.marks(t.hub), ['o9 wok a made']);
      expect(bar('o9'), findsOneWidget);
      await kitchen.away(tester);
    });

    testWidgets('a long note is shown whole on a phone, without running off it', (tester) async {
      final long = List.filled(7, 'No onions, no scallions, sauce on the side.').join(' ');
      await kitchen.pumpScreen(tester, kitchen: [noted(long)], size: const Size(360, 740));
      expect(tester.takeException(), isNull);
      final shown = find.text('Customer\'s note · $long');
      expect(shown, findsOneWidget);
      expect(tester.widget<Text>(shown).maxLines, isNull); // every word: it may say an allergy
      expect(tester.getSize(shown).width, lessThan(360));
      await kitchen.away(tester);
    });
  });
}
