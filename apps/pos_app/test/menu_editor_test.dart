import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/menu_admin.dart';
import 'package:pos_app/printers.dart';
import 'package:pos_app/screens/menu_editor.dart';
import 'package:pos_app/settings.dart';

Map<String, dynamic> row(String key, Map<String, dynamic> data) => {'key': key, ...data};

/// A small menu shaped like the backend's /admin/menu answer.
Map<String, dynamic> catalogJson({int revision = 7, String price = '24.95'}) => {
  'revision': revision,
  'errors': [],
  'warnings': [],
  'catalog': {
    'station': [
      row('wok1', {
        'code': 'wok1',
        'names': {'en': 'Wok 1'},
        'printers': ['wok1'],
        'cross_contact': [],
      }),
      row('wok2', {
        'code': 'wok2',
        'names': {'en': 'Wok 2'},
        'printers': ['wok2'],
        'cross_contact': [],
      }),
    ],
    'category': [
      row('mains', {
        'code': 'mains',
        'names': {'en': 'Mains'},
        'parent': null,
        'station': 'wok1',
        'sort': 0,
      }),
    ],
    'item': [
      row('GTC', {
        'code': 'GTC',
        'category': 'mains',
        'names': {'en': "General Tso's Chicken"},
        'station': null,
        'active': true,
        'sort': 0,
      }),
    ],
    'variant': [
      row('GTC:quart', {
        'id': 'GTC:quart',
        'item': 'GTC',
        'code': 'quart',
        'names': {'en': 'Quart'},
        'base_price': price,
        'sort': 0,
        'active': true,
      }),
    ],
    'group': [
      row('rice', {
        'code': 'rice',
        'names': {'en': 'Rice'},
        'min_select': 1,
        'max_select': 1,
        'free_count': 0,
      }),
    ],
    'option': [
      row('rice:white', {
        'id': 'rice:white',
        'group': 'rice',
        'code': 'white',
        'names': {'en': 'White rice'},
        'price': '0.00',
        'is_default': true,
        'active': true,
      }),
    ],
    'attachment': [
      row('item:GTC/rice', {'owner_kind': 'item', 'owner': 'GTC', 'group': 'rice', 'overrides': {}, 'sort': 0}),
    ],
    'menu': [
      row('dinner', {
        'code': 'dinner',
        'names': {'en': 'Dinner'},
        'channels': ['pos'],
      }),
      row('drinks', {
        'code': 'drinks',
        'names': {'en': 'Drinks'},
        'channels': ['pos'],
        'priority': -10,
      }),
    ],
    'section': [
      row('dinner/chefs', {
        'id': 'dinner/chefs',
        'menu': 'dinner',
        'names': {'en': "Chef's specials"},
        'sort': 0,
      }),
    ],
    'entry': [
      row('dinner:87', {
        'id': 'dinner:87',
        'menu': 'dinner',
        'section': 'dinner/chefs',
        'item': 'GTC',
        'number': '87',
        'variants': null,
        'price_overrides': {},
        'visible': true,
      }),
    ],
  },
};

