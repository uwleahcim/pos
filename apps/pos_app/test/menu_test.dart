import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/menu.dart';
import 'package:pos_app/screens/menu_panel.dart';
import 'package:pos_app/screens/theme.dart';
import 'package:pos_app/settings.dart';

/// Fixtures are the backend's own answers (sample menu), saved from its test client.
Map<String, dynamic> fixture(String name) =>
    jsonDecode(File('test/fixtures/$name.json').readAsStringSync()) as Map<String, dynamic>;

void main() {
  _platterTests();
  test('the menu parses with sections, two languages and one-tap entries', () {
    final menus = (fixture('menu')['menus'] as List).map((m) => Menu.fromJson(m as Map<String, dynamic>)).toList();
    final entries = {
      for (final s in menus.single.sections)
        for (final e in s.allEntries) e.item: e,
    };
    expect(entries['TSINGTAO']!.quickAdd, isTrue);
    expect(entries['TSINGTAO']!.secondName, '青岛啤酒');
    expect(entries['GTC']!.quickAdd, isFalse);
    expect(entries['GTC']!.priceLabel, endsWith('+'));
    expect(entries['DRAFT']!.variants.length, 2);
    // the backend says which tiles will ask something; a dish whose rice simply defaults does not
    expect(entries['GTC']!.needsChoice, isTrue);
    expect(entries['BB']!.needsChoice, isFalse);
    expect(entries['BB']!.hasOptions, isTrue);
    expect(MenuEntry.fromJson({'entry_id': 'x', 'item': 'X', 'has_options': true}).needsChoice, isTrue); // an older hub
    final sections = {for (final s in menus.single.sections) s.sectionId: s};
    expect(sections['dinner/sushi']!.color, '#2F5E48');
    expect(sections['dinner/apps']!.color, isNull);
  });

  test('item groups and the request sent back', () {
    final item = ItemDetail.fromJson(fixture('item_gtc'));
    final rice = item.groups.firstWhere((g) => g.groupId == 'rice');
    expect(rice.required && rice.single, isTrue);
    final request = LineRequest(
      variantId: 'GTC:quart',
      entryId: 'dinner:87',
      selections: {
        'rice': ['rice:brown'],
        'addons': ['addons:shrimp', 'addons:nomsg'],
      },
    );
    expect(request.toJson(), {
      'variant_id': 'GTC:quart',
      'entry_id': 'dinner:87',
      'selections': [
        {'group_id': 'rice', 'option_id': 'rice:brown'},
        {'group_id': 'addons', 'option_id': 'addons:shrimp'},
        {'group_id': 'addons', 'option_id': 'addons:nomsg'},
      ],
    });
    // a word on a choice travels with it, both ways
    request.prefixes['addons:shrimp'] = 'no';
    expect(
      request.toJson()['selections'],
      contains(equals({'group_id': 'addons', 'option_id': 'addons:shrimp', 'prefix': 'no'})),
    );
    final back = LineRequest.fromJson(request.toJson());
    expect(back.prefixes, {'addons:shrimp': 'no'});
    expect(back.copy().prefixes, {'addons:shrimp': 'no'});
  });

  test('the check carries the backend totals and Massachusetts tax lines', () {
    final check = Check.fromJson(fixture('check'));
    expect(check.lines.map((l) => l.lineId), ['L2', 'L1']);
    expect(check.line('L1')!.total, '25.95');
    expect(check.taxLines.map((t) => t.ratePct), ['6.25', '0.75']);
    expect(check.taxRatePct, '7.00');
    expect(check.total, '41.67');
  });

  testWidgets(
    'tap auto-adds items with defaults, expands inline section for required selections, and long-press opens modifier popup',
    (tester) async {
      final settings = Settings(device: 't1', endpoints: ['http://hub:8000']);
      final priced = <Map<String, dynamic>>[];
      final gtc = fixture('item_gtc');
      final bb = {
        ...gtc,
        'item': 'BB',
        'name': 'Beef with Broccoli',
        'variants': [
          {'variant_id': 'BB:regular', 'name': 'Regular', 'price': '14.95', 'status': 'available'},
        ],
      };
      final c5 = {
        'item': 'C5',
        'name': 'Combination Plate',
        'variants': [
          {'variant_id': 'C5:regular', 'name': 'Regular', 'price': '14.50', 'status': 'available'},
        ],
        'groups': [
          {
            'group_id': 'side',
            'name': 'Choice of side',
            'min_select': 1,
            'max_select': 1,
            'options': [
              {'option_id': 'side:pfr', 'name': 'Pork fried rice', 'price': '0.00', 'status': 'available'},
              {'option_id': 'side:lomein', 'name': 'Lo mein', 'price': '1.50', 'status': 'available'},
            ],
          },
        ],
      };
      final whisky = {
        'item': 'WHISKY',
        'name': 'Japanese whisky',
        'variants': [
          {'variant_id': 'WHISKY:2oz', 'name': '2 oz', 'price': '14.00', 'status': 'available'},
        ],
        'groups': [
          {
            'group_id': 'pour',
            'name': 'Serve',
            'min_select': 1,
            'max_select': 1,
            'options': [
              {'option_id': 'pour:neat', 'name': 'Neat', 'price': '0.00', 'status': 'available'},
              {'option_id': 'pour:rocks', 'name': 'On the rocks', 'price': '0.00', 'status': 'available'},
            ],
          },
        ],
      };
      final api = PosApi(
        settings,
        client: MockClient((request) async {
          switch (request.url.path) {
            case '/menu':
              return http.Response.bytes(utf8.encode(jsonEncode(fixture('menu'))), 200);
            case '/menu/items/GTC':
              return http.Response.bytes(utf8.encode(jsonEncode(gtc)), 200);
            case '/menu/items/BB':
              return http.Response.bytes(utf8.encode(jsonEncode(bb)), 200);
            case '/menu/items/C5':
              return http.Response.bytes(utf8.encode(jsonEncode(c5)), 200);
            case '/menu/items/WHISKY':
              return http.Response.bytes(utf8.encode(jsonEncode(whisky)), 200);
            case '/menu/price':
              priced.add(jsonDecode(request.body) as Map<String, dynamic>);
              return http.Response(jsonEncode({'name': "General Tso's Chicken (Pint)", 'unit_price': '15.95'}), 200);
          }
          return http.Response('{}', 404);
        }),
      );
      final chosen = <ChosenLine>[];
      await tester.binding.setSurfaceSize(const Size(1000, 800));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MenuPanel(api: api, onChosen: chosen.add),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 1. Simple item with no options: one tap adds immediately and shows quantity on the button
      await tester.enterText(find.byType(TextField), 'B1');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('entry-qty:dinner:B1:TSINGTAO')), findsNothing);
      await tester.tap(find.text('Tsingtao'));
      await tester.pump();
      expect(chosen.single.request.variantId, 'TSINGTAO:bottle');
      expect(
        find.descendant(of: find.byKey(const ValueKey('entry-qty:dinner:B1:TSINGTAO')), matching: find.text('1×')),
        findsOneWidget,
      );

      // 2. Item with modifier groups that all have defaults: one tap automatically adds with defaults
      await tester.enterText(find.byType(TextField), '88');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Beef with Broccoli'));
      await tester.pumpAndSettle();
      expect(find.byType(ItemSheet), findsNothing);
      expect(find.byKey(const ValueKey('required-selections')), findsNothing);
      expect(chosen.length, 2);
      expect(chosen.last.request.variantId, 'BB:regular');
      expect(chosen.last.request.selections['rice'], ['rice:white']);
      expect(chosen.last.request.selections['spice'], ['spice:medium']);
      expect(
        find.descendant(of: find.byKey(const ValueKey('entry-qty:dinner:88:BB')), matching: find.text('1×')),
        findsOneWidget,
      );

      // 3. Item needing a required size selection: tap expands inline section, selecting size collapses & adds
      await tester.enterText(find.byType(TextField), '87');
      await tester.pumpAndSettle();
      await tester.tap(find.text("General Tso's Chicken"));
      await tester.pumpAndSettle();
      expect(find.byType(ItemSheet), findsNothing);
      expect(find.byKey(const ValueKey('required-selections')), findsOneWidget);
      expect(find.text('Size'), findsWidgets);
      final itemTileSize = tester.getSize(find.byKey(const ValueKey('e:dinner:87:GTC')));
      final modTileSize = tester.getSize(find.byKey(const ValueKey('req-variant:GTC:pint')));
      expect(modTileSize, itemTileSize);
      await tester.tap(find.text('Pint'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('required-selections')), findsNothing);
      expect(chosen.length, 3);
      expect(chosen.last.request.variantId, 'GTC:pint');
      expect(chosen.last.request.selections['rice'], ['rice:white']);
      expect(
        find.descendant(of: find.byKey(const ValueKey('entry-qty:dinner:87:GTC')), matching: find.text('1×')),
        findsOneWidget,
      );

      // 4. Item with a required modifier group without defaults: tap expands inline section, picking option collapses & adds
      await tester.enterText(find.byType(TextField), 'C5');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Combination Plate'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('required-selections')), findsOneWidget);
      expect(find.text('Choice of side'), findsWidgets);
      await tester.tap(find.text('Lo mein'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('required-selections')), findsNothing);
      expect(chosen.length, 4);
      expect(chosen.last.request.variantId, 'C5:regular');
      expect(chosen.last.request.selections['side'], ['side:lomein']);
      expect(chosen.last.unitPrice, '16.00');

      // 5. Long-pressing an item opens the ItemSheet popup to change modifiers
      await tester.enterText(find.byType(TextField), '87');
      await tester.pumpAndSettle();
      await tester.longPress(find.text("General Tso's Chicken"));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
      expect(find.byType(ItemSheet), findsOneWidget);
      expect(find.text('Choice of rice (required)'), findsOneWidget);
      expect(priced.last['selections'], contains(equals({'group_id': 'rice', 'option_id': 'rice:white'})));
      expect(find.text('\$15.95'), findsOneWidget);
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();
      expect(chosen.length, 5);
      expect(chosen.last.request.variantId, 'GTC:pint');
      expect(
        find.descendant(of: find.byKey(const ValueKey('entry-qty:dinner:87:GTC')), matching: find.text('2×')),
        findsOneWidget,
      );

      // 6. Selecting a bottom-row item in an open category keeps the selected item visible as the
      // modifier selection section expands below it.
      await tester.tap(find.byTooltip('Clear'));
      await tester.binding.setSurfaceSize(null);
      tester.view
        ..physicalSize = const Size(390, 560)
        ..devicePixelRatio = 1; // a phone
      addTearDown(tester.view.reset);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Bar'));
      await tester.pumpAndSettle();
      final whiskyTile = find.byKey(const ValueKey('e:dinner:B5:WHISKY'));
      await tester.tap(whiskyTile);
      await tester.pump(); // complete async api.item('WHISKY')
      await tester.pump(MenuPanel.transition ~/ 2);
      final midItemsRect = tester.getRect(find.byKey(const ValueKey('items-dinner/bar')));
      final midWhiskyRect = tester.getRect(whiskyTile);
      expect(midWhiskyRect.bottom, lessThanOrEqualTo(midItemsRect.bottom + 0.5));
      await tester.pumpAndSettle();
      final finalItemsRect = tester.getRect(find.byKey(const ValueKey('items-dinner/bar')));
      final finalWhiskyRect = tester.getRect(whiskyTile);
      expect(finalWhiskyRect.top, greaterThanOrEqualTo(finalItemsRect.top - 0.5));
      expect(finalWhiskyRect.bottom, lessThanOrEqualTo(finalItemsRect.bottom + 0.5));
    },
  );

  testWidgets('a tablet keeps the category tiles when one opens, like a phone, and the dishes open below', (
    tester,
  ) async {
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
      client: MockClient(
        (request) async => request.url.path == '/menu'
            ? http.Response.bytes(utf8.encode(jsonEncode(menu)), 200)
            : http.Response(jsonEncode({'revision': 0}), 200),
      ),
    );
    tester.view
      ..physicalSize = const Size(1000, 800)
      ..devicePixelRatio = 1; // a tablet or Mac: the same layout as a phone, only wider
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MenuPanel(api: api, onChosen: (_) {}),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // every category tile has its own colour: the menu's own for the sushi bar, the palette for the rest
    final scheme = Theme.of(tester.element(find.text('Sushi bar'))).colorScheme;
    Color tileColor(String name) {
      final box = find.ancestor(of: find.text(name), matching: find.byType(AnimatedContainer)).first;
      return (tester.widget<AnimatedContainer>(box).decoration! as BoxDecoration).color!;
    }

    expect(tileColor('Sushi bar'), categoryTint(scheme, hex: '#2F5E48', index: 3).fill);
    expect(tileColor('Appetizers'), categoryTint(scheme, index: 0).fill);
    expect(tileColor('Appetizers'), isNot(tileColor("Chef's Specials")));

    // Opening a category: the tiles keep their size and only move up into the room the search bar leaves, and
    // the dishes open right below them. Never a strip of chips, however wide the screen (Mike, 2026-11-01).
    Finder tile(String label) => find.ancestor(of: find.text(label), matching: find.byType(PressableScale)).first;
    final before = tester.getRect(tile("Chef's Specials"));
    await tester.tap(find.text('Appetizers'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('category-strip')), findsNothing);
    expect(find.byKey(const ValueKey('categories-0')), findsOneWidget);
    final after = tester.getRect(tile("Chef's Specials"));
    expect(after.size, before.size);
    expect(after.top, lessThan(before.top));
    expect(find.text('Appetizers'), findsOneWidget); // its tile: no chip, no header
    expect(find.byType(TextField), findsNothing);
    expect(find.text('Egg roll'), findsOneWidget);
    final categories = tester.getRect(find.byKey(const ValueKey('categories-0')));
    final items = tester.getRect(find.byKey(const ValueKey('items-dinner/apps')));
    expect(items.top, closeTo(categories.bottom + 1.0, 0.5));

    // the customize mark only where a tap will ask: two sizes, not a rice group with a default
    await tester.tap(find.text("Chef's Specials"));
    await tester.pumpAndSettle();
    expect(find.text('Egg roll'), findsNothing);
    final gtc = find.byKey(const ValueKey('e:dinner:87:GTC'));
    final bb = find.byKey(const ValueKey('e:dinner:88:BB'));
    expect(find.descendant(of: gtc, matching: find.byIcon(Icons.tune)), findsOneWidget);
    expect(find.descendant(of: bb, matching: find.byIcon(Icons.tune)), findsNothing);

    // nested: Bar opens on its subcategory tile and its own dishes; Beer opens one level further under its own
    // tile, with no crumb; the mark on the open tile goes one level back
    await tester.tap(find.text('Bar'));
    await tester.pumpAndSettle();
    expect(find.text('Mai Tai'), findsOneWidget);
    expect(find.text('Tsingtao'), findsNothing);
    await tester.tap(find.text('Beer'));
    await tester.pumpAndSettle();
    expect(find.text('Tsingtao'), findsOneWidget);
    expect(find.text('Mai Tai'), findsNothing);
    expect(find.text('Bar ›'), findsNothing);
    expect(find.byKey(const ValueKey('categories-1')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('menu-back')));
    await tester.pumpAndSettle();
    expect(find.text('Mai Tai'), findsOneWidget);
    expect(find.text('Tsingtao'), findsNothing);

    // pulling down at the top of the dishes closes the category: the search is back
    await tester.drag(find.text('Mai Tai'), const Offset(0, 300));
    await tester.pumpAndSettle();
    expect(find.text('Mai Tai'), findsNothing);
    expect(find.byType(TextField), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the item sheet marks a choice No, Extra, On the side or Light with one tap each', (tester) async {
    final priced = <Map<String, dynamic>>[];
    final api = PosApi(
      Settings(device: 't1', endpoints: ['http://hub:8000']),
      client: MockClient((request) async {
        switch (request.url.path) {
          case '/menu/items/GTC':
            return http.Response.bytes(utf8.encode(jsonEncode(fixture('item_gtc'))), 200);
          case '/menu/price':
            priced.add(jsonDecode(request.body) as Map<String, dynamic>);
            return http.Response(jsonEncode({'name': "General Tso's Chicken (Pint)", 'unit_price': '13.95'}), 200);
        }
        return http.Response('{}', 404);
      }),
    );
    final chefs = ((fixture('menu')['menus'] as List)[0]['sections'] as List)[1] as Map<String, dynamic>;
    final entry = MenuEntry.fromJson((chefs['entries'] as List)[0] as Map<String, dynamic>);
    ChosenLine? result;
    await tester.binding.setSurfaceSize(const Size(1000, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => result = await showDialog<ChosenLine>(
              context: context,
              builder: (_) => ItemSheet(api: api, entry: entry),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    Finder chip(String label) => find.ancestor(of: find.text(label), matching: find.byType(ChoiceTile));
    bool selected(String label) => tester.widget<ChoiceTile>(chip(label)).selected;
    Future<void> tapAndPrice(Finder what) async {
      await tester.tap(what);
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
    }

    // sizes and choices are buttons of the menu's grid, all one size, several to a row; no chips
    expect(find.byType(FilterChip), findsNothing);
    final tiles = tester.widgetList<ChoiceTile>(find.byType(ChoiceTile)).length;
    expect(tiles, 12); // two sizes, three spice levels, three rices, four add-ons
    expect(tester.getSize(find.byType(ChoiceTile).first), tester.getSize(find.byType(ChoiceTile).last));
    final sizes = find.byWidgetPredicate((w) => w is ChoiceTile && w.groupLabel == 'Size');
    expect(tester.getTopLeft(sizes.first).dy, tester.getTopLeft(sizes.last).dy); // side by side
    expect(chip('Add shrimp'), findsOneWidget);
    expect(find.descendant(of: chip('Add shrimp'), matching: find.text('+4.00')), findsOneWidget); // price badge

    // "No" and then the choice: it goes on the line with its word, and costs nothing
    await tester.tap(find.byKey(const ValueKey('instruction:no')));
    await tester.pump();
    expect(find.text('Now tap the choice to mark “No”.'), findsOneWidget);
    await tapAndPrice(chip('Add shrimp'));
    expect(selected('No Add shrimp'), isTrue);
    expect(find.text('Now tap the choice to mark “No”.'), findsNothing); // one choice per word
    expect(
      priced.last['selections'],
      contains(equals({'group_id': 'addons', 'option_id': 'addons:shrimp', 'prefix': 'no'})),
    );

    // "On the side" keeps the price; the same word again leaves the plain choice
    await tester.tap(find.byKey(const ValueKey('instruction:side')));
    await tester.pump();
    await tapAndPrice(chip('Extra sauce'));
    expect(selected('On the side Extra sauce'), isTrue);
    await tester.tap(find.byKey(const ValueKey('instruction:side')));
    await tester.pump();
    await tapAndPrice(chip('On the side Extra sauce'));
    expect(selected('Extra sauce'), isTrue);

    // the add-ons take several of the same choice: a plain tap on a chosen one adds another, the minus on
    // its chip takes one off, and the last one off takes the choice off the line
    expect(find.text('Tap again for one more, the minus for one fewer.'), findsOneWidget);
    await tapAndPrice(chip('Extra sauce'));
    expect(selected('2x Extra sauce'), isTrue);
    await tapAndPrice(chip('2x Extra sauce'));
    expect(selected('3x Extra sauce'), isTrue);
    expect(priced.last['selections'], contains(equals({'group_id': 'addons', 'option_id': 'addons:sauce', 'qty': 3})));
    Finder minus(String label) => find.descendant(of: chip(label), matching: find.byIcon(Icons.remove_circle_outline));
    await tapAndPrice(minus('3x Extra sauce'));
    expect(selected('2x Extra sauce'), isTrue);
    // "No" means none of it, however many there were; a choice left off has no count
    expect(minus('No Add shrimp'), findsOneWidget);
    expect(find.descendant(of: chip('No MSG'), matching: find.byIcon(Icons.remove_circle_outline)), findsNothing);

    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    expect(result!.request.prefixes, {'addons:shrimp': 'no'});
    expect(result!.request.selections['addons'], ['addons:shrimp', 'addons:sauce']);
    expect(result!.request.quantities, {'addons:sauce': 2});
    expect(result!.modifiers.map((m) => (m.label, m.price)), [
      ('No Add shrimp', '0.00'), // left off: free
      ('2x Extra sauce', '1.00'),
    ]);
    // the request goes to the hub and comes back with its counts; a copy keeps them, a last minus forgets them
    final back = LineRequest.fromJson(result!.request.toJson()).copy();
    expect(back.quantities, {'addons:sauce': 2});
    final addons = ItemDetail.fromJson(fixture('item_gtc')).groups.firstWhere((g) => g.groupId == 'addons');
    expect((addons.allowQuantity, back.units('addons')), (true, 3));
    back.removeOne(addons, 'addons:sauce');
    back.removeOne(addons, 'addons:sauce');
    expect(back.selections['addons'], ['addons:shrimp']);
    expect(back.quantities, isEmpty);
  });

  testWidgets('a saved menu reaches the screen without reopening it', (tester) async {
    var revision = 3;
    var reads = 0;
    final api = PosApi(
      Settings(device: 't1', endpoints: ['http://hub:8000']),
      client: MockClient((request) async {
        switch (request.url.path) {
          case '/menu/revision':
            return http.Response(jsonEncode({'revision': revision}), 200);
          case '/menu':
            reads++;
            final menu = fixture('menu');
            final first = (((menu['menus'] as List)[0]['sections'] as List)[0]['entries'] as List)[0] as Map;
            if (revision > 3) first['name'] = 'Egg roll (new recipe)';
            return http.Response.bytes(utf8.encode(jsonEncode({...menu, 'revision': revision})), 200);
        }
        return http.Response('{}', 404);
      }),
    );
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MenuPanel(api: api, onChosen: (_) {}),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Appetizers'));
    await tester.pumpAndSettle();
    expect(find.text('Egg roll'), findsOneWidget);

    await tester.pump(MenuPanelCheck.every); // nothing saved: one cheap check, no reload
    await tester.pumpAndSettle();
    expect(reads, 1);

    revision = 4; // a manager saves
    await tester.pump(MenuPanelCheck.every);
    await tester.pumpAndSettle();
    expect(reads, 2);
    expect(find.text('Egg roll (new recipe)'), findsOneWidget); // and still in the category it had open
  });

  testWidgets('a dish whose choices cannot be loaded is not added blind', (tester) async {
    final api = PosApi(
      Settings(device: 't1', endpoints: ['http://hub:8000']),
      client: MockClient((request) async {
        switch (request.url.path) {
          case '/menu':
            return http.Response.bytes(utf8.encode(jsonEncode(fixture('menu'))), 200);
          case '/menu/items/WHISKY':
            return http.Response('{"detail": "restarting"}', 503); // the hub is down between the menu and the tap
        }
        return http.Response('{}', 404);
      }),
    );
    final chosen = <ChosenLine>[];
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MenuPanel(api: api, onChosen: chosen.add),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'B5');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Japanese whisky'));
    await tester.pumpAndSettle();
    // Not added with its 'Serve' choice unknown (the hub would refuse the line), and the operator is told why.
    expect(chosen, isEmpty);
    expect(find.byKey(const ValueKey('required-selections')), findsNothing);
    expect(find.textContaining("Can't load the choices for Japanese whisky"), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  test("a choice that is a dish carries the dish's own groups, and the choices on it travel as children", () {
    final c5 = ItemDetail.fromJson(fixture('item_c5'));
    final entree = c5.groups.firstWhere((g) => g.groupId == 'entree_slot');
    final gtc = entree.options.firstWhere((o) => o.optionId == 'entree_slot:gtc');
    expect((gtc.isDish, gtc.linkedItem, gtc.isDefault), (true, 'GTC', true));
    expect(gtc.groups.map((g) => g.groupId), ['spice', 'rice', 'addons']);
    final side = c5.groups.firstWhere((g) => g.groupId == 'side_slot');
    expect(side.options.first.isDish && side.options.first.groups.isEmpty, isTrue); // its choices are locked

    // the dish's defaults, and the defaults of the dish it comes with, one level down
    final request = LineRequest(variantId: 'C5:regular', entryId: 'dinner:C5');
    fillDefaults(c5.groups, request);
    expect(request.selections, {
      'entree_slot': ['entree_slot:gtc'],
      'side_slot': ['side_slot:eggroll'],
      'rice_slot': ['rice_slot:pfr'],
    });
    expect(request.nested['entree_slot:gtc']!.selections, {
      'spice': ['spice:medium'],
      'rice': ['rice:white'],
    });
    expect(pickedModifiers(c5.groups, request), isEmpty); // nothing differs from the menu

    // a change on the chosen dish goes as that selection's children, and comes back the same
    final inside = request.inside('entree_slot:gtc');
    inside.selections['spice'] = ['spice:extra'];
    inside.selections['addons'] = ['addons:shrimp'];
    inside.prefixes['addons:shrimp'] = 'extra';
    expect(request.toJson()['selections'], [
      {
        'group_id': 'entree_slot',
        'option_id': 'entree_slot:gtc',
        'children': [
          {'group_id': 'spice', 'option_id': 'spice:extra'},
          {'group_id': 'rice', 'option_id': 'rice:white'},
          {'group_id': 'addons', 'option_id': 'addons:shrimp', 'prefix': 'extra'},
        ],
      },
      {'group_id': 'side_slot', 'option_id': 'side_slot:eggroll'},
      {'group_id': 'rice_slot', 'option_id': 'rice_slot:pfr'},
    ]);
    final back = LineRequest.fromJson(request.toJson());
    expect(back.nested['entree_slot:gtc']!.selections['addons'], ['addons:shrimp']);
    expect(back.nested['entree_slot:gtc']!.prefixes, {'addons:shrimp': 'extra'});
    final copy = back.copy();
    copy.inside('entree_slot:gtc').selections['spice'] = ['spice:mild'];
    expect(back.nested['entree_slot:gtc']!.selections['spice'], ['spice:extra']); // a copy, not a view
    // the check lists the dish the menu chose, since a choice on it changed, then its changes one level in
    expect(pickedModifiers(c5.groups, back).map((m) => (m.label, m.price, m.depth)), [
      ("General Tso's Chicken", '0.00', 0),
      ('Extra spicy', '0.00', 1),
      ('Extra Add shrimp', '4.00', 1),
    ]);
    expect(CheckModifier.fromJson({'label': 'Extra spicy', 'price': '0.00', 'depth': 1}).depth, 1);
    expect(CheckModifier.fromJson({'label': 'Brown rice', 'price': '1.00'}).depth, 0); // an older hub

    // a note to the kitchen on the chosen dish goes as that selection's notes and reads under it on the check
    back.inside('entree_slot:gtc').notes = 'no MSG';
    final noted = (back.toJson()['selections'] as List).first as Map<String, dynamic>;
    expect(noted['notes'], 'no MSG');
    expect(LineRequest.fromJson(back.toJson()).nested['entree_slot:gtc']!.notes, 'no MSG');
    expect(back.copy().nested['entree_slot:gtc']!.notes, 'no MSG');
    expect(pickedModifiers(c5.groups, back).map((m) => (m.label, m.price, m.depth)).last, ('no MSG', '0.00', 1));
    back.inside('entree_slot:gtc').notes = '';
    expect((back.toJson()['selections'] as List).first, isNot(contains('notes')));

    // what choosing a dish still has to ask: the required groups its defaults do not answer
    expect(openGroups(gtc), isEmpty); // medium and white rice come by default
    final bb = c5.groups.first.options[1];
    expect(openGroups(bb), isEmpty);
    final rice = gtc.groups[1];
    final noDefault = GroupDetail(
      groupId: rice.groupId,
      name: rice.name,
      minSelect: rice.minSelect,
      maxSelect: rice.maxSelect,
      options: [
        for (final o in rice.options)
          OptionDetail(
            optionId: o.optionId,
            name: o.name,
            price: o.price,
            isDefault: false,
            status: o.status,
            linkedItem: o.linkedItem,
            groups: o.groups,
          ),
      ],
    );
    final openGtc = OptionDetail(
      optionId: gtc.optionId,
      name: gtc.name,
      price: gtc.price,
      isDefault: gtc.isDefault,
      status: gtc.status,
      linkedItem: gtc.linkedItem,
      groups: [gtc.groups[0], noDefault, gtc.groups[2]],
    );
    expect(openGroups(openGtc).map((g) => g.groupId), ['rice']);
    final fresh = defaultChoices(openGtc.groups);
    expect(fresh.selections, {
      'spice': ['spice:medium'],
    });
    expect(choicesComplete(openGtc.groups, fresh), isFalse);
    fresh.take(noDefault, 'rice:brown');
    expect(choicesComplete(openGtc.groups, fresh), isTrue);
    expect(choicesComplete(c5.groups, request), isTrue);
    // a dish chosen with a hold is taken as a tap takes it: alone in a single-pick group, added in a multi-pick one
    final plate = defaultChoices(c5.groups);
    plate.take(c5.groups.first, 'entree_slot:bb');
    expect(plate.selections['entree_slot'], ['entree_slot:bb']);
    final addons = gtc.groups[2];
    final extras = Choices()..prefixes['addons:shrimp'] = 'extra';
    extras.take(addons, 'addons:shrimp');
    extras.take(addons, 'addons:sauce');
    expect(extras.selections['addons'], ['addons:shrimp', 'addons:sauce']);
    expect(extras.prefixes, {'addons:shrimp': 'extra'});
  });

  testWidgets("the item sheet takes a chosen dish with its defaults, and a hold opens the dish's own sheet", (
    tester,
  ) async {
    final priced = <Map<String, dynamic>>[];
    final (entry, api) = plateAndApi(fixture('item_c5'), priced);
    ChosenLine? result;
    await tester.binding.setSurfaceSize(const Size(1000, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => result = await showDialog<ChosenLine>(
              context: context,
              builder: (_) => ItemSheet(api: api, entry: entry),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();

    // the entree the plate comes with is chosen as it comes: its defaults answer everything, so nothing opens
    expect(find.byKey(const ValueKey('inside:entree_slot:gtc')), findsNothing);
    expect(find.byKey(const ValueKey('inside:side_slot:eggroll')), findsNothing);
    expect(find.byIcon(Icons.restaurant_menu), findsNWidgets(7)); // every choice on the plate is a dish
    expect(find.byIcon(Icons.tune), findsNothing);
    // the hub was asked to price the plate with the entree's own defaults as children
    final first = (priced.last['selections'] as List).cast<Map<String, dynamic>>();
    expect(first.firstWhere((s) => s['option_id'] == 'entree_slot:gtc')['children'], [
      {'group_id': 'spice', 'option_id': 'spice:medium'},
      {'group_id': 'rice', 'option_id': 'rice:white'},
    ]);

    // a hold on the entree opens it like its own tile would: every choice on it, and a note to the kitchen
    final gtcChip = find.byKey(const ValueKey('choice:entree_slot:gtc@0'));
    await tester.longPress(gtcChip);
    await tester.pumpAndSettle();
    final dish = find.byType(DishChoicesSheet);
    expect(dish, findsOneWidget);
    for (final group in ['Spice level', 'Choice of rice (required)', 'Add-ons']) {
      expect(find.descendant(of: dish, matching: find.text(group)), findsWidgets); // the heading, and each button
    }
    await tester.tap(find.byKey(const ValueKey('choice:spice:extra@0')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('choice:addons:shrimp@0')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('dish-note')), 'no MSG');
    await tester.tap(find.widgetWithText(FilledButton, 'Done'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    expect(find.byType(DishChoicesSheet), findsNothing);
    final gtc = (priced.last['selections'] as List).firstWhere((s) => s['option_id'] == 'entree_slot:gtc');
    expect(gtc['children'], [
      {'group_id': 'spice', 'option_id': 'spice:extra'},
      {'group_id': 'rice', 'option_id': 'rice:white'},
      {'group_id': 'addons', 'option_id': 'addons:shrimp'},
    ]);
    expect(gtc['notes'], 'no MSG');
    expect(find.descendant(of: gtcChip, matching: find.byIcon(Icons.tune)), findsOneWidget); // changed

    // a hold on another entree, left with Cancel, changes nothing
    await tester.longPress(find.byKey(const ValueKey('choice:entree_slot:bb@0')));
    await tester.pumpAndSettle();
    expect(find.byType(DishChoicesSheet), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel').last);
    await tester.pumpAndSettle();
    expect(find.byType(DishChoicesSheet), findsNothing);
    final kept = (priced.last['selections'] as List).cast<Map<String, dynamic>>();
    expect(kept.map((s) => s['option_id']), contains('entree_slot:gtc'));
    expect(kept.map((s) => s['option_id']), isNot(contains('entree_slot:bb')));

    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    final request = result!.request;
    expect(request.selections['entree_slot'], ['entree_slot:gtc']);
    expect(request.nested['entree_slot:gtc']!.notes, 'no MSG');
    expect(result!.unitPrice, '19.50'); // the hub's price
    // the check reads the entree, since choices on it changed, then its changes and its note one step in
    expect(result!.modifiers.map((m) => (m.label, m.price, m.depth)), [
      ("General Tso's Chicken", '0.00', 0),
      ('Extra spicy', '0.00', 1),
      ('Add shrimp', '4.00', 1),
      ('no MSG', '0.00', 1),
    ]);
  });

  testWidgets("the item sheet asks under a chosen dish only what its defaults leave open", (tester) async {
    // the plate's entree comes without a rice: that one question opens under it, nothing else
    final c5 = fixture('item_c5');
    final gtc = ((c5['groups'] as List)[0]['options'] as List)[0] as Map<String, dynamic>;
    for (final g in gtc['groups'] as List) {
      if (g['group_id'] != 'rice') continue;
      for (final o in g['options'] as List) {
        o['is_default'] = false;
      }
    }
    final priced = <Map<String, dynamic>>[];
    final (entry, api) = plateAndApi(c5, priced);
    await tester.binding.setSurfaceSize(const Size(1000, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<ChosenLine>(
              context: context,
              builder: (_) => ItemSheet(api: api, entry: entry),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    final inside = find.byKey(const ValueKey('inside:entree_slot:gtc'));
    expect(inside, findsOneWidget);
    expect(find.descendant(of: inside, matching: find.text('Choice of rice (required)')), findsOneWidget);
    expect(find.descendant(of: inside, matching: find.text('Spice level')), findsNothing); // medium by default
    expect(find.descendant(of: inside, matching: find.text('Add-ons')), findsNothing); // nothing required
    await tester.tap(find.byKey(const ValueKey('choice:rice:brown@1')));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    final sent = (priced.last['selections'] as List).firstWhere((s) => s['option_id'] == 'entree_slot:gtc');
    expect(sent['children'], [
      {'group_id': 'spice', 'option_id': 'spice:medium'},
      {'group_id': 'rice', 'option_id': 'rice:brown'},
    ]);
    // another entree whose defaults answer everything: chosen, nothing opens
    await tester.tap(find.text('Beef with Broccoli'));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('inside:entree_slot:gtc')), findsNothing);
    expect(find.byKey(const ValueKey('inside:entree_slot:bb')), findsNothing);
    final bb = (priced.last['selections'] as List).firstWhere((s) => s['option_id'] == 'entree_slot:bb');
    expect(bb['children'], [
      {'group_id': 'spice', 'option_id': 'spice:medium'},
      {'group_id': 'rice', 'option_id': 'rice:white'},
    ]);
  });

  testWidgets("the tray asks what a chosen dish's own defaults leave open, under the dish", (tester) async {
    final api = makiApi();
    final chosen = <ChosenLine>[];
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MenuPanel(api: api, onChosen: chosen.add),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'C5');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Combination Plate'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('required-selections')), findsOneWidget);
    expect(find.text('Roll (0/2)'), findsNWidgets(2));
    expect(find.byKey(const ValueKey('req-option:roll:K01/sauce:sauce:soy')), findsNothing);

    // the first roll chosen has a sauce to pick: asked right after the rolls, named for the roll
    await tester.tap(find.text('Kappa Maki'));
    await tester.pumpAndSettle();
    expect(chosen, isEmpty);
    expect(find.text('Roll (1/2)'), findsNWidgets(2));
    expect(find.text('Kappa Maki · Sauce'), findsNWidgets(2));
    await tester.tap(find.text('Tekka Maki'));
    await tester.pumpAndSettle();
    expect(chosen, isEmpty); // two rolls, but the sauce is still open
    expect(find.text('Roll (2/2)'), findsNWidgets(2));
    await tester.tap(find.byKey(const ValueKey('req-option:roll:K01/sauce:sauce:spicy')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('required-selections')), findsNothing);
    final line = chosen.single;
    expect(line.request.selections['roll'], ['roll:K01', 'roll:K02']);
    expect(line.request.toJson()['selections'], [
      {
        'group_id': 'roll',
        'option_id': 'roll:K01',
        'children': [
          {'group_id': 'sauce', 'option_id': 'sauce:spicy'},
        ],
      },
      {'group_id': 'roll', 'option_id': 'roll:K02'},
    ]);
    expect(line.unitPrice, '15.00'); // 14.50 + the sauce
    expect(line.modifiers.map((m) => (m.label, m.price, m.depth)), [
      ('Kappa Maki', '0.00', 0),
      ('Spicy mayo', '0.50', 1),
      ('Tekka Maki', '0.00', 0),
    ]);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets("a hold on a dish in the tray opens the dish's own sheet, and Done chooses it as made there", (
    tester,
  ) async {
    final api = makiApi();
    final chosen = <ChosenLine>[];
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MenuPanel(api: api, onChosen: chosen.add),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'C5');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Combination Plate'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('required-selections')), findsOneWidget);
    expect(find.byIcon(Icons.restaurant_menu), findsNWidgets(2)); // both rolls are dishes: a hold opens them

    // a hold on the first roll: its sauce is asked in its own sheet, and Done waits for it
    await tester.longPress(find.text('Kappa Maki'));
    await tester.pumpAndSettle();
    final sheet = find.byType(DishChoicesSheet);
    expect(sheet, findsOneWidget);
    expect(find.descendant(of: sheet, matching: find.text('Sauce (required)')), findsOneWidget);
    final done = find.widgetWithText(FilledButton, 'Done');
    expect(tester.widget<FilledButton>(done).onPressed, isNull);
    await tester.tap(find.byKey(const ValueKey('choice:sauce:spicy@0')));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(done).onPressed, isNotNull);
    await tester.tap(done);
    await tester.pumpAndSettle();
    expect(find.byType(DishChoicesSheet), findsNothing);
    expect(chosen, isEmpty); // one roll of two
    expect(find.text('Roll (1/2)'), findsNWidgets(2));
    expect(find.text('Kappa Maki · Sauce'), findsNothing); // answered in the sheet, not asked again

    // a hold on a roll with nothing to choose: just the note to the kitchen
    await tester.longPress(find.text('Tekka Maki'));
    await tester.pumpAndSettle();
    expect(find.byType(DishChoicesSheet), findsOneWidget);
    expect(find.descendant(of: find.byType(DishChoicesSheet), matching: find.byType(ChoiceTile)), findsNothing);
    await tester.enterText(find.byKey(const ValueKey('dish-note')), 'no sesame');
    await tester.tap(find.widgetWithText(FilledButton, 'Done'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('required-selections')), findsNothing); // two rolls, nothing open: added
    final line = chosen.single;
    expect(line.request.toJson()['selections'], [
      {
        'group_id': 'roll',
        'option_id': 'roll:K01',
        'children': [
          {'group_id': 'sauce', 'option_id': 'sauce:spicy'},
        ],
      },
      {'group_id': 'roll', 'option_id': 'roll:K02', 'notes': 'no sesame'},
    ]);
    expect(line.unitPrice, '15.00');
    expect(line.modifiers.map((m) => (m.label, m.price, m.depth)), [
      ('Kappa Maki', '0.00', 0),
      ('Spicy mayo', '0.50', 1),
      ('Tekka Maki', '0.00', 0),
      ('no sesame', '0.00', 1),
    ]);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the tray takes two of the same choice where the group allows it', (tester) async {
    final api = makiApi(quantity: true);
    final chosen = <ChosenLine>[];
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MenuPanel(api: api, onChosen: chosen.add),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'C5');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Combination Plate'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tekka Maki'));
    await tester.pumpAndSettle();
    expect(find.text('Roll (1/2)'), findsNWidgets(2));
    expect(chosen, isEmpty);
    await tester.tap(find.text('Tekka Maki')); // the same roll again: two of it fill the combination
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('required-selections')), findsNothing);
    expect(chosen.single.request.toJson()['selections'], [
      {'group_id': 'roll', 'option_id': 'roll:K02', 'qty': 2},
    ]);
    expect(chosen.single.modifiers.map((m) => m.label), ['2x Tekka Maki']);
    await tester.pumpWidget(const SizedBox());
  });
}

/// The combination plate of the sample menu and a hub that serves its choices from [c5] and prices it at 19.50,
/// keeping every price request in [priced].
(MenuEntry, PosApi) plateAndApi(Map<String, dynamic> c5, List<Map<String, dynamic>> priced) {
  final api = PosApi(
    Settings(device: 't1', endpoints: ['http://hub:8000']),
    client: MockClient((request) async {
      switch (request.url.path) {
        case '/menu/items/C5':
          return http.Response.bytes(utf8.encode(jsonEncode(c5)), 200);
        case '/menu/price':
          priced.add(jsonDecode(request.body) as Map<String, dynamic>);
          return http.Response(jsonEncode({'name': 'Combination Plate', 'unit_price': '19.50'}), 200);
      }
      return http.Response('{}', 404);
    }),
  );
  final sections = (fixture('menu')['menus'] as List)[0]['sections'] as List;
  final entryJson = [
    for (final s in sections)
      for (final e in s['entries'] as List)
        if (e['item'] == 'C5') e,
  ].single;
  return (MenuEntry.fromJson(entryJson as Map<String, dynamic>), api);
}

/// A roll offered by a maki combination: a dish, with a sauce to pick when [sauce].
Map<String, dynamic> roll(String code, String name, {bool sauce = false}) => {
  'option_id': 'roll:$code',
  'name': name,
  'price': '0.00',
  'is_default': false,
  'status': 'available',
  'linked_item': code,
  'groups': [
    if (sauce)
      {
        'group_id': 'sauce',
        'name': 'Sauce',
        'min_select': 1,
        'max_select': 1,
        'options': [
          {'option_id': 'sauce:soy', 'name': 'Soy', 'price': '0.00', 'status': 'available'},
          {'option_id': 'sauce:spicy', 'name': 'Spicy mayo', 'price': '0.50', 'status': 'available'},
        ],
      },
  ],
};

/// A hub whose combination plate is a maki combination of two rolls, the first with a sauce to pick.
/// With [quantity] the same roll can be picked twice.
PosApi makiApi({bool quantity = false}) {
  final maki = {
    'item': 'C5',
    'name': 'Combination Plate',
    'variants': [
      {'variant_id': 'C5:regular', 'name': 'Regular', 'price': '14.50', 'status': 'available'},
    ],
    'groups': [
      {
        'group_id': 'roll',
        'name': 'Roll',
        'min_select': 2,
        'max_select': 2,
        'allow_quantity': quantity,
        'options': [roll('K01', 'Kappa Maki', sauce: true), roll('K02', 'Tekka Maki')],
      },
    ],
  };
  return PosApi(
    Settings(device: 't1', endpoints: ['http://hub:8000']),
    client: MockClient((request) async {
      switch (request.url.path) {
        case '/menu':
          return http.Response.bytes(utf8.encode(jsonEncode(fixture('menu'))), 200);
        case '/menu/items/C5':
          return http.Response.bytes(utf8.encode(jsonEncode(maki)), 200);
      }
      return http.Response('{}', 404);
    }),
  );
}

/// The appetizer platter's group as the hub sends it: six of eight come with the dish, six it must be.
GroupDetail _platter() => GroupDetail(
  groupId: 'platter',
  name: 'Platter',
  minSelect: 6,
  maxSelect: 6,
  allowQuantity: true,
  options: [
    for (final (code, comesWith) in [
      ('veg_spring_roll', false),
      ('spring_roll', true),
      ('chicken_wings', true),
      ('chicken_fingers', true),
      ('spare_ribs', false),
      ('boneless_ribs', true),
      ('beef_teriyaki', true),
      ('crab_rangoon', true),
    ])
      OptionDetail(optionId: 'platter:$code', name: code, price: '0.00', isDefault: comesWith, status: 'available'),
  ],
);

void _platterTests() {
  test('the platter comes with its six chosen, and a "no" leaves a place for one more of another', () {
    final platter = _platter();
    final fingers = platter.options[3];
    final choices = defaultChoices([platter]);
    expect(choices.selections['platter'], hasLength(6));
    expect(choices.units('platter'), 6);
    expect(choicesComplete([platter], choices), isTrue);
    expect(choices.room(platter), isFalse);
    expect(choices.addOne(platter, fingers), isFalse); // six is six

    choices.prefixes['platter:crab_rangoon'] = 'no';
    expect(choices.taken('platter'), 5);
    expect(choices.addOne(platter, fingers), isTrue);
    expect(choices.taken('platter'), 6);
    expect(choices.room(platter), isFalse);
    expect(choicesComplete([platter], choices), isTrue);

    // taken off outright instead: one short until something takes its place
    final swapped = defaultChoices([platter])..removeOne(platter, 'platter:crab_rangoon');
    expect(choicesComplete([platter], swapped), isFalse);
    expect(swapped.addOne(platter, fingers), isTrue);
    expect(choicesComplete([platter], swapped), isTrue);
  });
}
