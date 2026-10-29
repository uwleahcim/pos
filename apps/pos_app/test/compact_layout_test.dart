import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/camera.dart';
import 'package:pos_app/line_ops.dart';
import 'package:pos_app/local_order.dart';
import 'package:pos_app/menu.dart';
import 'package:pos_app/outbox.dart';
import 'package:pos_app/photos.dart';
import 'package:pos_app/screens/menu_panel.dart';
import 'package:pos_app/screens/order_screen.dart';
import 'package:pos_app/screens/status_bar.dart';
import 'package:pos_app/session.dart';
import 'package:pos_app/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> fixture(String name) =>
    jsonDecode(File('test/fixtures/$name.json').readAsStringSync()) as Map<String, dynamic>;

Map<String, dynamic> line(String item, int qty, {bool fired = false, String course = '2'}) => {
  'item': item,
  'qty': qty,
  'seat': 1,
  'course': course,
  'status': 'active',
  'fired': fired,
};

Line lineOf(String id, String item, int qty, {bool fired = false}) => Line.fromJson(id, line(item, qty, fired: fired));

Matcher op(String kind, Map data) =>
    isA<(String, Map)>().having((op) => op.$1, 'kind', kind).having((op) => op.$2, 'data', data);

http.Response json(Object body, [int status = 200]) => http.Response.bytes(utf8.encode(jsonEncode(body)), status);

