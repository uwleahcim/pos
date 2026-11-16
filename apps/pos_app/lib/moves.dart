/// Moving a table's check to another table, merging two checks, and passing dishes from one check to
/// another: the operations a screen queues for each. Nothing here talks to a hub.
///
/// A dish that changes checks is never voided and rung in again. The check that takes it gets an `add_line`
/// naming where the dish comes from, and the hub fills the dish in from there (what it is, its price, whether
/// the kitchen has it); the check that lets it go gets a `move_line`. The taking check's operations are
/// queued first, so a dish is on both checks for a moment and never on neither, and the hub stores the
/// second only when the first arrived (`pos.orders.moves` on the hub).
library;

import 'dart:math' as math;

import 'allergies.dart';
import 'api.dart';
import 'session.dart';

/// Operations for one order, in the order they are queued.
typedef OrderOps = (String orderId, List<(String, Map<String, dynamic>)> ops);

/// Who is doing it, as an operation says it.
Map<String, dynamic> _by(Staff? staff) => {
  if (staff != null) 'by': staff.name,
  if (staff != null) 'by_id': staff.staffId,
};

/// The table's checks go to another table as they are: each keeps its dishes, its server and its history.
List<OrderOps> moveTableOps(Iterable<String> orderIds, String toTable, {Staff? by}) => [
  for (final id in orderIds)
    (
      id,
      [
        ('set_field', {'table': toTable, ..._by(by)}),
      ],
    ),
];

/// The seat a dish of [from] gets on [onto] when the two checks become one: the guests who came over sit
/// after the ones already there, so seat 1 of the party that moved is the first seat after them.
int seatShift(Order onto) {
  final guests = onto.fields['guests'];
  final seated = onto.activeLines.fold<int>(0, (top, line) => math.max(top, line.seat ?? 0));
  return math.max(guests is int ? guests : 0, seated);
}

/// The dishes [lines] of [from] go onto the check [onto]. Each keeps what it is and whether the kitchen has
/// it (the hub's to fill in), and the discounts on it go with it. [seat] says where each sits on the other
/// check (null: for the table). The taking check's operations come first.
List<OrderOps> moveLinesOps({
  required Order from,
  required String onto,
  required List<Line> lines,
  required String Function() newId,
  int? Function(Line line)? seat,
  Staff? by,
}) {
  final taking = <(String, Map<String, dynamic>)>[];
  final letting = <(String, Map<String, dynamic>)>[];
  final ordered = [...lines.where((line) => line.isActive)]..sort((a, b) => a.rank.compareTo(b.rank));
  for (final line in ordered) {
    final id = newId();
    taking.add((
      'add_line',
      {
        'line_id': id,
        'item': line.item,
        'qty': line.qty,
        'seat': seat?.call(line),
        if (line.course != null) 'course': line.course,
        if (line.note.isNotEmpty) 'note': line.note,
        if (line.request != null) 'request': line.request!.toJson(),
        'from': {'order_id': from.orderId, 'line_id': line.lineId},
        // the hub says when it was sent; until it answers, the screen shows it as the kitchen has it
        if (line.fired) 'sent': 'sent',
        if (line.by.isNotEmpty) 'by': line.by,
        if (line.byId != null) 'by_id': line.byId,
        // who rang the dish in stays who rang it; who brings it over is said beside, for the check's history
        if (by != null) 'moved_by': by.name,
        if (by != null) 'moved_by_id': by.staffId,
      },
    ));
    for (final discount in from.discounts) {
      final on = discount.lineId;
      if (on == null || from.currentLine(on) != line.lineId) continue;
      taking.add((
        'discount',
        {
          'discount_id': newId(),
          'line_id': id,
          'from': {'order_id': from.orderId, 'discount_id': discount.discountId},
          ..._by(by),
        },
      ));
    }
    letting.add((
      'move_line',
      {
        'line_id': line.lineId,
        'to': {'order_id': onto, 'line_id': id},
        ..._by(by),
      },
    ));
  }
  if (taking.isEmpty) return const [];
  return [(onto, taking), (from.orderId, letting)];
}

/// What stands in the way of emptying [from] into another check, in words for the person asking; null when
/// nothing does. Money taken on a check stays with that check, so a check with a payment on it is not
/// emptied: it can sit at the other table, kept apart.
String? cannotMerge(Order from) {
  if (from.payments.isNotEmpty) return 'has a payment on it, so it stays a check of its own';
  return null;
}

/// Whether [order] carries a discount on the whole check. Such a discount was given on that check's own
/// total and does not go along when its dishes join another check.
bool hasCheckDiscount(Order order) => order.discounts.any((d) => d.lineId == null);

/// The check [from] is emptied into [onto]: every dish goes over (the guests who came sit after the ones
/// already there, see [seatShift]), the guests add up, the allergies told at [from] are told at [onto] (a
/// seat's on its new seat; the table's joins the other table's), and [from] is closed, empty, saying where
/// its dishes went. The taking check's operations come first.
List<OrderOps> mergeOps({required Order from, required Order onto, required String Function() newId, Staff? by}) {
  final shift = seatShift(onto);
  final who = _by(by);
  final moved = moveLinesOps(
    from: from,
    onto: onto.orderId,
    lines: from.activeLines,
    newId: newId,
    seat: (line) => line.seat == null ? null : line.seat! + shift,
    by: by,
  );
  final taking = <(String, Map<String, dynamic>)>[...(moved.isEmpty ? const [] : moved.first.$2)];
  final letting = <(String, Map<String, dynamic>)>[...(moved.isEmpty ? const [] : moved.last.$2)];
  final came = from.fields['guests'];
  final there = onto.fields['guests'];
  if (came is int && came > 0) {
    taking.add(('set_field', {'guests': (there is int ? there : 0) + came, ...who}));
  }
  final table = onto.allergies.where((a) => a.seat == null).firstOrNull;
  for (final told in from.allergies) {
    if (told.isEmpty) continue;
    final seat = told.seat;
    if (seat != null) {
      taking.add(('allergy', {'seat': seat + shift, 'allergens': told.allergens, 'note': told.note, ...who}));
    } else {
      // told for the whole of the table that moved: the kitchen is to keep it in mind for the joined table
      final notes = [if (table != null && table.note.isNotEmpty) table.note, if (told.note.isNotEmpty) told.note];
      taking.add((
        'allergy',
        {
          'seat': null,
          'allergens': <String>{...?table?.allergens, ...told.allergens}.toList(),
          'note': Allergy.cleanNote(notes.toSet().join('; ')),
          ...who,
        },
      ));
    }
  }
  letting.add(('set_field', {'merged_into': onto.orderId, ...who}));
  letting.add(('close', who));
  return [if (taking.isNotEmpty) (onto.orderId, taking), (from.orderId, letting)];
}
