import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/outbox.dart';
import 'package:pos_app/camera.dart';
import 'package:pos_app/photos.dart';
import 'package:pos_app/print_log.dart';
import 'package:pos_app/queue_store.dart';
import 'package:pos_app/screens/paper_view.dart';
import 'package:pos_app/screens/print_log_screen.dart';
import 'package:pos_app/screens/printers_screen.dart';
import 'package:pos_app/session.dart';
import 'package:pos_app/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'hub.dart';

/// Thursday evening, November 26: what "Today" and "Yesterday" are counted from.
DateTime now() => DateTime(2026, 11, 26, 20, 30);

int at(int day, int hour, int minute) => DateTime(2026, 11, day, hour, minute).millisecondsSinceEpoch;

/// A print as the hub's log lists it.
Map<String, dynamic> printed(
  String job, {
  required int atMs,
  String printer = 'wok',
  String name = 'Wok',
  String address = '10.27.1.14',
  String sort = 'ticket',
  String kind = 'new',
  String title = 'Table 12',
  String status = 'printed',
  String? printedOn,
  String printedName = '',
  String printedBy = 'hub',
  int tries = 0,
  String error = '',
  String reprintOf = '',
  String by = '',
  int reprints = 0,
  List<Map<String, dynamic>> events = const [],
  List<String> places = const [],
}) => {
  'job_id': job,
  'at_ms': atMs,
  'printer': printer,
  'name': name,
  'address': address,
  'sort': sort,
  'kind': kind,
  'title': title,
  'head': name,
  'status': status,
  'printed_ms': status == 'printed' ? atMs + 2000 : null,
  'printed_by': status == 'printed' ? printedBy : '',
  'printed_on': status == 'printed' ? (printedOn ?? address) : '',
  'printed_name': printedName,
  'tries': tries,
  'error': error,
  'reprint_of': reprintOf,
  'first_ms': null,
  'by': by,
  'reprints': reprints,
  'events': events,
  'places': places,
};

/// A kitchen ticket's paper, as the hub wrote its steps down.
List<List<Map<String, dynamic>>> ticketPaper(String table, List<String> dishes) => [
  [
    {'k': 'beep', 'n': 1},
    {'k': 'line', 'text': 'WOK', 'bold': true, 'big': true, 'center': true},
    {'k': 'cols', 'left': table, 'right': '7:05 PM', 'bold': true},
    {'k': 'rule'},
    for (final dish in dishes) {'k': 'line', 'text': dish, 'big': true},
    {'k': 'line', 'text': 'ALLERGY: PEANUT', 'bold': true, 'invert': true},
    {'k': 'feed', 'n': 2},
    {'k': 'cut'},
  ],
];

const wokPrinter = {'id': 'wok', 'name': 'Wok', 'address': '10.27.1.14'};
const barPrinter = {'id': 'bar', 'name': 'Bar', 'address': '10.27.1.166'};

/// An evening's log: a ticket that printed, one that went to the bar's printer, a bill, one still being
/// tried, one lost when the hub restarted, and older ones on the days before.
void evening(Hub hub) {
  hub.logPrinters = [wokPrinter, barPrinter];
  hub.printLog = [
    printed('t5', atMs: at(26, 19, 40), status: 'lost', title: 'Table 3', tries: 4, error: 'timed out'),
    printed(
      't4',
      atMs: at(26, 19, 31),
      status: 'waiting',
      title: '#45 Wu',
      tries: 3,
      error: '[Errno 113] No route to host',
      events: [
        {'ms': at(26, 19, 31), 'what': 'failed', 'text': '[Errno 113] No route to host', 'times': 3},
      ],
    ),
    printed('b1', atMs: at(26, 19, 20), printer: 'bar', name: 'Bar', address: '10.27.1.166', sort: 'bill', kind: ''),
    printed(
      't2',
      atMs: at(26, 19, 12),
      title: 'Table 7',
      printedOn: '10.27.1.166',
      printedName: 'Bar',
      tries: 2,
      error: 'timed out',
      events: [
        {'ms': at(26, 19, 12), 'what': 'failed', 'text': 'timed out', 'times': 2},
        {'ms': at(26, 19, 13), 'what': 'moved', 'text': 'Bar'},
        {'ms': at(26, 19, 13), 'what': 'printed', 'text': 'Bar'},
      ],
    ),
    printed(
      't1',
      atMs: at(26, 19, 5),
      events: [
        {'ms': at(26, 19, 5), 'what': 'printed', 'text': ''},
      ],
    ),
    printed('y1', atMs: at(25, 18, 0), kind: 'void', title: 'Table 2'),
    printed('o1', atMs: at(24, 12, 30), sort: 'day', kind: '', title: 'Day report'),
  ];
  for (final p in hub.printLog!) {
    hub.papers[p['job_id'] as String] = ticketPaper(p['title'] as String, ['1 x General Tso', '2 x Egg Roll']);
  }
}

/// The same evening as a hub that reads its log by type has it: the tickets are the kitchen's, the bar made
/// one for table 9 (two beers and a mai tai) and Mike had it printed again.
void night(Hub hub) {
  evening(hub);
  for (final p in hub.printLog!) {
    if (p['sort'] == 'ticket') p['places'] = ['kitchen'];
  }
  hub.printLog!.insertAll(0, [
    printed(
      'r1',
      atMs: at(26, 20, 10),
      printer: 'bar',
      name: 'Bar',
      address: '10.27.1.166',
      title: 'Table 9',
      reprintOf: 'd1',
      by: 'Mike',
      places: ['bar'],
    ),
    printed(
      'd1',
      atMs: at(26, 20, 0),
      printer: 'bar',
      name: 'Bar',
      address: '10.27.1.166',
      title: 'Table 9',
      reprints: 1,
      places: ['bar'],
    ),
  ]);
  for (final job in ['r1', 'd1']) {
    hub.papers[job] = ticketPaper('Table 9', ['2 x Tsingtao', '1 x Mai Tai (no ice, a slice of lime on the side)']);
  }
}

/// The prints on the screen, top to bottom.
List<String> listed(WidgetTester tester) => [
  for (final row in tester.widgetList<InkWell>(
    find.byWidgetPredicate((w) => w is InkWell && w.key is ValueKey<String> && '${w.key}'.contains('print-row:')),
  ))
    (row.key! as ValueKey<String>).value.split(':').last,
];

bool picked(WidgetTester tester, String type) =>
    tester.widget<ChoiceChip>(find.byKey(ValueKey('log-type:$type'))).selected;

Future<void> search(WidgetTester tester, String words) async {
  await tester.enterText(find.byKey(const ValueKey('log-search-box')), words);
  await tester.pump(const Duration(milliseconds: 400)); // the typing stopped
  await tester.pumpAndSettle();
}

Future<Terminal> pumpLog(
  WidgetTester tester, {
  void Function(Hub hub) arrange = evening,
  String? printer,
  Size size = const Size(700, 3000),
  double textScale = 1,
  ThemeData? theme,
}) async {
  final t = await terminal(tester);
  tester.view.physicalSize = size;
  arrange(t.hub);
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: PrintLogScreen(api: t.api, token: 'tok-admin', printer: printer, now: now),
    ),
  );
  await tester.pumpAndSettle();
  return t;
}

String said(WidgetTester tester, String key) => tester.widget<Text>(find.byKey(ValueKey(key))).data!;

/// The words of a print's line, with its time.
String line(WidgetTester tester, String job) =>
    tester.widget<Text>(find.byKey(ValueKey('print-line:$job'))).textSpan!.toPlainText();

/// The words a search has marked in [within], top to bottom: on a paper, in a line of the log.
List<String> marked(WidgetTester tester, Finder within) => [
  for (final text in tester.widgetList<Text>(find.descendant(of: within, matching: find.byType(Text), matchRoot: true)))
    if (text.textSpan case final TextSpan span)
      for (final part in span.children ?? const <InlineSpan>[])
        if (part is TextSpan && part.style?.backgroundColor == PaperView.marker) part.text!,
];

