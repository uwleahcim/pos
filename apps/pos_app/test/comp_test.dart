import 'package:flutter/gestures.dart' show kLongPressTimeout;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/menu.dart';
import 'package:pos_app/pricing.dart';
import 'package:pos_app/screens/comp_menu.dart';
import 'package:pos_app/screens/order_screen.dart';

import 'hub.dart';

/// Comps from the check (Mike, 2026-11-03): hold a dish's price and a menu offers the reasons the rules
/// allow on one item, each with what it gives. A fixed one (a comp, a staff meal) goes straight to the
/// manager's PIN and onto the item; one with a range asks how much first. A comped line stays on the check
/// and shows the comp, and the menu takes it off again. A tap on the price still opens the dish.
///
/// On the check (Mike, 2026-11-03) the dish's line shows its full price, choices included; each choice is a
/// line of its own with what it changes ("+0.50"); a discount is a line after the choices with what came
/// off in parentheses, "(30.00)", and the dish's old price struck through over the new one. A comp follows
/// the dish through an edit (which voids the line and adds the changed one in its place).

const rules = {
  'discounts': [
    {
      'code': 'comp',
      'name': 'Manager comp',
      'kinds': ['comp'],
      'approval': 'manager',
    },
    {
      'code': 'staff_meal',
      'name': 'Staff meal',
      'kinds': ['percent'],
      'fixed_percent': '50',
      'approval': 'manager',
    },
    {
      'code': 'loyalty',
      'name': 'Loyalty reward',
      'kinds': ['percent', 'amount'],
      'max_percent': '20',
      'max_amount': '20',
      'approval': 'none',
    },
    {
      'code': 'service_recovery',
      'name': 'Service recovery',
      'kinds': ['percent', 'amount', 'comp'],
      'max_percent': '100',
      'approval': 'manager',
    },
    {
      'code': 'birthday',
      'name': 'Birthday',
      'kinds': ['percent'],
      'max_percent': '10',
      'approval': 'none',
      'stacks': true,
    },
    {
      'code': 'happy_hour',
      'name': 'Happy hour',
      'kinds': ['percent'],
      'scopes': ['check'],
      'max_percent': '30',
      'approval': 'none',
    },
  ],
  'charges': [],
};

const gtc = "General Tso's Chicken (Quart)";

Map<String, dynamic> comped(String id, String lineId, String amount) => {
  'discount_id': id,
  'reason': 'comp',
  'name': 'Manager comp',
  'kind': 'comp',
  'value': '0',
  'line_id': lineId,
  'amount': amount,
  'applied_by': 'Amy',
  'approved_by': {'staff_id': 's3', 'name': 'Mike'},
};

/// The hub's check: an egg roll with two choices (one costs something), a comped duck, and a comped
/// General Tso's from a hub that still sends its choices as labels alone.
final check = {
  'lines': [
    {
      'line_id': 'L1',
      'name': 'Egg roll',
      'qty': 1,
      'total': '3.00',
      'modifiers': [
        {'label': 'Extra sauce', 'price': '0.50', 'amount': '0.50'},
        {'label': 'No scallions', 'price': '0', 'amount': '0.00'},
      ],
    },
    {'line_id': 'L2', 'name': 'Peking Duck', 'qty': 1, 'total': '30.00', 'discount': '30.00'},
    {
      'line_id': 'L3',
      'name': gtc,
      'qty': 1,
      'total': '25.95',
      'discount': '25.95',
      'modifiers': ['Brown rice'],
    },
  ],
  'subtotal': '58.95',
  'discounts': [comped('D1', 'L2', '30.00'), comped('D2', 'L3', '25.95')],
  'discount_total': '55.95',
  'tax_lines': [
    {'name': 'Massachusetts meals tax', 'rate_pct': '6.25', 'amount': '0.19'},
    {'name': 'Winchester meals tax', 'rate_pct': '0.75', 'amount': '0.02'},
  ],
  'tax_rate_pct': '7.00',
  'tax': '0.21',
  'total': '3.21',
};

