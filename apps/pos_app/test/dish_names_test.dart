import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/dish_names.dart';
import 'package:pos_app/menu.dart';
import 'package:pos_app/menu_admin.dart';
import 'package:pos_app/screens/display_dialog.dart';
import 'package:pos_app/screens/menu_editor.dart';
import 'package:pos_app/screens/menu_panel.dart';
import 'package:pos_app/screens/order_screen.dart';
import 'package:pos_app/session.dart';

import 'hub.dart';
import 'menu_editor_test.dart' show catalogJson;

/// Dish names in the language a person reads (docs/dish-names.md). The menu holds a dish in English and,
/// for most of the kitchen's dishes, in Chinese. Each person picks which one is the big one on the menu and
/// the one on the check; the other stays small under it on the menu. What is recorded, what the bill prints
/// and what the kitchen reads do not change with who rang the dish in.

Map<String, dynamic> fixture(String name) =>
    jsonDecode(File('test/fixtures/$name.json').readAsStringSync()) as Map<String, dynamic>;

/// The sample menu as a hub that names its categories in both languages serves it. [bare] dishes have no
/// Chinese name, like the ones the restaurant's old POS never had.
Map<String, dynamic> menuInTwo({Set<String> bare = const {}}) {
  final menu = fixture('menu');
  const categories = {'dinner/apps': '前菜', 'dinner/chefs': '招牌菜', 'dinner/bar': '酒吧'};
  for (final section in ((menu['menus'] as List).single as Map)['sections'] as List) {
    final row = section as Map<String, dynamic>;
    row['second_name'] = categories[row['section_id']];
    for (final entry in row['entries'] as List) {
      if (bare.contains((entry as Map)['item'])) entry['second_name'] = null;
    }
  }
  return menu;
}

/// The menu on a screen whose person reads the names [chinese] or not. Dishes tapped come back in [chosen].
Future<Terminal> pumpMenu(
  WidgetTester tester, {
  required bool chinese,
  List<ChosenLine>? chosen,
  Map<String, dynamic>? menu,
  Size size = const Size(1100, 800),
}) async {
  final t = await terminal(tester);
  t.hub.menu = menu ?? menuInTwo();
  tester.view.physicalSize = size;
  await tester.pumpWidget(menuUnder(t, chinese: chinese, chosen: chosen));
  await tester.pumpAndSettle();
  return t;
}

/// As the app does it: the language stands over every screen and dialog, so a dish's sheet has it too.
Widget menuUnder(Terminal t, {required bool chinese, List<ChosenLine>? chosen}) => MaterialApp(
  builder: (context, child) => DishLanguage(chinese: chinese, child: child!),
  home: Scaffold(
    body: MenuPanel(api: t.api, onChosen: (line) => chosen?.add(line), by: 'Amy'),
  ),
);

/// The words on the tile of [item], top to bottom, without its number and price.
List<String> tileWords(WidgetTester tester, String key) => [
  for (final text in tester.widgetList<Text>(
    find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(Text)),
  ))
    if (text.data != null && text.data!.isNotEmpty && !RegExp(r'^[\d$.+× ]+$').hasMatch(text.data!)) text.data!,
];

/// What a line of the hub's order holds once the hub priced it: the dish's names in both languages.
Map<String, dynamic> priced(String item, String en, String? zh, {String? size}) => {
  'item': item,
  'name': size == null ? en : '$en ($size)',
  'names': {'en': en, 'zh': ?zh},
  'variant_names': {'en': ?size},
};

/// Table A1 on the screen of a person who reads the names [chinese] or not.
Future<Terminal> pumpOrder(WidgetTester tester, Map<String, dynamic> order, {required bool chinese}) async {
  final t = await terminal(tester);
  t.session.staff = const Staff(staffId: 's1', name: 'Amy', role: 'server', method: 'pin');
  t.hub.menu = menuInTwo();
  t.hub.orders.add(order);
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => DishLanguage(chinese: chinese, child: child!),
      home: OrderScreen(api: t.api, outbox: t.outbox, photos: t.photos, orderId: 'o1', session: t.session),
    ),
  );
  await tester.pumpAndSettle();
  return t;
}

