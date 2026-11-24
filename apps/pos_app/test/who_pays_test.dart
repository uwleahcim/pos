import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/guests_report.dart';
import 'package:pos_app/screens/order_screen.dart';
import 'package:pos_app/seated.dart';
import 'package:pos_app/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'guests_report_test.dart' show linda, lindaClosely, lindaRow, pumpGuests, row, visit, year;
import 'guests_report_test.dart' as guests show tapKey;
import 'hub.dart';
import 'table_tags_test.dart' show a7, omar, said, seatedBooking, seatedParty, seven, strip;
import 'waitlist_test.dart' show key, tapKey;

/// Who pays (the Toast comparison; the owner's words of 2026-11-24): every guest of a check has the visit
/// in the guest list, and the check's money counts for one of them, the one who pays. A check with one
/// guest needs no word. Where two or more parties that left a number sit on a check (two parties at one
/// table, two tables put together), a tap on a party's name in the strip under the bar says that it pays:
/// a menu of one line, "Linda P. pays". The hub keeps the word (`POST /orders/{id}/payer`); nothing is
/// written on the check, and no money is taken by it. In the guest list, a visit somebody else paid says
/// so where its money would stand.

const lindaKey = 'reservation:b1';
const omarKey = 'waitlist:p1';

/// Linda (from her reservation) and Omar (from the waitlist) sit at A7 on the check `o1`, and both left a
/// number.
void twoAtA7(Hub hub) => hub
  ..payerCall = true
  ..ringTags = {
    '7815550101': ['VIP'],
  }
  ..bookings = [seatedBooking('b1', 'Linda P.', '781 555 0101', 'o1', note: 'Window table')]
  ..parties = [seatedParty('p1', 'Omar', omar, 'o1', seatedMs: seven + 60000)];

/// The check `o1` on the screen with somebody signed in ([signedIn] off: a screen without a session).
Future<Terminal> pumpTable(
  WidgetTester tester, {
  void Function(Hub hub)? hub,
  Map<String, dynamic>? order,
  bool signedIn = true,
  Size? size,
}) async {
  final t = await terminal(tester, role: 'server');
  if (size != null) tester.view.physicalSize = size;
  t.hub
    ..clockNow = seven
    ..orders.add(order ?? a7());
  (hub ?? twoAtA7)(t.hub);
  await tester.pumpWidget(
    MaterialApp(
      home: OrderScreen(
        api: t.api,
        outbox: t.outbox,
        photos: t.photos,
        orderId: 'o1',
        session: signedIn ? t.session : null,
        staffName: signedIn ? null : 'Amy',
      ),
    ),
  );
  await tester.pumpAndSettle();
  return t;
}

/// The menu of the party at [at] is opened and its one line tapped.
Future<void> sayPays(WidgetTester tester, int at) async {
  await tapKey(tester, 'seated-payer:$at');
  await tapKey(tester, 'seated-pays-pick:$at');
}

