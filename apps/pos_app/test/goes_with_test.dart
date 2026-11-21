import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/menu.dart';
import 'package:pos_app/menu_admin.dart';
import 'package:pos_app/screens/menu_editor.dart';
import 'package:pos_app/screens/order_screen.dart';
import 'package:pos_app/session.dart';
import 'package:pos_app/screens/tap_focus.dart';
import 'package:pos_app/screens/text_arrows.dart';

import 'hub.dart';
import 'menu_editor_test.dart' show catalogJson, row;
import 'menu_tabs_test.dart' show menus, tab;

/// The dishes that go with a dish (the Toast comparison, row 32; docs/goes-with.md): the menu says which
/// dishes go with a dish, a manager sets them on the dish in the menu editor, and once the dish is rung the
/// order screen shows them in the tray under the dishes, each as its own tile, one tap to add. Only ever a
/// suggestion: nothing goes on a check that nobody tapped.

/// Every entry of the test menu, by its dish.
Map<String, Map<String, dynamic>> entriesOf(Map<String, dynamic> menu) {
  final out = <String, Map<String, dynamic>>{};
  void walk(List<dynamic> sections) {
    for (final s in sections.cast<Map<String, dynamic>>()) {
      for (final e in (s['entries'] as List).cast<Map<String, dynamic>>()) {
        out[e['item'] as String] = e;
      }
      walk(s['sections'] as List? ?? const []);
    }
  }

  walk(((menu['menus'] as List).first as Map)['sections'] as List);
  return out;
}

/// The test menu with what goes with which dish, as the hub says it; the dishes in [soldOut] are 86'd.
Map<String, dynamic> menuWith(Map<String, List<Object?>> goesWith, {Set<String> soldOut = const {}}) {
  final menu = fixture('menu');
  final entries = entriesOf(menu);
  for (final MapEntry(key: item, value: with_) in goesWith.entries) {
    entries[item]!['goes_with'] = with_;
  }
  for (final item in soldOut) {
    for (final v in (entries[item]!['variants'] as List).cast<Map<String, dynamic>>()) {
      v['status'] = 'sold_out';
    }
  }
  return menu;
}

final _ids = {for (final e in entriesOf(fixture('menu')).values) e['item'] as String: e['entry_id'] as String};

/// A dish's tile, by the dish's code.
ValueKey<String> tileKey(String item) => ValueKey('e:${_ids[item]}:$item');

const tray = ValueKey('goes-with');
const trayTitle = ValueKey('goes-with-title');
const trayClose = ValueKey('goes-with-close');

/// A dish's tile on the menu itself (a category's dishes, or what the search found), not in the tray.
Finder onMenu(String item) => find
    .byWidgetPredicate((w) => w.key == tileKey(item), description: 'the tile of $item on the menu')
    .hitTestable()
    .first;

/// A dish's tile in the tray that says what goes with a dish.
Finder inTray(String item) => find.descendant(of: find.byKey(tray), matching: find.byKey(tileKey(item)));

/// The dishes the tray suggests, in the order shown, by what their tiles say.
List<String> suggested(WidgetTester tester) => [
  for (final item in _ids.keys)
    if (inTray(item).evaluate().isNotEmpty) (tester.getTopLeft(inTray(item)), item),
].sorted().map((e) => e.$2).toList();

extension on List<(Offset, String)> {
  List<(Offset, String)> sorted() =>
      [...this]..sort((a, b) => a.$1.dy != b.$1.dy ? a.$1.dy.compareTo(b.$1.dy) : a.$1.dx.compareTo(b.$1.dx));
}

String? titleOf(WidgetTester tester) =>
    find.byKey(trayTitle).evaluate().isEmpty ? null : tester.widget<Text>(find.byKey(trayTitle)).data;

/// The dishes rung so far, in order, by the dish's code in what the hub was sent.
List<String> rung(Terminal t) => [
  for (final op in t.hub.opsFor('o1'))
    if (op['kind'] == 'add_line') ((((op['data'] as Map)['request'] as Map)['variant_id']) as String).split(':').first,
];

