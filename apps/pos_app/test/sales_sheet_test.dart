import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/sales_report.dart';
import 'package:pos_app/screens/sales_screen.dart';

import 'hub.dart';
import 'sales_report_test.dart' show at, ms, pumpSales, tapKey, theWeek, today, week;

/// The days of the sales as a table for a spreadsheet (docs/sales-report.md, "For the accountant"): the hub
/// lays the table out and does every sum; these tests are about the screen asking for the days it shows,
/// putting exactly what the hub said on the clipboard, and saying what happened.

const idle = 'A line a day to paste into a spreadsheet: sales, tax, comps, voids and the money taken.';

/// Two days of a week as the hub lays them out, with the totals.
Map<String, dynamic> table({bool running = false}) => {
  'first': '2026-11-09',
  'last': '2026-11-15',
  'running': running,
  'columns': ['Day', 'Checks', 'Food', 'Drinks', 'Dishes sold', 'Sales tax', 'Total', 'Cash', 'Card', 'Money taken'],
  'rows': [
    ['2026-11-09', '41', '900.00', '310.00', '1210.00', '84.70', '1294.70', '400.00', '894.70', '1294.70'],
    ['2026-11-10', '0', '0.00', '0.00', '0.00', '0.00', '0.00', '0.00', '0.00', '0.00'],
  ],
  'total': ['Total', '41', '900.00', '310.00', '1210.00', '84.70', '1294.70', '400.00', '894.70', '1294.70'],
  'max_days': 92,
  'now_ms': ms(21),
};

/// What the device's clipboard was given, in order. [refuses] makes the device refuse.
List<String> clipboard(WidgetTester tester, {bool refuses = false}) {
  final given = <String>[];
  final messenger = tester.binding.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'Clipboard.setData') {
      if (refuses) throw PlatformException(code: 'refused');
      given.add((call.arguments as Map)['text'] as String);
    }
    return null;
  });
  addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform, null));
  return given;
}

String said(WidgetTester tester) => tester.widget<Text>(find.byKey(const ValueKey('sales-sheet-said'))).data!;

