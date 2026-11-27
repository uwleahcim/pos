import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/screens/order_screen.dart';
import 'package:pos_app/screens/theme.dart';
import 'package:pos_app/screens/waitlist_screen.dart';
import 'package:pos_app/session.dart';
import 'package:pos_app/settings.dart';
import 'package:pos_app/table_timers.dart' show TimerLevel;
import 'package:pos_app/waitlist.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'hub.dart';
import 'table_moves_test.dart' show byHolly, byMike, checkAt, floorThatMoves, sentTo;
import 'table_servers_test.dart' show amy, holly, mike, sentOne;

/// The waitlist (the Toast comparison's row 14): the parties waiting for a table, in the order they came,
/// each with how long it has waited beside the wait it was told. A party is put on the list, sits down at a
/// table tapped on the floor map, or goes off the list because it left; one taken off by mistake is put back.

const minute = 60000;

/// Seven in the evening on the hub's clock, for the tests that pump the list by itself.
final seven = DateTime(2026, 11, 16, 19).millisecondsSinceEpoch;

/// Chen came 12 minutes ago and was told 20; Garcia 31 minutes ago and was told 30 (late); Okafor 4 minutes
/// ago with no time told.
List<Map<String, dynamic>> three(int now) => [
  Hub.waitParty('p1', 'Garcia', 2, atMs: now - 31 * minute, quoted: 30, phone: '781 555 0102'),
  Hub.waitParty('p2', 'Chen', 4, atMs: now - 12 * minute, quoted: 20, note: 'High chair'),
  Hub.waitParty('p3', 'Okafor', 6, atMs: now - 4 * minute, by: 'Amy'),
];

Finder key(String name) => find.byKey(ValueKey(name));

Future<void> tapKey(WidgetTester tester, String name) async {
  await tester.tap(key(name));
  await tester.pumpAndSettle();
}

/// The names of the parties waiting, top to bottom.
List<String> waiting(WidgetTester tester) {
  final cards = find.byWidgetPredicate(
    (w) => w.key is ValueKey && '${(w.key! as ValueKey).value}'.startsWith('party:'),
  );
  final rows = [
    for (final element in cards.evaluate())
      (
        tester.getTopLeft(find.byWidget(element.widget)).dy,
        tester
            .widget<Text>(find.descendant(of: find.byWidget(element.widget), matching: find.byType(Text)).at(1))
            .data!,
      ),
  ]..sort((a, b) => a.$1.compareTo(b.$1));
  return [for (final row in rows) row.$2];
}

/// The colour behind a party's wait.
Color? pill(WidgetTester tester, String id) =>
    (tester.widget<Container>(key('party-wait:$id')).decoration! as BoxDecoration).color;

