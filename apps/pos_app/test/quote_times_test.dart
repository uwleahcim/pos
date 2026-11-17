import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/screens/rush.dart';
import 'package:pos_app/takeout.dart';

import 'counter_test.dart';
import 'location_rows.dart';

/// Quote times that follow the kitchen (the Toast comparison, 2026-11-15): a manager's rush adds minutes to
/// every new quote on every screen until the night is over, a big order is promised later (settled as it is
/// first sent), and an order for later is marked on the list of checks as its time to start nears.

int inMinutes(int minutes) => DateTime.now().add(Duration(minutes: minutes)).millisecondsSinceEpoch;

/// The quotes of a hub that knows the rush and big orders: no rush and no rule unless the test names them.
Map<String, dynamic> quotesNow({int rush = 0, int? until, int dishes = 0, int minutes = 0}) => {
  'minutes': {'counter': 15, 'phone': 20, 'online': 25, 'delivery': 45},
  'pay_at_pickup': ['phone'],
  'big_orders': {'dishes': dishes, 'minutes': minutes},
  'rush': rush > 0 ? {'minutes': rush, 'until': until ?? inMinutes(360), 'by': 'Mike'} : null,
};

/// A to-go order as the app makes one today: quoted, and saying so when the customer named its time.
Map<String, dynamic> quoted(
  String id, {
  int no = 7,
  String name = 'Linda',
  String channel = 'counter',
  int quote = 15,
  int? at,
  bool forLater = false,
  bool fired = false,
  String stage = 'new',
  Map<String, dynamic> payments = const {},
}) {
  final order = takeout(id, no: no, name: name, channel: channel, stage: stage, fired: fired, payments: payments);
  order['fields'] = <String, dynamic>{
    ...order['fields'] as Map<String, dynamic>,
    'quoted_minutes': quote,
    'promised_at': at ?? promised,
    if (forLater) 'for_later': true,
  };
  return order;
}

