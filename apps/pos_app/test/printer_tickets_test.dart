import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/printers.dart';
import 'package:pos_app/screens/printers_screen.dart';

import 'hub.dart';
import 'printers_screen_test.dart' show station;

/// The kitchen's printer, for the two woks and the fryer, and the bar's own: as a hub that can print a
/// ticket for each station lists them (`tickets` and `groups` on every printer).
Map<String, dynamic> printers({String tickets = 'one', List<List<String>> groups = const []}) => {
  'printers': [
    {
      'id': 'line',
      'station': 'wok1',
      'stations': ['wok1', 'wok2', 'fryer'],
      'address': '10.27.1.14',
      'dialect': 'escpos',
      'fallbacks': <String>[],
      'tickets': tickets,
      'groups': groups,
    },
    {
      'id': 'bar',
      'station': 'bar',
      'stations': ['bar'],
      'address': '10.27.1.166',
      'dialect': 'star',
      'fallbacks': <String>[],
      'tickets': 'one',
      'groups': <List<String>>[],
    },
  ],
  'takeout_station': 'takeout',
  'source': 'settings',
};

final stations = {
  'stations': [
    station('wok1', 'Wok 1', dishes: 120, printer: 'line'),
    station('wok2', 'Wok 2', dishes: 80, printer: 'line'),
    station('fryer', 'Fryer', dishes: 42, printer: 'line'),
    station('bar', 'Bar', dishes: 30, printer: 'bar'),
    station('broiler', 'Broiler', dishes: 12),
  ],
  'missing': <String>[],
  'takeout_station': 'takeout',
};

Future<Terminal> pumpPrinters(
  WidgetTester tester,
  Map<String, dynamic> saved, {
  Size size = const Size(1100, 3200),
}) async {
  final t = await terminal(tester);
  tester.view.physicalSize = size;
  t.hub.printers = saved;
  t.hub.stations = stations;
  await tester.pumpWidget(
    MaterialApp(
      home: PrintersScreen(api: t.api, token: 'tok-admin', addresses: const ['10.27.1.44']),
    ),
  );
  await tester.pumpAndSettle();
  return t;
}

String note(WidgetTester tester, String id) =>
    tester.widget<Text>(find.byKey(ValueKey('printer-tickets-note:$id'))).data!;

bool picked(WidgetTester tester, String key) => tester.widget<ChoiceChip>(find.byKey(ValueKey(key))).selected;

PrinterConfig saved(Terminal t, String id) =>
    PrinterSettings.fromJson(t.hub.printers).printers.firstWhere((p) => p.id == id);

