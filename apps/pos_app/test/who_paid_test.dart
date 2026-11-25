import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/api.dart' show ApiException;
import 'package:pos_app/guests_report.dart';
import 'package:pos_app/paid_checks.dart';
import 'package:pos_app/screens/guests_screen.dart';
import 'package:pos_app/screens/who_paid.dart';

import 'guests_report_test.dart'
    show favourite, linda, lindaClosely, omar, priya, pumpGuests, row, sam, tapKey, tess, visit, year;
import 'hub.dart';

/// Who paid, said afterwards (the Toast comparison; the owner's pick of 2026-11-24): a check with several
/// guests is one guest's money, the one who paid. A tap on the check says which while the party sits there.
/// When nobody tapped, the check waits and its money counts for nobody; the guest list says how many checks
/// wait, lists them with their guests to tap, and lets a visit at a table of several guests say who paid it
/// (docs/guest-list.md, "Who paid, said afterwards"). The hub keeps the word and does every sum; these
/// tests are about the screens saying what the hub said and sending the word.

const lindaKey = 'reservation:b1', omarKey = 'waitlist:p1', priyaKey = 'reservation:b7', samKey = 'check:t-2';

Map<String, dynamic> paidGuest(String key, String name, String phone, {bool typed = false, bool pays = false}) => {
  'key': key,
  'name': name,
  'phone': phone,
  'typed': typed,
  'pays': pays,
};

Map<String, dynamic> paidCheck(
  String id,
  String day,
  String table,
  String net,
  List<Map<String, dynamic>> guests, {
  int? no,
  int hour = 19,
  int minute = 5,
  String saidBy = '',
}) => {
  'order_id': id,
  'order_no': no,
  'table': table,
  'day': day,
  'opened_ms': DateTime.parse(day).add(Duration(hours: hour, minutes: minute)).millisecondsSinceEpoch,
  'kind': 'dine_in',
  'net': net,
  'guests': guests,
  'waits': guests.every((guest) => guest['pays'] != true),
  'said_by': saidBy,
};

/// The checks the hub noted guests on. Two wait: Linda and Omar at A7, and Priya with a number that gave no
/// name (the guest of a check that was merged into hers). Tess typed her number on a check Linda sat on
/// too, so she pays it without a word; and Amy tapped Linda on the fourth.
Map<String, Map<String, dynamic>> noted() => {
  'w1': paidCheck('w1', '2026-11-14', 'A7', '84.20', [
    paidGuest(lindaKey, 'Linda Chen', linda),
    paidGuest(omarKey, 'Omar Haddad', omar),
  ], no: 41),
  'w2': paidCheck(
    'w2',
    '2026-11-10',
    'B2',
    '128.20',
    [paidGuest(priyaKey, 'Priya Patel', priya), paidGuest(samKey, '', sam)],
    no: 17,
    hour: 12,
    minute: 30,
  ),
  'w3': paidCheck('w3', '2026-11-02', 'C1', '46.00', [
    paidGuest('typed', 'Tess Moreau', tess, typed: true, pays: true),
    paidGuest('reservation:b9', 'Linda Chen', linda),
  ], no: 8),
  'w4': paidCheck(
    'w4',
    '2026-10-10',
    'C3',
    '13.00',
    [paidGuest('reservation:b4', 'Linda Chen', linda, pays: true), paidGuest('waitlist:p4', 'Omar Haddad', omar)],
    no: 3,
    saidBy: 'Amy',
  ),
};

