import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/camera.dart';
import 'package:pos_app/live.dart';
import 'package:pos_app/outbox.dart';
import 'package:pos_app/photos.dart';
import 'package:pos_app/queue_store.dart';
import 'package:pos_app/screens/location_settings_screen.dart';
import 'package:pos_app/screens/logbook_screen.dart';
import 'package:pos_app/screens/orders_screen.dart';
import 'package:pos_app/screens/shift_notes_dialog.dart';
import 'package:pos_app/screens/shift_notes_screen.dart';
import 'package:pos_app/session.dart';
import 'package:pos_app/settings.dart';
import 'package:pos_app/shift_notes.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'hub.dart';
import 'idle_lock_test.dart' show amy, ben;
import 'location_rows.dart';

/// Notes for the shift and the manager's log (docs/shift-notes.md): a note a manager put up comes up once
/// for each person after they sign in, over the floor or the list and never over an open check; everybody
/// can read the notes again, and a manager writes, changes and takes them down and sees who has read each;
/// the managers' own log is read by subject and by words, written in, and struck out, never deleted.

/// Monday 16 November 2026, on the device's own clock.
DateTime at(int hour, [int minute = 0, int day = 16]) => DateTime(2026, 11, day, hour, minute);
int ms(int hour, [int minute = 0, int day = 16]) => at(hour, minute, day).millisecondsSinceEpoch;

/// A note as the pretend hub holds it: up, written by Mike at 15:40, seen by [seenBy].
Map<String, dynamic> note(
  String id,
  String text, {
  int? atMs,
  bool stays = false,
  int? editedMs,
  List<String> seenBy = const ['s3'],
}) => {
  'id': id,
  'text': text,
  'by': 'Mike',
  'at_ms': atMs ?? ms(15, 40),
  'until_ms': stays ? null : ms(4, 0, 17),
  'lasts': stays ? 'stays' : 'tonight',
  'edited_ms': editedMs,
  'seen_by': [...seenBy],
};

/// An entry of the log as the pretend hub holds it.
Map<String, dynamic> entry(
  String id,
  String subject,
  String text,
  int atMs,
  String day, {
  int? struckMs,
  String struckBy = '',
}) => {
  'id': id,
  'subject': subject,
  'subject_name': Hub.logSubjects.firstWhere((s) => s.$1 == subject).$2,
  'text': text,
  'by': 'Mike',
  'at_ms': atMs,
  'day': day,
  'struck_ms': struckMs,
  'struck_by': struckBy,
};

/// Five entries over four days of service, the newest first.
List<Map<String, dynamic>> fiveEntries() => [
  entry('e5', 'repairs', 'Tom fixed the cooler: a fan belt.', ms(15, 10), '2026-11-16'),
  entry('e4', 'staff', 'Holly covers Saturday for Amy.', ms(14), '2026-11-16'),
  entry('e3', 'deliveries', 'Fish order came 2 cases short of salmon.', ms(22, 30, 15), '2026-11-15'),
  // after midnight it is still Saturday night's entry
  entry('e2', 'repairs', 'Walk-in cooler read 45F at close. Called Tom.', ms(0, 40, 15), '2026-11-14'),
  entry('e1', 'guests', 'Table 12 waited 40 minutes for the duck.', ms(20, 0, 12), '2026-11-12'),
];

const amyStaff = Staff(staffId: 's1', name: 'Amy', role: 'server', method: 'pin');

final dialog = find.byKey(const ValueKey('shift-notes'));
final gotIt = find.byKey(const ValueKey('shift-notes-got-it'));

/// The floor and the list for whoever is signed in on [t], on a hub a test has already set up.
Future<void> pumpFloor(WidgetTester tester, Terminal t, {Size size = const Size(1100, 800)}) async {
  tester.view.physicalSize = size;
  await tester.pumpWidget(const SizedBox()); // whatever screen a test had up before is gone, with what it read
  await tester.pumpWidget(
    MaterialApp(
      home: OrdersScreen(
        api: t.api,
        outbox: t.outbox,
        settings: t.settings,
        session: t.session,
        camera: NoCamera(),
        photos: t.photos,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// A terminal with Amy, a server, signed in, and these notes up on its hub.
Future<Terminal> amyWith(WidgetTester tester, List<Map<String, dynamic>>? notes) async {
  final t = await terminal(tester, role: 'server');
  t.session.staff = amyStaff;
  t.hub.shiftNotes = notes;
  return t;
}

/// Somebody signs in on the screen that is up: after a lock, or in place of whoever was there.
Future<void> signIn(WidgetTester tester, Terminal t, Map<String, dynamic> who) async {
  t.session.lock();
  t.session.applySignIn(who);
  await tester.pumpAndSettle();
}

/// The Notes screen for whoever is signed in on [t], as the menu opens it, or with a manager's [token] as
/// Location does. Its clock reads 16:02 on Monday the 16th, as the pretend hub's does.
Future<void> pumpNotes(WidgetTester tester, Terminal t, {String? token, Size size = const Size(390, 844)}) async {
  tester.view.physicalSize = size;
  await tester.pumpWidget(const SizedBox());
  await tester.pumpWidget(
    MaterialApp(
      home: ShiftNotesScreen(api: t.api, device: 't1', staff: t.session.staff, token: token, now: () => at(16, 2)),
    ),
  );
  await tester.pumpAndSettle();
}

/// A manager types their PIN on the Notes screen.
Future<void> unlock(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('notes-unlock')));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField), '9999');
  await tester.tap(find.text('Change the notes'));
  await tester.pumpAndSettle();
}

