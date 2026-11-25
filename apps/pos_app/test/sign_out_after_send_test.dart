import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/camera.dart';
import 'package:pos_app/desk_phone_watcher.dart';
import 'package:pos_app/main.dart';
import 'package:pos_app/phone.dart';
import 'package:pos_app/print_relay.dart';
import 'package:pos_app/screens/order_screen.dart';
import 'package:pos_app/screens/settings_screen.dart';
import 'package:pos_app/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'hub.dart';
import 'phone_test.dart' show FakeStack;

/// Back to sign-in after sending: on a device set so (a screen several people share), leaving a check that
/// dishes were just sent from signs the person out, so the next one signs in. Off is how a device starts,
/// and then leaving a check goes back to the tables, still signed in.

/// A to-go order with nothing due: its screen offers Send, which sends everything and leaves.
Map<String, dynamic> toGo() => {
  'order_id': 'o1',
  'status': 'open',
  'fields': {'order_type': 'takeout', 'order_no': 7, 'customer_name': 'Linda', 'channel': 'counter', 'stage': 'new'},
  'lines': {'L1': line('Egg roll', course: '2')},
  'fired': <String, dynamic>{},
};

const nothingDue = {
  'lines': [
    {'line_id': 'L1', 'name': 'Egg roll', 'qty': 1, 'total': '0.00'},
  ],
  'subtotal': '0.00',
  'tax_lines': <Map<String, dynamic>>[],
  'tax': '0.00',
  'total': '0.00',
  'paid': '0.00',
  'due': '0.00',
};

/// The tables (a stand-in), with the order's screen opened from it as the app opens it.
Future<Terminal> pumpFromTables(WidgetTester tester, Map<String, dynamic> order, {required bool signsOut}) async {
  final t = await terminal(tester);
  await t.settings.saveSignOutAfterSend(signsOut);
  t.hub.orders.add(order);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => OrderScreen(
                    api: t.api,
                    outbox: t.outbox,
                    photos: t.photos,
                    orderId: order['order_id'] as String,
                    session: t.session,
                  ),
                ),
              ),
              child: const Text('the tables'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('the tables'));
  await tester.pumpAndSettle();
  expect(find.byType(OrderScreen), findsOneWidget);
  return t;
}

Map<String, dynamic> twoCourses() =>
    table('o1', {'L1': line('Egg roll', course: '1'), 'L2': line('Duck', course: '2')});

List<String> kinds(Terminal t) => [for (final op in t.hub.opsFor('o1')) op['kind'] as String];

