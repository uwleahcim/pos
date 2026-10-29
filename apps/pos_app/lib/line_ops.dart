/// Changing how many of a dish a line holds, as the operations the backend needs.
///
/// Before the kitchen has a line, its quantity simply changes. After, the kitchen is already cooking it:
/// more of it is a new line of the extra, held like any dish just added until the operator fires it; fewer
/// is a void of the line (a VOID ticket prints) and the rest sent again on the same ticket, which the
/// operator confirms first.
library;

import 'api.dart';

typedef Op = (String, Map<String, dynamic>);

class QtyChange {
  const QtyChange(this.ops, {this.newLineId, this.voidsFired = false});

  final List<Op> ops;

  /// The line this change adds, if it adds one: the screen prices it like the line it copies.
  final String? newLineId;

  /// The kitchen gets a VOID ticket: ask before sending.
  final bool voidsFired;

  bool get isEmpty => ops.isEmpty;
}

/// The operations that make `line` hold `qty`. Zero takes it off (a void once fired).
QtyChange qtyChange(Line line, int qty, {required String Function() newId}) {
  if (!line.isActive || qty == line.qty || qty < 0) return const QtyChange([]);
  final id = line.lineId;
  if (qty == 0) {
    return QtyChange([
      ('void_line', {'line_id': id, if (line.fired) 'reason': 'void'}),
    ], voidsFired: line.fired);
  }
  if (!line.fired) {
    return QtyChange([
      ('set_line', {'line_id': id, 'qty': qty}),
    ]);
  }
  final copy = newId();
  if (qty > line.qty) {
    return QtyChange([('add_line', _copyOf(line, copy, qty - line.qty))], newLineId: copy);
  }
  return QtyChange(
    [
      ('void_line', {'line_id': id, 'reason': 'fewer'}),
      ('add_line', _copyOf(line, copy, qty)),
      ('fire', {'course': line.course ?? '*'}),
    ],
    newLineId: copy,
    voidsFired: true,
  );
}

Map<String, dynamic> _copyOf(Line line, String id, int qty) => {
  'line_id': id,
  'item': line.item,
  'qty': qty,
  'seat': ?line.seat,
  'course': ?line.course,
  if (line.note.isNotEmpty) 'note': line.note,
  if (line.request != null) 'request': line.request!.toJson(),
};
