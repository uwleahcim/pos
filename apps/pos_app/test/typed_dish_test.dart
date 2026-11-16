import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/local_order.dart';
import 'package:pos_app/menu.dart';
import 'package:pos_app/menu_admin.dart';
import 'package:pos_app/screens/adjustments_screen.dart';
import 'package:pos_app/screens/menu_editor.dart';
import 'package:pos_app/screens/menu_panel.dart';
import 'package:pos_app/screens/order_screen.dart';
import 'package:pos_app/session.dart';
import 'package:pos_app/voids.dart';

import 'hub.dart';
import 'menu_editor_test.dart' show catalogJson;

/// The off-menu dish and the market price (the Toast comparison, 2026-11-16): a dish of the menu can ask
/// for its price when it is rung, and an off-menu dish (Open Food) for what it is as well. The tile says
/// "Ask", a tap opens the dish's sheet with the boxes, and nothing goes on the check before they are
/// filled. What was typed goes to the hub with the line, which prices it (and refuses a price on any
/// other dish); the manager's report lists every one. Which dish asks is menu data: two switches on the
/// dish in the menu editor.

Map<String, dynamic> _variant(String item) => {
  'variant_id': '$item:regular',
  'name': 'Regular',
  'price': '0.00',
  'price_source': 'variant_base',
  'status': 'available',
};

/// A dish as the hub lists it on the menu and describes it: [asks] is `name` for an off-menu dish, `price`
/// for a market price.
Map<String, dynamic> _entry(String item, String name, String asks) => {
  'entry_id': 'dinner:$item',
  'item': item,
  'name': name,
  'variants': [_variant(item)],
  'contains': <String>[],
  'tags': <String>[],
  'has_options': false,
  'needs_choice': true,
  'asks_$asks': true,
};

Map<String, dynamic> _detail(String item, String name, String asks) => {
  'item': item,
  'name': name,
  'kind': 'standard',
  'variants': [_variant(item)],
  'groups': <Map<String, dynamic>>[],
  'tax_class': 'prepared_food',
  'station': 'wok',
  'second_name': null,
  'asks_$asks': true,
};

/// The menu with a category of dishes that ask: Open Food (what it is and its price) and the fish of the
/// day (its price).
Map<String, dynamic> menuWithExtras() {
  final menu = fixture('menu');
  (((menu['menus'] as List).first as Map)['sections'] as List).add({
    'section_id': 'dinner/extras',
    'name': 'Extras',
    'entries': [_entry('FF', 'Open Food', 'name'), _entry('FISH', 'Fish of the day', 'price')],
    'sections': <Map<String, dynamic>>[],
  });
  return menu;
}

Future<Terminal> pumpOrder(WidgetTester tester, {Size? size}) async {
  final t = await terminal(tester);
  t.session.staff = const Staff(staffId: 's1', name: 'Amy', role: 'server', method: 'pin');
  if (size != null) tester.view.physicalSize = size;
  t.hub
    ..menu = menuWithExtras()
    ..items['FF'] = _detail('FF', 'Open Food', 'name')
    ..items['FISH'] = _detail('FISH', 'Fish of the day', 'price')
    ..orders.add(table('o1', {}));
  await tester.pumpWidget(
    MaterialApp(
      home: OrderScreen(api: t.api, outbox: t.outbox, photos: t.photos, orderId: 'o1', session: t.session),
    ),
  );
  await tester.pumpAndSettle();
  return t;
}

const openFood = ValueKey('e:dinner:FF:FF');
const fish = ValueKey('e:dinner:FISH:FISH');
const nameBox = ValueKey('typed-name');
const priceBox = ValueKey('typed-price');

/// Opens the Extras, where the two dishes are.
Future<void> extras(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('s:dinner/extras')));
  await tester.pumpAndSettle();
}

/// Types into one of the sheet's boxes and waits for the hub's price.
Future<void> type(WidgetTester tester, Key box, String text) async {
  await tester.enterText(find.byKey(box), text);
  await tester.pump(const Duration(milliseconds: 200));
  await tester.pumpAndSettle();
}

