import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/screens/bag_labels_dialog.dart';

import 'bill_test.dart' as table_check show pumpOrder;
import 'catering_test.dart' show chen, platters, pumpOrder, tapKey;
import 'hub.dart';

/// Labels for the bags of a to-go order (docs/bag-labels.md): a Labels button beside the total asks how many
/// bags the order went into, and a label prints for each. The hub makes and prints the labels
/// (backend/tests/printing/test_labels.py); these tests are about what the screen asks, says and sends.

final labels = find.byKey(const ValueKey('bag-labels'));
final dialog = find.byKey(const ValueKey('bag-labels-dialog'));

Finder bags(int n) => find.byKey(ValueKey('bags:$n'));

/// Chen's phone order for pickup, which the kitchen has, with Amy at it. A phone shows the check behind
/// its button, so the check is opened there.
Future<Terminal> pumpToGo(
  WidgetTester tester, {
  Map<String, dynamic>? order,
  Size size = const Size(1100, 800),
  bool splits = false,
}) async {
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final t = await pumpOrder(tester, order ?? chen(sent: true, channel: 'phone'), size: size);
  if (splits) {
    t.hub.check = {...platters(), 'split': null, 'checks': <dynamic>[]};
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  }
  if (size.width < 720) {
    await tester.tap(find.textContaining('Check'));
    await tester.pumpAndSettle();
  }
  return t;
}

/// Lets the message at the foot of the screen go, so the next tap reaches the check under it.
Future<void> said(WidgetTester tester) async {
  ScaffoldMessenger.of(tester.element(labels)).clearSnackBars();
  await tester.pumpAndSettle();
}

