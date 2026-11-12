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

/// The restaurant's stations for the tests of the pick list: the wok has a printer, the rest have none.
final shared = {
  'stations': [
    station('wok1', 'Wok 1', dishes: 120, printer: 'p1'),
    station('bar', 'Bar', dishes: 30),
    station('fryer', 'Fryer', dishes: 42),
    station('takeout', 'Takeout', choices: 2, takeout: true),
    station('soda', 'Soda'),
  ],
  'missing': ['fryer', 'takeout'],
  'takeout_station': 'takeout',
};

/// What the hub finds on the network: an Epson, a Star, one that said nothing, and an office printer.
final found = <Map<String, dynamic>>[
  {'address': '10.27.1.14', 'dialect': 'escpos', 'model': 'TM-T88VII', 'maker': 'EPSON', 'kind': 'receipt'},
  {'address': '10.27.1.166', 'dialect': 'star', 'model': 'mC-Print3', 'maker': 'Star', 'kind': 'receipt'},
  {'address': '10.27.1.90', 'dialect': null, 'model': null, 'maker': null},
  {'address': '10.27.1.129', 'dialect': null, 'model': 'MF750C', 'maker': 'Canon', 'kind': 'other'},
];

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
    t.hub.identity = {'reachable': true, 'dialect': 'star', 'model': 'mC-Print3', 'maker': 'Star', 'kind': 'receipt'};
    await tester.tap(find.byKey(const ValueKey('printers-save')));
    await tester.pumpAndSettle();
    expect(t.hub.printersAuth, 'Bearer tok-admin');
    // a new printer is on Auto: it was asked its language on the way to the hub, and that is saved with it
    expect(t.hub.identified, ['172.19.1.170']);
    final saved = PrinterSettings.fromJson(t.hub.printers);
    expect(saved.printers.map((p) => (p.id, p.stations.join('+'), p.address, p.dialect, p.detected)), [
      ('p1', 'wok1', '172.19.1.162', 'escpos', null),
      ('p2', 'fryer', '172.19.1.170', 'auto', 'star'),
    ]);
    expect(find.text('Auto: Star'), findsOneWidget);
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
        {'address': '172.19.1.91', 'dialect': 'star', 'model': 'mC-Print3', 'kind': 'receipt', 'guessed': true},
        {'address': '172.19.1.30', 'dialect': null, 'model': 'MF644C', 'maker': 'Canon', 'kind': 'other'},
      ];
    });
    expect(find.textContaining('No printer yet.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('printer-scan')));
    await tester.pumpAndSettle();
    expect(t.hub.scans.single['addresses'], contains('172.19.1.44')); // this terminal's address names the subnet
    expect(t.hub.scans.single['addresses'], contains('hub')); // and the hub's
    expect(find.text('5 printers on the network'), findsOneWidget);
    expect(find.text('EPSON TM-T88VII · ESC/POS (Epson and most)'), findsOneWidget);
    expect(find.text('Star (StarPRNT)'), findsOneWidget);
    expect(find.text('language unknown: pick it'), findsOneWidget);
    expect(find.text('mC-Print3 · Star (StarPRNT), going by its name'), findsOneWidget);
    // the office printer answers on the printer port too: it is named, and not offered for tickets
    expect(find.text('Canon MF644C · not a receipt printer'), findsOneWidget);
    expect(find.byKey(const ValueKey('found-add:172.19.1.30')), findsNothing);
    expect(find.byKey(const ValueKey('found-add:172.19.1.90')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('found-add:172.19.1.14')));
    await tester.pumpAndSettle();
    final address = tester.widget<TextField>(find.byKey(const ValueKey('printer-address:p1')));
    expect(address.controller!.text, '172.19.1.14');
    // on Auto, which shows the language the scan heard
    expect(tester.widget<ChoiceChip>(find.byKey(const ValueKey('printer-dialect-auto:p1'))).selected, isTrue);
    expect(find.text('Auto: Star'), findsOneWidget);
    expect(find.text('The printer says: Star (StarPRNT)'), findsOneWidget);
    expect(t.hub.identified, isEmpty); // the scan had said it: no second question
    expect(find.byKey(const ValueKey('found-add:172.19.1.14')), findsNothing); // added: the button is gone
    expect(find.byKey(const ValueKey('found-add:172.19.1.162')), findsOneWidget);
  });

  testWidgets('the magnifier turns the address into a list of the printers found, and Other turns it back', (
    tester,
  ) async {
    final t = await pumpPrinters(tester, (hub) {
      hub.printers = {
        'printers': [
          {
            'id': 'p1',
            'stations': ['wok1'],
            'address': '10.27.1.14',
            'dialect': 'auto',
            'detected': 'escpos',
          },
        ],
        'takeout_station': 'takeout',
        'source': 'settings',
      };
      hub.stations = shared;
      hub.found = found;
    });
    await tester.tap(find.byKey(const ValueKey('missing:fryer')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('printer-address:p2')), findsOneWidget); // typed, until the magnifier
    expect(
      find.text(
        'Tap Auto to ask the printer which language it speaks. Until it answers, its tickets go out '
        'as ESC/POS.',
      ),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('printer-detect:p2')));
    await tester.pumpAndSettle();
    expect(t.hub.scans, hasLength(1)); // the hub looked
    expect(find.byKey(const ValueKey('printer-address:p2')), findsNothing);
    expect(find.text('Pick a printer'), findsOneWidget);
    expect(find.text('4 printers on the network'), findsNothing); // the list at the foot is the other button's
    await tester.tap(find.byKey(const ValueKey('printer-pick:p2')));
    await tester.pumpAndSettle();
    // every printer found, with what it is; the one another card has says for which stations
    expect(find.text('10.27.1.14 · EPSON TM-T88VII'), findsOneWidget);
    expect(find.text('prints for Wok 1'), findsOneWidget);
    expect(find.text('10.27.1.166 · Star mC-Print3'), findsOneWidget);
    expect(find.text('10.27.1.90'), findsOneWidget);
    expect(find.text('10.27.1.129 · Canon MF750C'), findsOneWidget);
    expect(find.text('not a receipt printer'), findsOneWidget);
    expect(find.text('Look again'), findsOneWidget);
    await tester.tap(find.text('10.27.1.129 · Canon MF750C'));
    await tester.pumpAndSettle();
    expect(find.text('Look again'), findsOneWidget); // not to be picked: the list is still open
    await tester.tap(find.text('10.27.1.166 · Star mC-Print3'));
    await tester.pumpAndSettle();
    // picked: the address is set, and Auto shows the language the printer answered the scan with
    expect(find.text('Auto: Star'), findsOneWidget);
    expect(find.text('The printer says: Star mC-Print3 · Star (StarPRNT)'), findsOneWidget);
    expect(t.hub.identified, isEmpty);

    // the first printer's own list opens on its address, without the hub looking again
    await tester.tap(find.byKey(const ValueKey('printer-detect:p1')));
    await tester.pumpAndSettle();
    expect(t.hub.scans, hasLength(1));
    expect(find.text('10.27.1.14 · EPSON TM-T88VII'), findsOneWidget);
    expect(find.byKey(const ValueKey('printer-address:p1')), findsNothing);
    expect(find.text('The printer says: EPSON TM-T88VII · ESC/POS (Epson and most)'), findsOneWidget);

    // "Look again" asks the hub once more; "Other" goes back to typing, the address kept
    await tester.tap(find.byKey(const ValueKey('printer-pick:p2')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Look again').last);
    await tester.pumpAndSettle();
    expect(t.hub.scans, hasLength(2));
    await tester.tap(find.byKey(const ValueKey('printer-pick:p2')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Other: type the address').last);
    await tester.pumpAndSettle();
    final typed = tester.widget<TextField>(find.byKey(const ValueKey('printer-address:p2')));
    expect(typed.controller!.text, '10.27.1.166');
    await tester.enterText(find.byKey(const ValueKey('printer-address:p2')), '10.27.1.253');
    await tester.pumpAndSettle();
    expect(find.text('Auto: Star'), findsNothing); // another address: what the other printer said is gone
    t.hub.identity = {'reachable': true, 'dialect': 'star', 'model': 'mC-Print3', 'maker': 'Star', 'kind': 'receipt'};
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(t.hub.identified, ['10.27.1.253']); // entered on Auto: the printer is asked
    expect(find.text('Auto: Star'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('printers-save')));
    await tester.pumpAndSettle();
    final saved = PrinterSettings.fromJson(t.hub.printers);
    expect(saved.printers.map((p) => (p.id, p.stations.join('+'), p.address, p.dialect, p.detected)), [
      ('p1', 'wok1', '10.27.1.14', 'auto', 'escpos'),
      ('p2', 'fryer', '10.27.1.253', 'auto', 'star'),
    ]);
  });

  testWidgets('stations share a printer: picking one that has a card puts the station on it', (tester) async {
    final t = await pumpPrinters(tester, (hub) {
      hub.printers = {
        'printers': [
          {
            'id': 'p1',
            'stations': ['wok1'],
            'address': '10.27.1.14',
            'dialect': 'auto',
            'detected': 'escpos',
          },
          {
            'id': 'p2',
            'stations': ['bar'],
            'address': '10.27.1.166',
            'dialect': 'star',
            'fallbacks': [],
          },
        ],
        'takeout_station': 'takeout',
        'source': 'settings',
      };
      hub.stations = shared;
      hub.found = found;
    });
    await tester.tap(find.byKey(const ValueKey('missing:fryer')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('fallback-add:p2'))); // the bar falls back to the new printer
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fryer').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('printer-detect:p3')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('printer-pick:p3')));
    await tester.pumpAndSettle();
    expect(find.text('prints for Wok 1'), findsOneWidget);
    await tester.tap(find.text('10.27.1.14 · EPSON TM-T88VII').last);
    await tester.pumpAndSettle();
    // one printer, one card, both stations on it; the bar's fallback follows
    expect(find.byKey(const ValueKey('printer:p3')), findsNothing);
    expect(find.text('Wok 1 + Fryer printer'), findsOneWidget);
    expect(find.text('10.27.1.14 already prints for Wok 1: Fryer was added to it.'), findsOneWidget);
    expect(find.byKey(const ValueKey('printer-station:p1:fryer')), findsOneWidget);
    expect(find.byKey(const ValueKey('fallback:p2:p1')), findsOneWidget);
    expect(find.text('Wok 1 + Fryer printer · 10.27.1.14'), findsOneWidget);

    // a station is added on the card itself, from the ones no printer has; one that has a printer is not offered
    await tester.tap(find.byKey(const ValueKey('printer-station-add:p1')));
    await tester.pumpAndSettle();
    expect(find.text('Bar'), findsOneWidget); // only the bar printer's own chip
    await tester.tap(find.text('Soda (nothing prints here yet)').last);
    await tester.pumpAndSettle();
    expect(find.text('Wok 1 + Fryer + Soda printer'), findsOneWidget);
    // and one not on the menu yet, by its code
    await tester.tap(find.byKey(const ValueKey('printer-station-add:p2')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('A new station…').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('printer-station-code:p2')), 'Dessert');
    await tester.tap(find.byKey(const ValueKey('printer-station-commit:p2')));
    await tester.pumpAndSettle();
    expect(find.text('Bar + dessert printer'), findsOneWidget);
    // a chip's bin takes its station off the printer
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('printer-station:p1:soda')),
        matching: find.byTooltip('Take Soda off this printer'),
      ),
    );
    await tester.pumpAndSettle();

    // the list at the foot says which stations each printer found prints for
    await tester.tap(find.byKey(const ValueKey('printer-scan')));
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: find.byKey(const ValueKey('found:10.27.1.14')), matching: find.text('Wok 1 + Fryer')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('printers-save')));
    await tester.pumpAndSettle();
    final saved = PrinterSettings.fromJson(t.hub.printers);
    expect(saved.printers.map((p) => (p.id, p.stations.join('+'), p.address, p.fallbacks.join('+'))), [
      ('p1', 'wok1+fryer', '10.27.1.14', ''),
      ('p2', 'bar+dessert', '10.27.1.166', 'p1'),
    ]);
    expect((t.hub.printers['printers'] as List).first['station'], 'wok1'); // an older hub reads the first

    // two cards typed to one address are told so, not saved
    await tester.tap(find.byKey(const ValueKey('missing:takeout')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('printer-address:p3')), '10.27.1.166');
    await tester.tap(find.byKey(const ValueKey('printers-save')));
    await tester.pumpAndSettle();
    expect(find.textContaining('have the same address, 10.27.1.166'), findsOneWidget);
  });

  testWidgets('printers saved with one address open as one card with their stations', (tester) async {
    await pumpPrinters(tester, (hub) {
      hub.printers = {
        'printers': [
          {'id': 'p1', 'station': 'wok1', 'address': '10.27.1.14', 'dialect': 'escpos', 'fallbacks': []},
          {
            'id': 'p2',
            'station': 'bar',
            'address': '10.27.1.166',
            'dialect': 'star',
            'fallbacks': ['p3'],
          },
          {
            'id': 'p3',
            'station': 'fryer',
            'address': '10.27.1.14',
            'dialect': 'escpos',
            'fallbacks': ['p2'],
          },
        ],
        'takeout_station': 'takeout',
        'source': 'settings',
      };
      hub.stations = shared;
    });
    expect(find.text('Wok 1 + Fryer printer'), findsOneWidget);
    expect(find.byKey(const ValueKey('printer:p3')), findsNothing);
    expect(find.byKey(const ValueKey('fallback:p2:p1')), findsOneWidget); // the bar fell back to the fryer's
    expect(find.byKey(const ValueKey('fallback:p1:p2')), findsOneWidget); // and the fryer's fallback is kept
  });

  testWidgets('Auto asks the printer its language; a language set by hand is checked against it', (tester) async {
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
    ChoiceChip chip(String language) => tester.widget<ChoiceChip>(find.byKey(ValueKey('printer-dialect-$language:p1')));
    expect((chip('auto').selected, chip('escpos').selected, chip('star').selected), (false, false, true));
    expect(find.text('Auto'), findsOneWidget);
    expect(find.textContaining('Star for a Star printer in StarPRNT mode'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('printer-dialect-auto:p1')));
    await tester.pumpAndSettle();
    expect(t.hub.identified, ['172.19.1.162']);
    expect((chip('auto').selected, chip('star').selected), (true, false));
    expect(find.text('Auto: ESC/POS'), findsOneWidget); // Auto says what it found
    expect(find.text('The printer says: EPSON TM-T88VII · ESC/POS (Epson and most)'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('printer-dialect-auto:p1'))); // already picked: asks again
    await tester.pumpAndSettle();
    expect(t.hub.identified, hasLength(2));

    // a language set by hand that is not the printer's is said so
    await tester.tap(find.byKey(const ValueKey('printer-dialect-star:p1')));
    await tester.pumpAndSettle();
    expect(
      find.text('The printer says: EPSON TM-T88VII · ESC/POS (Epson and most), and Star is set here.'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('printer-dialect-auto:p1')));
    await tester.pumpAndSettle();

    // a printer that does not answer keeps what it said before
    t.hub.identity = {'reachable': false};
    await tester.tap(find.byKey(const ValueKey('printer-dialect-auto:p1')));
    await tester.pumpAndSettle();
    expect(find.text('Auto: ESC/POS'), findsOneWidget);
    expect(find.textContaining('Nothing answers at 172.19.1.162.'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('printers-save')));
    await tester.pumpAndSettle();
    final saved = PrinterSettings.fromJson(t.hub.printers).printers.single;
    expect((saved.dialect, saved.detected), ('auto', 'escpos'));

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
