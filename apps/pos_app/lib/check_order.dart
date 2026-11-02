/// The check as the order screen lays it out: a header per course and the lines under each, in rank order,
/// and where a line lands when it is dragged to another row.
library;

import 'api.dart';
import 'coursing.dart';

/// A row of the check: a course's header, or a line under one.
sealed class CheckRow {
  const CheckRow();
}

class CourseRow extends CheckRow {
  const CourseRow({required this.id, required this.name, required this.state});

  /// The course id; empty for lines with no course (or the one group while coursing is off).
  final String id;
  final String name;

  /// held, fired, "N to fire", or empty when nothing is under it.
  final String state;
}

class LineRow extends CheckRow {
  const LineRow(this.line, {required this.course, required this.courseState});
  final Line line;

  /// The course it is listed under (empty for none) and that course's state.
  final String course;
  final String courseState;
}

/// The rows of a check in service order. With coursing on, every course the location serves is listed,
/// empty or not, so a line can be dragged into any of them; a course no longer on the list follows, by its
/// id, then the lines with no course. With coursing off the check is one group, "Items". Under each header
/// the lines come by rank: the order they were added, until a drag moves one.
List<CheckRow> checkRows(Order order, Coursing coursing) {
  final known = [for (final c in coursing.courses) c.id];
  final shown = order.shownLines..sort(_byRank);
  final ids = [if (coursing.enabled) ...known];
  for (final line in shown) {
    final id = line.course ?? '';
    if (!ids.contains(id)) ids.add(id);
  }
  int place(String id) {
    final i = known.indexOf(id);
    return i < 0 ? known.length : i;
  }

  final ordered = [...ids]..sort((a, b) => place(a).compareTo(place(b))); // a stable sort: unknown ids keep their order
  final rows = <CheckRow>[];
  for (final id in ordered) {
    final lines = [
      for (final l in shown)
        if ((l.course ?? '') == id) l,
    ];
    final name = id.isEmpty ? (coursing.enabled ? 'No course' : 'Items') : coursing.nameOf(id);
    final state = _stateOf(lines);
    rows.add(CourseRow(id: id, name: name, state: state));
    rows.addAll([for (final l in lines) LineRow(l, course: id, courseState: state)]);
  }
  return rows;
}

int _byRank(Line a, Line b) {
  final byRank = a.rank.compareTo(b.rank);
  return byRank != 0 ? byRank : a.lineId.compareTo(b.lineId);
}

String _stateOf(List<Line> lines) {
  if (lines.isEmpty) return '';
  final active = lines.where((l) => l.isActive);
  final waiting = active.where((l) => !l.fired).length;
  if (waiting == 0) return 'fired';
  return waiting == active.length ? 'held' : '$waiting to fire';
}

/// Where the row at [from] lands when it is dropped at [to], counted after it has left [from] (as a
/// ReorderableListView's onReorderItem counts): the course whose header is above it, and a rank between
/// the lines around it there. Dropped above the first header, it goes to the top of the first course.
({String? course, double rank}) placement(List<CheckRow> rows, int from, int to) {
  final moved = rows[from] as LineRow;
  final rest = [...rows]..removeAt(from);
  var at = to.clamp(0, rest.length);
  var head = at - 1;
  while (head >= 0 && rest[head] is! CourseRow) {
    head--;
  }
  if (head < 0) {
    head = rest.indexWhere((r) => r is CourseRow);
    if (head < 0) return (course: moved.line.course, rank: moved.line.rank);
    at = head + 1;
  }
  final course = (rest[head] as CourseRow).id;
  final before = at - 1 > head ? (rest[at - 1] as LineRow).line.rank : null;
  final after = at < rest.length && rest[at] is LineRow ? (rest[at] as LineRow).line.rank : null;
  return (course: course.isEmpty ? null : course, rank: rankBetween(before, after, keep: moved.line.rank));
}

/// A rank between two neighbours: halfway between them, one past the only one there is, or [keep] when
/// the line is alone under its header.
double rankBetween(double? before, double? after, {required double keep}) {
  if (before == null && after == null) return keep;
  if (before == null) return after! - 1;
  if (after == null) return before + 1;
  return (before + after) / 2;
}