void main() {
  group('the button', () {
    testWidgets('a to-go order has Labels beside its total, before Bill', (tester) async {
      await pumpToGo(tester);
      expect(labels, findsOneWidget);
      expect(find.byTooltip('Print a label for each bag'), findsOneWidget);
      final bill = find.byKey(const ValueKey('bill'));
      expect(tester.getCenter(labels).dy, tester.getCenter(bill).dy);
      expect(tester.getTopRight(labels).dx, lessThan(tester.getTopLeft(bill).dx));
      // beside the total, at no row's cost
      expect(tester.getCenter(labels).dy, moreOrLessEquals(tester.getCenter(find.text('65.01').first).dy, epsilon: 6));
      expect(tester.takeException(), isNull);
      await stop(tester);
    });

    testWidgets('with Split it stands between Split and Bill', (tester) async {
      await pumpToGo(tester, splits: true);
      final split = find.byKey(const ValueKey('split'));
      final bill = find.byKey(const ValueKey('bill'));
      expect(split, findsOneWidget);
      expect(tester.getTopRight(split).dx, lessThan(tester.getTopLeft(labels).dx));
      expect(tester.getTopRight(labels).dx, lessThan(tester.getTopLeft(bill).dx));
      expect(tester.takeException(), isNull);
      await stop(tester);
    });

    testWidgets("a table's check has no Labels button, and neither has an order with no dish", (tester) async {
      await table_check.pumpOrder(tester);
      expect(find.byKey(const ValueKey('bill')), findsOneWidget);
      expect(labels, findsNothing);
      await stop(tester);

      final empty = chen(id: 'c2', channel: 'phone')..['lines'] = <String, dynamic>{};
      final t = await pumpOrder(tester, empty);
      t.hub.check = null;
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(labels, findsNothing);
      await stop(tester);
    });
  });

  group('how many bags', () {
    testWidgets('a tap asks, and a number prints that many labels', (tester) async {
      final t = await pumpToGo(tester);
      await tapKey(tester, 'bag-labels');
      expect(dialog, findsOneWidget);
      expect(find.text('How many bags?'), findsOneWidget);
      // whose bags they are, as the labels will head them
      expect(tester.widget<Text>(find.byKey(const ValueKey('bag-labels-whose'))).data, '#12 Chen');
      expect(find.text('A label prints for each bag.'), findsOneWidget);
      // the numbers most orders go into, as buttons; nothing printed for asking
      for (var n = 1; n <= BagLabelsDialog.first; n++) {
        expect(bags(n), findsOneWidget, reason: '$n');
      }
      expect(bags(BagLabelsDialog.first + 1), findsNothing);
      expect(t.hub.bagLabels, isEmpty);

      await tester.tap(bags(3));
      await tester.pumpAndSettle();
      expect(dialog, findsNothing);
      expect(t.hub.bagLabels, [('c1', 3)]);
      expect(find.text('3 labels are printing at Takeout'), findsOneWidget);
      // the order is not touched: nothing was sent for it
      expect(t.hub.sent, isEmpty);
      await stop(tester);
    });

    testWidgets('one bag is one label, and More shows the numbers up to the most', (tester) async {
      final t = await pumpToGo(tester);
      await tapKey(tester, 'bag-labels');
      await tester.tap(bags(1));
      await tester.pumpAndSettle();
      expect(find.text('1 label is printing at Takeout'), findsOneWidget);
      await said(tester);

      await tapKey(tester, 'bag-labels');
      await tester.tap(find.byKey(const ValueKey('bags-more')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('bags-more')), findsNothing);
      expect(bags(PosApi.bagsMost + 1), findsNothing);
      await tester.ensureVisible(bags(PosApi.bagsMost));
      await tester.pumpAndSettle();
      await tester.tap(bags(PosApi.bagsMost));
      await tester.pumpAndSettle();
      // asked again with another number, it prints what it is asked for
      expect(t.hub.bagLabels, [('c1', 1), ('c1', PosApi.bagsMost)]);
      expect(find.text('${PosApi.bagsMost} labels are printing at Takeout'), findsOneWidget);
      await stop(tester);
    });

    testWidgets('Cancel, Escape and a tap beside the question print nothing', (tester) async {
      final t = await pumpToGo(tester);
      await tapKey(tester, 'bag-labels');
      await tester.tap(find.byKey(const ValueKey('bags-cancel')));
      await tester.pumpAndSettle();
      expect(dialog, findsNothing);

      await tapKey(tester, 'bag-labels');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(dialog, findsNothing);

      await tapKey(tester, 'bag-labels');
      await tester.tapAt(const Offset(8, 8));
      await tester.pumpAndSettle();
      expect(dialog, findsNothing);
      expect(t.hub.bagLabels, isEmpty);
      expect(find.byType(SnackBar), findsNothing);
      await stop(tester);
    });

    testWidgets('a closed order still prints: a label that tore is printed again', (tester) async {
      final t = await pumpToGo(
        tester,
        order: chen(sent: true, status: 'closed', channel: 'phone'),
      );
      await tapKey(tester, 'bag-labels');
      await tester.tap(bags(2));
      await tester.pumpAndSettle();
      expect(t.hub.bagLabels, [('c1', 2)]);
      await stop(tester);
    });

    testWidgets('a catering order is asked the same', (tester) async {
      final t = await pumpToGo(tester, order: chen(sent: true));
      await tapKey(tester, 'bag-labels');
      await tester.tap(bags(12));
      await tester.pumpAndSettle();
      expect(t.hub.bagLabels, [('c1', 12)]);
      expect(find.text('12 labels are printing at Takeout'), findsOneWidget);
      await stop(tester);
    });
  });

  group('when it cannot', () {
    testWidgets('what the hub says, a hub older than labels, and a hub that is away', (tester) async {
      final t = await pumpToGo(tester);
      t.hub.refuseLabels = 'No printer is set up for this location.';
      await tapKey(tester, 'bag-labels');
      await tester.tap(bags(2));
      await tester.pumpAndSettle();
      expect(find.text('No printer is set up for this location.'), findsOneWidget);
      expect(t.hub.bagLabels, isEmpty);
      await said(tester);

      t.hub.bagLabels = null;
      await tapKey(tester, 'bag-labels');
      await tester.tap(bags(2));
      await tester.pumpAndSettle();
      expect(find.text('This hub does not print bag labels yet: update it'), findsOneWidget);
      await said(tester);

      t.hub.bagLabels = [];
      t.hub.down = true;
      await tapKey(tester, 'bag-labels');
      await tester.tap(bags(2));
      await tester.pump(const Duration(seconds: 7));
      await tester.pumpAndSettle();
      expect(find.text('The labels did not print: nothing answered'), findsOneWidget);
      expect(t.hub.bagLabels, isEmpty);
      // and the button is there to try again
      expect(tester.widget<OutlinedButton>(labels).onPressed, isNotNull);
      await stop(tester);
    });
  });

  group('the question alone', () {
    Future<int?> ask(WidgetTester tester, {String whose = '', int most = PosApi.bagsMost}) async {
      int? answer = -1;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async => answer = await showDialog<int>(
                context: context,
                builder: (_) => BagLabelsDialog(whose: whose, most: most),
              ),
              child: const Text('ask'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('ask'));
      await tester.pumpAndSettle();
      return answer;
    }

    testWidgets('an order with no number and no name is not named', (tester) async {
      await ask(tester);
      expect(find.text('A label prints for each bag.'), findsOneWidget);
      expect(find.byKey(const ValueKey('bag-labels-whose')), findsNothing);
    });

    testWidgets('a hub that prints fewer shows that many and no More', (tester) async {
      await ask(tester, whose: '#7', most: 6);
      expect(find.text('#7'), findsOneWidget);
      expect(bags(6), findsOneWidget);
      expect(bags(7), findsNothing);
      expect(find.byKey(const ValueKey('bags-more')), findsNothing);
    });

    testWidgets('a number says what it is to somebody who cannot see it', (tester) async {
      final handle = tester.ensureSemantics();
      await ask(tester);
      expect(find.bySemanticsLabel('1 bag'), findsOneWidget);
      expect(find.bySemanticsLabel('3 bags'), findsOneWidget);
      handle.dispose();
    });

    test('the words for how many labels', () {
      expect(BagLabelsDialog.labelWords(1), '1 label');
      expect(BagLabelsDialog.labelWords(24), '24 labels');
    });
  });

  group('on a phone', () {
    for (final (name, size, type) in const [
      ('a phone', Size(390, 844), 1.0),
      ('a small phone with large type', Size(320, 568), 1.3),
    ]) {
      testWidgets('the button and every number fit $name', (tester) async {
        tester.platformDispatcher.textScaleFactorTestValue = type;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final t = await pumpToGo(tester, size: size, splits: true);
        final panel = tester.getRect(find.byKey(const ValueKey('check-rows')));
        // nothing runs off the check: buttons too wide for it in large type take a second row
        for (final key in const ['split', 'bag-labels', 'bill']) {
          final button = tester.getRect(find.byKey(ValueKey(key)));
          expect(button.left, greaterThanOrEqualTo(panel.left), reason: key);
          expect(button.right, lessThanOrEqualTo(panel.right), reason: key);
        }
        // the foot of the check is on the screen already: tapped where it stands
        await tester.tap(labels);
        await tester.pumpAndSettle();
        // four numbers across, each wide enough for a finger
        expect(tester.getSize(bags(1)).width, greaterThanOrEqualTo(48));
        expect(tester.getSize(bags(1)).height, greaterThanOrEqualTo(48));
        expect(tester.getCenter(bags(1)).dy, tester.getCenter(bags(4)).dy);
        expect(tester.getCenter(bags(5)).dy, greaterThan(tester.getCenter(bags(4)).dy));
        await tester.tap(find.byKey(const ValueKey('bags-more')));
        await tester.pumpAndSettle();
        await tester.ensureVisible(bags(PosApi.bagsMost));
        await tester.pumpAndSettle();
        await tester.tap(bags(PosApi.bagsMost));
        await tester.pumpAndSettle();
        expect(t.hub.bagLabels, [('c1', PosApi.bagsMost)]);
        expect(tester.takeException(), isNull);
        await stop(tester);
      });
    }
  });
}