/// Linda read closely, with her visits at those tables and one to-go order of her own. [paid] is her visit
/// at A7 once somebody said that she paid it.
Map<String, dynamic> lindaAtTables({bool paid = false}) => {
  ...lindaClosely(),
  'latest': [
    {
      ...visit('w1', 41, '2026-11-14', 'dine_in', paid ? '84.20' : '0.00', [favourite('GTC', 'General Tso', 2)]),
      'paid': paid,
      'waits': !paid,
      'guests': 2,
      'table': 'A7',
    },
    {
      ...visit('w3', 8, '2026-11-02', 'dine_in', '0.00', [favourite('EGGROLL', 'Egg roll', 2)]),
      'paid': false,
      'guests': 2,
      'table': 'C1',
    },
    {
      ...visit('w4', 3, '2026-10-10', 'dine_in', '13.00', [favourite('TSINGTAO', 'Tsingtao', 2)]),
      'guests': 2,
      'table': 'C3',
    },
    visit('l2', 2, '2026-09-01', 'takeout', '24.90', [favourite('GTC', 'General Tso', 2)]),
  ],
};

/// The guest list of a hub that noted those checks.
Future<Terminal> pumpList(
  WidgetTester tester, {
  Map<String, Map<String, dynamic>>? checks,
  Size size = const Size(1100, 3600),
  void Function(Hub hub)? before,
}) => pumpGuests(
  tester,
  size: size,
  before: (hub) {
    hub.paidChecks = checks ?? noted();
    hub.guestDetails = {linda: lindaAtTables()};
    before?.call(hub);
  },
);

Finder key(String value) => find.byKey(ValueKey(value));

/// Taps the name of [guest] on the check [check].
Future<void> say(WidgetTester tester, String check, String guest) async {
  final button = key('who-paid-guest:$check:$guest');
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  await tester.tap(button);
  await tester.pumpAndSettle();
}

/// Whether [guest] is the ticked one on the check [check].
bool ticked(WidgetTester tester, String check, String guest) =>
    tester.widget(key('who-paid-guest:$check:$guest')) is FilledButton;

/// The line under the names of the check [check].
String standing(WidgetTester tester, String check) => tester.widget<Text>(key('who-paid-standing:$check')).data!;

/// The names on the buttons of the check [check], left to right.
List<String> names(WidgetTester tester, String check) => [
  for (final text in tester.widgetList<Text>(
    find.descendant(
      of: find.descendant(of: key('who-paid:$check'), matching: find.bySubtype<ButtonStyleButton>()),
      matching: find.byType(Text),
    ),
  ))
    text.data ?? '',
];