/// The sheet's button that puts the dish on the check (Add, or Update on a dish reopened).
FilledButton button(WidgetTester tester, String label) =>
    tester.widget<FilledButton>(find.widgetWithText(FilledButton, label));

Map<String, dynamic> dataOf(Map<String, dynamic> op) => (op['data'] as Map).cast<String, dynamic>();

const minute = 60000;
final noon = DateTime(2026, 11, 16, 12);

Map<String, dynamic> typedRow(
  String item, {
  String menuName = 'Open Food',
  bool named = true,
  int qty = 1,
  required String unitPrice,
  String? amount,
  bool voided = false,
  String? table,
  int? orderNo,
  String by = 'Amy',
  required int at,
}) => {
  'order_id': table ?? 'o$orderNo',
  'table': table,
  'order_no': orderNo,
  'customer_name': null,
  'line_id': 'L$at',
  'item': item,
  'menu_name': menuName,
  'named': named,
  'qty': qty,
  'unit_price': unitPrice,
  'amount': amount ?? unitPrice,
  'voided': voided,
  'by': by,
  'by_id': null,
  'at_ms': noon.millisecondsSinceEpoch + at * minute,
};

/// The report of a hub that lists them: a special rung twice, a market price by somebody the app did not
/// name, and an off-menu dish voided since.
Map<String, dynamic> report() => {
  'voids': <Map<String, dynamic>>[],
  'void_total': '0.00',
  'taken_off': <Map<String, dynamic>>[],
  'taken_off_total': '0.00',
  'taken_off_count': 0,
  'taken_off_by_staff': <Map<String, dynamic>>[],
  'taken_off_by_check': <Map<String, dynamic>>[],
  'typed': [
    typedRow('Lobster special', qty: 2, unitPrice: '38.00', amount: '76.00', table: '12', at: 1),
    typedRow(
      'Fish of the day',
      menuName: 'Fish of the day',
      named: false,
      unitPrice: '29.50',
      orderNo: 7,
      by: '',
      at: 5,
    ),
    typedRow('Staff meal', unitPrice: '8.00', amount: '0.00', voided: true, table: '3', at: 9),
  ],
  'typed_total': '105.50',
  'typed_count': 3,
  'typed_by_staff': [
    {'key': 'Amy', 'amount': '76.00', 'count': 2},
    {'key': '', 'amount': '29.50', 'count': 1},
  ],
  'discounts': <Map<String, dynamic>>[],
  'discount_total': '0.00',
};

Future<Terminal> pumpReport(WidgetTester tester, Map<String, dynamic> answer, {Size? size}) async {
  final t = await terminal(tester);
  if (size != null) tester.view.physicalSize = size;
  t.hub.report = answer;
  await tester.pumpWidget(
    MaterialApp(
      home: AdjustmentsScreen(api: t.api, now: () => noon.add(const Duration(hours: 3))),
    ),
  );
  await tester.pumpAndSettle();
  return t;
}

String rowWords(WidgetTester tester, int row) =>
    (tester.widget<ListTile>(find.byKey(ValueKey('typed-row:$row'))).subtitle! as Text).data!;

String rowDish(WidgetTester tester, int row) =>
    (tester.widget<ListTile>(find.byKey(ValueKey('typed-row:$row'))).title! as Text).data!;

