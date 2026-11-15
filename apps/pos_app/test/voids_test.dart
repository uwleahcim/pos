import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/line_ops.dart';
import 'package:pos_app/screens/adjustments_screen.dart';
import 'package:pos_app/screens/location_settings_screen.dart';
import 'package:pos_app/screens/order_screen.dart';
import 'package:pos_app/session.dart';
import 'package:pos_app/voids.dart';

import 'hub.dart';

/// Voids of dishes the kitchen already has (the Toast comparison, 2026-11-15): the person voiding picks a
/// reason from the location's list and, unless the location lets servers void, a manager types their PIN.
/// The void says who, why and who approved. A dish the kitchen has not seen still just comes off.

const rules = {
  'approval': 'manager',
  'reasons': [
    {'id': 'guest-changed-mind', 'name': 'Guest changed mind'},
    {'id': 'rung-in-wrong', 'name': 'Rung in wrong'},
    {'id': 'kitchen-error', 'name': 'Kitchen error'},
    {'id': 'out-of-stock', 'name': 'Out of stock'},
  ],
};

/// General Tso's chicken as the menu sells it, so a tap on its line reopens its choices.
Map<String, dynamic> gtc({int qty = 1, bool fired = true}) => {
  'item': "General Tso's Chicken (Quart)",
  'qty': qty,
  'seat': 1,
  'course': '2',
  'status': 'active',
  'fired': fired,
  'request': {
    'variant_id': 'GTC:quart',
    'entry_id': 'dinner:87',
    'selections': [
      {'group_id': 'rice', 'option_id': 'rice:brown'},
    ],
  },
  'priced': {'item': 'GTC', 'entry_id': 'dinner:87', 'variant_id': 'GTC:quart'},
};

/// The order screen with Amy, a server, signed in, on a hub that holds [voids] (null: one older than the rules).
Future<Terminal> pumpOrder(
  WidgetTester tester,
  Map<String, dynamic> lines, {
  Map<String, dynamic>? voids = rules,
}) async {
  final t = await terminal(tester);
  t.session.staff = const Staff(staffId: 's1', name: 'Amy', role: 'server', method: 'pin');
  t.hub.voids = voids;
  t.hub.orders.add(table('o1', lines));
  await tester.pumpWidget(
    MaterialApp(
      home: OrderScreen(api: t.api, outbox: t.outbox, photos: t.photos, orderId: 'o1', session: t.session),
    ),
  );
  await tester.pumpAndSettle();
  return t;
}

Map<String, dynamic> dataOf(Map<String, dynamic> op) => (op['data'] as Map).cast<String, dynamic>();

Future<void> pin(WidgetTester tester, String digits) async {
  await tester.enterText(find.byKey(const ValueKey('approval-pin')), digits);
  await tester.tap(find.byKey(const ValueKey('approve')));
  await tester.pumpAndSettle();
}

