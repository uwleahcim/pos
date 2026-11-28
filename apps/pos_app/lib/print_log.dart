/// The print log: every paper the hub made, where it went and how that ended, with the paper itself to look
/// at on the screen and to print again. The hub keeps it (`GET /print/log`, `GET /print/log/paper`,
/// `POST /print/log/reprint`; a manager reads it under Location settings › Printers › Print log) and
/// decides everything in it: what a print is called, where it stands, what the paper says. This file only
/// reads the hub's answers and puts them in words.
library;

import 'dart:math' as math;
import 'dart:ui' show TextRange;

import 'package:flutter/foundation.dart';

/// One thing that happened to a print: a try that failed ([text] says why, [times] how often running), a
/// move to a fallback printer, that it printed, that it was printed again.
@immutable
class PrintEvent {
  const PrintEvent({required this.ms, required this.what, this.text = '', this.times = 1});

  factory PrintEvent.fromJson(Map<String, dynamic> json) => PrintEvent(
    ms: (json['ms'] as num?)?.toInt() ?? 0,
    what: json['what'] as String? ?? '',
    text: json['text'] as String? ?? '',
    times: (json['times'] as num?)?.toInt() ?? 1,
  );

  final int ms;
  final String what;
  final String text;
  final int times;
}

/// What a printer said went wrong, in a restaurant's words; the hub's own words when they are not known.
String printerTrouble(String error) {
  final said = error.toLowerCase();
  if (said.contains('timed out')) return 'the printer did not answer';
  if (said.contains('refused')) return 'the printer refused the connection';
  if (said.contains('no route') || said.contains('unreachable')) return 'the printer cannot be reached on the network';
  if (said.contains('reset') || said.contains('broken pipe')) return 'the printer hung up part way';
  if (said.contains('name or service') || said.contains('getaddrinfo')) return 'the printer\'s address is not known';
  return error;
}

/// One print as the log has it.
@immutable
class PrintEntry {
  const PrintEntry({
    required this.jobId,
    required this.atMs,
    required this.printer,
    required this.name,
    this.address = '',
    this.sort = 'ticket',
    this.kind = '',
    this.title = '',
    this.head = '',
    this.status = 'printed',
    this.printedMs,
    this.printedBy = '',
    this.printedOn = '',
    this.printedName = '',
    this.tries = 0,
    this.error = '',
    this.reprintOf = '',
    this.firstMs,
    this.by = '',
    this.reprints = 0,
    this.events = const [],
    this.found = '',
  });

  factory PrintEntry.fromJson(Map<String, dynamic> json) => PrintEntry(
    jobId: json['job_id'] as String? ?? '',
    atMs: (json['at_ms'] as num?)?.toInt() ?? 0,
    printer: json['printer'] as String? ?? '',
    name: json['name'] as String? ?? '',
    address: json['address'] as String? ?? '',
    sort: json['sort'] as String? ?? 'ticket',
    kind: json['kind'] as String? ?? '',
    title: json['title'] as String? ?? '',
    head: json['head'] as String? ?? '',
    status: json['status'] as String? ?? 'printed',
    printedMs: (json['printed_ms'] as num?)?.toInt(),
    printedBy: json['printed_by'] as String? ?? '',
    printedOn: json['printed_on'] as String? ?? '',
    printedName: json['printed_name'] as String? ?? '',
    tries: (json['tries'] as num?)?.toInt() ?? 0,
    error: json['error'] as String? ?? '',
    reprintOf: json['reprint_of'] as String? ?? '',
    firstMs: (json['first_ms'] as num?)?.toInt(),
    by: json['by'] as String? ?? '',
    reprints: (json['reprints'] as num?)?.toInt() ?? 0,
    events: [
      for (final e in json['events'] as List? ?? const [])
        if (e is Map) PrintEvent.fromJson(e.cast<String, dynamic>()),
    ],
    found: json['found'] as String? ?? '',
  );

  /// The hub's name for the print (its job): what a reprint is asked for by.
  final String jobId;

  /// When the hub sent it to the printer.
  final int atMs;

  /// The printer it was made for: its id, and what its tickets are headed with ("Wok 1 + Fryer").
  final String printer;
  final String name;
  final String address;

  /// What kind of paper: `ticket`, `bill`, `day`, `pack`, `prep`, `labels`; and for a ticket what kind
  /// (`new`, `modify`, `void`, `allergy`, `moved`, `bag`, `notice`).
  final String sort;
  final String kind;

  /// What it is for ("Table 12", "#45 Wu", "Test print"), and the stations a ticket is headed with.
  final String title;
  final String head;

  /// Where it stands: `printed`, `waiting` (not tried yet, or being tried again) or `lost` (never printed,
  /// and the hub that had it stopped).
  final String status;
  final int? printedMs;