/// The checks on the "Who paid?" screen, top to bottom.
List<String> waiting(WidgetTester tester) => [
  for (final element
      in find
          .byWidgetPredicate(
            (w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('who-paid:'),
          )
          .evaluate())
    (element.widget.key! as ValueKey<String>).value.substring('who-paid:'.length),
];

void main() {
  group('what the hub says', () {
    test('a check and its guests, read into names', () {
      final check = PaidCheck.fromJson(noted()['w2']!);
      expect((check.orderId, check.orderNo, check.table, check.kind, check.net), ('w2', 17, 'B2', 'dine_in', '128.20'));
      expect(
        (check.day, check.openedMs),
        (DateTime(2026, 11, 10), DateTime(2026, 11, 10, 12, 30).millisecondsSinceEpoch),
      );
      expect((check.waits, check.saidBy, check.payer, check.shared), (true, '', null, true));
      expect(check.guests.map((guest) => (guest.key, guest.name, guest.phone, guest.typed, guest.pays)), [
        (priyaKey, 'Priya Patel', priya, false, false),
        (samKey, '', sam, false, false),
      ]);
      // a guest who gave no name is called by their number
      expect(check.guests.map((guest) => guest.called), ['Priya Patel', '781 555 0104']);
      final typed = PaidCheck.fromJson(noted()['w3']!);
      expect((typed.waits, typed.payer?.key, typed.payer?.typed), (false, 'typed', true));
    });

    test('an answer with little in it is a check of nobody', () {
      final bare = PaidCheck.fromJson({
        'order_id': 'x',
        'guests': [
          {'name': 'No key'},
          'nonsense',
          {'key': 'reservation:b1', 'name': 'Linda Chen'},
        ],
      });
      expect(
        (bare.orderNo, bare.table, bare.net, bare.openedMs, bare.waits, bare.saidBy),
        (null, '', '0.00', 0, false, ''),
      );
      // a guest the hub gave no key for could not be said to have paid
      expect(bare.guests.map((guest) => guest.key), ['reservation:b1']);
      expect((bare.shared, bare.payer), (false, null));
    });

    test('how a check stands, in one line', () {
      final checks = noted();
      expect(PaidCheck.fromJson(checks['w1']!).standing, 'Nobody said who paid.');
      expect(PaidCheck.fromJson(checks['w3']!).standing, 'Tess Moreau paid: their number is on the check.');
      expect(PaidCheck.fromJson(checks['w4']!).standing, 'Linda Chen paid, said by Amy.');
      // its only guest pays without a word
      final alone = paidCheck('a', '2026-11-01', 'D4', '9.00', [paidGuest(lindaKey, 'Linda Chen', linda, pays: true)]);
      expect(PaidCheck.fromJson(alone).standing, 'Linda Chen paid.');
      expect(PaidCheck.fromJson(alone).shared, isFalse);
    });

    test('the guest list says how many checks wait, and an older hub says nothing of it', () {
      final report = GuestsReport.fromJson({
        ...year(),
        'waiting': {'checks': 2, 'net': '212.40'},
      });
      expect((report.saysPaid, report.waiting, report.waitingNet), (true, 2, '212.40'));
      final none = GuestsReport.fromJson({
        ...year(),
        'waiting': {'checks': 0, 'net': '0.00'},
      });
      expect((none.saysPaid, none.waiting, none.waitingNet), (true, 0, '0.00'));
      final older = GuestsReport.fromJson(year());
      expect((older.saysPaid, older.waiting, older.waitingNet), (false, 0, '0.00'));
    });

    test('a visit says how many guests sat on its check, and at which table', () {
      final latest = GuestDetail.fromJson(lindaAtTables()).latest;
      expect(latest.map((visit) => (visit.orderId, visit.guests, visit.table, visit.shared)), [
        ('w1', 2, 'A7', true),
        ('w3', 2, 'C1', true),
        ('w4', 2, 'C3', true),
        ('l2', 1, '', false), // a hub that does not say it: the guest alone
      ]);
    });
  });

  group('the calls', () {
    testWidgets('carry the manager\'s token, and the word names the check and the guest', (tester) async {
      final t = await terminal(tester);
      t.hub.paidChecks = noted();
      final checks = await t.api.waitingChecks('tok-admin');
      expect(checks.map((check) => check.orderId), ['w1', 'w2']);
      expect((t.hub.paidListAsks, t.hub.paidAuth), (1, 'Bearer tok-admin'));

      t.hub.paidAuth = null;
      final one = await t.api.paidCheck('tok-admin', 'w4');
      expect((one.orderId, one.payer?.called, one.saidBy), ('w4', 'Linda Chen', 'Amy'));
      expect(t.hub.paidAsks, ['w4']);
      expect(t.hub.paidAuth, 'Bearer tok-admin');

      t.hub.paidAuth = null;
      final now = await t.api.sayPaid('tok-admin', 'w1', omarKey, pays: true);
      expect((now.payer?.key, now.waits, now.saidBy), (omarKey, false, 'Mike'));
      expect(t.hub.paidSaid, [('w1', omarKey, true)]);
      expect(t.hub.paidAuth, 'Bearer tok-admin');
      final back = await t.api.sayPaid('tok-admin', 'w1', omarKey, pays: false);
      expect((back.payer, back.waits, back.saidBy), (null, true, ''));
      expect(t.hub.paidSaid.last, ('w1', omarKey, false));
    });

    testWidgets('a check the hub noted no guest on is refused in the hub\'s words', (tester) async {
      final t = await terminal(tester);
      t.hub.paidChecks = noted();
      await expectLater(
        t.api.paidCheck('tok-admin', 'nobody'),
        throwsA(
          isA<ApiException>()
              .having((err) => err.status, 'status', 404)
              .having((err) => err.detail?['error'], 'error', 'no_check'),
        ),
      );
      await expectLater(
        t.api.sayPaid('tok-admin', 'w1', 'reservation:gone', pays: true),
        throwsA(isA<ApiException>().having((err) => err.detail?['error'], 'error', 'unknown_guest')),
      );
      expect(t.hub.paidSaid, isEmpty);
    });
  });

  group('the checks that wait', () {
    testWidgets('the guest list says how many wait and what they come to', (tester) async {
      await pumpList(tester);
      expect(row(tester, 'guests-waiting'), [
        '2 checks wait for who paid',
        r'$212.40 that counts for no guest yet. Tap to say who paid.',
      ]);
      // one check is said as one
      await pumpList(tester, checks: {'w1': noted()['w1']!, 'w4': noted()['w4']!});
      expect(row(tester, 'guests-waiting').first, '1 check waits for who paid');
    });

    testWidgets('it says nothing when no check waits, or to a hub older than this', (tester) async {
      await pumpList(tester, checks: {'w3': noted()['w3']!, 'w4': noted()['w4']!});
      expect(key('guests-waiting'), findsNothing);
      expect(key('guests-spent'), findsOneWidget);
      final older = await pumpGuests(tester);
      expect(older.hub.paidChecks, isNull);
      expect(key('guests-waiting'), findsNothing);
      expect(key('guests-spent'), findsOneWidget);
    });

    testWidgets('a tap opens them, the newest first, each with its guests to tap', (tester) async {
      final t = await pumpList(tester);
      await tapKey(tester, 'guests-waiting');
      expect(find.text('Who paid?'), findsOneWidget);
      expect((t.hub.paidListAsks, t.hub.paidAuth), (1, 'Bearer tok-admin'));
      expect(waiting(tester), ['w1', 'w2']);
      expect(row(tester, 'who-paid:w1'), containsAll(['Sat, Nov 14 · Table A7', r'$84.20', '7:05 PM · #41']));
      expect(names(tester, 'w1'), ['Linda Chen', 'Omar Haddad']);
      expect(row(tester, 'who-paid:w2'), containsAll(['Tue, Nov 10 · Table B2', r'$128.20', '12:30 PM · #17']));
      expect(names(tester, 'w2'), ['Priya Patel', '781 555 0104']);
      expect((standing(tester, 'w1'), standing(tester, 'w2')), ('Nobody said who paid.', 'Nobody said who paid.'));
      expect(ticked(tester, 'w1', lindaKey) || ticked(tester, 'w1', omarKey), isFalse);
      expect(tester.widget<Text>(key('who-paid-about')).data, contains('Tap the guest who paid.'));
      expect(tester.widget<Text>(key('who-paid-note')).data, contains('no money is taken'));
      expect(t.hub.paidSaid, isEmpty);
    });

    testWidgets('a tap on a name says that guest paid; another name moves it; the ticked name takes it back', (
      tester,
    ) async {
      final t = await pumpList(tester);
      await tapKey(tester, 'guests-waiting');
      final places = (
        tester.getRect(key('who-paid-guest:w1:$lindaKey')),
        tester.getRect(key('who-paid-guest:w1:$omarKey')),
      );
      await say(tester, 'w1', lindaKey);
      expect(t.hub.paidSaid, [('w1', lindaKey, true)]);
      expect((ticked(tester, 'w1', lindaKey), ticked(tester, 'w1', omarKey)), (true, false));
      expect(standing(tester, 'w1'), 'Linda Chen paid, said by Mike.');
      // the tick moves no name from under the finger
      expect((
        tester.getRect(key('who-paid-guest:w1:$lindaKey')),
        tester.getRect(key('who-paid-guest:w1:$omarKey')),
      ), places);
      // the other check is as it was
      expect(standing(tester, 'w2'), 'Nobody said who paid.');

      await say(tester, 'w1', omarKey);
      expect(t.hub.paidSaid.last, ('w1', omarKey, true));
      expect((ticked(tester, 'w1', lindaKey), ticked(tester, 'w1', omarKey)), (false, true));
      expect(standing(tester, 'w1'), 'Omar Haddad paid, said by Mike.');

      await say(tester, 'w1', omarKey);
      expect(t.hub.paidSaid.last, ('w1', omarKey, false));
      expect((ticked(tester, 'w1', lindaKey), ticked(tester, 'w1', omarKey)), (false, false));
      expect(standing(tester, 'w1'), 'Nobody said who paid.');
      expect(t.hub.paidSaid, hasLength(3));
    });

    testWidgets('a guest who gave no name is tapped by their number', (tester) async {
      final t = await pumpList(tester);
      await tapKey(tester, 'guests-waiting');
      await say(tester, 'w2', samKey);
      expect(t.hub.paidSaid, [('w2', samKey, true)]);
      expect(standing(tester, 'w2'), '781 555 0104 paid, said by Mike.');
    });

    testWidgets('a check that was said stays, to be put right, until the checks are read again', (tester) async {
      final t = await pumpList(tester);
      await tapKey(tester, 'guests-waiting');
      await say(tester, 'w1', lindaKey);
      expect(waiting(tester), ['w1', 'w2']);
      await tester.tap(key('who-paid-refresh'));
      await tester.pumpAndSettle();
      expect(t.hub.paidListAsks, 2);
      expect(waiting(tester), ['w2']);
      await say(tester, 'w2', priyaKey);
      await tester.tap(key('who-paid-refresh'));
      await tester.pumpAndSettle();
      expect(waiting(tester), isEmpty);
      expect(tester.widget<Text>(key('who-paid-about')).data, 'No check waits for who paid.');
      expect(key('who-paid-note'), findsNothing);
    });

    testWidgets('going back, the guest list is read again when something was said, and only then', (tester) async {
      final t = await pumpList(tester);
      expect(t.hub.guestsAsks, 1);
      await tapKey(tester, 'guests-waiting');
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(t.hub.guestsAsks, 1); // nothing was said: the figures are what they were
      expect(row(tester, 'guests-waiting').first, '2 checks wait for who paid');

      await tapKey(tester, 'guests-waiting');
      await say(tester, 'w1', lindaKey);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(t.hub.guestsAsks, 2);
      expect(row(tester, 'guests-waiting'), [
        '1 check waits for who paid',
        r'$128.20 that counts for no guest yet. Tap to say who paid.',
      ]);

      // the last one said: the list says nothing of waiting checks any more
      await tapKey(tester, 'guests-waiting');
      await say(tester, 'w2', priyaKey);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(t.hub.guestsAsks, 3);
      expect(key('guests-waiting'), findsNothing);
    });

    testWidgets('no hub answers the tap: it says so, and who paid stays as it is', (tester) async {
      final t = await pumpList(tester);
      await tapKey(tester, 'guests-waiting');
      t.hub.paidDown = true;
      await say(tester, 'w1', lindaKey);
      expect(tester.widget<Text>(key('who-paid-error:w1')).data, 'The hub is not answering: who paid stays as it is.');
      expect(ticked(tester, 'w1', lindaKey), isFalse);
      expect(standing(tester, 'w1'), 'Nobody said who paid.');
      expect(t.hub.paidSaid, isEmpty);
      // the next tap that the hub takes clears what was said of the last one
      t.hub.paidDown = false;
      await say(tester, 'w1', lindaKey);
      expect(key('who-paid-error:w1'), findsNothing);
      expect(ticked(tester, 'w1', lindaKey), isTrue);
    });

    testWidgets('the manager\'s hour is over: it says to open Location again', (tester) async {
      final t = await pumpList(tester);
      await tapKey(tester, 'guests-waiting');
      t.hub.refusePaid = 401;
      await say(tester, 'w1', lindaKey);
      expect(
        tester.widget<Text>(key('who-paid-error:w1')).data,
        "The manager's hour here is over: go back and open Location again.",
      );
      expect(ticked(tester, 'w1', lindaKey), isFalse);
      // nothing was said, so going back does not read the list again
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(t.hub.guestsAsks, 1);
    });

    testWidgets('a guest who is no guest of the check any more: the hub says why not', (tester) async {
      final t = await pumpList(tester);
      await tapKey(tester, 'guests-waiting');
      // the check was read again on the hub meanwhile: Linda's party is none of its guests now
      t.hub.paidChecks!['w1'] = paidCheck('w1', '2026-11-14', 'A7', '84.20', [
        paidGuest(omarKey, 'Omar Haddad', omar),
        paidGuest(priyaKey, 'Priya Patel', priya),
      ], no: 41);
      await say(tester, 'w1', lindaKey);
      expect(tester.widget<Text>(key('who-paid-error:w1')).data, 'This guest is not a guest of this check any more.');
      expect(t.hub.paidSaid, isEmpty);
      expect(names(tester, 'w1'), ['Linda Chen', 'Omar Haddad']);
    });

    testWidgets('the checks cannot be read: it says so, and reads them when asked again', (tester) async {
      final t = await pumpList(tester, before: (hub) => hub.paidDown = true);
      await tapKey(tester, 'guests-waiting');
      expect(
        tester.widget<Text>(key('who-paid-error')).data,
        'The hub is not answering: the checks could not be read.',
      );
      expect(key('who-paid-list'), findsNothing);
      t.hub.paidDown = false;
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(key('who-paid-error'), findsNothing);
      expect(waiting(tester), ['w1', 'w2']);
    });

    testWidgets('opened with no check waiting, it says so', (tester) async {
      final t = await terminal(tester);
      t.hub.paidChecks = {'w3': noted()['w3']!, 'w4': noted()['w4']!};
      await tester.pumpWidget(
        MaterialApp(
          home: WhoPaidScreen(api: t.api, token: 'tok-admin'),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(key('who-paid-about')).data, 'No check waits for who paid.');
      expect(waiting(tester), isEmpty);
      expect(key('who-paid-note'), findsNothing);
    });
  });

  group('from a guest\'s visit', () {
    testWidgets('a visit at a table of several guests can say who paid; a visit alone cannot', (tester) async {
      await pumpList(tester);
      await tapKey(tester, 'guest-row:$linda');
      String label(String check) => row(tester, 'guest-visit-paid:$linda:$check').single;
      expect(label('w1'), 'Say who paid'); // it waits
      expect(label('w3'), 'Who paid'); // another guest paid
      expect(label('w4'), 'Who paid'); // she paid
      expect(key('guest-visit-paid:$linda:l2'), findsNothing);
      expect(row(tester, 'guest-visit:$linda:w1'), contains('nobody said who paid'));
      // a visit at a table names the table, where the hub says which
      expect(row(tester, 'guest-visit:$linda:w1'), contains('Sat, Nov 14 · Table A7'));
      expect(row(tester, 'guest-visit:$linda:l2'), contains('Tue, Sep 1 · To go'));
    });

    testWidgets('it opens the check with its guests, and what is said there is on the list when it closes', (
      tester,
    ) async {
      final t = await pumpList(tester);
      await tapKey(tester, 'guest-row:$linda');
      expect(t.hub.guestsAsks, 1);
      expect(t.hub.guestAsks, [linda]);
      await tapKey(tester, 'guest-visit-paid:$linda:w1');
      expect(key('who-paid-dialog'), findsOneWidget);
      expect(t.hub.paidAsks, ['w1']);
      expect(t.hub.paidAuth, 'Bearer tok-admin');
      expect(names(tester, 'w1'), ['Linda Chen', 'Omar Haddad']);
      expect(standing(tester, 'w1'), 'Nobody said who paid.');

      await say(tester, 'w1', lindaKey);
      expect(t.hub.paidSaid, [('w1', lindaKey, true)]);
      expect(standing(tester, 'w1'), 'Linda Chen paid, said by Mike.');
      // the hub counts the check's money for her from now on
      t.hub.guestDetails = {linda: lindaAtTables(paid: true)};
      await tester.tap(key('who-paid-done'));
      await tester.pumpAndSettle();
      expect(key('who-paid-dialog'), findsNothing);
      expect(t.hub.guestsAsks, 2);
      expect(t.hub.guestAsks, [linda, linda]);
      expect(row(tester, 'guest-visit:$linda:w1'), contains(r'$84.20'));
      expect(row(tester, 'guest-visit-paid:$linda:w1').single, 'Who paid');
      expect(row(tester, 'guests-waiting').first, '1 check waits for who paid');
    });

    testWidgets('closed with nothing said, the list is not read again', (tester) async {
      final t = await pumpList(tester);
      await tapKey(tester, 'guest-row:$linda');
      await tapKey(tester, 'guest-visit-paid:$linda:w4');
      expect(standing(tester, 'w4'), 'Linda Chen paid, said by Amy.');
      expect(ticked(tester, 'w4', 'reservation:b4'), isTrue);
      await tester.tap(key('who-paid-done'));
      await tester.pumpAndSettle();
      expect(t.hub.guestsAsks, 1);
      expect(t.hub.guestAsks, [linda]);
      expect(t.hub.paidSaid, isEmpty);
    });

    testWidgets('the number on the check pays for want of a word: a tap on it says nothing, another name does', (
      tester,
    ) async {
      final t = await pumpList(tester);
      await tapKey(tester, 'guest-row:$linda');
      await tapKey(tester, 'guest-visit-paid:$linda:w3');
      expect(names(tester, 'w3'), ['Tess Moreau', 'Linda Chen']);
      expect(ticked(tester, 'w3', 'typed'), isTrue);
      expect(standing(tester, 'w3'), 'Tess Moreau paid: their number is on the check.');
      await say(tester, 'w3', 'typed');
      expect(t.hub.paidSaid, isEmpty); // no word to take back

      await say(tester, 'w3', 'reservation:b9');
      expect(t.hub.paidSaid, [('w3', 'reservation:b9', true)]);
      expect((ticked(tester, 'w3', 'typed'), ticked(tester, 'w3', 'reservation:b9')), (false, true));
      expect(standing(tester, 'w3'), 'Linda Chen paid, said by Mike.');
      // the word taken back: the number on the check pays again
      await say(tester, 'w3', 'reservation:b9');
      expect(t.hub.paidSaid.last, ('w3', 'reservation:b9', false));
      expect(ticked(tester, 'w3', 'typed'), isTrue);
      expect(standing(tester, 'w3'), 'Tess Moreau paid: their number is on the check.');
    });

    testWidgets('a check the hub knows no guest of says so, and can be asked for again', (tester) async {
      final checks = noted();
      final w1 = checks.remove('w1')!;
      final t = await pumpList(tester, checks: checks);
      await tapKey(tester, 'guest-row:$linda');
      await tapKey(tester, 'guest-visit-paid:$linda:w1');
      expect(
        tester.widget<Text>(key('who-paid-one-error')).data,
        'This check is no visit of the last year, or the hub noted no guest on it.',
      );
      expect(key('who-paid:w1'), findsNothing);
      t.hub.paidChecks!['w1'] = w1;
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(key('who-paid-one-error'), findsNothing);
      expect(names(tester, 'w1'), ['Linda Chen', 'Omar Haddad']);
      expect(t.hub.paidAsks, ['w1', 'w1']);
    });

    testWidgets('no hub answers: the check could not be read', (tester) async {
      final t = await pumpList(tester);
      await tapKey(tester, 'guest-row:$linda');
      t.hub.paidDown = true;
      await tapKey(tester, 'guest-visit-paid:$linda:w1');
      expect(
        tester.widget<Text>(key('who-paid-one-error')).data,
        'The hub is not answering: the check could not be read.',
      );
      await tester.tap(key('who-paid-done'));
      await tester.pumpAndSettle();
      expect(t.hub.guestsAsks, 1);
    });

    testWidgets('a hub older than this offers no button under a visit', (tester) async {
      await pumpGuests(tester, before: (hub) => hub.guestDetails = {linda: lindaAtTables()});
      await tapKey(tester, 'guest-row:$linda');
      expect(key('guest-visit:$linda:w1'), findsOneWidget);
      expect(key('guest-visit-paid:$linda:w1'), findsNothing);
      expect(key('guests-waiting'), findsNothing);
    });
  });

  group('on a phone', () {
    /// Checks with long names, many guests and large sums.
    Map<String, Map<String, dynamic>> crowded() => {
      for (var n = 0; n < 6; n++)
        'c$n': paidCheck('c$n', '2026-11-${10 + n}', 'Private dining room $n', '123456.78', [
          for (var g = 0; g < 5; g++)
            paidGuest(
              'reservation:c$n-$g',
              g == 3 ? '' : 'Bartholomew Maximilian Featherstonehaugh-Cholmondeley the $g',
              '78155504$n$g',
            ),
        ], no: 100000 + n),
    };

    testWidgets('the checks, their names and what the hub says fit, with large type and in the dark too', (
      tester,
    ) async {
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      for (final (size, type) in [(const Size(390, 844), 1.0), (const Size(320, 568), 1.5)]) {
        for (final dark in [false, true]) {
          final t = await terminal(tester);
          t.hub
            ..guests = year()
            ..guestDetails = {linda: lindaAtTables()}
            ..paidChecks = {...noted(), ...crowded()};
          tester.view.physicalSize = size;
          tester.platformDispatcher.textScaleFactorTestValue = type;
          await tester.pumpWidget(const SizedBox());
          await tester.pumpWidget(
            MaterialApp(
              theme: dark ? ThemeData.dark() : null,
              home: GuestsScreen(api: t.api, token: 'tok-admin'),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          final banner = tester.getRect(key('guests-waiting'));
          expect((banner.left >= 0, banner.right <= size.width), (true, true));

          await tapKey(tester, 'guests-waiting');
          expect(tester.takeException(), isNull);
          for (final button in find.bySubtype<ButtonStyleButton>().evaluate()) {
            final box = button.renderObject! as RenderBox;
            final right = box.localToGlobal(Offset.zero).dx + box.size.width;
            expect(right, lessThanOrEqualTo(size.width));
            // a finger's room on every name
            if (button.widget.key != null) expect(box.size.height, greaterThanOrEqualTo(40));
          }
          await say(tester, 'c5', 'reservation:c5-0');
          expect(t.hub.paidSaid, [('c5', 'reservation:c5-0', true)]);
          t.hub.paidDown = true;
          await say(tester, 'c5', 'reservation:c5-3');
          t.hub.paidDown = false;
          expect(key('who-paid-error:c5'), findsOneWidget);
          expect(tester.takeException(), isNull);
          for (var i = 0; i < 6; i++) {
            await tester.drag(key('who-paid-list'), const Offset(0, -500));
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
          }
          await tester.pageBack();
          await tester.pumpAndSettle();

          // and the one check, from a visit
          await tapKey(tester, 'guest-row:$linda');
          await tapKey(tester, 'guest-visit-paid:$linda:w1');
          expect(key('who-paid-dialog'), findsOneWidget);
          await say(tester, 'w1', omarKey);
          expect(standing(tester, 'w1'), 'Omar Haddad paid, said by Mike.');
          expect(tester.takeException(), isNull);
          await tester.tap(key('who-paid-done'));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }
      }
    });
  });
}
