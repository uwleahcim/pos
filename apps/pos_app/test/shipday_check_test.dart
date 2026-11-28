import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/check_history.dart';
import 'package:pos_app/roster.dart';
import 'package:pos_app/screens/deliveries_screen.dart';
import 'package:pos_app/shipday.dart';
import 'package:pos_app/takeout.dart' show clockTime;

import 'check_history_test.dart' show step;
import 'coursing_test.dart' show pumpLocation;
import 'delivery_test.dart' show bell, elm, pumpOrder, soon, stand;
import 'drivers_test.dart' show bag, cards, pumpDeliveries, words;
import 'hub.dart';
import 'location_rows.dart';
import 'runs_test.dart' as runs;
import 'shipday_test.dart' show pumpShipday, tapKey, textOf;

/// Shipday moves the check (docs/shipday.md; the owner, 2026-11-28): the hub takes a check Out when Shipday
/// says its delivery was picked up, and closes it when Shipday says it was delivered, unless money is still
/// due. The hub does the moving (backend/tests/shipday/test_follow.py, test_api.py); these tests are about
/// what the screens say of it: whose driver has the bag, what Shipday said where the check did not move with
/// it, that the Shipday screen says a mark is followed, and the switch under Location that turns it off.

/// Tom as Shipday knows the driver: no one of the POS's own staff.
const tomOfShipday = StaffMember(staffId: 'shipday:501', name: 'Tom Reyes', role: 'driver', delivers: true);

/// What the hub wrote on a check of what Shipday said, [minutes] before [soon].
Map<String, dynamic> told(String state, {int minutes = 5}) => {
  'id': 7001,
  'number': 'S-77',
  'state': state,
  'at_ms': saidAt(minutes),
};

int saidAt(int minutes) => soon.subtract(Duration(minutes: minutes)).millisecondsSinceEpoch;

/// A delivery as the hub lists it, with what Shipday said written on it ([state]); [out] with Shipday's
/// driver since ten minutes before [soon].
Map<String, dynamic> followed(
  String id,
  int no,
  String state, {
  bool out = true,
  String stage = 'ready',
  bool sent = true,
  String? due,
  String name = 'Raj',
  int minutes = 5,
}) {
  final o = bag(id, no, name: name, stage: stage, sent: sent, driver: out ? tomOfShipday : null, left: 10, due: due);
  (o['fields'] as Map<String, dynamic>)['shipday'] = told(state, minutes: minutes);
  return o;
}

Order read(Map<String, dynamic> json) => Order.fromJson(json);

bool moves(WidgetTester tester) => tester.widget<SwitchListTile>(find.byKey(const ValueKey('shipday-moves'))).value;

