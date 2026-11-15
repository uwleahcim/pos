import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/local_order.dart';
import 'package:pos_app/menu.dart';
import 'package:pos_app/menu_admin.dart';
import 'package:pos_app/screens/menu_editor.dart';
import 'package:pos_app/screens/menu_panel.dart';
import 'package:pos_app/settings.dart';

import 'menu_editor_test.dart' show catalogJson;

/// What a one-tap word on a choice charges (the Toast comparison, 2026-11-15): Extra charges the option
/// again, On the side and Light charge it once, unless the menu says otherwise for the location or for a
/// group. The hub prices the line; the screen shows the same price on the choice's button and in its own
/// estimate, and a manager sets the rule in the menu editor.

Map<String, dynamic> fixture(String name) =>
    jsonDecode(File('test/fixtures/$name.json').readAsStringSync()) as Map<String, dynamic>;

const standing = {'extra': '2', 'side': '1', 'light': '1'};

/// A dish as a hub with the rule sends it: every group says what each word charges on its choices.
Map<String, dynamic> withWords(String name, {Map<String, Map<String, String>> groups = const {}}) {
  final json = fixture(name);
  for (final g in (json['groups'] as List).cast<Map<String, dynamic>>()) {
    g['words'] = groups[g['group_id']] ?? standing;
  }
  return json;
}

GroupDetail groupOf(ItemDetail item, String id) => item.groups.firstWhere((g) => g.groupId == id);
OptionDetail optionOf(GroupDetail group, String id) => group.options.firstWhere((o) => o.optionId == id);

/// The menu editor's catalog from a hub that keeps what the words charge.
MenuCatalog pricedCatalog({List<Map<String, dynamic>> words = const [], Map<String, String>? rice}) {
  final json = catalogJson();
  ((json['catalog'] as Map)['group'] as List).first['word_factors'] = rice;
  (json['catalog'] as Map)['word'] = [
    for (final w in words) {'key': w['code'], ...w},
  ];
  return MenuCatalog.fromJson(json);
}

