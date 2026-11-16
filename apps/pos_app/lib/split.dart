/// Splitting a check: one table, several checks. The dishes stay on the one order; the order says how the
/// table pays (`split`) and a dish can be put on other checks than that gives it (the line's `checks`). The
/// hub reckons what each check comes to (pos.orders.split). Here: which dish is on which check, worked out
/// the hub's way so a tap shows at once, and the operations each gesture on the split screen sends.
library;

import 'api.dart';
import 'local_order.dart';
import 'menu.dart';

/// An operation to append to the order: its kind and its data.
typedef SplitOp = (String, Map<String, dynamic>);

/// Which checks a table has, by number, and which of them each live dish is on (several: shared between
/// them in equal parts). Empty while the table is not split by its dishes.
class Placed {
  const Placed(this.numbers, this.on);

  static const none = Placed([], {});

  final List<int> numbers;
  final Map<String, List<int>> on;

  /// Two checks or more: a table with every dish on one check is not split, whatever was asked.
  bool get isSplit => numbers.length > 1;

  /// The number a new check takes: the one after the highest, or the lowest one free once the numbers run out.
  int get next {
    final top = numbers.isEmpty ? 1 : numbers.last;
    if (top < maxChecks) return top + 1;
    for (var n = 1; n <= maxChecks; n++) {
      if (!numbers.contains(n)) return n;
    }
    return maxChecks;
  }
}

/// How the order says its table pays.
SplitMode splitOf(Order order) => SplitMode.of(order.fields['split']);

/// The hub's rule (`placed` in pos.orders.split): a dish put on checks by hand is on those; otherwise by
/// seat it is on its seat's check and a dish for the table is shared by every check, and by hand it is on
/// check 1.
Placed placedOn(Order order) {
  final mode = splitOf(order);
  if (!mode.byDishes) return Placed.none;
  final own = <String, List<int>?>{};
  for (final line in order.activeLines) {
    final seat = line.seat;
    own[line.lineId] =
        line.checks ??
        (mode.by == 'dish'
            ? const [1]
            : seat != null && seat >= 1 && seat <= maxChecks
            ? [seat]
            : null);
  }
  final numbers = <int>{for (final on in own.values) ...?on}.toList()..sort();
  if (numbers.isEmpty) return Placed.none;
  return Placed(numbers, {for (final MapEntry(:key, :value) in own.entries) key: value ?? numbers});
}

/// How many checks the table pays on as it stands on this screen: the parts of an even split, the checks its
/// dishes are on, or one.
int checksOf(Order order) {
  final mode = splitOf(order);
  if (mode.isEven) return mode.ways;
  final placed = placedOn(order);
  return placed.isSplit ? placed.numbers.length : 1;
}

/// [amount] cents in [n] equal parts that add up to it, the odd cents on the first parts: the hub's `parts`.
List<int> equalParts(int amount, int n) => [for (var i = 0; i < n; i++) amount ~/ n + (i < amount % n ? 1 : 0)];

/// What a dish worth [total] comes to on check [number] when it is on the checks [on].
String partOf(String total, List<int> on, int number) {
  final at = on.indexOf(number);
  return at < 0 ? '0.00' : money(equalParts(cents(total), on.length)[at]);
}

/// Every dish goes back to where the split places it: what was put by hand is forgotten, [except] for these.
List<SplitOp> _forget(Order order, {Set<String> except = const {}}) => [
  for (final line in order.activeLines)
    if (line.checks != null && !except.contains(line.lineId)) ('set_line', {'line_id': line.lineId, 'checks': null}),
];

/// A check for each seat, in one tap: the seats place the dishes, and whatever was moved by hand before
/// starts over.
List<SplitOp> bySeatOps(Order order) => [
  ..._forget(order),
  (
    'set_field',
    {
      'split': {'by': 'seat'},
    },
  ),
];

/// The total in [ways] equal parts; the dishes stay together.
List<SplitOp> evenOps(Order order, int ways) => [
  ..._forget(order),
  (
    'set_field',
    {
      'split': {'by': 'even', 'ways': ways.clamp(2, maxChecks)},
    },
  ),
];

/// One check again.
List<SplitOp> oneCheckOps(Order order) => [
  ..._forget(order),
  ('set_field', {'split': null}),
];

/// Puts [lines] on [checks]: one number moves them there, several share each of them between those checks.
/// On a table not split by its dishes yet this starts the split by hand, everything else on check 1.
List<SplitOp> putOps(Order order, Iterable<Line> lines, List<int> checks) {
  final on = checkNumbers(checks);
  if (on == null) return const [];
  final moved = {for (final line in lines) line.lineId};
  return [
    if (!splitOf(order).byDishes) ...[
      ..._forget(order, except: moved),
      (
        'set_field',
        {
          'split': {'by': 'dish'},
        },
      ),
    ],
    for (final id in moved) ('set_line', {'line_id': id, 'checks': on}),
  ];
}