void main() {
  final left = clockTime(saidAt(10));
  final said = clockTime(saidAt(5));

  group('what Shipday said, on a check', () {
    test('it is read off the order as the hub wrote it, and what nobody wrote is nothing', () {
      final word = ShipdaySaid.of(told('ALREADY_DELIVERED'))!;
      expect((word.state, word.atMs, word.id, word.number), ('ALREADY_DELIVERED', saidAt(5), 7001, 'S-77'));
      expect((word.delivered, word.pickedUp), (true, false));
      expect(word.words, 'Shipday: delivered $said');
      expect(ShipdaySaid.of(told('FAILED_DELIVERY'))!.words, 'Shipday: failed $said');
      expect(ShipdaySaid.of(told('INCOMPLETE'))!.words, 'Shipday: incomplete $said');
      expect(ShipdaySaid.of(told('PICKED_UP'))!.words, 'Shipday: picked up $said');
      expect(ShipdaySaid.of({'state': 'ALREADY_DELIVERED'})!.words, 'Shipday: delivered');
      for (final nothing in [
        null,
        'ALREADY_DELIVERED',
        7,
        <String, dynamic>{},
        {'state': ''},
        {'at_ms': 5},
      ]) {
        expect(ShipdaySaid.of(nothing), isNull, reason: '$nothing');
      }
      expect(read(bag('o1', 7)).shipdaySaid, isNull);
    });

    test('a screen says it only where it is more than the check says itself', () {
      // out as Shipday said: who has it and since when says it all
      expect(read(followed('o1', 7, 'PICKED_UP')).shipdaySays, isNull);
      // delivered, and still open for its money; failed; not completed: somebody has something to do
      expect(read(followed('o1', 7, 'ALREADY_DELIVERED', due: '21.40')).shipdaySays, 'Shipday: delivered $said');
      expect(read(followed('o1', 7, 'FAILED_DELIVERY')).shipdaySays, 'Shipday: failed $said');
      expect(read(followed('o1', 7, 'INCOMPLETE')).shipdaySays, 'Shipday: incomplete $said');
      // picked up there, never sent out here (the kitchen never had it, or the bag came back since)
      expect(
        read(followed('o1', 7, 'PICKED_UP', out: false, stage: 'new', sent: false)).shipdaySays,
        'Shipday: picked up $said',
      );
      expect(read(followed('o1', 7, 'PICKED_UP', out: false)).shipdaySays, 'Shipday: picked up $said');
      // a check that is closed, or marked delivered, says what became of it itself
      expect(read(followed('o1', 7, 'ALREADY_DELIVERED')..['status'] = 'closed').shipdaySays, isNull);
      expect(read(followed('o1', 7, 'ALREADY_DELIVERED', out: false, stage: 'picked_up')).shipdaySays, isNull);
      // and one the customer comes for after all is no delivery any more
      final pickup = followed('o1', 7, 'FAILED_DELIVERY');
      (pickup['fields'] as Map).remove('handover');
      expect(read(pickup).shipdaySays, isNull);
    });

    test("a driver of Shipday's is named as one, so nobody takes them for the POS's own", () {
      expect(isShipdayDriver('shipday:501'), isTrue);
      expect(isShipdayDriver('shipday'), isTrue);
      for (final ours in ['s1', 'd1', '', 'shipdays', 'ship:1']) {
        expect(isShipdayDriver(ours), isFalse, reason: ours);
      }
      expect(driverCalled('Tom Reyes', 'shipday:501'), 'Tom Reyes (Shipday)');
      expect(driverCalled('Shipday driver', 'shipday'), 'Shipday driver (Shipday)');
      expect(driverCalled('Tom', 'd1'), 'Tom');
    });

    test('the hub says whether it follows Shipday, and the check beside a delivery that it is out', () {
      expect(ShipdayBoard.fromJson(Hub.shipdayStands()).movesChecks, isTrue);
      expect(ShipdayBoard.fromJson(Hub.shipdayStands(moves: false)).movesChecks, isFalse);
      expect(ShipdayBoard.fromJson(Hub.shipdayStands(moves: null)).movesChecks, isFalse, reason: 'an older hub');
      expect(const ShipdayBoard().movesChecks, isFalse);
      ShipdayCheck check(String status, String stage) =>
          ShipdayCheck.fromJson(Hub.shipdayCheck('o-7', 14, status: status, stage: stage))!;
      expect(check('open', 'out').words, 'Check #14 · out');
      expect(check('open', 'ready').words, 'Check #14');
      expect(check('closed', 'picked_up').words, 'Check #14 · closed');
      expect(check('void', 'out').words, 'Check #14 · voided');
    });

    test("the check's history says what Shipday said where the check stayed as it was", () {
      List<String> history(String state, {int? saidMs, int atMs = 0}) {
        final words = wordsOf(
          HistoryStep.fromJson(step('shipday', atMs, by: 'Shipday', said: {'state': state, 'said_ms': saidMs})),
          time: (ms) => 'at $ms',
        );
        return [words.title, ...words.under];
      }

      expect(history('ALREADY_DELIVERED'), ['Shipday says it was delivered']);
      expect(history('PICKED_UP'), ['Shipday says it was picked up']);
      expect(history('FAILED_DELIVERY'), ['Shipday says the delivery failed']);
      expect(history('INCOMPLETE'), ['Shipday says the delivery was not completed']);
      expect(history('SOMETHING_NEW'), ['Shipday says: SOMETHING_NEW']);
      // Shipday's own moment, where that is not the minute the hub heard
      expect(history('ALREADY_DELIVERED', saidMs: 100000, atMs: 400000), [
        'Shipday says it was delivered',
        'at at 100000, as Shipday has it',
      ]);
      expect(history('ALREADY_DELIVERED', saidMs: 390000, atMs: 400000), ['Shipday says it was delivered']);
      // and who did it is Shipday, said once: the hub wrote it for Shipday, at no screen
      expect(whoLine(HistoryStep.fromJson(step('shipday', 0, by: 'Shipday', device: 'shipday'))), 'Shipday');
      expect(whoLine(HistoryStep.fromJson(step('closed', 0, by: 'Shipday', device: 'shipday'))), 'Shipday');
      expect(whoLine(HistoryStep.fromJson(step('closed', 0))), 'Amy · mac1');
    });
  });

  group('the Shipday screen', () {
    final tom = Hub.shipdayDriver(501, 'Tom Reyes', orders: 1);

    Map<String, dynamic> picture({bool? moves = true, String status = 'open', String stage = 'out'}) =>
        Hub.shipdayStands(
          moves: moves,
          drivers: [tom],
          orders: [
            Hub.shipdayOrder(
              7003,
              'S-77',
              state: 'PICKED_UP',
              name: 'Mei Lin',
              driver: tom,
              check: Hub.shipdayCheck('o-9', 9, status: status, stage: stage, by: 'phone'),
            ),
          ],
        );

    Future<void> askDelivered(WidgetTester tester) async {
      await tapKey(tester, 'shipday-mark-7003');
      await tester.tap(find.byKey(const ValueKey('shipday-step-ALREADY_DELIVERED')));
      await tester.pumpAndSettle();
      expect(find.text('Mark it delivered?'), findsOneWidget);
    }

    const leaves =
        "Mei Lin's delivery leaves Shipday's active deliveries as Delivered. That cannot be taken back from the POS.";

    testWidgets('where the hub follows Shipday the screen says so, and that a check is out', (tester) async {
      await pumpShipday(tester, picture: picture(), staffId: 's3');
      expect(
        textOf(tester, 'shipday-foot'),
        endsWith(
          'What Shipday says moves the check: picked up takes it Out, and delivered closes it unless money is '
          'still due.',
        ),
      );
      expect(find.text('Check #9 · out'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await stop(tester);
    });

    testWidgets('where it does not (turned off, or an older hub) the screen says nothing of it', (tester) async {
      for (final not in [false, null]) {
        await pumpShipday(
          tester,
          picture: picture(moves: not),
          staffId: 's3',
        );
        expect(textOf(tester, 'shipday-foot'), isNot(contains('moves the check')), reason: '$not');
        await askDelivered(tester);
        expect(textOf(tester, 'shipday-end-words'), leaves, reason: '$not');
        await stop(tester);
      }
    });

    testWidgets('marking it delivered says its open check follows, and only where one does', (tester) async {
      final t = await pumpShipday(tester, picture: picture(), staffId: 's3');
      await askDelivered(tester);
      expect(
        textOf(tester, 'shipday-end-words'),
        '$leaves Check #9 follows: it is closed as delivered, unless money is still due on it.',
      );
      await tester.tap(find.byKey(const ValueKey('shipday-end-yes')));
      await tester.pumpAndSettle();
      expect(t.hub.shipdayChanges, ['mark 7003 ALREADY_DELIVERED s3 was PICKED_UP']);
      await stop(tester);

      // a check that is closed already has nothing to follow with, and a mark that it failed moves none
      await pumpShipday(
        tester,
        picture: picture(status: 'closed', stage: 'picked_up'),
        staffId: 's3',
      );
      await askDelivered(tester);
      expect(textOf(tester, 'shipday-end-words'), leaves);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await stop(tester);
      await pumpShipday(tester, picture: picture(), staffId: 's3');
      await tapKey(tester, 'shipday-mark-7003');
      await tester.tap(find.byKey(const ValueKey('shipday-step-FAILED_DELIVERY')));
      await tester.pumpAndSettle();
      expect(
        textOf(tester, 'shipday-end-words'),
        "Mei Lin's delivery leaves Shipday's active deliveries as Failed. That cannot be taken back from the POS.",
      );
      await stop(tester);
    });

    testWidgets('the asking fits the narrowest phone with large type', (tester) async {
      await pumpShipday(tester, picture: picture(), size: const Size(320, 640), textScale: 1.6, staffId: 's3');
      await askDelivered(tester);
      expect(tester.takeException(), isNull);
      await stop(tester);
    });
  });

  group('the Deliveries screen', () {
    testWidgets("a bag Shipday took out is with Shipday's driver, by that name", (tester) async {
      await pumpDeliveries(tester, [followed('t1', 14, 'PICKED_UP', name: 'Diaz')]);
      expect(cards(tester, 'out'), ['t1']);
      expect(words(tester, 'driver-load:shipday:501'), 'Tom Reyes (Shipday) · 1 out · since $left');
      // out as Shipday said: the card says no more than any bag that is out
      expect(
        words(tester, 'out-t1'),
        '#14 Diaz | $elm | $bell | 781 555 0101 · left $left · pay at the door | Delivered | Came back',
      );
      expect(find.byKey(const ValueKey('shipday-says-t1')), findsNothing);
      await stop(tester);
    });

    testWidgets('one Shipday says was delivered stays out for its money, and says so', (tester) async {
      final t = await pumpDeliveries(tester, [followed('t1', 14, 'PICKED_UP', name: 'Diaz', due: '21.40')]);
      expect(find.byKey(const ValueKey('shipday-says-t1')), findsNothing);
      // the hub hears from Shipday that it was delivered: the check stays where it is, with the word on it
      (t.hub.orders[0]['fields'] as Map<String, dynamic>)['shipday'] = told('ALREADY_DELIVERED', minutes: 2);
      await tester.pump(const Duration(seconds: 40));
      await tester.pumpAndSettle();
      final at = clockTime(saidAt(2));
      expect(textOf(tester, 'shipday-says-t1'), 'Shipday: delivered $at');
      expect(
        words(tester, 'out-t1'),
        '#14 Diaz | $elm | $bell | 781 555 0101 · left $left · \$21.40 due | Shipday: delivered $at | '
        'Delivered | Came back',
      );
      // whoever takes the money taps Delivered, as for any bag: the money is asked first
      await tapKey(tester, 'delivered-t1');
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(t.hub.opsFor('t1'), isEmpty);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      await stop(tester);
    });

    testWidgets('one that failed, and one picked up that the POS never sent out, say what Shipday said', (
      tester,
    ) async {
      await pumpDeliveries(tester, [
        followed('t1', 14, 'FAILED_DELIVERY', name: 'Diaz'),
        followed('w1', 15, 'PICKED_UP', name: 'Shah', out: false, stage: 'new', sent: false),
        bag('w2', 16, name: 'Park'),
      ]);
      expect(textOf(tester, 'shipday-says-t1'), 'Shipday: failed $said');
      expect(textOf(tester, 'shipday-says-w1'), 'Shipday: picked up $said');
      expect(words(tester, 'waiting-w1'), endsWith('pay at the door | Shipday: picked up $said'));
      expect(find.byKey(const ValueKey('shipday-says-w2')), findsNothing);
      await stop(tester);
    });

    testWidgets('it fits a small phone with large type', (tester) async {
      await pumpDeliveries(
        tester,
        [
          followed('t1', 14, 'ALREADY_DELIVERED', name: 'Diaz-Montgomery', due: '121.40'),
          followed('w1', 15, 'PICKED_UP', name: 'Shah', out: false, stage: 'new', sent: false),
        ],
        size: const Size(320, 640),
        type: 1.3, // as large as the way here (the menu behind More) is tried with
      );
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('shipday-says-w1')), findsOneWidget);
      // the one that is out stands further down the one list of a phone
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('shipday-says-t1')),
        200,
        scrollable: find.descendant(of: find.byType(DeliveriesScreen), matching: find.byType(Scrollable)).first,
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await stop(tester);
    });
  });

  group('the list of checks, the order and the runs', () {
    testWidgets('the list says whose driver has it and what Shipday said after', (tester) async {
      final t = await stand(tester);
      t.hub
        ..withDrivers()
        ..keepsStages = true
        ..orders.add(followed('o1', 7, 'ALREADY_DELIVERED', due: '21.40'));
      await pumpOrdersOn(tester, t);
      final at = clockTime(soon.millisecondsSinceEpoch);
      expect(
        find.text(
          '1 items · open · fired · there $at · \$21.40 due · OUT · Tom Reyes (Shipday) since $left · '
          'Shipday: delivered $said · $elm',
        ),
        findsOneWidget,
      );
      await stop(tester);
    });

    testWidgets('the order says what Shipday said first, where its strip never cuts it off', (tester) async {
      await pumpOrder(tester, followed('o1', 7, 'ALREADY_DELIVERED', due: '21.40'));
      final strip = tester
          .widgetList<Text>(find.descendant(of: find.byKey(const ValueKey('when-strip')), matching: find.byType(Text)))
          .map((text) => text.data ?? '')
          .join(' | ');
      expect(strip, startsWith('Shipday: delivered $said · '));
      expect(strip, contains('out with Tom Reyes (Shipday) since $left'));
      await stop(tester);
    });

    testWidgets("the day's runs name Shipday's driver as Shipday's", (tester) async {
      await runs.pumpRuns(tester, {
        runs.monday: runs.report(runs.monday, [
          runs.driver('shipday:501', 'Tom Reyes', [
            runs.run([runs.leg('o1', 1, 'Linda', runs.at(17, 35), outcome: 'delivered', end: runs.at(17, 52))]),
          ]),
          runs.driver('d1', 'Tom', [
            runs.run([runs.leg('o2', 2, 'Raj', runs.at(18, 5))]),
          ]),
        ]),
      });
      expect(words(tester, 'runs-driver:shipday:501'), startsWith('Tom Reyes (Shipday) | '));
      expect(words(tester, 'runs-driver:d1'), startsWith('Tom | '));
      await stop(tester);
    });
  });

  group('under Location', () {
    testWidgets('it is on to start; a manager turns it off, and on again, with the one Save', (tester) async {
      final t = await pumpLocation(tester);
      await bringUp(tester, 'shipday-moves');
      expect(moves(tester), isTrue);
      expect(find.text('Shipday moves the check'), findsOneWidget);
      expect(
        find.text(
          'Picked up in Shipday takes a check Out, delivered closes it unless money is due. The POS sends no '
          'text for it',
        ),
        findsOneWidget,
      );
      // with the rest of what the location says of its deliveries
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('shipday-moves'))).dy,
        greaterThan(tester.getTopLeft(find.byKey(const ValueKey('address-list'))).dy),
      );
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('shipday-moves'))).dy,
        lessThan(tester.getTopLeft(find.byKey(const ValueKey('kitchen-notes'))).dy),
      );
      expect(saveWaiting(tester), isNull);

      await tester.tap(find.byKey(const ValueKey('shipday-moves')));
      await tester.pumpAndSettle();
      expect(moves(tester), isFalse);
      expect(
        find.text('A check stays where it is whatever Shipday says: Out and Delivered are tapped on the POS'),
        findsOneWidget,
      );
      expect((t.hub.shipdayMoves, t.hub.shipdayMovesAuth), (true, null), reason: 'nothing is sent before Save');
      expect(saveWaiting(tester), 'Not saved: Shipday');

      await saveLocation(tester);
      expect((t.hub.shipdayMoves, t.hub.shipdayMovesAuth), (false, 'Bearer tok-admin'));
      expect(find.text('Shipday saved'), findsOneWidget);
      expect(saveWaiting(tester), isNull);
      expect(moves(tester), isFalse);

      // put back as it was, it waits no longer; flipped and saved, the hub follows Shipday again
      await tester.tap(find.byKey(const ValueKey('shipday-moves')));
      await tester.pumpAndSettle();
      expect(saveWaiting(tester), 'Not saved: Shipday');
      await tester.tap(find.byKey(const ValueKey('shipday-moves')));
      await tester.pumpAndSettle();
      expect(saveWaiting(tester), isNull);
      await tester.tap(find.byKey(const ValueKey('shipday-moves')));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 5)); // the first "saved" has gone
      await saveLocation(tester);
      expect(t.hub.shipdayMoves, isTrue);
      await stop(tester);
    });

    testWidgets('it is kept by the same Save as the seats, each by itself', (tester) async {
      final t = await pumpLocation(tester);
      await bringUp(tester, 'seats-enabled');
      await tester.tap(find.byKey(const ValueKey('seats-enabled')));
      await tester.pumpAndSettle();
      await bringUp(tester, 'shipday-moves');
      await tester.tap(find.byKey(const ValueKey('shipday-moves')));
      await tester.pumpAndSettle();
      expect(saveWaiting(tester), 'Not saved: seats, Shipday');
      await saveLocation(tester);
      expect((t.hub.seats, t.hub.shipdayMoves), (false, false));
      expect(find.text('Seats and Shipday saved'), findsOneWidget);
      await stop(tester);
    });

    testWidgets('a hub older than it follows nothing and shows no switch', (tester) async {
      await pumpLocation(tester, setUp: (hub) => hub.shipdayMoves = null);
      await bringUp(tester, 'address-list');
      expect(find.byKey(const ValueKey('shipday-moves')), findsNothing);
      expect(find.text('Shipday moves the check'), findsNothing);
      await stop(tester);
    });
  });
}
