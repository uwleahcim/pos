/// The check as the order screen lays it out: a header per course and the lines under each, in rank order,
/// and where lines land when one is dragged to another row (with any picked up to go along with it).
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

/// Where lines let go on the check land: the course they go under, the row the first of them takes, and
/// the lines themselves (the one in hand and any picked up while it was held, in the order the check had
/// them) with a rank each.
class Drop {
  const Drop({required this.course, required this.at, required this.lines, required this.ranks});

  /// The course they land in; null for none.
  final String? course;

  /// The row the first of them takes, counted once they have all left their rows.
  final int at;

  /// The lines, in the order the check had them.
  final List<Line> lines;

  /// A rank each, in the same order.
  final List<double> ranks;
}

/// Where the row at [from] lands when it is dropped at [to], counted after it has left [from] (as a
/// ReorderableListView's onReorderItem counts), with the lines [picked] up while it was held: the course
/// whose header is above the drop, and ranks between the lines around it there. Dropped above the first
/// header, they go to the top of the first course. The picked lines leave their rows as well, so none of
/// them counts as a neighbour of the drop.
Drop dropOf(List<CheckRow> rows, int from, int to, {Set<String> picked = const {}}) {
  final held = rows[from] as LineRow;
  final moving = {held.line.lineId, ...picked};
  final lines = [
    for (final row in rows)
      if (row is LineRow && moving.contains(row.line.lineId)) row.line,
  ];
  final rest = [...rows]..removeAt(from);
  final slot = to.clamp(0, rest.length);
  var at = slot;
  final kept = <CheckRow>[];
  for (var i = 0; i < rest.length; i++) {
    final row = rest[i];
    if (row is LineRow && moving.contains(row.line.lineId)) {
      if (i < slot) at--;
      continue;
    }
    kept.add(row);
  }
  final ranks = [for (final line in lines) line.rank];
  var head = at - 1;
  while (head >= 0 && kept[head] is! CourseRow) {
    head--;
  }
  if (head < 0) {
    head = kept.indexWhere((r) => r is CourseRow);
    if (head < 0) return Drop(course: held.line.course, at: at, lines: lines, ranks: ranks);
    at = head + 1;
  }
  final course = (kept[head] as CourseRow).id;
  final before = at - 1 > head ? (kept[at - 1] as LineRow).line.rank : null;
  final after = at < kept.length && kept[at] is LineRow ? (kept[at] as LineRow).line.rank : null;
  return Drop(course: course.isEmpty ? null : course, at: at, lines: lines, ranks: ranksBetween(before, after, ranks));
}

/// Where the row at [from] lands, on its own, when it is dropped at [to]: see [dropOf].
({String? course, double rank}) placement(List<CheckRow> rows, int from, int to) {
  final drop = dropOf(rows, from, to);
  return (course: drop.course, rank: drop.ranks.single);
}

/// Ranks for lines let go between two neighbours, in order: spread evenly between the two, one apart past
/// the only one there is, or, with no neighbour at all, the first line's own rank (from [keep], the lines'
/// ranks now) and the rest one apart after it.
List<double> ranksBetween(double? before, double? after, List<double> keep) {
  final n = keep.length;
  if (n == 0) return const [];
  if (before == null && after == null) return [for (var i = 0; i < n; i++) keep.first + i];
  if (before == null) return [for (var i = 0; i < n; i++) after! - n + i];
  if (after == null) return [for (var i = 0; i < n; i++) before + 1 + i];
  return [for (var i = 0; i < n; i++) before + (after - before) * (i + 1) / (n + 1)];
}
