import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/camera.dart';
import 'package:pos_app/desk_phone_watcher.dart';
import 'package:pos_app/kitchen_bell.dart';
import 'package:pos_app/main.dart';
import 'package:pos_app/phone.dart';
import 'package:pos_app/print_relay.dart';
import 'package:pos_app/screens/kitchen_screen.dart';
import 'package:pos_app/screens/orders_screen.dart';
import 'package:pos_app/screens/settings_screen.dart';
import 'package:pos_app/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'hub.dart';
import 'kitchen_screen_test.dart' show away, board, button, dish, evening, names, pumpScreen, row, standing, ticket;
import 'phone_test.dart' show FakeStack;

/// The sound of a kitchen screen (docs/kitchen-screens.md): a chime when a ticket comes in, and for whatever
/// else a cook has to read anew (a dish voided or changed after it was sent, an allergy told late). Never
/// for the kitchen's own taps, never for the tickets that stood there before anybody listened, and not at all
/// on a device told to keep quiet.

/// Stands in for the device's sound: counts how often it was played.
class FakeChime implements Chime {
  int plays = 0;

  @override
  Future<void> play() async => plays++;
}

void main() {
  final soup = ticket('o1', 5, [dish('a', 'Hot and Sour Soup'), dish('b', 'Fried Rice')], table: '12');
  final wings = ticket('o2', 0, [dish('a', 'Chicken Wings')], table: '7');

  group('the bell', () {
    late FakeChime chime;
    late KitchenBell bell;

    setUp(() {
      chime = FakeChime();
      bell = KitchenBell(chime);
    });

    test('the first look at a screen is silent; a ticket that comes in sounds once', () {
      expect(bell.heard('wok', board([soup])), isFalse);
      expect(chime.plays, 0);
      expect(bell.heard('wok', board([soup, wings])), isTrue);
      expect(chime.plays, 1);
      // and the same tickets, read again, are nothing new
      expect(bell.heard('wok', board([soup, wings])), isFalse);
      expect(chime.plays, 1);
    });

    test('however many tickets come in at once, it is one chime', () {
      bell.heard('wok', board(const []));
      final rush = [
        soup,
        wings,
        ticket('o3', 0, [dish('a', 'Egg Roll')]),
      ];
      expect(bell.heard('wok', board(rush)), isTrue);
      expect(chime.plays, 1);
    });

    test('the kitchen\'s own taps are silent: a dish made, a ticket finished, one brought back', () {
      bell.heard('wok', board([soup, wings]));
      final oneMade = ticket('o1', 5, [
        dish('a', 'Hot and Sour Soup', made: ['wok']),
        dish('b', 'Fried Rice'),
      ], table: '12');
      expect(bell.heard('wok', board([oneMade, wings])), isFalse);
      final allMade = ticket('o1', 5, [
        dish('a', 'Hot and Sour Soup', made: ['wok']),
        dish('b', 'Fried Rice', made: ['wok']),
      ], table: '12');
      expect(bell.heard('wok', board([wings], recent: [allMade])), isFalse);
      // Recall: the same ticket stands among the ones to make again
      expect(bell.heard('wok', board([soup, wings])), isFalse);
      // and a ticket that only leaves (its order was voided whole) takes nothing new with it
      expect(bell.heard('wok', board([wings])), isFalse);
      expect(chime.plays, 0);
    });

    test('a dish voided or changed after it was sent sounds, and so does an allergy told late', () {
      bell.heard('wok', board([soup]));
      final struck = ticket('o1', 5, [
        dish('a', 'Hot and Sour Soup', isVoid: true),
        dish('b', 'Fried Rice'),
      ], table: '12');
      expect(bell.heard('wok', board([struck])), isTrue);
      // the cook marked it seen and it left the ticket: nothing to read
      final seen = ticket('o1', 5, [dish('b', 'Fried Rice')], table: '12');
      expect(bell.heard('wok', board([seen])), isFalse);
      final changed = ticket('o1', 5, [
        dish('b', 'Fried Rice', modifiers: ['No egg'], changed: true),
      ], table: '12');
      expect(bell.heard('wok', board([changed])), isTrue);
      final noted = ticket('o1', 5, [
        dish('b', 'Fried Rice', modifiers: ['No egg'], changed: true, note: 'on the side'),
      ], table: '12');
      expect(bell.heard('wok', board([noted])), isTrue);
      final allergic = ticket(
        'o1',
        5,
        [
          dish('b', 'Fried Rice', modifiers: ['No egg'], changed: true, note: 'on the side', allergy: 'Egg'),
        ],
        table: '12',
        allergies: ['Order: Egg'],
      );
      expect(bell.heard('wok', board([allergic])), isTrue);
      expect(chime.plays, 4);
      // where it sits is not the cook's to read anew: a check that moved table says nothing here
      final moved = {...allergic, 'table': '14'};
      expect(bell.heard('wok', board([moved])), isFalse);
      expect(chime.plays, 4);
    });

    test('another screen starts silent: its tickets were there before anybody listened', () {
      bell.heard('stations wok', board([soup]));
      expect(bell.heard('stations fryer', board([soup, wings])), isFalse);
      expect(
        bell.heard(
          'stations fryer',
          board([
            soup,
            wings,
            ticket('o3', 0, [dish('a', 'Egg Roll')]),
          ]),
        ),
        isTrue,
      );
      expect(chime.plays, 1);
    });

    test('a device told to keep quiet makes no sound, and switching it on sounds for nothing old', () {
      bell.heard('wok', board([soup]), on: false);
      expect(bell.heard('wok', board([soup, wings]), on: false), isTrue);
      expect(chime.plays, 0);
      expect(bell.heard('wok', board([soup, wings])), isFalse);
      expect(chime.plays, 0);
    });

    test('it keeps quiet while the device is on a call', () {
      var onCall = true;
      final polite = KitchenBell(chime, quiet: () => onCall);
      polite.heard('wok', board([soup]));
      expect(polite.heard('wok', board([soup, wings])), isTrue);
      expect(chime.plays, 0);
      onCall = false;
      polite.heard(
        'wok',
        board([
          soup,
          wings,
          ticket('o3', 0, [dish('a', 'Egg Roll')]),
        ]),
      );
      expect(chime.plays, 1);
    });

    test('the chime is in the app', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final sound = await rootBundle.load('assets/sounds/ticket.wav');
      expect(String.fromCharCodes(sound.buffer.asUint8List(0, 4)), 'RIFF');
      expect(sound.lengthInBytes, inInclusiveRange(10000, 100000)); // under a second of it
    });
  });

  group('a kitchen screen', () {
    testWidgets('is silent for what stands on it, and sounds once for a ticket that comes in', (tester) async {
      final chime = FakeChime();
      final t = await pumpScreen(tester, bell: KitchenBell(chime));
      expect(chime.plays, 0);
      t.hub.kitchen!.add(ticket('o9', 0, [dish('a', 'Hot and Sour Soup')], table: '21'));
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(chime.plays, 1);
      // nothing new on the next read, and the cook's own tap is no news
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      await tester.tap(row('o1', 'a'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      await tester.tap(button('done', 'o4'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(chime.plays, 1);
      await away(tester);
    });

    testWidgets('sounds when a dish it is cooking is voided', (tester) async {
      final chime = FakeChime();
      final t = await pumpScreen(tester, bell: KitchenBell(chime));
      final lines = t.hub.kitchen![0]['lines'] as List;
      lines[1] = {...lines[1] as Map<String, dynamic>, 'void': true};
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(chime.plays, 1);
      await away(tester);
    });

    testWidgets('the pass hears a ticket come in too', (tester) async {
      final chime = FakeChime();
      final t = await pumpScreen(tester, pass: true, stations: const [], bell: KitchenBell(chime));
      expect(chime.plays, 0);
      t.hub.kitchen!.add(ticket('o9', 0, [dish('a', 'Hot and Sour Soup')], table: '21'));
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(chime.plays, 1);
      await away(tester);
    });

    testWidgets('told to keep quiet, it makes no sound', (tester) async {
      final chime = FakeChime();
      final t = await pumpScreen(tester, bell: KitchenBell(chime), sound: false);
      t.hub.kitchen!.add(ticket('o9', 0, [dish('a', 'Hot and Sour Soup')], table: '21'));
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(chime.plays, 0);
      await away(tester);
    });
  });

  group('the device that is a kitchen screen', () {
    Future<Terminal> pumpDevice(WidgetTester tester, KitchenBell bell, {bool sound = true}) async {
      final t = await terminal(tester);
      t.session.signOut();
      await t.settings.saveKitchenStations(const ['wok'], sound: sound);
      t.hub.stations = {...names};
      t.hub.kitchen = evening();
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
          bell: bell,
        ),
      );
      await tester.pumpAndSettle();
      return t;
    }

    Future<void> signIn(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('kitchen-staff')));
      await tester.pumpAndSettle();
      for (final digit in '1111'.split('')) {
        await tester.tap(find.widgetWithText(FilledButton, digit));
        await tester.pump();
      }
      await tester.pumpAndSettle();
    }

    testWidgets('what came in while somebody was signed in on it is heard when the screen stands again', (
      tester,
    ) async {
      final chime = FakeChime();
      final t = await pumpDevice(tester, KitchenBell(chime));
      expect(find.byType(KitchenScreen), findsOneWidget);
      expect(chime.plays, 0);
      await signIn(tester);
      expect(find.byType(OrdersScreen), findsOneWidget);
      t.hub.kitchen!.add(ticket('o9', 0, [dish('a', 'Hot and Sour Soup')], table: '21'));
      await tester.pump(const Duration(seconds: 4));
      expect(chime.plays, 0); // no kitchen screen stands: nothing is read for it
      t.session.signOut();
      await tester.pumpAndSettle();
      expect(find.byType(KitchenScreen), findsOneWidget);
      expect(chime.plays, 1);
      // and a sign-in with nothing new in between is no reason to sound again
      await signIn(tester);
      t.session.signOut();
      await tester.pumpAndSettle();
      expect(chime.plays, 1);
      await away(tester);
    });

    testWidgets('a device told to keep quiet stays quiet', (tester) async {
      final chime = FakeChime();
      final t = await pumpDevice(tester, KitchenBell(chime), sound: false);
      t.hub.kitchen!.add(ticket('o9', 0, [dish('a', 'Hot and Sour Soup')], table: '21'));
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(standing(tester), contains('o9')); // it is read and shown like any other
      expect(chime.plays, 0);
      await away(tester);
    });
  });

  group('in the device\'s Settings', () {
    Future<Terminal> pumpSettings(WidgetTester tester, {KitchenBell? bell}) async {
      final t = await terminal(tester);
      t.hub.stations = {...names};
      tester.view.physicalSize = wholeSettings;
      await tester.pumpWidget(
        MaterialApp(
          home: SettingsScreen(settings: t.settings, api: t.api, bell: bell),
        ),
      );
      await tester.pumpAndSettle();
      return t;
    }

    final soundSwitch = find.byKey(const ValueKey('kitchen-sound-switch'));
    final playIt = find.byKey(const ValueKey('kitchen-sound-try'));

    testWidgets('the sound is offered on a kitchen screen only, on to start, with a button to hear it', (tester) async {
      final chime = FakeChime();
      await pumpSettings(tester, bell: KitchenBell(chime));
      expect(soundSwitch, findsNothing);
      expect(playIt, findsNothing);
      await tester.tap(find.byKey(const ValueKey('kitchen-station:wok')));
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(soundSwitch).value, isTrue);
      await tester.tap(playIt);
      await tester.pump();
      expect(chime.plays, 1);
      // the pass has it as well
      await tester.tap(find.byKey(const ValueKey('kitchen-station:wok')));
      await tester.pumpAndSettle();
      expect(soundSwitch, findsNothing);
      await tester.tap(find.byKey(const ValueKey('kitchen-pass-switch')));
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(soundSwitch).value, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('switched off, it is kept so with Save and from one start to the next', (tester) async {
      final t = await pumpSettings(tester, bell: KitchenBell(FakeChime()));
      await tester.tap(find.byKey(const ValueKey('kitchen-station:wok')));
      await tester.pumpAndSettle();
      await tester.tap(soundSwitch);
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(soundSwitch).value, isFalse);
      expect(playIt, findsNothing); // nothing to hear on a device that keeps quiet
      expect(t.settings.kitchenSound, isTrue); // not before Save
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(t.settings.kitchenSound, isFalse);
      expect(t.settings.kitchenStations, ['wok']);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('kitchen_sound'), isFalse);
      expect((await Settings.load()).kitchenSound, isFalse);
      // on again: the device is as one that was never asked
      await t.settings.saveKitchenStations(const ['wok'], sound: true);
      expect(prefs.containsKey('kitchen_sound'), isFalse);
      // and saving its stations alone leaves the sound as it was
      await t.settings.saveKitchenStations(const ['wok'], sound: false);
      await t.settings.saveKitchenStations(const ['wok', 'fryer']);
      expect(t.settings.kitchenSound, isFalse);
    });

    testWidgets('a device that was never asked sounds; one with no button to play still has the switch', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        'device': 't1',
        'endpoints': ['http://hub:8000'],
        'kitchen_stations': ['wok'],
      });
      expect((await Settings.load()).kitchenSound, isTrue);
      final t = await pumpSettings(tester);
      await t.settings.saveKitchenStations(const ['wok']);
      await tester.pumpWidget(
        MaterialApp(
          home: SettingsScreen(key: UniqueKey(), settings: t.settings, api: t.api),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(soundSwitch).value, isTrue);
      expect(playIt, findsNothing);
    });
  });
}