void main() {
  group('the words of the log', () {
    PrintEntry entry(Map<String, dynamic> json) => PrintEntry.fromJson(json);

    test('a print is named by its kind and what it is for', () {
      expect(entry(printed('a', atMs: 1)).line, 'Ticket · Table 12');
      expect(entry(printed('a', atMs: 1, kind: 'void')).line, 'Void · Table 12');
      expect(entry(printed('a', atMs: 1, kind: 'allergy', title: 'Table 4')).line, 'Allergy notice · Table 4');
      expect(
        entry(printed('a', atMs: 1, sort: 'bill', kind: '', title: 'Table 5 (4 guests)')).line,
        startsWith('Bill'),
      );
      expect(entry(printed('a', atMs: 1, sort: 'labels', kind: '', title: '#45 Wu')).line, 'Bag labels · #45 Wu');
      // a paper whose title is its kind says it once
      expect(entry(printed('a', atMs: 1, sort: 'day', kind: '', title: 'Day report')).line, 'Day report');
      expect(entry(printed('a', atMs: 1, reprintOf: 'first')).line, 'Reprint · Ticket · Table 12');
    });

    test('how it ended reads as a sentence', () {
      expect(entry(printed('a', atMs: 1)).outcome, 'Printed');
      expect(entry(printed('a', atMs: 1, printedBy: 'mac2')).outcome, 'Printed through mac2');
      expect(entry(printed('a', atMs: 1, tries: 1)).outcome, 'Printed after 1 failed try');
      expect(
        entry(printed('a', atMs: 1, printedOn: '10.27.1.166', printedName: 'Bar', tries: 2)).outcome,
        'Printed at Bar instead after 2 failed tries: Wok did not answer',
      );
      expect(entry(printed('a', atMs: 1, status: 'waiting')).outcome, 'Printing…');
      expect(
        entry(printed('a', atMs: 1, status: 'waiting', tries: 3, error: 'timed out')).outcome,
        'Not printed yet: the printer did not answer (3 failed tries). Still trying',
      );
      expect(entry(printed('a', atMs: 1, status: 'lost', tries: 9)).outcome, startsWith('Never printed'));
    });

    test('a print that printed first time at its own printer is no trouble; the rest are', () {
      expect(entry(printed('a', atMs: 1)).trouble, isFalse);
      expect(entry(printed('a', atMs: 1, tries: 1)).trouble, isTrue);
      expect(entry(printed('a', atMs: 1, printedOn: '10.27.1.166')).trouble, isTrue);
      expect(entry(printed('a', atMs: 1, status: 'waiting')).trouble, isTrue);
      expect(entry(printed('a', atMs: 1, status: 'lost')).trouble, isTrue);
    });

    test('what a printer said is put in a restaurant\'s words, and left alone when it is not known', () {
      expect(printerTrouble('[Errno 111] Connection refused'), 'the printer refused the connection');
      expect(printerTrouble('[Errno 113] No route to host'), 'the printer cannot be reached on the network');
      expect(printerTrouble('[Errno 104] Connection reset by peer'), 'the printer hung up part way');
      expect(printerTrouble('paper jam'), 'paper jam');
    });

    test('a paper is read step by step, and what is not a step is left out', () {
      final paper = PrintPaper.fromJson({
        ...printed('a', atMs: 1),
        'pages': [
          [
            {'k': 'line', 'text': 'WOK', 'big': true, 'center': true},
            {'k': 'cols', 'left': 'Table 12', 'right': '7:05 PM'},
            {'k': 'feed', 'n': 3},
            'nonsense',
          ],
          'nonsense',
        ],
      });
      expect(paper.entry.jobId, 'a');
      expect(paper.pages, hasLength(1));
      final [head, cols, feed] = paper.pages.single;
      expect((head.kind, head.text, head.big, head.center, head.invert), ('line', 'WOK', true, true, false));
      expect((cols.kind, cols.text, cols.right), ('cols', 'Table 12', '7:05 PM'));
      expect((feed.kind, feed.count), ('feed', 3));
    });
  });

  testWidgets('the log lists the prints by day, newest first, each with its printer and how it ended', (tester) async {
    final t = await pumpLog(tester);
    expect(t.hub.printLogAuth, 'Bearer tok-admin');
    expect(t.hub.printLogAsks.first, {'limit': '50'}); // every printer's, the newest

    expect(find.text('Today'), findsOneWidget);
    expect(find.text('Yesterday'), findsOneWidget);
    expect(find.text('Tue Nov 24'), findsOneWidget);
    expect(line(tester, 't1'), '7:05 PM  Ticket · Table 12');
    expect(said(tester, 'print-outcome:t1'), 'Wok · Printed');
    expect(said(tester, 'print-outcome:t2'), 'Wok · Printed at Bar instead after 2 failed tries: Wok did not answer');
    expect(line(tester, 'b1'), '7:20 PM  Bill · Table 12');
    expect(said(tester, 'print-outcome:b1'), 'Bar · Printed');
    expect(
      said(tester, 'print-outcome:t4'),
      'Wok · Not printed yet: the printer cannot be reached on the network (3 failed tries). Still trying',
    );
    expect(said(tester, 'print-outcome:t5'), 'Wok · Never printed: the hub restarted before it came out');
    expect(line(tester, 'y1'), '6:00 PM  Void · Table 2');
    expect(line(tester, 'o1'), '12:30 PM  Day report');
    expect(said(tester, 'log-end'), 'The log keeps the last 14 days.');

    // newest at the top
    final tops = [
      for (final job in ['t5', 't4', 'b1', 't2', 't1', 'y1', 'o1'])
        tester.getTopLeft(find.byKey(ValueKey('print:$job'))).dy,
    ];
    expect(tops, [...tops]..sort());
    // no paper is read until one is asked for
    expect(t.hub.paperAsks, isEmpty);
    expect(find.byType(PaperView), findsNothing);
    await stop(tester);
  });

  testWidgets('a tap on a print shows its paper as it came out, and what happened to it', (tester) async {
    final t = await pumpLog(tester);
    await tester.tap(find.byKey(const ValueKey('print-row:t2')));
    await tester.pumpAndSettle();
    expect(t.hub.paperAsks, ['t2']);
    expect(t.hub.printLogAuth, 'Bearer tok-admin');

    final paper = find.byKey(const ValueKey('paper:t2'));
    expect(paper, findsOneWidget);
    for (final words in ['WOK', 'Table 7', '7:05 PM', '1 x General Tso', '2 x Egg Roll', 'ALLERGY: PEANUT']) {
      expect(
        find.descendant(of: paper, matching: find.text(words)),
        findsOneWidget,
        reason: words,
      );
    }
    final story = find.byKey(const ValueKey('print-story:t2'));
    for (final words in [
      'Sent to Wok (10.27.1.14)',
      'Did not print: the printer did not answer (timed out), 2 times',
      'Passed on to Bar',
      'Printed at Bar',
    ]) {
      expect(
        find.descendant(of: story, matching: find.text(words)),
        findsOneWidget,
        reason: words,
      );
    }
    expect(said(tester, 'reprint-note:t2'), 'The paper comes out headed REPRINT.');

    // the same paper is not read twice: closed and opened again, and after the log is read again
    await tester.tap(find.byKey(const ValueKey('print-row:t2')));
    await tester.pumpAndSettle();
    expect(paper, findsNothing);
    await tester.tap(find.byKey(const ValueKey('print-row:t2')));
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(paper, findsOneWidget);
    expect(t.hub.paperAsks, ['t2']);

    // one that never printed says so, and can be printed again
    await tester.tap(find.byKey(const ValueKey('print-row:t5')));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('print-story:t5')),
        matching: find.textContaining('so it never came out. Reprint it'),
      ),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('reprint:t5')), findsOneWidget);
    await stop(tester);
  });

  testWidgets('Reprint prints the paper again, and the log lists the reprint', (tester) async {
    final t = await pumpLog(tester);
    await tester.tap(find.byKey(const ValueKey('print-row:t1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reprint:t1')));
    await tester.pumpAndSettle();

    expect(t.hub.reprints, [
      {'job': 't1'},
    ]); // at its own printer: the hub knows which
    expect(t.hub.printLogAuth, 'Bearer tok-admin');
    expect(find.text('Reprint sent to Wok'), findsOneWidget);
    expect(line(tester, 'reprint:1'), endsWith('Reprint · Ticket · Table 12'));
    expect(said(tester, 'print-outcome:reprint:1'), 'Wok · Printing…');

    // the reprint's own paper is headed REPRINT, and says who asked
    await tester.tap(find.byKey(const ValueKey('print-row:reprint:1')));
    await tester.pumpAndSettle();
    final paper = find.byKey(const ValueKey('paper:reprint:1'));
    expect(find.descendant(of: paper, matching: find.text('*** REPRINT ***')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('print-story:reprint:1')),
        matching: find.text('A reprint asked for by Mike of the paper from 7:05 PM.'),
      ),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 5)); // the words at the bottom go
    await stop(tester);
  });

  testWidgets('a paper can be reprinted at another printer', (tester) async {
    final t = await pumpLog(tester);
    await tester.tap(find.byKey(const ValueKey('print-row:t4')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reprint-at:t4')));
    await tester.pumpAndSettle();
    expect(find.text('Reprint at Bar'), findsOneWidget);
    expect(find.text('Reprint at Wok'), findsNothing); // its own printer is the button beside it
    await tester.tap(find.byKey(const ValueKey('reprint-at:t4:bar')));
    await tester.pumpAndSettle();
    expect(t.hub.reprints, [
      {'job': 't4', 'printer': 'bar'},
    ]);
    expect(find.text('Reprint sent to Bar'), findsOneWidget);
    expect(said(tester, 'print-outcome:reprint:1'), 'Bar · Printing…');
    await tester.pump(const Duration(seconds: 5));
    await stop(tester);
  });

  testWidgets('a reprint the hub cannot make says why, in the hub\'s words, and nothing is listed', (tester) async {
    final t = await pumpLog(tester);
    await tester.tap(find.byKey(const ValueKey('print-row:t1')));
    await tester.pumpAndSettle();
    t.hub.refuseReprint = 'Its printer is not set up any more. Choose another one.';
    await tester.tap(find.byKey(const ValueKey('reprint:t1')));
    await tester.pumpAndSettle();
    expect(said(tester, 'reprint-note:t1'), 'Its printer is not set up any more. Choose another one.');
    expect(find.byKey(const ValueKey('print:reprint:1')), findsNothing);
    expect(find.textContaining('Reprint sent'), findsNothing);

    // the hub gone: nothing was printed, and the button is there to press again
    t.hub
      ..refuseReprint = null
      ..down = true;
    await tester.tap(find.byKey(const ValueKey('reprint:t1')));
    await tester.pumpAndSettle();
    expect(said(tester, 'reprint-note:t1'), 'The hub is not answering, so nothing was printed.');
    t.hub.down = false;
    await tester.tap(find.byKey(const ValueKey('reprint:t1')));
    await tester.pumpAndSettle();
    expect(find.text('Reprint sent to Wok'), findsOneWidget);
    expect(said(tester, 'reprint-note:t1'), 'The paper comes out headed REPRINT.');
    await tester.pump(const Duration(seconds: 5));
    await stop(tester);
  });

  testWidgets('Expand all opens every print as a tap does, and Collapse all closes every one', (tester) async {
    final t = await pumpLog(tester, size: const Size(700, 9000));
    final all = find.byKey(const ValueKey('log-all'));
    expect(find.descendant(of: all, matching: find.text('Expand all')), findsOneWidget);
    await tester.tap(all);
    await tester.pumpAndSettle();
    expect(t.hub.paperAsks.toSet(), {'t5', 't4', 'b1', 't2', 't1', 'y1', 'o1'});
    expect(find.byType(PaperView), findsNWidgets(7));
    // each as a tap opens it: its paper, what happened to it, and Reprint under it
    expect(find.byKey(const ValueKey('print-story:b1')), findsOneWidget);
    expect(find.byKey(const ValueKey('reprint:b1')), findsOneWidget);
    expect(find.descendant(of: all, matching: find.text('Collapse all')), findsOneWidget);
    expect(find.text('Expand all'), findsNothing);

    // a tap closes that one alone, and another opens it again
    await tester.tap(find.byKey(const ValueKey('print-row:b1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('paper:b1')), findsNothing);
    expect(find.byType(PaperView), findsNWidgets(6));
    await tester.tap(find.byKey(const ValueKey('print-row:b1')));
    await tester.pumpAndSettle();
    expect(find.byType(PaperView), findsNWidgets(7));

    // every one is closed, the one closed by hand and the rest
    await tester.tap(find.byKey(const ValueKey('print-row:t1')));
    await tester.pumpAndSettle();
    await tester.tap(all);
    await tester.pumpAndSettle();
    expect(find.byType(PaperView), findsNothing);
    expect(find.descendant(of: all, matching: find.text('Expand all')), findsOneWidget);

    // one opened by hand does not make the button "Collapse all"; every one is opened, and then closed with it
    await tester.tap(find.byKey(const ValueKey('print-row:t2')));
    await tester.pumpAndSettle();
    expect(find.byType(PaperView), findsOneWidget);
    expect(find.descendant(of: all, matching: find.text('Expand all')), findsOneWidget);
    await tester.tap(all);
    await tester.pumpAndSettle();
    expect(find.byType(PaperView), findsNWidgets(7));
    await tester.tap(all);
    await tester.pumpAndSettle();
    expect(find.byType(PaperView), findsNothing);
    expect(t.hub.paperAsks.length, 7); // through all of it each paper was read once
    await stop(tester);
  });

  testWidgets('with every print open the list is still built a screenful at a time, and the papers are read ahead', (
    tester,
  ) async {
    final t = await pumpLog(
      tester,
      size: const Size(700, 900),
      arrange: (hub) {
        hub.logPrinters = [wokPrinter];
        hub.printLog = [
          for (var n = 70; n > 0; n--)
            printed('j${n.toString().padLeft(2, '0')}', atMs: at(26, 12, 0) + n * 60000, title: 'Table $n'),
        ];
        for (final p in hub.printLog!) {
          hub.papers[p['job_id'] as String] = ticketPaper(p['title'] as String, ['1 x General Tso', '2 x Egg Roll']);
        }
      },
    );
    await tester.tap(find.byKey(const ValueKey('log-all')));
    await tester.pumpAndSettle();
    // the prints on the screen are built, not the fifty listed
    expect(find.byKey(const ValueKey('paper:j70')), findsOneWidget);
    expect(find.byType(PaperView).evaluate().length, lessThan(8));
    // their papers were all read meanwhile, for the scrolling: each once, four at a time, first to last
    expect(t.hub.paperAsks.length, 50);
    expect(t.hub.paperAsks.toSet().length, 50);
    expect(t.hub.papersAtOnce, 4);
    expect(t.hub.paperAsks.sublist(8), [for (var n = 62; n > 20; n--) 'j$n']);

    // scrolled to, a print comes with its paper on it: nothing is asked for on the way down
    final list = find.descendant(of: find.byKey(const ValueKey('log-list')), matching: find.byType(Scrollable));
    await tester.scrollUntilVisible(find.byKey(const ValueKey('log-more')), 2000, scrollable: list, maxScrolls: 100);
    expect(find.byKey(const ValueKey('paper:j21')), findsOneWidget);
    expect(find.byType(PaperView).evaluate().length, lessThan(8));
    expect(t.hub.paperAsks.length, 50);

    // the older prints are open as they come, and their papers read
    await tester.tap(find.byKey(const ValueKey('log-more')));
    await tester.pumpAndSettle();
    expect(t.hub.paperAsks.length, 70);
    expect(t.hub.papersAtOnce, 4);
    await tester.scrollUntilVisible(find.byKey(const ValueKey('log-end')), 2000, scrollable: list, maxScrolls: 100);
    expect(find.byKey(const ValueKey('paper:j01')), findsOneWidget);
    expect(t.hub.paperAsks.length, 70);
    await stop(tester);
  });

  testWidgets('a paper that comes draws its own print again, not the screen, and a paper is drawn once', (
    tester,
  ) async {
    final t = await pumpLog(tester, size: const Size(700, 9000));
    t.hub.papersHeld = Completer<void>();
    await tester.tap(find.byKey(const ValueKey('log-all')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100)); // every print is open and waits for its paper
    expect(find.byType(PaperView), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNWidgets(7));

    final drawn = <String>[];
    debugOnRebuildDirtyWidget = (element, _) => drawn.add('${element.widget.runtimeType}');
    try {
      t.hub.papersHeld!.complete();
      t.hub.papersHeld = null;
      await tester.pumpAndSettle();
      expect(find.byType(PaperView), findsNWidgets(7));
      expect(drawn.where((w) => w == 'PaperView').length, 7);
      expect(drawn, isNot(contains('PrintLogScreen')));

      // the screen drawn again (a print is closed): the papers that stay are not
      drawn.clear();
      await tester.tap(find.byKey(const ValueKey('print-row:b1')));
      await tester.pumpAndSettle();
      expect(find.byType(PaperView), findsNWidgets(6));
      expect(drawn, contains('PrintLogScreen'));
      expect(drawn.where((w) => w == '_Sheet' || w.startsWith('LayoutBuilder')), isEmpty);

      // nor when the log is read again and has a new print at its top
      drawn.clear();
      t.hub.printLog!.insert(0, printed('t6', atMs: at(26, 19, 50), title: 'Table 8'));
      t.hub.papers['t6'] = ticketPaper('Table 8', ['1 x Lo Mein']);
      await tester.pump(const Duration(seconds: 12));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('paper:t6')), findsOneWidget); // open, like the rest
      expect(drawn.where((w) => w == '_Sheet').length, 1);
    } finally {
      debugOnRebuildDirtyWidget = null;
    }
    await stop(tester);
  });

  testWidgets('a print made while an older one is read comes in above the screen and moves nothing on it', (
    tester,
  ) async {
    final t = await pumpLog(tester, size: const Size(700, 600));
    void make(String job, int minute, String table) {
      t.hub.printLog!.insert(0, printed(job, atMs: at(26, 19, minute), title: table));
      t.hub.papers[job] = ticketPaper(table, ['1 x Lo Mein']);
    }

    await tester.tap(find.byKey(const ValueKey('log-all')));
    await tester.pumpAndSettle();
    final list = find.descendant(of: find.byKey(const ValueKey('log-list')), matching: find.byType(Scrollable));
    // the newest print's paper is being read, a little way down: the day's name is off the top of the screen
    await tester.drag(list, const Offset(0, -60));
    await tester.pumpAndSettle();
    final newest = tester.getRect(find.byKey(const ValueKey('paper:t5')));
    make('t6', 50, 'Table 8');
    await tester.pump(const Duration(seconds: 12));
    await tester.pumpAndSettle();
    // the day's name went up to the new print, and the paper being read has not moved for it
    expect(tester.getRect(find.byKey(const ValueKey('paper:t5'))), newest);
    expect(find.byKey(const ValueKey('print-row:t6')).hitTestable(), findsNothing);

    // further down the log
    final reading = find.byKey(const ValueKey('paper:t2'));
    await tester.scrollUntilVisible(reading, 300, scrollable: list);
    await tester.pumpAndSettle();
    final where = tester.getRect(reading);
    make('t8', 52, 'Table 6');
    await tester.pump(const Duration(seconds: 12));
    await tester.pumpAndSettle();
    expect(tester.getRect(reading), where);
    expect(find.byKey(const ValueKey('print-row:t8')).hitTestable(), findsNothing);

    // they are there, above: at the top of the list, under the day's name, each with its paper
    for (var drags = 0; drags < 2; drags++) {
      await tester.drag(list, const Offset(0, 9000)); // a list finds out how long it is as it is scrolled
      await tester.pumpAndSettle();
    }
    final top = tester.getTopLeft(find.byKey(const ValueKey('log-list'))).dy;
    expect(tester.getTopLeft(find.text('Today')).dy, closeTo(top + 14, 0.5));
    expect(find.text('Today'), findsOneWidget);
    expect(find.byKey(const ValueKey('paper:t8')), findsOneWidget);
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('print:t6'))).dy,
      tester.getBottomLeft(find.byKey(const ValueKey('print:t8'))).dy,
    );

    // read from the top, the next one shows there as it comes
    make('t7', 55, 'Table 4');
    await tester.pump(const Duration(seconds: 12));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('Today')).dy, closeTo(top + 14, 0.5));
    expect(find.byKey(const ValueKey('paper:t7')).hitTestable(), findsOneWidget);
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('print:t8'))).dy,
      tester.getBottomLeft(find.byKey(const ValueKey('print:t7'))).dy,
    );
    expect(listed(tester).take(2), ['t7', 't8']);

    // and the list scrolls from its newest print to the end of the log as one list
    await tester.scrollUntilVisible(find.byKey(const ValueKey('log-end')), 400, scrollable: list, maxScrolls: 100);
    expect(find.byKey(const ValueKey('paper:o1')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await stop(tester);
  });

  testWidgets('a paper the hub does not give says so under its own print, and is asked for again', (tester) async {
    final t = await pumpLog(tester);
    final paper = t.hub.papers.remove('t1')!;
    await tester.tap(find.byKey(const ValueKey('print-row:t1')));
    await tester.pumpAndSettle();
    final t1 = find.byKey(const ValueKey('print:t1'));
    expect(find.descendant(of: t1, matching: find.text('This paper is no longer in the log.')), findsOneWidget);
    expect(find.byKey(const ValueKey('reprint:t1')), findsOneWidget);
    // the others are not held up by it
    await tester.tap(find.byKey(const ValueKey('print-row:t2')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('paper:t2')), findsOneWidget);

    t.hub.papers['t1'] = paper;
    await tester.tap(find.descendant(of: t1, matching: find.text('Try again')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('paper:t1')), findsOneWidget);
    expect(find.text('This paper is no longer in the log.'), findsNothing);
    expect(t.hub.paperAsks, ['t1', 't2', 't1']);
    await stop(tester);
  });

  testWidgets('the words of a search are marked on the papers and in the lines of the log', (tester) async {
    await pumpLog(tester, arrange: night, size: const Size(700, 9000));
    await tester.tap(find.byKey(const ValueKey('log-all')));
    await tester.pumpAndSettle();
    expect(marked(tester, find.byKey(const ValueKey('log-list'))), isEmpty); // no search marks nothing

    await tester.tap(find.byKey(const ValueKey('log-search')));
    await tester.pumpAndSettle();
    await search(tester, 'tsing');
    expect(listed(tester), ['r1', 'd1']);
    // every print is still open, and the paper has the words marked as it has them, and nothing else
    final paper = find.byKey(const ValueKey('paper:d1'));
    expect(marked(tester, paper), ['Tsing']);
    expect(marked(tester, find.byKey(const ValueKey('paper:r1'))), ['Tsing']);
    final beers = tester.widget<Text>(find.descendant(of: paper, matching: find.text('2 x Tsingtao')));
    final mark = (beers.textSpan! as TextSpan).children!.cast<TextSpan>()[1].style!;
    expect((mark.backgroundColor, mark.color), (PaperView.marker, PaperView.ink));
    expect(mark.fontWeight, isNull); // a printer's letters keep their width
    // and the line it was found on, under the print's own line
    expect(marked(tester, find.byKey(const ValueKey('print-found:d1'))), ['Tsing']);
    expect(marked(tester, find.byKey(const ValueKey('print-line:d1'))), isEmpty);

    // found in what the print is called: marked there, and on the paper where it says it too
    await search(tester, 'table 9');
    expect(listed(tester), ['r1', 'd1']);
    expect(marked(tester, find.byKey(const ValueKey('print-line:d1'))), ['Table 9']);
    expect(line(tester, 'r1'), endsWith('Reprint · Ticket · Table 9'));
    expect(marked(tester, paper), ['Table 9']);

    // in its printer's name, not in how it ended
    await search(tester, 'bar');
    expect(listed(tester), ['r1', 'd1', 'b1']);
    final ended = find.byKey(const ValueKey('print-outcome:b1'));
    expect(tester.widget<Text>(ended).textSpan!.toPlainText(), 'Bar · Printed');
    expect(marked(tester, ended), ['Bar']);

    // in who asked for a reprint, where the print says so
    await search(tester, 'mike');
    expect(listed(tester), ['r1']);
    final story = find.byKey(const ValueKey('print-story:r1'));
    expect(find.descendant(of: story, matching: find.text('A reprint asked for by Mike.')), findsOneWidget);
    expect(marked(tester, story), ['Mike']);

    // words that begin on the left of the paper and end on its right are marked on both sides
    await search(tester, '9 7:05');
    expect(listed(tester), ['r1', 'd1']);
    expect(marked(tester, paper), ['9', '7:05']);

    // on a line that is white on black the marker is still the marker
    await search(tester, 'peanut');
    expect(listed(tester).length, 9);
    expect(marked(tester, find.byKey(const ValueKey('paper:t1'))), ['PEANUT']);

    // the search ended: the prints are still open, and nothing is marked
    await tester.tap(find.byKey(const ValueKey('log-search')));
    await tester.pumpAndSettle();
    expect(listed(tester).length, 9);
    expect(find.byType(PaperView), findsNWidgets(9));
    expect(marked(tester, find.byKey(const ValueKey('log-list'))), isEmpty);
    await stop(tester);
  });

  testWidgets('on a phone Expand all is its mark alone, and with large type the bar still fits', (tester) async {
    await pumpLog(tester, arrange: night, size: const Size(320, 6000), textScale: 1.6);
    final all = find.byKey(const ValueKey('log-all'));
    expect(tester.widget(all), isA<IconButton>());
    expect(tester.widget<IconButton>(all).tooltip, 'Expand all');
    await tester.tap(find.byKey(const ValueKey('log-search')));
    await tester.pumpAndSettle();
    await search(tester, 'mai tai');
    await tester.tap(all);
    await tester.pumpAndSettle();
    expect(tester.widget<IconButton>(all).tooltip, 'Collapse all');
    expect(tester.takeException(), isNull); // nothing ran over the edge
    expect(tester.getRect(find.byKey(const ValueKey('log-search-box'))).width, greaterThan(100));
    final paper = tester.getRect(find.byKey(const ValueKey('paper:d1')));
    expect((paper.left, paper.right), (16, 304));
    expect(marked(tester, find.byKey(const ValueKey('paper:d1'))), ['Mai Tai']);
    await stop(tester);
  });

  testWidgets('the log can be read for one printer, and for the prints that had a problem', (tester) async {
    final t = await pumpLog(tester);
    await tester.tap(find.byKey(const ValueKey('log-printer')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bar').last);
    await tester.pumpAndSettle();
    expect(t.hub.printLogAsks.last, {'printer': 'bar', 'limit': '50'});
    expect(find.byKey(const ValueKey('print:b1')), findsOneWidget);
    expect(find.byKey(const ValueKey('print:t1')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('log-trouble')));
    await tester.pumpAndSettle();
    expect(t.hub.printLogAsks.last, {'printer': 'bar', 'only': 'trouble', 'limit': '50'});
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('log-none')),
        matching: find.text('No problems in the last 14 days: every print came out at its own printer, first time.'),
      ),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('log-printer')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('All printers').last);
    await tester.pumpAndSettle();
    expect(t.hub.printLogAsks.last, {'only': 'trouble', 'limit': '50'});
    expect(find.byKey(const ValueKey('print:t2')), findsOneWidget);
    expect(find.byKey(const ValueKey('print:t4')), findsOneWidget);
    expect(find.byKey(const ValueKey('print:t5')), findsOneWidget);
    expect(find.byKey(const ValueKey('print:t1')), findsNothing);
    await stop(tester);
  });

  testWidgets('a long log comes fifty prints at a time; "Older prints" brings the next', (tester) async {
    final t = await pumpLog(
      tester,
      size: const Size(700, 9000),
      arrange: (hub) {
        hub.logPrinters = [wokPrinter];
        hub.printLog = [
          for (var n = 70; n > 0; n--) printed('j${n.toString().padLeft(2, '0')}', atMs: at(26, 12, 0) + n * 60000),
        ];
      },
    );
    expect(find.byKey(const ValueKey('print:j70')), findsOneWidget);
    expect(find.byKey(const ValueKey('print:j21')), findsOneWidget);
    expect(find.byKey(const ValueKey('print:j20')), findsNothing);
    expect(find.byKey(const ValueKey('log-end')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('log-more')));
    await tester.pumpAndSettle();
    expect(t.hub.printLogAsks.last, {'before': '${at(26, 12, 0) + 21 * 60000}:j21', 'limit': '50'});
    expect(find.byKey(const ValueKey('print:j20')), findsOneWidget);
    expect(find.byKey(const ValueKey('print:j01')), findsOneWidget);
    expect(find.byKey(const ValueKey('log-more')), findsNothing);
    expect(find.byKey(const ValueKey('log-end')), findsOneWidget);

    // a print made while the older ones are on the screen goes on top, and they stay
    t.hub.printLog!.insert(0, printed('j71', atMs: at(26, 12, 0) + 71 * 60000));
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('print:j71')), findsOneWidget);
    expect(find.byKey(const ValueKey('print:j01')), findsOneWidget);
    await stop(tester);
  });

  testWidgets('a hub from before the log says to update it, and is not asked again', (tester) async {
    final t = await pumpLog(tester, arrange: (hub) => hub.printLog = null);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('log-old')),
        matching: find.text('This hub does not keep a print log yet. Update the hub.'),
      ),
      findsOneWidget,
    );
    t.hub.requests.clear();
    await tester.pump(const Duration(seconds: 10));
    expect(t.hub.requests, isEmpty);
    await stop(tester);
  });

  testWidgets('with the hub away the log says so, and reads once it is back', (tester) async {
    final t = await pumpLog(
      tester,
      arrange: (hub) {
        evening(hub);
        hub.down = true;
      },
    );
    expect(
      find.descendant(of: find.byKey(const ValueKey('log-away')), matching: find.text('The hub is not answering.')),
      findsOneWidget,
    );
    t.hub.down = false;
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('print:t1')), findsOneWidget);

    // away again with the log on the screen: the log stays, and says it is old
    t.hub.down = true;
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('print:t1')), findsOneWidget);
    expect(find.text('The hub is not answering. This is the log as it was last read.'), findsOneWidget);
    t.hub.down = false;
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(find.text('The hub is not answering. This is the log as it was last read.'), findsNothing);
    await stop(tester);
  });

  testWidgets('a print that comes out while the log is open shows as printed without a tap', (tester) async {
    final t = await pumpLog(tester);
    expect(said(tester, 'print-outcome:t4'), contains('Not printed yet'));
    final waiting = t.hub.printLog!.firstWhere((p) => p['job_id'] == 't4');
    waiting
      ..['status'] = 'printed'
      ..['printed_ms'] = at(26, 19, 45)
      ..['printed_on'] = '10.27.1.14'
      ..['printed_by'] = 'hub';
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(said(tester, 'print-outcome:t4'), 'Wok · Printed after 3 failed tries');
    await stop(tester);
  });

  testWidgets('under the change feed the log waits to be told that a print was made', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final settings = Settings(
      device: 't1',
      endpoints: ['http://hub:8000'],
      prefs: await SharedPreferences.getInstance(),
    );
    final hub = Hub();
    final live = LiveHub(hub);
    final api = PosApi(settings, client: live.client);
    final session = Session(api)..staff = const Staff(staffId: 's3', name: 'Mike', role: 'manager', method: 'pin');
    final t = Terminal(
      hub,
      api,
      Outbox(api, settings, store: MemoryStore()),
      PhotoQueue(api, settings, NoCamera(), session, store: MemoryStore()),
      session,
      settings,
    );
    tester.view
      ..physicalSize = const Size(700, 3000)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    api.live.start();
    evening(hub);
    await tester.pumpWidget(
      MaterialApp(
        home: PrintLogScreen(api: api, token: 'tok-admin', now: now),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('print:t1')), findsOneWidget);
    live.hello();
    live.beats();
    await tester.pumpAndSettle();
    expect(api.live.isLive, isTrue);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();

    // twenty seconds in which nothing is printed: not one request
    hub.requests.clear();
    await tester.pump(const Duration(seconds: 20));
    await tester.pump();
    expect(hub.requests, isEmpty);

    // the kitchen prints a ticket: the hub says so, and it is on the screen
    hub.printLog!.insert(0, printed('t6', atMs: at(26, 20, 10), title: 'Table 9'));
    live.changed(topics: ['prints']);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
    expect(find.byKey(const ValueKey('print:t6')), findsOneWidget);
    expect(hub.requests, ['GET /print/log?limit=50']);

    // something else changes: nothing for the log to read
    hub.requests.clear();
    live.changed(orders: ['o9']);
    live.changed(topics: ['settings']);
    await tester.pump(const Duration(seconds: 2));
    expect(hub.requests, isEmpty);

    await stop(tester);
    live.close();
    t.api.dispose();
    await tester.pump();
  });

  testWidgets('on a phone, with large type, the log and an opened paper fit the screen', (tester) async {
    await pumpLog(tester, size: const Size(360, 5000), textScale: 1.6);
    await tester.tap(find.byKey(const ValueKey('print-row:t2')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('print-row:t4')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull); // nothing ran over the edge
    final paper = tester.getRect(find.byKey(const ValueKey('paper:t2')));
    expect(paper.left, greaterThanOrEqualTo(0));
    expect(paper.right, lessThanOrEqualTo(360));
    // the paper is as wide as the phone lets it be, and its letters are not blown up by the large type: a
    // printer's line stays a line
    expect(paper.width, 328);
    final words = find.descendant(of: find.byKey(const ValueKey('paper:t2')), matching: find.text('Table 7'));
    expect(MediaQuery.textScalerOf(tester.element(words)), TextScaler.noScaling);
    await stop(tester);
  });

  testWidgets('the log is read by kind of print: the kitchen, the bar, the bills, the reprints, the rest', (
    tester,
  ) async {
    final t = await pumpLog(tester, arrange: night);
    final chips = find.descendant(of: find.byKey(const ValueKey('log-types')), matching: find.byType(ChoiceChip));
    expect(
      [for (final chip in tester.widgetList<ChoiceChip>(chips)) (chip.label as Text).data],
      ['All', 'Kitchen', 'Bar', 'Bills', 'Reprints', 'Other'],
    );
    expect(picked(tester, 'all'), isTrue);
    expect(listed(tester), ['r1', 'd1', 't5', 't4', 'b1', 't2', 't1', 'y1', 'o1']);
    expect(t.hub.printLogAsks.last, {'limit': '50'});

    await tester.tap(find.byKey(const ValueKey('log-type:bar')));
    await tester.pumpAndSettle();
    expect(t.hub.printLogAsks.last, {'type': 'bar', 'limit': '50'});
    expect(listed(tester), ['r1', 'd1']); // the bar's ticket, and its reprint
    expect((picked(tester, 'bar'), picked(tester, 'all')), (true, false));

    await tester.tap(find.byKey(const ValueKey('log-type:reprint')));
    await tester.pumpAndSettle();
    expect(listed(tester), ['r1']);
    expect(line(tester, 'r1'), endsWith('Reprint · Ticket · Table 9'));
    await tester.tap(find.byKey(const ValueKey('log-type:bill')));
    await tester.pumpAndSettle();
    expect(listed(tester), ['b1']);
    await tester.tap(find.byKey(const ValueKey('log-type:other')));
    await tester.pumpAndSettle();
    expect(listed(tester), ['o1']);

    // with the other two ways of reading it: the kitchen's tickets that had a problem
    await tester.tap(find.byKey(const ValueKey('log-type:kitchen')));
    await tester.pumpAndSettle();
    expect(listed(tester), ['t5', 't4', 't2', 't1', 'y1']);
    await tester.tap(find.byKey(const ValueKey('log-trouble')));
    await tester.pumpAndSettle();
    expect(t.hub.printLogAsks.last, {'type': 'kitchen', 'only': 'trouble', 'limit': '50'});
    expect(listed(tester), ['t5', 't4', 't2']);
    await tester.tap(find.byKey(const ValueKey('log-trouble')));
    await tester.pumpAndSettle();

    // a kind this printer made none of says so, and "Show all prints" is every kind again
    await tester.tap(find.byKey(const ValueKey('log-type:bill')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('log-printer')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Wok').last);
    await tester.pumpAndSettle();
    expect(t.hub.printLogAsks.last, {'printer': 'wok', 'type': 'bill', 'limit': '50'});
    final none = find.byKey(const ValueKey('log-none'));
    expect(
      find.descendant(of: none, matching: find.text('No bills at this printer in the last 14 days.')),
      findsOneWidget,
    );
    await tester.tap(find.descendant(of: none, matching: find.text('Show all prints')));
    await tester.pumpAndSettle();
    expect(t.hub.printLogAsks.last, {'printer': 'wok', 'limit': '50'});
    expect(picked(tester, 'all'), isTrue);
    expect(listed(tester), ['t5', 't4', 't2', 't1', 'y1', 'o1']);
    await stop(tester);
  });

  testWidgets('the kinds offered are the ones the hub says: a restaurant with no bar is shown none', (tester) async {
    await pumpLog(
      tester,
      arrange: (hub) {
        night(hub);
        hub.printLogTypes = ['kitchen', 'bill', 'reprint', 'other', 'catering'];
      },
    );
    expect(find.byKey(const ValueKey('log-type:bar')), findsNothing);
    expect(find.byKey(const ValueKey('log-type:kitchen')), findsOneWidget);
    // a kind a newer hub added is offered under the hub's word for it
    expect(
      find.descendant(of: find.byKey(const ValueKey('log-type:catering')), matching: find.text('Catering')),
      findsOneWidget,
    );
    await stop(tester);
  });

  testWidgets('the log is searched from the bar, once the typing stops, on the papers themselves', (tester) async {
    final t = await pumpLog(tester, arrange: night);
    expect(find.byKey(const ValueKey('log-search-box')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('log-search')));
    await tester.pumpAndSettle();
    final box = find.byKey(const ValueKey('log-search-box'));
    expect(tester.widget<TextField>(box).focusNode!.hasFocus, isTrue);
    expect(find.text('Print log'), findsNothing); // the box has the title's place: no line of the screen is spent

    // not at every letter
    final asked = t.hub.printLogAsks.length;
    await tester.enterText(box, 'ts');
    await tester.pump(const Duration(milliseconds: 200));
    await tester.enterText(box, 'tsing');
    await tester.pump(const Duration(milliseconds: 200));
    expect(t.hub.printLogAsks.length, asked);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    expect(t.hub.printLogAsks.length, asked + 1);
    expect(t.hub.printLogAsks.last, {'q': 'tsing', 'limit': '50'});
    expect(listed(tester), ['r1', 'd1']);
    // the line of the paper it was found on, since the line of the log does not show it
    final found = tester.widget<Text>(find.byKey(const ValueKey('print-found:d1'))).textSpan!;
    expect(found.toPlainText(), 'On the paper: 2 x Tsingtao');
    final bold = [
      for (final span in (found as TextSpan).children!.cast<TextSpan>())
        if (span.style?.fontWeight == FontWeight.w700) span.text,
    ];
    expect(bold, ['Tsing']); // what was typed, as the paper has it

    // found in the log's own line: there is nothing to add to it
    await search(tester, '  Table   7 ');
    expect(t.hub.printLogAsks.last, {'q': 'Table 7', 'limit': '50'});
    expect(listed(tester), ['t2']);
    expect(find.byKey(const ValueKey('print-found:t2')), findsNothing);

    // Enter does not wait
    await tester.enterText(box, 'mike');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(t.hub.printLogAsks.last, {'q': 'mike', 'limit': '50'});
    expect(listed(tester), ['r1']);

    // within one kind of print, and the log read again by itself is still the search
    await search(tester, 'egg roll');
    expect(listed(tester), ['t5', 't4', 'b1', 't2', 't1', 'y1', 'o1']);
    await tester.tap(find.byKey(const ValueKey('log-type:bill')));
    await tester.pumpAndSettle();
    expect(t.hub.printLogAsks.last, {'q': 'egg roll', 'type': 'bill', 'limit': '50'});
    expect(listed(tester), ['b1']);
    t.hub.printLogAsks.clear();
    await tester.pump(const Duration(seconds: 12));
    await tester.pumpAndSettle();
    expect(t.hub.printLogAsks, isNotEmpty);
    expect(t.hub.printLogAsks.every((ask) => ask['q'] == 'egg roll' && ask['type'] == 'bill'), isTrue);

    // nothing has the words: it says what was looked through, and "Show all prints" ends the search
    await search(tester, 'lobster');
    final none = find.byKey(const ValueKey('log-none'));
    expect(
      find.descendant(of: none, matching: find.text('No bills in the last 14 days have “lobster” on them.')),
      findsOneWidget,
    );
    await tester.tap(find.descendant(of: none, matching: find.text('Show all prints')));
    await tester.pumpAndSettle();
    expect(t.hub.printLogAsks.last, {'limit': '50'});
    expect(find.byKey(const ValueKey('log-search-box')), findsNothing);
    expect(find.text('Print log'), findsOneWidget);
    expect(listed(tester).length, 9);
    await stop(tester);
  });

  testWidgets('the search is emptied with its cross, and ended by closing it; spaces are no search', (tester) async {
    final t = await pumpLog(tester, arrange: night);
    await tester.tap(find.byKey(const ValueKey('log-search')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('log-search-clear')), findsNothing);
    final asked = t.hub.printLogAsks.length;
    await search(tester, '   ');
    expect(t.hub.printLogAsks.length, asked); // nothing was asked again
    await search(tester, 'mai tai');
    expect(listed(tester), ['r1', 'd1']);

    await tester.tap(find.byKey(const ValueKey('log-search-clear')));
    await tester.pumpAndSettle();
    expect(t.hub.printLogAsks.last, {'limit': '50'});
    expect(listed(tester).length, 9);
    final box = find.byKey(const ValueKey('log-search-box'));
    expect(tester.widget<TextField>(box).controller!.text, isEmpty);
    expect(tester.widget<TextField>(box).focusNode!.hasFocus, isTrue); // to type the next one

    await search(tester, 'mai tai');
    expect(listed(tester), ['r1', 'd1']);
    await tester.tap(find.byKey(const ValueKey('log-search')));
    await tester.pumpAndSettle();
    expect(box, findsNothing);
    expect(t.hub.printLogAsks.last, {'limit': '50'});
    expect(listed(tester).length, 9);
    // Escape in the box backs out of the search too
    await tester.tap(find.byKey(const ValueKey('log-search')));
    await tester.pumpAndSettle();
    await search(tester, 'mai tai');
    expect(listed(tester), ['r1', 'd1']);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('log-search-box')), findsNothing);
    expect(listed(tester).length, 9);
    // a search is no longer than the hub reads
    await tester.tap(find.byKey(const ValueKey('log-search')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('log-search-box')), 'x' * 150);
    expect(tester.widget<TextField>(find.byKey(const ValueKey('log-search-box'))).controller!.text.length, 100);
    await tester.tap(find.byKey(const ValueKey('log-search')));
    await tester.pumpAndSettle();
    // and closed while the typing had not stopped yet: what was typed is not searched for after all
    await tester.tap(find.byKey(const ValueKey('log-search')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('log-search-box')), 'tsing');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byKey(const ValueKey('log-search')));
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(t.hub.printLogAsks.any((ask) => ask['q'] == 'tsing'), isFalse);
    expect(listed(tester).length, 9);
    await stop(tester);
  });

  testWidgets('the older prints of a kind and of a search are asked for the same way', (tester) async {
    final t = await pumpLog(
      tester,
      size: const Size(700, 9000),
      arrange: (hub) {
        hub.logPrinters = [wokPrinter];
        hub.printLog = [
          for (var n = 70; n > 0; n--)
            printed('j${n.toString().padLeft(2, '0')}', atMs: at(26, 12, 0) + n * 60000, places: ['kitchen']),
        ];
      },
    );
    await tester.tap(find.byKey(const ValueKey('log-type:kitchen')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('log-search')));
    await tester.pumpAndSettle();
    await search(tester, 'table 12');
    expect(listed(tester).length, 50);
    await tester.tap(find.byKey(const ValueKey('log-more')));
    await tester.pumpAndSettle();
    expect(t.hub.printLogAsks.last, {
      'type': 'kitchen',
      'q': 'table 12',
      'before': '${at(26, 12, 0) + 21 * 60000}:j21',
      'limit': '50',
    });
    expect(listed(tester).length, 70);
    await stop(tester);
  });

  testWidgets('a hub from before the kinds lists its log as before, with neither chips nor search', (tester) async {
    final t = await pumpLog(
      tester,
      arrange: (hub) {
        evening(hub);
        hub.printLogTypes = null;
      },
    );
    expect(listed(tester).length, 7);
    expect(find.byKey(const ValueKey('log-types')), findsNothing);
    expect(find.byKey(const ValueKey('log-search')), findsNothing);
    expect(find.byKey(const ValueKey('log-printer')), findsOneWidget);
    expect(said(tester, 'log-no-types'), 'Update the hub to read the log by kind of print and to search it.');
    expect(t.hub.printLogAsks.every((ask) => !ask.containsKey('type') && !ask.containsKey('q')), isTrue);
    await stop(tester);
  });

  testWidgets('on a phone, with large type, the kinds slide sideways and the search fits the bar', (tester) async {
    await pumpLog(tester, arrange: night, size: const Size(360, 3000), textScale: 1.6);
    expect(tester.takeException(), isNull);
    // one line of chips, wider than the phone: the last is brought on by a slide, not by a second line
    final all = tester.getRect(find.byKey(const ValueKey('log-type:all')));
    final other = find.byKey(const ValueKey('log-type:other'));
    expect(tester.getRect(other).top, all.top);
    expect(tester.getRect(other).right, greaterThan(360));
    await tester.drag(find.byKey(const ValueKey('log-types')), const Offset(-600, 0));
    await tester.pumpAndSettle();
    expect(tester.getRect(other).right, lessThanOrEqualTo(360));
    await tester.tap(other);
    await tester.pumpAndSettle();
    expect(listed(tester), ['o1']);
    await tester.tap(find.byKey(const ValueKey('log-type:reprint')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('log-search')));
    await tester.pumpAndSettle();
    await search(tester, 'a slice of lime on the side');
    expect(listed(tester), ['r1']);
    final found = tester.getRect(find.byKey(const ValueKey('print-found:r1')));
    expect(found.right, lessThanOrEqualTo(360)); // a long line of the paper wraps under the print
    expect(found.height, greaterThan(40));
    await search(tester, 'a search much longer than the bar of a phone is wide');
    expect(find.byKey(const ValueKey('log-none')), findsOneWidget);
    expect(tester.takeException(), isNull); // nothing ran over the edge
    await stop(tester);
  });

  testWidgets('the printers screen opens the log, for every printer or for one', (tester) async {
    final t = await terminal(tester);
    tester.view.physicalSize = const Size(1100, 3200);
    evening(t.hub);
    t.hub.printers = {
      'printers': [
        {'id': 'wok', 'station': 'wok1', 'address': '10.27.1.14', 'dialect': 'escpos', 'fallbacks': []},
        {'id': 'bar', 'station': 'bar', 'address': '10.27.1.166', 'dialect': 'star', 'fallbacks': []},
      ],
      'takeout_station': null,
      'source': 'settings',
    };
    await tester.pumpWidget(
      MaterialApp(
        home: PrintersScreen(api: t.api, token: 'tok-admin', addresses: const ['172.19.1.44']),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('printers-log')));
    await tester.pumpAndSettle();
    expect(find.byType(PrintLogScreen), findsOneWidget);
    expect(t.hub.printLogAsks.last, {'limit': '50'});
    expect(t.hub.printLogAuth, 'Bearer tok-admin');
    expect(find.byKey(const ValueKey('print:t1')), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('printer-log:bar')));
    await tester.pumpAndSettle();
    expect(t.hub.printLogAsks.last, {'printer': 'bar', 'limit': '50'});
    expect(find.byKey(const ValueKey('print:b1')), findsOneWidget);
    expect(find.byKey(const ValueKey('print:t1')), findsNothing);
    await stop(tester);
  });

  group('a paper on the screen', () {
    Future<void> pumpPaper(WidgetTester tester, List<List<PaperStep>> pages, {double width = 400}) async {
      tester.view
        ..physicalSize = Size(width, 2000)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: PaperView(pages: pages),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('big lines are twice the size, bold is bold, and a reversed line is white on black', (tester) async {
      await pumpPaper(tester, [
        const [
          PaperStep(kind: 'beep'),
          PaperStep(kind: 'line', text: '*** REPRINT ***', big: true, bold: true, center: true, invert: true),
          PaperStep(kind: 'line', text: 'plain'),
          PaperStep(kind: 'line', text: 'loud', big: true, bold: true),
          PaperStep(kind: 'cols', text: 'Subtotal', right: '\$24.00'),
          PaperStep(kind: 'rule'),
          PaperStep(kind: 'feed', count: 2),
          PaperStep(kind: 'cut'),
        ],
      ]);
      TextStyle style(String words) => tester.widget<Text>(find.text(words)).style!;
      expect(style('loud').fontSize, style('plain').fontSize! * 2);
      expect(style('loud').fontWeight, FontWeight.w700);
      expect(style('plain').fontWeight, FontWeight.w400);
      // paper is paper in a dark room too: dark letters on a light sheet
      expect(style('plain').color, PaperView.ink);
      expect(style('*** REPRINT ***').color, PaperView.paper);
      final bar = tester.widget<Container>(
        find.ancestor(of: find.text('*** REPRINT ***'), matching: find.byType(Container)).first,
      );
      expect(bar.color, PaperView.ink);
      expect(tester.widget<Text>(find.text('*** REPRINT ***')).textAlign, TextAlign.center);
      // two columns: the left at the left edge, the right at the right
      expect(tester.getTopLeft(find.text('Subtotal')).dx, lessThan(tester.getTopLeft(find.text('\$24.00')).dx));
      expect(tester.getTopRight(find.text('\$24.00')).dx, closeTo(tester.getTopRight(find.text('plain')).dx, 0.5));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a search marks its words where the paper has them: a whole number, either case, both columns', (
      tester,
    ) async {
      const pages = [
        [
          PaperStep(kind: 'line', text: '*** REPRINT ***', big: true, bold: true, center: true, invert: true),
          PaperStep(kind: 'cols', text: 'Table 1', right: '7:05 PM', bold: true),
          PaperStep(kind: 'line', text: 'moved from table 12'),
          PaperStep(kind: 'line', text: '2 x  Kung Pao   Chicken', big: true),
          PaperStep(kind: 'cols', text: '1 Peking Duck', right: '48.00'),
          PaperStep(kind: 'rule'),
          PaperStep(kind: 'cut'),
        ],
      ];
      Future<List<String>> marks(String typed) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: PaperView(pages: pages, find: PrintFind.of(typed)),
            ),
          ),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
        return marked(tester, find.byType(PaperView));
      }

      tester.view
        ..physicalSize = const Size(400, 2000)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      expect(await marks(''), isEmpty);
      expect(await marks('table 1'), ['Table 1']); // not table 12
      expect(await marks('TABLE'), ['Table', 'table']);
      expect(await marks('kung pao chicken'), ['Kung Pao   Chicken']); // with the room the paper leaves
      expect(await marks('duck 48.00'), ['Duck', '48.00']);
      expect(await marks('8.00'), isEmpty); // 48.00 is not 8.00
      expect(await marks('reprint'), ['REPRINT']);
      // marked or not, the paper is as tall and its lines are where they were
      final tall = tester.getSize(find.byType(PaperView));
      final at = tester.getTopLeft(find.text('1 Peking Duck'));
      expect(await marks('nothing of the kind'), isEmpty);
      expect(tester.getSize(find.byType(PaperView)), tall);
      expect(tester.getTopLeft(find.text('1 Peking Duck')), at);
    });

    testWidgets('a paper is drawn again for another search or another text size, and for nothing else', (tester) async {
      const pages = [
        [PaperStep(kind: 'line', text: '1 x Egg Roll'), PaperStep(kind: 'cut')],
      ];
      var sheets = 0;
      Future<int> drawnFor({String typed = '', double textScale = 1, String around = 'a'}) async {
        sheets = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
              child: Scaffold(
                body: Column(
                  children: [
                    Text(around),
                    PaperView(pages: pages, find: PrintFind.of(typed)),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        return sheets;
      }

      tester.view
        ..physicalSize = const Size(400, 2000)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      debugOnRebuildDirtyWidget = (element, _) => sheets += '${element.widget.runtimeType}' == '_Sheet' ? 1 : 0;
      try {
        expect(await drawnFor(), 1);
        expect(await drawnFor(around: 'b'), 0); // the screen around it changed: the paper did not
        expect(await drawnFor(typed: 'egg'), 1);
        expect(await drawnFor(typed: ' EGG ', around: 'c'), 1); // another way to type it marks another way
        expect(await drawnFor(typed: ' EGG ', around: 'd'), 0);
        expect(await drawnFor(typed: ' EGG ', textScale: 1.5), 1);
      } finally {
        debugOnRebuildDirtyWidget = null;
      }
    });

    testWidgets('the papers of one job stand one under the other, and a narrow screen gets a narrow paper', (
      tester,
    ) async {
      await pumpPaper(tester, [
        const [PaperStep(kind: 'line', text: 'BAG 1 OF 2', big: true), PaperStep(kind: 'cut')],
        const [PaperStep(kind: 'line', text: 'BAG 2 OF 2', big: true), PaperStep(kind: 'cut')],
      ], width: 300);
      expect(
        tester.getTopLeft(find.text('BAG 2 OF 2')).dy,
        greaterThan(tester.getBottomLeft(find.text('BAG 1 OF 2')).dy),
      );
      final sheet = tester.getRect(find.byType(PaperView));
      expect(sheet.width, 300);
      expect(tester.takeException(), isNull);
    });
  });
}
