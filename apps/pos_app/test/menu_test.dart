import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/menu.dart';
import 'package:pos_app/screens/menu_panel.dart';
import 'package:pos_app/screens/reflow.dart';
import 'package:pos_app/screens/theme.dart';
import 'package:pos_app/settings.dart';

/// Fixtures are the backend's own answers (sample menu), saved from its test client.
Map<String, dynamic> fixture(String name) =>
    jsonDecode(File('test/fixtures/$name.json').readAsStringSync()) as Map<String, dynamic>;

void main() {
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
        ..devicePixelRatio = 1; // a phone: the tray of tiles, not a tablet's strip
      addTearDown(tester.view.reset);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Bar'));
      await tester.pumpAndSettle();
      final whiskyTile = find.byKey(const ValueKey('e:dinner:B5:WHISKY'));
      await tester.tap(whiskyTile);
      await tester.pump(); // complete async api.item('WHISKY')
      await tester.pump(Reflow.duration ~/ 2);
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

  testWidgets('on a tablet an open category collapses its siblings to a strip and the dishes get the room', (
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
      ..devicePixelRatio = 1; // a tablet, by the screen width the panel goes by
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MenuPanel(api: api, onChosen: (_) {}),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('category-strip')), findsNothing);

    // every category tile has its own colour: the menu's own for the sushi bar, the palette for the rest
    final scheme = Theme.of(tester.element(find.text('Sushi bar'))).colorScheme;
    Color tileColor(String name) {
      final box = find.ancestor(of: find.text(name), matching: find.byType(AnimatedContainer)).first;
      return (tester.widget<AnimatedContainer>(box).decoration! as BoxDecoration).color!;
    }

    expect(tileColor('Sushi bar'), categoryTint(scheme, hex: '#2F5E48', index: 3).fill);
    expect(tileColor('Appetizers'), categoryTint(scheme, index: 0).fill);
    expect(tileColor('Appetizers'), isNot(tileColor("Chef's Specials")));

    // Opening a category: the tiles travel up into a strip of chips, and the dishes take the rest.
    final tileTop = tester.getTopLeft(find.text("Chef's Specials")).dy;
    await tester.tap(find.text('Appetizers'));
    await tester.pump(); // the new layout, with the travelling copies
    await tester.pump(); // their first frame
    await tester.pump(Reflow.duration ~/ 2);
    final halfway = [
      for (final e in find.text("Chef's Specials").evaluate()) tester.getTopLeft(find.byWidget(e.widget)).dy,
    ];
    await tester.pumpAndSettle();
    final strip = find.byKey(const ValueKey('category-strip'));
    expect(strip, findsOneWidget);
    expect(find.byKey(const ValueKey('categories-0')), findsNothing);
    expect(find.byType(TextField), findsNothing);
    expect(tester.getSize(strip).height, 48);
    final chipTop = tester.getTopLeft(find.text("Chef's Specials")).dy;
    expect(chipTop, lessThan(tileTop));
    expect(halfway.any((y) => y < tileTop - 4 && y > chipTop + 4), isTrue);
    expect(find.text('Egg roll'), findsOneWidget);
    final items = tester.getRect(find.byKey(const ValueKey('items-dinner/apps')));
    expect(items.top, closeTo(49, 1.5));
    expect(items.bottom, closeTo(800, 1.5));

    // the customize mark only where a tap will ask: two sizes, not a rice group with a default
    await tester.tap(find.text("Chef's Specials"));
    await tester.pumpAndSettle();
    expect(find.text('Egg roll'), findsNothing);
    final gtc = find.byKey(const ValueKey('e:dinner:87:GTC'));
    final bb = find.byKey(const ValueKey('e:dinner:88:BB'));
    expect(find.descendant(of: gtc, matching: find.byIcon(Icons.tune)), findsOneWidget);
    expect(find.descendant(of: bb, matching: find.byIcon(Icons.tune)), findsNothing);

    // nested: Bar's subcategory opens from the dishes into the strip, behind a crumb; back goes one level
    await tester.tap(find.text('Bar'));
    await tester.pumpAndSettle();
    expect(find.text('Mai Tai'), findsOneWidget);
    await tester.tap(find.text('Beer'));
    await tester.pumpAndSettle();
    expect(find.text('Tsingtao'), findsOneWidget);
    expect(find.text('Bar ›'), findsOneWidget);
    expect(find.text('Mai Tai'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('menu-back')));
    await tester.pumpAndSettle();
    expect(find.text('Mai Tai'), findsOneWidget);
    expect(find.text('Bar ›'), findsNothing);
    expect(find.text('Tsingtao'), findsNothing);

    // pulling down at the top of the dishes closes the category: the grid of tiles is back, with the search
    await tester.drag(find.text('Mai Tai'), const Offset(0, 300));
    await tester.pumpAndSettle();
    expect(strip, findsNothing);
    expect(find.byKey(const ValueKey('categories-0')), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('Mai Tai'), findsNothing);
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
    Finder chip(String label) => find.ancestor(of: find.text(label), matching: find.byType(FilterChip));
    bool selected(String label) => tester.widget<FilterChip>(chip(label)).selected;
    Future<void> tapAndPrice(Finder what) async {
      await tester.tap(what);
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
    }

    // "No" and then the choice: it goes on the line with its word, and costs nothing
    await tester.tap(find.byKey(const ValueKey('instruction:no')));
    await tester.pump();
    expect(find.text('Now tap the choice to mark “No”.'), findsOneWidget);
    await tapAndPrice(chip('Add shrimp +4.00'));
    expect(selected('No Add shrimp'), isTrue);
    expect(find.text('Now tap the choice to mark “No”.'), findsNothing); // one choice per word
    expect(
      priced.last['selections'],
      contains(equals({'group_id': 'addons', 'option_id': 'addons:shrimp', 'prefix': 'no'})),
    );

    // "On the side" keeps the price; the same word again leaves the plain choice; a plain tap takes it off
    await tester.tap(find.byKey(const ValueKey('instruction:side')));
    await tester.pump();
    await tapAndPrice(chip('Extra sauce +0.50'));
    expect(selected('On the side Extra sauce +0.50'), isTrue);
    await tester.tap(find.byKey(const ValueKey('instruction:side')));
    await tester.pump();
    await tapAndPrice(chip('On the side Extra sauce +0.50'));
    expect(selected('Extra sauce +0.50'), isTrue);
    await tapAndPrice(chip('Extra sauce +0.50'));
    expect(selected('Extra sauce +0.50'), isFalse);
    expect((priced.last['selections'] as List).any((s) => s['option_id'] == 'addons:sauce'), isFalse);

    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    expect(result!.request.prefixes, {'addons:shrimp': 'no'});
    expect(result!.request.selections['addons'], ['addons:shrimp']);
    expect(result!.modifiers, ['No Add shrimp']);
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
}
