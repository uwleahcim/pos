import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/menu.dart';
import 'package:pos_app/screens/eighty_six_board.dart';
import 'package:pos_app/screens/location_settings_screen.dart';
import 'package:pos_app/screens/menu_panel.dart';

import 'hub.dart';

/// The fixture menu as a hub that keeps numbers left says it: `left` on every size, null or what [counts]
/// names, and a size whose number is at zero sold out.
Map<String, dynamic> countedMenu([Map<String, int> counts = const {}]) {
  final menu = jsonDecode(jsonEncode(fixture('menu'))) as Map<String, dynamic>;
  void walk(List<dynamic> sections) {
    for (final section in sections.cast<Map<String, dynamic>>()) {
      for (final entry in (section['entries'] as List).cast<Map<String, dynamic>>()) {
        for (final variant in (entry['variants'] as List).cast<Map<String, dynamic>>()) {
          variant['left'] = counts[variant['variant_id']];
          if (variant['left'] == 0) variant['status'] = 'sold_out';
        }
      }
      walk(section['sections'] as List? ?? const []);
    }
  }

  for (final m in menu['menus'] as List) {
    walk((m as Map<String, dynamic>)['sections'] as List);
  }
  return menu;
}

MenuEntry dish(String item, List<Map<String, dynamic>> variants) =>
    MenuEntry.fromJson({'entry_id': 'dinner:$item', 'item': item, 'name': item, 'variants': variants});

Map<String, dynamic> size(String id, {int? left, bool counts = true, bool out = false}) => {
  'variant_id': id,
  'name': id.split(':').last,
  'price': '9.95',
  'status': out ? 'sold_out' : 'available',
  if (counts) 'left': left,
};

