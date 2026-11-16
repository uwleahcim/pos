import 'sales_report.dart' show calendarDays;

/// Dishes sold over a span of days as the hub reckons them (`GET /reports/dishes`, docs/dishes-sold.md):
/// every dish with how many and for how much, the same for as many days whole weeks earlier, the sizes it
/// went out in and every choice made on it. The hub does every sum; this is its answer read into names, and
/// the order the screen lists them in ([sortedDishes]). Amounts stay the hub's own words ("58.60").

String _s(Object? value, [String or = '']) => value is String ? value : or;
int _i(Object? value) => value is num ? value.toInt() : 0;
List<Map<String, dynamic>> _rows(Object? value) => [
  if (value is List)
    for (final row in value)
      if (row is Map) row.cast<String, dynamic>(),
];

/// How many and for how much, in the span and in the days before: a dish, one of its sizes, one of its
/// options, a name typed for an off-menu dish, or a category.
class SoldRow {
  const SoldRow({
    required this.name,
    this.group = '',
    this.count = 0,
    this.amount = '0.00',
    this.beforeCount = 0,
    this.beforeAmount = '0.00',
  });

  factory SoldRow.fromJson(Map<String, dynamic> json) => SoldRow(
    name: _s(json['name']),
    group: _s(json['group']),
    count: _i(json['count']),
    amount: _s(json['amount'], '0.00'),
    beforeCount: _i(json['before_count']),
    beforeAmount: _s(json['before_amount'], '0.00'),
  );

  final String name;

  /// For an option: the group it belongs to ("Choice of rice"), or the choice it was made on and then its
  /// group ("General Tso's Chicken · Spice level").
  final String group;
  final int count;

  /// What it was sold for. For an option: what it added to its dishes, which is in the dish's amount already.
  final String amount;
  final int beforeCount;
  final String beforeAmount;

  num get money => double.tryParse(amount) ?? 0;
  num get beforeMoney => double.tryParse(beforeAmount) ?? 0;
}

/// One dish of the menu, or one sold that the menu no longer has.
class DishSold extends SoldRow {
  const DishSold({
    required super.name,
    this.item,
    this.menu = '',
    this.menuName = '',
    this.category = '',
    this.categoryName = '',
    this.onMenu = true,
    super.count,
    super.amount,
    super.beforeCount,
    super.beforeAmount,
    this.sizes = const [],
    this.typed = const [],
    this.options = const [],
  });

  factory DishSold.fromJson(Map<String, dynamic> json) => DishSold(
    name: _s(json['name']),
    item: json['item'] is String ? json['item'] as String : null,
    menu: _s(json['menu']),
    menuName: _s(json['menu_name']),
    category: _s(json['category']),
    categoryName: _s(json['category_name']),
    onMenu: json['on_menu'] != false,
    count: _i(json['count']),
    amount: _s(json['amount'], '0.00'),
    beforeCount: _i(json['before_count']),
    beforeAmount: _s(json['before_amount'], '0.00'),
    sizes: [for (final row in _rows(json['sizes'])) SoldRow.fromJson(row)],
    typed: [for (final row in _rows(json['typed'])) SoldRow.fromJson(row)],
    options: [for (final row in _rows(json['options'])) SoldRow.fromJson(row)],
  );

  /// The dish's code on the menu; null for one the menu no longer has.
  final String? item;
  final String menu;
  final String menuName;
  final String category;
  final String categoryName;

  /// Whether the menu shows it today.
  final bool onMenu;

  /// The sizes it went out in, where it has more than one. They add up to the dish.
  final List<SoldRow> sizes;

  /// The names typed for an off-menu dish.
  final List<SoldRow> typed;

  /// Every choice made on it, in the order of its groups.
  final List<SoldRow> options;

  /// What tells it apart from every other line of the list.
  String get id => item ?? 'gone:$name';

  bool get hasMore => sizes.isNotEmpty || typed.isNotEmpty || options.isNotEmpty;
}

/// A category of a menu with what its dishes came to.
class DishCategory extends SoldRow {
  const DishCategory({
    required super.name,
    this.menu = '',
    this.menuName = '',
    this.code = '',
    this.dishes = 0,
    super.count,
    super.amount,
    super.beforeCount,
    super.beforeAmount,
  });

