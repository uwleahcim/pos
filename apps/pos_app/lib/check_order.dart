/// The check as the order screen lays it out: a header per course and the lines under each, in rank order,
/// and where lines land when one is held and let go on another row (with any picked up to go along).
library;

import 'api.dart';
import 'coursing.dart';
import 'takeout.dart' show clockTime;

/// A row of the check: a course's header, or a line under one.
sealed class CheckRow {
  const CheckRow();

  /// Tells the rows apart: `course:<id>` for a header, `line:<line id>` for a line.
  String get rowId;
}

class CourseRow extends CheckRow {
  const CourseRow({required this.id, required this.name, required this.state, this.sentMs});

  @override
  String get rowId => 'course:$id';

  /// The course id; empty for lines with no course (or the one group while coursing is off).
  final String id;
  final String name;

  /// held, fired, "N to fire", or empty when nothing is under it.
  final String state;

  /// When the course went to the kitchen: the first of its dishes to be sent ([sentOf]). Null while none
  /// was, and from a hub that does not say when.
  final int? sentMs;
}

class LineRow extends CheckRow {
  const LineRow(this.line, {required this.course, required this.courseState, this.sentMs});

  @override
  String get rowId => 'line:${line.lineId}';

  final Line line;

  /// The course it is listed under (empty for none) and that course's state.
  final String course;
  final String courseState;

  /// When this dish was sent, for a dish that says so itself: one that went a minute or more after its
  /// course's header says ([sentApart]). Null for a dish that went when the header says, and one not sent.
  final int? sentMs;
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
    final sent = sentOf(lines);
    rows.add(CourseRow(id: id, name: name, state: state, sentMs: sent));
    rows.addAll([
      for (final l in lines)
        LineRow(l, course: id, courseState: state, sentMs: l.isActive && sentApart(l.sentMs, sent) ? l.sentMs : null),
    ]);
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

/// When the dishes under one header went to the kitchen: the first of them to be sent, which is the wait
/// a guest asks about. The dishes still on the check count; a header with only voids under it says when
/// the first of those went. Null while nothing was sent, and from a hub that does not say when.
int? sentOf(List<Line> lines) {
  int? first(Iterable<Line> of) {
    int? at;
    for (final line in of) {
      final sent = line.sentMs;
      if (sent != null && (at == null || sent < at)) at = sent;
    }
    return at;
  }

  return first(lines.where((l) => l.isActive)) ?? first(lines);
}

/// Whether a dish sent at [lineMs] says its own time under a header that says [courseMs]: it went a minute
/// or more later (a dish added after the course was sent), so the header's time is not its own.
bool sentApart(int? lineMs, int? courseMs) =>
    lineMs != null && courseMs != null && lineMs - courseMs >= Duration.millisecondsPerMinute;

/// "sent 18:42" for a dish or a course the kitchen got at [sentMs]. With the time it is now ([nowMs], on
/// an open check) it also says how long ago: "sent 18:42, 23 min ago", "just now" within the first minute,
/// hours past two of them ("2 h 5 min ago"). The times are whole minutes on the clock: 18:42 seen at 19:05
/// is 23 minutes, whatever the seconds, so the words add up with the clock on the screen.
String sentWords(int sentMs, {int? nowMs}) {
  final at = 'sent ${clockTime(sentMs)}';
  if (nowMs == null) return at;
  const minute = Duration.millisecondsPerMinute;
  final ago = nowMs ~/ minute - sentMs ~/ minute;
  if (ago < 1) return '$at, just now';
  if (ago < 120) return '$at, $ago min ago';
  final (hours, minutes) = (ago ~/ 60, ago % 60);
  return minutes == 0 ? '$at, $hours h ago' : '$at, $hours h $minutes min ago';
}

/// Where the lines in hand land: the course they go under, the row the first of them takes, and the lines
/// themselves (the one held, then the ones picked up to go along, as stacked) with a rank each.
class Drop {
  const Drop({required this.course, required this.at, required this.lines, required this.ranks});

  /// The course they land in; null for none.
  final String? course;

  /// The row the first of them takes, counted among the rows that stay.
  final int at;

  /// The lines, in the order they are stacked.
  final List<Line> lines;

  /// A rank each, in the same order.
  final List<double> ranks;
}

/// Where the line [held] lands, with the lines [picked] up while it was held, when the stack is let go
/// before the [at]-th of the rows that stay (counted among the rows not in hand): the course whose header
/// is above that room, and ranks between the lines around it there. Let go above the first header, they go
/// to the top of the first course. They land as stacked: the held line first, then the others in the order
/// they were picked up.
Drop dropOf(List<CheckRow> rows, {required String held, List<String> picked = const [], required int at}) {
  final byId = {
    for (final row in rows)
      if (row is LineRow) row.line.lineId: row.line,
  };
  final lines = [
    for (final id in [held, ...picked]) ?byId[id],
  ];
  final moving = {for (final line in lines) line.lineId};
  final kept = [
    for (final row in rows)
      if (row is! LineRow || !moving.contains(row.line.lineId)) row,
  ];
  var slot = at.clamp(0, kept.length);
  final ranks = [for (final line in lines) line.rank];
  if (lines.isEmpty) return Drop(course: null, at: slot, lines: lines, ranks: ranks);
  var head = slot - 1;
  while (head >= 0 && kept[head] is! CourseRow) {
    head--;
  }
  if (head < 0) {
    head = kept.indexWhere((r) => r is CourseRow);
    if (head < 0) return Drop(course: lines.first.course, at: slot, lines: lines, ranks: ranks);
    slot = head + 1;
  }
  final course = (kept[head] as CourseRow).id;
  final before = slot - 1 > head ? (kept[slot - 1] as LineRow).line.rank : null;
  final after = slot < kept.length && kept[slot] is LineRow ? (kept[slot] as LineRow).line.rank : null;
  return Drop(
    course: course.isEmpty ? null : course,
    at: slot,
    lines: lines,
    ranks: ranksBetween(before, after, ranks),
  );
}

/// Where the row at [from] lands, on its own, when it is let go at [to], counted among the other rows.
({String? course, double rank}) placement(List<CheckRow> rows, int from, int to) {
  final drop = dropOf(rows, held: (rows[from] as LineRow).line.lineId, at: to);
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