Future<Terminal> pumpOrder(WidgetTester tester, Map<String, dynamic> menu, {Size? size}) async {
  final t = await terminal(tester);
  t.session.staff = const Staff(staffId: 's1', name: 'Amy', role: 'server', method: 'pin');
  if (size != null) tester.view.physicalSize = size;
  t.hub
    ..menu = menu
    ..orders.add(table('o1', {}));
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => TapTakesFocus(child: ArrowsLeaveTextBoxes(child: child!)),
      home: OrderScreen(api: t.api, outbox: t.outbox, photos: t.photos, orderId: 'o1', session: t.session),
    ),
  );
  await tester.pumpAndSettle();
  return t;
}

Future<void> open(WidgetTester tester, String section) async {
  await tester.tap(find.byKey(ValueKey('s:dinner/$section')));
  await tester.pumpAndSettle();
}

Future<void> tap(WidgetTester tester, Finder what) async {
  await tester.tap(what);
  await tester.pumpAndSettle();
}

void main() {
  test('the menu says what goes with a dish, and an older hub says nothing', () {
    final entries = entriesOf(
      menuWith({
        'EGGROLL': ['TSINGTAO', 'TEA'],
        'PUPU': ['MAITAI', 7, null, 'SODA'],
      }),
    );
    expect(MenuEntry.fromJson(entries['EGGROLL']!).goesWith, ['TSINGTAO', 'TEA']);
    // what is not a dish's code is passed over, not a reason to lose the menu
    expect(MenuEntry.fromJson(entries['PUPU']!).goesWith, ['MAITAI', 'SODA']);
    expect(MenuEntry.fromJson(entries['SPRINGROLL']!).goesWith, isEmpty);
  });

  testWidgets('a dish rung opens what goes with it under the dishes, and a tap adds one', (tester) async {
    final t = await pumpOrder(
      tester,
      menuWith({
        'EGGROLL': ['TSINGTAO', 'TEA'],
        'TSINGTAO': ['PFR'],
      }),
    );
    await open(tester, 'apps');
    expect(find.byKey(tray), findsNothing);

    await tap(tester, onMenu('EGGROLL'));
    expect(rung(t), ['EGGROLL']);
    expect(titleOf(tester), 'Goes with Egg roll');
    expect(suggested(tester), ['TSINGTAO', 'TEA']);

    // one tap adds the beer; nothing else went on the check, and the tray is still about the egg roll:
    // what was suggested suggests nothing further
    await tap(tester, inTray('TSINGTAO'));
    expect(rung(t), ['EGGROLL', 'TSINGTAO']);
    expect(titleOf(tester), 'Goes with Egg roll');
    expect(suggested(tester), ['TSINGTAO', 'TEA']);

    // another egg roll leaves the tray as it is
    await tap(tester, onMenu('EGGROLL'));
    expect(rung(t), ['EGGROLL', 'TSINGTAO', 'EGGROLL']);
    expect(suggested(tester), ['TSINGTAO', 'TEA']);

    // a dish that goes with nothing closes it
    await tap(tester, onMenu('SPRINGROLL'));
    expect(rung(t).last, 'SPRINGROLL');
    expect(find.byKey(tray), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('nothing is suggested by a dish that names none, and nothing goes on the check by itself', (
    tester,
  ) async {
    final t = await pumpOrder(tester, menuWith({}));
    await open(tester, 'apps');
    await tap(tester, onMenu('EGGROLL'));
    expect(rung(t), ['EGGROLL']);
    expect(find.byKey(tray), findsNothing);
  });

  testWidgets('a dish that is sold out is not suggested, and with none left there is no tray', (tester) async {
    final t = await pumpOrder(
      tester,
      menuWith(
        {
          'EGGROLL': ['TSINGTAO', 'TEA', 'NOSUCH'],
          'SPRINGROLL': ['TSINGTAO'],
        },
        soldOut: {'TSINGTAO'},
      ),
    );
    await open(tester, 'apps');
    await tap(tester, onMenu('EGGROLL'));
    expect(suggested(tester), ['TEA']);
    await tap(tester, onMenu('SPRINGROLL'));
    expect(find.byKey(tray), findsNothing);
    expect(rung(t), ['EGGROLL', 'SPRINGROLL']);
  });

  testWidgets('the tray closes by its button and when another category opens', (tester) async {
    await pumpOrder(
      tester,
      menuWith({
        'EGGROLL': ['TSINGTAO'],
      }),
    );
    await open(tester, 'apps');
    await tap(tester, onMenu('EGGROLL'));
    expect(find.byKey(tray), findsOneWidget);
    await tap(tester, find.byKey(trayClose));
    expect(find.byKey(tray), findsNothing);

    await tap(tester, onMenu('EGGROLL'));
    expect(find.byKey(tray), findsOneWidget);
    await open(tester, 'chefs');
    expect(find.byKey(tray), findsNothing);
  });

  testWidgets('a dish that asks its size first suggests once it is answered', (tester) async {
    final t = await pumpOrder(
      tester,
      menuWith({
        'DRAFT': ['EGGROLL'],
      }),
    );
    await open(tester, 'bar');
    await tap(tester, onMenu('DRAFT'));
    // the tray asks the size; nothing is on the check and nothing is suggested yet
    expect(rung(t), isEmpty);
    expect(find.byKey(tray), findsNothing);
    final sizes = find.byWidgetPredicate(
      (w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('req-variant:'),
    );
    expect(sizes, findsNWidgets(2));
    await tap(tester, sizes.first);
    expect(rung(t), ['DRAFT']);
    expect(titleOf(tester), 'Goes with House draft');
    expect(suggested(tester), ['EGGROLL']);
  });

  testWidgets('a suggested dish that asks its size is asked, and the suggestions come back after', (tester) async {
    final t = await pumpOrder(
      tester,
      menuWith({
        'EGGROLL': ['DRAFT', 'TEA'],
        'DRAFT': ['PFR'],
      }),
    );
    await open(tester, 'apps');
    await tap(tester, onMenu('EGGROLL'));
    await tap(tester, inTray('DRAFT'));
    expect(rung(t), ['EGGROLL']);
    expect(find.byKey(tray), findsNothing);
    final sizes = find.byWidgetPredicate(
      (w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('req-variant:'),
    );
    await tap(tester, sizes.first);
    expect(rung(t), ['EGGROLL', 'DRAFT']);
    // back to what goes with the egg roll, not what goes with the draft
    expect(titleOf(tester), 'Goes with Egg roll');
    expect(suggested(tester), ['DRAFT', 'TEA']);
  });

  testWidgets('on a phone the suggestions fit under the dishes, four at most in two rows', (tester) async {
    final t = await pumpOrder(
      tester,
      menuWith({
        'EGGROLL': ['TSINGTAO', 'TEA', 'SODA', 'PFR'],
      }),
      size: const Size(390, 800),
    );
    await open(tester, 'apps');
    await tap(tester, onMenu('EGGROLL'));
    expect(tester.takeException(), isNull);
    expect(suggested(tester), ['TSINGTAO', 'TEA', 'SODA', 'PFR']);
    // the dish that was rung is still on screen above them
    expect(onMenu('EGGROLL'), findsOneWidget);
    await tap(tester, inTray('PFR'));
    expect(rung(t), ['EGGROLL', 'PFR']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Escape in the tray goes back to the dish, and closes it', (tester) async {
    await pumpOrder(
      tester,
      menuWith({
        'EGGROLL': ['TSINGTAO', 'TEA'],
      }),
    );
    await open(tester, 'apps');
    await tap(tester, onMenu('EGGROLL'));
    await tap(tester, inTray('TEA'));
    expect(find.byKey(tray), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(tray), findsNothing);
  });

  testWidgets('a second quick tap for two of a dish cannot land on a suggestion while the tray opens', (tester) async {
    final t = await pumpOrder(
      tester,
      menuWith({
        'EGGROLL': ['TSINGTAO', 'TEA'],
      }),
    );
    await open(tester, 'apps');
    await tester.tap(onMenu('EGGROLL'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 160));
    // the tray is on its way open: its tiles are there to see, and take no tap yet
    expect(find.byKey(tray), findsOneWidget);
    expect(tester.hasRunningAnimations, isTrue);
    await tester.tap(inTray('TSINGTAO'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(rung(t), ['EGGROLL']);
    // at rest it does
    await tap(tester, inTray('TSINGTAO'));
    expect(rung(t), ['EGGROLL', 'TSINGTAO']);
  });

  testWidgets('a dish found by the search suggests too, and typing on closes the tray', (tester) async {
    final t = await pumpOrder(
      tester,
      menuWith({
        'EGGROLL': ['TSINGTAO'],
      }),
    );
    await tester.enterText(find.byType(TextField), 'egg');
    await tester.pumpAndSettle();
    await tap(tester, onMenu('EGGROLL'));
    expect(rung(t), ['EGGROLL']);
    expect(titleOf(tester), 'Goes with Egg roll');
    await tap(tester, inTray('TSINGTAO'));
    expect(rung(t), ['EGGROLL', 'TSINGTAO']);

    await tester.enterText(find.byType(TextField), 'spring');
    await tester.pumpAndSettle();
    expect(find.byKey(tray), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a suggestion that sells out while the tray is open leaves it, and the tray with the last', (
    tester,
  ) async {
    const with_ = {
      'EGGROLL': ['TSINGTAO', 'TEA'],
    };
    final t = await pumpOrder(tester, menuWith(with_));
    await open(tester, 'apps');
    await tap(tester, onMenu('EGGROLL'));
    expect(suggested(tester), ['TSINGTAO', 'TEA']);

    // the bar runs out of the beer: the menu is read again and the tray holds the tea alone
    t.hub
      ..menu = menuWith(with_, soldOut: {'TSINGTAO'})
      ..revision = 2;
    await tester.pump(const Duration(seconds: 31));
    await tester.pumpAndSettle();
    expect(suggested(tester), ['TEA']);
    expect(titleOf(tester), 'Goes with Egg roll');

    // then of the tea as well: nothing is left to suggest
    t.hub
      ..menu = menuWith(with_, soldOut: {'TSINGTAO', 'TEA'})
      ..revision = 3;
    await tester.pump(const Duration(seconds: 31));
    await tester.pumpAndSettle();
    expect(find.byKey(tray), findsNothing);
    expect(rung(t), ['EGGROLL']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('with a keyboard: Enter rings the dish, Down goes to what goes with it, Escape back to the dish', (
    tester,
  ) async {
    final t = await pumpOrder(
      tester,
      menuWith({
        'EGGROLL': ['TSINGTAO', 'TEA'],
      }),
    );

    /// The dish whose tile has the keyboard's focus, and whether that tile is in the tray.
    (String?, bool) focus() {
      String? dish;
      var offered = false;
      FocusManager.instance.primaryFocus?.context?.visitAncestorElements((element) {
        final key = element.widget.key;
        if (key is ValueKey<String> && dish == null && key.value.startsWith('e:')) dish = key.value.split(':').last;
        if (key == tray) offered = true;
        return true;
      });
      return (dish, offered);
    }

    Future<void> press(LogicalKeyboardKey key) async {
      await tester.sendKeyEvent(key);
      await tester.pumpAndSettle();
    }

    await tester.enterText(find.byType(TextField), 'egg');
    await tester.pumpAndSettle();
    await press(LogicalKeyboardKey.arrowDown);
    expect(focus(), ('EGGROLL', false));
    await press(LogicalKeyboardKey.enter);
    expect(rung(t), ['EGGROLL']);
    // the focus stays on the dish: Enter again is another egg roll, not a beer
    expect(focus(), ('EGGROLL', false));
    expect(suggested(tester), ['TSINGTAO', 'TEA']);

    await press(LogicalKeyboardKey.arrowDown);
    expect(focus(), ('TSINGTAO', true));
    await press(LogicalKeyboardKey.arrowRight);
    expect(focus(), ('TEA', true));
    await press(LogicalKeyboardKey.enter);
    expect(rung(t), ['EGGROLL', 'TEA']);
    expect(focus(), ('TEA', true));

    await press(LogicalKeyboardKey.escape);
    expect(find.byKey(tray), findsNothing);
    expect(focus(), ('EGGROLL', false));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a suggestion can come from another menu, and the other menu\'s tab closes the tray', (tester) async {
    // Food and Drinks: the beer is on Drinks alone, the tea on both
    final served = menus();
    final food = (served['menus'] as List).cast<Map<String, dynamic>>().firstWhere((m) => m['menu'] == 'dinner');
    final eggRoll = (((food['sections'] as List).first as Map)['entries'] as List).first as Map<String, dynamic>;
    eggRoll['goes_with'] = ['TSINGTAO', 'TEA'];
    final t = await pumpOrder(tester, served);
    await open(tester, 'apps');
    await tap(tester, onMenu('EGGROLL'));
    const beer = ValueKey('e:drinks:B1:TSINGTAO'); // as Drinks lists it
    const tea = ValueKey('e:dinner:D1:TEA'); // as the menu on screen lists it
    expect(find.descendant(of: find.byKey(tray), matching: find.byKey(beer)), findsOneWidget);
    expect(find.descendant(of: find.byKey(tray), matching: find.byKey(tea)), findsOneWidget);
    await tap(tester, find.byKey(beer));
    expect(rung(t), ['EGGROLL', 'TSINGTAO']);
    final sent = ((t.hub.opsFor('o1').last['data'] as Map)['request'] as Map)['entry_id'];
    expect(sent, 'drinks:B1');

    await tap(tester, tab('Drinks'));
    expect(find.byKey(tray), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pulling the tray down closes it', (tester) async {
    await pumpOrder(
      tester,
      menuWith({
        'EGGROLL': ['TSINGTAO'],
      }),
    );
    await open(tester, 'apps');
    await tap(tester, onMenu('EGGROLL'));
    await tester.drag(inTray('TSINGTAO'), const Offset(0, 120));
    await tester.pumpAndSettle();
    expect(find.byKey(tray), findsNothing);
  });

  testWidgets('a hold on a suggestion opens the dish\'s own sheet', (tester) async {
    final t = await pumpOrder(
      tester,
      menuWith({
        'EGGROLL': ['TSINGTAO'],
      }),
    );
    // the beer as the hub describes it to the dish's sheet
    t.hub.items['TSINGTAO'] = {
      'item': 'TSINGTAO',
      'name': 'Tsingtao',
      'kind': 'standard',
      'variants': [
        {'variant_id': 'TSINGTAO:bottle', 'name': 'Bottle', 'price': '6.50', 'status': 'available'},
      ],
      'groups': <Map<String, dynamic>>[],
      'tax_class': 'alcohol',
      'station': 'bar',
      'second_name': null,
    };
    await open(tester, 'apps');
    await tap(tester, onMenu('EGGROLL'));
    await tester.longPress(inTray('TSINGTAO'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(FilledButton, 'Add'), findsOneWidget);
    await tap(tester, find.widgetWithText(FilledButton, 'Add'));
    expect(rung(t), ['EGGROLL', 'TSINGTAO']);
    // still about the egg roll
    expect(titleOf(tester), 'Goes with Egg roll');
  });

  group('the menu editor', () {
    /// The editor's small catalog with five more dishes beside General Tso's: rice, tea, soup, beer (not on
    /// sale) and an egg roll.
    Map<String, dynamic> withDishes() {
      final json = catalogJson();
      final items = (json['catalog'] as Map)['item'] as List;
      for (final (n, (code, name)) in const [
        ('RICE', 'White rice'),
        ('TEA', 'Hot tea'),
        ('SOUP', 'Wonton soup'),
        ('BEER', 'Tsingtao'),
        ('EGGROLL', 'Egg roll'),
      ].indexed) {
        items.add(
          row(code, {
            'code': code,
            'category': 'mains',
            'names': {'en': name},
            'station': null,
            'active': code != 'BEER',
            'sort': n + 1,
          }),
        );
      }
      return json;
    }

    Future<MenuCatalog> pumpDish(WidgetTester tester, {List<Object?>? has}) async {
      final json = withDishes();
      final gtc = ((json['catalog'] as Map)['item'] as List).cast<Map<String, dynamic>>().firstWhere(
        (i) => i['code'] == 'GTC',
      );
      gtc['attrs'] = {'legacy_pos': true, 'goes_with': ?has};
      final catalog = MenuCatalog.fromJson(json);
      await tester.binding.setSurfaceSize(const Size(1400, 1600));
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
      return catalog;
    }

    Map<String, dynamic> attrs(MenuCatalog catalog) => (catalog.get('item', 'GTC')!['attrs'] as Map).cast();
    const add = ValueKey('GTC/goes-with/add');

    testWidgets('a manager says what a dish goes with, in order, and takes one away', (tester) async {
      final catalog = await pumpDish(tester);
      expect(goesWith(catalog, catalog.get('item', 'GTC')!), isEmpty);
      expect(catalog.dirty, isFalse);

      Future<void> pick(String name) async {
        await tester.tap(find.byKey(add));
        await tester.pumpAndSettle();
        await tester.tap(find.text('$name · Mains'));
        await tester.pumpAndSettle();
      }

      Future<void> takeAway(String code) async {
        final chip = find.byKey(ValueKey('GTC/goes-with/$code'));
        await tester.tap(find.descendant(of: chip, matching: find.byTooltip('Delete')));
        await tester.pumpAndSettle();
      }

      await tester.tap(find.byKey(add));
      await tester.pumpAndSettle();
      // every other dish can be picked, by the whole dish and not by a size; the dish itself cannot
      expect(find.text('Hot tea · Mains'), findsOneWidget);
      expect(find.text("General Tso's Chicken · Mains"), findsNothing);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(catalog.dirty, isFalse);

      await pick('Hot tea');
      await pick('White rice');
      expect(attrs(catalog), {
        'legacy_pos': true,
        'goes_with': ['TEA', 'RICE'],
      });
      final change = catalog.changes().single;
      expect((change['kind'], change['op']), ('item', 'put'));
      expect(((change['data'] as Map)['attrs'] as Map)['goes_with'], ['TEA', 'RICE']);
      expect(find.widgetWithText(InputChip, 'Hot tea'), findsOneWidget);

      // one already there is not offered twice
      await tester.tap(find.byKey(add));
      await tester.pumpAndSettle();
      expect(find.text('Hot tea · Mains'), findsNothing);
      expect(find.text('Wonton soup · Mains'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      // taken away, and with none left the dish is as it was: nothing to save
      await takeAway('TEA');
      expect(attrs(catalog)['goes_with'], ['RICE']);
      await takeAway('RICE');
      expect(attrs(catalog), {'legacy_pos': true});
      expect(catalog.dirty, isFalse);
    });

    testWidgets('four is the most, and a dish that is not on sale says so', (tester) async {
      final catalog = await pumpDish(tester, has: ['TEA', 'BEER', 'RICE']);
      expect(find.widgetWithText(InputChip, 'Tsingtao (not on sale)'), findsOneWidget);
      expect(find.byKey(add), findsOneWidget);
      await tester.tap(find.byKey(add));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Wonton soup · Mains'));
      await tester.pumpAndSettle();
      expect(attrs(catalog)['goes_with'], ['TEA', 'BEER', 'RICE', 'SOUP']);
      expect(find.byKey(add), findsNothing, reason: 'with four there is no fifth to add');
    });

    test('a dish goes with four at most, never itself, none twice, and only dishes that are there', () {
      final catalog = MenuCatalog.fromJson(withDishes());
      final item = catalog.get('item', 'GTC')!;
      item['attrs'] = {
        'goes_with': ['GTC', 'TEA', 'TEA', 'NOSUCH', 7, 'RICE'],
      };
      expect(goesWith(catalog, item), ['TEA', 'RICE']);
      item['attrs'] = {
        'goes_with': ['TEA', 'RICE', 'SOUP', 'BEER', 'EGGROLL'],
      };
      expect(goesWith(catalog, item), ['TEA', 'RICE', 'SOUP', 'BEER']);
      item['attrs'] = {'goes_with': 'TEA'};
      expect(goesWith(catalog, item), isEmpty);
      expect(goesWithMost, 4);
      expect(wholeDishes(catalog, except: {'GTC', 'TEA'}).keys, ['RICE', 'SOUP', 'BEER', 'EGGROLL']);
    });

    test('a dish that is deleted is no longer suggested by the others', () {
      final json = withDishes();
      // as the hub sends a dish: with its `attrs`, empty for most
      for (final i in ((json['catalog'] as Map)['item'] as List).cast<Map<String, dynamic>>()) {
        i['attrs'] = <String, dynamic>{};
      }
      final catalog = MenuCatalog.fromJson(json);
      final item = catalog.get('item', 'GTC')!;
      setGoesWith(item, ['TEA', 'RICE']);
      removeItem(catalog, 'TEA');
      expect((item['attrs'] as Map)['goes_with'], ['RICE']);
      removeItem(catalog, 'RICE');
      expect((item['attrs'] as Map).containsKey('goes_with'), isFalse);
      // the dish that suggested them is saved without them; nothing else about it changed
      final put = catalog.changes().where((c) => c['kind'] == 'item' && c['op'] == 'put');
      expect(put, isEmpty, reason: 'it had none before and has none now');
    });
  });
}
