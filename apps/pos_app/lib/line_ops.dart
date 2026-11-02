/// Changing a line on the check, as the operations the backend needs: how many of a dish it holds, and
/// where it sits (its place and its course) after a drag.
///
/// Before the kitchen has a line, it simply changes. After, the kitchen is already cooking it: more of it
/// is a new line of the extra, held like any dish just added until the operator fires it; fewer is a void
/// of the line (a VOID ticket prints) and the rest sent again on the same ticket; another course is a void
/// and the same dish again, held for the new course. A void is confirmed by the operator first.
library;

import 'api.dart';

typedef Op = (String, Map<String, dynamic>);

class LineChange {
  const LineChange(this.ops, {this.newLineId, this.voidsFired = false});

  final List<Op> ops;

  /// The line this change adds, if it adds one: the screen prices it like the line it copies.
  final String? newLineId;

  /// The kitchen gets a VOID ticket: ask before sending.
  final bool voidsFired;

  bool get isEmpty => ops.isEmpty;
}

/// The operations that make `line` hold `qty`. Zero takes it off (a void once fired).
LineChange qtyChange(Line line, int qty, {required String Function() newId}) {
  if (!line.isActive || qty == line.qty || qty < 0) return const LineChange([]);
  final id = line.lineId;
  if (qty == 0) {
    return LineChange([
      ('void_line', {'line_id': id, if (line.fired) 'reason': 'void'}),
    ], voidsFired: line.fired);
  }
  if (!line.fired) {
    return LineChange([
      ('set_line', {'line_id': id, 'qty': qty}),
    ]);
  }
  final copy = newId();
  if (qty > line.qty) {
    return LineChange([('add_line', _copyOf(line, copy, qty - line.qty, course: line.course))], newLineId: copy);
  }
  return LineChange(
    [
      ('void_line', {'line_id': id, 'reason': 'fewer'}),
      ('add_line', _copyOf(line, copy, qty, course: line.course)),
      ('fire', {'course': line.course ?? '*'}),
    ],
    newLineId: copy,
    voidsFired: true,
  );
}

/// The operations that put `line` under `course` (null: none) at `rank`, after a drag on the check. Within
/// its course a line just takes its place, sent or not: the kitchen is not told. Into another course, a
/// line the kitchen has not seen takes the course with it; one it has is voided and the same dish added
/// again under the new course, held until that course fires.
LineChange moveChange(Line line, {required String? course, required double rank, required String Function() newId}) {
  if (!line.isActive) return const LineChange([]);
  final id = line.lineId;
  if ((line.course ?? '') == (course ?? '')) {
    if (rank == line.rank) return const LineChange([]);
    return LineChange([
      ('set_line', {'line_id': id, 'rank': rank}),
    ]);
  }
  if (!line.fired) {
    return LineChange([
      ('set_line', {'line_id': id, 'course': course, 'rank': rank}),
    ]);
  }
  final copy = newId();
  return LineChange(
    [
      ('void_line', {'line_id': id, 'reason': 'moved'}),
      ('add_line', _copyOf(line, copy, line.qty, course: course, rank: rank)),
    ],
    newLineId: copy,
    voidsFired: true,
  );
}

Map<String, dynamic> _copyOf(Line line, String id, int qty, {required String? course, double? rank}) => {
  'line_id': id,
  'item': line.item,
  'qty': qty,
  'seat': ?line.seat,
  'course': ?course,
  if (line.note.isNotEmpty) 'note': line.note,
  if (line.request != null) 'request': line.request!.toJson(),
  'rank': ?rank,
};