  /// Who wrote it to the printer: `hub`, or the screen that carried it there.
  final String printedBy;

  /// Where it printed, and what that printer is called when it is not the one it was made for.
  final String printedOn;
  final String printedName;

  /// The tries that failed, and the last thing that went wrong.
  final int tries;
  final String error;

  /// A reprint: the print it repeats, when that one came out, and who asked.
  final String reprintOf;
  final int? firstMs;
  final String by;

  /// How often it was printed again.
  final int reprints;
  final List<PrintEvent> events;

  /// In a search: the line of the paper the hub found the words on, when the line of the log does not
  /// already show them. Empty otherwise.
  final String found;

  bool get printed => status == 'printed';
  bool get lost => status == 'lost';
  bool get isReprint => reprintOf.isNotEmpty;

  /// It printed at another printer than the one it was made for.
  bool get elsewhere => printed && printedOn.isNotEmpty && printedOn != address;

  /// Something to look at: it has not printed, a try failed, or it came out at another printer.
  bool get trouble => !printed || tries > 0 || elsewhere;

  /// The kind of paper in a word or two.
  String get what => switch (sort) {
    'bill' => 'Bill',
    'day' => 'Day report',
    'pack' => 'Pack sheet',
    'prep' => 'Prep list',
    'labels' => 'Bag labels',
    _ => switch (kind) {
      'modify' => 'Change',
      'void' => 'Void',
      'allergy' => 'Allergy notice',
      'moved' => 'Moved slip',
      'bag' => 'Bag slip',
      'notice' => 'Notice',
      _ => 'Ticket',
    },
  };

  /// What it is, in the line of the log: "Ticket · Table 12", "Reprint · Bill · Table 5 (4 guests)".
  String get line => [if (isReprint) 'Reprint', what, if (title.isNotEmpty && title != what) title].join(' · ');

  /// How it ended, in a sentence.
  String get outcome {
    if (printed) {
      final late = tries > 0 ? ' after ${_tries(tries)}' : '';
      if (elsewhere) {
        final where = printedName.isNotEmpty ? printedName : printedOn;
        return 'Printed at $where instead$late: ${name.isEmpty ? 'its own printer' : name} did not answer';
      }
      final carried = printedBy.isNotEmpty && printedBy != 'hub' ? ' through $printedBy' : '';
      return 'Printed$carried$late';
    }
    if (lost) return 'Never printed: the hub restarted before it came out';
    if (tries == 0) return 'Printing…';
    return 'Not printed yet: ${printerTrouble(error)} (${_tries(tries)}). Still trying';
  }

  static String _tries(int count) => count == 1 ? '1 failed try' : '$count failed tries';
}

/// One step of a paper as the hub wrote it down: a line of text, two columns, a rule, a feed, a cut. A beep
/// and a drawer pulse are steps too; they leave no mark on the paper.
@immutable
class PaperStep {
  const PaperStep({
    required this.kind,
    this.text = '',
    this.right = '',
    this.bold = false,
    this.big = false,
    this.center = false,
    this.invert = false,
    this.count = 1,
  });

  factory PaperStep.fromJson(Map<String, dynamic> json) {
    final kind = json['k'] as String? ?? '';
    return PaperStep(
      kind: kind,
      text: (kind == 'cols' ? json['left'] : json['text']) as String? ?? '',
      right: json['right'] as String? ?? '',
      bold: json['bold'] == true,
      big: json['big'] == true,
      center: json['center'] == true,
      invert: json['invert'] == true,
      count: (json['n'] as num?)?.toInt() ?? 1,
    );
  }

  /// `line`, `cols`, `rule`, `feed`, `cut`, `beep` or `drawer`.
  final String kind;

  /// A line's words, or the left of two columns; [right] is the right one.
  final String text;
  final String right;
  final bool bold;
  final bool big;
  final bool center;

  /// White on a black bar across the paper.
  final bool invert;

  /// How many lines a feed feeds.
  final int count;
}

/// A print with its paper: the pages (an order's bag labels are several, each cut off the next) and the
/// steps of each.
@immutable
class PrintPaper {
  const PrintPaper({required this.entry, required this.pages});

  factory PrintPaper.fromJson(Map<String, dynamic> json) => PrintPaper(
    entry: PrintEntry.fromJson(json),
    pages: [
      for (final page in json['pages'] as List? ?? const [])
        if (page is List)
          [
            for (final step in page)
              if (step is Map) PaperStep.fromJson(step.cast<String, dynamic>()),
          ],
    ],
  );

  final PrintEntry entry;
  final List<List<PaperStep>> pages;
}

/// A printer as the log names it: where a reprint can go.
@immutable
class LogPrinter {
  const LogPrinter({required this.id, required this.name});

  factory LogPrinter.fromJson(Map<String, dynamic> json) =>
      LogPrinter(id: json['id'] as String? ?? '', name: json['name'] as String? ?? '');