void main() {
  test('a typed price is read as dollars and cents, above zero, as the hub takes it', () {
    expect(
      [
        for (final said in ['18.5', '18.50', '18', ' 18 ', r'$18.50', r'$ 7', '.5', '0.05', '9999.99', '7.'])
          typedPrice(said),
      ],
      ['18.50', '18.50', '18.00', '18.00', '18.50', '7.00', '0.50', '0.05', '9999.99', '7.00'],
    );
    // nothing, nothing at all, no free dish (that is a comp), no more than the hub takes, no third decimal
    for (final said in ['', ' ', '.', '0', '0.00', '10000', '18.505', '-5', 'abc', '1,200', '18.5.0', '1e3']) {
      expect(typedPrice(said), isNull, reason: '"$said" is no price');
    }
  });

  test('the menu says which dishes ask, and such a dish has no price to show or to add at one tap', () {
    final open = MenuEntry.fromJson(_entry('FF', 'Open Food', 'name'));
    final market = MenuEntry.fromJson(_entry('FISH', 'Fish of the day', 'price'));
    expect((open.asksPrice, open.asksName), (true, true)); // a dish that asks its name asks its price too
    expect((market.asksPrice, market.asksName), (true, false));
    expect((open.priceLabel, market.priceLabel), ('Ask', 'Ask'));
    expect((open.quickAdd, market.quickAdd), (false, false));

    // the dish as the hub describes it says the same, and so does a line reopened from the check
    final detail = ItemDetail.fromJson(_detail('FF', 'Open Food', 'name'));
    expect((detail.asksPrice, detail.asksName), (true, true));
    final reopened = MenuEntry.fromDetail(detail, entryId: 'dinner:FF');
    expect((reopened.asksPrice, reopened.asksName), (true, true));

    // every other dish, and every dish of a hub older than this: a price of its own, as before
    final eggRoll = MenuEntry.fromJson({
      'entry_id': 'dinner:1',
      'item': 'EGGROLL',
      'name': 'Egg roll',
      'variants': [
        {..._variant('EGGROLL'), 'price': '3.50'},
      ],
    });
    expect((eggRoll.asksPrice, eggRoll.asksName, eggRoll.priceLabel, eggRoll.quickAdd), (false, false, '3.50', true));
    expect(ItemDetail.fromJson(fixture('item_gtc')).asksPrice, isFalse);
  });

  test('what was typed goes with the line, comes back with it, and prices it when no hub answers', () {
    final request = LineRequest(variantId: 'FF:regular', entryId: 'dinner:FF', price: '38.00', name: 'Lobster special');
    expect(request.toJson(), {
      'variant_id': 'FF:regular',
      'entry_id': 'dinner:FF',
      'selections': <Object>[],
      'price': '38.00',
      'name': 'Lobster special',
    });
    final back = LineRequest.fromJson(request.toJson());
    expect((back.price, back.name), ('38.00', 'Lobster special'));
    final copy = request.copy();
    expect((copy.price, copy.name), ('38.00', 'Lobster special'));
    // the hub writes a number where an app sent one
    expect(LineRequest.fromJson({'variant_id': 'FF:regular', 'price': 38.5}).price, '38.5');

    // a dish with a price of its own says nothing about one
    final plain = LineRequest(variantId: 'EGGROLL:regular', entryId: 'dinner:1');
    expect(plain.toJson().keys, isNot(contains('price')));
    expect(plain.toJson().keys, isNot(contains('name')));
    expect((plain.copy().price, plain.copy().name), (null, null));

    // with no hub this screen prices the dish itself: what was typed, not the menu's zero
    final detail = ItemDetail.fromJson(_detail('FF', 'Open Food', 'name'));
    final estimate = localPrice('Lobster special', detail.variants, detail, request);
    expect(
      (estimate.name, estimate.unitPrice, estimate.estimated, estimate.ok),
      ('Lobster special', '38.00', true, true),
    );
    // and a dish with choices adds them to what was typed
    final gtc = ItemDetail.fromJson(fixture('item_gtc'));
    final withShrimp = LineRequest(variantId: 'GTC:pint', entryId: 'dinner:87', price: '20.00');
    fillDefaults(gtc.groups, withShrimp);
    withShrimp.selections['addons'] = ['addons:shrimp'];
    expect(localPrice("General Tso's Chicken", gtc.variants, gtc, withShrimp).unitPrice, '24.00');
  });

  testWidgets('an off-menu dish asks what it is and its price, and goes on the check as what was typed', (
    tester,
  ) async {
    final t = await pumpOrder(tester);
    await extras(tester);
    // the tile has no price to show
    expect(find.descendant(of: find.byKey(openFood), matching: find.text('Ask')), findsOneWidget);

    await tester.tap(find.byKey(openFood));
    await tester.pumpAndSettle();
    expect(t.hub.opsFor('o1'), isEmpty, reason: 'nothing goes on the check before it has a name and a price');
    expect(find.byKey(nameBox), findsOneWidget);
    expect(find.byKey(priceBox), findsOneWidget);
    expect(button(tester, 'Add').onPressed, isNull);

    // a name alone is not enough, and nothing is asked of the hub yet
    await type(tester, nameBox, '  Lobster   special ');
    expect(button(tester, 'Add').onPressed, isNull);
    expect(t.hub.priced, isEmpty);

    // no free dish: the box says how a price looks, and the button stays off
    await type(tester, priceBox, '0');
    expect(find.text('Like 18.50'), findsOneWidget);
    expect(button(tester, 'Add').onPressed, isNull);
    expect(t.hub.priced, isEmpty);

    await type(tester, priceBox, '38');
    expect(find.text('Like 18.50'), findsNothing);
    expect((t.hub.priced.last['price'], t.hub.priced.last['name']), ('38.00', 'Lobster special'));
    expect(button(tester, 'Add').onPressed, isNotNull);

    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    final added = t.hub.opsFor('o1').single;
    expect(added['kind'], 'add_line');
    expect(dataOf(added)['item'], 'Lobster special');
    expect(dataOf(added)['request'], {
      'variant_id': 'FF:regular',
      'entry_id': 'dinner:FF',
      'selections': <Object>[],
      'price': '38.00',
      'name': 'Lobster special',
    });
    expect((dataOf(added)['by'], dataOf(added)['by_id']), ('Amy', 's1')); // the report says who rang it in
    expect(find.text('Lobster special'), findsOneWidget); // on the check, under what was typed
    await stop(tester);
  });

  testWidgets('a second off-menu dish is its own line, and a line reopened comes with what was typed', (tester) async {
    final t = await pumpOrder(tester);
    await extras(tester);
    Future<void> ring(String name, String price) async {
      await tester.tap(find.byKey(openFood));
      await tester.pumpAndSettle();
      await type(tester, nameBox, name);
      await type(tester, priceBox, price);
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();
    }

    await ring('Lobster special', '38');
    await ring('Side of kimchi', '4.5');
    expect(
      [for (final op in t.hub.opsFor('o1')) (op['kind'], dataOf(op)['item'], (dataOf(op)['request'] as Map)['price'])],
      [('add_line', 'Lobster special', '38.00'), ('add_line', 'Side of kimchi', '4.50')],
    );

    // a tap on the line opens the dish with its name and price in the boxes; a new price takes its place
    await tester.tap(find.text('Lobster special'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byKey(nameBox)).controller!.text, 'Lobster special');
    expect(tester.widget<TextField>(find.byKey(priceBox)).controller!.text, '38.00');
    expect(button(tester, 'Update').onPressed, isNotNull);
    await type(tester, priceBox, '42');
    await tester.tap(find.text('Update'));
    await tester.pumpAndSettle();
    final changed = t.hub.opsFor('o1').sublist(2);
    expect(changed.map((op) => op['kind']), ['void_line', 'add_line']);
    expect(dataOf(changed[1])['item'], 'Lobster special');
    expect((dataOf(changed[1])['request'] as Map)['price'], '42.00');
    expect((dataOf(changed[1])['request'] as Map)['name'], 'Lobster special');
    await stop(tester);
  });

  testWidgets('a market price asks its price alone: the dish keeps its name, and Enter in the box adds it', (
    tester,
  ) async {
    final t = await pumpOrder(tester);
    await extras(tester);
    expect(find.descendant(of: find.byKey(fish), matching: find.text('Ask')), findsOneWidget);
    await tester.tap(find.byKey(fish));
    await tester.pumpAndSettle();
    expect(find.byKey(nameBox), findsNothing);
    expect(find.byKey(priceBox), findsOneWidget);
    expect(button(tester, 'Add').onPressed, isNull);

    // Enter on an empty box adds nothing
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(t.hub.opsFor('o1'), isEmpty);

    await type(tester, priceBox, '29.5');
    expect(t.hub.priced.last['price'], '29.50');
    expect(t.hub.priced.last.containsKey('name'), isFalse);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    final added = dataOf(t.hub.opsFor('o1').single);
    expect(added['item'], 'Fish of the day');
    expect(added['request'], {
      'variant_id': 'FISH:regular',
      'entry_id': 'dinner:FISH',
      'selections': <Object>[],
      'price': '29.50',
    });
    await stop(tester);
  });

  testWidgets('with no hub answering the dish still goes on, at the price typed and marked estimated', (tester) async {
    final t = await pumpOrder(tester);
    await extras(tester);
    await tester.tap(find.byKey(openFood));
    await tester.pumpAndSettle();
    t.hub.down = true; // the cable is pulled with the dish open
    await type(tester, nameBox, 'Lobster special');
    await type(tester, priceBox, '38');
    await tester.pump(const Duration(seconds: 5)); // the call gives up
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('price-estimated')), findsOneWidget);
    expect(button(tester, 'Add').onPressed, isNotNull);
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    final waiting = t.outbox.pendingOps.single;
    expect(waiting['kind'], 'add_line');
    expect(dataOf(waiting)['item'], 'Lobster special');
    expect(find.text('Lobster special'), findsOneWidget); // on the check meanwhile

    // the hub is back: the line goes to it with what was typed, for the hub to price for real
    t.hub.down = false;
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    final added = dataOf(t.hub.opsFor('o1').single);
    expect(
      (added['item'], (added['request'] as Map)['price'], (added['request'] as Map)['name']),
      ('Lobster special', '38.00', 'Lobster special'),
    );
    await stop(tester);
  });

  testWidgets('the sheet fits a small phone with the keyboard up', (tester) async {
    final t = await terminal(tester);
    tester.view.physicalSize = const Size(320, 568);
    t.hub.items['FF'] = _detail('FF', 'Open Food', 'name');
    ChosenLine? chosen;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => chosen = await showDialog<ChosenLine>(
              context: context,
              builder: (_) => ItemSheet(api: t.api, entry: MenuEntry.fromJson(_entry('FF', 'Open Food', 'name'))),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding(bottom: 260);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    await type(tester, nameBox, 'A dish with a name longer than the box takes');
    await type(tester, priceBox, '1234.56');
    expect(tester.takeException(), isNull);
    // the name stops at what the hub takes, about a line of a kitchen ticket
    expect(tester.widget<TextField>(find.byKey(nameBox)).controller!.text, hasLength(typedNameMax));
    await tester.ensureVisible(find.text('Add'));
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    expect(
      (chosen!.name, chosen!.unitPrice, chosen!.request.price),
      ('A dish with a name longer than the box t', '1234.56', '1234.56'),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('the menu editor says whether a dish asks its price, and its name too', (tester) async {
    final json = catalogJson();
    (((json['catalog'] as Map)['item'] as List).first as Map)['attrs'] = {'legacy_pos': true};
    final catalog = MenuCatalog.fromJson(json);
    await tester.binding.setSurfaceSize(const Size(1400, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: StatefulBuilder(
              builder: (context, setState) =>
                  ItemEditor(catalog: catalog, itemKey: 'GTC', onChanged: () => setState(() {}), onDeleted: () {}),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    const price = ValueKey('GTC/asks-price');
    const name = ValueKey('GTC/asks-name');
    bool on(Key key) => tester.widget<SwitchListTile>(find.byKey(key)).value;
    Map<String, dynamic> attrs() => (catalog.get('item', 'GTC')!['attrs'] as Map).cast<String, dynamic>();
    Future<void> flip(Key key) async {
      await tester.tap(find.byKey(key));
      await tester.pumpAndSettle();
    }

    expect((on(price), on(name)), (false, false));
    expect(catalog.dirty, isFalse);

    // a market price: the rest of what the dish carries stays
    await flip(price);
    expect((on(price), on(name)), (true, false));
    expect(attrs(), {'legacy_pos': true, 'asks_price': true});
    final change = catalog.changes().single;
    expect((change['kind'], change['op']), ('item', 'put'));
    expect(((change['data'] as Map)['attrs'] as Map)['asks_price'], true);

    // an off-menu dish asks both
    await flip(name);
    expect((on(price), on(name)), (true, true));
    expect(attrs(), {'legacy_pos': true, 'asks_price': true, 'asks_name': true});

    // a dish that does not ask its price cannot ask its name; it is as it was, with nothing to save
    await flip(price);
    expect((on(price), on(name)), (false, false));
    expect(attrs(), {'legacy_pos': true});
    expect(catalog.dirty, isFalse);

    // the name's switch alone turns both on
    await flip(name);
    expect((on(price), on(name)), (true, true));
    await flip(name);
    expect((on(price), on(name)), (true, false));
  });

  test('the report reads the dishes rung at a typed price', () {
    final read = AdjustmentsReport.fromJson(report());
    expect((read.hasTyped, read.typedTotal, read.typed.length, read.typedDishes), (true, '105.50', 3, 3));
    expect(read.typed.map((row) => (row.item, row.menuName, row.named, row.qty, row.unitPrice, row.amount)), [
      ('Lobster special', 'Open Food', true, 2, '38.00', '76.00'),
      ('Fish of the day', 'Fish of the day', false, 1, '29.50', '29.50'),
      ('Staff meal', 'Open Food', true, 1, '8.00', '0.00'),
    ]);
    expect(read.typed.map((row) => (row.where, row.by, row.voided)), [
      ('Table 12', 'Amy', false),
      ('#7', '', false),
      ('Table 3', 'Amy', true),
    ]);
    expect(read.typedByStaff.map((total) => (total.key, total.amount, total.count)), [
      ('Amy', '76.00', 2),
      ('', '29.50', 1),
    ]);

    // a hub older than the list says nothing of it
    final older = AdjustmentsReport.fromJson({'voids': <Map<String, dynamic>>[]});
    expect((older.hasTyped, older.typed.length, older.typedTotal, older.typedDishes), (false, 0, '0.00', 0));
  });

  testWidgets('the report lists every dish rung at a typed price, by who rang it in and one by one', (tester) async {
    await pumpReport(tester, report());
    final section = find.text('Typed prices');
    await tester.ensureVisible(section);
    await tester.pumpAndSettle();
    expect(find.text('\$105.50'), findsOneWidget);
    expect(find.text('3 dishes'), findsOneWidget);
    expect(find.text('By who rang it in'), findsOneWidget);
    expect(find.text('Not recorded'), findsOneWidget);

    await tester.ensureVisible(find.byKey(const ValueKey('typed-row:2')));
    await tester.pumpAndSettle();
    expect(
      [for (var i = 0; i < 3; i++) rowDish(tester, i)],
      ['2 × Lobster special', '1 × Fish of the day', '1 × Staff meal'],
    );
    // an off-menu dish says what it was rung as; two of a dish say what one cost; a void says so
    expect(rowWords(tester, 0), '12:01 PM · Table 12 · rung as Open Food · \$38.00 each · by Amy');
    expect(rowWords(tester, 1), '12:05 PM · #7');
    expect(rowWords(tester, 2), '12:09 PM · Table 3 · rung as Open Food · by Amy · voided since');
    await stop(tester);
  });

  testWidgets('with none rung the report says so, on a phone too; an older hub has no such section', (tester) async {
    await pumpReport(tester, {
      ...report(),
      'typed': <Map<String, dynamic>>[],
      'typed_total': '0.00',
      'typed_count': 0,
      'typed_by_staff': <Map<String, dynamic>>[],
    }, size: const Size(360, 720));
    await tester.ensureVisible(find.text('Typed prices'));
    await tester.pumpAndSettle();
    expect(find.text('No off-menu dish and no market price was rung.'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await stop(tester);

    final older = report()..removeWhere((key, _) => key.startsWith('typed'));
    await pumpReport(tester, older);
    expect(find.text('Typed prices'), findsNothing);
    expect(find.text('Comps and discounts'), findsOneWidget);
    await stop(tester);
  });
}