/// The waitlist by itself, for [who], on a hub whose clock (and the screen's) reads [now].
Future<(Terminal, List<Object?>)> pumpList(
  WidgetTester tester, {
  Staff who = holly,
  List<Map<String, dynamic>>? parties,
  int Function()? now,
  Size size = const Size(1100, 800),
  bool older = false,
  String? device, // with it, the opened party offers Tags (tag_guest_test.dart)
}) async {
  final t = await terminal(tester);
  tester.view.physicalSize = size;
  t.session.staff = who;
  t.hub.clockNow = (now ?? () => seven)();
  if (!older) t.hub.parties = parties ?? three(seven);
  final popped = <Object?>[];
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () async => popped.add(
                await Navigator.of(context).push<Object?>(
                  MaterialPageRoute(
                    builder: (_) =>
                        WaitlistScreen(api: t.api, staffId: who.staffId, nowMs: now ?? () => seven, device: device),
                  ),
                ),
              ),
              child: const Text('open the list'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open the list'));
  await tester.pumpAndSettle();
  return (t, popped);
}

/// What a change to the list carried, without who made it.
Map<String, dynamic> carried(Hub hub, [int at = -1]) {
  final (_, body) = at < 0 ? hub.waitPosts.last : hub.waitPosts[at];
  return {...body}..remove('staff_id');
}

/// The orders screen of [who] on a hub that keeps a waitlist, the clock of both reading now.
Future<Terminal> pumpFloorWith(
  WidgetTester tester,
  Staff who, {
  List<Map<String, dynamic>> Function(int now)? parties,
  Size? size,
  void Function(Hub hub)? hub,
}) async {
  final t = await terminal(tester);
  if (size != null) tester.view.physicalSize = size;
  t.session.staff = who;
  final now = DateTime.now().millisecondsSinceEpoch;
  t.hub
    ..clockNow = now
    ..floor = floorThatMoves()
    ..parties = (parties ?? three)(now);
  hub?.call(t.hub);
  await pumpOrdersOn(tester, t);
  return t;
}

/// Seat is tapped on [party] of the list, so the floor map is up for its table.
Future<void> seatFromList(WidgetTester tester, String party) async {
  await tapKey(tester, 'waitlist-open');
  expect(find.byType(WaitlistScreen), findsOneWidget);
  await tapKey(tester, 'party-seat:$party');
  expect(find.byType(WaitlistScreen), findsNothing);
}

Finder seatingBar() => key('seating-party-bar');

void main() {
  group('the words', () {
    final chen = WaitParty.fromJson(Hub.waitParty('p2', 'Chen', 4, atMs: seven, quoted: 20));
    final okafor = WaitParty.fromJson(Hub.waitParty('p3', 'Okafor', 1, atMs: seven));

    test('a wait is counted in whole minutes from when the party came', () {
      expect(chen.waitedAt(seven), 0);
      expect(chen.waitedAt(seven + 59999), 0);
      expect(chen.waitedAt(seven + minute), 1);
      expect(chen.waitedAt(seven + 75 * minute), 75);
      expect(chen.waitedAt(seven - 5000), 0); // a screen whose clock runs behind the hub's
      expect(
        (waitWords(0), waitWords(8), waitWords(60), waitWords(65), waitWords(130)),
        ('0 min', '8 min', '1 h 00', '1 h 05', '2 h 10'),
      );
      expect((guestWords(1), guestWords(4)), ('1 guest', '4 guests'));
      expect((chen.label, okafor.label), ('Chen, party of 4', 'Okafor, party of 1'));
      expect((leftWords('left'), leftWords('no_show')), ('Left', 'No-show'));
    });

    test('a wait turns amber five minutes before the time told, and red at it', () {
      expect(chen.levelAt(seven), TimerLevel.ok);
      expect(chen.levelAt(seven + 15 * minute - 1), TimerLevel.ok);
      expect(chen.levelAt(seven + 15 * minute), TimerLevel.warn);
      expect(chen.levelAt(seven + 20 * minute - 1), TimerLevel.warn);
      expect(chen.levelAt(seven + 20 * minute), TimerLevel.late);
      // no time was told: never late, however long
      expect(okafor.levelAt(seven + 300 * minute), TimerLevel.ok);
    });

    test('the next change by the clock is a minute of the wait or a colour, whichever comes first', () {
      expect(chen.nextChange(seven), seven + minute);
      expect(chen.nextChange(seven + 90000), seven + 2 * minute);
      final short = WaitParty.fromJson(Hub.waitParty('p9', 'Lee', 2, atMs: seven + 20000, quoted: 6));
      // amber a minute after they came (06:00 less 5), on no minute of anybody else
      expect(short.amberMs, seven + 20000 + minute);
      expect(short.nextChange(seven + 20000 + 59000), seven + 20000 + minute);
      final list = Waitlist(waiting: [chen, okafor, short]);
      expect(list.levelAt(seven + 16 * minute), TimerLevel.late); // Lee's six minutes are over
      expect(list.levelAt(seven + 30000), TimerLevel.ok);
      expect(list.nextLevelChange(seven), seven + 20000 + minute);
      expect(list.nextLevelChange(seven + 19 * minute), seven + 20 * minute);
      expect(list.nextLevelChange(seven + 20 * minute), isNull);
      expect(const Waitlist().nextChange(seven), isNull);
      expect(Waitlist(waiting: [okafor]).nextLevelChange(seven), isNull);
    });

    test('the hub\'s answer is read, and one this build does not know reads as an empty list', () {
      final hub = Hub()
        ..parties = three(seven)
        ..clockNow = seven;
      final list = Waitlist.fromJson({
        'waiting': hub.parties,
        'earlier': [
          {...Hub.waitParty('p0', 'Silva', 3, atMs: seven - 50 * minute), 'status': 'seated', 'table_label': 'A7'},
        ],
        'counts': {'waiting': 3, 'guests': 12, 'seated': 1, 'left': 0, 'average_wait_minutes': 17},
        'quotes': [10, 20],
        'name_max': 24,
      });
      expect(list.waiting.map((p) => (p.name, p.size, p.quotedMinutes)), [
        ('Garcia', 2, 30),
        ('Chen', 4, 20),
        ('Okafor', 6, null),
      ]);
      expect((list.earlier.single.isSeated, list.earlier.single.tableLabel), (true, 'A7'));
      expect((list.counts.guests, list.counts.averageWaitMinutes), (12, 17));
      expect(list.quotes, [10, 20]);
      final empty = Waitlist.fromJson(const {'waiting': 'soon'});
      expect(empty.waiting, isEmpty);
      expect(empty.earlier, isEmpty);
      expect(empty.quotes, Waitlist.standardQuotes);
      expect(empty.counts.waiting, 0);
    });
  });

  group('the list', () {
    testWidgets('the parties stand in the order they came, each with its wait beside the wait it was told', (
      tester,
    ) async {
      final (t, _) = await pumpList(tester);
      expect(waiting(tester), ['Garcia', 'Chen', 'Okafor']);
      expect(tester.widget<Text>(key('waitlist-count')).data, '3 parties · 12 guests');
      for (final words in ['31 min', 'told 30 min', '12 min', 'told 20 min', 'High chair', '4 min', 'no time told']) {
        expect(find.text(words), findsOneWidget, reason: words);
      }
      // past the time told is red; within it, and with no time told, is plain
      final pos = PosColors.of(tester.element(key('waitlist')));
      expect(pill(tester, 'p1'), pos.timerLate);
      expect(pill(tester, 'p2'), isNot(anyOf(pos.timerLate, pos.timerWarn)));
      expect(pill(tester, 'p3'), pill(tester, 'p2'));
      expect(key('waitlist-earlier'), findsNothing);
      expect(key('waitlist-away'), findsNothing);
      expect(t.hub.waitPosts, isEmpty);
      await stop(tester);
    });

    testWidgets('with nobody waiting it says so', (tester) async {
      await pumpList(tester, parties: []);
      expect(find.text('Nobody is waiting.'), findsOneWidget);
      expect(key('waitlist-count'), findsNothing);
      expect(key('party-add'), findsOneWidget);
      await stop(tester);
    });

    testWidgets('a wait gains its minutes and turns amber, then red, by the clock alone', (tester) async {
      var now = seven;
      await pumpList(tester, now: () => now);
      final pos = PosColors.of(tester.element(key('waitlist')));
      expect(find.text('12 min'), findsOneWidget);
      // three minutes on: Chen is five minutes from the twenty he was told
      now = seven + 3 * minute;
      await tester.pump(const Duration(seconds: 61));
      expect(find.text('15 min'), findsOneWidget);
      expect(pill(tester, 'p2'), pos.timerWarn);
      now = seven + 8 * minute;
      await tester.pump(const Duration(seconds: 61));
      expect(find.text('20 min'), findsOneWidget);
      expect(pill(tester, 'p2'), pos.timerLate);
      expect(find.text('39 min'), findsOneWidget); // Garcia
      await stop(tester);
    });

    testWidgets('Add party asks the name, how many, the wait told, a phone and a note', (tester) async {
      final (t, _) = await pumpList(tester, parties: []);
      await tapKey(tester, 'party-add');
      expect(find.text('Add to the waitlist'), findsOneWidget);
      // nothing is added without a name
      expect(tester.widget<FilledButton>(key('party-save')).onPressed, isNull);
      await tester.enterText(key('party-name'), '  Chen ');
      await tester.pump();
      expect(tester.widget<Text>(key('party-size')).data, '2 guests');
      await tester.tap(key('party-size:4'));
      await tester.pump();
      await tester.tap(key('party-more'));
      await tester.pump();
      expect(tester.widget<Text>(key('party-size')).data, '5 guests');
      await tester.tap(key('party-quote:20'));
      await tester.pump();
      await tester.enterText(key('party-phone'), '781 555 0101');
      await tester.enterText(key('party-note'), 'Booth if there is one');
      await tapKey(tester, 'party-save');

      expect(t.hub.waitPosts.single.$1, 'POST /waitlist');
      expect(t.hub.waitPosts.single.$2, {
        'staff_id': 's4',
        'name': 'Chen',
        'size': 5,
        'phone': '781 555 0101',
        'quoted_minutes': 20,
        'note': 'Booth if there is one',
      });
      expect(find.byType(AlertDialog), findsNothing);
      expect(waiting(tester), ['Chen']);
      expect(find.text('told 20 min'), findsOneWidget);
      expect(tester.widget<Text>(key('waitlist-count')).data, '1 party · 5 guests');
      await stop(tester);
    });

    testWidgets('a party with no time told and no phone is taken as it is', (tester) async {
      final (t, _) = await pumpList(tester, parties: []);
      await tapKey(tester, 'party-add');
      await tester.enterText(key('party-name'), 'Lee');
      await tester.pump();
      await tester.tap(key('party-fewer'));
      await tester.pump();
      expect(tester.widget<Text>(key('party-size')).data, '1 guest');
      expect(tester.widget<IconButton>(key('party-fewer')).onPressed, isNull); // nobody is no party
      await tapKey(tester, 'party-save');
      expect(carried(t.hub), {'name': 'Lee', 'size': 1, 'phone': '', 'quoted_minutes': null, 'note': ''});
      expect(find.text('no time told'), findsOneWidget);
      await stop(tester);
    });

    testWidgets('what the hub does not take is said in the form, which stays open', (tester) async {
      final (t, _) = await pumpList(tester, parties: []);
      await tapKey(tester, 'party-add');
      await tester.enterText(key('party-name'), 'Chen');
      await tester.enterText(key('party-phone'), '555');
      t.hub.refuseWait = (422, 'bad_phone', 'A phone number has 7 digits or more, or is left empty.');
      await tapKey(tester, 'party-save');
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(tester.widget<Text>(key('party-problem')).data, 'A phone number has 7 digits or more, or is left empty.');
      // put right, it goes through
      await tester.enterText(key('party-phone'), '');
      await tapKey(tester, 'party-save');
      expect(find.byType(AlertDialog), findsNothing);
      expect(waiting(tester), ['Chen']);
      await stop(tester);
    });

    testWidgets('a tap on a party offers the rest, and Called marks that it was told its table is ready', (
      tester,
    ) async {
      final (t, _) = await pumpList(tester);
      await tester.tap(find.text('Garcia'));
      await tester.pumpAndSettle();
      expect(find.text('Garcia, party of 2'), findsOneWidget);
      expect(tester.widget<SelectableText>(key('party-sheet-phone')).data, '781 555 0102');
      for (final what in ['seat', 'called', 'change', 'left', 'no_show']) {
        expect(key('party-do:$what'), findsOneWidget, reason: what);
      }
      await tapKey(tester, 'party-do:called');
      expect(t.hub.waitPosts.single.$1, 'POST /waitlist/p1/called');
      expect(carried(t.hub), {'on': true});
      expect(tester.widget<Text>(key('party-called:p1')).data, 'called just now');
      expect(waiting(tester), ['Garcia', 'Chen', 'Okafor']); // it keeps its place

      // called by mistake: the same button takes it back
      await tester.tap(find.text('Garcia'));
      await tester.pumpAndSettle();
      expect(find.descendant(of: key('party-do:called'), matching: find.text('Not called')), findsOneWidget);
      await tapKey(tester, 'party-do:called');
      expect(carried(t.hub), {'on': false});
      expect(key('party-called:p1'), findsNothing);
      await stop(tester);
    });

    testWidgets('Change opens the party as it stands and puts right what it said', (tester) async {
      final (t, _) = await pumpList(tester);
      await tester.tap(find.text('Chen'));
      await tester.pumpAndSettle();
      await tapKey(tester, 'party-do:change');
      expect(find.text('Change Chen'), findsOneWidget);
      expect(tester.widget<Text>(key('party-size')).data, '4 guests');
      expect(tester.widget<ChoiceChip>(key('party-quote:20')).selected, isTrue);
      expect(find.text('Counted from when they came, 12 min ago.'), findsOneWidget);
      expect(tester.widget<TextField>(key('party-note')).controller!.text, 'High chair');
      await tester.tap(key('party-size:6'));
      await tester.pump();
      await tester.tap(key('party-quote:30'));
      await tester.pump();
      await tapKey(tester, 'party-save');
      expect(t.hub.waitPosts.single.$1, 'PUT /waitlist/p2');
      expect(carried(t.hub), {'name': 'Chen', 'size': 6, 'phone': '', 'quoted_minutes': 30, 'note': 'High chair'});
      expect(find.text('told 30 min'), findsNWidgets(2));
      expect(waiting(tester), ['Garcia', 'Chen', 'Okafor']);
      await stop(tester);
    });

    testWidgets('Left and No-show take a party off the list, and it can be put back at once', (tester) async {
      final (t, _) = await pumpList(tester);
      await tester.tap(find.text('Garcia'));
      await tester.pumpAndSettle();
      await tapKey(tester, 'party-do:left');
      expect(t.hub.waitPosts.single.$1, 'POST /waitlist/p1/left');
      expect(carried(t.hub), {'why': 'left'});
      expect(waiting(tester), ['Chen', 'Okafor']);
      expect(find.text('Garcia is off the list'), findsOneWidget);
      // the wrong party: the way back is beside the words
      await tester.tap(find.widgetWithText(SnackBarAction, 'Put back'));
      await tester.pumpAndSettle();
      expect(t.hub.waitPosts.last.$1, 'POST /waitlist/p1/back');
      expect(waiting(tester), ['Garcia', 'Chen', 'Okafor']); // where it stood

      await tester.tap(find.text('Okafor'));
      await tester.pumpAndSettle();
      await tapKey(tester, 'party-do:no_show');
      expect(carried(t.hub), {'why': 'no_show'});
      expect(waiting(tester), ['Garcia', 'Chen']);
      expect(find.text('Okafor is off the list as a no-show'), findsOneWidget);
      await stop(tester);
    });

    testWidgets('the parties that went off the list tonight are underneath, each with a way back', (tester) async {
      final parties = three(seven);
      parties[0].addAll({
        'status': 'seated',
        'seated_ms': seven - 2 * minute,
        'table': 'A7',
        'table_label': 'A7',
        'order_id': 'o1',
        'ended_by': 'Holly',
        'waited_minutes': 29,
      });
      parties[2].addAll({
        'status': 'left',
        'left_ms': seven - minute,
        'left_why': 'no_show',
        'ended_by': 'Amy',
        'waited_minutes': 3,
      });
      final (t, _) = await pumpList(tester, parties: parties);
      expect(waiting(tester), ['Chen']);
      expect(find.text('Earlier tonight · 1 seated · 1 left'), findsOneWidget);
      expect(find.text('Seated after 29 min on average'), findsOneWidget);
      expect(find.text('Okafor'), findsNothing); // folded away until asked for
      await tapKey(tester, 'waitlist-earlier');
      expect(find.text('No-show · after 3 min · Amy'), findsOneWidget);
      expect(find.text('Seated at A7 · after 29 min · Holly'), findsOneWidget);

      await tapKey(tester, 'party-back:p1');
      expect(t.hub.waitPosts.single.$1, 'POST /waitlist/p1/back');
      expect(waiting(tester), ['Garcia', 'Chen']);
      // the check opened for them is another matter, and the words say so
      expect(find.text('Garcia is back on the list. The check at A7 stays as it is.'), findsOneWidget);
      expect(find.text('Earlier tonight · 1 left'), findsOneWidget);
      await stop(tester);
    });

    testWidgets('Seat hands the party to the floor map', (tester) async {
      final (t, popped) = await pumpList(tester);
      await tapKey(tester, 'party-seat:p2');
      expect(find.byType(WaitlistScreen), findsNothing);
      expect((popped.single! as SeatParty).party.name, 'Chen');
      expect(t.hub.waitPosts, isEmpty); // nothing is told until a table is tapped
      await stop(tester);
    });

    testWidgets('with no hub answering it is the list as last read, and a change says why it cannot be made', (
      tester,
    ) async {
      final (t, _) = await pumpList(tester);
      expect(key('waitlist-away'), findsNothing);
      t.hub.waitDown = true;
      await tester.pump(const Duration(seconds: 3)); // the screen asks again, and nothing answers
      await tester.pumpAndSettle();
      expect(key('waitlist-away'), findsOneWidget);
      expect(waiting(tester), ['Garcia', 'Chen', 'Okafor']);
      await tester.tap(find.text('Garcia'));
      await tester.pumpAndSettle();
      await tapKey(tester, 'party-do:left');
      expect(find.textContaining('The hub cannot be reached'), findsNWidgets(2)); // the strip and the line
      expect(waiting(tester), ['Garcia', 'Chen', 'Okafor']);
      // the hub is back: the next reading takes the strip away
      t.hub.waitDown = false;
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(key('waitlist-away'), findsNothing);
      await stop(tester);
    });

    testWidgets('a hub older than the waitlist says so, with nothing to add to', (tester) async {
      await pumpList(tester, older: true);
      expect(key('waitlist-older'), findsOneWidget);
      expect(key('party-add'), findsNothing);
      await stop(tester);
    });

    testWidgets('a party another screen put on the list shows when the hub says the list changed', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final settings = Settings(
        device: 't1',
        endpoints: ['http://hub:8000'],
        prefs: await SharedPreferences.getInstance(),
      );
      final hub = Hub()
        ..clockNow = seven
        ..parties = three(seven);
      final live = LiveHub(hub);
      final api = PosApi(settings, client: live.client);
      tester.view
        ..physicalSize = const Size(1100, 800)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      api.live.start();
      await tester.pumpWidget(
        MaterialApp(
          home: WaitlistScreen(api: api, staffId: 's4', nowMs: () => seven),
        ),
      );
      await tester.pumpAndSettle();
      live.hello();
      live.beats();
      await tester.pumpAndSettle();
      expect(api.live.isLive, isTrue);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(waiting(tester), ['Garcia', 'Chen', 'Okafor']);

      hub.parties!.add(Hub.waitParty('p4', 'Silva', 3, atMs: seven, by: 'Amy'));
      final asks = hub.waitAsks;
      live.changed(topics: ['waitlist']);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1)); // told reads are a second apart at the least
      await tester.pumpAndSettle();
      expect(hub.waitAsks, asks + 1);
      expect(waiting(tester), ['Garcia', 'Chen', 'Okafor', 'Silva']);
      // news of something else reads nothing here
      live.changed(topics: ['notes'], orders: ['o1']);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(hub.waitAsks, asks + 1);

      await stop(tester);
      live.close();
      api.dispose();
      await tester.pump();
    });

    testWidgets('a 320-wide phone: the list, a party\'s buttons and the form fit', (tester) async {
      final parties = three(seven)
        ..add(
          Hub.waitParty(
            'p4',
            'Bartholomew-Fitzgerald X',
            12,
            atMs: seven - 75 * minute,
            quoted: 90,
            note: 'Birthday, two high chairs, by the window if it can be done',
            calledMs: seven - 3 * minute,
          ),
        );
      await pumpList(tester, parties: parties, size: const Size(320, 640));
      expect(tester.takeException(), isNull);
      final screen = tester.getRect(find.byType(Scaffold).first);
      for (final id in ['p1', 'p2', 'p3', 'p4']) {
        final rect = tester.getRect(key('party-seat:$id'));
        expect(rect.left >= 0 && rect.right <= screen.right, isTrue, reason: '$id $rect');
      }
      expect(find.text('1 h 15'), findsOneWidget);
      expect(find.text('called 3 min ago'), findsOneWidget);
      await tester.tap(find.text('Bartholomew-Fitzgerald X'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      for (final what in ['seat', 'called', 'change', 'left', 'no_show']) {
        final rect = tester.getRect(key('party-do:$what'));
        expect(rect.left >= 0 && rect.right <= screen.right && rect.bottom <= screen.bottom, isTrue, reason: what);
      }
      await tapKey(tester, 'party-do:change');
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(key('party-save'));
      final save = tester.getRect(key('party-save'));
      expect(save.right <= screen.right && save.bottom <= screen.bottom, isTrue, reason: '$save');
      await stop(tester);
    });
  });

  group('on the floor', () {
    testWidgets('the waitlist\'s button says how many parties wait, red when one is past its time', (tester) async {
      final t = await pumpFloorWith(tester, mike);
      expect(key('waitlist-open'), findsOneWidget);
      expect(find.descendant(of: key('waitlist-open'), matching: find.text('3')), findsOneWidget);
      expect(key('waitlist-badge:late'), findsOneWidget); // Garcia was told 30 minutes, 31 ago
      expect(find.byTooltip('Waitlist: 3 waiting'), findsOneWidget);
      expect(t.hub.waitPosts, isEmpty);
      await stop(tester);
    });

    testWidgets('with nobody waiting the button has no number, and within the time told it is not red', (tester) async {
      await pumpFloorWith(tester, mike, parties: (_) => []);
      expect(find.byTooltip('Waitlist'), findsOneWidget);
      expect(find.descendant(of: key('waitlist-open'), matching: find.byType(Text)), findsNothing);
      await stop(tester);

      await pumpFloorWith(tester, mike, parties: (now) => [Hub.waitParty('p1', 'Chen', 4, atMs: now, quoted: 20)]);
      expect(key('waitlist-badge:ok'), findsOneWidget);
      await stop(tester);
    });

    testWidgets('a hub older than the waitlist shows no button', (tester) async {
      final t = await pumpFloorWith(tester, mike, hub: (hub) => hub.parties = null);
      expect(key('waitlist-open'), findsNothing);
      expect(find.byTooltip('Waitlist'), findsNothing);
      expect(t.hub.requests.where((r) => r.startsWith('GET /waitlist')), isNotEmpty); // it asked
      await stop(tester);
    });

    testWidgets('on a phone the button shows while a party waits and for whoever gives tables out', (tester) async {
      const phone = Size(390, 800);
      // a server with nobody waiting: the list is in the menu, and the bar keeps its room
      await pumpFloorWith(tester, amy, parties: (_) => [], size: phone);
      expect(key('waitlist-open'), findsNothing);
      await openHome(tester, 'waitlist');
      await tester.pumpAndSettle();
      expect(find.byType(WaitlistScreen), findsOneWidget);
      await stop(tester);

      // a party waits: every phone shows the number, and the menu's tile says how many
      await pumpFloorWith(tester, amy, size: phone);
      expect(key('waitlist-open'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await openMore(tester);
      expect(find.descendant(of: homeTile('waitlist'), matching: find.text('3 waiting')), findsOneWidget);
      await stop(tester);

      // the host has the button whether anybody waits or not
      await pumpFloorWith(tester, holly, parties: (_) => [], size: phone);
      expect(key('waitlist-open'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await stop(tester);
    });

    testWidgets('a server seats a party at a free table: the check opens with its guests, and the list is told', (
      tester,
    ) async {
      final t = await pumpFloorWith(tester, amy);
      await seatFromList(tester, 'p2');
      // the floor map is up, and says what the next tap does
      expect(seatingBar(), findsOneWidget);
      expect(find.text('Seating Chen, party of 4. Tap their table.'), findsOneWidget);
      expect(key('to-go'), findsNothing);
      expect(key('new-tab'), findsNothing);

      await tester.tap(find.text('A8'));
      await tester.pumpAndSettle();
      expect(find.text('Seat Chen at A8'), findsOneWidget);
      expect(find.text('4 guests'), findsOneWidget); // as the list has them
      expect(find.text('Server'), findsNothing); // a server takes the table she seats
      await tapKey(tester, 'seat');

      final (orderId, data) = sentOne(t.hub, 'create');
      expect(data, {'table': 'A8', 'guests': 4, 'order_type': 'dine_in', 'server': 'Amy', 'server_id': 's1'});
      expect(t.hub.waitPosts.single.$1, 'POST /waitlist/p2/seat');
      expect(t.hub.waitPosts.single.$2, {'staff_id': 's1', 'table': 'A8', 'order_id': orderId});
      expect(find.byType(OrderScreen), findsOneWidget); // her check is open, to take the order
      expect(t.hub.parties!.firstWhere((p) => p['id'] == 'p2')['status'], 'seated');
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(seatingBar(), findsNothing);
      expect(find.descendant(of: key('waitlist-open'), matching: find.text('2')), findsOneWidget);
      await stop(tester);
    });

    testWidgets('the host seats a party for a server, who has to be named, and stays on the floor', (tester) async {
      final t = await pumpFloorWith(tester, holly);
      await seatFromList(tester, 'p1');
      await tester.tap(find.text('A8'));
      await tester.pumpAndSettle();
      expect(find.text('Seat Garcia at A8'), findsOneWidget);
      expect(find.text('2 guests'), findsOneWidget);
      expect(tester.widget<FilledButton>(key('seat')).onPressed, isNull);
      // one more turned up at the door
      await tester.tap(find.byIcon(Icons.add));
      await tester.pump();
      await tester.tap(key('server:s1'));
      await tester.pump();
      await tapKey(tester, 'seat');

      final (orderId, data) = sentOne(t.hub, 'create');
      expect(data, {
        'table': 'A8',
        'guests': 3,
        'order_type': 'dine_in',
        'server': 'Amy',
        'server_id': 's1',
        ...byHolly,
      });
      expect(t.hub.waitPosts.single.$2, {'staff_id': 's4', 'table': 'A8', 'order_id': orderId});
      expect(find.byType(OrderScreen), findsNothing);
      expect(find.text("A8 is Amy's"), findsOneWidget);
      expect(seatingBar(), findsNothing);
      expect(find.descendant(of: key('waitlist-open'), matching: find.text('2')), findsOneWidget);
      await stop(tester);
    });

    testWidgets('a party that joins a table that is seated adds its guests to that table\'s check', (tester) async {
      final t = await pumpFloorWith(
        tester,
        mike,
        hub: (hub) => hub.orders.add(checkAt('o1', 'A7', {'M1': line('Egg roll', rank: 1)}, guests: 4)),
      );
      await seatFromList(tester, 'p1');
      await tester.tap(find.text('A7'));
      await tester.pumpAndSettle();
      expect(find.text('A7 is seated'), findsOneWidget);
      expect(find.textContaining('Does Garcia, party of 2 join the table? Its check then counts 6 guests.'), findsOne);
      await tapKey(tester, 'party-join');

      expect(sentTo(t.hub), [
        [
          'o1',
          'set_field',
          {'guests': 6, ...byMike},
        ],
      ]);
      expect(t.hub.waitPosts.single.$2, {'staff_id': 's3', 'table': 'A7', 'order_id': 'o1'});
      expect(find.text('Garcia joined A7'), findsOneWidget);
      expect(seatingBar(), findsNothing);
      expect(find.byType(OrderScreen), findsNothing);
      await stop(tester);
    });

    testWidgets('seating can be called off: nothing is opened and the party stays on the list', (tester) async {
      final t = await pumpFloorWith(tester, amy);
      await seatFromList(tester, 'p2');
      // the guests are asked for and given up: the party is still in hand for another table
      await tester.tap(find.text('A8'));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Cancel')));
      await tester.pumpAndSettle();
      expect(seatingBar(), findsOneWidget);
      // a seated table asked about and given up too
      await tester.tap(find.text('A7'));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Cancel')));
      await tester.pumpAndSettle();
      expect(seatingBar(), findsOneWidget);
      await tester.tap(find.descendant(of: seatingBar(), matching: find.text('Cancel')));
      await tester.pumpAndSettle();
      expect(seatingBar(), findsNothing);
      expect(key('to-go'), findsOneWidget);
      expect(t.hub.sent, isEmpty);
      expect(t.hub.waitPosts, isEmpty);
      // a table tapped now seats a party walking in, as ever
      await tester.tap(find.text('A8'));
      await tester.pumpAndSettle();
      expect(find.text('Seat A8'), findsOneWidget);
      await stop(tester);
    });

    testWidgets('going back to the list of checks calls the seating off too', (tester) async {
      await pumpFloorWith(tester, amy);
      await seatFromList(tester, 'p2');
      await tester.tap(find.byTooltip('List of checks'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Floor map'));
      await tester.pumpAndSettle();
      expect(seatingBar(), findsNothing);
      await stop(tester);
    });

    testWidgets('the check opens even when the list cannot be told, and the screen says the party is still on it', (
      tester,
    ) async {
      final t = await pumpFloorWith(tester, holly);
      await seatFromList(tester, 'p1');
      t.hub.waitDown = true;
      await tester.tap(find.text('A8'));
      await tester.pumpAndSettle();
      await tester.tap(key('server:s1'));
      await tester.pump();
      await tapKey(tester, 'seat');
      expect(sentOne(t.hub, 'create').$2['table'], 'A8'); // the guests are at the table whatever the list says
      await tester.pump(const Duration(seconds: 5)); // the first line goes, the second comes
      await tester.pumpAndSettle();
      expect(
        find.text('Garcia is at A8, but the waitlist could not be told. Take them off the list when the hub is back.'),
        findsOneWidget,
      );
      expect(t.hub.parties!.first['status'], 'waiting');
      await stop(tester);
    });

    testWidgets('a party another screen sat first keeps that table, and the screen says so', (tester) async {
      final t = await pumpFloorWith(tester, mike);
      await seatFromList(tester, 'p2');
      // meanwhile the host sat them at B5
      t.hub.parties![1].addAll({
        'status': 'seated',
        'seated_ms': t.hub.clockNow,
        'table': 'B5',
        'table_label': 'B5',
        'order_id': 'o9',
        'ended_by': 'Holly',
      });
      await tester.tap(find.text('A8'));
      await tester.pumpAndSettle();
      await tapKey(tester, 'seat');
      expect(find.text('Chen was already seated at B5. The list keeps that table.'), findsOneWidget);
      expect(t.hub.parties![1]['table'], 'B5');
      await stop(tester);
    });

    testWidgets('a 320-wide phone: the button, the seating strip and the question fit', (tester) async {
      await pumpFloorWith(tester, holly, size: const Size(320, 640));
      expect(tester.takeException(), isNull);
      final screen = tester.getRect(find.byType(Scaffold).first);
      final button = tester.getRect(key('waitlist-open'));
      expect(button.left >= 0 && button.right <= screen.right, isTrue, reason: '$button');
      await seatFromList(tester, 'p2');
      expect(seatingBar(), findsOneWidget);
      expect(tester.takeException(), isNull);
      // how many, and whose table
      await tester.tap(find.text('A8'));
      await tester.pumpAndSettle();
      expect(find.text('Seat Chen at A8'), findsOneWidget);
      expect(tester.takeException(), isNull);
      final seat = tester.getRect(key('seat'));
      expect(seat.right <= screen.right && seat.bottom <= screen.bottom, isTrue, reason: '$seat');
      await stop(tester);
    });
  });
}
