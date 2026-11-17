import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/camera.dart';
import 'package:pos_app/desk_phone_watcher.dart';
import 'package:pos_app/main.dart';
import 'package:pos_app/phone.dart';
import 'package:pos_app/print_relay.dart';
import 'package:pos_app/screens/floor_view.dart';
import 'package:pos_app/screens/order_screen.dart';
import 'package:pos_app/screens/orders_screen.dart';
import 'package:pos_app/screens/settings_screen.dart';
import 'package:pos_app/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'hub.dart';
import 'phone_test.dart' show FakeStack;

/// The opening screen per device: a device says what whoever signs in on it sees first, the floor map (how
/// every device starts: a host stand, a server station) or the list of checks, where the to-go orders are
/// by stage (the counter). The button in the bar still switches between the two.

Map<String, dynamic> person(String id, String name) => {
  'staff_id': id,
  'name': name,
  'role': 'server',
  'method': 'pin',
  'preferences': {'text_scale': 1.0, 'high_contrast': false, 'locale': 'en'},
};

Map<String, dynamic> toGo() => {
  'order_id': 'o9',
  'status': 'open',
  'fields': {'order_type': 'takeout', 'order_no': 7, 'customer_name': 'Linda', 'channel': 'counter', 'stage': 'new'},
  'lines': {'L1': line('Egg roll', course: '2')},
  'fired': <String, dynamic>{},
};

