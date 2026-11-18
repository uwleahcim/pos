/// Where an open to-go order stands, for the row of chips above the list of checks: waiting for a time the
/// customer named, with the kitchen, ready on the shelf, and (across all three) not paid yet.
library;

import 'api.dart';
import 'local_order.dart';
import 'takeout.dart';

/// The chips, in the order an order moves through them; [unpaid] cuts across the other three.
enum ToGoChip {
  later('Later', 'No orders are waiting for a later time.'),
  cooking('Cooking', 'No to-go orders are with the kitchen.'),
  ready('Ready', 'No to-go orders are ready.'),
  unpaid('Unpaid', 'Every to-go order is paid.');

  const ToGoChip(this.label, this.none);

  final String label;

  /// What the list says when the chip is picked and nothing is in it.
  final String none;
}

/// Whether an open to-go order is still waiting for the time the customer named: nobody sent it yet, or it
/// was sent and the hub holds its ticket until it must start cooking (its time less its quote). The kitchen
/// has seen nothing of it, so it is not cooking and cannot be ready.
bool waitsForItsTime(Order order, DateTime now) {
  final promised = order.promisedAt;
  if (!order.forLater || promised == null) return false;
  return !order.isFired || now.isBefore(startsAt(promised, order.quotedMinutes));
}

/// Whether [order] is listed under [chip] at [now]. Only open to-go orders are; a table's check never is.
/// An order still being rung up for now (not sent, no time named) is in none of the three stages: it shows
/// under [ToGoChip.unpaid] until it is paid, and in the whole list.
bool inChip(ToGoChip chip, Order order, DateTime now) {
  if (!order.isTakeout || !order.isOpen) return false;
  return switch (chip) {
    ToGoChip.later => order.stage == 'new' && waitsForItsTime(order, now),
    ToGoChip.cooking => order.stage == 'new' && order.isFired && !waitsForItsTime(order, now),
    ToGoChip.ready => order.stage == 'ready',
    ToGoChip.unpaid => owes(order),
  };
}

/// Whether money is still to collect on a to-go order, as far as a list of checks can tell: by what the hub
/// says is due on an order that took money (a deposit is not the whole of it), and on any other order, or
/// with a hub older than deposits, by whether anything was paid at all.
bool owes(Order order) => switch (order.due) {
  final due? => cents(due) > 0,
  null => !order.hasPaid,
};

/// What a list of checks says of a to-go order's money: "paid", "pay at pickup" while nothing was taken
/// ("pay at the door" of a delivery, docs/delivery.md), and "$45.01 due" once a deposit was.
String moneyWords(Order order) => switch (order.due) {
  final due? when cents(due) > 0 => '\$$due due',
  _ when order.hasPaid => 'paid',
  _ => order.isDelivery ? 'pay at the door' : 'pay at pickup',
};

/// How many of [orders] each chip lists at [now].
Map<ToGoChip, int> chipCounts(Iterable<Order> orders, DateTime now) => {
  for (final chip in ToGoChip.values) chip: orders.where((order) => inChip(chip, order, now)).length,
};

/// The orders a chip lists, the one due first at the top: what the counter and the kitchen work down. Two
/// due at the same minute keep the order their numbers were given in.
List<T> dueFirst<T>(Iterable<T> rows, Order Function(T row) order) {
  int due(T row) => order(row).promisedAt ?? (1 << 62); // one with no time goes last
  // Sorted with its place in the list as it came, which is the order the checks were opened in.
  final placed = rows.indexed.toList()
    ..sort((a, b) {
      final byTime = due(a.$2).compareTo(due(b.$2));
      return byTime != 0 ? byTime : a.$1.compareTo(b.$1);
    });
  return [for (final (_, row) in placed) row];
}

/// The bar's tabs by the name on each, whatever its case: what a bartender looks down for "Linda". Two of
/// one name keep the order they were opened in.
List<T> tabsByName<T>(Iterable<T> rows, Order Function(T row) order) {
  final placed = rows.indexed.toList()
    ..sort((a, b) {
      final byName = order(a.$2).customerName
          .trim()
          .toLowerCase()
          .compareTo(order(b.$2).customerName.trim().toLowerCase());
      return byName != 0 ? byName : a.$1.compareTo(b.$1);
    });
  return [for (final (_, row) in placed) row];
}
