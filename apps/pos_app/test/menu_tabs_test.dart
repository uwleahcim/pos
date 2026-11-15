import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/screens/menu_panel.dart';
import 'package:pos_app/settings.dart';

import 'hub.dart';

/// The fixture's one menu as the hub serves it now: the food on the Food menu, the bar on a Drinks menu of its
/// own, the soft drinks on both (an entry per menu, the same dish). Lunch comes and goes with the hour, one
/// category of specials. On request a Wine menu whose one category holds sub-categories.
Map<String, dynamic> menus({bool lunch = false, bool wine = false}) {
  final sections = (fixture('menu')['menus'] as List)[0]['sections'] as List;
  Map<String, dynamic> onMenu(Map<String, dynamic> section, String menu) {
    final id = (section['section_id'] as String).replaceFirst('dinner/', '$menu/');
    return {
      ...section,
      'section_id': id,
      'entries': [
        for (final e in section['entries'] as List)
          {...e as Map<String, dynamic>, 'entry_id': (e['entry_id'] as String).replaceFirst('dinner:', '$menu:')},
      ],
    };
  }

  final bar = sections.firstWhere((s) => s['section_id'] == 'dinner/bar') as Map<String, dynamic>;
  final soft = sections.firstWhere((s) => s['section_id'] == 'dinner/drinks') as Map<String, dynamic>;
  final appetizers = sections.first as Map<String, dynamic>;
  return {
    'revision': lunch ? 1 : 0,
    'menus': [
      if (lunch)
        {
          'menu': 'lunch',
          'name': 'Lunch',
          'priority': 10,
          'sections': [
            {
              ...appetizers,
              'section_id': 'lunch/specials',
              'name': 'Lunch Specials',
              'entries': [
                {
                  ...(appetizers['entries'] as List).first as Map<String, dynamic>,
                  'entry_id': 'lunch:L1',
                  'number': 'L1',
                  'variants': [
                    {'variant_id': 'EGGROLL:regular', 'name': '2 pc', 'price': '2.50', 'status': 'available'},
                  ],
                },
              ],
            },
          ],
        },
      {
        'menu': 'dinner',
        'name': 'Food',
        'priority': 0,
        'sections': [
          for (final s in sections)
            if (s != bar) s,
        ],
      },
      {
        'menu': 'drinks',
        'name': 'Drinks',
        'priority': -10,
        'sections': [onMenu(bar, 'drinks'), onMenu(soft, 'drinks')],
      },
      if (wine)
        {
          'menu': 'wine',
          'name': 'Wine',
          'priority': -20,
          'sections': [
            {
              'section_id': 'wine/list',
              'name': 'Wine list',
              'entries': <Map<String, dynamic>>[],
              'sections': [
                {...onMenu(bar, 'wine'), 'name': 'Bar shelf'},
                onMenu(soft, 'wine'),
              ],
            },
          ],
        },
    ],
  };
}

