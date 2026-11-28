import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/check_history.dart';
import 'package:pos_app/shipday.dart';

import 'check_history_test.dart' show step;
import 'coursing_test.dart' show pumpLocation;
import 'hub.dart';
import 'location_rows.dart';
import 'shipday_test.dart' show evening, pumpShipday, textOf;

/// A check marked Ready tells Shipday (docs/shipday.md, "Saying it is ready for pickup"; the owner,
/// 2026-11-28: "By itself when the check is Ready"): the hub tells Shipday a delivery is ready for pickup
/// when its check on the POS is marked Ready, once, and writes on the check that it did. The hub does the
/// telling (backend/tests/shipday/test_api.py); these tests are about what the screens say of it: the Shipday
/// screen's foot, the check beside a delivery, the check's history, and the switch under Location that turns
/// it off. The button that tells Shipday by hand is in shipday_test.dart.

bool tells(WidgetTester tester) => tester.widget<SwitchListTile>(find.byKey(const ValueKey('shipday-ready'))).value;

bool moves(WidgetTester tester) => tester.widget<SwitchListTile>(find.byKey(const ValueKey('shipday-moves'))).value;

const itself =
    'A delivery whose check is marked Ready on the POS is told to Shipday as ready for pickup by itself. '
    'The Ready for pickup button stays for the odd one.';
const byHand = 'Ready for pickup tells Shipday the food is made and waits for its driver.';

