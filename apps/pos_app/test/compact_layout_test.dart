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
import 'package:pos_app/screens/reflow.dart';
import 'package:pos_app/screens/signin_screen.dart';
import 'package:pos_app/screens/status_bar.dart';
import 'package:pos_app/screens/theme.dart';
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

    // Category buttons keep the exact same size when collapsed, and the categories section only
    // collapses by as many rows as the opened category's items need.
    Finder categoryTile(String label) =>
        find.ancestor(of: find.text(label), matching: find.byType(PressableScale)).first;
    final initialTileSize = tester.getSize(categoryTile("Chef's Specials"));
    final tile = tester.getCenter(find.text("Chef's Specials"));
    await tester.tap(find.text('Appetizers'));
    await tester.pump(); // the new layout, with the travelling copies
    await tester.pump(); // their first frame
    await tester.pump(Reflow.duration ~/ 2);
    final halfway = [
      for (final e in find.text("Chef's Specials").evaluate()) tester.getCenter(find.byWidget(e.widget)).dy,
    ];
    await tester.pumpAndSettle();
    final after = tester.getCenter(find.text("Chef's Specials"));
    expect(after.dy, lessThan(tile.dy));
    expect(halfway.any((y) => y < tile.dy - 4 && y > after.dy + 4), isTrue);
    expect(tester.getSize(categoryTile("Chef's Specials")), initialTileSize);
    expect(find.text('Egg roll'), findsOneWidget);
    expect(find.text('Pu Pu Platter'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    // No duplicate category header bar in the items section: 'Appetizers' appears only once (on its tile).
    expect(find.text('Appetizers'), findsOneWidget);
    // The items section expands directly below the categories section, not from the bottom of the screen.
    final catRect = tester.getRect(find.byKey(const ValueKey('categories-0')));
    final appsItemsRect = tester.getRect(find.byKey(const ValueKey('items-dinner/apps')));
    expect(appsItemsRect.top, closeTo(catRect.bottom + 1.0, 0.5));
    expect(appsItemsRect.bottom, lessThan(700));

    // When screen height requires collapsing categories (e.g. 560px tall), Appetizers (2 rows of items)
    // collapses categories more than Chef's Specials (1 row of items), and switching between them
    // smoothly expands the categories section and shrinks the items section.
    await tester.binding.setSurfaceSize(const Size(400, 560));
    await tester.pumpAndSettle();
    final twoRowCategoriesHeight = tester.getSize(find.byKey(const ValueKey('categories-0'))).height;

    await tester.tap(find.text("Chef's Specials"));
    await tester.pump();
    await tester.pump(Reflow.duration ~/ 2);
    final midExpandHeight = tester.getSize(find.byKey(const ValueKey('categories-0'))).height;
    await tester.pumpAndSettle();
    expect(tester.getSize(categoryTile("Chef's Specials")), initialTileSize);
    final oneRowCategoriesHeight = tester.getSize(find.byKey(const ValueKey('categories-0'))).height;
    expect(oneRowCategoriesHeight, greaterThan(twoRowCategoriesHeight + 90));
    expect(midExpandHeight, greaterThan(twoRowCategoriesHeight + 20));
    expect(midExpandHeight, lessThan(oneRowCategoriesHeight - 20));
    expect(find.text("General Tso's Chicken"), findsOneWidget);
    expect(find.text('Beef with Broccoli'), findsOneWidget);
    await tester.binding.setSurfaceSize(const Size(400, 800));
    await tester.pumpAndSettle();

    await tester.drag(find.text("General Tso's Chicken"), const Offset(0, 300));
    await tester.pumpAndSettle();
    expect(find.text("General Tso's Chicken"), findsNothing);
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

    // Selecting a bottom-row category whose items expand over its original y-position scrolls the
    // categories grid in lockstep so the selected category is never covered by the items section.
    await tester.binding.setSurfaceSize(const Size(390, 560));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bar'));
    await tester.pump();
    await tester.pump(Reflow.duration ~/ 2);
    final midCatRect = tester.getRect(find.byKey(const ValueKey('categories-0')));
    final midBarRect = tester.getRect(categoryTile('Bar'));
    expect(midBarRect.bottom, lessThanOrEqualTo(midCatRect.bottom + 0.5));
    await tester.pumpAndSettle();
    final finalCatRect = tester.getRect(find.byKey(const ValueKey('categories-0')));
    final finalBarRect = tester.getRect(categoryTile('Bar'));
    expect(finalBarRect.top, greaterThanOrEqualTo(finalCatRect.top - 0.5));
    expect(finalBarRect.bottom, lessThanOrEqualTo(finalCatRect.bottom + 0.5));

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

    final name = tester.getTopLeft(find.text('Egg roll'));
    await tester.tap(egg);
    await tester.pumpAndSettle();
    expect(sent().last, op('set_line', {'line_id': 'L1', 'qty': 2}));
    expect(find.byKey(const ValueKey('sending-L1')), findsOneWidget); // waiting to send, on the far left
    expect(tester.getTopLeft(find.text('Egg roll')), name); // and nothing else moved
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

    // Opening Appetizers on the menu shows the current check quantity (4×) on the Egg roll button,
    // and voiding the line removes the quantity badge from the button.
    await tester.tap(find.byKey(const ValueKey('s:dinner/apps')));
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: find.byKey(const ValueKey('entry-qty:dinner:1:EGGROLL')), matching: find.text('4×')),
      findsOneWidget,
    );

    await tester.longPress(eggBin);
    await tester.pumpAndSettle();
    expect(sent().last, op('void_line', {'line_id': 'L1'}));
    expect(egg, findsNothing);
    expect(find.byKey(const ValueKey('entry-qty:dinner:1:EGGROLL')), findsNothing);

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

  testWidgets('the check scrolls to the dish just added; seats come off from the end once empty', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final settings = Settings(device: 't1', endpoints: ['http://hub:8000'], prefs: prefs);
    // all on seat 1, in the course a new dish goes to
    final lines = {for (var i = 1; i <= 30; i++) 'L$i': line('Dish $i', 1, course: '1')};
    final api = PosApi(
      settings,
      client: MockClient((request) async {
        switch (request.url.path) {
          case '/orders/o1':
            return json({
              'order_id': 'o1',
              'fields': {'table': 'A1', 'guests': 3},
              'lines': lines,
            });
          case '/orders/o1/check':
            return json({'lines': [], 'subtotal': '0.00', 'tax_rate_pct': '7.00', 'tax': '0.00', 'total': '0.00'});
          case '/menu':
            return json(fixture('menu'));
          case '/orders/o1/ops':
            return http.Response('down', 503);
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

    await tester.tap(find.text('Bar'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(ChoiceChip, '1')); // after the 30 on seat 1: the bottom of the check
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tsingtao'));
    await tester.pumpAndSettle();
    final added = find.text('Tsingtao').first; // the check line, left of the menu
    expect(tester.getRect(added).bottom, lessThan(800));
    expect(tester.getRect(added).left, lessThan(380));

    // three seats; the last two are empty and come off, seat 1 has dishes and stays
    expect(find.widgetWithText(ChoiceChip, '3'), findsOneWidget);
    await tester.tap(find.byTooltip('Remove seat 3'));
    await tester.pumpAndSettle();
    expect(sent().last, op('set_field', {'guests': 2}));
    expect(find.widgetWithText(ChoiceChip, '3'), findsNothing);
    await tester.tap(find.byTooltip('Remove seat 2'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Remove seat 1'));
    await tester.pumpAndSettle();
    expect(sent().last, op('set_field', {'guests': 1}));
    expect(find.text('Seat 1 still has 31 dishes. Take them off first.'), findsOneWidget);
    await tester.tap(find.byTooltip('Add a seat'));
    await tester.pumpAndSettle();
    expect(sent().last, op('set_field', {'guests': 2}));

    await tester.pumpWidget(const SizedBox());
    outbox.dispose();
    photos.dispose();
  });

  testWidgets('sign-in PIN pad animates dots, shakes on wrong PIN, and scales on press', (tester) async {
    final settings = Settings(device: 'bar1', endpoints: ['http://hub:8000']);
    final api = PosApi(
      settings,
      client: MockClient((request) async {
        final pin = (jsonDecode(request.body) as Map)['pin'];
        if (pin == '1111') {
          return json({'staff_id': 's1', 'name': 'Amy', 'role': 'server', 'method': 'pin'});
        }
        return json({
          'detail': {'error': 'unknown_credential'},
        }, 401);
      }),
    );
    final session = Session(api);
    await tester.binding.setSurfaceSize(const Size(900, 700));
    await tester.pumpWidget(
      MaterialApp(
        theme: PosTheme.light(),
        darkTheme: PosTheme.dark(),
        home: SignInScreen(session: session, settings: settings, camera: NoCamera()),
      ),
    );
    expect(find.text('Enter your PIN'), findsOneWidget);

    // Press down on a key to verify tactile PressableScale feedback, then tap digits
    final gesture = await tester.startGesture(tester.getCenter(find.text('1')));
    await tester.pump(const Duration(milliseconds: 50));
    expect(
      tester.widget<AnimatedScale>(find.ancestor(of: find.text('1'), matching: find.byType(AnimatedScale))).scale,
      lessThan(1.0),
    );
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.text('●'), findsOneWidget);

    // Clear and enter 4 digits of a wrong PIN -> error message & shake animation
    await tester.tap(find.text('C'));
    await tester.pump();
    for (var i = 0; i < 4; i++) {
      await tester.tap(find.text('2'));
      await tester.pump(const Duration(milliseconds: 30));
    }
    await tester.pumpAndSettle();
    expect(find.text('Wrong PIN'), findsOneWidget);

    // Enter right PIN -> signs in
    for (var i = 0; i < 4; i++) {
      await tester.tap(find.text('1'));
      await tester.pump(const Duration(milliseconds: 30));
    }
    await tester.pumpAndSettle();
    expect(session.signedIn, isTrue);
  });
}
