import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/dishes_report.dart';
import 'package:pos_app/screens/dishes_screen.dart';
import 'package:pos_app/screens/location_settings_screen.dart';
import 'package:pos_app/screens/sales_screen.dart';

import 'hub.dart';
import 'location_rows.dart';

/// Dishes sold, best to worst (docs/dishes-sold.md): what a manager reads to see what the menu sells and
/// what it does not. The hub does every sum; these tests are about the screen saying what the hub said, in
/// the order asked for, and asking for the right days.

/// Monday 16 November 2026, on the device's own clock.
DateTime at(int hour, [int minute = 0, int day = 16]) => DateTime(2026, 11, day, hour, minute);
int ms(int hour, [int minute = 0, int day = 16]) => at(hour, minute, day).millisecondsSinceEpoch;

Map<String, dynamic> sold(String name, int count, String amount, int before, String beforeAmount, {String? group}) => {
  'name': name,
  'group': ?group,
  'count': count,
  'amount': amount,
  'before_count': before,
  'before_amount': beforeAmount,
};

Map<String, dynamic> dish(
  String? item,
  String name,
  String category,
  int count,
  String amount,
  int before,
  String beforeAmount, {
  List<Map<String, dynamic>> sizes = const [],
  List<Map<String, dynamic>> typed = const [],
  List<Map<String, dynamic>> options = const [],
  bool onMenu = true,
}) {
  final (menu, menuName, code, categoryName) = switch (category) {
    'chefs' => ('dinner', 'Dinner', 'chefs', "Chef's Specials"),
    'sides' => ('dinner', 'Dinner', 'sides', 'Appetizers'),
    'rolls' => ('dinner', 'Dinner', 'rolls', 'Rolls'),
    'beer' => ('drinks', 'Drinks', 'beer', 'Beer'),
    'cocktails' => ('drinks', 'Drinks', 'cocktails', 'Cocktails'),
    _ => ('', '', '', 'Off the menu now'),
  };
  return {
    ...sold(name, count, amount, before, beforeAmount),
    'item': item,
    'menu': menu,
    'menu_name': menuName,
    'category': code,
    'category_name': categoryName,
    'on_menu': onMenu,
    'sizes': sizes,
    'typed': typed,
    'options': options,
  };
}

Map<String, dynamic> category(
  String menu,
  String menuName,
  String code,
  String name,
  int dishes,
  int count,
  String amount,
) => {
  'menu': menu,
  'menu_name': menuName,
  'code': code,
  'name': name,
  'dishes': dishes,
  'count': count,
  'amount': amount,
  'before_count': 0,
  'before_amount': '0.00',
};

/// The week of Monday 9 November beside the week before it, most sold first as the hub lists them.
Map<String, dynamic> week() => {
  'span': {'first': '2026-11-09', 'last': '2026-11-15', 'running': false, 'count': 1204, 'amount': '14210.50'},
  'before': {'first': '2026-11-02', 'last': '2026-11-08', 'running': false, 'count': 1150, 'amount': '12700.00'},
  'dishes': [
    dish('EGGROLL', 'Egg roll', 'sides', 140, '490.00', 150, '525.00'),
    dish('TSINGTAO', 'Tsingtao', 'beer', 96, '624.00', 96, '624.00'),
    dish(
      'GTC',
      "General Tso's Chicken",
      'chefs',
      86,
      '1240.70',
      74,
      '1050.00',
      sizes: [sold('Pint', 52, '725.40', 48, '669.60'), sold('Quart', 34, '515.30', 26, '380.40')],
      options: [
        sold('Medium', 60, '0.00', 55, '0.00', group: 'Spice level'),
        sold('Extra spicy', 26, '0.00', 19, '0.00', group: 'Spice level'),
        sold('White rice', 70, '0.00', 62, '0.00', group: 'Choice of rice'),
        sold('Brown rice', 16, '16.00', 12, '12.00', group: 'Choice of rice'),
        sold('EXTRA Add shrimp', 5, '40.00', 0, '0.00', group: 'Add-ons'),
      ],
    ),
    dish('DRAGON', 'Dragon roll', 'rolls', 61, '972.95', 0, '0.00'),
    dish(
      'C5',
      'Combination Plate',
      'chefs',
      12,
      '184.00',
      9,
      '130.50',
      options: [
        sold("General Tso's Chicken", 10, '0.00', 9, '0.00', group: 'Entree'),
        sold('Beef with Broccoli', 2, '0.00', 0, '0.00', group: 'Entree'),
        sold('Extra spicy', 3, '0.00', 1, '0.00', group: "General Tso's Chicken · Spice level"),
      ],
    ),
    dish(
      'OPEN',
      'Open Food',
      'chefs',
      4,
      '68.00',
      2,
      '30.00',
      typed: [
        {'name': 'Lobster ginger scallion', 'count': 3, 'amount': '59.00'},
        {'name': 'Fried bananas', 'count': 1, 'amount': '9.00'},
      ],
    ),
    dish('MAITAI', 'Mai Tai', 'cocktails', 0, '0.00', 3, '36.00'),
    dish('SALNIG', 'Salmon nigiri', 'rolls', 0, '0.00', 0, '0.00'),
    dish(null, 'Scallion pancake', '', 0, '0.00', 12, '71.40', onMenu: false),
  ],
  'categories': [
    category('dinner', 'Dinner', 'sides', 'Appetizers', 1, 140, '490.00'),
    category('dinner', 'Dinner', 'chefs', "Chef's Specials", 3, 102, '1492.70'),
    category('dinner', 'Dinner', 'rolls', 'Rolls', 2, 61, '972.95'),
    category('drinks', 'Drinks', 'beer', 'Beer', 1, 96, '624.00'),
    category('drinks', 'Drinks', 'cocktails', 'Cocktails', 1, 0, '0.00'),
    category('', '', '', 'Off the menu now', 1, 0, '0.00'),
  ],
  'max_days': 92,
  'now_ms': ms(21),
};

