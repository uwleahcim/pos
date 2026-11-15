/// Where an open to-go order stands, for the row of chips above the list of checks: waiting for a time the
/// customer named, with the kitchen, ready on the shelf, and (across all three) not paid yet.
library;

import 'api.dart';
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
    ToGoChip.unpaid => !order.hasPaid,
  };
}

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