void main() {
  test('only what changed goes back, as puts and deletes', () {
    final catalog = MenuCatalog.fromJson(catalogJson());
    expect(catalog.changes(), isEmpty);
    catalog.get('variant', 'GTC:quart')!['base_price'] = '25.95';
    (catalog.get('item', 'GTC')!['names'] as Map)['zh'] = '左宗棠鸡';
    removeVariant(catalog, 'GTC:none'); // nothing to take with it
    catalog.delete('attachment', 'item:GTC/rice');
    final changes = catalog.changes();
    expect([for (final c in changes) '${c['op']} ${c['kind']}'], ['put item', 'put variant', 'delete attachment']);
    expect(changes[1]['data']['base_price'], '25.95');
    expect(changes[2]['key'], 'item:GTC/rice');

    // a new size, then a dish that goes with everything it had
    catalog.put('variant', newVariant('GTC', 'pint', 'Pint', '14.95', 1));
    expect(catalog.variantsOf('GTC').map((v) => v['id']), ['GTC:quart', 'GTC:pint']);
    removeItem(catalog, 'GTC');
    expect(
      {for (final c in catalog.changes()) '${c['op']} ${c['kind']} ${c['key'] ?? ''}'.trim()},
      {'delete entry dinner:87', 'delete attachment item:GTC/rice', 'delete variant GTC:quart', 'delete item GTC'},
    );
  });

  test('a category goes on a menu with every dish in it, and comes off it with them', () {
    final catalog = MenuCatalog.fromJson(catalogJson());
    expect(catalog.menus().map((m) => m['code']), ['dinner', 'drinks']); // the order screen's tab order
    expect(catalog.categoryOn('mains', 'drinks'), isFalse);
    putCategoryOnMenu(catalog, 'mains', 'drinks');
    expect(catalog.categoryOn('mains', 'drinks'), isTrue);
    final section = catalog.get('section', 'drinks/mains')!;
    expect(section['menu'], 'drinks');
    expect(section['names'], {'en': 'Mains'});
    expect(section['parent'], isNull);
    final entry = catalog.get('entry', 'drinks:GTC')!;
    // the dish brings the number it has on the other menu, so both menus agree
    expect([entry['section'], entry['item'], entry['number'], entry['visible']], ['drinks/mains', 'GTC', '87', true]);
    expect([for (final c in catalog.changes()) '${c['op']} ${c['kind']}'], ['put section', 'put entry']);
    putCategoryOnMenu(catalog, 'mains', 'drinks'); // already there: nothing doubles
    expect(catalog.entriesOf('GTC').length, 2);
    takeCategoryOffMenu(catalog, 'mains', 'drinks');
    expect(catalog.changes(), isEmpty);
    expect(catalog.entriesOf('GTC').map((e) => e['id']), ['dinner:87']); // the other menu keeps the dish
  });

  /// The small menu with a Soup category under Mains: two soups, one in two sizes, and one off sale.
  MenuCatalog withSoups() {
    final catalog = MenuCatalog.fromJson(catalogJson());
    catalog.put('category', {
      'code': 'soup',
      'names': {'en': 'Soup', 'zh': '汤'},
      'parent': 'mains',
      'station': 'wok2',
      'sort': 1,
    });
    void soup(String code, String name, int sort, {bool active = true}) {
      catalog.put('item', {
        'code': code,
        'category': 'soup',
        'names': {'en': name},
        'station': null,
        'active': active,
        'sort': sort,
      });
    }

    soup('801', 'Miso Soup', 0);
    soup('803', 'Hot & Sour Soup', 1);
    soup('804', 'Egg Drop Soup', 2, active: false);
    catalog.put('variant', newVariant('801', 'regular', 'Regular', '2.50', 0));
    catalog.put('variant', newVariant('803', 'small', 'Small', '3.25', 0));
    catalog.put('variant', newVariant('803', 'large', 'Large', '6.50', 1));
    catalog.put('variant', newVariant('804', 'regular', 'Regular', '2.50', 0));
    return catalog;
  }

  test('a group that offers a category gets an option per dish on sale, named after the dish', () {
    final catalog = withSoups();
    final code = newSourcedGroup(catalog, 'soup');
    expect(code, 'soup');
    final group = catalog.get('group', 'soup')!;
    expect(group['names'], {'en': 'Soup', 'zh': '汤'});
    expect((group['source_category'], group['min_select'], group['max_select']), ('soup', 1, 1));
    // one option per dish, one per size when it has several, the dish off sale left out; each named for its dish
    expect(catalog.optionsOf('soup').map((o) => o['id']), ['soup:801', 'soup:803-small', 'soup:803-large']);
    expect(catalog.optionsOf('soup').map((o) => optionName(catalog, o)), [
      'Miso Soup',
      'Hot & Sour Soup (Small)',
      'Hot & Sour Soup (Large)',
    ]);
    expect(catalog.get('option', 'soup:801')!['linked_variant'], '801:regular');
    expect(catalog.get('option', 'soup:801')!['names'], isEmpty);

    // the editor's own option stays and keeps its name; a price set on a dish's option stays too
    catalog.put('option', {
      'id': 'soup:none',
      'group': 'soup',
      'code': 'none',
      'names': {'en': 'No soup'},
      'price': '0.00',
      'is_default': true,
      'linked_variant': null,
      'sort': 99,
      'active': true,
    });
    catalog.get('option', 'soup:801')!['price'] = '1.00';
    catalog.get('item', '804')!['active'] = true; // back on sale
    catalog.get('item', '801')!['category'] = 'mains'; // out of the category (still under Mains, but Mains is not Soup)
    expect(syncSourcedOptions(catalog, 'soup'), ['removed soup:801', 'added soup:804']);
    expect(catalog.optionsOf('soup').map((o) => optionName(catalog, o)), [
      'Hot & Sour Soup (Small)',
      'Hot & Sour Soup (Large)',
      'Egg Drop Soup',
      'No soup',
    ]);
    expect(syncSourcedOptions(catalog, 'soup'), isEmpty); // done once
    // the whole subtree: a group that offers Mains offers the soups too
    final mains = newSourcedGroup(catalog, 'mains');
    expect(catalog.optionsOf(mains).map((o) => o['id']), [
      '$mains:801', // the soup moved to Mains sorts with the chicken (both 0), then by code
      '$mains:GTC',
      '$mains:803-small',
      '$mains:803-large',
      '$mains:804',
    ]);
    expect(catalog.categoryChain('soup'), ['soup', 'mains']);
    // a group whose options are typed is left alone
    expect(syncSourcedOptions(catalog, 'rice'), isEmpty);
    expect(catalog.optionsOf('rice').map((o) => o['id']), ['rice:white']);
    // a hand-made option linked to a dish takes the dish's name until it is named itself
    final white = catalog.get('option', 'rice:white')!;
    white['linked_variant'] = '801:regular';
    white['names'] = <String, dynamic>{};
    expect(optionName(catalog, white), 'Miso Soup');
    white['names'] = {'en': 'The soup'};
    expect(optionName(catalog, white), 'The soup');
    expect(dishChoices(catalog)['803:small'], 'Hot & Sour Soup (Small) · Soup');
  });

  testWidgets('the group editor offers a category, shows its dishes read-only and links a typed option to a dish', (
    tester,
  ) async {
    final catalog = withSoups();
    var changes = 0;
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: StatefulBuilder(
              builder: (context, setState) =>
                  GroupEditor(catalog: catalog, groupKey: 'rice', onChanged: () => setState(() => changes++)),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Options come from'), findsOneWidget);
    expect(find.byKey(const ValueKey('rice:white/link')), findsOneWidget);

    // the typed option becomes the Miso Soup: it reads as the dish, and can be a word again
    await tester.tap(find.byKey(const ValueKey('rice:white/link')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('dish-search')), 'miso');
    await tester.pumpAndSettle();
    expect(find.text('Hot & Sour Soup (Small) · Soup'), findsNothing);
    await tester.tap(find.text('Miso Soup · Soup'));
    await tester.pumpAndSettle();
    expect(catalog.get('option', 'rice:white')!['linked_variant'], '801:regular');
    expect(find.byKey(const ValueKey('rice:white/dish')), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const ValueKey('rice:white/dish'))).data, 'Miso Soup');
    await tester.tap(find.byKey(const ValueKey('rice:white/unlink')));
    await tester.pumpAndSettle();
    expect(catalog.get('option', 'rice:white')!['linked_variant'], isNull);
    expect(catalog.get('option', 'rice:white')!['names'], {'en': 'Miso Soup'}); // keeps the name it showed

    // the group offers the Soup category: its dishes are the options, each read-only and not removable
    await tester.tap(find.text('Options typed here'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('The dishes of Soup').last);
    await tester.pumpAndSettle();
    expect(catalog.get('group', 'rice')!['source_category'], 'soup');
    expect(catalog.optionsOf('rice').map((o) => o['id']), [
      'rice:801',
      'rice:white',
      'rice:803-small',
      'rice:803-large',
    ]);
    expect(find.byKey(const ValueKey('rice:803-small/dish')), findsOneWidget);
    expect(find.byKey(const ValueKey('rice:803-small/unlink')), findsNothing);
    expect(find.textContaining('Every dish on sale in Soup is an option here'), findsOneWidget);
    expect(find.byTooltip('Remove this option'), findsOneWidget); // only the typed option can go
    expect(changes, greaterThan(0));
  });

  testWidgets('a group says which stations\' tickets list its picks, and a tap takes a station off or puts it back', (
    tester,
  ) async {
    Future<void> show(MenuCatalog catalog, VoidCallback onChanged) async {
      await tester.binding.setSurfaceSize(const Size(1400, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: StatefulBuilder(
                builder: (context, setState) =>
                    GroupEditor(catalog: catalog, groupKey: 'rice', onChanged: () => setState(onChanged)),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    String line() => tester.widget<Text>(find.byKey(const ValueKey('rice/tickets-line'))).data!;
    bool ticked(String station) => tester.widget<FilterChip>(find.byKey(ValueKey('rice/ticket:$station'))).selected;

    // a hub from before the change does not send the field and would refuse it: nothing is offered
    await show(MenuCatalog.fromJson(catalogJson()), () {});
    expect(find.text('On the tickets at'), findsNothing);
    await tester.pumpWidget(const SizedBox());

    final json = catalogJson();
    ((json['catalog'] as Map)['group'] as List).first['hidden_at'] = null; // nobody has said
    final catalog = MenuCatalog.fromJson(json)
      ..put('station', {
        'code': 'takeout',
        'names': {'en': 'Takeout'},
        'printers': <String>[],
        'cross_contact': <String>[],
      });
    var changes = 0;
    await show(catalog, () => changes++);
    expect(find.text('On the tickets at'), findsOneWidget);
    expect([ticked('wok1'), ticked('wok2'), ticked('takeout')], [true, true, true]);
    expect(line(), 'Every station\'s ticket lists what is picked here, under the dish.');
    expect(catalog.isChanged('group', 'rice'), isFalse);

    // the wok cooks do not read the rice: one tap each
    await tester.tap(find.byKey(const ValueKey('rice/ticket:wok2')));
    await tester.pumpAndSettle();
    expect(catalog.get('group', 'rice')!['hidden_at'], ['wok2']);
    expect([ticked('wok1'), ticked('wok2'), ticked('takeout')], [true, false, true]);
    expect(
      line(),
      'Left off the tickets at Wok 2: the dish prints there without what is picked here. '
      'The check and the other stations still show it.',
    );
    await tester.tap(find.byKey(const ValueKey('rice/ticket:wok1')));
    await tester.pumpAndSettle();
    expect(catalog.get('group', 'rice')!['hidden_at'], ['wok1', 'wok2']); // in the stations' own order
    expect(
      line(),
      'Only the tickets at Takeout list what is picked here: the dish prints at the other stations without it. '
      'The check still shows it.',
    );
    final put = catalog.changes().singleWhere((c) => c['kind'] == 'group');
    expect((put['op'], put['data']['code']), ('put', 'rice'));
    expect(put['data']['hidden_at'], ['wok1', 'wok2']);
    expect(changes, 2);

    // a pick that is a dish (the soup) has a station of its own, and the line says it still prints there
    catalog.get('option', 'rice:white')!['linked_variant'] = 'GTC:quart';
    await tester.tap(find.byKey(const ValueKey('rice/ticket:takeout')));
    await tester.pumpAndSettle();
    expect(
      line(),
      'No station\'s ticket lists what is picked here: the dish prints without it. '
      'The check still shows it. A pick that is a dish still prints at its own station.',
    );

    // back on every ticket: an empty list, which is a manager's answer and still a change to save
    for (final station in ['wok1', 'wok2', 'takeout']) {
      await tester.tap(find.byKey(ValueKey('rice/ticket:$station')));
      await tester.pumpAndSettle();
    }
    expect(catalog.get('group', 'rice')!['hidden_at'], isEmpty);
    expect(line(), 'Every station\'s ticket lists what is picked here, under the dish.');
    expect(catalog.isChanged('group', 'rice'), isTrue);
  });

  testWidgets('a dish says where it prints and whether a printer serves it; a choice can send it elsewhere too', (
    tester,
  ) async {
    final catalog = withSoups();
    final stations = StationList.fromJson({
      'stations': [
        {'code': 'wok1', 'name': 'Wok 1', 'dishes': 2, 'choices': 0, 'printer': null, 'takeout': false},
        {'code': 'wok2', 'name': 'Wok 2', 'dishes': 1, 'choices': 0, 'printer': 'p2', 'takeout': false},
      ],
      'missing': ['wok1'],
      'takeout_station': 'takeout',
    });
    var changes = 0;
    await tester.binding.setSurfaceSize(const Size(1400, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    Widget editor(Widget Function(void Function()) build) => MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: StatefulBuilder(builder: (context, setState) => build(() => setState(() => changes++))),
        ),
      ),
    );
    await tester.pumpWidget(
      editor(
        (changed) =>
            ItemEditor(catalog: catalog, itemKey: 'GTC', onChanged: changed, onDeleted: () {}, stations: stations),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Prints at'), findsOneWidget);
    // General Tso's inherits Wok 1 from Mains, which has no printer yet
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('prints-at'))).data,
      startsWith('No printer for Wok 1 yet: it prints on the first printer in the list.'),
    );
    await tester.tap(find.text("Category's station (Wok 1)"));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Wok 2').last);
    await tester.pumpAndSettle();
    expect(catalog.get('item', 'GTC')!['station'], 'wok2');
    expect(tester.widget<Text>(find.byKey(const ValueKey('prints-at'))).data, 'Prints on the Wok 2 printer.');

    // a new station from the dish itself
    await tester.tap(find.text('Wok 2').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('A new station…').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Dessert');
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    expect(catalog.get('station', 'dessert')!['names'], {'en': 'Dessert'});
    expect(catalog.get('item', 'GTC')!['station'], 'dessert');
    expect(changes, greaterThan(1));

    // the rice group: White rice also sends the dish to Wok 2
    await tester.pumpWidget(
      editor((changed) => GroupEditor(catalog: catalog, groupKey: 'rice', onChanged: changed, stations: stations)),
    );
    await tester.pumpAndSettle();
    expect(find.byTooltip('Also print the dish at another station (take out, say)'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('rice:white/routes')));
    await tester.pumpAndSettle();
    expect(find.text('"White rice" also prints the dish at'), findsOneWidget);
    expect(find.text('no printer yet'), findsOneWidget); // Wok 1
    await tester.tap(find.byKey(const ValueKey('route:wok2')));
    await tester.pumpAndSettle();
    expect(catalog.get('option', 'rice:white')!['routes_to'], 'wok2');
    expect(find.byTooltip('Also prints the dish at Wok 2'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('rice:white/routes')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('route:nowhere')));
    await tester.pumpAndSettle();
    expect(catalog.get('option', 'rice:white')!['routes_to'], isNull);
  });

  test('prices are kept as dollars and cents', () {
    expect(normalizePrice('8.5'), '8.50');
    expect(normalizePrice('12'), '12.00');
    expect(normalizePrice('012.30'), '12.30');
  });

  testWidgets('a manager changes a price and saves; the backend gets one change from the revision read', (
    tester,
  ) async {
    final sent = <Map<String, dynamic>>[];
    var revision = 7;
    var price = '24.95';
    final api = PosApi(
      Settings(device: 'mac1', endpoints: ['http://hub:8000']),
      client: MockClient((request) async {
        expect(request.headers['authorization'], 'Bearer tok');
        switch (request.url.path) {
          case '/admin/menu':
            return http.Response.bytes(
              utf8.encode(jsonEncode(catalogJson(revision: revision, price: price))),
              200,
              headers: {'content-type': 'application/json'},
            );
          case '/admin/menu/changes':
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            sent.add(body);
            if (sent.length == 2) {
              return http.Response(
                jsonEncode({
                  'detail': {
                    'error': 'menu_problems',
                    'errors': [
                      {'code': 'no_variant', 'message': 'GTC has no active variant'},
                    ],
                  },
                }),
                422,
              );
            }
            revision++;
            price = '25.95';
            return http.Response(jsonEncode({'revision': revision, 'updated': 1, 'errors': [], 'warnings': []}), 200);
        }
        return http.Response('{}', 404);
      }),
    );
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    await tester.pumpWidget(
      MaterialApp(
        home: MenuEditorScreen(api: api, settings: api.settings, token: 'tok'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Menu editor · revision 7'), findsOneWidget);
    expect(find.text('Saved'), findsOneWidget);

    await tester.tap(find.text("General Tso's Chicken"));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('GTC:quart/price')), '25.95');
    await tester.enterText(find.byKey(const ValueKey('GTC/zh')), '左宗棠鸡');
    await tester.pumpAndSettle();
    expect(find.text('Save 2'), findsOneWidget);

    await tester.tap(find.text('Save 2'));
    await tester.pumpAndSettle();
    expect(sent.single['revision'], 7);
    final changes = (sent.single['changes'] as List).cast<Map<String, dynamic>>();
    expect(changes.map((c) => c['kind']), ['item', 'variant']);
    expect(changes[0]['data']['names'], {'en': "General Tso's Chicken", 'zh': '左宗棠鸡'});
    expect(changes[1]['data']['base_price'], '25.95');
    expect(find.text('Menu editor · revision 8'), findsOneWidget); // reloaded after the save

    // switching the only size off is refused by the backend, and the reason is shown
    await tester.tap(find.text("General Tso's Chicken").first);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Switch).at(1));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save 1'));
    await tester.pumpAndSettle();
    expect(find.text('Not saved'), findsOneWidget);
    expect(find.text('GTC has no active variant'), findsOneWidget);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.text('Save 1'), findsOneWidget); // the edit is still there to fix
  });

  testWidgets('the editor opens only for a manager PIN', (tester) async {
    final api = PosApi(
      Settings(device: 'mac1', endpoints: ['http://hub:8000']),
      client: MockClient((request) async {
        if (request.url.path == '/admin/session') {
          final pin = (jsonDecode(request.body) as Map)['pin'];
          if (pin == '1111') {
            return http.Response(
              jsonEncode({
                'detail': {'error': 'not_allowed'},
              }),
              403,
            );
          }
          return http.Response(jsonEncode({'token': 'tok', 'name': 'Mike', 'role': 'manager'}), 200);
        }
        expect(request.headers['authorization'], 'Bearer tok');
        return http.Response.bytes(
          utf8.encode(jsonEncode(catalogJson())),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    await tester.pumpWidget(
      MaterialApp(
        home: MenuEditorScreen(api: api, settings: api.settings),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '1111');
    await tester.tap(find.text('Open the editor'));
    await tester.pumpAndSettle();
    expect(find.text('Only a manager can edit the menu'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, '9999');
    await tester.tap(find.text('Open the editor'));
    await tester.pumpAndSettle();
    expect(find.text('Menu editor · revision 7'), findsOneWidget);
    expect(find.text('MAINS'), findsOneWidget);

    // a category's editor: a chip per menu, filled where the category is; a tap puts it on a menu
    await tester.tap(find.text('MAINS'));
    await tester.pumpAndSettle();
    expect(find.text('On the menus'), findsOneWidget);
    final drinks = find.byKey(const ValueKey('on-menu-drinks'));
    expect(tester.widget<FilterChip>(drinks).selected, isFalse);
    await tester.tap(drinks);
    await tester.pumpAndSettle();
    expect(tester.widget<FilterChip>(drinks).selected, isTrue);
    expect(find.text('Save 2'), findsOneWidget); // the section and the dish's entry
  });
}