Future<void> mount(WidgetTester tester, Map<String, dynamic> Function() served, {List<ChosenLine>? chosen}) async {
  final api = PosApi(
    Settings(device: 't1', endpoints: ['http://hub:8000']),
    client: MockClient((request) async {
      final body = served();
      return switch (request.url.path) {
        // with the hub's content type: without it the Chinese names would be read as Latin-1
        '/menu' => http.Response.bytes(
          utf8.encode(jsonEncode(body)),
          200,
          headers: {'content-type': 'application/json'},
        ),
        '/menu/revision' => http.Response(jsonEncode({'revision': body['revision']}), 200),
        _ => http.Response('{}', 404),
      };
    }),
  );
  tester.view
    ..physicalSize =
        const Size(400, 800) // a phone: the tabs share the search's row, no row of their own
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: MenuPanel(api: api, onChosen: (line) => chosen?.add(line)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder tab(String name) => find.descendant(of: find.byKey(const ValueKey('menu-tabs')), matching: find.text(name));

/// The dishes the search found, as they read on the screen: row by row, left to right.
List<String> foundDishes(WidgetTester tester) {
  final tiles = find
      .descendant(
        of: find.byKey(const ValueKey('search-grid')),
        matching: find.byWidgetPredicate(
          (w) => switch (w.key) {
            ValueKey<String>(:final value) => value.startsWith('e:'),
            _ => false,
          },
        ),
      )
      .evaluate()
      .toList();
  Offset at(Element tile) => (tile.renderObject! as RenderBox).localToGlobal(Offset.zero);
  tiles.sort((a, b) => at(a).dy != at(b).dy ? at(a).dy.compareTo(at(b).dy) : at(a).dx.compareTo(at(b).dx));
  return [for (final tile in tiles) (tile.widget.key! as ValueKey<String>).value];
}

void main() {
  testWidgets('the menus open are tabs: Food first, a tap shows the other menu and closes what was open', (
    tester,
  ) async {
    await mount(tester, menus);
    expect(find.byKey(const ValueKey('menu-tabs')), findsOneWidget);
    expect(tab('Food'), findsOneWidget);
    expect(tab('Drinks'), findsOneWidget);
    // the Food tab's categories: the kitchen's, and the soft drinks that are on both menus; not the bar
    expect(find.text('Appetizers'), findsOneWidget);
    expect(find.text('Soft drinks'), findsOneWidget);
    expect(find.text('Bar'), findsNothing);
    // the tabs and the search share one row above the categories, as high as the search row alone was
    final tabs = tester.getRect(find.byKey(const ValueKey('menu-tabs')));
    final search = tester.getRect(find.byType(TextField));
    expect(search.left, greaterThan(tabs.right));
    expect(tester.getRect(find.byKey(const ValueKey('categories-0'))).top, closeTo(56, 0.5));

    // a category opens its dishes below; the tabs stay (the search goes), so the other menu is one tap away
    await tester.tap(find.text('Appetizers'));
    await tester.pumpAndSettle();
    expect(find.text('Egg roll'), findsOneWidget);
    expect(tab('Drinks'), findsOneWidget);
    expect(
      tester.widget<Opacity>(find.ancestor(of: find.byType(TextField), matching: find.byType(Opacity)).first).opacity,
      0,
    );

    // the Drinks tab: its categories, the open Food category closed
    await tester.tap(tab('Drinks'));
    await tester.pumpAndSettle();
    expect(find.text('Bar'), findsOneWidget);
    expect(find.text('Soft drinks'), findsOneWidget);
    expect(find.text('Appetizers'), findsNothing);
    expect(find.text('Egg roll'), findsNothing);
    await tester.tap(find.text('Bar'));
    await tester.pumpAndSettle();
    expect(find.text('Tsingtao'), findsOneWidget);
    expect(find.byKey(const ValueKey('items-drinks/bar')), findsOneWidget);

    // and back
    await tester.tap(tab('Food'));
    await tester.pumpAndSettle();
    expect(find.text('Appetizers'), findsOneWidget);
    expect(find.text('Tsingtao'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('one menu open shows no tabs, and the search row folds away as before', (tester) async {
    await mount(tester, () => fixture('menu'));
    expect(find.byKey(const ValueKey('menu-tabs')), findsNothing);
    expect(find.text('Bar'), findsOneWidget);
    await tester.tap(find.text('Appetizers'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the search looks on every menu, whichever tab shows, and lists a dish on two menus once', (
    tester,
  ) async {
    await mount(tester, menus);
    await tester.enterText(find.byType(TextField), 'Tsingtao'); // at the bar, typed on the Food tab
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('e:drinks:B1:TSINGTAO')), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Soda'); // on both menus
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('e:dinner:D2:SODA')), findsOneWidget); // once, under its first menu
    expect(find.byKey(const ValueKey('e:drinks:D2:SODA')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the search lists a dish the lunch menu sells at another price from both menus', (tester) async {
    await mount(tester, () => menus(lunch: true));
    await tester.enterText(find.byType(TextField), 'Egg roll'); // L1 at lunch, 1 on the Food menu
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('e:lunch:L1:EGGROLL')), findsOneWidget);
    expect(find.byKey(const ValueKey('e:dinner:1:EGGROLL')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the search lists the best match first: every word typed, in any order, then one of them', (
    tester,
  ) async {
    await mount(tester, menus);
    // both words, the other way round: the spring roll, then the other rolls as the menu has them (the one
    // with the longest name last)
    await tester.enterText(find.byType(TextField), 'roll spring');
    await tester.pumpAndSettle();
    expect(foundDishes(tester), [
      'e:dinner:2:SPRINGROLL',
      'e:dinner:1:EGGROLL',
      'e:dinner:S1:CALROLL',
      'e:dinner:S4:DRAGON',
      'e:dinner:S2:SPTUNA',
    ]);
    // "with" is not a word to look for, a slip of the keyboard is forgiven, several is one
    await tester.enterText(find.byType(TextField), 'beef with brocoli');
    await tester.pumpAndSettle();
    expect(foundDishes(tester), ['e:dinner:88:BB']);
    await tester.enterText(find.byType(TextField), 'chicken wing');
    await tester.pumpAndSettle();
    expect(foundDishes(tester), ['e:dinner:3:WINGS', 'e:dinner:87:GTC']);
    // two words typed as one, at the bar
    await tester.enterText(find.byType(TextField), 'maitai');
    await tester.pumpAndSettle();
    expect(foundDishes(tester), ['e:drinks:B3:MAITAI']);
    // the Chinese name on the button, and a number typed whole
    await tester.enterText(find.byType(TextField), '芥兰');
    await tester.pumpAndSettle();
    expect(foundDishes(tester), ['e:dinner:88:BB']);
    await tester.enterText(find.byType(TextField), 's4');
    await tester.pumpAndSettle();
    expect(foundDishes(tester), ['e:dinner:S4:DRAGON']);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the search finds a dish by what the kitchen calls it, after the dishes named so', (tester) async {
    Map<String, dynamic> served() {
      final served = menus();
      Iterable<Map<String, dynamic>> entries() sync* {
        for (final menu in served['menus'] as List) {
          for (final section in menu['sections'] as List) {
            yield* (section['entries'] as List).cast<Map<String, dynamic>>();
          }
        }
      }

      // as the hub sends the original POS's labels: the Chinese name, the abbreviation, r for "with rice"
      entries().firstWhere((e) => e['item'] == 'GTC')['kitchen_name'] = '左宗棠鸡 GEN TSO CHKN r';
      entries().firstWhere((e) => e['item'] == 'WINGS')['kitchen_name'] = '鸡翅 CHKN WING r';
      entries().firstWhere((e) => e['item'] == 'PFR')['kitchen_name'] = '叉烧炒饭 PORK FR RICE (chicken on request)';
      return served;
    }

    await mount(tester, served);
    await tester.enterText(find.byType(TextField), 'tso chkn');
    await tester.pumpAndSettle();
    expect(foundDishes(tester), ['e:dinner:87:GTC', 'e:dinner:3:WINGS']);
    await tester.enterText(find.byType(TextField), 'chicken');
    await tester.pumpAndSettle();
    expect(foundDishes(tester), ['e:dinner:3:WINGS', 'e:dinner:87:GTC', 'e:dinner:40:PFR']);
    // the kitchen's mark for "with rice" is no word: r finds the names with an r, the rolls first, not the wings
    await tester.enterText(find.byType(TextField), 'r');
    await tester.pumpAndSettle();
    expect(foundDishes(tester).first, 'e:dinner:1:EGGROLL');
    expect(foundDishes(tester), isNot(contains('e:dinner:3:WINGS')));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a menu that closes gives way to the first: lunch is over, Food shows', (tester) async {
    var lunch = true;
    await mount(tester, () => menus(lunch: lunch));
    // at lunch the hub lists Lunch first (its priority), so the screen opens on the specials: the Lunch menu's
    // one category, shown as its dishes with no tile
    expect(tab('Lunch'), findsOneWidget);
    expect(find.byKey(const ValueKey('e:lunch:L1:EGGROLL')), findsOneWidget);
    expect(find.text('Appetizers'), findsNothing);
    await tester.tap(tab('Food'));
    await tester.pumpAndSettle();
    expect(find.text('Appetizers'), findsOneWidget);
    await tester.tap(tab('Lunch'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('e:lunch:L1:EGGROLL')), findsOneWidget);

    lunch = false; // the hub's revision moves as the hour closes the menu; the panel asks every 5 seconds
    await tester.pump(MenuPanelCheck.every);
    await tester.pumpAndSettle();
    expect(tab('Lunch'), findsNothing);
    expect(tab('Food'), findsOneWidget);
    expect(find.text('Appetizers'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a menu with one category skips the tile: its dishes show where the tiles would, the search stays', (
    tester,
  ) async {
    final chosen = <ChosenLine>[];
    await mount(tester, () => menus(lunch: true), chosen: chosen);
    // Lunch Specials is the Lunch menu's only category: no tile, no tray, the specials in the top grid
    expect(find.text('Lunch Specials'), findsNothing);
    expect(find.byKey(const ValueKey('items-lunch/specials')), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('categories-0')),
        matching: find.byKey(const ValueKey('e:lunch:L1:EGGROLL')),
      ),
      findsOneWidget,
    );
    expect(
      tester.widget<Opacity>(find.ancestor(of: find.byType(TextField), matching: find.byType(Opacity)).first).opacity,
      1,
    );
    // a tap adds the dish as from any grid
    await tester.tap(find.text('Egg roll'));
    await tester.pumpAndSettle();
    expect(chosen.map((c) => c.name), ['Egg roll']);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a single category with sub-categories tiles those instead, and they open their dishes below', (
    tester,
  ) async {
    await mount(tester, () => menus(wine: true));
    await tester.tap(tab('Wine'));
    await tester.pumpAndSettle();
    expect(find.text('Wine list'), findsNothing);
    expect(find.text('Bar shelf'), findsOneWidget);
    expect(find.text('Soft drinks'), findsOneWidget);
    expect(find.text('Tsingtao'), findsNothing);
    await tester.tap(find.text('Bar shelf'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('items-wine/bar')), findsOneWidget);
    expect(find.text('Tsingtao'), findsOneWidget);
    expect(find.text('Bar shelf'), findsOneWidget); // the tile stays, as on any menu
    await tester.pumpWidget(const SizedBox());
  });
}
