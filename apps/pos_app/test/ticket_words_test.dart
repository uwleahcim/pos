import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/printers.dart';
import 'package:pos_app/screens/location_settings_screen.dart';

import 'hub.dart';

/// What the kitchen tickets of one send say about each other (the Toast comparison, 2026-11-15): "Ticket 2
/// of 3" and "Also at: Wok 2, Sushi Bar". The hub prints them; a manager turns either off under Location
/// settings, on the printers' card.

/// Scrolls the settings down to [finder]: the cards low on the screen are built only once they come near.
Future<void> show(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(finder, 200, scrollable: find.byType(Scrollable).first);
  await tester.pumpAndSettle();
}

void main() {
  test('the setting is two switches, both on unless the hub says otherwise', () {
    expect(TicketWords.fromJson(const {}), const TicketWords());
    final words = TicketWords.fromJson(const {'numbered': false, 'also_at': true});
    expect((words.numbered, words.alsoAt), (false, true));
    expect(words.copyWith(alsoAt: false).toJson(), {'numbered': false, 'also_at': false});
    expect(words == const TicketWords(numbered: false), isTrue);
  });

  testWidgets('a manager flips either line under the printers, and it is saved at once', (tester) async {
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

    await tester.tap(numbered);
    await tester.pumpAndSettle();
    expect(t.hub.ticketWords, {'numbered': false, 'also_at': true});
    expect(t.hub.ticketWordsAuth, 'Bearer tok-admin');
    expect(tester.widget<SwitchListTile>(numbered).value, isFalse);

    await tester.tap(alsoAt);
    await tester.pumpAndSettle();
    expect(t.hub.ticketWords, {'numbered': false, 'also_at': false});

    // what the hub refuses is said in its words, and the switch stays where the hub has it
    t.hub.refuseTicketWords = 'numbered must be true or false';
    await tester.tap(numbered);
    await tester.pumpAndSettle();
    expect(find.text('numbered must be true or false'), findsOneWidget);
    expect(tester.widget<SwitchListTile>(numbered).value, isFalse);
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
    await stop(tester);
  });

  testWidgets('the two switches fit a phone', (tester) async {
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
    await stop(tester);
  });
}