void main() {
  test('the rules as the hub sends them, and a reason new on the screen goes back without an id', () {
    final read = VoidRules.fromJson(rules);
    expect(read.needsManager, isTrue);
    expect(read.reasons.map((r) => (r.id, r.name)).first, ('guest-changed-mind', 'Guest changed mind'));
    expect(VoidRules.fromJson({...rules, 'approval': 'none'}).needsManager, isFalse);
    const edited = VoidRules(
      needsManager: false,
      reasons: [
        VoidReason(id: 'kitchen-error', name: 'Kitchen mistake'),
        VoidReason(name: 'Spilled'),
      ],
    );
    expect(edited.toJson(), {
      'approval': 'none',
      'reasons': [
        {'id': 'kitchen-error', 'name': 'Kitchen mistake'},
        {'name': 'Spilled'},
      ],
    });
  });

  test('the operator\'s word goes on the void and on nothing else of the change', () {
    const sent = Line(lineId: 'L1', item: 'Duck', qty: 2, status: 'active', fired: true, course: '2');
    final fewer = qtyChange(sent, 1, newId: () => 'L9').voiding({'reason': 'kitchen-error', 'by': 'Amy'});
    expect(fewer.ops.map((o) => o.$1), ['void_line', 'add_line', 'fire']);
    expect(fewer.ops[0].$2, {'line_id': 'L1', 'reason': 'kitchen-error', 'by': 'Amy'});
    expect(fewer.ops[1].$2.containsKey('reason'), isFalse);
    expect((fewer.newLineId, fewer.voidsFired), ('L9', true));
  });

  testWidgets('voiding a sent dish asks why, then for a manager, and the void says who, why and who approved', (
    tester,
  ) async {
    final t = await pumpOrder(tester, {'L1': line('Egg roll', fired: true)});
    await tester.tap(find.byKey(const ValueKey('bin-L1')));
    await tester.pumpAndSettle();
    expect(find.text('Void Egg roll?'), findsOneWidget);
    for (final reason in const ['Guest changed mind', 'Rung in wrong', 'Kitchen error', 'Out of stock']) {
      expect(find.text(reason), findsOneWidget);
    }
    expect(find.widgetWithText(FilledButton, 'Void'), findsNothing); // the reason is the word

    await tester.tap(find.text('Kitchen error'));
    await tester.pumpAndSettle();
    expect(find.text('Voiding Egg roll (Kitchen error) needs a manager.'), findsOneWidget);
    await pin(tester, '1111'); // Amy's own PIN approves nothing
    expect(find.text('Only a manager can approve this'), findsOneWidget);
    expect(t.hub.opsFor('o1'), isEmpty);

    await pin(tester, '9999');
    final op = t.hub.opsFor('o1').single;
    expect(op['kind'], 'void_line');
    expect(dataOf(op), {'line_id': 'L1', 'reason': 'kitchen-error', 'by': 'Amy', 'by_id': 's1', 'approval': 'tok-o1'});
    expect(t.hub.purposes, ['void', 'void']); // asked for a void, not for a discount
    expect(find.byType(AlertDialog), findsNothing);
    await stop(tester);
  });

  testWidgets('keeping the dish, or walking away from the PIN, sends nothing', (tester) async {
    final t = await pumpOrder(tester, {'L1': line('Egg roll', fired: true)});
    await tester.tap(find.byKey(const ValueKey('bin-L1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Keep it'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);

    await tester.tap(find.byKey(const ValueKey('bin-L1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Out of stock'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(t.hub.opsFor('o1'), isEmpty);
    expect(t.outbox.pendingOps, isEmpty);
    expect(find.widgetWithText(ListTile, 'Egg roll'), findsOneWidget);
    await stop(tester);
  });

  testWidgets('with the keyboard, Enter keeps the dish: a void takes a step over to a reason', (tester) async {
    final t = await pumpOrder(tester, {'L1': line('Egg roll', fired: true)});
    await tester.tap(find.byKey(const ValueKey('bin-L1')));
    await tester.pumpAndSettle();
    expect(find.text('Void Egg roll?'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(t.hub.opsFor('o1'), isEmpty);
    await stop(tester);
  });

  testWidgets('where the location lets servers void, the reason alone is enough', (tester) async {
    final t = await pumpOrder(tester, {'L1': line('Egg roll', fired: true)}, voids: {...rules, 'approval': 'none'});
    await tester.tap(find.byKey(const ValueKey('bin-L1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Guest changed mind'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(dataOf(t.hub.opsFor('o1').single), {
      'line_id': 'L1',
      'reason': 'guest-changed-mind',
      'by': 'Amy',
      'by_id': 's1',
    });
    expect(t.hub.pins, isEmpty);
    await stop(tester);
  });

  testWidgets('fewer of a sent dish is a void too: the reason and the approval go on the void', (tester) async {
    final t = await pumpOrder(tester, {
      'L1': {...line('Egg roll', fired: true, course: '1'), 'qty': 3},
    });
    await tester.tap(find.byKey(const ValueKey('bin-L1')));
    await tester.pumpAndSettle();
    expect(find.text('Void Egg roll and send 2 again?'), findsOneWidget);
    await tester.tap(find.text('Rung in wrong'));
    await tester.pumpAndSettle();
    await pin(tester, '9999');
    final ops = t.hub.opsFor('o1');
    expect(ops.map((op) => op['kind']), ['void_line', 'add_line', 'fire']);
    expect(dataOf(ops[0]), {
      'line_id': 'L1',
      'reason': 'rung-in-wrong',
      'by': 'Amy',
      'by_id': 's1',
      'approval': 'tok-o1',
    });
    expect((dataOf(ops[1])['qty'], dataOf(ops[1])['replaces']), (2, 'L1'));
    await stop(tester);
  });

  testWidgets('a dish the kitchen has not seen comes off with nothing asked', (tester) async {
    final t = await pumpOrder(tester, {'L1': line('Egg roll')});
    await tester.tap(find.byKey(const ValueKey('bin-L1')));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(dataOf(t.hub.opsFor('o1').single), {'line_id': 'L1'});
    expect(t.hub.requests.where((r) => r.contains('/settings/voids')), isEmpty);
    await stop(tester);
  });

  testWidgets('changing a sent dish asks nothing, but fewer of it on the way is a void of the difference', (
    tester,
  ) async {
    final t = await pumpOrder(tester, {'L1': gtc(qty: 2)});
    Future<void> openDish() async {
      await tester.tap(find.text("General Tso's Chicken (Quart)").last); // the dish as it stands, under its void
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 200)); // the sheet prices the dish as it opens
      await tester.pumpAndSettle();
    }

    await openDish();
    await tester.tap(find.text('Update'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    var ops = t.hub.opsFor('o1');
    expect(ops.map((op) => op['kind']), ['void_line', 'add_line', 'fire']);
    expect(dataOf(ops[0]), {'line_id': 'L1', 'reason': 'changed'});
    final changed = dataOf(ops[1])['line_id'] as String;

    await openDish();
    await tester.ensureVisible(find.byIcon(Icons.remove)); // the quantity sits at the foot of a tall sheet
    await tester.tap(find.byIcon(Icons.remove));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Update'));
    await tester.pumpAndSettle();
    expect(find.text("Void 1 of the 2 General Tso's Chicken (Quart)?"), findsOneWidget);
    await tester.tap(find.text('Kitchen error'));
    await tester.pumpAndSettle();
    await pin(tester, '9999');
    ops = t.hub.opsFor('o1').sublist(3);
    expect(ops.map((op) => op['kind']), ['void_line', 'add_line', 'fire']);
    expect(dataOf(ops[0]), {
      'line_id': changed,
      'reason': 'kitchen-error',
      'by': 'Amy',
      'by_id': 's1',
      'approval': 'tok-o1',
    });
    expect((dataOf(ops[1])['qty'], dataOf(ops[1])['replaces']), (1, changed));
    await stop(tester);
  });

  testWidgets('on a phone the reasons are buttons two across, and the PIN follows', (tester) async {
    final t = await pumpOrder(tester, {'L1': line('Egg roll', fired: true)});
    tester.view.physicalSize = const Size(390, 844);
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Check')); // a phone shows the check and the menu as two tabs
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('bin-L1')));
    await tester.pumpAndSettle();
    final first = tester.getRect(find.byKey(const ValueKey('void-reason:guest-changed-mind')));
    final second = tester.getRect(find.byKey(const ValueKey('void-reason:rung-in-wrong')));
    final third = tester.getRect(find.byKey(const ValueKey('void-reason:kitchen-error')));
    expect(second.top, first.top); // side by side
    expect(third.left, first.left); // and the third starts the next row
    expect(first.width, greaterThan(100));
    await tester.tap(find.text('Out of stock'));
    await tester.pumpAndSettle();
    await pin(tester, '9999');
    expect(dataOf(t.hub.opsFor('o1').single)['reason'], 'out-of-stock');
    await stop(tester);
  });

  testWidgets('a hub older than the rules is voided on with the operator\'s word alone, as before', (tester) async {
    final t = await pumpOrder(tester, {'L1': line('Egg roll', fired: true)}, voids: null);
    await tester.tap(find.byKey(const ValueKey('bin-L1')));
    await tester.pumpAndSettle();
    expect(find.text('Void Egg roll?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Void'));
    await tester.pumpAndSettle();
    expect(dataOf(t.hub.opsFor('o1').single), {'line_id': 'L1', 'reason': 'void'});
    await stop(tester);
  });

  testWidgets('with no backend answering, a sent dish stays: nobody could check the PIN', (tester) async {
    final t = await pumpOrder(tester, {'L1': line('Egg roll', fired: true)});
    t.hub.down = true;
    await tester.tap(find.byKey(const ValueKey('bin-L1')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.textContaining('needs a hub or the cloud'), findsOneWidget);
    expect(t.outbox.pendingOps, isEmpty);
    await stop(tester);
  });

  testWidgets('a voided dish says why on the check', (tester) async {
    await pumpOrder(tester, {
      'L1': {
        ...line('Egg roll', fired: true),
        'status': 'void',
        'voided': {'reason': 'kitchen-error', 'reason_name': 'Kitchen error', 'by': 'Amy'},
      },
      'L2': {...line('Hot tea', fired: true), 'status': 'void'}, // voided before reasons were asked
    });
    expect(
      find.descendant(
        of: find.widgetWithText(ListTile, 'Egg roll'),
        matching: find.textContaining('void · Kitchen error'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: find.widgetWithText(ListTile, 'Hot tea'), matching: find.textContaining('void')),
      findsOneWidget,
    );
    await stop(tester);
  });

  testWidgets('a manager sets who approves a void and the reasons to pick from', (tester) async {
    final t = await terminal(tester);
    t.hub.voids = rules;
    await tester.pumpWidget(
      MaterialApp(
        home: LocationSettingsScreen(api: t.api, token: 'tok-admin', device: 't1'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('voids')));
    await tester.pumpAndSettle();
    expect(find.text("A sent dish is voided with a reason and a manager's PIN · 4 reasons"), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('voids')));
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(find.byKey(const ValueKey('voids-manager'))).value, isTrue);
    expect(
      tester.widget<TextField>(find.byKey(const ValueKey('void-reason-name:2'))).controller!.text,
      'Kitchen error',
    );

    // let servers void, rename a reason, drop one and add one
    await tester.tap(find.byKey(const ValueKey('voids-manager')));
    await tester.enterText(find.byKey(const ValueKey('void-reason-name:2')), 'Kitchen mistake');
    await tester.tap(find.byKey(const ValueKey('void-reason-remove:3')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('void-reason-add')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('void-reason-add')));
    await tester.pumpAndSettle();

    // a reason with no name is caught here, and what the hub refuses is shown in its words
    await tester.tap(find.byKey(const ValueKey('voids-save')));
    await tester.pumpAndSettle();
    expect(find.text('Every reason needs a name'), findsOneWidget);
    expect(t.hub.voidsAuth, isNull);
    await tester.enterText(find.byKey(const ValueKey('void-reason-name:4')), 'Dropped');
    t.hub.refuseVoids = 'the reason id \'dropped\' is taken';
    await tester.tap(find.byKey(const ValueKey('voids-save')));
    await tester.pumpAndSettle();
    expect(find.text("the reason id 'dropped' is taken"), findsOneWidget);

    t.hub.refuseVoids = null;
    await tester.tap(find.byKey(const ValueKey('voids-save')));
    await tester.pumpAndSettle();
    expect(t.hub.voidsAuth, 'Bearer tok-admin');
    expect(t.hub.voids, {
      'approval': 'none',
      'reasons': [
        {'id': 'guest-changed-mind', 'name': 'Guest changed mind'},
        {'id': 'rung-in-wrong', 'name': 'Rung in wrong'},
        {'id': 'kitchen-error', 'name': 'Kitchen mistake'}, // renamed: it keeps its id
        {'id': 'dropped', 'name': 'Dropped'}, // new: the hub named it
      ],
    });
    expect(find.text('Void rules saved'), findsOneWidget);
    expect(find.text('A sent dish is voided with a reason alone · 4 reasons'), findsOneWidget);
    await stop(tester);
  });

  testWidgets('a hub older than the void rules: the card says so and opens nothing', (tester) async {
    final t = await terminal(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: LocationSettingsScreen(api: t.api, token: 'tok-admin', device: 't1'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('voids')));
    await tester.pumpAndSettle();
    expect(find.text('The hub has not answered about voids (an older hub: update it)'), findsOneWidget);
    expect(tester.widget<ListTile>(find.byKey(const ValueKey('voids'))).onTap, isNull);
    await stop(tester);
  });

  testWidgets('the report adds the voids up by reason, by person and by manager, and lists each one', (tester) async {
    final t = await terminal(tester);
    final noon = DateTime(2026, 11, 15, 12);
    t.hub.report = {
      'voids': [
        {
          'order_id': 'o1',
          'table': '12',
          'item': 'Peking Duck',
          'qty': 1,
          'amount': '48.00',
          'reason': 'kitchen-error',
          'reason_name': 'Kitchen error',
          'by': 'Amy',
          'approved_by': {'staff_id': 's3', 'name': 'Mike'},
          'at_ms': noon.millisecondsSinceEpoch,
        },
        {
          'order_id': 'o2',
          'table': null,
          'order_no': 7,
          'item': 'Hot tea',
          'qty': 2,
          'amount': '5.00',
          'reason': 'void',
          'reason_name': '', // voided before reasons were asked
          'by': '',
          'approved_by': null,
          'at_ms': noon.millisecondsSinceEpoch + 60000,
        },
      ],
      'void_total': '53.00',
      'void_count': 2,
      'voids_by_reason': [
        {'key': 'Kitchen error', 'amount': '48.00', 'count': 1},
        {'key': '', 'amount': '5.00', 'count': 1},
      ],
      'voids_by_staff': [
        {'key': 'Amy', 'amount': '48.00', 'count': 1},
        {'key': '', 'amount': '5.00', 'count': 1},
      ],
      'voids_by_approver': [
        {'key': 'Mike', 'amount': '48.00', 'count': 1},
        {'key': '', 'amount': '5.00', 'count': 1},
      ],
      'discounts': [
        {'reason': 'comp', 'name': 'Manager comp', 'amount': '20.00', 'applied_by': 'Amy', 'table': '12'},
      ],
      'discount_total': '20.00',
      'by_reason': [
        {'key': 'comp', 'amount': '20.00'},
      ],
      'by_staff': [
        {'key': 'Amy', 'amount': '20.00'},
      ],
      'by_approver': [
        {'key': 'Mike', 'amount': '20.00'},
      ],
    };
    await tester.pumpWidget(
      MaterialApp(
        home: AdjustmentsScreen(api: t.api, now: () => noon.add(const Duration(hours: 3))),
      ),
    );
    await tester.pumpAndSettle();
    // today: from this morning's midnight on this device
    final midnight = DateTime(2026, 11, 15).millisecondsSinceEpoch;
    expect(t.hub.requests.last, 'GET /reports/adjustments?since=$midnight');

    expect(find.text('\$53.00'), findsOneWidget);
    expect(find.text('2 dishes'), findsOneWidget);
    expect(find.text('Kitchen error'), findsOneWidget);
    expect(find.text('No reason given'), findsOneWidget);
    expect(find.text('Not recorded'), findsOneWidget);
    expect(find.text('No manager'), findsOneWidget);
    expect(find.text('1 × Peking Duck'), findsOneWidget);
    expect(find.text('12:00 PM · Table 12 · Kitchen error · by Amy · Mike approved'), findsOneWidget);
    expect(find.text('12:01 PM · #7 · No reason given'), findsOneWidget);
    // comps under them, with the reason as the rules name it
    await tester.ensureVisible(find.text('Comps and discounts'));
    await tester.pumpAndSettle();
    expect(find.text('Manager comp'), findsOneWidget);
    expect(find.text('\$20.00'), findsWidgets);

    await tester.ensureVisible(find.byKey(const ValueKey('report-days:7')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('report-days:7')));
    await tester.pumpAndSettle();
    final weekAgo = DateTime(2026, 11, 8).millisecondsSinceEpoch;
    tester.view.physicalSize = const Size(390, 844); // and it reads the same on a phone
    await tester.pumpAndSettle();
    expect(t.hub.requests.last, 'GET /reports/adjustments?since=$weekAgo');
    expect(find.textContaining('Nov 15'), findsNWidgets(2)); // over several days, each void says its day
  });
}
