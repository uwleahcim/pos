import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/menu.dart';
import 'package:pos_app/screens/menu_panel.dart';
import 'package:pos_app/screens/order_screen.dart';
import 'package:pos_app/screens/text_arrows.dart';
import 'package:pos_app/settings.dart';

import 'hub.dart';

/// Ordering with a keyboard (Mike, 2026-11-14): the arrows move the focus, Enter goes into what it opens,
/// Escape backs out of the level the focus is on, Delete or Backspace takes a dish off the check.

/// Where the keyboard's focus is: the grid and the key of the tile it is on ('items-dinner/chefs e:dinner:87:GTC'),
/// 'search' for the search field ('search button' for the Clear button in it), 'line L2' for a line of the check.
String focused() {
  final focus = FocusManager.instance.primaryFocus;
  final context = focus?.context;
  if (context == null) return 'none';
  String? tile;
  String? grid;
  String? search;
  context.visitAncestorElements((element) {
    final widget = element.widget;
    final key = widget.key;
    if (widget is TextField) search = widget.focusNode == focus ? 'search' : 'search button';
    if (widget is ListTile) tile ??= 'line ${widget.focusNode?.debugLabel?.split(' ').last}';
    if (key is ValueKey<String> && tile == null && RegExp(r'^(s|e|req-variant|req-option):').hasMatch(key.value)) {
      tile = key.value;
    }
    if (widget is GridView && key is ValueKey<String>) grid = key.value;
    if (key == const ValueKey('required-selections')) grid = 'tray';
    return grid == null;
  });
  if (search != null) return search!;
  return [?grid, tile ?? 'other'].join(' ');
}

Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pumpAndSettle();
}

/// A dish that asks its size and then a sauce, and one that wants two picks of one question.
final saucy = {
  'item': 'GTC',
  'name': "General Tso's Chicken",
  'variants': [
    {'variant_id': 'GTC:pint', 'name': 'Pint', 'price': '15.95', 'status': 'available'},
    {'variant_id': 'GTC:quart', 'name': 'Quart', 'price': '25.95', 'status': 'available'},
  ],
  'groups': [
    {
      'group_id': 'sauce',
      'name': 'Sauce',
      'min_select': 1,
      'max_select': 1,
      'options': [
        {'option_id': 'sauce:sold', 'name': 'House', 'price': '0.00', 'status': 'unavailable'},
        {'option_id': 'sauce:sweet', 'name': 'Sweet', 'price': '0.00', 'status': 'available'},
        {'option_id': 'sauce:hot', 'name': 'Hot', 'price': '0.00', 'status': 'available'},
      ],
    },
  ],
};

final twoSides = {
  'item': 'C5',
  'name': 'Combination Plate',
  'variants': [
    {'variant_id': 'C5:regular', 'name': 'Regular', 'price': '14.50', 'status': 'available'},
  ],
  'groups': [
    {
      'group_id': 'side',
      'name': 'Two sides',
      'min_select': 2,
      'max_select': 2,
      'options': [
        {'option_id': 'side:pfr', 'name': 'Pork fried rice', 'price': '0.00', 'status': 'available'},
        {'option_id': 'side:lomein', 'name': 'Lo mein', 'price': '0.00', 'status': 'available'},
        {'option_id': 'side:soup', 'name': 'Soup', 'price': '0.00', 'status': 'available'},
      ],
    },
  ],
};

/// A dish whose choices all have defaults: a tap or Enter adds it as it comes.
Map<String, dynamic> get plain => {
  ...fixture('item_gtc'),
  'item': 'BB',
  'name': 'Beef with Broccoli',
  'variants': [
    {'variant_id': 'BB:regular', 'name': 'Regular', 'price': '14.95', 'status': 'available'},
  ],
};

