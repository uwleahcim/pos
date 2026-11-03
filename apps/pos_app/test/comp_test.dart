import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart' show kLongPressTimeout;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/camera.dart';
import 'package:pos_app/menu.dart';
import 'package:pos_app/outbox.dart';
import 'package:pos_app/photos.dart';
import 'package:pos_app/pricing.dart';
import 'package:pos_app/screens/comp_menu.dart';
import 'package:pos_app/screens/order_screen.dart';
import 'package:pos_app/session.dart';
import 'package:pos_app/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Comps from the check (Mike, 2026-11-03): hold a dish's price and a menu offers the reasons the rules
/// allow on one item, each with what it gives. A fixed one (a comp, a staff meal) goes straight to the
/// manager's PIN and onto the item; one with a range asks how much first. A comped line stays on the check
/// and shows the comp, and the menu takes it off again. A tap on the price still opens the dish.

Map<String, dynamic> fixture(String name) =>
    jsonDecode(File('test/fixtures/$name.json').readAsStringSync()) as Map<String, dynamic>;

http.Response json(Object body, [int status = 200]) => http.Response.bytes(utf8.encode(jsonEncode(body)), status);

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

Map<String, dynamic> line(String item, {bool fired = false}) => {
  'item': item,
  'qty': 1,
  'seat': 1,
  'course': '2',
  'status': 'active',
  'fired': fired,
};

final check = {
  'lines': [
    {'line_id': 'L1', 'name': 'Egg roll', 'qty': 1, 'total': '2.50'},
    {'line_id': 'L2', 'name': 'Peking Duck', 'qty': 1, 'total': '30.00', 'discount': '30.00'},
  ],
  'subtotal': '32.50',
  'discounts': [
    {
      'discount_id': 'D1',
      'reason': 'comp',
      'name': 'Manager comp',
      'kind': 'comp',
      'value': '0',
      'line_id': 'L2',
      'amount': '30.00',
      'applied_by': 'Amy',
      'approved_by': {'staff_id': 's3', 'name': 'Mike'},
    },
  ],
  'discount_total': '30.00',
  'tax_rate_pct': '7.00',
  'tax': '0.18',
  'total': '2.68',
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

/// The order screen on a pretend hub that records what it is sent and approves PIN 9999.
Future<(List<Map<String, dynamic>>, List<String>)> pump(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final settings = Settings(device: 't1', endpoints: ['http://hub:8000'], prefs: prefs);
  final sent = <Map<String, dynamic>>[];
  final pins = <String>[];
  final api = PosApi(
    settings,
    client: MockClient((request) async {
      switch (request.url.path) {
        case '/orders/o1':
          return json({
            'order_id': 'o1',
            'fields': {'table': 'A1', 'guests': 2},
            'lines': {'L1': line('Egg roll'), 'L2': line('Peking Duck', fired: true)},
          });
        case '/orders/o1/check':
          return json(check);
        case '/pricing/rules':
          return json(rules);
        case '/approvals':
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          pins.add(body['pin'] as String);
          expect(body['order_id'], 'o1');
          if (body['pin'] != '9999') {
            return json({
              'detail': {'error': 'not_allowed', 'role': 'server'},
            }, 403);
          }
          return json({'approval': 'tok-o1', 'staff_id': 's3', 'name': 'Mike', 'role': 'manager', 'expires': 1});
        case '/orders/o1/ops':
          final ops = (jsonDecode(request.body) as List).cast<Map<String, dynamic>>();
          sent.addAll(ops);
          return json({'accepted': ops.map((o) => o['op_id']).toList(), 'cursor': 1}, 202);
        case '/menu':
          return json(fixture('menu'));
      }
      return json({'revision': 0});
    }),
  );
  final outbox = Outbox(api, settings, prefs: prefs);
  final photos = PhotoQueue(api, settings, NoCamera(), Session(api), prefs: prefs);
  tester.view
    ..physicalSize = const Size(1100, 800)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: OrderScreen(api: api, outbox: outbox, photos: photos, orderId: 'o1', staffName: 'Amy'),
    ),
  );
  await tester.pumpAndSettle();
  return (sent, pins);
}

Finder price(String lineId) => find.byKey(ValueKey('price-$lineId'));

