import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/printers.dart';
import 'package:pos_app/screens/printers_screen.dart';

import 'hub.dart';

Map<String, dynamic> station(
  String code,
  String name, {
  int dishes = 0,
  int choices = 0,
  String? printer,
  bool takeout = false,
}) => {
  'code': code,
  'name': name,
  'known': true,
  'dishes': dishes,
  'choices': choices,
  'printer': printer,
  'takeout': takeout,
};

Future<Terminal> pumpPrinters(WidgetTester tester, void Function(Hub hub) arrange) async {
  final t = await terminal(tester);
  tester.view.physicalSize = const Size(1100, 3200); // the whole list on one tall screen, nothing to scroll
  arrange(t.hub);
  await tester.pumpWidget(
    MaterialApp(
      home: PrintersScreen(api: t.api, token: 'tok-admin', addresses: const ['172.19.1.44']),
    ),
  );
  await tester.pumpAndSettle();
  return t;
}

void main() {
  testWidgets('the stations the menu prints at with no printer are offered; a tap adds the printer', (tester) async {
    final t = await pumpPrinters(tester, (hub) {
      hub.printers = {
        'printers': [
          {'id': 'p1', 'station': 'wok1', 'address': '172.19.1.162', 'dialect': 'escpos', 'fallbacks': []},
        ],
        'takeout_station': 'takeout',
        'source': 'settings',
      };
      hub.stations = {
        'stations': [
          station('wok1', 'Wok 1', dishes: 120, printer: 'p1'),
          station('fryer', 'Fryer', dishes: 42),
          station('takeout', 'Takeout', choices: 2, takeout: true),
          station('soda', 'Soda'),
        ],
        'missing': ['fryer', 'takeout'],
        'takeout_station': 'takeout',
      };
    });
    expect(find.text('The menu prints at 2 stations with no printer'), findsOneWidget);
    expect(find.text('Fryer · 42 dishes'), findsOneWidget);
    expect(find.text('Takeout · 2 choices, to-go orders'), findsOneWidget);
    expect(find.text('Wok 1 printer'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('missing:fryer')));
    await tester.pumpAndSettle();
    expect(find.text('Fryer printer'), findsOneWidget); // the row is there, its station set
    expect(find.byKey(const ValueKey('missing:fryer')), findsNothing); // and no longer suggested
    expect(find.text('The menu prints at a station with no printer'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('printer-address:p2')), '172.19.1.170');
    await tester.tap(find.byKey(const ValueKey('printers-save')));
    await tester.pumpAndSettle();
    expect(t.hub.printersAuth, 'Bearer tok-admin');
    final saved = PrinterSettings.fromJson(t.hub.printers);
    expect(saved.printers.map((p) => (p.id, p.station, p.address, p.dialect)), [
      ('p1', 'wok1', '172.19.1.162', 'escpos'),
      ('p2', 'fryer', '172.19.1.170', 'escpos'),
    ]);
    expect(saved.takeoutStation, 'takeout');
    expect(find.text('Printers saved'), findsOneWidget);
  });

  testWidgets('fallbacks come from a list of the other printers and are tried in the order dragged', (tester) async {
    final t = await pumpPrinters(tester, (hub) {
      hub.printers = {
        'printers': [
          {'id': 'wok', 'station': 'wok1', 'address': '10.0.0.1', 'dialect': 'escpos', 'fallbacks': []},
          {'id': 'bar', 'station': 'bar', 'address': '10.0.0.2', 'dialect': 'star', 'fallbacks': []},
          {'id': 'sushi', 'station': 'sushi', 'address': '10.0.0.3', 'dialect': 'escpos', 'fallbacks': []},
        ],
        'takeout_station': null,
        'source': 'settings',
      };
      hub.stations = {
        'stations': [
          station('wok1', 'Wok 1', dishes: 1, printer: 'wok'),
          station('bar', 'Bar', dishes: 1, printer: 'bar'),
          station('sushi', 'Sushi bar', dishes: 1, printer: 'sushi'),
        ],
        'missing': [],
        'takeout_station': null,
      };
    });
    expect(find.text('No fallback: its tickets wait until it answers again.'), findsNWidgets(3));
    // the wok's fallbacks: the bar, then the sushi bar
    await tester.tap(find.byKey(const ValueKey('fallback-add:wok')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bar').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('fallback-add:wok')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sushi bar').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('fallback:wok:bar')), findsOneWidget);
    expect(find.byKey(const ValueKey('fallback:wok:sushi')), findsOneWidget);
    // only the two are offered: the list is empty now
    expect(find.byKey(const ValueKey('fallback-add:wok')), findsNothing);

    // dragged above the bar, the sushi bar is tried first
    await tester.drag(find.byKey(const ValueKey('fallback-handle:wok:sushi')), const Offset(0, -300));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('printers-save')));
    await tester.pumpAndSettle();
    final saved = PrinterSettings.fromJson(t.hub.printers);
    expect(saved.printers.first.fallbacks, ['sushi', 'bar']);
    expect(saved.printers[1].fallbacks, isEmpty);

    // a removed printer leaves every fallback list
    await tester.tap(find.byKey(const ValueKey('printer-delete:bar')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('fallback:wok:bar')), findsNothing);
    expect(find.byKey(const ValueKey('fallback:wok:sushi')), findsOneWidget);
  });

  testWidgets('a scan lists the printers on the network, and Add takes the address and the language', (tester) async {
    final t = await pumpPrinters(tester, (hub) {
      hub.found = [
        {'address': '172.19.1.162', 'reachable': true, 'dialect': 'escpos', 'model': 'TM-T88VII', 'maker': 'EPSON'},
        {'address': '172.19.1.14', 'reachable': true, 'dialect': 'star', 'model': null, 'maker': null},
        {'address': '172.19.1.90', 'reachable': true, 'dialect': null, 'model': null, 'maker': null},
      ];
    });
    expect(find.textContaining('No printer yet.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('printer-scan')));
    await tester.pumpAndSettle();
    expect(t.hub.scans.single['addresses'], contains('172.19.1.44')); // this terminal's address names the subnet
    expect(t.hub.scans.single['addresses'], contains('hub')); // and the hub's
    expect(find.text('3 printers on the network'), findsOneWidget);
    expect(find.text('EPSON TM-T88VII · ESC/POS (Epson and most)'), findsOneWidget);
    expect(find.text('Star (StarPRNT)'), findsOneWidget);
    expect(find.text('language unknown: pick it'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('found-add:172.19.1.14')));
    await tester.pumpAndSettle();
    final address = tester.widget<TextField>(find.byKey(const ValueKey('printer-address:p1')));
    expect(address.controller!.text, '172.19.1.14');
    final dialect = tester.widget<SegmentedButton<String>>(find.byKey(const ValueKey('printer-dialect:p1')));
    expect(dialect.selected, {'star'});
    expect(find.text('The printer says: Star (StarPRNT)'), findsOneWidget);
    expect(find.byKey(const ValueKey('found-add:172.19.1.14')), findsNothing); // added: the button is gone
    expect(find.byKey(const ValueKey('found-add:172.19.1.162')), findsOneWidget);
  });

  testWidgets('the magnifier asks the printer what it is, and the hub\'s refusal is shown', (tester) async {
    final t = await pumpPrinters(tester, (hub) {
      hub.printers = {
        'printers': [
          {'id': 'p1', 'station': 'wok1', 'address': '172.19.1.162', 'dialect': 'star', 'fallbacks': []},
        ],
        'takeout_station': 'takeout',
        'source': 'env',
      };
      hub.stations = {
        'stations': [station('wok1', 'Wok 1', dishes: 3, printer: 'p1'), station('takeout', 'Takeout', takeout: true)],
        'missing': ['takeout'],
        'takeout_station': 'takeout',
      };
      hub.identity = {'reachable': true, 'dialect': 'escpos', 'model': 'TM-T88VII', 'maker': 'EPSON'};
    });
    expect(find.textContaining('come from the hub\'s POS_PRINTERS'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('printer-detect:p1')));
    await tester.pumpAndSettle();
    expect(find.text('The printer says: EPSON TM-T88VII · ESC/POS (Epson and most)'), findsOneWidget);
    final dialect = tester.widget<SegmentedButton<String>>(find.byKey(const ValueKey('printer-dialect:p1')));
    expect(dialect.selected, {'escpos'}); // the detected language replaces the wrong one

    await tester.tap(find.byKey(const ValueKey('printer-test:p1')));
    await tester.pumpAndSettle();
    expect(t.hub.testPrints, ['p1']);

    t.hub.refusePrinters = 'the wok1 printer falls back to \'zz\', which is not a printer';
    await tester.tap(find.byKey(const ValueKey('printers-save')));
    await tester.pumpAndSettle();
    expect(find.text('the wok1 printer falls back to \'zz\', which is not a printer'), findsOneWidget);
  });

  testWidgets('the station a to-go order prints whole at is a setting', (tester) async {
    final t = await pumpPrinters(tester, (hub) {
      hub.printers = {
        'printers': [
          {'id': 'p1', 'station': 'wok1', 'address': '172.19.1.162', 'dialect': 'escpos', 'fallbacks': []},
        ],
        'takeout_station': 'takeout',
        'source': 'settings',
      };
      hub.stations = {
        'stations': [station('wok1', 'Wok 1', dishes: 3, printer: 'p1'), station('takeout', 'Takeout', takeout: true)],
        'missing': ['takeout'],
        'takeout_station': 'takeout',
      };
    });
    await tester.tap(find.byKey(const ValueKey('takeout-station')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Nowhere else').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('printers-save')));
    await tester.pumpAndSettle();
    expect(t.hub.printers['takeout_station'], isNull);
  });
}