Future<void> pumpLog(WidgetTester tester, Terminal t, {Size size = const Size(390, 844)}) async {
  tester.view.physicalSize = size;
  await tester.pumpWidget(const SizedBox());
  await tester.pumpWidget(
    MaterialApp(
      home: LogbookScreen(api: t.api, token: 'tok-admin', device: 't1', now: () => at(16, 2)),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> tapKey(WidgetTester tester, String key) async {
  await tester.tap(find.byKey(ValueKey(key)));
  await tester.pumpAndSettle();
}

/// What the hub was told about who has seen which notes: "s1: n2, n1" for each call.
List<String> seenPosts(Hub hub) => [for (final (staffId, ids) in hub.notesSeenPosts) '$staffId: ${ids.join(', ')}'];

bool enabled(WidgetTester tester, String key) =>
    tester.widget<FilledButton>(find.byKey(ValueKey(key))).onPressed != null;

void main() {
  group('the words', () {
    test('a day and a time are said as a person would', () {
      final now = at(16, 2);
      expect(whenWords(ms(15, 40), now), 'today 15:40');
      expect(whenWords(ms(22, 10, 15), now), 'yesterday 22:10');
      expect(whenWords(ms(9, 5, 14), now), 'Sat Nov 14, 09:05');
      expect(dayWords(DateTime(2025, 12, 31), now), 'Wed Dec 31, 2025');
      expect(logDayWords('2026-11-16', now), 'Today');
      expect(logDayWords('2026-11-12', now), 'Thu Nov 12');
      expect(logDayWords('not a day', now), 'not a day');
    });

    test('a note says who wrote it, how long it is up, and who has seen it', () {
      final now = at(16, 2);
      final tonight = ShiftNote.fromJson(note('n1', 'Out: lobster'));
      expect((tonight.stays, tonight.lasts, lastsWords(tonight)), (false, 'tonight', 'For tonight'));
      expect(noteByWords(tonight, now), 'Mike, today 15:40');
      final changed = ShiftNote.fromJson(note('n2', 'Meeting', stays: true, editedMs: ms(15, 55)));
      expect((changed.stays, changed.lasts, lastsWords(changed)), (true, 'stays', 'Until taken down'));
      expect(noteByWords(changed, now), 'Mike, today 15:40 · changed today 15:55');

      // for one person the hub says whether they have seen it; on a manager's list, who has
      expect(ShiftNote.fromJson({...note('n1', 'x'), 'seen': true}).seen, isTrue);
      final listed = ShiftNote.fromJson({
        ...note('n1', 'x'),
        'seen': [
          {'staff_id': 's3', 'name': 'Mike', 'at_ms': ms(15, 40)},
          {'staff_id': 's1', 'name': 'Amy', 'at_ms': ms(15, 50)},
        ],
        'waiting': ['Ben', 'Holly'],
      });
      expect(listed.seen, isFalse);
      expect([for (final s in listed.seenBy) s.name], ['Mike', 'Amy']);
      expect(listed.waiting, ['Ben', 'Holly']);
      expect(seenWords(listed, 4), 'Seen by 2 of 4');
      expect(
        seenWords(
          ShiftNote.fromJson({
            ...note('n1', 'x'),
            'seen': listed.seenBy.map((s) => {'name': s.name}).toList(),
          }),
          2,
        ),
        'Seen by everyone',
      );

      final down = ShiftNote.fromJson({
        ...note('n3', 'x'),
        'ended_ms': ms(15, 58),
        'removed_by': 'Mike',
        'seen_count': 3,
      });
      expect(endedWords(down, now), 'Taken down by Mike, today 15:58');
      final over = ShiftNote.fromJson({...note('n4', 'x'), 'ended_ms': ms(4), 'removed_by': '', 'seen_count': 5});
      expect(endedWords(over, now), 'Came down today 04:00');
    });

    test('the notes one person has not seen are picked out, the newest first', () {
      final mine = MyNotes.fromJson({
        'notes': [
          {...note('n3', 'c'), 'seen': false},
          {...note('n2', 'b'), 'seen': true},
          {...note('n1', 'a'), 'seen': false},
        ],
      });
      expect([for (final n in mine.unseen) n.id], ['n3', 'n1']);
      expect(const MyNotes().unseen, isEmpty);
    });
  });

  group('the calls', () {
    test('the notes are read for one person, and a hub older than them answers nothing', () async {
      final t = await _bare();
      t.hub.shiftNotes = [
        note('n1', 'Out: lobster', seenBy: ['s3']),
      ];
      final mine = (await t.api.shiftNotes('s1'))!;
      expect((mine.notes.single.text, mine.notes.single.seen), ('Out: lobster', false));
      expect(t.hub.notesAsks, ['s1']);
      final after = await t.api.notesSeen('s1', ['n1']);
      expect(after.unseen, isEmpty);
      expect(seenPosts(t.hub), ['s1: n1']);
      t.hub.shiftNotes = null;
      expect(await t.api.shiftNotes('s1'), isNull);
    });

    test("a manager's calls carry the token", () async {
      final t = await _bare();
      t.hub.shiftNotes = [];
      final written = await t.api.writeNote('tok-admin', text: 'Out: lobster', lasts: 'tonight');
      expect(t.hub.notesAuth, 'Bearer tok-admin');
      expect(t.hub.notesWritten.single, {'text': 'Out: lobster', 'lasts': 'tonight'});
      await t.api.changeNote('tok-admin', written.id, text: 'Out: lobster, crab', lasts: 'stays');
      expect(t.hub.notesChanged.single.$2, {'text': 'Out: lobster, crab', 'lasts': 'stays'});
      final board = await t.api.notesBoard('tok-admin');
      expect(
        (board.notes.single.text, board.notes.single.stays, board.staff, board.most),
        ('Out: lobster, crab', true, 4, 12),
      );
      await t.api.takeNoteDown('tok-admin', written.id);
      expect(t.hub.notesDown, [written.id]);

      t.hub.logbook = fiveEntries();
      final log = await t.api.logbook('tok-admin', subject: 'repairs', find: ' cooler ', before: 'e5');
      expect(t.hub.logAsks.single, {'subject': 'repairs', 'q': 'cooler', 'before': 'e5'});
      expect([for (final e in log.entries) e.id], ['e2']);
      expect((log.count, t.hub.logAuth), (2, 'Bearer tok-admin'));
      expect((await t.api.logbook('tok-admin')).entries.length, 5);
      expect(t.hub.logAsks.last, isEmpty);
      final entry = await t.api.writeLogEntry('tok-admin', subject: 'bar', text: 'Keg changed', device: 't1');
      expect(t.hub.logWritten.single, {'subject': 'bar', 'text': 'Keg changed', 'device': 't1'});
      expect((await t.api.strikeLogEntry('tok-admin', entry.id)).struck, isTrue);
    });
  });

  group('once after signing in', () {
    testWidgets('a note comes up once, with one button, and the hub is told who has seen it', (tester) async {
      final t = await amyWith(tester, [note('n1', 'Specials: salt and pepper squid.\nOut tonight: lobster.')]);
      await pumpFloor(tester, t);
      expect(dialog, findsOneWidget);
      expect(find.text('A note for the shift'), findsOneWidget);
      expect(find.text('Specials: salt and pepper squid.\nOut tonight: lobster.'), findsOneWidget);
      expect(find.textContaining('Mike, '), findsOneWidget);
      expect(find.textContaining('For tonight'), findsOneWidget);
      expect(t.hub.notesAsks, ['s1']);

      // a note is read, not brushed away: a tap beside it leaves it up
      await tester.tapAt(const Offset(8, 8));
      await tester.pumpAndSettle();
      expect(dialog, findsOneWidget);
      expect(t.hub.notesSeenPosts, isEmpty);

      await tester.tap(gotIt);
      await tester.pumpAndSettle();
      expect(dialog, findsNothing);
      expect(seenPosts(t.hub), ['s1: n1']);

      // she signs in again: it is read for her and not shown a second time
      await signIn(tester, t, amy);
      expect(t.hub.notesAsks, ['s1', 's1']);
      expect(dialog, findsNothing);
      expect(t.hub.notesSeenPosts.length, 1);
      await stop(tester);
    });

    testWidgets('several notes come up together, the newest first', (tester) async {
      final t = await amyWith(tester, [
        note('n2', 'Table 12 is a birthday: a candle with dessert.', atMs: ms(15, 50)),
        note('n1', 'Out tonight: lobster.'),
        note('n0', 'Staff meeting Saturday at 3.', stays: true, seenBy: ['s3', 's1']),
      ]);
      await pumpFloor(tester, t);
      expect(find.text('2 notes for the shift'), findsOneWidget);
      final first = tester.getTopLeft(find.byKey(const ValueKey('shift-note:n2'))).dy;
      expect(first, lessThan(tester.getTopLeft(find.byKey(const ValueKey('shift-note:n1'))).dy));
      expect(find.byKey(const ValueKey('shift-note:n0')), findsNothing, reason: 'she has seen that one');
      await tester.tap(gotIt);
      await tester.pumpAndSettle();
      expect(t.hub.notesSeenPosts.single.$2, ['n2', 'n1']);
      await stop(tester);
    });

    testWidgets('while a note is up the menu offers the notes to read again; a server cannot change them', (
      tester,
    ) async {
      final t = await amyWith(tester, [
        note('n1', 'Out tonight: lobster.', seenBy: ['s3', 's1']),
      ]);
      await pumpFloor(tester, t);
      expect(dialog, findsNothing, reason: 'seen already');
      await openHome(tester, 'notes');
      await tester.pumpAndSettle();
      expect(find.byType(ShiftNotesScreen), findsOneWidget);
      expect(find.text('Out tonight: lobster.'), findsOneWidget);
      expect(find.byKey(const ValueKey('notes-unlock')), findsNothing);
      expect(find.byKey(const ValueKey('note-write')), findsNothing);
      expect(find.byKey(const ValueKey('note-change:n1')), findsNothing);
      await stop(tester);
    });

    testWidgets('on a phone the notes are in the More menu, and with none up they take no room', (tester) async {
      final t = await amyWith(tester, [
        note('n1', 'Out tonight: lobster.', seenBy: ['s3', 's1']),
      ]);
      await pumpFloor(tester, t, size: const Size(390, 844));
      await openMore(tester);
      expect(find.descendant(of: homeTile('notes'), matching: find.text('1 up')), findsOneWidget);
      await tester.tap(homeTile('notes'));
      await tester.pumpAndSettle();
      expect(find.byType(ShiftNotesScreen), findsOneWidget);
      await stop(tester);

      final none = await amyWith(tester, []);
      await pumpFloor(tester, none, size: const Size(390, 844));
      expect(dialog, findsNothing);
      await openMore(tester);
      expect(find.text('Sign out'), findsOneWidget);
      expect(homeTile('notes'), findsNothing);
      await stop(tester);
    });

    testWidgets('whoever signs in next on the same screen gets the notes they have not seen', (tester) async {
      final t = await amyWith(tester, [
        note('n1', 'Out tonight: lobster.', seenBy: ['s3', 's1']),
      ]);
      await pumpFloor(tester, t);
      expect(dialog, findsNothing);
      await signIn(tester, t, ben);
      expect(dialog, findsOneWidget);
      await tester.tap(gotIt);
      await tester.pumpAndSettle();
      expect(seenPosts(t.hub), ['s2: n1']);
      await stop(tester);
    });

    testWidgets('a screen that changed hands under a note marks nobody who did not read it', (tester) async {
      final t = await amyWith(tester, [note('n1', 'Out tonight: lobster.')]);
      await pumpFloor(tester, t);
      expect(dialog, findsOneWidget); // Amy's, and she walks away
      await signIn(tester, t, ben);
      await tester.tap(gotIt); // Ben taps it
      await tester.pumpAndSettle();
      // Amy has not seen it, and the note comes up for Ben as his own
      expect(dialog, findsOneWidget);
      expect(t.hub.notesSeenPosts, isEmpty);
      await tester.tap(gotIt);
      await tester.pumpAndSettle();
      expect(dialog, findsNothing);
      expect(seenPosts(t.hub), ['s2: n1']);
      await stop(tester);
    });

    testWidgets('a hub that could not keep it is told again later, and the note does not come up twice', (
      tester,
    ) async {
      final t = await amyWith(tester, [note('n1', 'Out tonight: lobster.')]);
      t.hub.refuseNotesSeen = 503; // a standby: it reads, and writes nothing
      await pumpFloor(tester, t);
      await tester.tap(gotIt);
      await tester.pumpAndSettle();
      expect(dialog, findsNothing);
      expect(t.hub.notesSeenPosts, isEmpty);

      await signIn(tester, t, amy);
      expect(dialog, findsNothing, reason: 'she tapped Got it: not again on this screen');
      t.hub.refuseNotesSeen = null;
      await signIn(tester, t, amy);
      expect(dialog, findsNothing);
      expect(seenPosts(t.hub), ['s1: n1']);
      await stop(tester);
    });

    testWidgets('a hub older than the notes shows nothing and offers nothing', (tester) async {
      final t = await amyWith(tester, null);
      await pumpFloor(tester, t);
      expect(dialog, findsNothing);
      expect(homeIds(tester), isNot(contains('notes')));
      expect(find.byKey(const ValueKey('home-sign-out')), findsOneWidget);
      await stop(tester);
    });

    testWidgets('a note put up in the middle of service comes up over the list, never over an open check', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final settings = Settings(
        device: 't1',
        endpoints: ['http://hub:8000'],
        prefs: await SharedPreferences.getInstance(),
      );
      final hub = Hub();
      final live = LiveHub(hub);
      final api = PosApi(settings, client: live.client);
      final session = Session(api)..staff = amyStaff;
      final outbox = Outbox(api, settings, store: MemoryStore());
      final photos = PhotoQueue(api, settings, NoCamera(), session, store: MemoryStore());
      final t = Terminal(hub, api, outbox, photos, session, settings);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      api.live.start();
      await pumpFloor(tester, t);
      live.hello();
      live.beats();
      await tester.pumpAndSettle();
      expect(api.live.isLive, isTrue);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(dialog, findsNothing);

      // a manager puts a note up at another screen: the hub says the notes changed
      hub.shiftNotes!.insert(0, note('n1', 'Rush on wok 2: quote 30 minutes.'));
      final asked = hub.notesAsks.length;
      live.changed(topics: ['notes']);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));
      await tester.pumpAndSettle();
      expect(hub.notesAsks.length, asked + 1);
      expect(find.text('Rush on wok 2: quote 30 minutes.'), findsOneWidget);
      await tester.tap(gotIt);
      await tester.pumpAndSettle();
      expect(hub.notesSeenPosts.single.$2, ['n1']);

      // a check is open over the list: the next note waits
      final navigator = Navigator.of(tester.element(find.byType(OrdersScreen)));
      navigator.push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('an open check'))));
      await tester.pumpAndSettle();
      hub.shiftNotes!.insert(0, note('n2', 'Out now: crab.'));
      final before = hub.notesAsks.length;
      live.changed(topics: ['notes']);
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      expect(dialog, findsNothing);
      expect(hub.notesAsks.length, before, reason: 'nothing is read under an open check');

      // back at the list it comes up
      navigator.pop();
      await tester.pumpAndSettle();
      expect(find.text('Out now: crab.'), findsOneWidget);
      await tester.tap(gotIt);
      await tester.pumpAndSettle();
      expect(hub.notesSeenPosts.last.$2, ['n2']);

      await stop(tester);
      live.close();
      api.dispose();
      await tester.pump();
    });

    testWidgets('on a 320-wide phone a long note scrolls and the button stays on the screen', (tester) async {
      final long = List.filled(14, 'Specials tonight: salt and pepper squid.').join(' ');
      final t = await amyWith(tester, [
        note('n2', long.substring(0, 500), atMs: ms(15, 50)),
        note('n1', 'Out tonight: lobster, crab, sea bass and the duck.'),
      ]);
      await pumpFloor(tester, t, size: const Size(320, 568));
      expect(find.text('2 notes for the shift'), findsOneWidget);
      final button = tester.getRect(gotIt);
      expect(button.bottom, lessThanOrEqualTo(568));
      expect(button.right, lessThanOrEqualTo(320));
      await tester.tap(gotIt);
      await tester.pumpAndSettle();
      expect(t.hub.notesSeenPosts.single.$2, ['n2', 'n1']);
      await stop(tester);
    });

    testWidgets('the dialog words each note with who wrote it and how long it is up', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ShiftNotesDialog(
            now: at(16, 2),
            notes: [
              ShiftNote.fromJson(note('n1', 'Out tonight: lobster.')),
              ShiftNote.fromJson(note('n0', 'Staff meeting Saturday at 3.', stays: true, atMs: ms(21, 0, 15))),
            ],
          ),
        ),
      );
      expect(find.text('Mike, today 15:40 · For tonight'), findsOneWidget);
      expect(find.text('Mike, yesterday 21:00 · Until taken down'), findsOneWidget);
    });
  });

  group('the notes screen', () {
    testWidgets('with no note up it says so, and only a manager is offered to write one', (tester) async {
      final t = await amyWith(tester, []);
      await pumpNotes(tester, t);
      expect(find.text('No note is up.'), findsOneWidget);
      expect(find.byKey(const ValueKey('notes-unlock')), findsNothing);

      final m = await terminal(tester);
      await pumpNotes(tester, m);
      expect(find.textContaining('No note is up. Write one'), findsOneWidget);
      expect(find.byKey(const ValueKey('notes-unlock')), findsOneWidget);
      expect(m.hub.pins, isEmpty, reason: 'reading asks for no PIN');
    });

    testWidgets("a manager's PIN shows who has seen each note, and a new note goes up", (tester) async {
      final t = await terminal(tester);
      t.hub.shiftNotes = [
        note('n1', 'Out tonight: lobster.', seenBy: ['s3', 's1']),
      ];
      await pumpNotes(tester, t);
      expect(find.text('Mike, today 15:40 · For tonight'), findsOneWidget);
      expect(find.byKey(const ValueKey('note-write')), findsNothing);
      expect(find.textContaining('Seen by'), findsNothing);

      await unlock(tester);
      expect(t.hub.pins, ['9999']);
      expect(t.hub.notesAuth, 'Bearer tok-admin');
      expect(find.text('Seen by 2 of 4 · not yet: Ben, Holly'), findsOneWidget);
      expect(find.byKey(const ValueKey('notes-unlock')), findsNothing);

      await tapKey(tester, 'note-write');
      expect(find.text('A note for the shift'), findsOneWidget);
      expect(enabled(tester, 'note-save'), isFalse);
      await tester.enterText(find.byKey(const ValueKey('note-text')), '  Staff meeting Saturday at 3.  ');
      await tester.pump();
      expect(find.text('It comes down by itself when the night is over.'), findsOneWidget);
      await tapKey(tester, 'note-lasts:stays');
      expect(find.text('It stays up until a manager takes it down.'), findsOneWidget);
      await tapKey(tester, 'note-save');
      expect(t.hub.notesWritten.single, {'text': 'Staff meeting Saturday at 3.', 'lasts': 'stays'});
      expect(find.byKey(const ValueKey('note-up')), findsOneWidget);
      expect(find.text('Staff meeting Saturday at 3.'), findsOneWidget);
      expect(find.text('Mike, today 16:02 · Until taken down'), findsOneWidget);
      expect(find.text('Seen by 1 of 4 · not yet: Amy, Ben, Holly'), findsOneWidget);
      expect(t.hub.pins.length, 1, reason: 'the PIN is asked once');
    });

    testWidgets('new words show a note to everybody again; only how long it is up does not', (tester) async {
      final t = await terminal(tester);
      t.hub.shiftNotes = [
        note('n1', 'Out tonight: lobster.', seenBy: ['s3', 's1', 's2']),
      ];
      await pumpNotes(tester, t);
      await unlock(tester);
      expect(find.text('Seen by 3 of 4 · not yet: Holly'), findsOneWidget);

      await tapKey(tester, 'note-change:n1');
      expect(find.text('Change the note'), findsOneWidget);
      expect(find.text('New words show the note to everybody again.'), findsOneWidget);
      expect(enabled(tester, 'note-save'), isFalse, reason: 'nothing is changed yet');
      await tapKey(tester, 'note-lasts:stays');
      await tapKey(tester, 'note-save');
      expect(t.hub.notesChanged.single.$2, {'text': 'Out tonight: lobster.', 'lasts': 'stays'});
      expect(find.text('Changed.'), findsOneWidget);
      expect(find.text('Seen by 3 of 4 · not yet: Holly'), findsOneWidget);

      await tapKey(tester, 'note-change:n1');
      await tester.enterText(find.byKey(const ValueKey('note-text')), 'Out tonight: lobster and crab.');
      await tester.pump();
      await tapKey(tester, 'note-save');
      expect(t.hub.notesChanged.last.$2, {'text': 'Out tonight: lobster and crab.', 'lasts': 'stays'});
      expect(find.text('Changed. Everybody sees it again.'), findsOneWidget);
      expect(find.text('Seen by 1 of 4 · not yet: Amy, Ben, Holly'), findsOneWidget);
      expect(find.textContaining('changed today 16:02'), findsOneWidget);
    });

    testWidgets('a note taken down is asked about first, and stays in the list of those that came down', (
      tester,
    ) async {
      final t = await terminal(tester);
      t.hub.shiftNotes = [
        note('n1', 'Out tonight: lobster.', seenBy: ['s3', 's1']),
      ];
      await pumpNotes(tester, t);
      await unlock(tester);
      await tapKey(tester, 'note-down:n1');
      expect(find.text('Take this note down?'), findsOneWidget);
      await tester.tap(find.text('Keep it up'));
      await tester.pumpAndSettle();
      expect(t.hub.notesDown, isEmpty);

      await tapKey(tester, 'note-down:n1');
      await tapKey(tester, 'note-down-sure');
      expect(t.hub.notesDown, ['n1']);
      expect(find.byKey(const ValueKey('notes-none')), findsOneWidget);
      expect(find.text('Came down in the last 14 days'), findsOneWidget);
      expect(find.text('Out tonight: lobster.'), findsOneWidget);
      expect(find.text('Taken down by Mike, today 16:02 · seen by 2'), findsOneWidget);
      expect(find.byKey(const ValueKey('note-change:n1')), findsNothing);
    });

    testWidgets('a tap on who has seen a note lists them with the time, and who has not yet', (tester) async {
      final t = await terminal(tester);
      t.hub.shiftNotes = [
        note('n1', 'Out tonight: lobster.', seenBy: ['s3', 's1']),
      ];
      await pumpNotes(tester, t, token: 'tok-admin');
      expect(t.hub.pins, isEmpty, reason: 'Location has the PIN already');
      await tapKey(tester, 'note-seen:n1');
      final sheet = find.byKey(const ValueKey('note-who'));
      expect(find.descendant(of: sheet, matching: find.text('Seen by 2 of 4')), findsOneWidget);
      expect(find.descendant(of: sheet, matching: find.text('Ben, Holly')), findsOneWidget);
      expect(find.descendant(of: sheet, matching: find.text('Mike')), findsOneWidget);
      expect(find.descendant(of: sheet, matching: find.text('Amy')), findsOneWidget);
      expect(find.descendant(of: sheet, matching: find.text('today 15:40')), findsNWidgets(2));
    });

    testWidgets('what the hub refuses is said in its own words', (tester) async {
      final t = await terminal(tester);
      t.hub.shiftNotes = [];
      t.hub.refuseNote = (409, 'too_many', '12 notes are up already. Take one down first.');
      await pumpNotes(tester, t, token: 'tok-admin');
      await tapKey(tester, 'note-write');
      await tester.enterText(find.byKey(const ValueKey('note-text')), 'One more');
      await tester.pump();
      await tapKey(tester, 'note-save');
      expect(find.text('12 notes are up already. Take one down first.'), findsOneWidget);
      expect(find.byKey(const ValueKey('note-up')), findsNothing);
    });

    testWidgets("when the manager's hour is over the screen goes back to reading and asks the PIN again", (
      tester,
    ) async {
      final t = await terminal(tester);
      t.hub.shiftNotes = [note('n1', 'Out tonight: lobster.')];
      await pumpNotes(tester, t);
      await unlock(tester);
      t.hub.refuseNotes = 401;
      await tapKey(tester, 'note-down:n1');
      await tapKey(tester, 'note-down-sure');
      expect(find.textContaining("The manager's hour is over"), findsOneWidget);
      expect(find.byKey(const ValueKey('notes-unlock')), findsOneWidget);
      expect(find.byKey(const ValueKey('note-down:n1')), findsNothing);
      expect(find.text('Out tonight: lobster.'), findsOneWidget);

      // opened from Location, there is no PIN to ask for here: it says to open Location again
      await pumpNotes(tester, t, token: 'tok-old');
      expect(find.byKey(const ValueKey('notes-error')), findsOneWidget);
      expect(find.textContaining('open Location again'), findsOneWidget);
      t.hub.refuseNotes = null;
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('note-write')), findsOneWidget);
    });

    testWidgets('a hub older than the notes says so', (tester) async {
      final t = await terminal(tester);
      t.hub.shiftNotes = null;
      await pumpNotes(tester, t);
      expect(find.byKey(const ValueKey('notes-old')), findsOneWidget);
      expect(find.byKey(const ValueKey('notes-unlock')), findsNothing);
    });

    testWidgets('on a 320-wide phone the notes, the form and the questions fit', (tester) async {
      final t = await terminal(tester);
      const names = [
        'Amy',
        'Ben',
        'Mike',
        'Holly',
        'Xiaoling',
        'Guillermo',
        'Anastasia',
        'Bartholomew',
        'Josephine',
        'Max',
      ];
      t.hub.notesStaff = {for (final (at, name) in names.indexed) 's${at + 1}': name};
      t.hub.shiftNotes = [
        note(
          'n2',
          List.filled(12, 'Specials: salt and pepper squid, soft shell crab.').join(' ').substring(0, 500),
          stays: true,
        ),
        note('n1', 'Out tonight: lobster.'),
      ];
      await pumpNotes(tester, t, token: 'tok-admin', size: const Size(320, 568));
      expect(find.textContaining('Seen by 1 of 10 · not yet: Amy, Ben, Holly, Xiaoling'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('note-seen:n2'))); // under 500 letters of note
      await tester.pumpAndSettle();
      await tapKey(tester, 'note-seen:n2');
      expect(find.byKey(const ValueKey('note-waiting')), findsOneWidget);
      await tester.tapAt(const Offset(160, 20));
      await tester.pumpAndSettle();
      // the second note is under the long one, a scroll away
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('note-down:n1')),
        150,
        scrollable: find
            .descendant(of: find.byKey(const ValueKey('notes-list')), matching: find.byType(Scrollable))
            .first,
      );
      await tester.pumpAndSettle();
      await tapKey(tester, 'note-change:n1');
      expect(find.text('Change the note'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await tapKey(tester, 'note-down:n1');
      expect(find.text('Take this note down?'), findsOneWidget);
      await tester.tap(find.text('Keep it up'));
      await tester.pumpAndSettle();
      await tapKey(tester, 'note-write');
      expect(find.text('Put it up'), findsOneWidget);
    });

    testWidgets('Location settings opens the notes with the manager already known', (tester) async {
      final t = await terminal(tester);
      t.hub.shiftNotes = [note('n1', 'Out tonight: lobster.')];
      await tester.pumpWidget(
        MaterialApp(
          home: LocationSettingsScreen(api: t.api, token: 'tok-admin', device: 't1'),
        ),
      );
      await tester.pumpAndSettle();
      await bringUp(tester, 'shift-notes');
      await tapKey(tester, 'shift-notes');
      expect(find.byType(ShiftNotesScreen), findsOneWidget);
      expect(find.byKey(const ValueKey('note-write')), findsOneWidget);
      expect(t.hub.notesAuth, 'Bearer tok-admin');
      expect(t.hub.pins, isEmpty);
    });
  });

  group("the manager's log", () {
    testWidgets('it is read with the newest entry first, under its day of service, with a chip per subject', (
      tester,
    ) async {
      final t = await terminal(tester);
      t.hub.logbook = fiveEntries();
      await pumpLog(tester, t);
      expect(t.hub.logAuth, 'Bearer tok-admin');
      for (final chip in ['All 5', 'Guests 1', 'Staff 1', 'Repairs 2', 'Deliveries 1']) {
        expect(find.text(chip), findsOneWidget, reason: chip);
      }
      expect(find.textContaining('Kitchen'), findsNothing, reason: 'nothing is written under it');
      for (final day in ['Today', 'Yesterday', 'Sat Nov 14', 'Thu Nov 12']) {
        expect(find.text(day), findsOneWidget, reason: day);
      }
      expect(find.text('Repairs · 15:10 · Mike'), findsOneWidget);
      expect(find.text('Repairs · 00:40 · Mike'), findsOneWidget);
      double top(String id) => tester.getTopLeft(find.byKey(ValueKey('log:$id'))).dy;
      final tops = [top('e5'), top('e4'), top('e3'), top('e2'), top('e1')];
      expect(tops, [...tops]..sort(), reason: 'the newest is first');
      expect(find.text('The newest first.'), findsOneWidget);
    });

    testWidgets('a chip narrows the log to its subject, and the box finds every word in the whole log', (tester) async {
      final t = await terminal(tester);
      t.hub.logbook = fiveEntries();
      await pumpLog(tester, t);
      await tapKey(tester, 'log-of:repairs');
      expect(t.hub.logAsks.last, {'subject': 'repairs'});
      expect(find.byKey(const ValueKey('log:e5')), findsOneWidget);
      expect(find.byKey(const ValueKey('log:e2')), findsOneWidget);
      expect(find.byKey(const ValueKey('log:e4')), findsNothing);
      expect(find.text('All 5'), findsOneWidget, reason: 'the chips still count every subject');
      await tapKey(tester, 'log-of:all');
      expect(find.byKey(const ValueKey('log:e4')), findsOneWidget);

      // the hub is asked once the typing stops, not for each letter
      final asks = t.hub.logAsks.length;
      await tester.enterText(find.byKey(const ValueKey('log-find')), 'CALLED');
      await tester.pump(const Duration(milliseconds: 200));
      await tester.enterText(find.byKey(const ValueKey('log-find')), 'called tom');
      await tester.pump(const Duration(milliseconds: 200));
      expect(t.hub.logAsks.length, asks);
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
      expect(t.hub.logAsks.length, asks + 1);
      expect(t.hub.logAsks.last, {'q': 'called tom'});
      expect(find.byKey(const ValueKey('log:e2')), findsOneWidget);
      expect(find.byKey(const ValueKey('log:e5')), findsNothing);
      expect(find.text('All 1'), findsOneWidget);
      expect(find.text('Entries holding every word, the newest first.'), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('log-find')), 'lobster');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.text('No entry holds that.'), findsOneWidget);
      await tapKey(tester, 'log-find-clear');
      expect(find.text('All 5'), findsOneWidget);
      expect(find.byKey(const ValueKey('log:e1')), findsOneWidget);
    });

    testWidgets('an entry is written under a subject, and is at the top at once', (tester) async {
      final t = await terminal(tester);
      t.hub.logbook = fiveEntries();
      await pumpLog(tester, t);
      await tapKey(tester, 'log-write');
      expect(find.text('What is it about?'), findsOneWidget);
      expect(find.text('An entry cannot be changed later, only struck out.'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('log-text')), ' Wok 2 burner is weak again. ');
      await tester.pump();
      expect(enabled(tester, 'log-save'), isFalse, reason: 'no subject is picked');
      await tapKey(tester, 'log-subject:kitchen');
      await tapKey(tester, 'log-save');
      expect(t.hub.logWritten.single, {'subject': 'kitchen', 'text': 'Wok 2 burner is weak again.', 'device': 't1'});
      expect(find.byKey(const ValueKey('log-written')), findsOneWidget);
      expect(find.text('Kitchen · 16:02 · Mike'), findsOneWidget);
      expect(find.text('All 6'), findsOneWidget);
      expect(find.text('Kitchen 1'), findsOneWidget);
      final written = tester.getTopLeft(find.text('Wok 2 burner is weak again.')).dy;
      expect(written, lessThan(tester.getTopLeft(find.byKey(const ValueKey('log:e5'))).dy));

      // narrowed to a subject, a new entry starts under it
      await tapKey(tester, 'log-of:repairs');
      await tapKey(tester, 'log-write');
      expect(tester.widget<ChoiceChip>(find.byKey(const ValueKey('log-subject:repairs'))).selected, isTrue);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(t.hub.logWritten.length, 1);
    });

    testWidgets('a mistaken entry is struck out and stays readable; nothing is deleted', (tester) async {
      final t = await terminal(tester);
      t.hub.logbook = fiveEntries();
      await pumpLog(tester, t);
      await tapKey(tester, 'log-strike:e4');
      expect(find.text('Strike this entry out?'), findsOneWidget);
      await tester.tap(find.text('Leave it'));
      await tester.pumpAndSettle();
      expect(t.hub.logStruck, isEmpty);

      await tapKey(tester, 'log-strike:e4');
      await tapKey(tester, 'log-strike-sure');
      expect(t.hub.logStruck, ['e4']);
      expect(find.text('Holly covers Saturday for Amy.'), findsOneWidget);
      final words = tester.widget<Text>(find.text('Holly covers Saturday for Amy.'));
      expect(words.style?.decoration, TextDecoration.lineThrough);
      expect(find.text('Struck out by Mike, today 16:02'), findsOneWidget);
      expect(find.byKey(const ValueKey('log-strike:e4')), findsNothing);
      expect(find.text('All 4'), findsOneWidget);
      expect(find.text('Staff 1'), findsNothing, reason: 'a struck entry is not counted');
    });

    testWidgets('older entries are read a page at a time', (tester) async {
      final t = await terminal(tester);
      t.hub.logbook = fiveEntries();
      t.hub.logPage = 2;
      await pumpLog(tester, t);
      expect(find.byKey(const ValueKey('log:e4')), findsOneWidget);
      expect(find.byKey(const ValueKey('log:e3')), findsNothing);
      await tapKey(tester, 'log-older');
      expect(t.hub.logAsks.last, {'before': 'e4'});
      expect(find.byKey(const ValueKey('log:e2')), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('log-older')));
      await tapKey(tester, 'log-older');
      expect(t.hub.logAsks.last, {'before': 'e2'});
      expect(find.byKey(const ValueKey('log-older')), findsNothing);
      await tester.ensureVisible(find.byKey(const ValueKey('log:e1')));
      expect(find.byKey(const ValueKey('log:e1')), findsOneWidget);
    });

    testWidgets('an empty log, an older hub and a session that ran out each say so', (tester) async {
      final t = await terminal(tester);
      await pumpLog(tester, t);
      expect(find.text('All 0'), findsOneWidget);
      expect(find.text('Nothing is written yet. Write what the next manager should know.'), findsOneWidget);

      t.hub.logbook = null;
      await pumpLog(tester, t);
      expect(find.textContaining("This hub is older than the manager's log"), findsOneWidget);
      expect(find.byKey(const ValueKey('log-write')), findsNothing);

      t.hub.logbook = fiveEntries();
      t.hub.refuseLog = 401;
      await pumpLog(tester, t);
      expect(find.textContaining('open Location again'), findsOneWidget);
      t.hub.refuseLog = null;
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(find.text('All 5'), findsOneWidget);
    });

    testWidgets('on a 320-wide phone the log and the form to write in it fit', (tester) async {
      final t = await terminal(tester);
      t.hub.logbook = [
        entry(
          'e9',
          'deliveries',
          List.filled(8, 'The fish order came short again and the driver left no slip.').join(' '),
          ms(15, 10),
          '2026-11-16',
        ),
        ...fiveEntries(),
        entry(
          'e0',
          'money',
          'Deposit bag 114 dropped at the bank.',
          ms(23, 0, 11),
          '2026-11-11',
          struckMs: ms(23, 30, 11),
          struckBy: 'Guillermo',
        ),
        entry('k1', 'kitchen', 'Wok 2 burner weak.', ms(21, 0, 11), '2026-11-11'),
        entry('b1', 'bar', 'Keg changed.', ms(20, 0, 11), '2026-11-11'),
        entry('o1', 'other', 'Snow shovelled.', ms(19, 0, 11), '2026-11-11'),
      ];
      await pumpLog(tester, t, size: const Size(320, 568));
      expect(find.text('All 9'), findsOneWidget);
      expect(find.text('Other 1'), findsOneWidget);
      await tapKey(tester, 'log-write');
      for (final (id, _) in Hub.logSubjects) {
        expect(find.byKey(ValueKey('log-subject:$id')), findsOneWidget);
      }
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      // the first entry is under the chips and the box, a scroll away on so small a screen
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('log-strike:e9')),
        150,
        scrollable: find
            .descendant(of: find.byKey(const ValueKey('log-list')), matching: find.byType(Scrollable))
            .first,
      );
      await tester.pumpAndSettle();
      await tapKey(tester, 'log-strike:e9');
      expect(find.text('Strike this entry out?'), findsOneWidget);
    });

    testWidgets("Location settings opens the log with the manager's token", (tester) async {
      final t = await terminal(tester);
      t.hub.logbook = fiveEntries();
      await tester.pumpWidget(
        MaterialApp(
          home: LocationSettingsScreen(api: t.api, token: 'tok-admin', device: 't1'),
        ),
      );
      await tester.pumpAndSettle();
      await bringUp(tester, 'logbook');
      await tapKey(tester, 'logbook');
      expect(find.byType(LogbookScreen), findsOneWidget);
      expect((t.hub.logAuth, find.text('All 5').evaluate().length), ('Bearer tok-admin', 1));
    });
  });

  test('the feed says when the notes changed', () {
    expect(const LiveChange(notes: true).toString(), 'LiveChange(notes)');
    expect(const LiveChange(notes: true).anyOrder, isFalse, reason: 'no order is read for it');
  });
}

/// A hub and the calls to it, with no screen.
Future<Terminal> _bare() async {
  SharedPreferences.setMockInitialValues({});
  final settings = Settings(device: 't1', endpoints: ['http://hub:8000'], prefs: await SharedPreferences.getInstance());
  final hub = Hub();
  final api = PosApi(settings, client: MockClient(hub.handle));
  final session = Session(api);
  return Terminal(
    hub,
    api,
    Outbox(api, settings, store: MemoryStore()),
    PhotoQueue(api, settings, NoCamera(), session, store: MemoryStore()),
    session,
    settings,
  );
}
