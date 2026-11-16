import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/printers.dart';
import 'package:pos_app/screens/location_settings_screen.dart';
import 'package:pos_app/screens/ticket_skips_dialog.dart';

import 'hub.dart';
import 'printers_screen_test.dart' show station;
import 'ticket_words_test.dart' show show;

/// Screens that skip a station (the Toast comparison: drinks rung at the bar, the simple way): a manager says
/// which stations each screen prints no ticket at, so what the bartender rings in at the bar's own screen
/// prints nothing at the bar. The hub keeps the list and prints by it; this is the manager's screen for it,
/// under Location settings, on the printers' card.

final kitchen = {
  'stations': [
    station('wok1', 'Wok 1', dishes: 120, printer: 'p1'),
    station('sushi', 'Sushi Bar', dishes: 40, printer: 'p2'),
    station('bar', 'Bar', dishes: 30, printer: 'p3'),
    station('takeout', 'Takeout', takeout: true, printer: 'p4'),
  ],
  'missing': <String>[],
  'takeout_station': 'takeout',
};

/// Location settings with the printers' card in view, on a hub that hears from the bar's and the host's
/// screens besides this one.
Future<Terminal> pumpSettings(WidgetTester tester, {void Function(Hub hub)? before, Size? size}) async {
  final t = await terminal(tester);
  if (size != null) tester.view.physicalSize = size;
  t.hub.stations = kitchen;
  t.hub.devices = ['host1', 'bar1', 't1'];
  before?.call(t.hub);
  await tester.pumpWidget(
    MaterialApp(
      home: LocationSettingsScreen(api: t.api, token: 'tok-admin', device: 't1'),
    ),
  );
  await tester.pumpAndSettle();
  if (t.hub.ticketSkips != null) await show(tester, find.byKey(const ValueKey('ticket-skips')));
  return t;
}

Future<void> open(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('ticket-skips')));
  await tester.pumpAndSettle();
  expect(find.byType(TicketSkipsDialog), findsOneWidget);
}

FilterChip chip(WidgetTester tester, String device, String code) =>
    tester.widget<FilterChip>(find.byKey(ValueKey('skips:$device:$code')));

String rowLine(WidgetTester tester) =>
    (tester.widget<ListTile>(find.byKey(const ValueKey('ticket-skips'))).subtitle! as Text).data!;

