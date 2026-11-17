import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/camera.dart';
import 'package:pos_app/desk_phone_watcher.dart';
import 'package:pos_app/face_signin.dart';
import 'package:pos_app/idle_lock.dart';
import 'package:pos_app/main.dart';
import 'package:pos_app/phone.dart';
import 'package:pos_app/print_relay.dart';
import 'package:pos_app/screens/lock_layer.dart';
import 'package:pos_app/screens/order_screen.dart';
import 'package:pos_app/screens/settings_screen.dart';
import 'package:pos_app/screens/signin_screen.dart';
import 'package:pos_app/session.dart';
import 'package:pos_app/settings.dart';
import 'package:pos_app/switching.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'hub.dart';
import 'phone_test.dart' show FakeStack;

/// Lock an idle screen: a device given minutes (off to start) locks itself when nobody has touched it for
/// that long. The sign-in pad comes over what was open and nothing is closed: the person who was there
/// finds it as they left it, and anybody else carries on with the open order, as in a hands-free switch.

const minute = Duration.millisecondsPerMinute;

Map<String, dynamic> person(String id, String name, String method, {String role = 'server'}) => {
  'staff_id': id,
  'name': name,
  'role': role,
  'method': method,
  'preferences': {'text_scale': 1.0, 'high_contrast': false, 'locale': 'en'},
};

final amy = person('s1', 'Amy', 'pin');
final ben = person('s2', 'Ben', 'pin');

/// A device with its session, a clock the test moves, and the idle lock on it.
class Desk {
  Desk({int minutes = 0}) : settings = Settings(device: 't1', endpoints: ['http://hub:8000'], lockMinutes: minutes) {
    session = Session(PosApi(settings, client: MockClient(hub.handle)));
    lock = IdleLock(settings, session, now: () => now);
  }

  final hub = Hub();
  final Settings settings;
  late final Session session;
  late final IdleLock lock;
  int now = 1_800_000_000_000;

  /// Time passes with nobody at the screen: the test's clock and the lock's own look at it.
  Future<void> wait(WidgetTester tester, Duration time) async {
    now += time.inMilliseconds;
    await tester.pump(time);
  }
}

/// The app as far as the lock goes: every touch told to the lock, the pad over the screens while locked,
/// and what a change of person closes.
Future<GlobalKey<NavigatorState>> pumpApp(WidgetTester tester, Desk desk, {Widget? home, bool realPad = false}) async {
  final navigator = GlobalKey<NavigatorState>();
  final messenger = GlobalKey<ScaffoldMessengerState>();
  final watcher = SessionWatcher(desk.session, navigator: navigator, messenger: messenger);
  addTearDown(watcher.dispose);
  desk.lock.start();
  addTearDown(desk.lock.dispose);
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: navigator,
      scaffoldMessengerKey: messenger,
      builder: (context, child) => Touches(
        lock: desk.lock,
        child: LockLayer(
          session: desk.session,
          pad: (context) => realPad
              ? SignInScreen(
                  session: desk.session,
                  settings: desk.settings,
                  camera: NoCamera(),
                  lockedNote: lockedNote(desk.settings.lockMinutes, desk.session.lockedFrom?.name ?? ''),
                )
              : const Scaffold(body: Center(child: Text('the pad'))),
          child: child!,
        ),
      ),
      home: home ?? const Scaffold(body: Text('home')),
    ),
  );
  return navigator;
}

void push(GlobalKey<NavigatorState> navigator, String text, {bool order = false}) => navigator.currentState!.push(
  MaterialPageRoute<void>(
    settings: order ? const RouteSettings(name: SessionWatcher.orderRoute) : null,
    builder: (_) => Scaffold(body: Text(text)),
  ),
);