/// The evening that is running, beside the Monday before.
Map<String, dynamic> today() => {
  'span': {'first': '2026-11-16', 'last': '2026-11-16', 'running': true, 'count': 3, 'amount': '15.95'},
  'before': {'first': '2026-11-09', 'last': '2026-11-09', 'running': false, 'count': 0, 'amount': '0.00'},
  'dishes': [
    dish('EGGROLL', 'Egg roll', 'sides', 2, '7.00', 0, '0.00'),
    dish('WINGS', 'Chicken wings', 'sides', 1, '8.95', 0, '0.00'),
  ],
  'categories': [category('dinner', 'Dinner', 'sides', 'Appetizers', 2, 3, '15.95')],
  'max_days': 92,
  'now_ms': ms(21),
};

class Dishes {
  Dishes(this.t);
  final Terminal t;
  final picks = <DateTimeRange>[];
  final asked = <DateTimeRange?>[];

  Future<DateTimeRange?> pickSpan(BuildContext context, DateTimeRange? from) async {
    asked.add(from);
    return picks.isEmpty ? null : picks.removeAt(0);
  }
}

const theWeek = '2026-11-09..2026-11-15';

Future<Dishes> pumpDishes(
  WidgetTester tester, {
  Map<String, Map<String, dynamic>>? dishes,
  bool older = false,
  Size size = const Size(1100, 3600),
  DateTime? now,
  void Function(Hub hub)? before,
}) async {
  final t = await terminal(tester);
  t.hub.dishes = older ? null : (dishes ?? {theWeek: week(), '': today()});
  before?.call(t.hub);
  tester.view.physicalSize = size;
  final d = Dishes(t);
  await tester.pumpWidget(const SizedBox()); // a screen from earlier in the test is gone before this one opens
  await tester.pumpWidget(
    MaterialApp(
      home: DishesScreen(api: t.api, token: 'tok-admin', now: () => now ?? at(21), pickSpan: d.pickSpan),
    ),
  );
  await tester.pumpAndSettle();
  return d;
}

Future<void> tapKey(WidgetTester tester, String key) async {
  if (find.byKey(ValueKey(key)).evaluate().isEmpty) {
    await tester.scrollUntilVisible(find.byKey(ValueKey(key)), 150, scrollable: find.byType(Scrollable).first);
  }
  await tester.ensureVisible(find.byKey(ValueKey(key)));
  await tester.pumpAndSettle(); // where it scrolled to is laid out before the tap is aimed
  await tester.tap(find.byKey(ValueKey(key)));
  await tester.pumpAndSettle();
}

/// Every text inside the row with that key, in order (a line in two colours as the one line it reads as).
List<String> row(WidgetTester tester, String key) => [
  for (final text in tester.widgetList<Text>(
    find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(Text)),
  ))
    text.data ?? text.textSpan?.toPlainText() ?? '',
];

/// The dishes listed, top to bottom, by name.
List<String> listed(WidgetTester tester) => [
  for (final element in find.byWidgetPredicate((w) => w.key is ValueKey<String> && _isRow(w.key!)).evaluate())
    row(tester, (element.widget.key! as ValueKey<String>).value)[1],
];

bool _isRow(Key key) => (key as ValueKey<String>).value.startsWith('dish-row:');

double bar(WidgetTester tester, String id) => tester
    .widget<FractionallySizedBox>(
      find.ancestor(of: find.byKey(ValueKey('dish-bar:$id')), matching: find.byType(FractionallySizedBox)).first,
    )
    .widthFactor!;

