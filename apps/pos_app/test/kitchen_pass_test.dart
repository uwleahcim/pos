import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/camera.dart';
import 'package:pos_app/desk_phone_watcher.dart';
import 'package:pos_app/idle_lock.dart';
import 'package:pos_app/kitchen_screen.dart';
import 'package:pos_app/main.dart';
import 'package:pos_app/phone.dart';
import 'package:pos_app/print_relay.dart';
import 'package:pos_app/screens/kitchen_screen.dart';
import 'package:pos_app/screens/settings_screen.dart';
import 'package:pos_app/screens/signin_screen.dart';
import 'package:pos_app/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'hub.dart';
import 'kitchen_screen_test.dart'
    show ago, away, board, button, dish, evening, marks, names, pumpScreen, row, six, standing, ticket, words;
import 'phone_test.dart' show FakeStack;

/// The pass and the all-day counts (docs/kitchen-screens.md). The pass is the kitchen screen of whoever
/// calls the orders: every station's dishes of a ticket together, each with where it is cooked and whether
/// that station has made it; a tap says a dish went out. All day, on a station's screen and on the pass,
/// counts how many of each dish the tickets still wait for.

/// The evening with the phone order's two dishes made at their stations, and half of table 12's.
List<Map<String, dynamic>> cooking() {
  final kitchen = evening();
  ((kitchen[0]['lines'] as List)[1] as Map)['made'] = ['wok']; // the lo mein
  for (final line in kitchen[1]['lines'] as List) {
    (line as Map)['made'] = [...line['stations'] as List];
  }
  return kitchen;
}

/// The stations a dish at the pass names, each with a tick once it has made it: "Wok✓", "Fryer".
List<String> cooks(WidgetTester tester, String orderId, String lineId, [int index = 0]) => [
  for (final tag
      in find
          .descendant(
            of: row(orderId, lineId, index),
            matching: find.byWidgetPredicate((w) => '${w.key}'.contains('kitchen-cook:')),
          )
          .evaluate())
    () {
      final said = '${tag.widget.key}'.split('kitchen-cook:').last.split(':');
      return '${said[0]}${said[1].startsWith('made') ? '✓' : ''}';
    }(),
];

/// What All day lists, top to bottom: "2 General Tso Chicken".
List<String> counted(WidgetTester tester) => [
  for (final cell in find.byWidgetPredicate((w) => '${w.key}'.contains('kitchen-count-of:')).evaluate())
    [
      for (final text in find.descendant(of: find.byWidget(cell.widget), matching: find.byType(Text)).evaluate())
        (text.widget as Text).data,
    ].join(' '),
];