/// The orders screen as it comes up, with nothing tapped, on a device that opens on [opensOn].
Future<Terminal> pumpDevice(WidgetTester tester, {String? opensOn}) async {
  final t = await terminal(tester);
  if (opensOn != null) await t.settings.saveOpensOn(opensOn);
  t.hub.orders.add(toGo());
  await tester.pumpWidget(
    MaterialApp(
      home: OrdersScreen(
        api: t.api,
        outbox: t.outbox,
        settings: t.settings,
        session: t.session,
        camera: NoCamera(),
        photos: t.photos,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return t;
}

/// The floor map is up: its tables, and the bar's button offers the list.
void expectFloor() {
  expect(find.byType(FloorView), findsOneWidget);
  expect(find.byTooltip('List of checks'), findsOneWidget);
  expect(find.byKey(const ValueKey('orders-list')), findsNothing);
}

/// The list of checks is up, the to-go order in it and its stages above: the bar's button offers the map.
void expectList() {
  expect(find.byType(FloorView), findsNothing);
  expect(find.byTooltip('Floor map'), findsOneWidget);
  expect(find.byKey(const ValueKey('orders-list')), findsOneWidget);
  expect(find.byKey(const ValueKey('to-go-chips')), findsOneWidget);
  expect(find.textContaining('Linda'), findsWidgets);
}

void main() {
  group('the device\'s choice', () {
    test('is the floor map to start, and is kept on the device', () async {
      SharedPreferences.setMockInitialValues({});
      final loaded = await Settings.load();
      expect((loaded.opensOn, loaded.opensOnFloor), (Settings.floorMap, true));
      final prefs = await SharedPreferences.getInstance();
      final settings = Settings(device: 't1', endpoints: const ['http://hub:8000'], prefs: prefs);
      var told = 0;
      settings.addListener(() => told += 1);
      await settings.saveOpensOn(Settings.listOfChecks);
      expect((settings.opensOnFloor, prefs.getString('opens_on'), told), (false, 'checks', 1));
      expect((await Settings.load()).opensOn, Settings.listOfChecks);
      await settings.saveOpensOn(Settings.floorMap);
      expect((settings.opensOnFloor, prefs.containsKey('opens_on')), (true, false));
    });

    test('is the floor map for anything a device does not know', () async {
      expect(Settings.cleanOpensOn(null), Settings.floorMap);
      expect(Settings.cleanOpensOn('kitchen'), Settings.floorMap);
      expect(Settings.cleanOpensOn('checks'), Settings.listOfChecks);
      expect(Settings(device: 't1', endpoints: const [], opensOn: 'kitchen').opensOnFloor, isTrue);
      SharedPreferences.setMockInitialValues({'opens_on': 'a screen of a later version'});
      expect((await Settings.load()).opensOnFloor, isTrue);
    });

    testWidgets('is on the device\'s settings screen as two buttons, kept with Save', (tester) async {
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
      expect(find.text('This screen opens on'), findsOneWidget);
      ChoiceChip chip(String value) => tester.widget<ChoiceChip>(find.byKey(ValueKey('opens-on:$value')));
      expect((chip('floor').selected, chip('checks').selected), (true, false));
      expect(find.widgetWithText(ChoiceChip, 'Floor map'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, 'List of checks'), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('opens-on-line'))).data,
        contains('starts on the floor map'),
      );

      await tester.tap(find.byKey(const ValueKey('opens-on:checks')));
      await tester.pump();
      expect((chip('floor').selected, chip('checks').selected), (false, true));
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('opens-on-line'))).data,
        contains('starts on the list of checks'),
      );
      expect(settings.opensOnFloor, isTrue); // not until Save
      await tester.ensureVisible(find.text('Save'));
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect((settings.opensOn, prefs.getString('opens_on')), ('checks', 'checks'));
    });
  });

  group('the orders screen', () {
    testWidgets('opens on the floor map on a device that was never told', (tester) async {
      await pumpDevice(tester);
      expectFloor();
      await stop(tester);
    });

    testWidgets('opens on the list of checks, with the to-go orders, on a device set so', (tester) async {
      await pumpDevice(tester, opensOn: Settings.listOfChecks);
      expectList();
      await stop(tester);
    });

    testWidgets('still goes to the other one with the button in the bar, and stays there', (tester) async {
      final t = await pumpDevice(tester, opensOn: Settings.listOfChecks);
      await tester.tap(find.byTooltip('Floor map'));
      await tester.pumpAndSettle();
      expectFloor();
      // what the hub, the session and the device tell of other things moves nothing
      await t.settings.saveLockMinutes(5);
      t.session.applySignIn(person('s3', 'Mike'));
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expectFloor();
      await tester.tap(find.byTooltip('List of checks'));
      await tester.pumpAndSettle();
      expectList();
      await stop(tester);
    });

    testWidgets('shows the device\'s new choice as soon as it is saved', (tester) async {
      final t = await pumpDevice(tester);
      expectFloor();
      await t.settings.saveOpensOn(Settings.listOfChecks);
      await tester.pumpAndSettle();
      expectList();
      await t.settings.saveOpensOn(Settings.floorMap);
      await tester.pumpAndSettle();
      expectFloor();
      await stop(tester);
    });

    testWidgets('goes back to the device\'s choice when another person takes the screen over', (tester) async {
      final t = await pumpDevice(tester, opensOn: Settings.listOfChecks);
      await tester.tap(find.byTooltip('Floor map')); // Mike looks at the tables
      await tester.pumpAndSettle();
      expectFloor();
      t.session.applySignIn(person('s1', 'Amy')); // a hands-free switch: Amy is at the screen now
      await tester.pumpAndSettle();
      expectList();
      await stop(tester);
    });

    testWidgets('is as it was left for the person who comes back to a locked screen', (tester) async {
      final t = await pumpDevice(tester, opensOn: Settings.listOfChecks);
      await tester.tap(find.byTooltip('Floor map'));
      await tester.pumpAndSettle();
      t.session.lock();
      await tester.pumpAndSettle();
      expectFloor(); // a lock by itself moves nothing under the pad
      t.session.applySignIn(person('s3', 'Mike'));
      await tester.pumpAndSettle();
      expectFloor();

      t.session.lock();
      await tester.pumpAndSettle();
      t.session.applySignIn(person('s2', 'Ben')); // somebody else unlocks it
      await tester.pumpAndSettle();
      expectList();
      await stop(tester);
    });
  });

  group('the whole app', () {
    testWidgets('each sign-in starts on the device\'s screen, whatever the last person looked at', (tester) async {
      final t = await terminal(tester);
      t.session.signOut();
      await t.settings.saveOpensOn(Settings.listOfChecks);
      t.hub.orders.add(toGo());
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
      expectList();

      // a check opened from the list and left again: back on the list
      await tester.tap(find.textContaining('Linda').first);
      await tester.pumpAndSettle();
      expect(find.byType(OrderScreen), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expectList();

      await tester.tap(find.byTooltip('Floor map'));
      await tester.pumpAndSettle();
      expectFloor();
      t.session.signOut();
      await tester.pumpAndSettle();
      expect(find.text('Sign in · t1'), findsOneWidget);
      await pin('1111');
      expectList();
      await stop(tester);
    });
  });
}