void main() {
  group('the device\'s switch', () {
    test('is off to start and kept on the device', () async {
      SharedPreferences.setMockInitialValues({});
      expect((await Settings.load()).signOutAfterSend, isFalse);
      final prefs = await SharedPreferences.getInstance();
      final settings = Settings(device: 't1', endpoints: const ['http://hub:8000'], prefs: prefs);
      var told = 0;
      settings.addListener(() => told += 1);
      await settings.saveSignOutAfterSend(true);
      expect((settings.signOutAfterSend, prefs.getBool('sign_out_after_send'), told), (true, true, 1));
      expect((await Settings.load()).signOutAfterSend, isTrue);
      await settings.saveSignOutAfterSend(false);
      expect((settings.signOutAfterSend, prefs.containsKey('sign_out_after_send')), (false, false));
    });

    testWidgets('is on the device\'s settings screen, kept with Save', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final settings = Settings(device: 't1', endpoints: ['http://hub:8000'], prefs: prefs);
      tester.view
        ..physicalSize = wholeSettings
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () =>
                    Navigator.of(context)
                        .push(MaterialPageRoute<void>(builder: (_) => SettingsScreen(settings: settings))),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      final tile = find.byKey(const ValueKey('sign-out-after-send'));
      expect(find.text('Back to sign-in after sending'), findsOneWidget);
      expect(tester.widget<SwitchListTile>(tile).value, isFalse);
      expect(find.textContaining('still signed in'), findsOneWidget);
      await tester.tap(tile);
      await tester.pump();
      expect(tester.widget<SwitchListTile>(tile).value, isTrue);
      expect(find.textContaining('leaving that check signs out'), findsOneWidget);
      expect(settings.signOutAfterSend, isFalse); // not until Save
      await tester.pumpAndSettle(); // the Save bar comes up with the change
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect((settings.signOutAfterSend, prefs.getBool('sign_out_after_send')), (true, true));
    });
  });

  group('with the switch off', () {
    testWidgets('sending and leaving goes back to the tables, still signed in', (tester) async {
      final t = await pumpFromTables(tester, twoCourses(), signsOut: false);
      await tester.tap(find.byTooltip('Fire'));
      await tester.pumpAndSettle();
      expect(find.text('Fire everything and leave'), findsOneWidget);
      expect(find.text('Fire everything and sign out'), findsNothing);
      await tester.tap(find.text('Fire everything and leave'));
      await tester.pumpAndSettle();
      expect(kinds(t), ['fire']);
      expect(find.byType(OrderScreen), findsNothing);
      expect(find.text('the tables'), findsOneWidget);
      expect(t.session.signedIn, isTrue);
    });
  });

  group('with the switch on', () {
    testWidgets('sending and leaving says it signs out, and does', (tester) async {
      final t = await pumpFromTables(tester, twoCourses(), signsOut: true);
      await tester.tap(find.byTooltip('Fire'));
      await tester.pumpAndSettle();
      expect(find.text('Fire everything and leave'), findsNothing);
      await tester.tap(find.text('Fire everything and sign out'));
      await tester.pumpAndSettle();
      expect(t.hub.opsFor('o1').single['data'], {'course': '*'});
      expect(find.byType(OrderScreen), findsNothing);
      expect(t.session.signedIn, isFalse);
    });

    testWidgets('a course sent stays on the check, signed in; leaving the check afterwards signs out', (tester) async {
      final t = await pumpFromTables(tester, twoCourses(), signsOut: true);
      await tester.tap(find.byTooltip('Fire'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Fire Appetizers'));
      await tester.pumpAndSettle();
      expect(t.hub.opsFor('o1').single['data'], {'course': '1'});
      expect(find.byType(OrderScreen), findsOneWidget); // staying for the next round is still staying
      expect(t.session.signedIn, isTrue);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(OrderScreen), findsNothing);
      expect(t.session.signedIn, isFalse);
    });

    testWidgets('a check that was only looked at is left signed in', (tester) async {
      final t = await pumpFromTables(tester, twoCourses(), signsOut: true);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('the tables'), findsOneWidget);
      expect(kinds(t), isEmpty);
      expect(t.session.signedIn, isTrue);
    });

    testWidgets('a dish rung in and not sent leaves the person signed in', (tester) async {
      final t = await pumpFromTables(tester, twoCourses(), signsOut: true);
      await tester.tap(find.byKey(const ValueKey('s:dinner/apps')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('e:dinner:1:EGGROLL')));
      await tester.pumpAndSettle();
      expect(kinds(t), ['add_line']);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(t.session.signedIn, isTrue);
    });

    testWidgets('a to-go order sent from the counter signs out', (tester) async {
      final t = await terminal(tester);
      t.hub.check = nothingDue;
      await t.settings.saveSignOutAfterSend(true);
      t.hub.orders.add(toGo());
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        OrderScreen(api: t.api, outbox: t.outbox, photos: t.photos, orderId: 'o1', session: t.session),
                  ),
                ),
                child: const Text('the orders'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('the orders'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Send'));
      await tester.pumpAndSettle();
      expect(kinds(t), contains('fire'));
      expect(find.byType(OrderScreen), findsNothing);
      expect(t.session.signedIn, isFalse);
    });
  });

  group('the whole app', () {
    testWidgets('after a send the screen is the sign-in pad, and the next person signs in', (tester) async {
      final t = await terminal(tester);
      t.session.signOut();
      await t.settings.saveSignOutAfterSend(true);
      t.hub.orders.add(table('o1', {'L1': line('Egg roll', course: '1')}));
      await tester.pumpWidget(
        PosApp(
          settings: t.settings,
          api: t.api,
          outbox: t.outbox,
          session: t.session,
          camera: NoCamera(),
          photos: t.photos,
          relay: PrintRelay(t.api, t.settings),
          phone: PhoneClient(FakeStack()),
          deskPhones: DeskPhoneWatcher(t.api, t.settings),
        ),
      );
      await tester.pumpAndSettle();
      Future<void> pin(String digits) async {
        for (final digit in digits.split('')) {
          await tester.tap(find.widgetWithText(FilledButton, digit));
          await tester.pump();
        }
        await tester.pumpAndSettle();
      }

      await pin('1111');
      expect(t.session.staff?.name, 'Amy');
      await tester.tap(find.text('A7')); // her table on the floor map: the check o1
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Fire'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Fire everything and sign out'));
      await tester.pumpAndSettle();
      expect(kinds(t), ['fire']);
      expect(t.session.signedIn, isFalse);
      expect(find.text('Sign in · t1'), findsOneWidget);
      expect(find.byType(OrderScreen), findsNothing);

      await pin('1111');
      expect(t.session.staff?.name, 'Amy');
      expect(find.byType(OrderScreen), findsNothing); // on the tables, not back in the check
      expect(find.text('A7'), findsOneWidget);
      await stop(tester);
    });
  });
}