void main() {
  group('changing how many', () {
    var n = 0;
    String newId() => 'N${++n}';

    test('before the kitchen has it, the quantity just changes; zero takes it off', () {
      final egg = lineOf('L1', 'Egg roll', 2);
      expect(qtyChange(egg, 3, newId: newId).ops, [
        op('set_line', {'line_id': 'L1', 'qty': 3}),
      ]);
      expect(qtyChange(egg, 1, newId: newId).voidsFired, isFalse);
      expect(qtyChange(egg, 0, newId: newId).ops, [
        op('void_line', {'line_id': 'L1'}),
      ]);
      expect(qtyChange(egg, 2, newId: newId).isEmpty, isTrue);
    });

    test('after, one more is a held line of the extra and fewer voids and sends the rest', () {
      final gtc = lineOf('L2', 'GTC', 3, fired: true);
      final more = qtyChange(gtc, 4, newId: newId);
      expect(more.ops.map((op) => op.$1), ['add_line']);
      expect(more.ops.single.$2, {'line_id': more.newLineId, 'item': 'GTC', 'qty': 1, 'seat': 1, 'course': '2'});
      expect(more.voidsFired, isFalse);

      final fewer = qtyChange(gtc, 1, newId: newId);
      expect(fewer.ops.map((op) => op.$1), ['void_line', 'add_line', 'fire']);
      expect(fewer.ops[0].$2, {'line_id': 'L2', 'reason': 'fewer'});
      expect(fewer.ops[1].$2['qty'], 1);
      expect(fewer.ops[2].$2, {'course': '2'});
      expect(fewer.voidsFired, isTrue);

      final none = qtyChange(gtc, 0, newId: newId);
      expect(none.ops, [
        op('void_line', {'line_id': 'L2', 'reason': 'void'}),
      ]);
      expect(none.voidsFired, isTrue);
    });

    test('the screen shows a new quantity at once and prices it from the backend', () {
      final order = Order.fromJson({
        'order_id': 'o1',
        'lines': {'L1': line('Egg roll', 1)},
      });
      final shown = withLocalOps(order, [
        {
          'kind': 'set_line',
          'data': {'line_id': 'L1', 'qty': 3},
        },
      ]);
      final egg = shown.lines.single;
      expect((egg.qty, egg.pending), (3, true));

      final check = Check.fromJson({
        'lines': [
          {'line_id': 'L1', 'name': 'Egg roll', 'qty': 1, 'total': '2.50'},
        ],
        'subtotal': '2.50',
        'tax_rate_pct': '7.00',
        'tax': '0.18',
        'total': '2.68',
      });
      final estimate = estimateCheck(check, shown, const {});
      expect(estimate.estimated, isTrue);
      expect((estimate.line('L1')!.qty, estimate.line('L1')!.total), (3, '7.50'));
      expect(estimate.total, '8.03');
    });
  });

  testWidgets('the connection is one icon; a tap shows the details', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final settings = Settings(device: 't1', endpoints: ['http://hub1:8000', 'http://hub2:8000']);
    final api = PosApi(settings, client: MockClient((_) async => json({})));
    final outbox = Outbox(api, settings, prefs: await SharedPreferences.getInstance());
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(
            actions: [StatusIcon(api: api, outbox: outbox)],
          ),
        ),
      ),
    );
    expect(find.textContaining('Connected'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('status')));
    await tester.pumpAndSettle();
    expect(find.text('Everything is sent'), findsOneWidget);
    expect(find.text('Backends, in failover order'), findsOneWidget);
  });

  testWidgets('the menu opens on its categories and a pull down at the top goes back', (tester) async {
    final menu = fixture('menu');
    // one nested level, as a category with subcategories would come
    final sections = (menu['menus'] as List)[0]['sections'] as List;
    final bar = sections.firstWhere((s) => s['section_id'] == 'dinner/bar') as Map<String, dynamic>;
    final entries = bar['entries'] as List;
    bar['sections'] = [
      {'section_id': 'dinner/bar/beer', 'name': 'Beer', 'entries': entries.sublist(0, 2)},
    ];
    bar['entries'] = entries.sublist(2);
    final api = PosApi(
      Settings(device: 't1', endpoints: ['http://hub:8000']),
      client: MockClient((request) async => request.url.path == '/menu' ? json(menu) : json({'revision': 0})),
    );
    await tester.binding.setSurfaceSize(const Size(400, 800));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MenuPanel(api: api, onChosen: (_) {}),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Appetizers'), findsOneWidget);
    expect(find.text('Egg roll'), findsNothing);

    await tester.tap(find.text('Appetizers'));
    await tester.pumpAndSettle();
    expect(find.text('Egg roll'), findsOneWidget);
    expect(find.byType(ChoiceChip), findsWidgets); // the categories, shrunk to a strip
    expect(find.byType(TextField), findsNothing);

    await tester.drag(find.text('Egg roll'), const Offset(0, 300));
    await tester.pumpAndSettle();
    expect(find.text('Egg roll'), findsNothing);
    expect(find.byType(TextField), findsOneWidget);

    // nested: Bar opens on its subcategory and its own dishes; Beer opens one more level
    await tester.tap(find.text('Bar'));
    await tester.pumpAndSettle();
    expect(find.text('Mai Tai'), findsOneWidget);
    expect(find.text('Tsingtao'), findsNothing);
    await tester.tap(find.text('Beer'));
    await tester.pumpAndSettle();
    expect(find.text('Tsingtao'), findsOneWidget);
    await tester.fling(find.text('Tsingtao'), const Offset(0, 200), 1500);
    await tester.pumpAndSettle();
    expect(find.text('Mai Tai'), findsOneWidget); // one level back, not all the way
    await tester.tap(find.byKey(const ValueKey('menu-back')));
    await tester.pumpAndSettle();
    expect(find.text('Mai Tai'), findsNothing);
    expect(find.text('Appetizers'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('tap the quantity for one more, the bin for one fewer; hold for any number or none', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final settings = Settings(device: 't1', endpoints: ['http://hub:8000'], prefs: prefs);
    final api = PosApi(
      settings,
      client: MockClient((request) async {
        switch (request.url.path) {
          case '/orders/o1':
            return json({
              'order_id': 'o1',
              'fields': {'table': 'A1', 'guests': 2},
              'lines': {'L1': line('Egg roll', 1), 'L2': line('Beef with Broccoli', 2, fired: true)},
            });
          case '/orders/o1/check':
            return json({
              'lines': [
                {'line_id': 'L1', 'name': 'Egg roll', 'qty': 1, 'total': '2.50'},
                {'line_id': 'L2', 'name': 'Beef with Broccoli', 'qty': 2, 'total': '30.00'},
              ],
              'subtotal': '32.50',
              'tax_rate_pct': '7.00',
              'tax': '2.28',
              'total': '34.78',
            });
          case '/menu':
            return json(fixture('menu'));
          case '/orders/o1/ops':
            return http.Response('down', 503); // offline: what the screen sent stays in the outbox to look at
        }
        return json({'revision': 0});
      }),
    );
    final outbox = Outbox(api, settings, prefs: prefs);
    final photos = PhotoQueue(api, settings, NoCamera(), Session(api), prefs: prefs);
    List<(String, Map)> sent() => [for (final op in outbox.pendingOps) (op['kind'] as String, op['data'] as Map)];

    await tester.binding.setSurfaceSize(const Size(1000, 800));
    await tester.pumpWidget(
      MaterialApp(
        home: OrderScreen(api: api, outbox: outbox, photos: photos, orderId: 'o1'),
      ),
    );
    await tester.pumpAndSettle();
    final egg = find.byKey(const ValueKey('qty-L1'));
    final eggBin = find.byKey(const ValueKey('bin-L1'));

    await tester.tap(egg);
    await tester.pumpAndSettle();
    expect(sent().last, op('set_line', {'line_id': 'L1', 'qty': 2}));
    expect(find.descendant(of: egg, matching: find.text('2×')), findsOneWidget);
    expect(find.text('5.00'), findsOneWidget);

    await tester.longPress(egg);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('qty-field')), '5');
    await tester.tap(find.text('Set'));
    await tester.pumpAndSettle();
    expect(sent().last, op('set_line', {'line_id': 'L1', 'qty': 5}));

    await tester.tap(eggBin);
    await tester.pumpAndSettle();
    expect(sent().last, op('set_line', {'line_id': 'L1', 'qty': 4}));

    await tester.longPress(eggBin);
    await tester.pumpAndSettle();
    expect(sent().last, op('void_line', {'line_id': 'L1'}));
    expect(egg, findsNothing);

    // fired: one fewer asks first, then voids the two and sends one
    await tester.tap(find.byKey(const ValueKey('bin-L2')));
    await tester.pumpAndSettle();
    expect(find.text('Void Beef with Broccoli and send 1 again?'), findsOneWidget);
    await tester.tap(find.text('Void'));
    await tester.pumpAndSettle();
    final last = sent().sublist(sent().length - 3);
    expect(last.map((op) => op.$1), ['void_line', 'add_line', 'fire']);
    expect(last[1].$2['qty'], 1);
    expect(find.text('15.00'), findsNWidgets(2)); // the new line, priced like the old one, and the subtotal

    // a phone: the app bar keeps icons only, and seat and course share one line
    await tester.binding.setSurfaceSize(null);
    tester.view
      ..physicalSize = const Size(390, 844)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpAndSettle();
    expect(find.text('Close'), findsNothing);
    expect(find.byTooltip('Close'), findsOneWidget);
    expect(find.text('Seat  '), findsOneWidget);
    expect(tester.getTopLeft(find.text('Course  ')).dy, tester.getTopLeft(find.text('Seat  ')).dy);

    await tester.pumpWidget(const SizedBox());
    outbox.dispose();
    photos.dispose();
  });
}