void main() {
  group('a check marked Ready tells Shipday', () {
    test('the hub says whether it tells Shipday by itself, and the check beside a delivery that it is ready', () {
      expect(ShipdayBoard.fromJson(Hub.shipdayStands()).tellsReady, isTrue);
      expect(ShipdayBoard.fromJson(Hub.shipdayStands(tells: false)).tellsReady, isFalse);
      expect(ShipdayBoard.fromJson(Hub.shipdayStands(tells: null)).tellsReady, isFalse, reason: 'an older hub');
      expect(const ShipdayBoard().tellsReady, isFalse);
      final check = ShipdayCheck.fromJson(Hub.shipdayCheck('o-7', 14, stage: 'ready'))!;
      expect(check.words, 'Check #14 · ready');
      // what the location says of Shipday, as the hub keeps it; one from before the second switch says
      // nothing of it
      final both = ShipdaySetting.fromJson({'moves_checks': false, 'tells_ready': true});
      expect((both.movesChecks, both.tellsReady), (false, true));
      final older = ShipdaySetting.fromJson({'moves_checks': true});
      expect((older.movesChecks, older.tellsReady), (true, null));
    });

    test("the check's history says that Shipday was told, and whether the hub told it by itself", () {
      List<String> history({required bool auto, String by = 'Shipday'}) {
        final words = wordsOf(
          HistoryStep.fromJson(step('shipday_ready', 0, by: by, device: 'shipday', said: {'auto': auto, 'told_ms': 0})),
          time: (ms) => 'at $ms',
        );
        return [words.title, ...words.under];
      }

      expect(history(auto: true), ['Told Shipday it is ready for pickup', 'By itself, as the check was marked Ready']);
      expect(history(auto: false, by: 'Amy'), ['Told Shipday it is ready for pickup']);
      // who did it: the hub for Shipday, said once; or whoever tapped Ready for pickup on the Shipday screen
      expect(whoLine(HistoryStep.fromJson(step('shipday_ready', 0, by: 'Shipday', device: 'shipday'))), 'Shipday');
      expect(whoLine(HistoryStep.fromJson(step('shipday_ready', 0, by: 'Amy', device: 'shipday'))), 'Amy · shipday');
    });

    testWidgets('the Shipday screen says that Ready on the POS tells Shipday, where the hub does', (tester) async {
      await pumpShipday(tester, size: const Size(390, 2600), staffId: 's3');
      expect(textOf(tester, 'shipday-foot'), contains(itself));
      expect(textOf(tester, 'shipday-foot'), isNot(contains(byHand)));
      // the location turned it off, or the hub is from before it: the button is the way, and the foot says so
      for (final not in [false, null]) {
        final picture = evening();
        if (not == null) {
          picture.remove('tells_ready');
        } else {
          picture['tells_ready'] = false;
        }
        await tester.pumpWidget(const SizedBox());
        await pumpShipday(tester, picture: picture, size: const Size(390, 2600), staffId: 's3');
        expect(textOf(tester, 'shipday-foot'), contains(byHand), reason: '$not');
        expect(textOf(tester, 'shipday-foot'), isNot(contains('by itself')), reason: '$not');
        expect(find.byKey(const ValueKey('shipday-ready-7002')), findsOneWidget, reason: 'the button stays');
      }
      await stop(tester);
    });

    testWidgets('the foot fits the narrowest phone with large type', (tester) async {
      await pumpShipday(tester, size: const Size(320, 640), textScale: 1.6, staffId: 's3');
      await tester.dragUntilVisible(
        find.byKey(const ValueKey('shipday-foot')),
        find.byKey(const ValueKey('shipday-list')),
        const Offset(0, -300),
      );
      expect(textOf(tester, 'shipday-foot'), contains(itself));
      expect(tester.takeException(), isNull);
      await stop(tester);
    });
  });

  group('under Location', () {
    testWidgets('it is on to start; a manager turns it off, and on again, with the one Save', (tester) async {
      final t = await pumpLocation(tester);
      await bringUp(tester, 'shipday-ready');
      expect(tells(tester), isTrue);
      expect(find.text('Ready tells Shipday'), findsOneWidget);
      expect(
        find.text(
          "A delivery's check marked Ready tells Shipday it is ready for pickup, once. The button on the Shipday "
          'screen stays for the odd one',
        ),
        findsOneWidget,
      );
      // right under the other thing the location says of Shipday
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('shipday-ready'))).dy,
        greaterThan(tester.getTopLeft(find.byKey(const ValueKey('shipday-moves'))).dy),
      );
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('shipday-ready'))).dy,
        lessThan(tester.getTopLeft(find.byKey(const ValueKey('kitchen-notes'))).dy),
      );
      expect(saveWaiting(tester), isNull);

      await tester.tap(find.byKey(const ValueKey('shipday-ready')));
      await tester.pumpAndSettle();
      expect(tells(tester), isFalse);
      expect(
        find.text('Shipday is told a delivery is ready only by Ready for pickup on the Shipday screen'),
        findsOneWidget,
      );
      expect(t.hub.shipdayTells, isTrue);
      expect(t.hub.shipdaySaved, isEmpty, reason: 'nothing is sent before Save');
      expect(saveWaiting(tester), 'Not saved: Shipday');

      await saveLocation(tester);
      expect((t.hub.shipdayTells, t.hub.shipdayMoves, t.hub.shipdayMovesAuth), (false, true, 'Bearer tok-admin'));
      expect(t.hub.shipdaySaved, [
        {'tells_ready': false},
      ], reason: 'only the switch that was turned is sent');
      expect(find.text('Shipday saved'), findsOneWidget);
      expect(saveWaiting(tester), isNull);
      expect((tells(tester), moves(tester)), (false, true));

      // put back as it was, it waits no longer; flipped and saved, the hub tells Shipday again
      await tester.tap(find.byKey(const ValueKey('shipday-ready')));
      await tester.pumpAndSettle();
      expect(saveWaiting(tester), 'Not saved: Shipday');
      await tester.tap(find.byKey(const ValueKey('shipday-ready')));
      await tester.pumpAndSettle();
      expect(saveWaiting(tester), isNull);
      await tester.tap(find.byKey(const ValueKey('shipday-ready')));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 5)); // the first "saved" has gone
      await saveLocation(tester);
      expect(t.hub.shipdayTells, isTrue);
      await stop(tester);
    });

    testWidgets('both switches of Shipday are one part of the Save, each sent only when it was turned', (tester) async {
      final t = await pumpLocation(tester);
      await bringUp(tester, 'shipday-moves');
      await tester.tap(find.byKey(const ValueKey('shipday-moves')));
      await tester.pumpAndSettle();
      await bringUp(tester, 'shipday-ready');
      await tester.tap(find.byKey(const ValueKey('shipday-ready')));
      await tester.pumpAndSettle();
      expect(saveWaiting(tester), 'Not saved: Shipday');
      await saveLocation(tester);
      expect(t.hub.shipdaySaved, [
        {'moves_checks': false, 'tells_ready': false},
      ]);
      expect((t.hub.shipdayMoves, t.hub.shipdayTells), (false, false));
      expect((moves(tester), tells(tester)), (false, false));
      // the first alone: the second is not sent, and stays as the hub has it
      await tester.pump(const Duration(seconds: 5));
      await bringUp(tester, 'shipday-moves');
      await tester.tap(find.byKey(const ValueKey('shipday-moves')));
      await tester.pumpAndSettle();
      await saveLocation(tester);
      expect(t.hub.shipdaySaved.last, {'moves_checks': true});
      expect((t.hub.shipdayMoves, t.hub.shipdayTells), (true, false));
      await stop(tester);
    });

    testWidgets('a hub from before it shows the first switch alone, and is never sent the second', (tester) async {
      final t = await pumpLocation(tester, setUp: (hub) => hub.shipdayTells = null);
      await bringUp(tester, 'shipday-moves');
      expect(find.byKey(const ValueKey('shipday-ready')), findsNothing);
      expect(find.text('Ready tells Shipday'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('shipday-moves')));
      await tester.pumpAndSettle();
      await saveLocation(tester);
      expect(t.hub.shipdaySaved, [
        {'moves_checks': false},
      ]);
      expect(moves(tester), isFalse);
      expect(find.byKey(const ValueKey('shipday-ready')), findsNothing);
      await stop(tester);
    });

    testWidgets('a hub older than Shipday moving a check shows neither', (tester) async {
      await pumpLocation(tester, setUp: (hub) => hub.shipdayMoves = null);
      await bringUp(tester, 'address-list');
      expect(find.byKey(const ValueKey('shipday-moves')), findsNothing);
      expect(find.byKey(const ValueKey('shipday-ready')), findsNothing);
      await stop(tester);
    });
  });
}
