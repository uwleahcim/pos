import 'dart:convert';
import 'dart:io';

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
import 'package:pos_app/screens/order_screen.dart';
import 'package:pos_app/session.dart';
import 'package:pos_app/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Discounts, comps and service charges (architecture section 9): the sheet offers the hub's reasons, a
/// manager's PIN buys the approval a comp carries, and every discount or charge is a row a tap takes off.

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
  ],
  'charges': [
    {
      'code': 'auto_gratuity',
      'name': 'Gratuity 18%',
      'kind': 'percent',
      'value': '18',
      'gratuity': true,
      'automatic': true,
      'removal': 'manager',
    },
    {'code': 'catering', 'name': 'Catering service', 'kind': 'percent', 'value': '18', 'automatic': false},
  ],
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
  'charges': [
    {
      'charge_id': 'auto_gratuity',
      'name': 'Gratuity 18%',
      'kind': 'percent',
      'value': '18',
      'amount': '0.45',
      'gratuity': true,
      'automatic': true,
      'taxed': false,
    },
  ],
  'charge_total': '0.45',
  'tax_rate_pct': '7.00',
  'tax': '0.18',
  'total': '3.13',
};

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
            'fields': {'table': 'A1', 'guests': 6},
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

Future<void> openSheet(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(TextButton, 'Discount'));
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey('reason:loyalty')), findsOneWidget);
}

Future<void> enterPin(WidgetTester tester, String pin) async {
  await tester.enterText(find.byKey(const ValueKey('approval-pin')), pin);
  await tester.tap(find.byKey(const ValueKey('approve')));
  await tester.pumpAndSettle();
}

void main() {
  test('a check carries its discounts and charges; the rules say what each reason allows', () {
    final parsed = Check.fromJson(check);
    expect(parsed.line('L2')!.isDiscounted, isTrue);
    expect(parsed.discounts.single.approvedBy, 'Mike');
    expect((parsed.discountTotal, parsed.charges.single.automatic, parsed.chargeTotal), ('30.00', true, '0.45'));

    final parsedRules = PricingRules.fromJson(rules);
    final loyalty = parsedRules.discounts[2];
    expect(loyalty.needsManager, isFalse);
    expect(loyalty.problem('percent', '25'), 'At most 20%');
    expect(loyalty.problem('amount', ''), 'Enter an amount');
    expect(loyalty.problem('percent', '10'), isNull);
    expect(parsedRules.discounts[1].problem('percent', '40'), 'Staff meal is always 50%');
    expect(parsedRules.discounts[0].problem('comp', ''), isNull);
    expect(parsedRules.manualCharges.map((c) => c.code), ['catering']);
    expect(parsedRules.charge('auto_gratuity')!.needsManagerToRemove, isTrue);
  });

  testWidgets('a loyalty reward goes on from the sheet with no PIN, named after who gave it', (tester) async {
    final (sent, pins) = await pump(tester);
    await openSheet(tester);
    expect(find.byKey(const ValueKey('discount-apply')), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('discount-apply'))).onPressed, isNull);

    await tester.tap(find.byKey(const ValueKey('reason:loyalty')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('preset:50')), findsNothing); // over the 20% cap
    await tester.tap(find.byKey(const ValueKey('preset:10')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('discount-apply'))); // the sheet scrolls on a short screen
    await tester.tap(find.byKey(const ValueKey('discount-apply')));
    await tester.pumpAndSettle();

    expect(pins, isEmpty);
    final op = sent.single;
    expect(op['kind'], 'discount');
    final data = op['data'] as Map<String, dynamic>;
    expect(data['discount_id'], isNotEmpty);
    expect((data['reason'], data['kind'], data['value'], data['applied_by']), ('loyalty', 'percent', '10', 'Amy'));
    expect(data.containsKey('approval'), isFalse);
    expect(data.containsKey('line_id'), isFalse); // the whole check
  });

  testWidgets('a comp asks for the manager PIN on the spot and carries the approval', (tester) async {
    final (sent, pins) = await pump(tester);
    await openSheet(tester);
    await tester.tap(find.byKey(const ValueKey('reason:comp')));
    await tester.pumpAndSettle();
    expect(find.text('A manager puts in their PIN next.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('discount-scope')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1× Egg roll').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Manager PIN'));
    await tester.tap(find.widgetWithText(FilledButton, 'Manager PIN'));
    await tester.pumpAndSettle();

    expect(find.text('Manager comp needs a manager.'), findsOneWidget);
    await enterPin(tester, '1111');
    expect(find.text('Only a manager can approve this'), findsOneWidget);
    expect(sent, isEmpty);
    await enterPin(tester, '9999');

    expect(pins, ['1111', '9999']);
    final data = sent.single['data'] as Map<String, dynamic>;
    expect((data['reason'], data['kind'], data['line_id'], data['approval']), ('comp', 'comp', 'L1', 'tok-o1'));
    expect(data.containsKey('value'), isFalse);
  });

  testWidgets('each discount and charge is a row; a tap takes it off, the gratuity with a manager', (tester) async {
    final (sent, pins) = await pump(tester);
    expect(find.text('Manager comp · on Peking Duck · Mike approved'), findsOneWidget);
    expect(find.text('−30.00'), findsOneWidget);
    expect(find.text('Gratuity 18%'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('discount-D1')));
    await tester.pumpAndSettle();
    expect(sent.single['kind'], 'remove_discount');
    expect((sent.single['data'] as Map)['discount_id'], 'D1');

    await tester.tap(find.byKey(const ValueKey('charge-auto_gratuity')));
    await tester.pumpAndSettle();
    expect(find.text('Taking off Gratuity 18% needs a manager.'), findsOneWidget);
    await enterPin(tester, '9999');
    expect(pins, ['9999']);
    expect(sent.last['kind'], 'remove_charge');
    expect(sent.last['data'], {'charge_id': 'auto_gratuity', 'approval': 'tok-o1'});
  });

  testWidgets('a charge staff may put on goes straight from the sheet', (tester) async {
    final (sent, _) = await pump(tester);
    await openSheet(tester);
    await tester.tap(find.byKey(const ValueKey('charge:catering')));
    await tester.pumpAndSettle();
    expect(sent.single['kind'], 'charge');
    final data = sent.single['data'] as Map<String, dynamic>;
    expect((data['code'], data['applied_by']), ('catering', 'Amy'));
    expect(data['charge_id'], isNotEmpty);
  });
}