/// The menu alone, as the order screen shows it on a Mac, with [menu] or the sample menu.
Future<({List<ChosenLine> chosen, List<MenuEntry> removed})> pumpMenu(
  WidgetTester tester, {
  Map<String, dynamic>? menu,
  Map<String, Map<String, dynamic>> items = const {},
  Size size = const Size(1000, 800),
}) async {
  final api = PosApi(
    Settings(device: 't1', endpoints: ['http://hub:8000']),
    client: MockClient((request) async {
      final path = request.url.path;
      if (path == '/menu') return http.Response.bytes(utf8.encode(jsonEncode(menu ?? fixture('menu'))), 200);
      if (path.startsWith('/menu/items/')) {
        final id = path.split('/').last;
        final item = items[id] ?? (id == 'BB' ? plain : fixture('item_${id.toLowerCase()}'));
        return http.Response.bytes(utf8.encode(jsonEncode(item)), 200);
      }
      return http.Response(jsonEncode({'revision': 0}), 200);
    }),
  );
  final chosen = <ChosenLine>[];
  final removed = <MenuEntry>[];
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      // as the app has it, around every screen
      builder: (context, child) => ArrowsLeaveTextBoxes(child: child!),
      home: Scaffold(
        body: MenuPanel(api: api, onChosen: chosen.add, onRemove: removed.add),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (chosen: chosen, removed: removed);
}

Finder tray() => find.byKey(const ValueKey('required-selections'));

String typed(WidgetTester tester) => tester.widget<TextField>(find.byType(TextField)).controller!.text;

void main() {
  testWidgets('Down leaves the search field for the first tile, and Enter on a category goes to its first dish', (
    tester,
  ) async {
    final menu = await pumpMenu(tester);
    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(focused(), 'search');

    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focused(), 'categories-0 s:dinner/apps');
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focused(), 'categories-0 s:dinner/chefs');
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(focused(), 'search', reason: 'and Up from the first row goes back to it');
    await press(tester, LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.arrowRight);

    // Enter opens the category: the focus is on the first of its dishes
    await press(tester, LogicalKeyboardKey.enter);
    expect(find.byKey(const ValueKey('items-dinner/chefs')), findsOneWidget);
    expect(focused(), 'items-dinner/chefs e:dinner:87:GTC');
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focused(), 'items-dinner/chefs e:dinner:88:BB');

    // a dish that asks nothing is added, and the focus stays on it for one more
    await press(tester, LogicalKeyboardKey.enter);
    expect(menu.chosen.single.request.variantId, 'BB:regular');
    expect(focused(), 'items-dinner/chefs e:dinner:88:BB');

    // Escape: out of the dishes, back on the category, which closes
    await press(tester, LogicalKeyboardKey.escape);
    expect(find.byKey(const ValueKey('items-dinner/chefs')), findsNothing);
    expect(focused(), 'categories-0 s:dinner/chefs');

    // Escape at the top of the menu: back in the search field
    await press(tester, LogicalKeyboardKey.escape);
    expect(focused(), 'search');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Enter on a dish with choices goes into them, and the focus is back on the dish once it is added', (
    tester,
  ) async {
    final menu = await pumpMenu(tester);
    await tester.enterText(find.byType(TextField), '87');
    await tester.pumpAndSettle();
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focused(), 'search-grid e:dinner:87:GTC');

    await press(tester, LogicalKeyboardKey.enter);
    expect(tray(), findsOneWidget);
    expect(focused(), 'tray req-variant:GTC:pint');
    expect(menu.chosen, isEmpty);
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focused(), 'tray req-variant:GTC:quart');

    await press(tester, LogicalKeyboardKey.enter);
    expect(menu.chosen.single.request.variantId, 'GTC:quart');
    expect(tray(), findsNothing);
    expect(focused(), 'search-grid e:dinner:87:GTC');

    // Escape from the choices: the tray closes, nothing is added, the focus is on the dish
    await press(tester, LogicalKeyboardKey.enter);
    expect(focused(), 'tray req-variant:GTC:pint');
    await press(tester, LogicalKeyboardKey.escape);
    expect(tray(), findsNothing);
    expect(menu.chosen.length, 1);
    expect(focused(), 'search-grid e:dinner:87:GTC');

    // Escape from what the search found: back in the search field, with what was typed
    await press(tester, LogicalKeyboardKey.escape);
    expect(focused(), 'search');
    expect(typed(tester), '87');
    // Enter in the field goes to what it found, like Down
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(focused(), 'search-grid e:dinner:87:GTC');
    await press(tester, LogicalKeyboardKey.escape);
    expect(focused(), 'search');
    // and Escape there clears it
    await press(tester, LogicalKeyboardKey.escape);
    expect(typed(tester), '');
    expect(find.byKey(const ValueKey('categories-0')), findsOneWidget);
    expect(focused(), 'search');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('in the choices the focus moves on to the next question once one is answered', (tester) async {
    final menu = await pumpMenu(tester, items: {'GTC': saucy, 'C5': twoSides});
    await tester.enterText(find.byType(TextField), '87');
    await tester.pumpAndSettle();
    await press(tester, LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.enter);
    expect(focused(), 'tray req-variant:GTC:pint');

    // the size is answered: on to the sauce, the first one that is not 86'd
    await press(tester, LogicalKeyboardKey.enter);
    expect(menu.chosen, isEmpty);
    expect(focused(), 'tray req-option:sauce:sauce:sweet');
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focused(), 'tray req-option:sauce:sauce:hot');
    await press(tester, LogicalKeyboardKey.enter);
    expect(menu.chosen.single.request.variantId, 'GTC:pint');
    expect(menu.chosen.single.request.selections['sauce'], ['sauce:hot']);
    expect(focused(), 'search-grid e:dinner:87:GTC');

    // a question that wants two picks keeps the focus where it is until it has them
    await tester.enterText(find.byType(TextField), 'C5');
    await tester.pumpAndSettle();
    await press(tester, LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.enter);
    expect(focused(), 'tray req-option:side:side:pfr');
    await press(tester, LogicalKeyboardKey.enter);
    expect(focused(), 'tray req-option:side:side:pfr');
    await press(tester, LogicalKeyboardKey.arrowRight);
    await press(tester, LogicalKeyboardKey.enter);
    expect(menu.chosen.last.request.selections['side'], ['side:pfr', 'side:lomein']);
    expect(focused(), 'search-grid e:dinner:C5:C5');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Escape backs out of the level the focus is on, and closes what is open under it', (tester) async {
    final menu = await pumpMenu(tester);
    await tester.tap(find.byType(TextField));
    await tester.pump();
    await press(tester, LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.arrowRight);
    await press(tester, LogicalKeyboardKey.enter); // Chef's Specials
    await press(tester, LogicalKeyboardKey.enter); // General Tso's: its sizes open
    expect(focused(), 'tray req-variant:GTC:pint');

    // back up among the dishes with the choices still open
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(focused(), 'items-dinner/chefs e:dinner:87:GTC');
    expect(tray(), findsOneWidget);

    // the focus is on the dishes: Escape goes back to the category, and the dishes and the choices close
    await press(tester, LogicalKeyboardKey.escape);
    expect(tray(), findsNothing);
    expect(find.byKey(const ValueKey('items-dinner/chefs')), findsNothing);
    expect(focused(), 'categories-0 s:dinner/chefs');
    expect(menu.chosen, isEmpty);

    // with a category open and the focus on the categories: Escape closes it and goes to the search field
    await press(tester, LogicalKeyboardKey.enter);
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(focused(), 'categories-0 s:dinner/apps');
    await press(tester, LogicalKeyboardKey.escape);
    expect(find.byKey(const ValueKey('items-dinner/chefs')), findsNothing);
    expect(focused(), 'search');

    // nothing left to back out of: Escape is not the menu's
    await press(tester, LogicalKeyboardKey.escape);
    expect(focused(), 'search');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a category inside a category: Enter goes in, Escape comes back out one level at a time', (tester) async {
    final menu = fixture('menu');
    final sections = (menu['menus'] as List)[0]['sections'] as List;
    final bar = sections.firstWhere((s) => s['section_id'] == 'dinner/bar') as Map<String, dynamic>;
    final entries = bar['entries'] as List;
    bar['sections'] = [
      {'section_id': 'dinner/bar/beer', 'name': 'Beer', 'entries': entries.sublist(0, 2)},
      {'section_id': 'dinner/bar/wine', 'name': 'Wine', 'entries': entries.sublist(2, 3)},
    ];
    bar['entries'] = entries.sublist(3);
    await pumpMenu(tester, menu: menu);
    await tester.tap(find.byType(TextField));
    await tester.pump();
    await press(tester, LogicalKeyboardKey.arrowDown);
    for (var i = 0; i < 4; i++) {
      await press(tester, LogicalKeyboardKey.arrowRight);
    }
    expect(focused(), 'categories-0 s:dinner/bar');

    await press(tester, LogicalKeyboardKey.enter);
    expect(focused(), 'items-dinner/bar s:dinner/bar/beer');
    await press(tester, LogicalKeyboardKey.arrowRight);
    await press(tester, LogicalKeyboardKey.enter);
    expect(focused(), 'items-dinner/bar/wine e:dinner:B3:MAITAI');

    // out of the wines: on Wine, among what Bar holds
    await press(tester, LogicalKeyboardKey.escape);
    expect(focused(), 'items-dinner/bar s:dinner/bar/wine');
    // in again, then up to Bar's categories on top: Escape there leaves Bar altogether
    await press(tester, LogicalKeyboardKey.enter);
    expect(focused(), 'items-dinner/bar/wine e:dinner:B3:MAITAI');
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(focused(), 'categories-1 s:dinner/bar/beer');
    await press(tester, LogicalKeyboardKey.escape);
    expect(find.byKey(const ValueKey('categories-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('items-dinner/bar')), findsNothing);
    expect(focused(), 'categories-0 s:dinner/bar');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a menu too long for the screen: the focus reaches tiles that scrolled away, and they scroll into view', (
    tester,
  ) async {
    Map<String, dynamic> dish(String id) => {
      'entry_id': 'e$id',
      'item': 'I$id',
      'name': 'Dish $id',
      'number': id,
      'variants': [
        {'variant_id': 'I$id:r', 'name': 'Regular', 'price': '1.00', 'status': 'available'},
      ],
      'has_options': false,
      'needs_choice': false,
    };
    final long = {
      'menus': [
        {
          'menu': 'food',
          'name': 'Food',
          'sections': [
            for (var c = 0; c < 30; c++)
              {
                'section_id': 'c$c',
                'name': 'Category $c',
                'entries': [for (var d = 0; d < 40; d++) dish('$c-$d')],
                'sections': <Object>[],
              },
          ],
        },
      ],
    };
    // the focused tile, wholly inside the grid that scrolls it
    bool shown() {
      final node = FocusManager.instance.primaryFocus!;
      final box = Scrollable.of(node.context!).context.findRenderObject()! as RenderBox;
      final view = box.localToGlobal(Offset.zero) & box.size;
      return node.rect.top >= view.top - 0.5 && node.rect.bottom <= view.bottom + 0.5;
    }

    await pumpMenu(tester, menu: long, size: const Size(700, 500));
    await tester.tap(find.byType(TextField));
    await tester.pump();
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focused(), 'categories-0 s:c0');

    // down the categories until the first row is gone
    for (var i = 0; i < 6; i++) {
      await press(tester, LogicalKeyboardKey.arrowDown);
    }
    final far = focused();
    expect(far, isNot('categories-0 s:c0'));
    expect(find.byKey(const ValueKey('s:c0')), findsNothing, reason: 'the first row is no longer built');
    expect(shown(), isTrue);

    // Enter: the first dish; a long way down its dishes; Escape: the category again, back in view
    await press(tester, LogicalKeyboardKey.enter);
    expect(focused(), startsWith('items-'));
    for (var i = 0; i < 9; i++) {
      await press(tester, LogicalKeyboardKey.arrowDown);
    }
    expect(shown(), isTrue);
    await press(tester, LogicalKeyboardKey.escape);
    expect(focused(), far);
    expect(shown(), isTrue);

    // back to the search field, and Down from it finds the first category although it had scrolled away
    await press(tester, LogicalKeyboardKey.escape);
    expect(focused(), 'search');
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focused(), 'categories-0 s:c0');
    expect(shown(), isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Enter and Down in the search field land on the best match, and the arrows go on from it', (
    tester,
  ) async {
    await pumpMenu(tester);
    await tester.enterText(find.byType(TextField), 'roll dragon'); // the words the other way round
    await tester.pumpAndSettle();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(focused(), 'search-grid e:dinner:S4:DRAGON');
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focused(), 'search-grid e:dinner:1:EGGROLL', reason: 'the other rolls follow, as the menu has them');
    await press(tester, LogicalKeyboardKey.escape);
    expect(focused(), 'search');
    expect(typed(tester), 'roll dragon');
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focused(), 'search-grid e:dinner:S4:DRAGON');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('an arrow leaves the search field only once it can move the cursor no further', (tester) async {
    await pumpMenu(tester);
    int cursor() => tester.widget<TextField>(find.byType(TextField)).controller!.selection.extentOffset;
    await tester.enterText(find.byType(TextField), '87');
    await tester.pumpAndSettle();
    expect((focused(), cursor()), ('search', 2));

    // at the end of what was typed, Down has nowhere to take the cursor: the first dish found
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focused(), 'search-grid e:dinner:87:GTC');
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(focused(), 'search');

    // with the cursor before the end, the arrows are the text's: Left steps back, Down runs to the end
    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect((focused(), cursor()), ('search', 1));
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect((focused(), cursor()), ('search', 2), reason: 'the first Down only reaches the end');
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focused(), 'search-grid e:dinner:87:GTC', reason: 'the second leaves');
    await press(tester, LogicalKeyboardKey.arrowUp);

    // Up runs to the start first; there is nothing above the field here, so the focus stays in it
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect((focused(), cursor()), ('search', 0));
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect((focused(), cursor()), ('search', 0));
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect((focused(), cursor()), ('search', 2), reason: 'from the start, Down is still the cursor’s');

    // a held Down stops at the end of the text: only a fresh press leaves
    await press(tester, LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect((focused(), cursor()), ('search', 2));

    // Right at the end leaves too, to what is beside the field: its Clear button
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focused(), 'search button');
    expect(Focus.of(tester.element(find.byIcon(Icons.close))).hasPrimaryFocus, isTrue);
    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(focused(), 'search', reason: 'and Left from it is the field again');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Backspace edits the search field, and takes a dish off only with the focus on the dish', (tester) async {
    final menu = await pumpMenu(tester);
    await tester.enterText(find.byType(TextField), 'egg');
    await tester.pumpAndSettle();
    await press(tester, LogicalKeyboardKey.backspace);
    expect(typed(tester), 'eg');
    expect(menu.removed, isEmpty);

    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focused(), 'search-grid e:dinner:1:EGGROLL');
    await press(tester, LogicalKeyboardKey.backspace);
    expect(menu.removed.single.item, 'EGGROLL');
    expect(typed(tester), 'eg', reason: 'what was typed is left alone');
    await press(tester, LogicalKeyboardKey.delete);
    expect(menu.removed.length, 2);

    // a key held down takes one off, not one after another
    await tester.sendKeyDownEvent(LogicalKeyboardKey.backspace);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.backspace);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.backspace);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.backspace);
    expect(menu.removed.length, 3);

    // on a category there is no dish to take off
    await press(tester, LogicalKeyboardKey.escape);
    await press(tester, LogicalKeyboardKey.escape);
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focused(), 'categories-0 s:dinner/apps');
    await press(tester, LogicalKeyboardKey.backspace);
    expect(menu.removed.length, 3);
    await tester.pumpWidget(const SizedBox());
  });

  group('on the order', () {
    Future<Terminal> pumpOrder(WidgetTester tester, Map<String, dynamic> lines) async {
      final t = await terminal(tester);
      t.hub.orders.add(table('o1', lines));
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => ArrowsLeaveTextBoxes(child: child!),
          home: OrderScreen(api: t.api, outbox: t.outbox, photos: t.photos, orderId: 'o1', staffName: 'Amy'),
        ),
      );
      await tester.pumpAndSettle();
      return t;
    }

    /// What the hub was sent, each operation as 'kind {data}'.
    List<String> sent(Terminal t) => [for (final op in t.hub.opsFor('o1')) '${op['kind']} ${op['data']}'];
    List<String> voids(Terminal t) => sent(t).where((op) => op.startsWith('void_line')).toList();

    testWidgets('Enter on a dish adds one, Backspace takes the last one off, and a sent one is voided only on Void', (
      tester,
    ) async {
      final t = await pumpOrder(tester, {'L1': line('Egg roll', fired: true)});
      await tester.enterText(find.byType(TextField), 'egg');
      await tester.pumpAndSettle();
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focused(), 'search-grid e:dinner:1:EGGROLL');

      await press(tester, LogicalKeyboardKey.enter);
      await press(tester, LogicalKeyboardKey.enter);
      final added = [
        for (final op in t.hub.opsFor('o1'))
          if (op['kind'] == 'add_line') (op['data'] as Map)['line_id'] as String,
      ];
      expect(added.length, 2);
      expect(find.widgetWithText(ListTile, 'Egg roll'), findsNWidgets(3));

      // the one added last goes first; neither was sent, so they simply come off
      await press(tester, LogicalKeyboardKey.backspace);
      expect(sent(t).last, 'void_line {line_id: ${added[1]}}');
      await press(tester, LogicalKeyboardKey.backspace);
      expect(sent(t).last, 'void_line {line_id: ${added[0]}}');
      expect(find.byType(AlertDialog), findsNothing);
      expect(focused(), 'search-grid e:dinner:1:EGGROLL', reason: 'the focus stays on the dish');

      // what is left is with the kitchen: the operator is asked, and Enter keeps it
      await press(tester, LogicalKeyboardKey.backspace);
      expect(find.text('Void Egg roll?'), findsOneWidget);
      await press(tester, LogicalKeyboardKey.enter);
      expect(find.byType(AlertDialog), findsNothing);
      expect(voids(t).length, 2);
      expect(focused(), 'search-grid e:dinner:1:EGGROLL');

      await press(tester, LogicalKeyboardKey.backspace);
      await press(tester, LogicalKeyboardKey.tab);
      await press(tester, LogicalKeyboardKey.enter);
      expect(sent(t).last, 'void_line {line_id: L1, reason: void}');

      // nothing of it left on the check: nothing happens
      await press(tester, LogicalKeyboardKey.backspace);
      expect(find.byType(AlertDialog), findsNothing);
      expect(voids(t).length, 3);
      await stop(tester);
    });

    testWidgets('one fewer of a line that holds several', (tester) async {
      final t = await pumpOrder(tester, {
        'L1': {...line('Egg roll'), 'qty': 3},
      });
      await tester.enterText(find.byType(TextField), 'egg');
      await tester.pumpAndSettle();
      await press(tester, LogicalKeyboardKey.arrowDown);
      await press(tester, LogicalKeyboardKey.backspace);
      expect(sent(t).last, 'set_line {line_id: L1, qty: 2}');
      await stop(tester);
    });

    testWidgets('Delete on a highlighted line of the check takes the line off and moves on to the next', (
      tester,
    ) async {
      final t = await pumpOrder(tester, {
        'L1': line('Egg roll', rank: 1),
        'L2': {...line('Spring roll', rank: 2), 'qty': 2},
        'L3': line('Pork fried rice', rank: 3),
        'L4': line('Hot tea', rank: 4, fired: true),
      });
      tester.widget<ListTile>(find.widgetWithText(ListTile, 'Spring roll')).focusNode!.requestFocus();
      await tester.pumpAndSettle();
      expect(focused(), 'line L2');

      // the whole line, both spring rolls; the focus is on the line after it
      await press(tester, LogicalKeyboardKey.delete);
      expect(sent(t).last, 'void_line {line_id: L2}');
      expect(find.widgetWithText(ListTile, 'Spring roll'), findsNothing);
      expect(focused(), 'line L3');

      await press(tester, LogicalKeyboardKey.backspace);
      expect(sent(t).last, 'void_line {line_id: L3}');
      expect(focused(), 'line L4');

      // a line the kitchen has: asked first, and kept, it keeps the focus
      await press(tester, LogicalKeyboardKey.delete);
      expect(find.text('Void Hot tea?'), findsOneWidget);
      await press(tester, LogicalKeyboardKey.escape);
      expect(sent(t).length, 2);
      expect(focused(), 'line L4');

      // voided, it takes no more keys: the focus is on the line before it
      await press(tester, LogicalKeyboardKey.delete);
      await tester.tap(find.text('Void'));
      await tester.pumpAndSettle();
      expect(sent(t).last, 'void_line {line_id: L4, reason: void}');
      expect(focused(), 'line L1');
      await stop(tester);
    });
  });
}