void main() {
  test('a choice costs its price times what its word charges in its group', () {
    final item = ItemDetail.fromJson(withWords('item_gtc'));
    final addons = groupOf(item, 'addons');
    final shrimp = optionOf(addons, 'addons:shrimp'); // 4.00 on this dish
    expect(addons.words, {'extra': 2.0, 'side': 1.0, 'light': 1.0});
    expect(
      [
        for (final word in [null, 'extra', 'side', 'light', 'no']) choiceCents(addons, shrimp, word),
      ],
      [400, 800, 400, 400, 0],
    );
    expect(choiceCents(addons, shrimp, 'extra', 2), 1600); // two of it, each charged again
    expect(choicePrice(addons, shrimp, 'extra'), '8.00');
    // a free choice stays free whatever the word
    final spice = groupOf(item, 'spice');
    expect(choiceCents(spice, optionOf(spice, 'spice:mild'), 'extra'), 0);

    // a hub older than the rule says nothing, and charges the option once whatever the word
    final older = groupOf(ItemDetail.fromJson(fixture('item_gtc')), 'addons');
    expect(older.words, isEmpty);
    expect(choiceCents(older, optionOf(older, 'addons:shrimp'), 'extra'), 400);

    // the menu says otherwise for this group: Extra one and a half times, Light for less, to the nearest cent
    final own = groupOf(
      ItemDetail.fromJson(
        withWords(
          'item_gtc',
          groups: {
            'addons': {'extra': '1.5', 'side': '1', 'light': '0.75'},
          },
        ),
      ),
      'addons',
    );
    expect(choiceCents(own, optionOf(own, 'addons:shrimp'), 'extra'), 600);
    expect(choiceCents(own, optionOf(own, 'addons:shrimp'), 'light'), 300);
    expect(choiceCents(own, optionOf(own, 'addons:sauce'), 'light'), 38); // 0.375, as the hub rounds it

    // a choice that is a dish (the brown rice of a combination) is charged once whatever the word
    final combo = ItemDetail.fromJson(withWords('item_c5'));
    final rice = groupOf(combo, 'rice_slot');
    expect(choiceCents(rice, optionOf(rice, 'rice_slot:brown'), 'extra'), 100);
  });

  test("the check's rows and this screen's own price charge an Extra as the hub does", () {
    final item = ItemDetail.fromJson(withWords('item_gtc'));
    final request = LineRequest(variantId: 'GTC:pint', entryId: 'dinner:87');
    fillDefaults(item.groups, request);
    request.selections['addons'] = ['addons:shrimp', 'addons:sauce'];
    request.prefixes['addons:shrimp'] = 'extra';
    request.prefixes['addons:sauce'] = 'light';
    expect(pickedModifiers(item.groups, request).map((m) => (m.label, m.price)), [
      ('Extra Add shrimp', '8.00'),
      ('Light Extra sauce', '0.50'),
    ]);
    expect(localPrice("General Tso's Chicken", item.variants, item, request).unitPrice, '22.45'); // 13.95 + 8.50
    request.quantities['addons:shrimp'] = 2;
    expect(pickedModifiers(item.groups, request).first.price, '16.00');
    expect(localPrice("General Tso's Chicken", item.variants, item, request).unitPrice, '30.45');
  });

  testWidgets('the item sheet shows on the button what a choice costs with its word', (tester) async {
    final api = PosApi(
      Settings(device: 't1', endpoints: ['http://hub:8000']),
      client: MockClient((request) async {
        switch (request.url.path) {
          case '/menu/items/GTC':
            return http.Response.bytes(utf8.encode(jsonEncode(withWords('item_gtc'))), 200);
          case '/menu/price':
            return http.Response(jsonEncode({'name': "General Tso's Chicken (Pint)", 'unit_price': '13.95'}), 200);
        }
        return http.Response('{}', 404);
      }),
    );
    final chefs = ((fixture('menu')['menus'] as List)[0]['sections'] as List)[1] as Map<String, dynamic>;
    final entry = MenuEntry.fromJson((chefs['entries'] as List)[0] as Map<String, dynamic>);
    await tester.binding.setSurfaceSize(const Size(1000, 900));
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
    Finder chip(String label) => find.ancestor(of: find.text(label), matching: find.byType(ChoiceTile));
    String? badge(String label) => tester.widget<ChoiceTile>(chip(label)).priceLabel;
    Future<void> mark(String word, String label) async {
      await tester.tap(find.byKey(ValueKey('instruction:$word')));
      await tester.pump();
      await tester.tap(chip(label));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
    }

    expect(badge('Add shrimp'), '+4.00');
    await mark('extra', 'Add shrimp');
    expect(badge('Extra Add shrimp'), '+8.00'); // the shrimp, charged again
    await mark('side', 'Extra Add shrimp');
    expect(badge('On the side Add shrimp'), '+4.00');
    await mark('no', 'On the side Add shrimp');
    expect(badge('No Add shrimp'), isNull);
    await mark('extra', 'Mild');
    expect(badge('Extra Mild'), isNull); // a free choice stays free
  });

  test('the editor keeps what each word charges, for the location and for a group', () {
    // a hub older than the rule: nothing to set
    expect(MenuCatalog.fromJson(catalogJson()).pricesWords, isFalse);

    final catalog = pricedCatalog();
    expect(catalog.pricesWords, isTrue);
    expect([for (final word in pricedWords.keys) catalog.locationFactor(word)], [2.0, 1.0, 1.0]); // the standing rule
    expect(catalog.groupFactor('rice', 'extra'), isNull);
    expect(catalog.factorIn('rice', 'extra'), 2.0);

    catalog.setLocationFactor('light', 0.5);
    expect(catalog.changes(), [
      {
        'kind': 'word',
        'op': 'put',
        'data': {'code': 'light', 'factor': '0.5'},
      },
    ]);
    catalog.setLocationFactor('light', 1); // the standing rule again, where nobody had said: nothing to save
    expect(catalog.dirty, isFalse);

    catalog.setGroupFactor('rice', 'extra', 1);
    expect(catalog.get('group', 'rice')!['word_factors'], {'extra': '1'});
    expect((catalog.factorIn('rice', 'extra'), catalog.factorIn('rice', 'light')), (1.0, 1.0));
    expect(catalog.changes().single['kind'], 'group');
    catalog.setGroupFactor('rice', 'extra', null); // back on the location's rule
    expect(catalog.get('group', 'rice')!['word_factors'], isNull);
    expect(catalog.dirty, isFalse);

    // what was saved comes back as the hub writes numbers, and picking the same number again is no change
    final saved = pricedCatalog(
      words: [
        {'code': 'extra', 'factor': '1.500'},
      ],
      rice: {'light': '0.500'},
    );
    expect((saved.locationFactor('extra'), saved.groupFactor('rice', 'light')), (1.5, 0.5));
    saved.setLocationFactor('extra', 2);
    saved.setLocationFactor('extra', 1.5);
    saved.setGroupFactor('rice', 'light', 1);
    saved.setGroupFactor('rice', 'light', 0.5);
    expect(saved.dirty, isFalse);
    saved.setLocationFactor('extra', 2); // the standing rule, said outright where a row was saved
    expect(saved.changes().single['data'], {'code': 'extra', 'factor': '2'});
  });

  testWidgets('a group charges otherwise than the location with one tap, and goes back with another', (tester) async {
    Future<void> show(MenuCatalog catalog) async {
      await tester.binding.setSurfaceSize(const Size(1400, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: StatefulBuilder(
                builder: (context, setState) =>
                    GroupEditor(catalog: catalog, groupKey: 'rice', onChanged: () => setState(() {})),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    String line() => tester.widget<Text>(find.byKey(const ValueKey('rice/words-line'))).data!;
    bool on(String chip) => tester.widget<ChoiceChip>(find.byKey(ValueKey('rice/word:$chip'))).selected;

    // a hub from before the rule does not send the field and would refuse it: nothing is offered
    await show(MenuCatalog.fromJson(catalogJson()));
    expect(find.text('Extra, On the side, Light'), findsNothing);
    await tester.pumpWidget(const SizedBox());

    final catalog = pricedCatalog();
    await show(catalog);
    expect(find.text('Extra, On the side, Light'), findsOneWidget);
    expect(find.text('As the location (2×)'), findsOneWidget);
    expect(find.text('As the location (1×)'), findsNWidgets(2));
    expect([on('extra:location'), on('extra:2'), on('side:location'), on('light:location')], [true, false, true, true]);
    expect(
      line(),
      'On a choice picked here: Extra charges the option twice. On the side and Light charge the option once. '
      'A free option stays free, "No" always costs nothing, and a choice that is a dish is charged once whatever '
      'the word.',
    );

    await tester.tap(find.byKey(const ValueKey('rice/word:extra:1')));
    await tester.pumpAndSettle();
    expect(catalog.get('group', 'rice')!['word_factors'], {'extra': '1'});
    expect([on('extra:location'), on('extra:1')], [false, true]);
    expect(line(), startsWith('On a choice picked here: Extra, On the side and Light charge the option once. '));
    await tester.tap(find.byKey(const ValueKey('rice/word:light:0.5')));
    await tester.pumpAndSettle();
    expect(catalog.get('group', 'rice')!['word_factors'], {'extra': '1', 'light': '0.5'});
    expect(
      line(),
      startsWith(
        'On a choice picked here: Extra and On the side charge the option once. '
        "Light charges half the option's price. ",
      ),
    );

    await tester.tap(find.byKey(const ValueKey('rice/word:extra:location')));
    await tester.tap(find.byKey(const ValueKey('rice/word:light:location')));
    await tester.pumpAndSettle();
    expect(catalog.get('group', 'rice')!['word_factors'], isNull);
    expect(catalog.dirty, isFalse);
  });

  testWidgets("the location's rule is ahead of the option groups, and a change to it is saved with the menu", (
    tester,
  ) async {
    final sent = <Map<String, dynamic>>[];
    var older = false;
    final api = PosApi(
      Settings(device: 'mac1', endpoints: ['http://hub:8000']),
      client: MockClient((request) async {
        switch (request.url.path) {
          case '/admin/menu':
            final json = catalogJson();
            if (!older) {
              ((json['catalog'] as Map)['group'] as List).first['word_factors'] = {'extra': '1'};
              (json['catalog'] as Map)['word'] = <Map<String, dynamic>>[
                if (sent.isNotEmpty) {'key': 'extra', 'code': 'extra', 'factor': '1.500'},
              ];
            }
            return http.Response.bytes(utf8.encode(jsonEncode(json)), 200);
          case '/admin/menu/changes':
            sent.add(jsonDecode(request.body) as Map<String, dynamic>);
            return http.Response(jsonEncode({'revision': 8, 'updated': 1, 'errors': [], 'warnings': []}), 200);
        }
        return http.Response('{}', 404);
      }),
    );
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: MenuEditorScreen(api: api, settings: api.settings, token: 'tok'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Option groups'));
    await tester.pumpAndSettle();
    final tile = find.byKey(const ValueKey('words-tile'));
    expect(tile, findsOneWidget);
    expect(
      find.descendant(
        of: tile,
        matching: find.text('Extra charges the option twice. On the side and Light charge the option once.'),
      ),
      findsOneWidget,
    );

    await tester.tap(tile);
    await tester.pumpAndSettle();
    String line() => tester.widget<Text>(find.byKey(const ValueKey('words/line'))).data!;
    expect(line(), 'Extra charges the option twice. On the side and Light charge the option once.');
    expect(find.text('As the location (2×)'), findsNothing); // the location has no one to follow
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('words/apart'))).data,
      'Charging otherwise, set on the group: Rice.',
    );
    await tester.tap(find.byKey(const ValueKey('words/word:extra:1.5')));
    await tester.pumpAndSettle();
    expect(line(), 'Extra charges the option one and a half times. On the side and Light charge the option once.');
    expect(find.text('Save 1'), findsOneWidget);

    await tester.tap(find.text('Save 1'));
    await tester.pumpAndSettle();
    expect(sent.single['changes'], [
      {
        'kind': 'word',
        'op': 'put',
        'data': {'code': 'extra', 'factor': '1.5'},
      },
    ]);
    // reloaded after the save: the rule is still the one in view, with what was saved
    expect(line(), 'Extra charges the option one and a half times. On the side and Light charge the option once.');
    expect(find.text('Saved'), findsOneWidget);

    // a hub older than the rule: no such tile among the option groups
    older = true;
    await tester.tap(find.byTooltip('Reload'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('words-tile')), findsNothing);
    expect(find.text('Rice'), findsWidgets);
  });
}