Finder reason(String code) => find.byKey(ValueKey('comp:$code'));

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
    final (sent, pins) = await pump(tester);
    await holdPrice(tester, 'L1');
    expect(find.text('Egg roll · 2.50'), findsOneWidget);
    expect(reason('comp'), findsOneWidget);
    expect(reason('happy_hour'), findsNothing);
    expect(find.text('free'), findsOneWidget);

    await tester.tap(reason('comp'));
    await tester.pumpAndSettle();
    expect(find.text('Manager comp needs a manager.'), findsOneWidget);
    await enterPin(tester, '1111');
    expect(find.text('Only a manager can approve this'), findsOneWidget);
    expect(sent, isEmpty);
    await enterPin(tester, '9999');

    expect(pins, ['1111', '9999']);
    expect(sent.single['kind'], 'discount');
    final data = dataOf(sent.single);
    expect(data['discount_id'], isNotEmpty);
    expect(
      (data['reason'], data['kind'], data['line_id'], data['approval'], data['applied_by']),
      ('comp', 'comp', 'L1', 'tok-o1', 'Amy'),
    );
    expect(data.containsKey('value'), isFalse);
  });

  testWidgets('a reason with a range asks how much first; a loyalty reward needs no PIN', (tester) async {
    final (sent, pins) = await pump(tester);
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

    expect(pins, isEmpty);
    final data = dataOf(sent.single);
    expect((data['reason'], data['kind'], data['value'], data['line_id']), ('loyalty', 'percent', '10', 'L1'));
    expect(data.containsKey('approval'), isFalse);
  });

  testWidgets('an amount off is typed, within the cap', (tester) async {
    final (sent, _) = await pump(tester);
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
    final data = dataOf(sent.single);
    expect((data['reason'], data['kind'], data['value'], data['line_id']), ('loyalty', 'amount', '1.50', 'L1'));
  });

  testWidgets('service recovery offers free as well as a percentage or an amount', (tester) async {
    final (sent, pins) = await pump(tester);
    await holdPrice(tester, 'L1');
    await tester.tap(reason('service_recovery'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('kind:comp')));
    await tester.pumpAndSettle();
    expect(find.text('The item comes to nothing.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('how-much-apply')));
    await tester.pumpAndSettle();
    await enterPin(tester, '9999');
    expect(pins, ['9999']);
    final data = dataOf(sent.single);
    expect(
      (data['reason'], data['kind'], data['line_id'], data['approval']),
      ('service_recovery', 'comp', 'L1', 'tok-o1'),
    );
    expect(data.containsKey('value'), isFalse);
  });

  testWidgets('a comped line stays on the check and shows the comp; the menu takes it off', (tester) async {
    final (sent, _) = await pump(tester);
    expect(find.descendant(of: price('L2'), matching: find.text('30.00')), findsOneWidget);
    expect(find.descendant(of: price('L2'), matching: find.text('0.00')), findsOneWidget);
    expect(find.text('Comped · Manager comp'), findsOneWidget);
    expect(find.descendant(of: price('L1'), matching: find.text('2.50')), findsOneWidget);

    await holdPrice(tester, 'L2');
    expect(find.byKey(const ValueKey('uncomp:D1')), findsOneWidget);
    expect((tester.widget(reason('loyalty')) as PopupMenuItem).enabled, isFalse);
    expect((tester.widget(reason('comp')) as PopupMenuItem).enabled, isFalse);
    await tester.tap(find.byKey(const ValueKey('uncomp:D1')));
    await tester.pumpAndSettle();
    expect(sent.single['kind'], 'remove_discount');
    expect(dataOf(sent.single), {'discount_id': 'D1'});
  });

  testWidgets('a tap on the price still opens the dish', (tester) async {
    final (sent, _) = await pump(tester);
    await tester.tap(price('L1'));
    await tester.pumpAndSettle();
    expect(reason('comp'), findsNothing);
    expect(find.text('This line has no menu choices to change. Remove it and add it again.'), findsOneWidget);
    expect(sent, isEmpty);
  });

  testWidgets('while a dish is in hand, holding a price opens nothing', (tester) async {
    final (sent, _) = await pump(tester);
    final gesture = await tester.startGesture(tester.getCenter(find.text('Egg roll')));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    expect(find.byKey(const ValueKey('check-stack')), findsOneWidget); // the egg roll is in hand
    await tester.longPress(price('L2'));
    await tester.pumpAndSettle();
    expect(reason('comp'), findsNothing);
    expect(find.byKey(const ValueKey('uncomp:D1')), findsNothing);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(sent.where((op) => op['kind'] == 'discount' || op['kind'] == 'remove_discount'), isEmpty);
  });
}