Map<String, dynamic> dish(String item, {bool fired = false, Map<String, dynamic>? request, String? itemId}) => {
  'item': item,
  'qty': 1,
  'seat': 1,
  'course': '2',
  'status': 'active',
  'fired': fired,
  'request': ?request,
  if (itemId != null) 'priced': {'item': itemId, 'entry_id': 'dinner:87'},
};

CheckDiscount discount(String reason, String name, String kind, String value, {String? lineId}) => CheckDiscount(
  discountId: 'D-$reason',
  reason: reason,
  name: name,
  kind: kind,
  value: value,
  amount: '1.00',
  lineId: lineId,
);

/// The order screen on the pretend hub, signed in as Amy; the hub approves PIN 9999 as Mike.
Future<Terminal> pump(WidgetTester tester) async {
  final t = await terminal(tester);
  t.hub.rules = rules;
  t.hub.check = check;
  t.hub.orders.add(
    table('o1', {
      'L1': dish('Egg roll'),
      'L2': dish('Peking Duck', fired: true),
      'L3': dish(
        gtc,
        itemId: 'GTC',
        request: {
          'variant_id': 'GTC:quart',
          'entry_id': 'dinner:87',
          'selections': [
            {'group_id': 'rice', 'option_id': 'rice:brown'},
          ],
        },
      ),
    }),
  );
  await tester.pumpWidget(
    MaterialApp(
      home: OrderScreen(api: t.api, outbox: t.outbox, photos: t.photos, orderId: 'o1', staffName: 'Amy'),
    ),
  );
  await tester.pumpAndSettle();
  return t;
}

Finder price(String lineId) => find.byKey(ValueKey('price-$lineId'));

Finder reason(String code) => find.byKey(ValueKey('comp:$code'));

/// The whole row of a dish on the check.
Finder tile(String name) => find.ancestor(of: find.text(name), matching: find.byType(ListTile)).first;

Finder inTile(String name, String text) => find.descendant(of: tile(name), matching: find.text(text));

TextDecoration? decorationOf(WidgetTester tester, Finder text) => tester.widget<Text>(text).style?.decoration;

Future<void> holdPrice(WidgetTester tester, String lineId) async {
  await tester.longPress(price(lineId));
  await tester.pumpAndSettle();
}

Future<void> enterPin(WidgetTester tester, String pin) async {
  await tester.enterText(find.byKey(const ValueKey('approval-pin')), pin);
  await tester.tap(find.byKey(const ValueKey('approve')));
  await tester.pumpAndSettle();
}

Map<String, dynamic> dataOf(Map<String, dynamic> op) => op['data'] as Map<String, dynamic>;