void main() {
  test('the stations of each ticket: all on one, or each its own with the groups together', () {
    const three = ['wok1', 'wok2', 'fryer'];
    expect(ticketSets(three, 'one', const []), [three]);
    expect(ticketSets(three, null, const []), [three]); // a hub that knows one way
    expect(ticketSets(three, 'each', const []), [
      ['wok1'],
      ['wok2'],
      ['fryer'],
    ]);
    expect(
      ticketSets(three, 'each', const [
        ['wok1', 'fryer'],
      ]),
      [
        ['wok1', 'fryer'], // where the first of the group stands
        ['wok2'],
      ],
    );
    expect(ticketSets(const ['wok1'], 'each', const []), [
      ['wok1'],
    ]);
    // a group keeps the stations still on the printer, in its order; one station left is no group
    expect(
      keptGroups(three, const [
        ['wok2', 'wok1', 'range'],
        ['fryer', 'sushi'],
        ['wok1', 'fryer'],
      ]),
      [
        ['wok1', 'wok2'],
      ],
    );
  });

  test('a printer from a hub that prints one ticket a printer gets no word of tickets back', () {
    final old = PrinterConfig.fromJson(const {'id': 'p1', 'station': 'wok1', 'address': '10.0.0.1'});
    expect(old.tickets, isNull);
    expect(old.toJson().containsKey('tickets'), isFalse);
    expect(old.toJson().containsKey('groups'), isFalse);
    final now = PrinterConfig.fromJson(const {
      'id': 'p1',
      'stations': ['wok1', 'wok2', 'fryer'],
      'address': '10.0.0.1',
      'tickets': 'each',
      'groups': [
        ['wok1', 'wok2'],
      ],
    });
    expect(now.sets, [
      ['wok1', 'wok2'],
      ['fryer'],
    ]);
    expect(now.toJson()['tickets'], 'each');
    expect(now.toJson()['groups'], [
      ['wok1', 'wok2'],
    ]);
    expect(now, PrinterConfig.fromJson(now.toJson()));
  });

  testWidgets('a printer for several stations prints one ticket for all, or one per station', (tester) async {
    final t = await pumpPrinters(tester, printers());
    // as it always printed, until told otherwise
    expect(picked(tester, 'printer-tickets-one:line'), isTrue);
    expect(note(tester, 'line'), 'Their dishes come out on one ticket, headed Wok 1 + Wok 2 + Fryer.');
    expect(find.text('Print together'), findsNothing);
    // a printer for one station has nothing to choose
    expect(find.byKey(const ValueKey('printer-tickets-one:bar')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('printer-tickets-each:line')));
    await tester.pumpAndSettle();
    expect(picked(tester, 'printer-tickets-each:line'), isTrue);
    expect(note(tester, 'line'), 'A ticket for each of: Wok 1 · Wok 2 · Fryer');
    expect(find.text('Print together'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('printers-save')));
    await tester.pumpAndSettle();
    expect(saved(t, 'line').tickets, 'each');
    expect(saved(t, 'line').groups, isEmpty);
    expect(saved(t, 'bar').tickets, 'one');
    expect(picked(tester, 'printer-tickets-each:line'), isTrue); // and it stands as saved

    // the demo ticket prints once for each, headed as the tickets will be
    await tester.pump(const Duration(seconds: 5)); // "Printers saved" has had its time
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('printer-test:line')));
    await tester.pumpAndSettle();
    expect(find.text('3 demo tickets queued for the Wok 1 + Wok 2 + Fryer printer'), findsOneWidget);
  });

  testWidgets('stations grouped on a printer share a ticket', (tester) async {
    final t = await pumpPrinters(tester, printers(tickets: 'each'));
    await tester.tap(find.byKey(const ValueKey('printer-group-add:line')));
    await tester.pumpAndSettle();
    expect(find.text('Print together'), findsNWidgets(2)); // the row's label, and the dialog's title
    // one station is no group
    await tester.tap(find.byKey(const ValueKey('group-station:wok1')));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('group-save'))).onPressed, isNull);
    await tester.tap(find.byKey(const ValueKey('group-station:wok2')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('group-save')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('printer-group:line:wok1')), findsOneWidget);
    expect(find.text('Wok 1 + Wok 2'), findsOneWidget);
    expect(note(tester, 'line'), 'A ticket for each of: Wok 1 + Wok 2 · Fryer');
    // one station left over: nothing more to group
    expect(find.byKey(const ValueKey('printer-group-add:line')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('printers-save')));
    await tester.pumpAndSettle();
    expect(saved(t, 'line').groups, [
      ['wok1', 'wok2'],
    ]);
    expect(find.byKey(const ValueKey('printer-group:line:wok1')), findsOneWidget);

    // a tap on the group changes it: the fryer in place of wok 2
    await tester.tap(find.byKey(const ValueKey('printer-group:line:wok1')));
    await tester.pumpAndSettle();
    expect(tester.widget<FilterChip>(find.byKey(const ValueKey('group-station:wok2'))).selected, isTrue);
    await tester.tap(find.byKey(const ValueKey('group-station:wok2')));
    await tester.tap(find.byKey(const ValueKey('group-station:fryer')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('group-save')));
    await tester.pumpAndSettle();
    expect(note(tester, 'line'), 'A ticket for each of: Wok 1 + Fryer · Wok 2');

    // its bin takes the group apart
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('printer-group:line:wok1')),
        matching: find.byTooltip('Print Wok 1 and Fryer apart'),
      ),
    );
    await tester.pumpAndSettle();
    expect(note(tester, 'line'), 'A ticket for each of: Wok 1 · Wok 2 · Fryer');
    expect(find.byKey(const ValueKey('printer-group-add:line')), findsOneWidget);
  });

  testWidgets('a station taken off the printer leaves its group, and two stations have nothing to group', (
    tester,
  ) async {
    final t = await pumpPrinters(
      tester,
      printers(
        tickets: 'each',
        groups: [
          ['wok1', 'wok2'],
        ],
      ),
    );
    expect(note(tester, 'line'), 'A ticket for each of: Wok 1 + Wok 2 · Fryer');
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('printer-station:line:wok2')),
        matching: find.byTooltip('Take Wok 2 off this printer'),
      ),
    );
    await tester.pumpAndSettle();
    expect(note(tester, 'line'), 'A ticket for each of: Wok 1 · Fryer');
    expect(find.text('Print together'), findsNothing); // two grouped would be one ticket for all
    await tester.tap(find.byKey(const ValueKey('printers-save')));
    await tester.pumpAndSettle();
    expect(saved(t, 'line').stations, ['wok1', 'fryer']);
    expect(saved(t, 'line').tickets, 'each');
    expect(saved(t, 'line').groups, isEmpty);
  });

  testWidgets('a hub that prints one ticket a printer is offered no choice', (tester) async {
    final old = printers();
    for (final p in old['printers'] as List) {
      (p as Map)
        ..remove('tickets')
        ..remove('groups');
    }
    final t = await pumpPrinters(tester, old);
    expect(find.text('Tickets'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('printer-dialect-star:line'))); // a change, so there is a Save
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('printers-save')));
    await tester.pumpAndSettle();
    expect(((t.hub.printers['printers'] as List).first as Map).containsKey('tickets'), isFalse);
  });

  testWidgets('on a phone the choice and the groups wrap inside the card', (tester) async {
    // The test font is far wider than the real one, and older rows of the card run over the side with it:
    // they are let be here, and the rows this adds are measured.
    final complain = FlutterError.onError;
    FlutterError.onError = (_) {};
    addTearDown(() => FlutterError.onError = complain);
    await pumpPrinters(
      tester,
      printers(
        tickets: 'each',
        groups: [
          ['wok1', 'wok2'],
        ],
      ),
      size: const Size(360, 2400),
    );
    expect(note(tester, 'line'), 'A ticket for each of: Wok 1 + Wok 2 · Fryer');
    for (final key in ['printer-tickets-one:line', 'printer-tickets-each:line', 'printer-group:line:wok1']) {
      final box = tester.getRect(find.byKey(ValueKey(key)));
      expect(box.left >= 0 && box.right <= 360, isTrue, reason: '$key at $box');
    }
    expect(tester.getRect(find.byKey(const ValueKey('printer-tickets-note:line'))).right <= 360, isTrue);
    await tester.tap(find.byKey(const ValueKey('printer-group:line:wok1')));
    await tester.pumpAndSettle();
    final dialog = tester.getRect(find.byType(AlertDialog));
    for (final code in ['wok1', 'wok2', 'fryer']) {
      final chip = tester.getRect(find.byKey(ValueKey('group-station:$code')));
      expect(chip.left >= dialog.left && chip.right <= dialog.right, isTrue, reason: '$code at $chip');
    }
    FlutterError.onError = complain;
  });
}