void main() {
  group('the calls', () {
    Future<(Hub, PosApi)> hubAndApi() async {
      SharedPreferences.setMockInitialValues({});
      final settings = Settings(
        device: 't1',
        endpoints: ['http://hub:8000'],
        prefs: await SharedPreferences.getInstance(),
      );
      final hub = Hub();
      twoAtA7(hub);
      return (hub, PosApi(settings, client: MockClient(hub.handle)));
    }

    test('who sits on a check says who can pay and who does, and never a number', () async {
      final (hub, api) = await hubAndApi();
      hub.parties!.add(seatedParty('p2', 'Walk-up', '', 'o1', seatedMs: seven + 120000)); // left no number
      final table = (await api.tableGuests('o1'))!;
      expect(table.takesPayer, isTrue);
      expect(table.parties, const [
        SeatedParty(
          name: 'Linda P.',
          size: 2,
          note: 'Window table',
          tags: ['VIP'],
          booked: true,
          key: lindaKey,
          listed: true,
        ),
        SeatedParty(name: 'Omar', size: 2, key: omarKey, listed: true),
        SeatedParty(name: 'Walk-up', size: 2, key: 'waitlist:p2'),
      ]);
      expect([for (final party in table.payers) party.name], ['Linda P.', 'Omar']);
      expect(table.asksPayer, isTrue);
    });

    test('the word that a party pays, and the word taken back', () async {
      final (hub, api) = await hubAndApi();
      var table = await api.sayPayer('s1', 'o1', omarKey, pays: true);
      expect([for (final party in table.parties) party.pays], [false, true]);
      table = await api.sayPayer('s1', 'o1', lindaKey, pays: true);
      expect([for (final party in table.parties) party.pays], [true, false]); // one guest pays a check
      table = await api.sayPayer('s2', 'o1', lindaKey, pays: false);
      expect([for (final party in table.parties) party.pays], [false, false]);
      expect(hub.payerSaid, [('o1', omarKey, true, 's1'), ('o1', lindaKey, true, 's1'), ('o1', lindaKey, false, 's2')]);
      expect(
        hub.requests.where((r) => r.startsWith('POST')),
        everyElement('POST /orders/o1/payer'),
      ); // no operation was sent: nothing is written on the check
      await expectLater(
        api.sayPayer('s1', 'o1', 'waitlist:gone', pays: true),
        throwsA(isA<ApiException>().having((e) => e.detail?['error'], 'error', 'unknown_party')),
      );
    });

    test('a hub that takes no such word says none of it, and nothing is asked of anybody', () async {
      final (hub, api) = await hubAndApi();
      hub.payerCall = false;
      final table = (await api.tableGuests('o1'))!;
      expect(table.takesPayer, isFalse);
      expect(table.parties, const [
        SeatedParty(name: 'Linda P.', size: 2, note: 'Window table', tags: ['VIP'], booked: true),
        SeatedParty(name: 'Omar', size: 2),
      ]);
      expect(table.payers, isEmpty);
      expect(table.asksPayer, isFalse);
    });

    test('one guest alone pays without a word, and so does the only one that left a number', () {
      const linda = SeatedParty(name: 'Linda P.', key: lindaKey, listed: true);
      const walkUp = SeatedParty(name: 'Walk-up', key: 'waitlist:p2');
      expect(const TableGuests(parties: [linda], takesPayer: true).asksPayer, isFalse);
      expect(const TableGuests(parties: [linda, walkUp], takesPayer: true).asksPayer, isFalse);
      expect(TableGuests.none.asksPayer, isFalse);
      expect(
        TableGuests.fromJson(const {
          'payer': true,
          'parties': [
            {'name': 'Linda P.', 'key': 7, 'listed': 'yes', 'pays': 1}, // nonsense is no word
          ],
        }).parties,
        const [SeatedParty(name: 'Linda P.')],
      );
    });
  });

  group('on the check', () {
    testWidgets('two parties at one table: the strip asks who pays, and a tap on a name says it', (tester) async {
      final t = await pumpTable(tester);
      expect(said(tester, 'seated-who-pays'), 'Who pays? Tap a name.');
      expect(said(tester, 'seated-name:0'), 'Linda P.');
      expect(said(tester, 'seated-name:1'), 'Omar');
      expect(key('seated-pays:0'), findsNothing);
      expect(key('seated-pays:1'), findsNothing);

      await tapKey(tester, 'seated-payer:0');
      expect(find.text('Linda P. pays'), findsOneWidget); // the menu's one line names who it is about
      await tapKey(tester, 'seated-pays-pick:0');
      expect(t.hub.payerSaid, [('o1', lindaKey, true, 's3')]);
      expect(key('seated-pays:0'), findsOneWidget);
      expect(key('seated-pays:1'), findsNothing);
      expect(key('seated-who-pays'), findsNothing); // it was said
      // the rest of the strip is as it was: the tags and the note of each party
      expect(key('seated-tag:0:VIP'), findsOneWidget);
      expect(said(tester, 'seated-note:0'), 'Window table');
      // nothing was written on the check
      expect(t.hub.opsFor('o1'), isEmpty);
    });

    testWidgets('the other party is tapped: the label moves, for one guest pays a check', (tester) async {
      final t = await pumpTable(tester);
      await sayPays(tester, 0);
      await sayPays(tester, 1);
      expect(key('seated-pays:0'), findsNothing);
      expect(key('seated-pays:1'), findsOneWidget);
      expect(t.hub.payers, {'o1': omarKey});
    });

    testWidgets('the word is taken back by the same tap, and the strip asks again', (tester) async {
      final t = await pumpTable(tester);
      await sayPays(tester, 1);
      await tapKey(tester, 'seated-payer:1');
      expect(tester.widget<CheckedPopupMenuItem<bool>>(key('seated-pays-pick:1')).checked, isTrue); // ticked: Omar pays
      await tapKey(tester, 'seated-pays-pick:1');
      expect(t.hub.payerSaid.last, ('o1', omarKey, false, 's3'));
      expect(t.hub.payers, isEmpty);
      expect(key('seated-pays:1'), findsNothing);
      expect(key('seated-who-pays'), findsOneWidget);
    });

    testWidgets('a party that pays already is shown so when the check is opened', (tester) async {
      await pumpTable(
        tester,
        hub: (hub) {
          twoAtA7(hub);
          hub.payers['o1'] = omarKey;
        },
      );
      expect(key('seated-pays:1'), findsOneWidget);
      expect(key('seated-who-pays'), findsNothing);
    });

    testWidgets('one party alone: nothing to say, and the strip is the strip it was', (tester) async {
      await pumpTable(
        tester,
        hub: (hub) {
          twoAtA7(hub);
          hub.parties = [];
        },
      );
      expect(said(tester, 'seated-name:0'), 'Linda P.');
      expect(key('seated-payer:0'), findsNothing);
      expect(key('seated-who-pays'), findsNothing);
      expect(find.descendant(of: key(strip), matching: find.byType(PopupMenuButton<bool>)), findsNothing);
    });

    testWidgets('a party that left no number cannot be the one: its name is plain', (tester) async {
      await pumpTable(
        tester,
        hub: (hub) {
          twoAtA7(hub);
          hub.parties!.add(seatedParty('p2', 'Walk-up', '', 'o1', seatedMs: seven + 120000));
        },
      );
      expect(key('seated-payer:0'), findsOneWidget);
      expect(key('seated-payer:1'), findsOneWidget);
      expect(key('seated-payer:2'), findsNothing);
      expect(said(tester, 'seated-name:2'), 'Walk-up');
    });

    testWidgets('one of two left no number: the other is the only guest and pays without a word', (tester) async {
      await pumpTable(
        tester,
        hub: (hub) {
          twoAtA7(hub);
          hub.parties = [seatedParty('p2', 'Walk-up', '', 'o1', seatedMs: seven + 120000)];
        },
      );
      expect(key('seated-payer:0'), findsNothing);
      expect(key('seated-who-pays'), findsNothing);
    });

    testWidgets('a number typed on the check has its money: the strip does not ask, a tap still says', (tester) async {
      final t = await pumpTable(tester, order: a7({'phone': '7815550177', 'customer_name': 'Novak'}));
      expect(key('seated-who-pays'), findsNothing);
      await sayPays(tester, 0);
      expect(t.hub.payers, {'o1': lindaKey});
      expect(key('seated-pays:0'), findsOneWidget);
    });

    testWidgets('a hub that takes no such word: the strip is the strip it was', (tester) async {
      await pumpTable(
        tester,
        hub: (hub) {
          twoAtA7(hub);
          hub.payerCall = false;
        },
      );
      expect(said(tester, 'seated-name:0'), 'Linda P.');
      expect(said(tester, 'seated-name:1'), 'Omar');
      expect(key('seated-payer:0'), findsNothing);
      expect(key('seated-who-pays'), findsNothing);
    });

    testWidgets('nobody signed in: there is nobody to say it', (tester) async {
      await pumpTable(tester, signedIn: false);
      expect(key('seated-payer:0'), findsNothing);
      expect(key('seated-who-pays'), findsNothing);
      expect(said(tester, 'seated-name:0'), 'Linda P.');
    });

    testWidgets('no hub answers the tap: it says so, and who pays stays as it is', (tester) async {
      final t = await pumpTable(tester);
      t.hub.payerDown = true;
      await sayPays(tester, 0);
      expect(find.text('The hub is not answering: who pays stays as it is.'), findsOneWidget);
      expect(key('seated-pays:0'), findsNothing);
      expect(key('seated-who-pays'), findsOneWidget);
    });

    testWidgets('the party went back to the book meanwhile: the hub says why not', (tester) async {
      final t = await pumpTable(tester);
      t.hub.bookings = []; // put back at the host stand
      await sayPays(tester, 0);
      expect(find.text('This party does not sit on this check any more.'), findsOneWidget);
      expect(t.hub.payers, isEmpty);
    });

    testWidgets('on a phone the names and the label fit, and the menu opens under the name', (tester) async {
      final t = await pumpTable(tester, size: const Size(390, 844));
      await sayPays(tester, 1);
      expect(t.hub.payers, {'o1': omarKey});
      expect(tester.takeException(), isNull);
      final label = tester.getRect(key('seated-pays:1'));
      expect(label.right, lessThanOrEqualTo(390));
      // a finger's room: the name is taller to tap than its letters
      expect(tester.getSize(key('seated-payer:1')).height, greaterThanOrEqualTo(24));
    });
  });

  group('in the guest list', () {
    test('a visit says whether the guest paid it, and a hub that does not say means they did', () {
      final paid = GuestVisit.fromJson(visit('l5', 41, '2026-11-14', 'dine_in', '31.90', const []));
      expect(paid.paid, isTrue);
      expect(paid.unpaidWords, isNull);
      final another = GuestVisit.fromJson({
        ...visit('l4', 17, '2026-11-02', 'dine_in', '0.00', const []),
        'paid': false,
      });
      expect(another.unpaidWords, 'another guest paid');
      final waits = GuestVisit.fromJson({
        ...visit('l3', 8, '2026-10-10', 'dine_in', '0.00', const []),
        'paid': false,
        'waits': true,
      });
      expect(waits.unpaidWords, 'nobody said who paid');
    });

    test('a guest says how many of their visits they paid, only when it is not all of them', () {
      expect(Guest.fromJson(lindaRow()).paidWords, isNull); // an older hub says no such figure
      expect(Guest.fromJson({...lindaRow(), 'paid': 5}).paidWords, isNull);
      expect(Guest.fromJson({...lindaRow(), 'paid': 3}).paidWords, 'paid 3 of 5');
      final kept = Guest.fromJson({...lindaRow(), 'paid': 3}).kept(note: 'x', tags: const []);
      expect(kept.paid, 3);
    });

    testWidgets('a table another guest paid says so where its money would stand', (tester) async {
      await pumpGuests(
        tester,
        before: (hub) {
          final rows = [
            for (final guest in (year()['guests'] as List).cast<Map<String, dynamic>>())
              guest['phone'] == linda ? {...guest, 'paid': 3} : guest,
          ];
          hub.guests = {...year(), 'guests': rows};
          final closely = lindaClosely();
          final latest = (closely['latest'] as List).cast<Map<String, dynamic>>();
          hub.guestDetails = {
            linda: {
              ...closely,
              'guest': {...closely['guest'] as Map<String, dynamic>, 'paid': 3},
              'latest': [
                latest[0],
                {...latest[1], 'net': '0.00', 'paid': false},
                {...latest[2], 'net': '0.00', 'paid': false, 'waits': true},
              ],
            },
          };
        },
      );
      await guests.tapKey(tester, 'guest-row:$linda');
      expect(row(tester, 'guest-visit:$linda:l5'), contains(r'$31.90'));
      expect(row(tester, 'guest-visit:$linda:l4'), contains('another guest paid'));
      expect(row(tester, 'guest-visit:$linda:l4'), isNot(contains(r'$0.00')));
      expect(row(tester, 'guest-visit:$linda:l3'), contains('nobody said who paid'));
      expect(said(tester, 'guest-rate:$linda'), contains('paid 3 of 5'));
    });
  });
}