void main() {
  group('the menu', () {
    final parsed = PricingRules.fromJson(rules);

    test('offers the reasons the rules allow on one item, with what each gives', () {
      final choices = compChoices(parsed, const [], 'L1');
      // happy hour is for the whole check only
      expect(choices.map((c) => c.rule.code), ['comp', 'staff_meal', 'loyalty', 'service_recovery', 'birthday']);
      expect(choices.map((c) => c.gives), ['free', '50% off', 'up to 20% or \$20', 'any amount', 'up to 10%']);
      expect(choices.map((c) => c.asksHowMuch), [false, false, true, true, true]);
      expect(choices.map((c) => c.enabled), everyElement(isTrue));
    });

    test('greys out what cannot go on top of a discount already on the item or on the whole check', () {
      final comped = [discount('comp', 'Manager comp', 'comp', '0', lineId: 'L2')];
      expect(compChoices(parsed, comped, 'L2').map((c) => c.enabled), everyElement(isFalse));
      expect(compChoices(parsed, comped, 'L1').map((c) => c.enabled), everyElement(isTrue));
      final whole = [discount('loyalty', 'Loyalty reward', 'percent', '10')];
      expect(compChoices(parsed, whole, 'L1').map((c) => c.enabled), everyElement(isFalse));
      // a discount that stacks takes another that stacks, and nothing else
      final stacking = [discount('birthday', 'Birthday', 'percent', '10', lineId: 'L1')];
      expect(compChoices(parsed, stacking, 'L1').map((c) => (c.rule.code, c.enabled)), [
        ('comp', false),
        ('staff_meal', false),
        ('loyalty', false),
        ('service_recovery', false),
        ('birthday', true),
      ]);
    });

    test('names a comp on a line by what it is', () {
      expect(compLabel(discount('comp', 'Manager comp', 'comp', '0', lineId: 'L2')), 'Comped · Manager comp');
      expect(compLabel(discount('staff_meal', 'Staff meal', 'percent', '50', lineId: 'L2')), '50% off · Staff meal');
      expect(compLabel(discount('loyalty', 'Loyalty reward', 'amount', '5', lineId: 'L2')), '\$5 off · Loyalty reward');
    });
  });

  testWidgets('holding the price of a dish opens the comp menu; a manager comp asks the PIN and goes on the item', (
    tester,
  ) async {
    final t = await pump(tester);
    await holdPrice(tester, 'L1');
    expect(find.text('Egg roll · 3.00'), findsOneWidget);
    expect(reason('comp'), findsOneWidget);
    expect(reason('happy_hour'), findsNothing);
    expect(find.text('free'), findsOneWidget);

    await tester.tap(reason('comp'));
    await tester.pumpAndSettle();
    expect(find.text('Manager comp needs a manager.'), findsOneWidget);
    await enterPin(tester, '1111');
    expect(find.text('Only a manager can approve this'), findsOneWidget);
    expect(t.hub.sent, isEmpty);
    await enterPin(tester, '9999');

    expect(t.hub.pins, ['1111', '9999']);
    final op = t.hub.opsFor('o1').single;
    expect(op['kind'], 'discount');
    final data = dataOf(op);
    expect(data['discount_id'], isNotEmpty);
    expect(
      (data['reason'], data['kind'], data['line_id'], data['approval'], data['applied_by']),
      ('comp', 'comp', 'L1', 'tok-o1', 'Amy'),
    );
    expect(data.containsKey('value'), isFalse);
  });

  testWidgets('a reason with a range asks how much first; a loyalty reward needs no PIN', (tester) async {
    final t = await pump(tester);
    await holdPrice(tester, 'L1');
    await tester.tap(reason('loyalty'));
    await tester.pumpAndSettle();
    expect(find.text('Loyalty reward on Egg roll'), findsOneWidget);
    expect(find.byKey(const ValueKey('preset:50')), findsNothing); // over the 20% cap
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('how-much-apply'))).onPressed, isNull);

    await tester.tap(find.byKey(const ValueKey('preset:10')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('how-much-apply')));
    await tester.pumpAndSettle();

    expect(t.hub.pins, isEmpty);
    final data = dataOf(t.hub.opsFor('o1').single);
    expect((data['reason'], data['kind'], data['value'], data['line_id']), ('loyalty', 'percent', '10', 'L1'));
    expect(data.containsKey('approval'), isFalse);
  });

  testWidgets('an amount off is typed, within the cap', (tester) async {
    final t = await pump(tester);
    await holdPrice(tester, 'L1');
    await tester.tap(reason('loyalty'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('kind:amount')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('how-much-value')), '25');
    await tester.pumpAndSettle();
    expect(find.text('At most \$20'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('how-much-apply'))).onPressed, isNull);

    await tester.enterText(find.byKey(const ValueKey('how-much-value')), '1.50');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('how-much-apply')));
    await tester.pumpAndSettle();
    final data = dataOf(t.hub.opsFor('o1').single);
    expect((data['reason'], data['kind'], data['value'], data['line_id']), ('loyalty', 'amount', '1.50', 'L1'));
  });

  testWidgets('service recovery offers free as well as a percentage or an amount', (tester) async {
    final t = await pump(tester);
    await holdPrice(tester, 'L1');
    await tester.tap(reason('service_recovery'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('kind:comp')));
    await tester.pumpAndSettle();
    expect(find.text('The item comes to nothing.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('how-much-apply')));
    await tester.pumpAndSettle();
    await enterPin(tester, '9999');
    expect(t.hub.pins, ['9999']);
    final data = dataOf(t.hub.opsFor('o1').single);
    expect(
      (data['reason'], data['kind'], data['line_id'], data['approval']),
      ('service_recovery', 'comp', 'L1', 'tok-o1'),
    );
    expect(data.containsKey('value'), isFalse);
  });

  testWidgets('the dish shows its full price; each choice is its own line with what it changes', (tester) async {
    await pump(tester);
    expect(inTile('Egg roll', '3.00'), findsOneWidget); // the dish with its choices
    expect(decorationOf(tester, inTile('Egg roll', '3.00')), isNot(TextDecoration.lineThrough));
    expect(inTile('Egg roll', 'Extra sauce'), findsOneWidget);
    expect(inTile('Egg roll', '+0.50'), findsOneWidget); // what the choice changes, not a new total
    expect(inTile('Egg roll', 'No scallions'), findsOneWidget);
    expect(inTile('Egg roll', '0.00'), findsNothing); // a free choice shows no amount
    expect(inTile('Egg roll', '+0.00'), findsNothing);
    expect(inTile('Egg roll', '2.50'), findsNothing); // no price without the choices
    // a hub that still sends labels alone
    expect(inTile(gtc, 'Brown rice'), findsOneWidget);
    expect(find.text('Extra sauce · No scallions'), findsNothing); // no longer one line of text
  });

  testWidgets(
    'a comped line shows its old price struck over the new one and what came off in (); the menu takes it off',
    (tester) async {
      final t = await pump(tester);
      expect(decorationOf(tester, inTile('Peking Duck', '30.00')), TextDecoration.lineThrough);
      expect(inTile('Peking Duck', '0.00'), findsOneWidget); // the new price, under the old one
      expect(
        tester.getTopLeft(inTile('Peking Duck', '0.00')).dy,
        greaterThan(tester.getTopLeft(inTile('Peking Duck', '30.00')).dy),
      );
      expect(inTile('Peking Duck', 'Comped · Manager comp'), findsOneWidget);
      expect(inTile('Peking Duck', '(30.00)'), findsOneWidget); // the accounting way to show what came off
      expect(inTile('Peking Duck', '−30.00'), findsNothing);
      expect(decorationOf(tester, inTile(gtc, '25.95')), TextDecoration.lineThrough);
      expect(inTile(gtc, '(25.95)'), findsOneWidget);
      expect(inTile(gtc, '0.00'), findsOneWidget);
      // the footer says it the same way
      expect(find.text('(30.00)'), findsNWidgets(2));

      await holdPrice(tester, 'L2');
      expect(find.byKey(const ValueKey('uncomp:D1')), findsOneWidget);
      expect((tester.widget(reason('loyalty')) as PopupMenuItem).enabled, isFalse);
      expect((tester.widget(reason('comp')) as PopupMenuItem).enabled, isFalse);
      await tester.tap(find.byKey(const ValueKey('uncomp:D1')));
      await tester.pumpAndSettle();
      final op = t.hub.opsFor('o1').single;
      expect(op['kind'], 'remove_discount');
      expect(dataOf(op), {'discount_id': 'D1'});
    },
  );

  testWidgets('changing a comped dish keeps its comp: the new line says which line it replaces', (tester) async {
    final t = await pump(tester);
    await tester.tap(find.text(gtc)); // a tap on the line opens the dish
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 200)); // the sheet prices the dish as it opens
    await tester.pumpAndSettle();
    await tester.tap(find.text('Update'));
    await tester.pumpAndSettle();

    final ops = t.hub.opsFor('o1');
    expect(ops.map((o) => o['kind']), ['void_line', 'add_line']);
    expect(dataOf(ops.first)['line_id'], 'L3');
    final added = dataOf(ops.last);
    expect(added['replaces'], 'L3');
    expect(added['line_id'], isNot('L3'));
    // the changed dish is still comped on the screen: the sheet's 26.95 (rice included) struck through over
    // 0.00, the rice's +1.00 on its line, the comp after it with (26.95); nobody was asked again
    expect(decorationOf(tester, inTile(gtc, '26.95')), TextDecoration.lineThrough);
    expect(inTile(gtc, '0.00'), findsOneWidget);
    expect(inTile(gtc, 'Brown rice'), findsOneWidget);
    expect(inTile(gtc, '+1.00'), findsOneWidget);
    expect(decorationOf(tester, inTile(gtc, '+1.00')), isNot(TextDecoration.lineThrough));
    expect(inTile(gtc, 'Comped · Manager comp'), findsOneWidget);
    expect(inTile(gtc, '(26.95)'), findsOneWidget);
    expect(inTile(gtc, '25.95'), findsNothing);
    // the price lines in order: the choice, then the discount, then the line's state
    final rows = [inTile(gtc, 'Brown rice'), inTile(gtc, 'Comped · Manager comp'), inTile(gtc, 'not sent yet')];
    final tops = [for (final r in rows) tester.getTopLeft(r).dy];
    expect(tops, [...tops]..sort());
    expect(find.text('Manager comp · on $gtc · Mike approved'), findsOneWidget);
    expect(t.hub.pins, isEmpty);
  });

  testWidgets('taking a comped dish off the check takes its comp off too', (tester) async {
    final t = await pump(tester);
    expect(find.byKey(const ValueKey('discount-D1')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('bin-L2'))); // the duck went to the kitchen: a void, confirmed
    await tester.pumpAndSettle();
    await tester.tap(find.text('Void'));
    await tester.pumpAndSettle();
    expect(t.hub.opsFor('o1').map((op) => op['kind']), ['void_line']);
    expect(inTile('Peking Duck', 'void'), findsOneWidget); // the voided line stays on the check, as a void
    expect(inTile('Peking Duck', 'Comped · Manager comp'), findsNothing);
    expect(find.byKey(const ValueKey('discount-D1')), findsNothing);
    expect(find.text('Manager comp · on Peking Duck · Mike approved'), findsNothing);
    expect(find.byKey(const ValueKey('discount-D2')), findsOneWidget); // the other comp is untouched
    expect(t.hub.opsFor('o1').where((op) => op['kind'] == 'remove_discount'), isEmpty); // the log keeps the comp
  });

  testWidgets('a tap on the price still opens the dish', (tester) async {
    final t = await pump(tester);
    await tester.tap(price('L1'));
    await tester.pumpAndSettle();
    expect(reason('comp'), findsNothing);
    expect(find.text('This line has no menu choices to change. Remove it and add it again.'), findsOneWidget);
    expect(t.hub.sent, isEmpty);
  });

  testWidgets('while a dish is in hand, holding a price opens nothing', (tester) async {
    final t = await pump(tester);
    final gesture = await tester.startGesture(tester.getCenter(find.text('Egg roll')));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    expect(find.byKey(const ValueKey('check-stack')), findsOneWidget); // the egg roll is in hand
    await tester.longPress(price('L2'));
    await tester.pumpAndSettle();
    expect(reason('comp'), findsNothing);
    expect(find.byKey(const ValueKey('uncomp:D1')), findsNothing);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(t.hub.opsFor('o1').where((op) => op['kind'] == 'discount' || op['kind'] == 'remove_discount'), isEmpty);
    await stop(tester);
  });
}