void main() {
  group('the session', () {
    test('a lock signs nobody in and remembers who was there; a sign-in or a sign-out ends it', () {
      final session = Desk().session;
      session.lock(); // nobody is signed in: nothing to lock
      expect((session.locked, session.signedIn), (false, false));

      session.applySignIn(amy);
      var told = 0;
      session.addListener(() => told += 1);
      session.lock();
      expect((session.locked, session.signedIn, session.lockedFrom?.name, told), (true, false, 'Amy', 1));
      session.lock(); // locked already
      expect((session.lockedFrom?.name, told), ('Amy', 1));

      session.applySignIn(ben);
      expect((session.locked, session.staff?.name), (false, 'Ben'));
      session.lock();
      session.signOut();
      expect((session.locked, session.signedIn), (false, false));
    });
  });

  group('the device\'s minutes', () {
    test('start at never, are kept on the device, and stay within a day\'s work', () async {
      SharedPreferences.setMockInitialValues({});
      expect((await Settings.load()).lockMinutes, 0);
      final prefs = await SharedPreferences.getInstance();
      final settings = Settings(device: 't1', endpoints: const ['http://hub:8000'], prefs: prefs);
      var told = 0;
      settings.addListener(() => told += 1);
      await settings.saveLockMinutes(5);
      expect((settings.lockMinutes, prefs.getInt('lock_minutes'), told), (5, 5, 1));
      expect((await Settings.load()).lockMinutes, 5);
      await settings.saveLockMinutes(0);
      expect((settings.lockMinutes, prefs.containsKey('lock_minutes')), (0, false));
      expect((Settings.cleanLockMinutes(-3), Settings.cleanLockMinutes(100000)), (0, 720));
    });

    test('the pad says why it is there', () {
      expect(lockedNote(5, 'Amy'), 'Locked after 5 minutes untouched. Amy was signed in. Nothing was closed.');
      expect(lockedNote(1, ''), 'Locked after 1 minute untouched. Nothing was closed.');
    });
  });

  group('the lock', () {
    testWidgets('a device with no minutes never locks, and looks at no clock', (tester) async {
      final desk = Desk();
      desk.lock.start();
      addTearDown(desk.lock.dispose);
      desk.session.applySignIn(amy);
      expect(desk.lock.watching, isFalse);
      await desk.wait(tester, const Duration(hours: 12));
      expect(desk.session.locked, isFalse);
    });

    testWidgets('locks after its minutes without a touch, counted from the last one', (tester) async {
      final desk = Desk(minutes: 5);
      desk.lock.start();
      addTearDown(desk.lock.dispose);
      expect(desk.lock.watching, isFalse); // nobody is signed in: nothing to lock
      await desk.wait(tester, const Duration(minutes: 30));
      desk.session.applySignIn(amy);
      expect(desk.lock.watching, isTrue);
      await desk.wait(tester, const Duration(minutes: 4));
      desk.lock.touched();
      await desk.wait(tester, const Duration(minutes: 4, seconds: 50));
      expect(desk.session.locked, isFalse); // 8:50 since the sign-in, 4:50 since the touch
      await desk.wait(tester, const Duration(seconds: 10));
      expect((desk.session.locked, desk.session.signedIn, desk.session.lockedFrom?.name), (true, false, 'Amy'));
      expect(desk.lock.watching, isFalse); // locked: nothing more to watch

      // whoever signs in next has the full minutes
      desk.session.applySignIn(ben);
      await desk.wait(tester, const Duration(minutes: 4, seconds: 55));
      expect(desk.session.locked, isFalse);
      await desk.wait(tester, const Duration(seconds: 5));
      expect(desk.session.lockedFrom?.name, 'Ben');
    });

    testWidgets('a key on the keyboard is somebody at the screen', (tester) async {
      final desk = Desk(minutes: 1);
      desk.lock.start();
      addTearDown(desk.lock.dispose);
      desk.session.applySignIn(amy);
      await desk.wait(tester, const Duration(seconds: 50));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await desk.wait(tester, const Duration(seconds: 50));
      expect(desk.session.locked, isFalse);
      await desk.wait(tester, const Duration(seconds: 10));
      expect(desk.session.locked, isTrue);
    });

    testWidgets('other minutes set on the device count from then; never stops the lock', (tester) async {
      final desk = Desk(minutes: 10);
      desk.lock.start();
      addTearDown(desk.lock.dispose);
      desk.session.applySignIn(amy);
      await desk.wait(tester, const Duration(minutes: 8));
      await desk.settings.saveLockMinutes(2);
      await desk.wait(tester, const Duration(minutes: 1, seconds: 55));
      expect(desk.session.locked, isFalse); // not at once for the eight minutes gone by
      await desk.settings.saveLockMinutes(0);
      expect(desk.lock.watching, isFalse);
      await desk.wait(tester, const Duration(hours: 1));
      expect(desk.session.locked, isFalse);
    });

    testWidgets('a device that slept through its minutes is locked the moment it is back', (tester) async {
      final desk = Desk(minutes: 5);
      desk.lock.start();
      addTearDown(desk.lock.dispose);
      desk.session.applySignIn(amy);
      desk.now += 20 * minute; // asleep: no timer ran
      desk.lock.check(); // the app is in front again
      expect(desk.session.locked, isTrue);
    });
  });

  group('over the screens', () {
    testWidgets('a touch on the screen is told to the lock, and still reaches what was touched', (tester) async {
      final desk = Desk(minutes: 1);
      var taps = 0;
      await pumpApp(
        tester,
        desk,
        home: Scaffold(
          body: Center(
            child: FilledButton(onPressed: () => taps += 1, child: const Text('ring it in')),
          ),
        ),
      );
      desk.session.applySignIn(amy);
      await desk.wait(tester, const Duration(seconds: 50));
      await tester.tap(find.text('ring it in'));
      expect(taps, 1);
      await desk.wait(tester, const Duration(seconds: 50));
      expect(desk.session.locked, isFalse);
      expect(find.text('the pad'), findsNothing);
      await desk.wait(tester, const Duration(seconds: 10));
      expect(desk.session.locked, isTrue);
      expect(find.text('the pad'), findsOneWidget);
    });

    testWidgets('the pad covers the screens, which keep what they held and take no touch or key', (tester) async {
      final desk = Desk(minutes: 1);
      var taps = 0;
      final navigator = await pumpApp(
        tester,
        desk,
        home: Scaffold(
          body: Column(
            children: [
              const TextField(key: ValueKey('note')),
              FilledButton(onPressed: () => taps += 1, child: const Text('ring it in')),
            ],
          ),
        ),
      );
      desk.session.applySignIn(amy);
      await tester.pump();
      await tester.enterText(find.byKey(const ValueKey('note')), 'no onions');
      final field = tester.state<EditableTextState>(find.byType(EditableText));
      expect(field.widget.focusNode.hasFocus, isTrue);

      desk.session.lock();
      await tester.pump();
      expect(find.text('the pad'), findsOneWidget);
      expect(field.widget.focusNode.hasFocus, isFalse); // a badge reader's typing lands nowhere
      await tester.tapAt(tester.getCenter(find.text('ring it in', skipOffstage: false)));
      expect(taps, 0);
      // a screen opened meanwhile (a call picked up on the desk phone) comes up under the pad
      push(navigator, 'the caller\'s order');
      await tester.pumpAndSettle();
      expect(find.text('the pad'), findsOneWidget);
      expect(find.text('the pad').hitTestable(), findsOneWidget);
      expect(find.text('the caller\'s order').hitTestable(), findsNothing);

      // the same person back: everything as it was
      desk.session.applySignIn(amy);
      await tester.pumpAndSettle();
      expect(find.text('the pad'), findsNothing);
      expect(find.text('the caller\'s order'), findsOneWidget);
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(find.text('no onions'), findsOneWidget); // the same field, not one built anew
      expect(tester.state<EditableTextState>(find.byType(EditableText)), same(field));
      await tester.tap(find.text('ring it in'));
      expect(taps, 1);
      desk.lock.dispose(); // signed in with minutes set: its look at the clock would outlive the test
    });

    testWidgets('the person who was there finds the order and what was open over it', (tester) async {
      final desk = Desk(minutes: 5);
      final navigator = await pumpApp(tester, desk);
      desk.session.applySignIn(amy);
      push(navigator, 'an order', order: true);
      await tester.pumpAndSettle();
      push(navigator, 'a sheet');
      await tester.pumpAndSettle();
      await desk.wait(tester, const Duration(minutes: 5));
      expect(desk.session.locked, isTrue);
      expect(find.text('the pad'), findsOneWidget);
      expect(navigator.currentState!.canPop(), isTrue); // nothing was closed

      desk.session.applySignIn(amy);
      await tester.pumpAndSettle();
      expect(find.text('the pad'), findsNothing);
      expect(find.text('a sheet'), findsOneWidget);
      expect(find.textContaining('Hi '), findsNothing);
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(find.text('an order'), findsOneWidget);
      desk.lock.dispose();
    });

    testWidgets('somebody else carries on with the open order: what was over it closes, by PIN too', (tester) async {
      final desk = Desk(minutes: 5);
      final navigator = await pumpApp(tester, desk);
      desk.session.applySignIn(amy);
      push(navigator, 'an order', order: true);
      await tester.pumpAndSettle();
      push(navigator, 'a sheet');
      await tester.pumpAndSettle();
      desk.session.lock();
      await tester.pump();

      desk.session.applySignIn(ben); // by PIN
      await tester.pumpAndSettle();
      expect(find.text('the pad'), findsNothing);
      expect(find.text('a sheet'), findsNothing);
      expect(find.text('an order'), findsOneWidget);
      expect(find.text('Hi Ben'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      desk.lock.dispose();
    });

    testWidgets('with no order open, a manager\'s screen does not pass to the next person', (tester) async {
      final desk = Desk(minutes: 5);
      final navigator = await pumpApp(tester, desk);
      desk.session.applySignIn(person('s3', 'Mike', 'pin', role: 'manager'));
      push(navigator, 'location settings');
      await tester.pumpAndSettle();
      desk.session.lock();
      await tester.pump();
      desk.session.applySignIn(amy);
      await tester.pumpAndSettle();
      expect(find.text('location settings'), findsNothing);
      expect(find.text('home'), findsOneWidget);
      expect(find.text('Hi Amy'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      desk.lock.dispose();
    });

    testWidgets('a sign-out still closes everything, locked or not', (tester) async {
      final desk = Desk(minutes: 5);
      final navigator = await pumpApp(tester, desk);
      desk.session.applySignIn(amy);
      push(navigator, 'an order', order: true);
      await tester.pumpAndSettle();
      desk.session.lock();
      await tester.pump();
      desk.session.signOut();
      await tester.pumpAndSettle();
      expect(find.text('the pad'), findsNothing);
      expect(find.text('an order'), findsNothing);
      expect(find.text('home'), findsOneWidget);
    });
  });

  group('the pad', () {
    testWidgets('says why it is there, and a PIN unlocks the screen as it was', (tester) async {
      tester.view
        ..physicalSize = const Size(1100, 800)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final desk = Desk(minutes: 5);
      final navigator = await pumpApp(tester, desk, realPad: true);
      desk.session.applySignIn(amy);
      push(navigator, 'an order', order: true);
      await tester.pumpAndSettle();
      await desk.wait(tester, const Duration(minutes: 5));
      await tester.pump();
      expect(find.text('Locked · t1'), findsOneWidget);
      expect(find.text('Locked after 5 minutes untouched. Amy was signed in. Nothing was closed.'), findsOneWidget);
      expect(find.byTooltip('Settings'), findsNothing); // the device's settings are not behind a locked screen

      for (final digit in ['2', '2', '2', '2']) {
        await tester.tap(find.widgetWithText(FilledButton, digit));
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(find.text('Wrong PIN'), findsOneWidget);
      expect(desk.session.locked, isTrue);

      for (final digit in ['1', '1', '1', '1']) {
        await tester.tap(find.widgetWithText(FilledButton, digit));
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect((desk.session.locked, desk.session.staff?.name), (false, 'Amy'));
      expect(find.text('Locked · t1'), findsNothing);
      expect(find.text('an order'), findsOneWidget);
      // and the minutes count anew from the sign-in
      await desk.wait(tester, const Duration(minutes: 4, seconds: 55));
      expect(desk.session.locked, isFalse);
      desk.lock.dispose();
    });

    testWidgets('a tag held to the reader unlocks it for whoever it belongs to', (tester) async {
      final desk = Desk(minutes: 5);
      final navigator = await pumpApp(tester, desk);
      desk.hub.tags['04AABB'] = {'staff_id': 's2', 'name': 'Ben', 'role': 'bartender'};
      final faces = FaceSignIn(desk.session.api, desk.settings, NoCamera(), desk.session);
      addTearDown(faces.dispose);
      desk.session.applySignIn(amy);
      push(navigator, 'an order', order: true);
      await tester.pumpAndSettle();
      desk.session.lock();
      await tester.pump();
      await tester.runAsync(() => faces.tag('04AABB'));
      await tester.pumpAndSettle();
      expect((desk.session.locked, desk.session.staff?.name), (false, 'Ben'));
      expect(find.text('an order'), findsOneWidget);
      expect(find.text('Hi Ben'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      desk.lock.dispose();
    });
  });

  group('the whole app', () {
    testWidgets('an idle screen locks over the open order, and the PIN brings the order back', (tester) async {
      final t = await terminal(tester);
      t.session.signOut();
      await t.settings.saveLockMinutes(5);
      t.hub.orders.add(table('o1', {'L1': line('Egg roll', course: '1')}));
      var now = 1_800_000_000_000;
      final lock = IdleLock(t.settings, t.session, now: () => now)..start();
      addTearDown(lock.dispose);
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
          idleLock: lock,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Sign in · t1'), findsOneWidget);
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
      expect(find.byType(OrderScreen), findsOneWidget);

      // four minutes, a tap on the check, then five minutes with nobody there
      now += 4 * minute;
      await tester.pump(const Duration(minutes: 4));
      await tester.tap(find.text('Egg roll'));
      await tester.pumpAndSettle();
      now += 4 * minute;
      await tester.pump(const Duration(minutes: 4));
      expect(t.session.locked, isFalse);
      now += minute;
      await tester.pump(const Duration(minutes: 1));
      await tester.pump();
      expect(t.session.locked, isTrue);
      expect(find.text('Locked · t1'), findsOneWidget);
      expect(find.byKey(const ValueKey('locked-note')), findsOneWidget);
      expect(find.byType(OrderScreen, skipOffstage: false), findsOneWidget); // still there, under the pad
      expect(find.text('Egg roll').hitTestable(), findsNothing);

      await pin('1111');
      expect((t.session.locked, t.session.staff?.name), (false, 'Amy'));
      expect(find.text('Locked · t1'), findsNothing);
      expect(find.byType(OrderScreen), findsOneWidget);
      expect(find.text('Egg roll').hitTestable(), findsWidgets);
      lock.dispose();
      await stop(tester);
    });
  });

  group('the device\'s settings', () {
    testWidgets('offer the minutes as buttons, and Save keeps the pick on the device', (tester) async {
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
      expect(find.text('Lock this screen when idle'), findsOneWidget);
      ChoiceChip chip(int minutes) => tester.widget<ChoiceChip>(find.byKey(ValueKey('lock:$minutes')));
      expect(chip(0).selected, isTrue); // never, to start
      expect(find.widgetWithText(ChoiceChip, 'Never'), findsOneWidget);
      for (final minutes in Settings.lockChoices) {
        expect(find.widgetWithText(ChoiceChip, '$minutes min'), findsOneWidget);
      }
      expect(tester.widget<Text>(find.byKey(const ValueKey('lock-line'))).data, startsWith('This screen never locks'));

      await tester.tap(find.byKey(const ValueKey('lock:5')));
      await tester.pump();
      expect((chip(5).selected, chip(0).selected), (true, false));
      expect(tester.widget<Text>(find.byKey(const ValueKey('lock-line'))).data, startsWith('After 5 minutes without'));
      expect(settings.lockMinutes, 0); // not until Save
      await tester.ensureVisible(find.text('Save'));
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect((settings.lockMinutes, prefs.getInt('lock_minutes')), (5, 5));
    });
  });
}
