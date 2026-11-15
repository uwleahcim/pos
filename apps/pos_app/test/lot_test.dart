import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/menu.dart';
import 'package:pos_app/pricing.dart';
import 'package:pos_app/screens/lot_comp_dialog.dart';
import 'package:pos_app/screens/order_screen.dart';
import 'package:pos_app/session.dart';

import 'comp_test.dart' as comps show rules;
import 'hub.dart';
import 'move_lines_test.dart' show holdRow, inCheck, inList, moveTo, settleRows, stack;
import 'voids_test.dart' as voids show rules;

/// Comp and Void for the dishes picked up on the check (the Toast comparison, 2026-11-15): while dishes are
/// in hand the foot of the check offers Comp and Void; let go over one and all of them are comped or voided
/// with one reason and, where one is needed, one manager's PIN, sent as one change. A dish the kitchen has
/// not seen still comes off with nothing asked.

Map<String, dynamic> priced(String id, String name, String total, {String discount = '0.00'}) => {
  'line_id': id,
  'name': name,
  'qty': 1,
  'total': total,
  'discount': discount,
};

/// The hub's check for the four dishes: the duck already comped.
final check = {
  'lines': [
    priced('L1', 'Egg roll', '3.00'),
    priced('L2', 'Peking Duck', '48.00', discount: '48.00'),
    priced('L3', 'Hot tea', '2.50'),
    priced('L4', 'Fried rice', '9.00'),
  ],
  'subtotal': '62.50',
  'discounts': [
    {
      'discount_id': 'D1',
      'reason': 'comp',
      'name': 'Manager comp',
      'kind': 'comp',
      'value': '0',
      'line_id': 'L2',
      'amount': '48.00',
    },
  ],
  'discount_total': '48.00',
  'tax_lines': [
    {'name': 'Meals tax', 'rate_pct': '7.00', 'amount': '1.02'},
  ],
  'tax_rate_pct': '7.00',
  'tax': '1.02',
  'total': '15.52',
};

/// Four dishes on table A1, Amy signed in: the egg roll and the rice not sent yet, the duck and the tea at
/// the kitchen. The hub asks a manager for voids and has the comp tests' reasons.
Future<Terminal> pumpOrder(WidgetTester tester, {bool comped = false, Size? size}) async {
  final t = await terminal(tester);
  if (size != null) tester.view.physicalSize = size;
  t.session.staff = const Staff(staffId: 's1', name: 'Amy', role: 'server', method: 'pin');
  t.hub.voids = voids.rules;
  t.hub.rules = comps.rules;
  t.hub.check = comped ? check : {...check, 'discounts': <Map<String, dynamic>>[], 'discount_total': '0.00'};
  t.hub.orders.add(
    table('o1', {
      'L1': line('Egg roll', rank: 1),
      'L2': line('Peking Duck', fired: true, rank: 2),
      'L3': line('Hot tea', fired: true, rank: 3),
      'L4': line('Fried rice', rank: 4),
    }),
  );
  await tester.pumpWidget(
    MaterialApp(
      home: OrderScreen(api: t.api, outbox: t.outbox, photos: t.photos, orderId: 'o1', session: t.session),
    ),
  );
  await tester.pumpAndSettle();
  return t;
}

Finder target(String id) => find.byKey(ValueKey('lot-target:$id'));

/// Holds [held] by its name, taps [others] to stack them behind it, and leaves them all in hand.
Future<(TestGesture, Offset)> pickUp(WidgetTester tester, String held, [List<String> others = const []]) async {
  final from = tester.getCenter(inCheck(held));
  final gesture = await holdRow(tester, inCheck(held));
  await settleRows(tester);
  for (final other in others) {
    await tester.tap(inList(other));
    await settleRows(tester);
  }
  return (gesture, from);
}

/// Carries what is in hand onto a target at the foot of the check and lets go there.
Future<void> dropOn(WidgetTester tester, TestGesture gesture, Offset from, String id) async {
  await moveTo(tester, gesture, from, tester.getCenter(target(id)));
  await gesture.up();
  await tester.pumpAndSettle();
}