void main() {
  group('the table as text', () {
    test('the names, a line a day, then the totals: cells a tab apart, lines a line apart', () {
      final sheet = SalesSheet.fromJson(table());
      expect(sheet.text.split('\n'), [
        'Day\tChecks\tFood\tDrinks\tDishes sold\tSales tax\tTotal\tCash\tCard\tMoney taken',
        '2026-11-09\t41\t900.00\t310.00\t1210.00\t84.70\t1294.70\t400.00\t894.70\t1294.70',
        '2026-11-10\t0\t0.00\t0.00\t0.00\t0.00\t0.00\t0.00\t0.00\t0.00',
        'Total\t41\t900.00\t310.00\t1210.00\t84.70\t1294.70\t400.00\t894.70\t1294.70',
      ]);
      expect(
        (sheet.running, sheet.maxDays, sheet.copied),
        (false, 92, 'Copied 2 days and the totals. Paste them into a spreadsheet.'),
      );
    });

    test('a cell never ends a cell or a line, whatever a menu is called', () {
      final sheet = SalesSheet.fromJson({
        'columns': ['Day', 'Food\tand\nmore', 7],
        'rows': [
          ['2026-11-16', '1.00', '2'],
        ],
      });
      expect(sheet.text, 'Day\tFood and more\t7\n2026-11-16\t1.00\t2');
      expect(sheet.total, isEmpty);
      expect(sheet.copied, 'Copied 1 day. Paste it into a spreadsheet.');
    });

    test('an answer with nothing in it is a table with nothing in it', () {
      final sheet = SalesSheet.fromJson(const {});
      expect([sheet.columns, sheet.rows, sheet.total], everyElement(isEmpty));
      expect(sheet.text, '');
    });
  });

  group('copying the days shown', () {
    testWidgets('the tile is under what the checks come to, and a tap copies what the hub laid out', (tester) async {
      final given = clipboard(tester);
      final s = await pumpSales(tester, before: (hub) => hub.sheets = {theWeek: table()});
      expect(find.text('Copy each day for the accountant'), findsOneWidget);
      expect(said(tester), idle);
      expect(find.byKey(const ValueKey('sales-sheet-copy')), findsOneWidget);
      final tile = tester.getTopLeft(find.byKey(const ValueKey('sales-sheet'))).dy;
      expect(tile, greaterThan(tester.getTopLeft(find.byKey(const ValueKey('sales-total'))).dy));
      expect(tile, lessThan(tester.getTopLeft(find.byKey(const ValueKey('sales-by-day'))).dy));
      expect(s.t.hub.sheetAsks, isEmpty); // nothing is asked until somebody wants it

      await tapKey(tester, 'sales-sheet');
      expect(s.t.hub.sheetAsks, [theWeek]);
      expect(s.t.hub.sheetAuth, 'Bearer tok-admin');
      expect(given, [SalesSheet.fromJson(table()).text]);
      expect(given.single.split('\n').first, startsWith('Day\tChecks\tFood\tDrinks'));
      expect(said(tester), 'Copied 2 days and the totals. Paste them into a spreadsheet.');
      expect(find.byKey(const ValueKey('sales-sheet-done')), findsOneWidget);
      expect(find.byKey(const ValueKey('sales-sheet-copy')), findsNothing);
      // a second tap copies again: the hub is asked again, so the table is what the days come to now
      await tapKey(tester, 'sales-sheet');
      expect((s.t.hub.sheetAsks.length, given.length), (2, 2));
    });

    testWidgets('one day is said as the day, asked for by name, and today is said to be still running', (tester) async {
      final given = clipboard(tester);
      final s = await pumpSales(tester);
      await tester.tap(find.byKey(const ValueKey('sales:today')));
      await tester.pumpAndSettle();
      expect(find.text('Copy the day for the accountant'), findsOneWidget);
      await tapKey(tester, 'sales-sheet');
      expect(s.t.hub.sheetAsks, ['2026-11-16..2026-11-16']); // the day the screen shows, not "whatever runs now"
      expect(given.single, 'Day\tChecks\tTotal\n2026-11-16\t0\t0.00\nTotal\t0\t0.00');
      expect(
        said(tester),
        'Copied 1 day and the totals. Paste them into a spreadsheet. Today is not over, so its line will still change.',
      );
    });

    testWidgets('other days read: what was said about the last copy is gone', (tester) async {
      clipboard(tester);
      final s = await pumpSales(tester);
      await tapKey(tester, 'sales-sheet');
      expect(said(tester), 'Copied 7 days and the totals. Paste them into a spreadsheet.');
      await tester.tap(find.byKey(const ValueKey('sales:yesterday')));
      await tester.pumpAndSettle();
      expect(said(tester), idle);
      expect(find.byKey(const ValueKey('sales-sheet-copy')), findsOneWidget);
      await tapKey(tester, 'sales-sheet');
      expect(s.t.hub.sheetAsks, [theWeek, '2026-11-15..2026-11-15']);
      expect(said(tester), 'Copied 1 day and the totals. Paste them into a spreadsheet.');
    });

    testWidgets('while the hub adds up the tile turns, and a second tap asks nothing more', (tester) async {
      final given = clipboard(tester);
      final s = await pumpSales(tester);
      final held = s.t.hub.sheetHeld = Completer<void>();
      await tester.ensureVisible(find.byKey(const ValueKey('sales-sheet')));
      await tester.tap(find.byKey(const ValueKey('sales-sheet')));
      await tester.pump();
      expect(find.byKey(const ValueKey('sales-sheet-busy')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('sales-sheet')));
      await tester.pump();
      expect(s.t.hub.sheetAsks.length, 1);
      expect(given, isEmpty);
      held.complete();
      s.t.hub.sheetHeld = null;
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('sales-sheet-busy')), findsNothing);
      expect((given.length, said(tester)), (1, 'Copied 7 days and the totals. Paste them into a spreadsheet.'));
    });

    testWidgets('days picked while the hub adds up: nothing is copied for days no longer shown', (tester) async {
      final given = clipboard(tester);
      final s = await pumpSales(tester);
      final held = s.t.hub.sheetHeld = Completer<void>();
      await tester.ensureVisible(find.byKey(const ValueKey('sales-sheet')));
      await tester.tap(find.byKey(const ValueKey('sales-sheet')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('sales:yesterday')));
      await tester.pump();
      held.complete();
      s.t.hub.sheetHeld = null;
      await tester.pumpAndSettle();
      expect(given, isEmpty);
      expect(said(tester), idle);
      expect(find.byKey(const ValueKey('sales-sheet-busy')), findsNothing);
      await tapKey(tester, 'sales-sheet'); // and the days now shown copy as any others
      expect((given.length, s.t.hub.sheetAsks.last), (1, '2026-11-15..2026-11-15'));
    });

    testWidgets(
      'an older hub, the hour over, no answer, a device that refuses: said on the tile, and a tap asks again',
      (tester) async {
        final given = clipboard(tester);
        final s = await pumpSales(tester, before: (hub) => hub.sheets = null);
        await tapKey(tester, 'sales-sheet');
        expect(said(tester), 'This hub is older than this table. Update the hub, then copy again.');
        final words = tester.widget<Text>(find.byKey(const ValueKey('sales-sheet-said')));
        final context = tester.element(find.byKey(const ValueKey('sales-sheet')));
        expect(words.style?.color, Theme.of(context).colorScheme.error);
        expect(find.byKey(const ValueKey('sales-sheet-copy')), findsOneWidget); // nothing was copied
        expect(find.byKey(const ValueKey('sales-net')), findsOneWidget); // and the sales stay as they read

        s.t.hub
          ..sheets = {}
          ..refuseSheet = 401;
        await tapKey(tester, 'sales-sheet');
        expect(said(tester), "The manager's hour here is over: go back and open Location again.");
        s.t.hub
          ..refuseSheet = null
          ..down = true;
        await tapKey(tester, 'sales-sheet');
        expect(said(tester), 'The hub is not answering');
        expect(given, isEmpty);
        s.t.hub.down = false;
        await tapKey(tester, 'sales-sheet');
        expect((given.length, said(tester)), (1, 'Copied 7 days and the totals. Paste them into a spreadsheet.'));

        // a device that will not take it says so, and says nothing was copied
        clipboard(tester, refuses: true);
        await tapKey(tester, 'sales-sheet');
        expect(said(tester), 'This device would not take it on its clipboard.');
        expect(find.byKey(const ValueKey('sales-sheet-done')), findsNothing);
      },
    );

    testWidgets('on a small phone with large type the tile fits whatever it says, in the dark too', (tester) async {
      clipboard(tester);
      for (final dark in [false, true]) {
        final t = await terminal(tester);
        t.hub
          ..sales = {theWeek: week(), '': today()}
          ..sheets = {theWeek: table(running: true)};
        tester.view.physicalSize = const Size(320, 568);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(
          MaterialApp(
            theme: dark ? ThemeData.dark() : null,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.3)),
              child: child!,
            ),
            home: SalesScreen(api: t.api, token: 'tok-admin', now: () => at(21)),
          ),
        );
        await tester.pumpAndSettle();
        // the tile is brought whole onto the screen first: with type this large it is several lines tall
        Future<void> tapTile() async {
          await tester.ensureVisible(find.byKey(const ValueKey('sales-sheet')));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('sales-sheet')));
          await tester.pumpAndSettle();
        }

        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('sales-sheet')),
          150,
          scrollable: find.byType(Scrollable).first,
        );
        expect(tester.takeException(), isNull);
        await tapTile();
        expect(
          said(tester),
          'Copied 2 days and the totals. Paste them into a spreadsheet. Today is not over, so its line will still change.',
        );
        expect(tester.takeException(), isNull);
        t.hub.down = true;
        await tapTile();
        expect(said(tester), 'The hub is not answering');
        expect(tester.takeException(), isNull);
        t.hub.down = false;
      }
    });
  });
}
