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
/// own, the soft drinks on both (an entry per menu, the same dish). Lunch comes and goes with the hour.
Map<String, dynamic> menus({bool lunch = false}) {
  final sections = (fixture('menu')['menus'] as List)[0]['sections'] as List;
  Map<String, dynamic> onDrinks(Map<String, dynamic> section) {
    final id = (section['section_id'] as String).replaceFirst('dinner/', 'drinks/');
    return {
      ...section,
      'section_id': id,
      'entries': [
        for (final e in section['entries'] as List)
          {...e as Map<String, dynamic>, 'entry_id': (e['entry_id'] as String).replaceFirst('dinner:', 'drinks:')},
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
        'sections': [onDrinks(bar), onDrinks(soft)],
      },
    ],
  };
}

Future<void> mount(WidgetTester tester, Map<String, dynamic> Function() served) async {
  final api = PosApi(
    Settings(device: 't1', endpoints: ['http://hub:8000']),
    client: MockClient((request) async {
      final body = served();
      return switch (request.url.path) {
        '/menu' => http.Response.bytes(utf8.encode(jsonEncode(body)), 200),
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
        body: MenuPanel(api: api, onChosen: (_) {}),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder tab(String name) => find.descendant(of: find.byKey(const ValueKey('menu-tabs')), matching: find.text(name));

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

  testWidgets('a menu that closes gives way to the first: lunch is over, Food shows', (tester) async {
    var lunch = true;
    await mount(tester, () => menus(lunch: lunch));
    // at lunch the hub lists Lunch first (its priority), so the screen opens on the lunch specials
    expect(tab('Lunch'), findsOneWidget);
    expect(find.text('Lunch Specials'), findsOneWidget);
    expect(find.text('Appetizers'), findsNothing);
    await tester.tap(tab('Food'));
    await tester.pumpAndSettle();
    expect(find.text('Appetizers'), findsOneWidget);
    await tester.tap(tab('Lunch'));
    await tester.pumpAndSettle();
    expect(find.text('Lunch Specials'), findsOneWidget);

    lunch = false; // the hub's revision moves as the hour closes the menu; the panel asks every 5 seconds
    await tester.pump(MenuPanelCheck.every);
    await tester.pumpAndSettle();
    expect(tab('Lunch'), findsNothing);
    expect(tab('Food'), findsOneWidget);
    expect(find.text('Appetizers'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
