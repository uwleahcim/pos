/// The pickup board (docs/pickup-board.md): what a screen facing the pickup shelf tells the customers. The
/// to-go orders the kitchen is making and the ones that are ready, each by its number and a first name.
/// Nothing else of an order is on it: no dishes, no money, no phone number, no family name.
library;

import 'api.dart';
import 'takeout.dart';
import 'to_go_stages.dart';

/// One order as the board names it.
class BoardOrder {
  const BoardOrder({required this.orderId, this.number, this.name = ''});

  final String orderId;

  /// The number the hub gave the order for the day; null on an order that has none.
  final int? number;

  /// The first name, as it was typed on the order; empty when none was.
  final String name;
}

/// The first word of the name on an order: "Linda" of "Linda Chen", "Mr." of "Mr. Wong". A board the whole
/// room can read says no more of a customer than that.
String firstName(String name) {
  final words = name.trim().split(RegExp(r'\s+'));
  return words.isEmpty ? '' : words.first;
}

/// What the board lists at [now]: the open to-go orders the kitchen has ([made]: sent, and their ticket's
/// time has come) and the ones marked ready ([ready]), each by its number, lowest first, so a customer
/// finds theirs where they expect it. An order still being rung up, or sent ahead for a later time whose
/// ticket has not printed, is on neither list; nor is a table's check or a bar tab. Nor is an order that is
/// brought to the customer (docs/delivery.md): nobody stands at the shelf waiting for it.
({List<BoardOrder> made, List<BoardOrder> ready}) boardOf(Iterable<Order> orders, DateTime now) {
  List<BoardOrder> listed(ToGoChip chip) {
    final rows = [
      for (final order in orders)
        if (inChip(chip, order, now) && !order.isDelivery)
          BoardOrder(orderId: order.orderId, number: order.orderNo, name: firstName(order.customerName)),
    ];
    // (a stable sort: two with no number keep the order they came in)
    final placed = rows.indexed.toList()
      ..sort((a, b) {
        final byNumber = (a.$2.number ?? (1 << 30)).compareTo(b.$2.number ?? (1 << 30));
        return byNumber != 0 ? byNumber : a.$1.compareTo(b.$1);
      });
    return [for (final (_, row) in placed) row];
  }

  return (made: listed(ToGoChip.cooking), ready: listed(ToGoChip.ready));
}

/// The next moment after [now] at which the board changes by itself: an order sent ahead for a later time
/// starts cooking when its ticket prints, with nobody touching anything. Null when no order is waiting.
DateTime? boardChanges(Iterable<Order> orders, DateTime now) {
  DateTime? next;
  for (final order in orders) {
    final promised = order.promisedAt;
    if (promised == null || !order.isFired || !inChip(ToGoChip.later, order, now)) continue;
    final starts = startsAt(promised, order.quotedMinutes);
    if (starts.isAfter(now) && (next == null || starts.isBefore(next))) next = starts;
  }
  return next;
}