  factory DishCategory.fromJson(Map<String, dynamic> json) => DishCategory(
    name: _s(json['name']),
    menu: _s(json['menu']),
    menuName: _s(json['menu_name']),
    code: _s(json['code']),
    dishes: _i(json['dishes']),
    count: _i(json['count']),
    amount: _s(json['amount'], '0.00'),
    beforeCount: _i(json['before_count']),
    beforeAmount: _s(json['before_amount'], '0.00'),
  );

  final String menu;
  final String menuName;
  final String code;

  /// How many dishes it lists.
  final int dishes;

  String get id => '$menu:$code';
}

/// The days of a span and what all their dishes come to.
class DishesSpan {
  const DishesSpan({
    required this.first,
    required this.last,
    this.running = false,
    this.count = 0,
    this.amount = '0.00',
  });

  factory DishesSpan.fromJson(Map<String, dynamic> json) => DishesSpan(
    first: DateTime.tryParse(_s(json['first'])) ?? DateTime(2000),
    last: DateTime.tryParse(_s(json['last'])) ?? DateTime(2000),
    running: json['running'] == true,
    count: _i(json['count']),
    amount: _s(json['amount'], '0.00'),
  );

  final DateTime first;
  final DateTime last;
  final bool running;

  /// How many dishes were sold, and for how much before comps and discounts: Sales' "Dishes sold".
  final int count;
  final String amount;

  int get dayCount => calendarDays(first, last);
}

class DishesReport {
  const DishesReport({
    required this.span,
    required this.before,
    this.dishes = const [],
    this.categories = const [],
    this.maxDays = 92,
    this.nowMs = 0,
  });

  factory DishesReport.fromJson(Map<String, dynamic> json) => DishesReport(
    span: DishesSpan.fromJson((json['span'] as Map?)?.cast<String, dynamic>() ?? const {}),
    before: DishesSpan.fromJson((json['before'] as Map?)?.cast<String, dynamic>() ?? const {}),
    dishes: [for (final row in _rows(json['dishes'])) DishSold.fromJson(row)],
    categories: [for (final row in _rows(json['categories'])) DishCategory.fromJson(row)],
    maxDays: json['max_days'] is num ? (json['max_days'] as num).toInt() : 92,
    nowMs: _i(json['now_ms']),
  );

  final DishesSpan span;

  /// As many days, whole weeks earlier.
  final DishesSpan before;

  /// Every dish sold in either, and every dish on the menu that sold none.
  final List<DishSold> dishes;

  /// The same by menu and category, in the order of the menu.
  final List<DishCategory> categories;
  final int maxDays;
  final int nowMs;

  /// Dishes the menu shows that nobody ordered in the span.
  int get unsold => dishes.where((dish) => dish.onMenu && dish.count == 0).length;
}

/// The orders the list can stand in.
enum DishSort {
  most('Most sold', byMoney: false, worstFirst: false),
  least('Least sold', byMoney: false, worstFirst: true),
  mostMoney('Most money', byMoney: true, worstFirst: false),
  leastMoney('Least money', byMoney: true, worstFirst: true);

  const DishSort(this.words, {required this.byMoney, required this.worstFirst});

  final String words;

  /// Ranked by what they were sold for, not by how many.
  final bool byMoney;
  final bool worstFirst;
}

/// [dishes] in the order [sort] asks: by how many or by the money, best or worst first, the other figure
/// telling equals apart and then the name. Worst first lists what the menu still shows before what it no
/// longer has: a dish taken off the menu sold none because it could not.
List<DishSold> sortedDishes(Iterable<DishSold> dishes, DishSort sort) {
  int byName(DishSold a, DishSold b) => a.name.toLowerCase().compareTo(b.name.toLowerCase());
  int compare(DishSold a, DishSold b) {
    final count = a.count.compareTo(b.count), money = a.money.compareTo(b.money);
    final first = sort.byMoney ? money : count, second = sort.byMoney ? count : money;
    final order = first != 0 ? first : second;
    if (order != 0) return sort.worstFirst ? order : -order;
    if (sort.worstFirst && a.onMenu != b.onMenu) return a.onMenu ? -1 : 1;
    return byName(a, b);
  }

  return dishes.toList()..sort(compare);
}

/// The dishes whose name has every word of [words], whatever the case and the order.
List<DishSold> dishesNamed(Iterable<DishSold> dishes, String words) {
  final wanted = words.toLowerCase().split(RegExp(r'\s+')).where((word) => word.isNotEmpty).toList();
  if (wanted.isEmpty) return dishes.toList();
  return [
    for (final dish in dishes)
      if (wanted.every(dish.name.toLowerCase().contains)) dish,
  ];
}