Future<void> pin(WidgetTester tester, String digits) async {
  await tester.enterText(find.byKey(const ValueKey('approval-pin')), digits);
  await tester.tap(find.byKey(const ValueKey('approve')));
  await tester.pumpAndSettle();
}

Map<String, dynamic> dataOf(Map<String, dynamic> op) => (op['data'] as Map).cast<String, dynamic>();

void main() {
  test('a reason is offered for the dishes it can go on, and not at all when it can go on none', () {
    final rules = PricingRules.fromJson(comps.rules);
    const comp = CheckDiscount(
      discountId: 'D1',
      reason: 'comp',
      name: 'Manager comp',
      kind: 'comp',
      value: '0',
      amount: '48.00',
      lineId: 'L2',
    );
    final free = lotChoices(rules, const [], ['L1', 'L2', 'L3']);
    // the reasons for one item, in the rules' order; the one for a whole check is not among them
    expect(free.map((c) => c.rule.code), ['comp', 'staff_meal', 'loyalty', 'service_recovery', 'birthday']);
    expect(free.every((c) => c.lineIds.length == 3), isTrue);
    expect(free.map((c) => c.asksHowMuch), [false, false, true, true, true]);

    // the duck is comped already: nothing goes on top of it
    final some = lotChoices(rules, const [comp], ['L1', 'L2', 'L3']);
    expect(some.first.lineIds, ['L1', 'L3']);
    expect(lotChoices(rules, const [comp], ['L2']), isEmpty);

    final chosen = LotComp(rule: some.first.rule, kind: 'comp', lineIds: some.first.lineIds);
    expect(chosen.discounts, [
      {'reason': 'comp', 'kind': 'comp', 'line_id': 'L1'},
      {'reason': 'comp', 'kind': 'comp', 'line_id': 'L3'},
    ]);
    final half = LotComp(rule: some[1].rule, kind: 'percent', value: '50', lineIds: const ['L1']);
    expect(half.discounts.single, {'reason': 'staff_meal', 'kind': 'percent', 'value': '50', 'line_id': 'L1'});
    expect((dishes(1), dishes(3)), ('1 dish', '3 dishes'));
  });

  testWidgets('with dishes in hand the foot of the check offers Comp and Void, and says how many', (tester) async {
    final t = await pumpOrder(tester);
    expect(find.byKey(const ValueKey('lot-targets')), findsNothing);

    final (gesture, _) = await pickUp(tester, 'Egg roll');
    expect(find.byKey(const ValueKey('lot-targets')), findsOneWidget);
    // one dish the kitchen has not seen: it would simply come off
    expect(find.descendant(of: target('comp'), matching: find.text('Comp')), findsOneWidget);
    expect(find.descendant(of: target('void'), matching: find.text('Take off')), findsOneWidget);

    await tester.tap(inList('Fried rice'));
    await settleRows(tester);
    expect(find.descendant(of: target('void'), matching: find.text('Take off 2')), findsOneWidget);
    await tester.tap(inList('Peking Duck')); // the kitchen has this one: a void
    await settleRows(tester);
    expect(find.descendant(of: target('comp'), matching: find.text('Comp 3')), findsOneWidget);
    expect(find.descendant(of: target('void'), matching: find.text('Void 3')), findsOneWidget);

    // put back down where it was: nothing is sent, and the targets go
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('lot-targets')), findsNothing);
    expect(stack(), findsNothing);
    expect(t.hub.opsFor('o1').where((op) => op['kind'] != 'set_line'), isEmpty);
    await stop(tester);
  });

  testWidgets('dishes the kitchen has not seen come off together with nothing asked', (tester) async {
    final t = await pumpOrder(tester);
    final (gesture, from) = await pickUp(tester, 'Egg roll', ['Fried rice']);
    await dropOn(tester, gesture, from, 'void');
    expect(find.byType(AlertDialog), findsNothing);
    final ops = t.hub.opsFor('o1');
    expect(ops.map((op) => op['kind']), ['void_line', 'void_line']);
    expect(ops.map(dataOf), [
      {'line_id': 'L1', 'by': 'Amy', 'by_id': 's1'},
      {'line_id': 'L4', 'by': 'Amy', 'by_id': 's1'},
    ]);
    expect(t.hub.pins, isEmpty);
    await stop(tester);
  });

  testWidgets('sent dishes are voided together with one reason and one manager PIN', (tester) async {
    final t = await pumpOrder(tester);
    final (gesture, from) = await pickUp(tester, 'Peking Duck', ['Hot tea', 'Egg roll']);
    await dropOn(tester, gesture, from, 'void');
    expect(find.text('Void 2 dishes?'), findsOneWidget);
    expect(
      find.text(
        '1 × Peking Duck, 1 × Hot tea. They have gone to the kitchen. A VOID ticket prints so they stop '
        'making them. The other dish was not sent and just comes off.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Kitchen error'));
    await tester.pumpAndSettle();
    expect(find.text('Voiding 2 dishes (Kitchen error) needs a manager.'), findsOneWidget);
    expect(t.hub.opsFor('o1'), isEmpty);
    await pin(tester, '9999');

    expect(t.hub.pins, ['9999']); // asked once for all of them
    expect(t.hub.purposes, ['void']);
    final ops = t.hub.opsFor('o1');
    expect(ops.map((op) => op['kind']), ['void_line', 'void_line', 'void_line']);
    const word = {'reason': 'kitchen-error', 'by': 'Amy', 'by_id': 's1', 'approval': 'tok-o1'};
    expect(ops.map(dataOf), [
      {'line_id': 'L2', ...word},
      {'line_id': 'L3', ...word},
      {'line_id': 'L1', 'by': 'Amy', 'by_id': 's1'}, // never sent: no reason, no approval
    ]);
    // one change: the kitchen gets one VOID ticket
    expect(t.hub.batches.last.length, 3);
    expect(find.byType(AlertDialog), findsNothing);
    await stop(tester);
  });

  testWidgets('keeping them, or walking away from the PIN, keeps every dish', (tester) async {
    final t = await pumpOrder(tester);
    var (gesture, from) = await pickUp(tester, 'Peking Duck', ['Egg roll']);
    await dropOn(tester, gesture, from, 'void');
    expect(find.text('Void Peking Duck?'), findsOneWidget); // one sent dish is named
    await tester.tap(find.text('Keep it'));
    await tester.pumpAndSettle();
    expect(t.hub.opsFor('o1'), isEmpty);

    (gesture, from) = await pickUp(tester, 'Peking Duck', ['Egg roll']);
    await dropOn(tester, gesture, from, 'void');
    await tester.tap(find.text('Rung in wrong'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(t.hub.opsFor('o1'), isEmpty); // not even the unsent one came off
    expect(inCheck('Egg roll'), findsOneWidget);
    await stop(tester);
  });

  testWidgets('dishes are comped together with one reason and one manager PIN, each with its own discount', (
    tester,
  ) async {
    final t = await pumpOrder(tester);
    final (gesture, from) = await pickUp(tester, 'Egg roll', ['Hot tea', 'Fried rice']);
    await dropOn(tester, gesture, from, 'comp');
    expect(find.text('Comp 3 dishes'), findsOneWidget);
    for (final dish in const ['1 × Egg roll', '1 × Hot tea', '1 × Fried rice']) {
      expect(find.text(dish), findsOneWidget);
    }
    expect(find.text('One reason for all of them'), findsOneWidget);
    expect(find.byKey(const ValueKey('lot-comp:happy_hour')), findsNothing); // a whole check's reason
    await tester.tap(find.byKey(const ValueKey('lot-comp:comp')));
    await tester.pumpAndSettle();
    expect(find.text('Manager comp on 3 dishes needs a manager.'), findsOneWidget);
    await pin(tester, '9999');

    expect(t.hub.pins, ['9999']);
    final ops = t.hub.opsFor('o1');
    expect(ops.map((op) => op['kind']), ['discount', 'discount', 'discount']);
    expect(ops.map((op) => dataOf(op)['line_id']), ['L1', 'L3', 'L4']);
    expect(ops.map((op) => dataOf(op)['discount_id']).toSet().length, 3);
    for (final op in ops) {
      final data = dataOf(op);
      expect((data['reason'], data['kind'], data['applied_by'], data['approval']), ('comp', 'comp', 'Amy', 'tok-o1'));
    }
    expect(t.hub.batches.last.length, 3);
    await stop(tester);
  });

  testWidgets('a reason with a range asks how much once, and one that needs no manager asks for no PIN', (
    tester,
  ) async {
    final t = await pumpOrder(tester);
    final (gesture, from) = await pickUp(tester, 'Egg roll', ['Hot tea']);
    await dropOn(tester, gesture, from, 'comp');
    await tester.tap(find.byKey(const ValueKey('lot-comp:loyalty')));
    await tester.pumpAndSettle();
    expect(find.text('Loyalty reward on each of 2 dishes'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('preset:10')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('how-much-apply')));
    await tester.pumpAndSettle();
    expect(t.hub.pins, isEmpty);
    expect(t.hub.opsFor('o1').map((op) => (dataOf(op)['line_id'], dataOf(op)['kind'], dataOf(op)['value'])), [
      ('L1', 'percent', '10'),
      ('L3', 'percent', '10'),
    ]);
    expect(t.hub.opsFor('o1').every((op) => !dataOf(op).containsKey('approval')), isTrue);
    await stop(tester);
  });

  testWidgets('a dish already comped is left as it is, and the reason says on how many it goes', (tester) async {
    final t = await pumpOrder(tester, comped: true);
    var (gesture, from) = await pickUp(tester, 'Egg roll', ['Peking Duck', 'Hot tea']);
    await dropOn(tester, gesture, from, 'comp');
    expect(find.text('Free · 2 of 3'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('lot-comp:comp')));
    await tester.pumpAndSettle();
    expect(find.text('Manager comp on 2 dishes needs a manager.'), findsOneWidget);
    await pin(tester, '9999');
    expect(t.hub.opsFor('o1').map((op) => dataOf(op)['line_id']), ['L1', 'L3']);

    // the comped duck alone: there is nothing to pick, and Cancel walks away
    (gesture, from) = await pickUp(tester, 'Peking Duck');
    await dropOn(tester, gesture, from, 'comp');
    expect(find.byKey(const ValueKey('lot-comp-none')), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(t.hub.opsFor('o1').length, 2);
    await stop(tester);
  });

  testWidgets('the two places fit a phone, and the one under the finger is filled in', (tester) async {
    await pumpOrder(tester, size: const Size(390, 844));
    await tester.tap(find.textContaining('Check')); // a phone shows the check and the menu as two tabs
    await tester.pumpAndSettle();
    final (gesture, from) = await pickUp(tester, 'Egg roll', ['Peking Duck', 'Hot tea', 'Fried rice']);
    expect(tester.takeException(), isNull);
    expect(find.descendant(of: target('void'), matching: find.text('Void 4')), findsOneWidget);
    Color fill(String id) => (tester.widget<AnimatedContainer>(target(id)).decoration! as BoxDecoration).color!;
    final scheme = Theme.of(tester.element(target('comp'))).colorScheme;
    final idle = fill('comp');
    expect(fill('void'), scheme.errorContainer);
    expect(idle, isNot(scheme.tertiary));
    await moveTo(tester, gesture, from, tester.getCenter(target('void')));
    await tester.pump(const Duration(milliseconds: 120));
    expect((fill('comp'), fill('void')), (idle, scheme.error));
    await moveTo(tester, gesture, tester.getCenter(target('void')), tester.getCenter(target('comp')));
    await tester.pump(const Duration(milliseconds: 120));
    expect((fill('comp'), fill('void')), (scheme.tertiary, scheme.errorContainer));
    expect(tester.takeException(), isNull);
    // back up onto the check and let go: a move, not a comp
    await moveTo(tester, gesture, tester.getCenter(target('comp')), from);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    await stop(tester);
  });
}