  final String id;
  final String name;
}

/// A page of the log, newest first. [next] asks for the page after it; null at the end of the log.
@immutable
class PrintLogPage {
  const PrintLogPage({required this.prints, this.next, this.printers = const [], this.keepsDays = 14, this.types});

  factory PrintLogPage.fromJson(Map<String, dynamic> json) => PrintLogPage(
    prints: [
      for (final p in json['prints'] as List? ?? const [])
        if (p is Map) PrintEntry.fromJson(p.cast<String, dynamic>()),
    ],
    next: json['next'] as String?,
    printers: [
      for (final p in json['printers'] as List? ?? const [])
        if (p is Map) LogPrinter.fromJson(p.cast<String, dynamic>()),
    ],
    keepsDays: (json['keeps_days'] as num?)?.toInt() ?? 14,
    types: json['types'] is List ? [for (final t in json['types'] as List) '$t'] : null,
  );

  final List<PrintEntry> prints;
  final String? next;

  /// The printers as they stand now.
  final List<LogPrinter> printers;

  /// How far back the hub keeps the log.
  final int keepsDays;

  /// The types this restaurant's log can be read by, in the order to offer them ([printTypeName]); a log
  /// that can be read by type can be searched too. Null from a hub older than both.
  final List<String>? types;
}

/// A type of print as the log's filter names it: the hub's `kitchen`, `bar`, `bill`, `reprint`, `other`. A
/// type a newer hub added is offered under the hub's own word for it.
String printTypeName(String type) => switch (type) {
  'kitchen' => 'Kitchen',
  'bar' => 'Bar',
  'bill' => 'Bills',
  'reprint' => 'Reprints',
  'other' => 'Other',
  _ => type.isEmpty ? type : '${type[0].toUpperCase()}${type.substring(1)}',
};

/// The prints of a type, as a sentence says them: "No bar tickets in the last 14 days."
String printTypeThings(String? type) => switch (type) {
  null => 'prints',
  'kitchen' => 'kitchen tickets',
  'bar' => 'bar tickets',
  'bill' => 'bills',
  'reprint' => 'reprints',
  'other' => 'other prints',
  _ => 'prints of this kind',
};

/// A search as the hub reads it: the words as typed, one space between them.
String printSearch(String typed) => typed.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).join(' ');

/// A search as its words are found on a paper, the way the hub finds them (`pattern_of` in
/// `pos.printing.log`): the words as they were typed, in either case, on one line, with whatever room the
/// paper leaves between them; a number at either end is a whole number there, so "table 1" is not found on
/// table 12, nor "#45" on order 451. The hub says which prints have the words; this says where on a line
/// they are, for a screen to mark them. The two are held to the same cases by
/// `backend/tests/printing/search_cases.json`.
@immutable
class PrintFind {
  const PrintFind._(this.q, this._words);

  /// The search for what was typed; null when nothing was (spaces are no search).
  static PrintFind? of(String typed) {
    final q = printSearch(typed);
    if (q.isEmpty) return null;
    // what was typed is letters, never a pattern
    final words = [for (final word in q.split(' ')) word.replaceAllMapped(_signs, (sign) => '\\${sign[0]}')];
    final before = _digit(q.codeUnitAt(0)) ? '(?<![0-9])' : '';
    final after = _digit(q.codeUnitAt(q.length - 1)) ? '(?![0-9])' : '';
    return PrintFind._(q, RegExp('$before${words.join(r'\s+')}$after', caseSensitive: false, unicode: true));
  }

  static final _signs = RegExp(r'[\\^$.|?*+()\[\]{}]');

  static bool _digit(int unit) => unit >= 0x30 && unit <= 0x39;

  /// The search, as the hub was asked it.
  final String q;
  final RegExp _words;

  /// Where on a line the words are: every place, first to last; nowhere is an empty list.
  List<TextRange> on(String line) => [
    for (final hit in _words.allMatches(line)) TextRange(start: hit.start, end: hit.end),
  ];

  /// Where they are on a line of two columns, which the hub reads as one line: the places on the left
  /// side and the ones on the right; words that begin on the left and end on the right are on both.
  (List<TextRange>, List<TextRange>) across(String left, String right) {
    final from = left.length + 2; // where the right side begins in the line as it is read
    final onLeft = <TextRange>[], onRight = <TextRange>[];
    for (final hit in _words.allMatches('$left  $right')) {
      if (hit.start < left.length) onLeft.add(TextRange(start: hit.start, end: math.min(hit.end, left.length)));
      if (hit.end > from) onRight.add(TextRange(start: math.max(hit.start, from) - from, end: hit.end - from));
    }
    return (onLeft, onRight);
  }

  @override
  bool operator ==(Object other) => other is PrintFind && other.q == q;

  @override
  int get hashCode => q.hashCode;
}