void main() {
  group('the words', () {
    test('the name a person reads comes first, and the other one goes under it', () {
      expect(namesShown('Egg roll', '蛋卷', chineseFirst: false), ('Egg roll', '蛋卷'));
      expect(namesShown('Egg roll', '蛋卷', chineseFirst: true), ('蛋卷', 'Egg roll'));
      // a dish the menu names in one language has that name, and nothing under it, whoever reads it
      expect(namesShown('Open Food', null, chineseFirst: true), ('Open Food', null));
      expect(namesShown('Open Food', ' ', chineseFirst: true), ('Open Food', null));
      expect(namesShown('Sake', 'Sake', chineseFirst: true), ('Sake', null));
      expect(namesShown('Sake', null, chineseFirst: false), ('Sake', null));
    });

    test('what a person stored says which they read', () {
      expect(readsChinese('zh'), isTrue);
      expect(readsChinese('zh-Hans'), isTrue);
      expect(readsChinese('en'), isFalse);
      expect(readsChinese(''), isFalse);
      expect(const DisplayPrefs().locale, englishNames);
    });

    test('a line of the check has its Chinese name from what the hub keeps with it', () {
      expect(chineseLineName(priced('EGGROLL', 'Egg roll', '蛋卷')), '蛋卷');
      // a dish with sizes says its size after the Chinese name, as it does after the English one
      expect(chineseLineName(priced('GTC', "General Tso's Chicken", '左宗棠鸡', size: 'Quart')), '左宗棠鸡 (Quart)');
      expect(
        chineseLineName({
          ...priced('GTC', "General Tso's Chicken", '左宗棠鸡', size: 'Quart'),
          'variant_names': {'en': 'Quart', 'zh': '大'},
        }),
        '左宗棠鸡 (大)',
      );
      // English only on the menu, a typed name, a line the hub has not priced, an older hub's line
      expect(chineseLineName(priced('SODA', 'Soda', null)), isNull);
      expect(
        chineseLineName({
          'item': 'OPEN',
          'name': 'Lobster special',
          'names': {'en': 'Lobster special'},
        }),
        isNull,
      );
      expect(chineseLineName(null), isNull);
      expect(chineseLineName({'item': 'GTC', 'entry_id': 'dinner:87'}), isNull);
      final line = Line.fromJson('L1', {'item': 'Egg roll', 'priced': priced('EGGROLL', 'Egg roll', '蛋卷')});
      expect((line.item, line.zhName), ('Egg roll', '蛋卷'));
      expect(line.copyWith(qty: 2).zhName, '蛋卷');
    });

    test('a category reads its other name when the hub says one', () {
      final sections = Menu.fromJson((menuInTwo()['menus'] as List).single as Map<String, dynamic>).sections;
      expect({for (final s in sections) s.name: s.secondName}, containsPair("Chef's Specials", '招牌菜'));
      // a hub older than this says none: the category keeps its English name for everybody
      final older = Menu.fromJson((fixture('menu')['menus'] as List).single as Map<String, dynamic>).sections;
      expect(older.every((s) => s.secondName == null), isTrue);
    });
  });

  group('the setting', () {
    testWidgets('a person picks which name they read, and it is kept with their text size', (tester) async {
      final t = await terminal(tester);
      await tester.pumpWidget(MaterialApp(home: DisplayDialog(session: t.session)));
      ChoiceChip chip(String code) => tester.widget<ChoiceChip>(find.byKey(ValueKey('dish-names:$code')));
      expect((chip('en').selected, chip('zh').selected), (true, false));

      await tester.tap(find.text('中文'));
      await tester.pumpAndSettle();
      expect(t.session.prefs.locale, 'zh');
      expect((chip('en').selected, chip('zh').selected), (false, true));
      final (who, saved) = t.hub.prefsSaved.last;
      expect(who, 's3');
      expect(saved, containsPair('locale', 'zh'));
      // the text size they had is sent along untouched
      expect(saved, containsPair('text_scale', 1.0));

      await tester.tap(find.text('English'));
      await tester.pumpAndSettle();
      expect(t.session.prefs.locale, 'en');
      expect((chip('en').selected, chip('zh').selected), (true, false));
    });

    testWidgets('it comes back with the sign-in on any screen, and the next person starts in English', (tester) async {
      final t = await terminal(tester);
      t.session.applySignIn({
        'staff_id': 's5',
        'name': 'Wei',
        'role': 'server',
        'preferences': {'locale': 'zh', 'text_scale': 1.15},
      });
      expect(readsChinese(t.session.prefs.locale), isTrue);
      t.session.signOut();
      expect(readsChinese(t.session.prefs.locale), isFalse);
    });

    testWidgets('the choice fits a 320-wide phone with large text', (tester) async {
      final t = await terminal(tester);
      tester.view.physicalSize = const Size(320, 568);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(size: Size(320, 568), textScaler: TextScaler.linear(1.3)),
            child: DisplayDialog(session: t.session),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.byKey(const ValueKey('dish-names:zh')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('dish-names:zh')));
      await tester.pumpAndSettle();
      expect(t.session.prefs.locale, 'zh');
      expect(tester.takeException(), isNull);
    });
  });

  group('the menu', () {
    testWidgets('in English nothing changes: the English name is the big one, the Chinese small under it', (
      tester,
    ) async {
      await pumpMenu(tester, chinese: false);
      expect(find.text("Chef's Specials"), findsOneWidget);
      expect(find.text('招牌菜'), findsNothing);
      await tester.tap(find.text("Chef's Specials"));
      await tester.pumpAndSettle();
      expect(tileWords(tester, 'e:dinner:87:GTC'), ["General Tso's Chicken", '左宗棠鸡']);
    });

    testWidgets('in Chinese the categories and the dishes read in Chinese, with the English under a dish', (
      tester,
    ) async {
      await pumpMenu(tester, chinese: true, menu: menuInTwo(bare: {'BB'}));
      expect(find.text('招牌菜'), findsOneWidget);
      expect(find.text("Chef's Specials"), findsNothing);
      // a category the menu names in English only keeps its name
      expect(find.text('Sushi bar'), findsOneWidget);
      await tester.tap(find.text('招牌菜'));
      await tester.pumpAndSettle();
      expect(tileWords(tester, 'e:dinner:87:GTC'), ['左宗棠鸡', "General Tso's Chicken"]);
      // a dish with no Chinese name reads in English, once
      expect(find.text('Beef with Broccoli'), findsOneWidget);
    });

    testWidgets('the tiles change with the person at the screen, with nothing read again', (tester) async {
      final t = await pumpMenu(tester, chinese: false);
      await tester.tap(find.text("Chef's Specials"));
      await tester.pumpAndSettle();
      final asked = t.hub.requests.length;

      await tester.pumpWidget(menuUnder(t, chinese: true)); // Wei signs in where Amy was
      await tester.pump();
      expect(find.text('招牌菜'), findsOneWidget);
      expect(tileWords(tester, 'e:dinner:87:GTC'), ['左宗棠鸡', "General Tso's Chicken"]);
      expect(t.hub.requests.length, asked);

      await tester.pumpWidget(menuUnder(t, chinese: false));
      await tester.pump();
      expect(find.text("Chef's Specials"), findsOneWidget);
      expect(tileWords(tester, 'e:dinner:87:GTC'), ["General Tso's Chicken", '左宗棠鸡']);
    });

    testWidgets('a dish rung from Chinese tiles is sent under its English name', (tester) async {
      final chosen = <ChosenLine>[];
      await pumpMenu(tester, chinese: true, chosen: chosen);
      await tester.tap(find.text('前菜'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('蛋卷'));
      await tester.pumpAndSettle();
      expect((chosen.single.name, chosen.single.zhName), ('Egg roll', '蛋卷'));
    });

    testWidgets('a dish with sizes carries its size after both names', (tester) async {
      final chosen = <ChosenLine>[];
      await pumpMenu(tester, chinese: true, chosen: chosen);
      await tester.tap(find.text('酒吧'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('生啤'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Pint').first);
      await tester.pumpAndSettle();
      expect(chosen.single.name, startsWith('House draft ('));
      expect(chosen.single.zhName, startsWith('生啤 ('));
      expect(chosen.single.zhName!.substring(2), chosen.single.name.substring('House draft'.length));
    });

    testWidgets('the search finds a dish by either name, whoever reads it', (tester) async {
      await pumpMenu(tester, chinese: true);
      await tester.enterText(find.byType(TextField), 'egg');
      await tester.pumpAndSettle();
      expect(find.text('蛋卷'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '春卷');
      await tester.pumpAndSettle();
      expect(find.text('Spring roll'), findsOneWidget);
    });

    testWidgets("a dish's sheet is headed by the name the person reads", (tester) async {
      await pumpMenu(tester, chinese: true);
      await tester.tap(find.text('招牌菜'));
      await tester.pumpAndSettle();
      await tester.longPress(find.text('左宗棠鸡'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
      expect(find.byType(ItemSheet), findsOneWidget);
      expect(find.text("左宗棠鸡  General Tso's Chicken"), findsOneWidget);
    });

    testWidgets('a 320-wide phone: Chinese tiles fit', (tester) async {
      await pumpMenu(tester, chinese: true, size: const Size(320, 568));
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('招牌菜'));
      await tester.pumpAndSettle();
      expect(find.text('左宗棠鸡'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('the check', () {
    Map<String, dynamic> a1() => table('o1', {
      'L1': line('Egg roll', course: '1')..['priced'] = priced('EGGROLL', 'Egg roll', '蛋卷'),
      'L2': line("General Tso's Chicken (Quart)", course: '2')
        ..['priced'] = priced('GTC', "General Tso's Chicken", '左宗棠鸡', size: 'Quart'),
      'L3': line('Soda', course: '1')..['priced'] = priced('SODA', 'Soda', null),
    });

    testWidgets('in Chinese each dish reads by its Chinese name, and a dish without one in English', (tester) async {
      await pumpOrder(tester, a1(), chinese: true);
      expect(find.text('蛋卷'), findsOneWidget);
      expect(find.text('左宗棠鸡 (Quart)'), findsOneWidget);
      expect(find.text('Soda'), findsWidgets);
      expect(find.text('Egg roll'), findsNothing);
      await stop(tester);
    });

    testWidgets('in English the check reads as it always did', (tester) async {
      await pumpOrder(tester, a1(), chinese: false);
      expect(find.text('Egg roll'), findsOneWidget);
      expect(find.text("General Tso's Chicken (Quart)"), findsOneWidget);
      expect(find.text('蛋卷'), findsNothing);
      await stop(tester);
    });

    testWidgets('a dish rung in Chinese shows in Chinese at once and is recorded in English', (tester) async {
      final t = await pumpOrder(tester, table('o1', {}), chinese: true);
      await tester.tap(find.text('前菜'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('蛋卷').first);
      await tester.pumpAndSettle();
      // on the check under its Chinese name (the tile says it too)
      expect(find.text('蛋卷'), findsNWidgets(2));
      final added = t.hub.opsFor('o1').singleWhere((op) => op['kind'] == 'add_line');
      expect((added['data'] as Map)['item'], 'Egg roll');
      expect(jsonEncode(added), isNot(contains('蛋卷')));
      await stop(tester);
    });
  });

  group('the menu editor', () {
    test("a category's Chinese name goes onto its tile on every menu", () {
      final catalog = MenuCatalog.fromJson(catalogJson());
      putCategoryOnMenu(catalog, 'mains', 'dinner');
      putCategoryOnMenu(catalog, 'mains', 'drinks');
      renameCategorySections(catalog, 'mains', 'zh', null, '主菜');
      expect(catalog.get('section', 'dinner/mains')!['names'], {'en': 'Mains', 'zh': '主菜'});
      expect(catalog.get('section', 'drinks/mains')!['names'], {'en': 'Mains', 'zh': '主菜'});
      // another category's section is not touched
      expect(catalog.get('section', 'dinner/chefs')!['names'], {'en': "Chef's specials"});

      // taken away again, it goes from the tiles too
      renameCategorySections(catalog, 'mains', 'zh', '主菜', null);
      expect(catalog.get('section', 'dinner/mains')!['names'], {'en': 'Mains'});
    });

    test('a section that was given a name of its own keeps it', () {
      final catalog = MenuCatalog.fromJson(catalogJson());
      putCategoryOnMenu(catalog, 'mains', 'dinner');
      putCategoryOnMenu(catalog, 'mains', 'drinks');
      catalog.get('section', 'drinks/mains')!['names'] = {'en': 'Bar food'};
      renameCategorySections(catalog, 'mains', 'en', 'Mains', 'Entrees');
      expect(catalog.get('section', 'dinner/mains')!['names'], {'en': 'Entrees'});
      expect(catalog.get('section', 'drinks/mains')!['names'], {'en': 'Bar food'});
    });

    testWidgets('typing it in the category\'s box is what does it', (tester) async {
      final catalog = MenuCatalog.fromJson(catalogJson());
      putCategoryOnMenu(catalog, 'mains', 'dinner');
      var changed = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: CategoryEditor(catalog: catalog, categoryKey: 'mains', onChanged: () => changed++),
            ),
          ),
        ),
      );
      await tester.enterText(find.byKey(const ValueKey('mains/zh')), '主菜');
      expect(changed, 1);
      expect(catalog.get('category', 'mains')!['names'], {'en': 'Mains', 'zh': '主菜'});
      expect(catalog.get('section', 'dinner/mains')!['names'], {'en': 'Mains', 'zh': '主菜'});
      // both go to the hub with Save
      expect({
        for (final c in catalog.changes()) '${c['op']} ${c['kind']} ${(c['data'] as Map?)?['id'] ?? ''}'.trim(),
      }, containsAll(['put category', 'put section dinner/mains']));
    });
  });
}
