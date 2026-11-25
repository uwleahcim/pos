import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/printers.dart';
import 'package:pos_app/screens/location_settings_screen.dart';

import 'hub.dart';
import 'location_rows.dart';

/// What the kitchen tickets of one send say about each other (the Toast comparison, 2026-11-15): "Ticket 2
/// of 3" and "Also at: Wok 2, Sushi Bar"; and PAID or NOT PAID on a to-go order's takeout ticket. The hub
/// prints them; a manager turns any of them off under Location settings, on the printers' card.

/// Scrolls the settings down to [finder]: the cards low on the screen are built only once they come near.
Future<void> show(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(finder, 200, scrollable: find.byType(Scrollable).first);
  await tester.pumpAndSettle();
}

void main() {
  test('the setting is a switch for each line, on unless the hub says otherwise', () {
    expect(TicketWords.fromJson(const {}), const TicketWords());
    final words = TicketWords.fromJson(const {'numbered': false, 'also_at': true});
    expect((words.numbered, words.alsoAt, words.paid), (false, true, null));
    // a hub that says nothing of PAID / NOT PAID hears nothing of it back
    expect(words.copyWith(alsoAt: false).toJson(), {'numbered': false, 'also_at': false});
    expect(words == const TicketWords(numbered: false), isTrue);

    final newer = TicketWords.fromJson(const {'numbered': true, 'also_at': true, 'paid': true});
    expect(newer.paid, isTrue);
    expect(newer.copyWith(paid: false).toJson(), {'numbered': true, 'also_at': true, 'paid': false});
    expect(newer.copyWith(numbered: false).paid, isTrue);
    expect(newer == const TicketWords(), isFalse);

    // and the same for the MOVED slip: kept and said back only when the hub has it
    expect(newer.moved, isNull);
    final newest = TicketWords.fromJson(const {'numbered': true, 'also_at': true, 'paid': true, 'moved': true});
    expect(newest.copyWith(moved: false).toJson(), {'numbered': true, 'also_at': true, 'paid': true, 'moved': false});
    expect(newest.copyWith(paid: false).moved, isTrue);
    expect(newest == newer, isFalse);
  });

  testWidgets('a manager flips the lines under the printers, and Save keeps them', (tester) async {
    final t = await terminal(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: LocationSettingsScreen(api: t.api, token: 'tok-admin', device: 't1'),
      ),
    );
    await tester.pumpAndSettle();
    final numbered = find.byKey(const ValueKey('tickets-numbered'));
    final alsoAt = find.byKey(const ValueKey('tickets-also-at'));
    await show(tester, numbered); // at the top of the screen, the other one under it
    expect(tester.widget<SwitchListTile>(numbered).value, isTrue);
    expect(tester.widget<SwitchListTile>(alsoAt).value, isTrue);
    expect(find.text('"Ticket 2 of 3", when more than one station is cooking'), findsOneWidget);

    // a flip waits for Save, like every setting of the screen: nothing is sent, and the bar says what waits
    await tester.tap(numbered);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(numbered).value, isFalse);
    expect(t.hub.ticketWords, {'numbered': true, 'also_at': true, 'paid': true, 'moved': true});
    expect(t.hub.ticketWordsAuth, isNull);
    expect(saveWaiting(tester), 'Not saved: tickets');
    await saveLocation(tester);
    expect(t.hub.ticketWords, {'numbered': false, 'also_at': true, 'paid': true, 'moved': true});
    expect(t.hub.ticketWordsAuth, 'Bearer tok-admin');
    expect(tester.widget<SwitchListTile>(numbered).value, isFalse);
    expect(find.text('Tickets saved'), findsOneWidget);
    expect(saveWaiting(tester), isNull);

    // the rest in one go: the other stations, PAID or NOT PAID on the takeout station's ticket, and the MOVED
    // slip for the stations cooking for a table that changes tables
    await tester.tap(alsoAt);
    await tester.pumpAndSettle();
    final paid = find.byKey(const ValueKey('tickets-paid'));
    await show(tester, paid);
    expect(tester.widget<SwitchListTile>(paid).value, isTrue);
    expect(find.text('Print PAID or NOT PAID on to-go orders'), findsOneWidget);
    await tester.tap(paid);
    await tester.pumpAndSettle();
    final moved = find.byKey(const ValueKey('tickets-moved'));
    await show(tester, moved);
    expect(tester.widget<SwitchListTile>(moved).value, isTrue);
    expect(find.text('Tell the kitchen when a table moves'), findsOneWidget);
    await tester.tap(moved);
    await tester.pumpAndSettle();
    expect(t.hub.ticketWords, {'numbered': false, 'also_at': true, 'paid': true, 'moved': true});
    await saveLocation(tester);
    expect(t.hub.ticketWords, {'numbered': false, 'also_at': false, 'paid': false, 'moved': false});
    expect(tester.widget<SwitchListTile>(paid).value, isFalse);
    expect(tester.widget<SwitchListTile>(moved).value, isFalse);
    await show(tester, numbered);

    // what the hub refuses is said in its words by the bar, and the flip keeps waiting to be tried again
    t.hub.refuseTicketWords = 'numbered must be true or false';
    await tester.tap(numbered);
    await tester.pumpAndSettle();
    await saveLocation(tester);
    expect(saveProblem(tester), 'Tickets: numbered must be true or false');
    expect(saveWaiting(tester), 'Not saved: tickets');
    expect(tester.widget<SwitchListTile>(numbered).value, isTrue);
    expect(t.hub.ticketWords!['numbered'], isFalse);
    // flipped back to what the hub has, nothing waits and the refusal goes with the bar
    await tester.tap(numbered);
    await tester.pumpAndSettle();
    expect(saveWaiting(tester), isNull);
    await stop(tester);
  });

  testWidgets('a hub older than the two lines shows no switch for them', (tester) async {
    final t = await terminal(tester);
    t.hub.ticketWords = null;
    await tester.pumpWidget(
      MaterialApp(
        home: LocationSettingsScreen(api: t.api, token: 'tok-admin', device: 't1'),
      ),
    );
    await tester.pumpAndSettle();
    await show(tester, find.byKey(const ValueKey('printers'))); // the switches would be on its card
    expect(find.byKey(const ValueKey('printers')), findsOneWidget);
    expect(find.byKey(const ValueKey('tickets-numbered')), findsNothing);
    expect(find.byKey(const ValueKey('tickets-also-at')), findsNothing);
    expect(find.byKey(const ValueKey('tickets-paid')), findsNothing);
    expect(find.byKey(const ValueKey('tickets-moved')), findsNothing);
    await stop(tester);
  });

  testWidgets('a hub older than PAID / NOT PAID shows the two it has, and saving them says nothing of it', (
    tester,
  ) async {
    final t = await terminal(tester);
    t.hub.ticketWords = {'numbered': true, 'also_at': true};
    await tester.pumpWidget(
      MaterialApp(
        home: LocationSettingsScreen(api: t.api, token: 'tok-admin', device: 't1'),
      ),
    );
    await tester.pumpAndSettle();
    final alsoAt = find.byKey(const ValueKey('tickets-also-at'));
    await show(tester, alsoAt);
    expect(find.byKey(const ValueKey('tickets-paid')), findsNothing);
    expect(find.byKey(const ValueKey('tickets-moved')), findsNothing);
    await tester.tap(alsoAt);
    await tester.pumpAndSettle();
    await saveLocation(tester);
    expect(t.hub.ticketWords, {'numbered': true, 'also_at': false});
    await stop(tester);
  });

  testWidgets('a hub older than the MOVED slip shows the three it has, and saving them says nothing of it', (
    tester,
  ) async {
    final t = await terminal(tester);
    t.hub.ticketWords = {'numbered': true, 'also_at': true, 'paid': true};
    await tester.pumpWidget(
      MaterialApp(
        home: LocationSettingsScreen(api: t.api, token: 'tok-admin', device: 't1'),
      ),
    );
    await tester.pumpAndSettle();
    final paid = find.byKey(const ValueKey('tickets-paid'));
    await show(tester, paid);
    expect(find.byKey(const ValueKey('tickets-moved')), findsNothing);
    await tester.tap(paid);
    await tester.pumpAndSettle();
    await saveLocation(tester);
    expect(t.hub.ticketWords, {'numbered': true, 'also_at': true, 'paid': false});
    await stop(tester);
  });

  testWidgets('the switches fit a phone', (tester) async {
    final t = await terminal(tester);
    tester.view.physicalSize = const Size(390, 844);
    await tester.pumpWidget(
      MaterialApp(
        home: LocationSettingsScreen(api: t.api, token: 'tok-admin', device: 't1'),
      ),
    );
    await tester.pumpAndSettle();
    await show(tester, find.byKey(const ValueKey('tickets-also-at')));
    expect(tester.takeException(), isNull);
    expect(find.text('Name the other stations on each ticket'), findsOneWidget);
    await show(tester, find.byKey(const ValueKey('tickets-paid')));
    expect(tester.takeException(), isNull);
    expect(find.text("On the takeout station's ticket, with what is still to collect"), findsOneWidget);
    await show(tester, find.byKey(const ValueKey('tickets-moved')));
    expect(tester.takeException(), isNull);
    expect(find.text('A MOVED slip at each station still cooking for it, with the new table'), findsOneWidget);
    await stop(tester);
  });
}
