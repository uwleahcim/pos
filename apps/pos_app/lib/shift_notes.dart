import 'takeout.dart' show clockTime;

/// Notes for the shift and the manager's log, as the hub answers them (docs/shift-notes.md).
///
/// A note for the shift is what a manager wants everybody to know before they start: the specials, what is
/// out. Each person sees a note once, after signing in; the hub keeps who has seen which. The manager's log
/// is the managers' own book, each entry under one subject. The hub makes every rule; this is its answers
/// read into names, and the words the screens say about them.

String _s(Object? value, [String or = '']) => value is String ? value : or;
int _i(Object? value) => value is num ? value.toInt() : 0;
int? _ms(Object? value) => value is num ? value.toInt() : null;
List<Map<String, dynamic>> _rows(Object? value) => [
  if (value is List)
    for (final row in value)
      if (row is Map) row.cast<String, dynamic>(),
];

/// Somebody who has seen a note, and when.
class NoteSeen {
  const NoteSeen({required this.staffId, required this.name, required this.atMs});

  factory NoteSeen.fromJson(Map<String, dynamic> json) =>
      NoteSeen(staffId: _s(json['staff_id']), name: _s(json['name']), atMs: _i(json['at_ms']));

  final String staffId;
  final String name;
  final int atMs;
}

/// A note for the shift.
class ShiftNote {
  const ShiftNote({
    required this.id,
    required this.text,
    this.by = '',
    this.atMs = 0,
    this.untilMs,
    this.editedMs,
    this.seen = false,
    this.seenBy = const [],
    this.waiting = const [],
    this.endedMs,
    this.removedBy = '',
    this.seenCount = 0,
  });

  factory ShiftNote.fromJson(Map<String, dynamic> json) {
    final seen = json['seen'];
    return ShiftNote(
      id: _s(json['id']),
      text: _s(json['text']),
      by: _s(json['by']),
      atMs: _i(json['at_ms']),
      untilMs: _ms(json['until_ms']),
      editedMs: _ms(json['edited_ms']),
      seen: seen == true,
      seenBy: [for (final row in _rows(seen)) NoteSeen.fromJson(row)],
      waiting: [
        if (json['waiting'] is List)
          for (final name in json['waiting'] as List)
            if (name is String) name,
      ],
      endedMs: _ms(json['ended_ms']),
      removedBy: _s(json['removed_by']),
      seenCount: _i(json['seen_count']),
    );
  }

  final String id;
  final String text;

  /// The manager who wrote it.
  final String by;
  final int atMs;

  /// When it comes down by itself (the end of its night); null stays until a manager takes it down.
  final int? untilMs;

  /// When its words were last changed, which showed it to everybody again.
  final int? editedMs;

  /// Whether the person the notes were read for has seen it (`GET /notes`).
  final bool seen;

  /// On a manager's list (`GET /notes/board`): who has seen it, the first first, and who has not yet.
  final List<NoteSeen> seenBy;
  final List<String> waiting;

  /// On a manager's list, for a note that has come down: when, which manager took it down (nobody when its
  /// night ended), and how many people had seen it.
  final int? endedMs;
  final String removedBy;
  final int seenCount;

  /// It stays up until a manager takes it down.
  bool get stays => untilMs == null;

  /// How long it is up, as the hub names the two: `tonight` or `stays`.
  String get lasts => stays ? 'stays' : 'tonight';
}

/// The notes that are up, for one person (`GET /notes?staff_id=`).
class MyNotes {
  const MyNotes({this.notes = const []});

  factory MyNotes.fromJson(Map<String, dynamic> json) =>
      MyNotes(notes: [for (final row in _rows(json['notes'])) ShiftNote.fromJson(row)]);

  /// The newest first.
  final List<ShiftNote> notes;

  /// The ones this person has not seen yet.
  List<ShiftNote> get unseen => [
    for (final note in notes)
      if (!note.seen) note,
  ];
}

/// A manager's list of the notes (`GET /notes/board`).
class NotesBoard {
  const NotesBoard({
    this.notes = const [],
    this.earlier = const [],
    this.staff = 0,
    this.most = 12,
    this.textMax = 500,
    this.earlierDays = 14,
  });

  factory NotesBoard.fromJson(Map<String, dynamic> json) => NotesBoard(
    notes: [for (final row in _rows(json['notes'])) ShiftNote.fromJson(row)],
    earlier: [for (final row in _rows(json['earlier'])) ShiftNote.fromJson(row)],
    staff: _i(json['staff']),
    most: json['most'] is num ? _i(json['most']) : 12,
    textMax: json['text_max'] is num ? _i(json['text_max']) : 500,
    earlierDays: json['earlier_days'] is num ? _i(json['earlier_days']) : 14,
  );

  /// The notes that are up, the newest first, each with who has seen it.
  final List<ShiftNote> notes;

  /// The ones that came down in the last [earlierDays] days, the latest to come down first.
  final List<ShiftNote> earlier;

  /// How many people work here: "seen by 3 of 8".
  final int staff;

  /// The most notes up at once, and the most letters of one.
  final int most;
  final int textMax;
  final int earlierDays;
}