void main() {
  test('the list is read from the hub and said back without the screens that skip nothing', () {
    expect(TicketSkips.fromJson(const {}).screens, isEmpty);
    final skips = TicketSkips.fromJson(const {
      'screens': [
        {
          'device': 'bar1',
          'stations': ['bar', 'sushi'],
        },
        {'device': 'host1', 'stations': <String>[]},
      ],
    });
    expect(skips.of('BAR1'), ['bar', 'sushi']); // whatever the case of the name
    expect(skips.of('t1'), isEmpty);
    expect(skips.toJson(), {
      'screens': [
        {
          'device': 'bar1',
          'stations': ['bar', 'sushi'],
        },
      ],
    });
  });

  test('the row says which screens skip what, by the stations\' names', () {
    final stations = StationList.fromJson(kitchen);
    expect(ticketSkipsLine(const TicketSkips(), stations), 'Every screen prints at every station');
    expect(
      ticketSkipsLine(
        const TicketSkips({
          'bar1': ['bar'],
        }),
        stations,
      ),
      'bar1: no ticket at Bar',
    );
    expect(
      ticketSkipsLine(
        const TicketSkips({
          'bar1': ['bar', 'sushi'],
          'sushi1': ['sushi'],
          'bar2': ['bar'],
          'host1': [],
        }),
        stations,
      ),
      'bar1: no ticket at Bar, Sushi Bar · sushi1: no ticket at Sushi Bar · 1 more',
    );
    // a station the menu no longer names is said by its code, and so is every one before the hub lists them
    expect(
      ticketSkipsLine(
        const TicketSkips({
          'bar1': ['patio'],
        }),
        null,
      ),
      'bar1: no ticket at patio',
    );
  });

  testWidgets('a manager adds the bar\'s screen, taps the bar, and it is saved for the location', (tester) async {
    final t = await pumpSettings(tester);
    expect(find.text('Screens that skip a station'), findsOneWidget);
    expect(rowLine(tester), 'Every screen prints at every station');

    await open(tester);
    expect(find.byKey(const ValueKey('skips-none')), findsOneWidget);
    // the screens the hub hears from are buttons, this one first
    expect(find.widgetWithText(ActionChip, 't1 (this device)'), findsOneWidget);
    final offered = [
      for (final chip in tester.widgetList<ActionChip>(find.byType(ActionChip))) (chip.label as Text).data,
    ];
    expect(offered, ['t1 (this device)', 'bar1', 'host1', 'Other…']);

    await tester.tap(find.byKey(const ValueKey('skips-add:bar1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('skips-screen:bar1')), findsOneWidget);
    expect(find.byKey(const ValueKey('skips-add:bar1')), findsNothing); // listed: no longer offered
    expect(find.textContaining('With none, it prints everywhere'), findsOneWidget);
    // every station is a button, none picked
    for (final code in ['wok1', 'sushi', 'bar', 'takeout']) {
      expect(chip(tester, 'bar1', code).selected, isFalse);
    }
    expect((chip(tester, 'bar1', 'sushi').label as Text).data, 'Sushi Bar');

    await tester.tap(find.byKey(const ValueKey('skips:bar1:bar')));
    await tester.pumpAndSettle();
    expect(chip(tester, 'bar1', 'bar').selected, isTrue);
    expect(find.text('Prints no ticket at:'), findsOneWidget);
    expect(t.hub.ticketSkipsAuth, isNull); // nothing is sent before Save

    await tester.tap(find.byKey(const ValueKey('skips-save')));
    await tester.pumpAndSettle();
    expect(find.byType(TicketSkipsDialog), findsNothing);
    expect(t.hub.ticketSkipsAuth, 'Bearer tok-admin');
    expect(t.hub.ticketSkips, {
      'screens': [
        {
          'device': 'bar1',
          'stations': ['bar'],
        },
      ],
    });
    expect(rowLine(tester), 'bar1: no ticket at Bar');
    expect(find.text('Saved: the next send prints by it'), findsOneWidget);
  });

  testWidgets('a listed screen shows its stations picked; one is taken off, another put on, a screen removed', (
    tester,
  ) async {
    final t = await pumpSettings(
      tester,
      before: (hub) => hub.ticketSkips = {
        'screens': [
          {
            'device': 'bar1',
            'stations': ['bar', 'patio'],
          },
          {
            'device': 'host1',
            'stations': ['takeout'],
          },
        ],
      },
    );
    expect(rowLine(tester), 'bar1: no ticket at Bar, patio · host1: no ticket at Takeout');
    await open(tester);
    expect((chip(tester, 'bar1', 'bar').selected, chip(tester, 'bar1', 'sushi').selected), (true, false));
    // a station the menu no longer has is still there to take off
    expect(chip(tester, 'bar1', 'patio').selected, isTrue);
    expect(find.byKey(const ValueKey('skips:host1:patio')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('skips:bar1:patio')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('skips:bar1:patio')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('skips:bar1:sushi'))); // tapped after the bar, listed before it
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('skips-remove:host1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('skips-screen:host1')), findsNothing);
    expect(find.byKey(const ValueKey('skips-add:host1')), findsOneWidget); // and can be added again

    await tester.ensureVisible(find.byKey(const ValueKey('skips-save')));
    await tester.tap(find.byKey(const ValueKey('skips-save')));
    await tester.pumpAndSettle();
    expect(t.hub.ticketSkips, {
      'screens': [
        {
          'device': 'bar1',
          'stations': ['sushi', 'bar'], // in the order the menu lists its stations
        },
      ],
    });
    expect(rowLine(tester), 'bar1: no ticket at Sushi Bar, Bar');
  });

  testWidgets('a screen left with no station drops off the list when it is saved', (tester) async {
    final t = await pumpSettings(
      tester,
      before: (hub) => hub.ticketSkips = {
        'screens': [
          {
            'device': 'bar1',
            'stations': ['bar'],
          },
        ],
      },
    );
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('skips:bar1:bar')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('skips-save')));
    await tester.pumpAndSettle();
    expect(jsonEncode(t.hub.ticketSkips), '{"screens":[]}');
    expect(rowLine(tester), 'Every screen prints at every station');
  });

  testWidgets('a screen the hub has not heard from is typed, by its device name', (tester) async {
    final t = await pumpSettings(tester);
    await open(tester);
    expect(find.byKey(const ValueKey('skips-typed')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('skips-add-other')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const ValueKey('skips-typed')), 'bar 2');
    await tester.tap(find.byKey(const ValueKey('skips-typed-add')));
    await tester.pumpAndSettle();
    expect(find.text('A device name is letters and digits, as its Settings show it'), findsOneWidget);
    expect(find.byKey(const ValueKey('skips-screen:bar 2')), findsNothing);

    await tester.enterText(find.byKey(const ValueKey('skips-typed')), 'bar2');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('skips-screen:bar2')), findsOneWidget);
    expect(find.byKey(const ValueKey('skips-message')), findsNothing);
    expect(find.byKey(const ValueKey('skips-typed')), findsNothing);

    // the same screen is not listed twice, whatever the case it is typed in
    await tester.tap(find.byKey(const ValueKey('skips-add-other')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('skips-typed')), 'BAR2');
    await tester.tap(find.byKey(const ValueKey('skips-typed-add')));
    await tester.pumpAndSettle();
    expect(find.text('BAR2 is already listed'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('skips:bar2:bar')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('skips-save')));
    await tester.tap(find.byKey(const ValueKey('skips-save')));
    await tester.pumpAndSettle();
    expect(t.hub.ticketSkips, {
      'screens': [
        {
          'device': 'bar2',
          'stations': ['bar'],
        },
      ],
    });
  });

  testWidgets('what the hub refuses is said in the dialog, and Cancel keeps the list as it was', (tester) async {
    final t = await pumpSettings(tester, before: (hub) => hub.refuseTicketSkips = 'the screen bar1 is listed twice');
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('skips-add:bar1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('skips:bar1:bar')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('skips-save')));
    await tester.pumpAndSettle();
    expect(find.byType(TicketSkipsDialog), findsOneWidget);
    expect(find.text('the screen bar1 is listed twice'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(TicketSkipsDialog), findsNothing);
    expect(rowLine(tester), 'Every screen prints at every station');
    expect(jsonEncode(t.hub.ticketSkips), '{"screens":[]}');
  });

  testWidgets('on a phone the stations wrap as buttons and nothing runs off the screen', (tester) async {
    await pumpSettings(
      tester,
      size: const Size(360, 720),
      before: (hub) => hub.ticketSkips = {
        'screens': [
          {
            'device': 'bar1',
            'stations': ['bar'],
          },
        ],
      },
    );
    await open(tester);
    expect(tester.takeException(), isNull);
    final dialog = tester.getRect(find.byType(AlertDialog));
    for (final code in ['wok1', 'sushi', 'bar', 'takeout']) {
      final rect = tester.getRect(find.byKey(ValueKey('skips:bar1:$code')));
      expect(rect.left >= dialog.left && rect.right <= dialog.right, isTrue, reason: code);
    }
  });

  testWidgets('a hub older than this shows no row for it', (tester) async {
    await pumpSettings(tester, before: (hub) => hub.ticketSkips = null);
    await show(tester, find.byKey(const ValueKey('printers')));
    expect(find.byKey(const ValueKey('ticket-skips')), findsNothing);
    expect(find.text('Screens that skip a station'), findsNothing);
  });
}