void main() {
  group('what the pass and the counts read', () {
    test('the counts add up each dish still waited for, the most first', () {
      final read = board(evening());
      expect(
        [for (final count in read.counts) '${count.qty} ${count.label}'],
        [
          '4 Egg Roll',
          '2 Beef Teriyaki',
          '2 General Tso Chicken',
          '1 Beef Lo Mein',
          '1 California Roll',
          '1 Chicken Wings',
          '1 Crab Rangoon',
          '1 Kung Pao Shrimp',
        ],
      );
      // a dish made is not counted, nor a void, nor a ticket that is finished
      final some = board(
        [
          ticket('o1', 5, [
            dish('a', 'Soup', qty: 3),
            dish('b', 'Soup', made: ['wok']),
            dish('c', 'Soup', isVoid: true),
            dish('d', 'Rice', qty: 2),
          ]),
        ],
        recent: [
          ticket('o2', 9, [
            dish('a', 'Rice', made: ['wok']),
          ]),
        ],
      );
      expect([for (final count in some.counts) '${count.qty} ${count.label}'], ['3 Soup', '2 Rice']);
      expect(const KitchenBoard().counts, isEmpty);
    });

    test('the pass says so, names the stations it watches, and knows a ticket that is all made', () {
      Map<String, dynamic> at(String lineId, String label, Map<String, bool> cooks, {bool out = false}) => {
        ...dish(lineId, label, stations: const ['*pass'], made: [if (out) '*pass']),
        'cooks': [
          for (final MapEntry(key: code, value: made) in cooks.entries)
            {'code': code, 'name': code.toUpperCase(), 'made': made},
        ],
      };
      KitchenBoard pass(List<Map<String, dynamic>> lines, {List<Map<String, String>> stations = const []}) =>
          KitchenBoard.fromJson({
            'pass': true,
            'stations': stations,
            'tickets': [
              {...ticket('o1', 5, lines), 'id': 'o1:1'},
            ],
          });
      final waiting = pass([
        at('a', 'Soup', {'wok': true}),
        at('b', 'Wings', {'fryer': false, 'wok': true}),
      ]);
      expect((waiting.pass, waiting.title), (true, 'The pass'));
      final line = waiting.tickets.single.lines[1];
      expect(
        [for (final cook in line.cooks) '${cook.code} ${cook.name} ${cook.made}'],
        ['fryer FRYER false', 'wok WOK true'],
      );
      expect((line.cooked, line.done, waiting.tickets.single.allMade), (false, false, false));
      final ready = pass(
        [
          at('a', 'Soup', {'wok': true}),
          at('b', 'Wings', {'fryer': false}, out: true), // gone out already: nobody waits for it
          {
            ...at('c', 'Rice', {'wok': false}),
            'void': true,
          },
        ],
        stations: const [
          {'code': 'fryer', 'name': 'Fryer'},
          {'code': 'wok', 'name': 'Wok'},
        ],
      );
      expect(ready.title, 'The pass · Fryer · Wok');
      expect(ready.tickets.single.allMade, isTrue);
      // a dish nobody cooks (typed, with no station) holds nothing up, and makes nothing ready by itself
      expect(pass([at('a', 'Open dish', const {})]).tickets.single.allMade, isFalse);
      expect(board(evening()).tickets.first.allMade, isFalse); // a station's screen has no such word

      // its own word laid over: the dish went out, with what the stations made of it still said
      Map<String, dynamic> out(List<String> ids) => {
        'kind': 'done',
        'data': {'station': '*pass', 'line_ids': ids},
      };
      final laid = waiting.withLocal(
        (id) => [
          out(['a', 'b']),
        ],
        nowMs: ago(0),
      );
      expect((laid.pass, laid.tickets.length, laid.recent.single.done), (true, 0, true));
      expect(laid.recent.single.lines[1].cooks, hasLength(2));
      expect(
        [for (final (kind, data) in markOps(waiting.tickets.single.lines, made: true)) '$kind $data'],
        ['done {station: *pass, line_ids: [a, b]}'],
      );
    });
  });

  group('All day on a station\'s screen', () {
    testWidgets('counts what its tickets still wait for, and Back returns to them', (tester) async {
      final t = await pumpScreen(tester);
      await tester.tap(find.byKey(const ValueKey('kitchen-all-day')));
      await tester.pump();
      expect(tester.widget<Text>(find.byKey(const ValueKey('kitchen-title'))).data, 'All day · Wok');
      expect(counted(tester), [
        '2 Beef Teriyaki',
        '2 General Tso Chicken',
        '1 Beef Lo Mein',
        '1 Chicken Wings',
        '1 Kung Pao Shrimp',
      ]);
      expect(standing(tester), isEmpty);
      expect(find.byKey(const ValueKey('kitchen-recall')), findsNothing);
      expect(find.byKey(const ValueKey('kitchen-count')), findsNothing);
      expect(marks(t.hub), isEmpty); // looking is not changing
      await tester.tap(find.byKey(const ValueKey('kitchen-back')));
      await tester.pump();
      expect(standing(tester), ['o1', 'o2', 'o3', 'o4']);

      // a dish made is counted no longer
      await tester.tap(row('o1', 'a'));
      await tester.pump();
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('kitchen-all-day')));
      await tester.pump();
      expect(counted(tester), ['2 Beef Teriyaki', '1 Beef Lo Mein', '1 Chicken Wings', '1 Kung Pao Shrimp']);
      await away(tester);
    });

    testWidgets('it follows the kitchen while it is looked at, and leaves when nothing waits', (tester) async {
      final t = await pumpScreen(
        tester,
        kitchen: [
          ticket('o1', 5, [dish('a', 'Soup', qty: 2)], table: '3'),
        ],
      );
      await tester.tap(find.byKey(const ValueKey('kitchen-all-day')));
      await tester.pump();
      expect(counted(tester), ['2 Soup']);
      t.hub.kitchen!.add(ticket('o2', 0, [dish('a', 'Soup'), dish('b', 'Rice')], table: '4'));
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(counted(tester), ['3 Soup', '1 Rice']);
      // every ticket made somewhere else (two stations' screens show the same dishes): nothing to count
      t.hub.kitchen!.clear();
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(counted(tester), isEmpty);
      expect(tester.widget<Text>(find.byKey(const ValueKey('kitchen-none'))).data, 'Nothing to make right now.');
      expect(tester.widget<Text>(find.byKey(const ValueKey('kitchen-title'))).data, 'Wok');
      expect(find.byKey(const ValueKey('kitchen-all-day')), findsNothing); // nothing to count: no button
      await away(tester);
    });

    testWidgets('a small phone with large text has it as an icon, and every count fits', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await pumpScreen(tester, size: const Size(320, 568));
      await tester.ensureVisible(button('done', 'o4'));
      await tester.pump();
      await tester.tap(button('done', 'o4')); // (so that Recall stands in the head too)
      await tester.pump();
      await tester.pump();
      expect(tester.widget(find.byKey(const ValueKey('kitchen-all-day'))), isA<IconButton>());
      expect(tester.widget(find.byKey(const ValueKey('kitchen-recall'))), isA<IconButton>());
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('kitchen-all-day')));
      await tester.pump();
      expect(counted(tester), ['2 Beef Teriyaki', '2 General Tso Chicken', '1 Beef Lo Mein', '1 Kung Pao Shrimp']);
      expect(tester.takeException(), isNull);
      await away(tester);
    });
  });

  group('the pass', () {
    testWidgets('lists every station\'s dishes of a ticket, each with where it is cooked and whether it is made', (
      tester,
    ) async {
      final t = await pumpScreen(tester, stations: const [], pass: true, kitchen: cooking());
      expect(t.hub.requests, contains('GET /kitchen/pass'));
      expect(tester.widget<Text>(find.byKey(const ValueKey('kitchen-title'))).data, 'The pass');
      expect(tester.widget<Text>(find.byKey(const ValueKey('kitchen-count'))).data, '4 tickets');
      expect(standing(tester), ['o1', 'o2', 'o3', 'o4']);
      expect(
        words(tester, 'o2'),
        containsAllInOrder(['#14 Linda', '1 × Kung Pao Shrimp', 'Wok', '4 × Egg Roll', 'Fryer']),
      );
      expect(cooks(tester, 'o1', 'a'), ['wok']);
      expect(cooks(tester, 'o1', 'b', 1), ['wok✓']);
      expect(cooks(tester, 'o2', 'b', 1), ['fryer✓']);
      expect(cooks(tester, 'o3', 'b', 2), ['sushi']);
      // every station has made its part of the phone order: the pass is told so, and of no other ticket
      expect(button('ready', 'o2'), findsOneWidget);
      expect(find.text('All made'), findsOneWidget);
      // the button says what the pass does with a ticket
      expect(find.widgetWithText(FilledButton, 'Sent out'), findsNWidgets(4));
      expect(find.widgetWithText(FilledButton, 'Done'), findsNothing);
      await away(tester);
    });

    testWidgets('a tap says a dish went out, Sent out the whole ticket, and Recall brings one back', (tester) async {
      final t = await pumpScreen(tester, stations: const [], pass: true, kitchen: cooking());
      await tester.tap(row('o1', 'a'));
      await tester.pump();
      await tester.pump();
      expect(marks(t.hub), ['o1 *pass a made']);
      expect((t.hub.sent.single.$2['data'] as Map).keys, ['station', 'line_ids']);
      expect(find.byIcon(Icons.check_circle), findsOneWidget);
      expect(standing(tester), ['o1', 'o2', 'o3', 'o4']);
      expect(cooks(tester, 'o1', 'a'), ['wok']); // what the wok made of it is the wok's to say

      await tester.tap(button('done', 'o2'));
      await tester.pump();
      await tester.pump();
      expect(marks(t.hub).last, 'o2 *pass a,b made');
      expect(t.hub.batches.last, hasLength(1));
      expect(standing(tester), ['o1', 'o3', 'o4']);

      await tester.tap(find.byKey(const ValueKey('kitchen-recall')));
      await tester.pump();
      expect(tester.widget<Text>(find.byKey(const ValueKey('kitchen-title'))).data, 'Sent out from the pass');
      expect(standing(tester), ['o2']);
      expect(button('ready', 'o2'), findsNothing); // nothing to wait for on a ticket that is gone
      await tester.tap(button('bring-back', 'o2'));
      await tester.pump();
      await tester.pump();
      expect(marks(t.hub).last, 'o2 *pass a,b not made');
      expect(standing(tester), ['o1', 'o2', 'o3', 'o4']);
      expect(button('ready', 'o2'), findsOneWidget);
      await away(tester);
    });

    testWidgets('what a station makes shows at the pass on the next read', (tester) async {
      final t = await pumpScreen(tester, stations: const [], pass: true);
      expect(cooks(tester, 'o4', 'a'), ['wok']);
      expect(find.text('All made'), findsNothing);
      ((t.hub.kitchen![3]['lines'] as List).single as Map)['made'] = ['wok'];
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(cooks(tester, 'o4', 'a'), ['wok✓']);
      expect(button('ready', 'o4'), findsOneWidget);
      await away(tester);
    });

    testWidgets('a pass told its stations asks for those, and says them', (tester) async {
      final t = await pumpScreen(tester, stations: const ['wok', 'fryer'], pass: true);
      expect(t.hub.requests, contains('GET /kitchen/pass?stations=wok%2Cfryer'));
      expect(tester.widget<Text>(find.byKey(const ValueKey('kitchen-title'))).data, 'The pass · Fryer · Wok');
      // table 7's sushi is not this pass's
      expect(words(tester, 'o3'), isNot(contains('1 × California Roll')));
      expect(words(tester, 'o3'), containsAll(['1 × Crab Rangoon', '2 × Beef Teriyaki']));
      await away(tester);
    });

    testWidgets('All day at the pass counts what has not gone out', (tester) async {
      await pumpScreen(tester, stations: const [], pass: true, kitchen: cooking());
      await tester.tap(button('done', 'o2'));
      await tester.pump();
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('kitchen-all-day')));
      await tester.pump();
      expect(tester.widget<Text>(find.byKey(const ValueKey('kitchen-title'))).data, 'All day · The pass');
      expect(counted(tester), [
        '2 Beef Teriyaki',
        '2 General Tso Chicken',
        '1 Beef Lo Mein', // made at the wok, and still on the pass
        '1 California Roll',
        '1 Chicken Wings',
        '1 Crab Rangoon',
      ]);
      await away(tester);
    });

    testWidgets('nothing at the pass says so; a hub older than the pass says to update it', (tester) async {
      await pumpScreen(tester, stations: const [], pass: true, kitchen: []);
      expect(tester.widget<Text>(find.byKey(const ValueKey('kitchen-none'))).data, 'Nothing at the pass right now.');
      await away(tester);
      final t = await terminal(tester);
      t.session.signOut();
      t.hub.kitchenPassKnown = false;
      await tester.pumpWidget(
        MaterialApp(
          home: KitchenScreen(api: t.api, outbox: t.outbox, stations: const [], pass: true, now: () => six),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('kitchen-none'))).data,
        startsWith('This hub is older than the pass screen.'),
      );
      expect(tester.widget<Text>(find.byKey(const ValueKey('kitchen-title'))).data, 'The pass');
      await away(tester);
    });

    testWidgets('a small phone with large text still fits every word of it', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await pumpScreen(tester, stations: const [], pass: true, kitchen: cooking(), size: const Size(320, 568));
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(button('done', 'o4'));
      await tester.pump();
      await tester.tap(button('done', 'o4'));
      await tester.pump();
      await tester.pump();
      expect(tester.takeException(), isNull);
      await away(tester);
    });
  });

  group('the device that is the pass', () {
    testWidgets('the switch is in the device\'s Settings, off to start, and kept with Save', (tester) async {
      final t = await terminal(tester);
      t.hub.stations = {...names};
      expect((t.settings.kitchenPass, t.settings.kitchen, t.settings.stands), (false, false, false));
      tester.view.physicalSize = wholeSettings;
      await tester.pumpWidget(
        MaterialApp(
          home: SettingsScreen(settings: t.settings, api: t.api),
        ),
      );
      await tester.pumpAndSettle();
      final line = find.byKey(const ValueKey('kitchen-screen-line'));
      bool passOn() => tester.widget<SwitchListTile>(find.byKey(const ValueKey('kitchen-pass-switch'))).value;
      expect(passOn(), isFalse);
      await tester.tap(find.byKey(const ValueKey('kitchen-pass-switch')));
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(line).data, contains('this screen is the pass'));
      expect(tester.widget<Text>(line).data, contains('It watches every station.'));
      await tester.tap(find.byKey(const ValueKey('kitchen-station:wok')));
      await tester.tap(find.byKey(const ValueKey('kitchen-station:fryer')));
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(line).data, contains('It watches Wok and Fryer.'));
      expect(t.settings.kitchenPass, isFalse); // not before Save
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect((t.settings.kitchenPass, t.settings.kitchenStations.join(',')), (true, 'wok,fryer'));
      final prefs = await SharedPreferences.getInstance();
      expect((prefs.getBool('kitchen_pass'), prefs.getStringList('kitchen_stations')?.join(',')), (true, 'wok,fryer'));
    });

    testWidgets('a pass of every station is a kitchen screen with no station picked; never a pickup board too', (
      tester,
    ) async {
      final t = await terminal(tester);
      t.hub.stations = {...names};
      await t.settings.savePickupBoard(true);
      tester.view.physicalSize = wholeSettings;
      await tester.pumpWidget(
        MaterialApp(
          home: SettingsScreen(settings: t.settings, api: t.api),
        ),
      );
      await tester.pumpAndSettle();
      bool boardOn() => tester.widget<SwitchListTile>(find.byKey(const ValueKey('pickup-board-switch'))).value;
      bool passOn() => tester.widget<SwitchListTile>(find.byKey(const ValueKey('kitchen-pass-switch'))).value;
      await tester.tap(find.byKey(const ValueKey('kitchen-pass-switch')));
      await tester.pumpAndSettle();
      expect((boardOn(), passOn()), (false, true));
      await tester.tap(find.byKey(const ValueKey('pickup-board-switch')));
      await tester.pumpAndSettle();
      expect((boardOn(), passOn()), (true, false));
      await tester.tap(find.byKey(const ValueKey('kitchen-pass-switch')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect((t.settings.pickupBoard, t.settings.kitchenPass, t.settings.kitchenStations.length), (false, true, 0));
      expect((t.settings.kitchen, t.settings.stands), (true, true));
      // and the device keeps it so, whichever was saved last
      await t.settings.savePickupBoard(true);
      expect((t.settings.pickupBoard, t.settings.kitchenPass, t.settings.kitchen), (true, false, false));
      await t.settings.saveKitchenStations(const [], pass: true);
      expect((t.settings.pickupBoard, t.settings.kitchenPass), (false, true));
      await t.settings.saveKitchenStations(const ['wok']); // a station's screen again
      expect((t.settings.kitchenPass, t.settings.kitchenStations.join(',')), (false, 'wok'));
      expect((await SharedPreferences.getInstance()).getBool('kitchen_pass'), isNull);
      // a pass may watch more stations than a screen stands for
      final many = [for (var n = 0; n < 40; n++) 's$n'];
      expect(Settings.cleanStations(many), hasLength(8));
      expect(Settings.cleanStations(many, pass: true), hasLength(32));
    });

    testWidgets('the pass stands while nobody is signed in, with the pad one tap away, and is kept over a restart', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        'device': 't1',
        'endpoints': ['http://hub:8000'],
        'kitchen_pass': true,
      });
      final kept = await Settings.load();
      expect((kept.kitchenPass, kept.kitchenStations.length, kept.stands), (true, 0, true));

      final t = await terminal(tester);
      t.session.signOut();
      await t.settings.saveKitchenStations(const [], pass: true);
      t.hub.stations = {...names};
      t.hub.kitchen = cooking();
      final lock = IdleLock(t.settings, t.session)..start();
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
      expect(find.byType(KitchenScreen), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const ValueKey('kitchen-title'))).data, 'The pass');
      expect(standing(tester), ['o1', 'o2', 'o3', 'o4']);
      await tester.tap(find.byKey(const ValueKey('kitchen-staff')));
      await tester.pumpAndSettle();
      expect(find.byType(SignInScreen), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Kitchen screen'), findsOneWidget); // the way back
      await tester.tap(find.byKey(const ValueKey('board-back')));
      await tester.pumpAndSettle();
      expect(find.byType(KitchenScreen), findsOneWidget);
      // made a station's screen from Settings: another screen altogether, with nothing of the pass on it
      await t.settings.saveKitchenStations(const ['fryer']);
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(find.byKey(const ValueKey('kitchen-title'))).data, 'Fryer');
      expect(standing(tester), ['o3']); // the phone order's egg rolls are made
      expect(find.widgetWithText(FilledButton, 'Sent out'), findsNothing);
      await away(tester);
    });
  });
}