/// What an entry of the manager's log is about, with how many entries it has.
class LogSubject {
  const LogSubject({required this.id, required this.name, this.count = 0});

  factory LogSubject.fromJson(Map<String, dynamic> json) =>
      LogSubject(id: _s(json['id']), name: _s(json['name']), count: _i(json['count']));

  final String id;
  final String name;
  final int count;
}

/// One entry of the manager's log.
class LogEntry {
  const LogEntry({
    required this.id,
    required this.subject,
    this.subjectName = '',
    required this.text,
    this.by = '',
    this.atMs = 0,
    this.day = '',
    this.struckMs,
    this.struckBy = '',
  });

  factory LogEntry.fromJson(Map<String, dynamic> json) => LogEntry(
    id: _s(json['id']),
    subject: _s(json['subject']),
    subjectName: _s(json['subject_name'], _s(json['subject'])),
    text: _s(json['text']),
    by: _s(json['by']),
    atMs: _i(json['at_ms']),
    day: _s(json['day']),
    struckMs: _ms(json['struck_ms']),
    struckBy: _s(json['struck_by']),
  );

  final String id;
  final String subject;
  final String subjectName;
  final String text;
  final String by;
  final int atMs;

  /// The day of service it was written in ("2026-11-16"): an entry after midnight is still that night's.
  final String day;

  /// When it was struck out, and by whom. A struck entry stays in the log, readable.
  final int? struckMs;
  final String struckBy;

  bool get struck => struckMs != null;
}

/// A reading of the manager's log (`GET /logbook`).
class Logbook {
  const Logbook({
    this.subjects = const [],
    this.count = 0,
    this.entries = const [],
    this.more = false,
    this.textMax = 2000,
  });

  factory Logbook.fromJson(Map<String, dynamic> json) => Logbook(
    subjects: [for (final row in _rows(json['subjects'])) LogSubject.fromJson(row)],
    count: _i(json['count']),
    entries: [for (final row in _rows(json['entries'])) LogEntry.fromJson(row)],
    more: json['more'] == true,
    textMax: json['text_max'] is num ? _i(json['text_max']) : 2000,
  );

  /// Every subject in the order the hub offers them, with how many entries each has (of those the search
  /// finds; the struck ones are not counted).
  final List<LogSubject> subjects;

  /// The entries under all the subjects together.
  final int count;

  /// The entries read, the newest first.
  final List<LogEntry> entries;

  /// Older entries wait to be read: ask again with the last one's id.
  final bool more;
  final int textMax;
}

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// A day as the notes and the log say it: "today", "yesterday", or "Sat Nov 14" (with its year when that
/// is not this one).
String dayWords(DateTime day, DateTime now) {
  final days = DateTime(now.year, now.month, now.day).difference(DateTime(day.year, day.month, day.day)).inDays;
  if (days == 0) return 'today';
  if (days == 1) return 'yesterday';
  final words = '${_weekdays[day.weekday - 1]} ${_months[day.month - 1]} ${day.day}';
  return day.year == now.year ? words : '$words, ${day.year}';
}

/// When something was written or seen: "today 16:05", "yesterday 22:10", "Sat Nov 14, 16:05".
String whenWords(int atMs, DateTime now) {
  final at = DateTime.fromMillisecondsSinceEpoch(atMs);
  final day = dayWords(at, now);
  final time = clockTime(atMs);
  return day == 'today' || day == 'yesterday' ? '$day $time' : '$day, $time';
}

/// How long a note is up, under it: "For tonight" or "Until taken down".
String lastsWords(ShiftNote note) => note.stays ? 'Until taken down' : 'For tonight';

/// Under a note: who wrote it and when, and that its words changed since.
String noteByWords(ShiftNote note, DateTime now) => [
  [if (note.by.isNotEmpty) note.by, whenWords(note.atMs, now)].join(', '),
  if (note.editedMs != null) 'changed ${whenWords(note.editedMs!, now)}',
].join(' · ');

/// "Seen by 3 of 8", or "Seen by everyone" once nobody is waiting.
String seenWords(ShiftNote note, int staff) {
  if (note.waiting.isEmpty && note.seenBy.isNotEmpty) return 'Seen by everyone';
  final of = staff > 0 ? staff : note.seenBy.length + note.waiting.length;
  return 'Seen by ${note.seenBy.length} of $of';
}

/// How a note that has come down ended: "Taken down by Mike, today 19:00" or "Came down yesterday 04:00".
String endedWords(ShiftNote note, DateTime now) {
  final ended = note.endedMs;
  final when = ended == null ? '' : whenWords(ended, now);
  if (note.removedBy.isNotEmpty) return ['Taken down by ${note.removedBy}', if (when.isNotEmpty) when].join(', ');
  return when.isEmpty ? 'Came down' : 'Came down $when';
}

/// A day of the log as its heading: "Today", "Yesterday", "Sat Nov 14". [day] is the hub's "2026-11-14".
String logDayWords(String day, DateTime now) {
  final parsed = DateTime.tryParse(day);
  if (parsed == null) return day;
  final words = dayWords(parsed, now);
  return words.substring(0, 1).toUpperCase() + words.substring(1);
}