void main() {
  test('a rush adds its minutes to every quote made while it runs, and to nothing after its night', () {
    final at = DateTime(2026, 11, 15, 19);
    final until = DateTime(2026, 11, 16, 4);
    final quotes = Quotes.fromJson(quotesNow(rush: 20, until: until.millisecondsSinceEpoch));
    expect((quotes.takesRush, quotes.rush?.minutes, quotes.rush?.by), (true, 20, 'Mike'));
    expect((quotes.baseFor('phone'), quotes.minutesFor('phone', at: at)), (20, 40));
    expect(quotes.minutesFor('counter', at: at), 35);
    expect(quotes.minutesFor('phone', at: until), 20); // left on overnight, it is over by itself
    expect((quotes.rushAt(until.subtract(const Duration(minutes: 1))), quotes.rushAt(until)), (20, 0));

    // A time the customer named takes the rush only inside the rush's own night.
    expect(quotes.minutesFor('phone', at: at, promised: DateTime(2026, 11, 15, 21)), 40);
    expect(quotes.minutesFor('phone', at: at, promised: DateTime(2026, 11, 16, 12)), 20);

    final none = Quotes.fromJson(quotesNow());
    expect((none.takesRush, none.rush, none.minutesFor('phone', at: at)), (true, null, 20));
    expect(Rush.fromJson({'minutes': 0, 'until': until.millisecondsSinceEpoch}), isNull);
    expect(Rush.fromJson('nonsense'), isNull);

    // A hub from before the rush names none: it is not offered the button.
    final older = Quotes.fromJson({
      'minutes': {'phone': 30},
      'pay_at_pickup': <String>[],
    });
    expect((older.takesRush, older.takesBigOrders, older.minutesFor('phone', at: at)), (false, false, 30));
  });

  test('a big order takes more minutes, and the rule goes back to the hub only when the hub knows it', () {
    final quotes = Quotes.fromJson(quotesNow(dishes: 8, minutes: 10));
    expect((quotes.takesBigOrders, quotes.bigDishes, quotes.bigMinutes), (true, 8, 10));
    expect((quotes.extraFor(7), quotes.extraFor(8), quotes.extraFor(30)), (0, 10, 10));
    expect(quotes.toJson()['big_orders'], {'dishes': 8, 'minutes': 10});
    expect(quotes.toJson().containsKey('rush'), isFalse); // the rush is set by itself

    final off = Quotes.fromJson(quotesNow());
    expect((off.extraFor(0), off.extraFor(50)), (0, 0));
    expect(Quotes.fromJson(quotesNow(dishes: 8)).extraFor(50), 0); // dishes with no minutes: no rule
    expect(const Quotes().toJson().containsKey('big_orders'), isFalse);
  });

  test('an order says how many dishes it has, what it was quoted and whether its time was named', () {
    final order = Order.fromJson(quoted('o1', quote: 20, forLater: true));
    expect((order.dishes, order.quotedMinutes, order.forLater), (2, 20, true));
    final plain = Order.fromJson(takeout('o2'));
    expect((plain.quotedMinutes, plain.forLater), (0, false));
  });

  test('an order for later is marked when its start is near, and when it passed with nothing sent', () {
    final promisedAt = DateTime(2026, 11, 15, 18, 30);
    final ms = promisedAt.millisecondsSinceEpoch;
    LaterStage stage(DateTime now, {bool sent = false, bool forLater = true}) =>
        laterStage(forLater: forLater, promisedAt: ms, quotedMinutes: 20, sent: sent, now: now);

    expect(startsAt(ms, 20), DateTime(2026, 11, 15, 18, 10));
    expect(stage(DateTime(2026, 11, 15, 17, 54)), LaterStage.waiting);
    expect(stage(DateTime(2026, 11, 15, 17, 55)), LaterStage.soon); // a quarter of an hour before it starts
    expect(stage(DateTime(2026, 11, 15, 18, 9), sent: true), LaterStage.soon);
    expect(stage(DateTime(2026, 11, 15, 18, 10)), LaterStage.unsent);
    expect(stage(DateTime(2026, 11, 15, 18, 10), sent: true), LaterStage.none); // its ticket prints by itself
    expect(stage(DateTime(2026, 11, 15, 18, 0), forLater: false), LaterStage.none);
    expect(
      laterStage(forLater: true, promisedAt: null, quotedMinutes: 20, sent: false, now: promisedAt),
      LaterStage.none,
    );

    DateTime? next(DateTime now) => laterStageChanges(promisedAt: ms, quotedMinutes: 20, now: now);
    expect(next(DateTime(2026, 11, 15, 12)), DateTime(2026, 11, 15, 17, 55));
    expect(next(DateTime(2026, 11, 15, 17, 55)), DateTime(2026, 11, 15, 18, 10));
    expect(next(DateTime(2026, 11, 15, 18, 10)), isNull);
  });

  testWidgets('a manager sets the rush: every new quote is longer, the strip says so, Off takes it away', (
    tester,
  ) async {
    final t = await pumpOrders(tester, const [], before: (hub) async => hub.quotes = quotesNow());
    expect(find.byKey(const ValueKey('rush-strip')), findsNothing);

    await tester.tap(find.byTooltip('Kitchen rush'));
    await tester.pumpAndSettle();
    expect(find.text('Manager PIN'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, '9999');
    await tester.tap(find.widgetWithText(FilledButton, 'Set the rush'));
    await tester.pumpAndSettle();
    expect(find.text('Kitchen is busy'), findsOneWidget);
    for (final minutes in rushChoices) {
      expect(find.byKey(ValueKey('rush:$minutes')), findsOneWidget);
    }
    expect(find.widgetWithText(FilledButton, 'Off'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('rush:20')));
    await tester.pumpAndSettle();

    expect(t.hub.rushSet, [20]);
    expect(t.hub.rushAuth, 'Bearer tok-admin');
    expect(find.byKey(const ValueKey('rush-strip')), findsOneWidget);
    expect(find.text('Kitchen is busy: new quotes +20 min'), findsOneWidget);
    expect(find.text('until ${clockTime(t.hub.rushUntil)}'), findsOneWidget);
    expect(find.text('New to-go orders are quoted 20 minutes longer on every screen, until closing.'), findsOneWidget);

    // The next to-go order is quoted the channel's minutes and the rush, and the form says why.
    await tester.tap(find.text('To go'));
    await tester.pumpAndSettle();
    expect(find.text('Ready in about 35 min (busy kitchen: +20)'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('takeout-name')), 'Linda');
    await tester.tap(find.byKey(const ValueKey('channel:phone')));
    await tester.pumpAndSettle();
    expect(find.text('Ready in about 40 min (busy kitchen: +20)'), findsOneWidget);
    final before = DateTime.now();
    await tester.tap(find.byKey(const ValueKey('takeout-start')));
    await tester.pumpAndSettle();
    final data = t.hub.sent.single.$2['data'] as Map<String, dynamic>;
    expect((data['quoted_minutes'], data.containsKey('for_later')), (40, false));
    final promisedAt = DateTime.fromMillisecondsSinceEpoch(data['promised_at'] as int);
    expect(promisedAt.difference(before).inMinutes, inInclusiveRange(39, 40));

    // Back on the checks, the strip is the way to change it: Off, and the usual quote is back.
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rush-strip')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '9999');
    await tester.tap(find.widgetWithText(FilledButton, 'Set the rush'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(FilledButton, '+20 min'), findsOneWidget); // the one it is set to
    await tester.tap(find.byKey(const ValueKey('rush:0')));
    await tester.pumpAndSettle();
    expect(t.hub.rushSet, [20, 0]);
    expect(find.byKey(const ValueKey('rush-strip')), findsNothing);
    expect(find.text('The rush is off. New orders get the usual quote.'), findsOneWidget);
    await tester.tap(find.text('To go'));
    await tester.pumpAndSettle();
    expect(find.text('Ready in about 15 min'), findsOneWidget);
    await stop(tester);
  });

  testWidgets('a server sees the rush and cannot set it; a hub from before the rush offers no button', (tester) async {
    final t = await pumpOrders(
      tester,
      const [],
      role: 'server',
      before: (hub) async => hub.quotes = quotesNow(rush: 30),
    );
    expect(find.text('Kitchen is busy: new quotes +30 min'), findsOneWidget);
    expect(find.byTooltip('Kitchen rush'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('rush-strip')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '1111');
    await tester.tap(find.widgetWithText(FilledButton, 'Set the rush'));
    await tester.pumpAndSettle();
    expect(find.text('Only a manager can add minutes to the quotes'), findsOneWidget);
    expect(t.hub.rushSet, isEmpty);
    await stop(tester);

    await pumpOrders(tester, const []); // a manager, on a hub that was not updated yet
    expect(find.byTooltip('Kitchen rush'), findsNothing);
    expect(find.byKey(const ValueKey('rush-strip')), findsNothing);
    await stop(tester);
  });

  testWidgets('a rush left on from last night shows nowhere, and one that runs out leaves by itself', (tester) async {
    await pumpOrders(tester, const [], before: (hub) async => hub.quotes = quotesNow(rush: 20, until: inMinutes(-5)));
    expect(find.byKey(const ValueKey('rush-strip')), findsNothing);
    await tester.tap(find.text('To go'));
    await tester.pumpAndSettle();
    expect(find.text('Ready in about 15 min'), findsOneWidget);
    await stop(tester);

    final soon = DateTime.now().add(const Duration(milliseconds: 1500)).millisecondsSinceEpoch;
    await pumpOrders(tester, const [], before: (hub) async => hub.quotes = quotesNow(rush: 20, until: soon));
    expect(find.byKey(const ValueKey('rush-strip')), findsOneWidget);
    // The screen's clock rings once, when the rush is over; the wall clock has to get there too.
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1700)));
    await tester.pump(const Duration(seconds: 4));
    expect(find.byKey(const ValueKey('rush-strip')), findsNothing);
    await stop(tester);
  });

  testWidgets('a time named for tomorrow takes none of tonight\'s rush, and the order says it was named', (
    tester,
  ) async {
    final t = await pumpOrders(tester, const [], before: (hub) async => hub.quotes = quotesNow(rush: 20));
    await tester.tap(find.text('To go'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('takeout-name')), 'Linda');
    await tester.tap(find.byKey(const ValueKey('takeout-later')));
    await tester.pumpAndSettle();
    expect(find.text('Prints ahead of its time by the quote (35 min tonight)'), findsOneWidget);

    await tester.tap(find.text('Tomorrow'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('takeout-time')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Switch to text input mode'));
    await tester.pumpAndSettle();
    final fields = find.descendant(of: find.byType(Dialog).last, matching: find.byType(TextField));
    await tester.enterText(fields.at(0), '6');
    await tester.enterText(fields.at(1), '30');
    await tester.tap(find.text('PM'));
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.text('Prints ahead of its time by the quote'), findsOneWidget); // tomorrow is not tonight

    await tester.tap(find.byKey(const ValueKey('takeout-start')));
    await tester.pumpAndSettle();
    final data = t.hub.sent.single.$2['data'] as Map<String, dynamic>;
    expect((data['quoted_minutes'], data['for_later']), (15, true));
    await stop(tester);
  });

  testWidgets('an order that becomes big is said, shown later in the title, and settled as it is paid and sent', (
    tester,
  ) async {
    final order = quoted('o1');
    final t = await pumpOrder(tester, order, before: (hub) => hub.quotes = quotesNow(dishes: 3, minutes: 10));
    // The pretend hub plays its part: a dish added shows on the order it serves.
    t.hub.onOp = (id, op) {
      if (op['kind'] != 'add_line') return;
      order['lines'] = <String, dynamic>{
        ...order['lines'] as Map<String, dynamic>,
        'L2': {'item': 'Spring roll', 'qty': 1, 'seat': 1, 'course': '2', 'status': 'active', 'fired': false},
      };
    };
    expect(find.text('#7 Linda · ${clockTime(promised)}'), findsOneWidget);
    expect(find.byKey(const ValueKey('big-order-said')), findsNothing); // two dishes: not a big order

    await tester.tap(find.text('Appetizers').last); // the category's tile
    await tester.pumpAndSettle();
    await tester.tap(find.text('Spring roll'));
    await tester.pumpAndSettle();
    final later = promised + 10 * 60000;
    expect(find.text('Big order: ready at ${clockTime(later)}, 10 minutes later.'), findsOneWidget);
    expect(find.text('#7 Linda · ${clockTime(later)}'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Pay & send'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('pay-send')));
    await tester.pumpAndSettle();
    final ops = t.hub.opsFor('o1');
    expect(ops.map((op) => op['kind']), ['add_line', 'pay', 'set_field', 'fire']);
    expect(ops[2]['data'], {'quoted_minutes': 25, 'promised_at': later});
    await stop(tester);
  });

  testWidgets('a time the customer named does not move for a big order: the kitchen starts it sooner', (tester) async {
    final at = inMinutes(180);
    final t = await pumpOrder(
      tester,
      quoted('o2', channel: 'phone', quote: 20, at: at, forLater: true),
      before: (hub) => hub.quotes = quotesNow(dishes: 2, minutes: 10),
    );
    // Big as it opens (the same again as last time): said once, and the title keeps the time.
    expect(
      find.text('Big order: the kitchen starts it 10 minutes sooner. Still for ${clockTime(at)}.'),
      findsOneWidget,
    );
    expect(find.text('#7 Linda · ${clockTime(at)}'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Pay & send'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('pay:later')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('pay-send')));
    await tester.pumpAndSettle();
    final ops = t.hub.opsFor('o2');
    expect(ops.map((op) => op['kind']), ['set_field', 'fire']);
    expect(ops.first['data'], {'quoted_minutes': 30}); // ahead of its time by ten more minutes; the time stays
    await stop(tester);
  });

  testWidgets('Send settles a paid big order too; one the kitchen already has keeps its time', (tester) async {
    final t = await pumpOrder(
      tester,
      quoted('o3', payments: cash),
      paid: true,
      before: (hub) => hub.quotes = quotesNow(dishes: 2, minutes: 10),
    );
    final later = promised + 10 * 60000;
    expect(find.text('#7 Linda · ${clockTime(later)}'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Send'));
    await tester.pumpAndSettle();
    final ops = t.hub.opsFor('o3');
    expect(ops.map((op) => op['kind']), ['set_field', 'fire']);
    expect(ops.first['data'], {'quoted_minutes': 25, 'promised_at': later});
    expect(find.text('next customer'), findsOneWidget);
    await stop(tester);

    await pumpOrder(
      tester,
      quoted('o4', fired: true, payments: cash),
      paid: true,
      before: (hub) => hub.quotes = quotesNow(dishes: 2, minutes: 10),
    );
    expect(find.text('#7 Linda · ${clockTime(promised)}'), findsOneWidget);
    expect(find.byKey(const ValueKey('big-order-said')), findsNothing);
    await stop(tester);
  });

  testWidgets('a manager sets the big-order rule with the quote times; one box alone is not a rule', (tester) async {
    final t = await pumpOrders(tester, const [], before: (hub) async => hub.quotes = quotesNow(rush: 20));
    await tester.tap(find.byTooltip('Location'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '9999');
    await tester.tap(find.widgetWithText(FilledButton, 'Open location settings'));
    await tester.pumpAndSettle();
    await bringUp(tester, 'quote-times');
    expect(
      find.text('Counter 15 · Phone 20 · Online 25 · Delivery 45 · Catering 60 min'),
      findsOneWidget,
    ); // not the rush
    await tester.tap(find.byKey(const ValueKey('quote-times')));
    await tester.pumpAndSettle();
    expect(find.text('Big orders'), findsOneWidget);
    expect(tester.widget<TextField>(find.byKey(const ValueKey('quote:counter'))).controller!.text, '15');
    expect(tester.widget<TextField>(find.byKey(const ValueKey('big-dishes'))).controller!.text, '');

    await tester.enterText(find.byKey(const ValueKey('big-dishes')), '8');
    await tester.tap(find.byKey(const ValueKey('quotes-save')));
    await tester.pumpAndSettle();
    expect(find.text('For big orders, fill in both the dishes and the minutes, or leave both empty'), findsOneWidget);
    expect(t.hub.quotesAuth, isNull);

    await tester.enterText(find.byKey(const ValueKey('big-minutes')), '10');
    await tester.tap(find.byKey(const ValueKey('quotes-save')));
    await tester.pumpAndSettle();
    expect(t.hub.quotesAuth, 'Bearer tok-admin');
    expect(t.hub.quotes['big_orders'], {'dishes': 8, 'minutes': 10});
    expect((t.hub.quotes['minutes'] as Map)['counter'], 15); // the channel's own minutes, not the rush on top
    expect((t.hub.quotes['rush'] as Map)['minutes'], 20); // saving the quote times leaves the rush alone
    expect(find.text('Quote times saved'), findsOneWidget);
    expect(
      find.text('Counter 15 · Phone 20 · Online 25 · Delivery 45 · Catering 60 min · 8 dishes or more +10'),
      findsOneWidget,
    );
    await stop(tester);
  });

  testWidgets('a hub from before big orders is not offered the boxes', (tester) async {
    await pumpOrders(tester, const []);
    await tester.tap(find.byTooltip('Location'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '9999');
    await tester.tap(find.widgetWithText(FilledButton, 'Open location settings'));
    await tester.pumpAndSettle();
    await bringUp(tester, 'quote-times');
    await tester.tap(find.byKey(const ValueKey('quote-times')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('quote:counter')), findsOneWidget);
    expect(find.text('Big orders'), findsNothing);
    expect(find.byKey(const ValueKey('big-dishes')), findsNothing);
    await stop(tester);
  });

  testWidgets('the list marks an order for later as its start nears, and when it passed with nothing sent', (
    tester,
  ) async {
    final soon = inMinutes(30); // quoted 20: it starts in ten minutes
    final past = inMinutes(10); // it should have started ten minutes ago
    final far = inMinutes(180);
    await pumpOrders(tester, [
      quoted('o1', no: 1, quote: 20, at: soon, forLater: true),
      quoted('o2', no: 2, quote: 20, at: soon, forLater: true, fired: true),
      quoted('o3', no: 3, quote: 20, at: past, forLater: true),
      quoted('o4', no: 4, quote: 20, at: far, forLater: true),
      quoted('o5', no: 5, quote: 20, at: soon), // as soon as it can be: no time was named
      quoted('o6', no: 6, quote: 20, at: past, forLater: true, fired: true), // the kitchen has it
    ]);
    Finder mark(String id) => find.byKey(ValueKey('later-$id'));
    String said(String id) => tester.widget<Text>(find.descendant(of: mark(id), matching: find.byType(Text))).data!;
    expect(said('o1'), 'Send by ${clockTime(soon - 20 * 60000)}');
    expect(said('o2'), 'Starts ${clockTime(soon - 20 * 60000)}');
    expect(said('o3'), 'Not sent, due to start ${clockTime(past - 20 * 60000)}');
    for (final id in ['o4', 'o5', 'o6']) {
      expect(mark(id), findsNothing);
    }
    // The amber of a table's timer for "soon", its red for "not sent".
    Color fill(String id) =>
        (tester.widget<Container>(find.descendant(of: mark(id), matching: find.byType(Container))).decoration!
                as BoxDecoration)
            .color!;
    expect(fill('o1'), fill('o2'));
    expect(fill('o3'), isNot(fill('o1')));

    // (with its day, should the time fall past midnight)
    expect(find.text('2 items · open · for ${whenFor(far, DateTime.now())} · pay at pickup'), findsOneWidget);
    expect(find.text('2 items · open · ready ${clockTime(soon)} · pay at pickup'), findsOneWidget);
    await stop(tester);
  });

  testWidgets('the mark comes by itself when the time does, with nothing redrawn in between', (tester) async {
    // Quoted 20, for 35 minutes and a second and a half from now: "soon" begins in a second and a half.
    final at = DateTime.now().add(const Duration(minutes: 35, milliseconds: 1500)).millisecondsSinceEpoch;
    await pumpOrders(tester, [quoted('o1', quote: 20, at: at, forLater: true)]);
    expect(find.byKey(const ValueKey('later-o1')), findsNothing);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1700)));
    await tester.pump(const Duration(seconds: 4));
    expect(find.byKey(const ValueKey('later-o1')), findsOneWidget);
    await stop(tester);
  });
}