void main() {
  group('what the list reads', () {
    test('the hub\'s answer, read into names', () {
      final report = DishesReport.fromJson(week());
      expect(
        (report.span.first, report.span.last, report.span.dayCount),
        (DateTime(2026, 11, 9), DateTime(2026, 11, 15), 7),
      );
      expect((report.span.count, report.span.amount, report.before.count), (1204, '14210.50', 1150));
      expect((report.maxDays, report.nowMs, report.span.running, report.unsold), (92, ms(21), false, 2));
      final chicken = report.dishes[2];
      expect(
        (chicken.id, chicken.name, chicken.menuName, chicken.categoryName),
        ('GTC', "General Tso's Chicken", 'Dinner', "Chef's Specials"),
      );
      expect(
        (chicken.count, chicken.amount, chicken.beforeCount, chicken.beforeAmount),
        (86, '1240.70', 74, '1050.00'),
      );
      expect(chicken.sizes.map((s) => (s.name, s.count, s.beforeCount)), [('Pint', 52, 48), ('Quart', 34, 26)]);
      expect(chicken.options.map((o) => o.group).toSet(), {'Spice level', 'Choice of rice', 'Add-ons'});
      expect((chicken.hasMore, chicken.onMenu, chicken.money), (true, true, 1240.70));
      final gone = report.dishes.last;
      expect((gone.id, gone.item, gone.onMenu, gone.hasMore), ('gone:Scallion pancake', null, false, false));
      expect(report.dishes[5].typed.map((t) => (t.name, t.count, t.amount)).first, (
        'Lobster ginger scallion',
        3,
        '59.00',
      ));
      expect(report.categories.map((c) => (c.id, c.dishes)).take(2), [('dinner:sides', 1), ('dinner:chefs', 3)]);
    });

    test('an answer with nothing in it lists nothing', () {
      final report = DishesReport.fromJson({
        'span': {'first': '2026-11-16', 'last': '2026-11-16'},
      });
      expect(report.dishes, isEmpty);
      expect(report.categories, isEmpty);
      expect((report.span.count, report.span.amount), (0, '0.00'));
      expect((report.unsold, report.maxDays, report.before.count), (0, 92, 0));
    });

    test('the orders the list can stand in', () {
      final dishes = DishesReport.fromJson(week()).dishes;
      List<String> names(DishSort sort) => [for (final dish in sortedDishes(dishes, sort)) dish.name];
      expect(names(DishSort.most).take(4), ['Egg roll', 'Tsingtao', "General Tso's Chicken", 'Dragon roll']);
      expect(names(DishSort.mostMoney).take(4), ["General Tso's Chicken", 'Dragon roll', 'Tsingtao', 'Egg roll']);
      // worst first: what the menu shows and nobody ordered, by name, before a dish it no longer has
      expect(names(DishSort.least).take(4), ['Mai Tai', 'Salmon nigiri', 'Scallion pancake', 'Open Food']);
      expect(names(DishSort.leastMoney).take(5).last, 'Combination Plate');
      expect(names(DishSort.most).reversed.take(3), ['Scallion pancake', 'Salmon nigiri', 'Mai Tai']);
      // as many sold: the one that brought more first, and last when worst is first
      final same = [
        const DishSold(name: 'B', item: 'b', count: 5, amount: '10.00'),
        const DishSold(name: 'a', item: 'a', count: 5, amount: '10.00'),
        const DishSold(name: 'C', item: 'c', count: 5, amount: '40.00'),
      ];
      expect([for (final dish in sortedDishes(same, DishSort.most)) dish.name], ['C', 'a', 'B']);
      expect([for (final dish in sortedDishes(same, DishSort.least)) dish.name], ['a', 'B', 'C']);
      expect(DishSort.values.map((sort) => sort.words), ['Most sold', 'Least sold', 'Most money', 'Least money']);
    });

    test('a dish is found by the words of its name, whatever their order and case', () {
      final dishes = DishesReport.fromJson(week()).dishes;
      List<String> named(String words) => [for (final dish in dishesNamed(dishes, words)) dish.name];
      expect(named('roll'), ['Egg roll', 'Dragon roll']);
      expect(named('CHICKEN tso'), ["General Tso's Chicken"]);
      expect(named('  '), hasLength(9));
      expect(named('pizza'), isEmpty);
    });
  });

  group('the calls', () {
    testWidgets('carry the manager\'s token and the days', (tester) async {
      final t = await terminal(tester);
      final running = await t.api.dishesReport('tok-admin');
      await t.api.dishesReport('tok-admin', from: '2026-11-09', to: '2026-11-15');
      await t.api.dishesReport('tok-admin', from: '2026-11-12');
      expect(t.hub.dishesAsks, ['', theWeek, '2026-11-12..2026-11-12']);
      expect(t.hub.dishesAuth, 'Bearer tok-admin');
      expect((running.span.first, running.before.first), (DateTime(2026, 11, 16), DateTime(2026, 11, 9)));
      expect(running.dishes, isEmpty);
    });
  });

  group('the screen', () {
    testWidgets('Location settings opens Dishes sold with the manager\'s token', (tester) async {
      final t = await terminal(tester);
      t.hub.dishes = {theWeek: week()};
      tester.view.physicalSize = const Size(1100, 2800);
      await tester.pumpWidget(
        MaterialApp(
          home: LocationSettingsScreen(api: t.api, token: 'tok-admin', device: 't1'),
        ),
      );
      await tester.pumpAndSettle();
      await bringUp(tester, 'dishes-report');
      expect(find.text('Best to worst, with their sizes and options'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('dishes-report')));
      await tester.pumpAndSettle();
      expect(find.byType(DishesScreen), findsOneWidget);
      expect(t.hub.dishesAsks, hasLength(1));
      expect(t.hub.dishesAuth, 'Bearer tok-admin');
      expect(find.byKey(const ValueKey('dishes-total')), findsOneWidget);
    });

    testWidgets('Sales opens it on the days Sales was reading', (tester) async {
      final t = await terminal(tester);
      const october = '2026-10-01..2026-10-10';
      Map<String, dynamic> sales(String first, String last) => {
        'span': {
          'first': first,
          'last': last,
          'sales': {'gross': '10.00'},
          'menus': [
            {'menu': 'dinner', 'name': 'Dinner', 'count': 1, 'amount': '10.00'},
          ],
          'categories': [
            {'menu': 'dinner', 'code': 'sides', 'name': 'Appetizers', 'count': 1, 'amount': '10.00'},
          ],
        },
        'before': {'first': '2026-09-17', 'last': '2026-09-26'},
        'max_days': 92,
        'now_ms': ms(21),
      };
      t.hub.sales = {theWeek: sales('2026-11-09', '2026-11-15'), october: sales('2026-10-01', '2026-10-10')};
      t.hub.dishes = {
        october: {
          ...week(),
          'span': {'first': '2026-10-01', 'last': '2026-10-10', 'count': 1204, 'amount': '14210.50'},
          'before': {'first': '2026-09-17', 'last': '2026-09-26'},
        },
      };
      tester.view.physicalSize = const Size(1100, 3600);
      final d = Dishes(t)..picks.add(DateTimeRange(start: DateTime(2026, 10, 1), end: DateTime(2026, 10, 10)));
      await tester.pumpWidget(
        MaterialApp(
          home: SalesScreen(api: t.api, token: 'tok-admin', now: () => at(21), pickSpan: d.pickSpan),
        ),
      );
      await tester.pumpAndSettle();
      await tapKey(tester, 'sales:other');
      expect(find.text('Each dish of these days, best to worst'), findsOneWidget);
      await tapKey(tester, 'sales-dishes');
      expect(find.byType(DishesScreen), findsOneWidget);
      expect(t.hub.dishesAsks, [october]);
      expect(t.hub.dishesAuth, 'Bearer tok-admin');
      expect(tester.widget<ChoiceChip>(find.byKey(const ValueKey('dishes:other'))).selected, isTrue);
      expect(find.text('Thu, Oct 1 to Sat, Oct 10, 2026'), findsOneWidget);
      expect(listed(tester).first, 'Egg roll');
      // the calendar there opens on the same days, and back in Sales nothing has moved
      await tapKey(tester, 'dishes:other');
      expect(d.asked.last, DateTimeRange(start: DateTime(2026, 10, 1), end: DateTime(2026, 10, 10)));
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(DishesScreen), findsNothing);
      expect(tester.widget<ChoiceChip>(find.byKey(const ValueKey('sales:other'))).selected, isTrue);
    });

    testWidgets('it opens on the seven days just gone, the most sold first', (tester) async {
      final d = await pumpDishes(tester);
      expect(d.t.hub.dishesAsks, [theWeek]);
      expect(tester.widget<ChoiceChip>(find.byKey(const ValueKey('dishes:week'))).selected, isTrue);
      expect(find.text('Mon, Nov 9 to Sun, Nov 15, 2026'), findsOneWidget);
      expect(find.text('Beside the same days a week before: Mon, Nov 2 to Sun, Nov 8.'), findsOneWidget);
      expect(find.byKey(const ValueKey('dishes-running')), findsNothing);
      expect(row(tester, 'dishes-total'), ['Dishes sold', '1,150 before · up 4.7%', '1,204']);
      expect(row(tester, 'dishes-money'), ['They were sold for', r'$12,700.00 before · up 11.9%', r'$14,210.50']);
      expect(listed(tester), [
        'Egg roll',
        'Tsingtao',
        "General Tso's Chicken",
        'Dragon roll',
        'Combination Plate',
        'Open Food',
        'Mai Tai',
        'Salmon nigiri',
        'Scallion pancake',
      ]);
      expect(row(tester, 'dish-row:EGGROLL'), [
        '1',
        'Egg roll',
        '140×',
        r'$490.00',
        'Appetizers · 150 before · down 6.7%',
      ]);
      expect(row(tester, 'dish-row:TSINGTAO'), ['2', 'Tsingtao', '96×', r'$624.00', 'Beer · 96 before · the same']);
      expect(row(tester, 'dish-row:GTC'), [
        '3',
        "General Tso's Chicken",
        '86×',
        r'$1,240.70',
        "Chef's Specials · 74 before · up 16.2%",
      ]);
      // nothing sold before is said once; none sold at all is said so; a dish gone from the menu says where it is
      expect(row(tester, 'dish-row:DRAGON'), ['4', 'Dragon roll', '61×', r'$972.95', 'Rolls · nothing before']);
      expect(row(tester, 'dish-row:MAITAI'), ['7', 'Mai Tai', '0×', r'$0.00', 'Cocktails · 3 before · down 100%']);
      expect(row(tester, 'dish-row:SALNIG'), ['8', 'Salmon nigiri', '0×', r'$0.00', 'Rolls · none sold']);
      expect(row(tester, 'dish-row:gone:Scallion pancake'), [
        '9',
        'Scallion pancake',
        '0×',
        r'$0.00',
        'Off the menu now · 12 before · down 100%',
      ]);
      expect(find.text('9 dishes · 2 on the menu sold none'), findsOneWidget);
      expect(find.byKey(const ValueKey('dishes-note')), findsOneWidget);
    });

    testWidgets('Money ranks by what they were sold for, and the figure before is money too', (tester) async {
      await pumpDishes(tester);
      await tapKey(tester, 'dishes-by:money');
      expect(listed(tester).take(4), ["General Tso's Chicken", 'Dragon roll', 'Tsingtao', 'Egg roll']);
      expect(row(tester, 'dish-row:GTC'), [
        '1',
        "General Tso's Chicken",
        '86×',
        r'$1,240.70',
        "Chef's Specials · \$1,050.00 before · up 18.2%",
      ]);
      expect(row(tester, 'dish-row:EGGROLL').last, r'Appetizers · $525.00 before · down 6.7%');
      await tapKey(tester, 'dishes-by:count');
      expect(listed(tester).first, 'Egg roll');
    });

    testWidgets('Worst first begins with what nobody ordered, a dish the menu no longer has after those', (
      tester,
    ) async {
      await pumpDishes(tester);
      await tapKey(tester, 'dishes-worst');
      expect(tester.widget<FilterChip>(find.byKey(const ValueKey('dishes-worst'))).selected, isTrue);
      expect(listed(tester), [
        'Mai Tai',
        'Salmon nigiri',
        'Scallion pancake',
        'Open Food',
        'Combination Plate',
        'Dragon roll',
        "General Tso's Chicken",
        'Tsingtao',
        'Egg roll',
      ]);
      expect(row(tester, 'dish-row:MAITAI').first, '1');
      await tapKey(tester, 'dishes-by:money'); // the least money first
      expect(listed(tester).skip(3).take(3), ['Open Food', 'Combination Plate', 'Egg roll']);
      await tapKey(tester, 'dishes-worst');
      expect(listed(tester).first, "General Tso's Chicken");
    });

    testWidgets('each bar is drawn against the best of the list, by how many or by the money', (tester) async {
      await pumpDishes(tester);
      expect(bar(tester, 'EGGROLL'), 1);
      expect(bar(tester, 'GTC'), closeTo(86 / 140, 0.001));
      expect(bar(tester, 'MAITAI'), 0);
      await tapKey(tester, 'dishes-by:money');
      expect(bar(tester, 'GTC'), 1);
      expect(bar(tester, 'EGGROLL'), closeTo(490 / 1240.70, 0.001));
    });

    testWidgets('a dish opens to its sizes and its options, each under its group, and closes again', (tester) async {
      await pumpDishes(tester);
      expect(find.byKey(const ValueKey('dish-more:GTC')), findsNothing);
      await tapKey(tester, 'dish-row:GTC');
      expect(row(tester, 'dish-more:GTC'), [
        'Sizes',
        'Pint',
        '48 before · up 8.3%',
        '52×',
        r'$725.40',
        'Quart',
        '26 before · up 30.8%',
        '34×',
        r'$515.30',
        'Spice level',
        'Medium',
        '55 before · up 9.1%',
        '60×',
        '',
        'Extra spicy',
        '19 before · up 36.8%',
        '26×',
        '',
        'Choice of rice',
        'White rice',
        '62 before · up 12.9%',
        '70×',
        '',
        'Brown rice',
        '12 before · up 33.3%',
        '16×',
        r'$16.00',
        'Add-ons',
        'EXTRA Add shrimp',
        'nothing before',
        '5×',
        r'$40.00',
      ]);
      // a choice made on a choice stands under the choice it belongs to
      await tapKey(tester, 'dish-row:C5');
      expect(row(tester, "dish-option:C5:General Tso's Chicken · Spice level:Extra spicy"), [
        'Extra spicy',
        '1 before · up 200%',
        '3×',
        '',
      ]);
      expect(find.text("General Tso's Chicken · Spice level"), findsOneWidget);
      expect(find.byKey(const ValueKey('dish-more:GTC')), findsOneWidget); // each dish opens by itself
      await tapKey(tester, 'dish-row:GTC');
      expect(find.byKey(const ValueKey('dish-more:GTC')), findsNothing);
      expect(find.byKey(const ValueKey('dish-more:C5')), findsOneWidget);
    });

    testWidgets('an off-menu dish opens to the names typed for it', (tester) async {
      await pumpDishes(tester);
      await tapKey(tester, 'dish-row:OPEN');
      expect(row(tester, 'dish-more:OPEN'), [
        'As it was typed',
        'Lobster ginger scallion',
        '3×',
        r'$59.00',
        'Fried bananas',
        '1×',
        r'$9.00',
      ]);
    });

    testWidgets('a dish with nothing under it has no arrow and does not open', (tester) async {
      await pumpDishes(tester);
      expect(
        find.descendant(of: find.byKey(const ValueKey('dish-row:GTC')), matching: find.byType(Icon)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: find.byKey(const ValueKey('dish-row:EGGROLL')), matching: find.byType(Icon)),
        findsNothing,
      );
      await tapKey(tester, 'dish-row:EGGROLL');
      expect(find.byKey(const ValueKey('dish-more:EGGROLL')), findsNothing);
    });

    testWidgets('one category: only its dishes, numbered from one, and the button names it', (tester) async {
      await pumpDishes(tester);
      await tapKey(tester, 'dishes-category');
      expect(row(tester, 'dishes-category:all'), ['All dishes', '9 dishes', '1,204×', r'$14,210.50']);
      expect(row(tester, 'dishes-category:dinner:chefs'), ["Chef's Specials", '3 dishes', '102×', r'$1,492.70']);
      expect(row(tester, 'dishes-category:drinks:cocktails'), ['Cocktails', '1 dish', '0×', r'$0.00']);
      final sheet = row(tester, 'dishes-categories');
      expect(sheet.indexOf('Dinner'), lessThan(sheet.indexOf('Appetizers'))); // each menu over its categories
      expect(sheet.indexOf('Drinks'), greaterThan(sheet.indexOf('Rolls')));
      await tapKey(tester, 'dishes-category:dinner:chefs');
      expect(find.byKey(const ValueKey('dishes-categories')), findsNothing);
      expect(listed(tester), ["General Tso's Chicken", 'Combination Plate', 'Open Food']);
      // the category is on the button, so a row does not repeat it
      expect(row(tester, 'dish-row:GTC'), ['1', "General Tso's Chicken", '86×', r'$1,240.70', '74 before · up 16.2%']);
      expect(row(tester, 'dishes-category'), ["Chef's Specials"]);
      expect(find.text('3 dishes'), findsOneWidget);
      expect(bar(tester, 'GTC'), 1); // the best of what is shown
      // the totals above stay those of all the dishes
      expect(row(tester, 'dishes-total').last, '1,204');
      await tapKey(tester, 'dishes-category');
      await tapKey(tester, 'dishes-category:all');
      expect(listed(tester), hasLength(9));
      expect(row(tester, 'dishes-category'), ['All dishes']);
      // what the menu no longer has is a place of its own
      await tapKey(tester, 'dishes-category');
      await tapKey(tester, 'dishes-category::');
      expect(listed(tester), ['Scallion pancake']);
      expect(row(tester, 'dish-row:gone:Scallion pancake').last, 'Off the menu now · 12 before · down 100%');
    });

    testWidgets('a dish is found by its name while the keyboard stays, and none by that name is said', (tester) async {
      await pumpDishes(tester);
      await tester.tap(find.byKey(const ValueKey('dishes-find')));
      await tester.pump();
      await tester.enterText(find.byKey(const ValueKey('dishes-find')), 'ro');
      await tester.pumpAndSettle();
      expect(listed(tester), ['Egg roll', 'Dragon roll']);
      expect(find.text('2 dishes'), findsOneWidget);
      expect(row(tester, 'dish-row:DRAGON').first, '2');
      final field = tester.widget<EditableText>(
        find.descendant(of: find.byKey(const ValueKey('dishes-find')), matching: find.byType(EditableText)),
      );
      expect(field.focusNode.hasFocus, isTrue);
      await tester.enterText(find.byKey(const ValueKey('dishes-find')), 'pizza');
      await tester.pumpAndSettle();
      expect(listed(tester), isEmpty);
      expect(find.text('No dish by that name.'), findsOneWidget);
      await tapKey(tester, 'dishes-find-clear');
      expect(listed(tester), hasLength(9));
      // within one category
      await tapKey(tester, 'dishes-category');
      await tapKey(tester, 'dishes-category:dinner:rolls');
      await tester.enterText(find.byKey(const ValueKey('dishes-find')), 'roll');
      await tester.pumpAndSettle();
      expect(listed(tester), ['Dragon roll']);
    });

    testWidgets('more sold is green and less is red, and the same is neither', (tester) async {
      await pumpDishes(tester);
      Color? moved(String key) {
        final line = tester
            .widgetList<Text>(find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(Text)))
            .firstWhere((text) => text.textSpan != null);
        return ((line.textSpan! as TextSpan).children!.last as TextSpan).style!.color;
      }

      final error = Theme.of(tester.element(find.byKey(const ValueKey('dishes-total')))).colorScheme.error;
      expect(moved('dishes-total'), isNot(error));
      expect(moved('dishes-total'), isNotNull);
      expect(moved('dish-row:GTC'), moved('dishes-total'));
      expect(moved('dish-row:EGGROLL'), error);
      expect(moved('dish-row:TSINGTAO'), isNull);
      expect(moved('dish-row:DRAGON'), isNull);
      // under a dish: more of a size is more sold; more of one choice is only how the dish went out
      await tapKey(tester, 'dish-row:GTC');
      expect(moved('dish-size:GTC:Quart'), moved('dishes-total'));
      expect(moved('dish-option:GTC:Spice level:Extra spicy'), isNull);
    });

    testWidgets('Today is the day running; Yesterday and 4 weeks ask for whole days by name', (tester) async {
      final d = await pumpDishes(tester);
      await tapKey(tester, 'dishes:today');
      expect(d.t.hub.dishesAsks.last, '');
      expect(find.text('Monday, November 16, 2026'), findsOneWidget);
      expect(find.text('Beside the same day a week before: Mon, Nov 9.'), findsOneWidget);
      expect(find.byKey(const ValueKey('dishes-running')), findsOneWidget);
      expect(row(tester, 'dishes-total'), ['Dishes sold', 'nothing before', '3']);
      expect(listed(tester), ['Egg roll', 'Chicken wings']);
      await tapKey(tester, 'dishes:yesterday');
      await tapKey(tester, 'dishes:four-weeks');
      expect(d.t.hub.dishesAsks.skip(2), ['2026-11-15..2026-11-15', '2026-10-19..2026-11-15']);
      // days with no dish in the answer: said, with nothing under it
      expect(find.text('No dish here.'), findsOneWidget);
      expect(row(tester, 'dishes-total'), ['Dishes sold', '0']);
      // in the small hours the day of service is still the one before
      final late = await pumpDishes(tester, now: at(2, 30, 17));
      await tapKey(tester, 'dishes:yesterday');
      expect(late.t.hub.dishesAsks, [theWeek, '2026-11-15..2026-11-15']);
    });

    testWidgets('Other days asks the calendar, and more days than the hub adds up are said', (tester) async {
      final d = await pumpDishes(tester);
      await tapKey(tester, 'dishes:other'); // the calendar closed without any day: nothing changes
      expect(d.asked, [null]);
      expect(d.t.hub.dishesAsks, [theWeek]);
      d.picks.add(DateTimeRange(start: DateTime(2026, 10, 1), end: DateTime(2026, 10, 10)));
      await tapKey(tester, 'dishes:other');
      expect(d.t.hub.dishesAsks, [theWeek, '2026-10-01..2026-10-10']);
      expect(find.text('Oct 1 to Oct 10'), findsOneWidget);
      expect(find.text('Thu, Oct 1 to Sat, Oct 10, 2026'), findsOneWidget);
      d.picks.add(DateTimeRange(start: DateTime(2026, 7, 1), end: DateTime(2026, 10, 10)));
      await tapKey(tester, 'dishes:other');
      expect(find.byKey(const ValueKey('dishes-too-long')), findsOneWidget);
      expect(find.text('At most 92 days at a time: that was 102. Pick fewer days.'), findsOneWidget);
      expect(d.t.hub.dishesAsks, hasLength(2));
    });

    testWidgets('another order or other days start the list from its top; reading again stays where it was', (
      tester,
    ) async {
      final many = week();
      many['dishes'] = [
        for (var i = 0; i < 60; i++) dish('D$i', 'Dish number $i', 'sides', 200 - i, '${900 - i}.00', 100, '500.00'),
      ];
      await pumpDishes(tester, size: const Size(390, 844), dishes: {theWeek: many, '': today()});
      double offset() => tester.state<ScrollableState>(find.byType(Scrollable).first).position.pixels;
      Future<void> down() async {
        await tester.drag(find.byKey(const ValueKey('dishes-list')), const Offset(0, -150));
        await tester.pumpAndSettle();
      }

      await down();
      final scrolled = offset();
      expect(scrolled, greaterThan(100));
      await tester.tap(find.byKey(const ValueKey('dishes-refresh')));
      await tester.pumpAndSettle();
      expect(offset(), scrolled);
      await tester.tap(find.byKey(const ValueKey('dishes-worst')));
      await tester.pumpAndSettle();
      expect(offset(), 0);
      expect(listed(tester).first, 'Dish number 59');
      await down();
      await tester.tap(find.byKey(const ValueKey('dishes:today')));
      await tester.pumpAndSettle();
      expect(offset(), 0);
      expect(find.text('Monday, November 16, 2026'), findsOneWidget);
      // far down a long list the rows are still numbered and named
      await tester.tap(find.byKey(const ValueKey('dishes:week')));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('dishes-note')),
        400,
        scrollable: find.byType(Scrollable).first,
      );
      expect(row(tester, 'dish-row:D0').take(2), ['60', 'Dish number 0']); // worst first is still asked
    });

    testWidgets('while the hub adds up, the screen says so', (tester) async {
      final d = await pumpDishes(tester);
      final held = d.t.hub.dishesHeld = Completer<void>();
      await tester.tap(find.byKey(const ValueKey('dishes:yesterday')));
      await tester.pump();
      expect(find.text('Adding up the days'), findsOneWidget);
      expect(find.text('Many days can take some seconds the first time.'), findsNothing);
      expect(find.byKey(const ValueKey('dishes-total')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('dishes:four-weeks')));
      await tester.pump();
      expect(find.text('Many days can take some seconds the first time.'), findsOneWidget);
      held.complete();
      d.t.hub.dishesHeld = null;
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('dishes-reading')), findsNothing);
      expect(find.text('Mon, Oct 19 to Sun, Nov 15, 2026'), findsOneWidget);
    });

    testWidgets('the manager\'s hour is over, the hub is older, refuses or does not answer: the screen says which', (
      tester,
    ) async {
      await pumpDishes(tester, before: (hub) => hub.refuseDishes = 401);
      expect(find.text("The manager's hour here is over: go back and open Location again."), findsOneWidget);
      await pumpDishes(tester, older: true);
      expect(
        find.text('This hub is older than the list of dishes sold. Update the hub to see it here.'),
        findsOneWidget,
      );
      final refused = await pumpDishes(
        tester,
        before: (hub) => hub
          ..refuseDishes = 422
          ..salesRefusal = 'At most 92 days at a time.',
      );
      expect(find.text('At most 92 days at a time.'), findsOneWidget);
      refused.t.hub.refuseDishes = null;
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('dishes-error')), findsNothing);
      expect(row(tester, 'dishes-total').last, '1,204');
      final down = await pumpDishes(tester, before: (hub) => hub.down = true);
      expect(find.text('The hub is not answering'), findsOneWidget);
      down.t.hub.down = false;
    });

    testWidgets('on a small phone a long menu fits, every dish open, in the dark too', (tester) async {
      final big = week();
      big['span'] = {...big['span'] as Map<String, dynamic>, 'count': 1234567, 'amount': '12345678.90'};
      big['dishes'] = [
        for (var i = 0; i < 40; i++)
          dish(
            'D$i',
            'Chef\'s seasonal speciality number $i with three delights',
            'chefs',
            123456 - i,
            '1234567.89',
            120000,
            '1200000.00',
            sizes: [sold('Small for the table', 100000, '1000000.00', 90000, '900000.00')],
            options: [
              sold(
                'EXTRA Sauce on the side with scallions',
                123456,
                '123456.78',
                100000,
                '100000.00',
                group: 'Chef\'s seasonal speciality number one · Choice of sauce and of rice',
              ),
            ],
          ),
      ];
      for (final dark in [false, true]) {
        final t = await terminal(tester);
        t.hub.dishes = {theWeek: big};
        tester.view.physicalSize = const Size(320, 568);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(
          MaterialApp(
            theme: dark ? ThemeData.dark() : null,
            home: DishesScreen(api: t.api, token: 'tok-admin', now: () => at(21)),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tapKey(tester, 'dish-row:D0');
        await tapKey(tester, 'dish-row:D1');
        expect(tester.takeException(), isNull);
        for (var i = 0; i < 6; i++) {
          await tester.drag(find.byKey(const ValueKey('dishes-list')), const Offset(0, -500));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }
        await tester.drag(find.byKey(const ValueKey('dishes-list')), const Offset(0, 5000));
        await tester.pumpAndSettle();
        await tapKey(tester, 'dishes-category');
        expect(tester.takeException(), isNull);
      }
    });
  });
}
