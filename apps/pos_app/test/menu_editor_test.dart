import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/menu_admin.dart';
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