void main() {
  test('a size says how many are left, and whether the hub keeps numbers at all', () {
    final counted = VariantOffer.fromJson(size('DUCK:whole', left: 3));
    expect((counted.left, counted.counts, counted.available), (3, true, true));
    final plain = VariantOffer.fromJson(size('DUCK:whole'));
    expect((plain.left, plain.counts), (null, true));
    final older = VariantOffer.fromJson(size('DUCK:whole', counts: false)); // a hub from before the numbers
    expect((older.left, older.counts), (null, false));
    expect(sizeLabel(counted), 'Size · 3 left');
    expect(sizeLabel(plain), 'Size');
  });

  test('the tile shows the dish\'s number, or the lowest of its sizes when every one on sale is counted', () {
    expect(dish('DUCK', [size('DUCK:whole', left: 3)]).left, 3);
    expect(dish('DUCK', [size('DUCK:whole')]).left, isNull);
    expect(dish('GTC', [size('GTC:pint', left: 5), size('GTC:quart', left: 2)]).left, 2);
    expect(dish('GTC', [size('GTC:pint', left: 5), size('GTC:quart')]).left, isNull); // the quart is not counted
    // a size that ran out is not on sale: what is left is the other size's number
    expect(dish('GTC', [size('GTC:pint', left: 0, out: true), size('GTC:quart', left: 4)]).left, 4);
    expect(dish('GTC', [size('GTC:pint', left: 0, out: true), size('GTC:quart', out: true)]).left, isNull);
    expect(dish('DUCK', [size('DUCK:whole', counts: false)]).counts, isFalse);
    expect(dish('DUCK', [size('DUCK:whole')]).counts, isTrue);
  });

  test('a row of the board says it in a few words', () {
    BoardRow row(Map<String, dynamic> more) => BoardRow.fromJson({'target_id': 'X:1', 'name': 'Duck', ...more});
    expect(row({'status': 'sold_out'}).said, 'Sold out');
    expect(row({'status': 'sold_out', 'left': 0, 'total': 12}).said, 'Sold out · all 12 sold');
    expect(row({'status': 'available', 'left': 3, 'total': 12}).said, '3 of 12 left');
    expect(row({'status': 'available', 'left': 3, 'total': 12}).soldOut, isFalse);
    expect(EightySixBoard.summary(const []), 'Nothing is sold out, and no dish has a number left');
    expect(
      EightySixBoard.summary([
        row({'status': 'sold_out'}),
        row({'status': 'available', 'left': 3, 'total': 12}),
        row({'status': 'available', 'left': 5, 'total': 6}),
      ]),
      '1 sold out · 2 with a number left',
    );
  });

  testWidgets('the tile of a counted dish says how many are left where its price was, and 86 at zero', (tester) async {
    final t = await terminal(tester);

    /// The appetizers as a screen shows them once the hub's menu says these numbers.
    Future<Finder> eggRollWith(Map<String, int> counts) async {
      t.hub.menu = countedMenu(counts);
      await tester.pumpWidget(
        MaterialApp(
          key: ValueKey(counts.toString()), // a screen reading the menu afresh
          home: Scaffold(
            body: MenuPanel(api: t.api, onChosen: (_) {}),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Appetizers'));
      await tester.pumpAndSettle();
      return find.byKey(const ValueKey('e:dinner:1:EGGROLL'));
    }

    var eggRoll = await eggRollWith({'EGGROLL:regular': 3});
    expect(find.descendant(of: eggRoll, matching: find.text('3 left')), findsOneWidget);
    expect(find.byKey(const ValueKey('entry-left:dinner:1:EGGROLL')), findsOneWidget);
    expect(find.descendant(of: eggRoll, matching: find.text('3.50')), findsNothing);
    expect(find.text('3.25'), findsOneWidget); // the spring roll next to it, which nobody counts
    expect(find.textContaining(' left'), findsOneWidget);

    // the last ones go: the hub marks it sold out, and the tile says 86 like any dish that ran out
    eggRoll = await eggRollWith({'EGGROLL:regular': 0});
    expect(find.descendant(of: eggRoll, matching: find.text('86')), findsOneWidget);
    expect(find.textContaining(' left'), findsNothing);

    // nobody counting: the price is back
    eggRoll = await eggRollWith({});
    expect(find.descendant(of: eggRoll, matching: find.text('3.50')), findsOneWidget);
  });

  testWidgets('a dish with one size counted says so on that size, not on its tile', (tester) async {
    final t = await terminal(tester);
    t.hub.menu = countedMenu({'GTC:pint': 2});
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MenuPanel(api: t.api, onChosen: (_) {}),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text("Chef's Specials"));
    await tester.pumpAndSettle();
    final tile = find.byKey(const ValueKey('e:dinner:87:GTC'));
    expect(find.descendant(of: tile, matching: find.text('13.95+')), findsOneWidget);
    await tester.tap(find.text("General Tso's Chicken"));
    await tester.pumpAndSettle();
    final pint = find.byKey(const ValueKey('req-variant:GTC:pint'));
    final quart = find.byKey(const ValueKey('req-variant:GTC:quart'));
    expect(find.descendant(of: pint, matching: find.text('Size · 2 left')), findsOneWidget);
    expect(find.descendant(of: quart, matching: find.text('Size')), findsOneWidget);
  });

  testWidgets('whoever 86s a dish can type how many are left', (tester) async {
    final t = await terminal(tester);
    t.hub.menu = countedMenu();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MenuPanel(api: t.api, onChosen: (_) {}, by: 'Amy'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text("Chef's Specials"));
    await tester.pumpAndSettle();
    await tester.longPress(find.text("General Tso's Chicken"));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip("86 General Tso's Chicken"));
    await tester.pumpAndSettle();
    expect(find.byType(EightySixDialog), findsOneWidget);
    final pint = find.byKey(const ValueKey('left:GTC:pint'));
    expect(pint, findsOneWidget);
    expect(find.byKey(const ValueKey('left:GTC:quart')), findsOneWidget); // each size has its own number

    // nothing typed is not a number
    await tester.tap(find.byKey(const ValueKey('left-set:GTC:pint')));
    await tester.pumpAndSettle();
    expect(find.text('Type how many are left, from 1 to 999.'), findsOneWidget);
    expect(t.hub.boardChanges, isEmpty);

    await tester.enterText(pint, '12');
    await tester.tap(find.byKey(const ValueKey('left-set:GTC:pint')));
    await tester.pumpAndSettle();
    expect(t.hub.boardChanges.single, {'target_id': 'GTC:pint', 'status': 'available', 'remaining': 12, 'by': 'Amy'});
    expect(find.text('Type how many are left, from 1 to 999.'), findsNothing);
    expect(find.byKey(const ValueKey('left-off:GTC:quart')), findsNothing);

    // the number comes off again, and the dish stays on sale
    await tester.tap(find.byKey(const ValueKey('left-off:GTC:pint')));
    await tester.pumpAndSettle();
    expect(t.hub.boardChanges.last, {'target_id': 'GTC:pint', 'status': 'available', 'by': 'Amy'});
    expect(tester.widget<TextField>(pint).controller!.text, '');
    expect(find.byKey(const ValueKey('left-off:GTC:pint')), findsNothing);

    // sold out by hand is still one switch
    await tester.tap(find.byKey(const ValueKey('out:GTC:quart')));
    await tester.pumpAndSettle();
    expect(t.hub.boardChanges.last, {'target_id': 'GTC:quart', 'status': 'sold_out', 'by': 'Amy'});

    final reads = t.hub.requests.where((r) => r.startsWith('GET /menu?')).length;
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(t.hub.requests.where((r) => r.startsWith('GET /menu?')).length, reads + 1); // the tiles are read again
  });

  testWidgets('the 86 sheet shows the number a dish has, and takes a new one', (tester) async {
    final t = await terminal(tester);
    final duck = dish('DUCK', [size('DUCK:whole', left: 4)]);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EightySixDialog(api: t.api, entry: duck),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final number = find.byKey(const ValueKey('left:DUCK:whole'));
    expect(tester.widget<TextField>(number).controller!.text, '4');
    expect(tester.widget<SwitchListTile>(find.byKey(const ValueKey('out:DUCK:whole'))).value, isFalse);
    expect(find.byKey(const ValueKey('left-off:DUCK:whole')), findsOneWidget);
    await tester.enterText(number, '9');
    await tester.testTextInput.receiveAction(TextInputAction.done); // Enter sets it too
    await tester.pumpAndSettle();
    expect(t.hub.boardChanges.single, {'target_id': 'DUCK:whole', 'status': 'available', 'remaining': 9});

    // marking it sold out by hand drops the number
    await tester.tap(find.byKey(const ValueKey('out:DUCK:whole')));
    await tester.pumpAndSettle();
    expect(t.hub.boardChanges.last, {'target_id': 'DUCK:whole', 'status': 'sold_out'});
    expect(tester.widget<TextField>(number).controller!.text, '');
    expect(find.byKey(const ValueKey('left-off:DUCK:whole')), findsNothing);
  });

  testWidgets('a dish that sold its last one shows as sold out with its number at zero', (tester) async {
    final t = await terminal(tester);
    final duck = dish('DUCK', [size('DUCK:whole', left: 0, out: true)]);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EightySixDialog(api: t.api, entry: duck),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(find.byKey(const ValueKey('out:DUCK:whole'))).value, isTrue);
    expect(tester.widget<TextField>(find.byKey(const ValueKey('left:DUCK:whole'))).controller!.text, '0');
    // the kitchen made six more
    await tester.enterText(find.byKey(const ValueKey('left:DUCK:whole')), '6');
    await tester.tap(find.byKey(const ValueKey('left-set:DUCK:whole')));
    await tester.pumpAndSettle();
    expect(t.hub.boardChanges.single, {'target_id': 'DUCK:whole', 'status': 'available', 'remaining': 6});
    expect(tester.widget<SwitchListTile>(find.byKey(const ValueKey('out:DUCK:whole'))).value, isFalse);
  });

  testWidgets('a hub from before the numbers offers the switch alone', (tester) async {
    final t = await terminal(tester);
    final duck = dish('DUCK', [size('DUCK:whole', counts: false)]);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EightySixDialog(api: t.api, entry: duck),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('out:DUCK:whole')), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.textContaining('With a number'), findsNothing);
  });

  testWidgets('the manager sees what is sold out and what is running low, and brings a dish back', (tester) async {
    final t = await terminal(tester);
    t.hub.board = [
      {'target_id': 'GTC:quart', 'name': "General Tso's Chicken (Quart)", 'status': 'sold_out', 'by': 'Amy'},
      {'target_id': 'WINGS:6pc', 'name': 'Chicken wings', 'status': 'sold_out', 'by': 'Ben', 'left': 0, 'total': 12},
      {'target_id': 'EGGROLL:regular', 'name': 'Egg roll', 'status': 'available', 'by': null, 'left': 3, 'total': 12},
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: LocationSettingsScreen(api: t.api, token: 'tok-admin', device: 't1'),
      ),
    );
    await tester.pumpAndSettle();
    final card = find.byKey(const ValueKey('board'));
    await tester.ensureVisible(card);
    await tester.pumpAndSettle();
    expect(find.descendant(of: card, matching: find.text('2 sold out · 1 with a number left')), findsOneWidget);

    await tester.tap(card);
    await tester.pumpAndSettle();
    String under(String target) => tester
        .widget<Text>(find.descendant(of: find.byKey(ValueKey('board:$target')), matching: find.byType(Text)).at(1))
        .data!;
    expect(under('GTC:quart'), 'Sold out · Amy');
    expect(under('WINGS:6pc'), 'Sold out · all 12 sold · Ben');
    expect(under('EGGROLL:regular'), '3 of 12 left');
    expect(find.widgetWithText(TextButton, 'Bring back'), findsNWidgets(2));

    await tester.tap(find.byKey(const ValueKey('board-back:WINGS:6pc')));
    await tester.pumpAndSettle();
    expect(t.hub.boardChanges.single, {'target_id': 'WINGS:6pc', 'status': 'available'});
    expect(find.byKey(const ValueKey('board:WINGS:6pc')), findsNothing);

    await tester.tap(find.widgetWithText(TextButton, 'No number'));
    await tester.pumpAndSettle();
    expect(t.hub.boardChanges.last, {'target_id': 'EGGROLL:regular', 'status': 'available'});

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.descendant(of: card, matching: find.text('1 sold out')), findsOneWidget);
  });

  testWidgets('an empty board says so', (tester) async {
    final t = await terminal(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: EightySixBoard(api: t.api)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Nothing is sold out, and no dish has a number left.'), findsOneWidget);
    expect(find.byType(ListTile), findsNothing);
  });
}
