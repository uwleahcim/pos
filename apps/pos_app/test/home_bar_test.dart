import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/camera.dart';
import 'package:pos_app/screens/floor_view.dart';
import 'package:pos_app/screens/home_bar.dart';
import 'package:pos_app/screens/home_menu.dart';
import 'package:pos_app/screens/orders_ahead_screen.dart';
import 'package:pos_app/screens/orders_screen.dart';
import 'package:pos_app/screens/reservations_screen.dart';
import 'package:pos_app/screens/settings_screen.dart';
import 'package:pos_app/screens/waste_screen.dart';
import 'package:pos_app/session.dart';
import 'package:pos_app/takeout.dart' show clockTime;

import 'counter_test.dart' show takeout;
import 'hub.dart';
import 'time_clock_test.dart' show clockOn;

/// The home screen's row and the menu behind More (docs/home-screen.md): the row holds what a service
/// needs and never runs off the screen, the menu holds every way out by its group, and nothing the old
/// row of icons offered is out of reach.

const mike = Staff(staffId: 's3', name: 'Mike', role: 'manager', method: 'pin');
const amy = Staff(staffId: 's1', name: 'Amy', role: 'server', method: 'pin');

const phone = Size(390, 844);
const smallPhone = Size(320, 568);
const upright = Size(768, 1024);
const onItsSide = Size(1024, 768);

Finder key(String name) => find.byKey(ValueKey(name));

/// The home screen for [who] on a screen of [size], on an evening with everything in use: three parties
/// waiting, two booked tables to come, drivers, the time clock, a note up, a contest, the website's orders.
Future<Terminal> pumpHome(
  WidgetTester tester,
  Staff who,
  Size size, {
  double scale = 1,
  void Function(Hub hub)? hub,
}) async {
  final t = await terminal(tester);
  tester.view.physicalSize = size;
  t.session.staff = who;
  final now = DateTime.now().millisecondsSinceEpoch;
  t.hub
    ..clockNow = now
    ..withDrivers()
    ..timeClock = clockOn()
    ..online = Hub.onlineStatus(came: 6, placed: 6, answeredMs: now)
    ..contests = [Hub.contest('c1', 'Dumpling week', board: 'all')]
    ..shiftNotes = [
      {
        'id': 'n1',
        'text': 'Out tonight: lobster.',
        'by': 'Mike',
        'at_ms': now,
        'seen_by': ['s1', 's3'],
      },
    ]
    ..bookings = [
      Hub.booking('b1', 'Chen', 4, time: clockTime(now + 40 * 60000), atMs: now + 40 * 60000),
      Hub.booking('b2', 'Okafor', 2, time: clockTime(now + 70 * 60000), atMs: now + 70 * 60000),
    ]
    ..parties = [
      Hub.waitParty('p1', 'Omar', 4, atMs: now - 5 * 60000, quoted: 20),
      Hub.waitParty('p2', 'Wu', 2, atMs: now - 3 * 60000, quoted: 15),
      Hub.waitParty('p3', 'Garcia', 6, atMs: now - 60000, quoted: 30),
    ];
  hub?.call(t.hub);
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
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

/// The ids of the menu's tiles, in the order they are drawn.
List<String> tiles(WidgetTester tester) => [
  for (final tile in tester.widgetList<HomeTile>(find.byType(HomeTile))) tile.entry.id,
];

/// The ids of the buttons of the row that came out of the list of entries.
List<String> inRow(WidgetTester tester) => [
  for (final pill in tester.widgetList<HomePill>(find.byType(HomePill)))
    if (pill.key case ValueKey<String>(:final value) when value.startsWith('home-quick:'))
      value.substring('home-quick:'.length),
];

Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pumpAndSettle();
}

/// The id of the tile the keyboard's focus is on; null when it is on none.
String? focusedTile() {
  String? id;
  FocusManager.instance.primaryFocus?.context?.visitAncestorElements((element) {
    if (element.widget case HomeTile(:final entry)) {
      id = entry.id;
      return false;
    }
    return true;
  });
  return id;
}

const everything = [
  'waitlist',
  'reservations',
  'ahead',
  'deliveries',
  'online',
  'clock',
  'notes',
  'contests',
  'waste',
  'today',
  'location',
  'menu',
  'closed',
  'display',
  'settings',
];

void main() {
  group('the row', () {
    testWidgets('a phone has the person, the switch, the waitlist, the connection and More', (tester) async {
      await pumpHome(tester, mike, phone);
      expect(tester.takeException(), isNull);
      expect(find.descendant(of: find.byType(HomeBar), matching: find.text('Mike')), findsOneWidget);
      expect(key('home-view'), findsOneWidget);
      expect(key('waitlist-open'), findsOneWidget);
      expect(key('status'), findsOneWidget);
      expect(key('home-more'), findsOneWidget);
      // nothing else: no button of the menu's stands in a phone's row, and Sign out is in the menu
      expect(inRow(tester), isEmpty);
      expect(key('home-sign-out'), findsNothing);
      expect(find.descendant(of: find.byType(HomeBar), matching: find.byType(IconButton)), findsNWidgets(3));
      await stop(tester);
    });

    testWidgets('a manager on an upright tablet: every button is on the screen (the old row ran off it)', (
      tester,
    ) async {
      await pumpHome(tester, mike, upright);
      expect(tester.takeException(), isNull);
      expect(inRow(tester), ['reservations', 'ahead', 'deliveries']);
      for (final name in ['home-sign-out', 'home-view', 'waitlist-open', 'status', 'home-more']) {
        final box = tester.getRect(key(name));
        expect(box.left, greaterThanOrEqualTo(0), reason: name);
        expect(box.right, lessThanOrEqualTo(upright.width), reason: name);
      }
      expect(tester.getRect(key('home-more')).right, lessThanOrEqualTo(upright.width));
      await stop(tester);
    });

    testWidgets('a wide screen names its buttons, a narrower one keeps to their icons', (tester) async {
      // the tests' type is wide: a row this long has the room for the words
      await pumpHome(tester, mike, const Size(1900, 900));
      expect(tester.takeException(), isNull);
      expect(inRow(tester), ['reservations', 'ahead', 'deliveries']);
      final row = find.byType(HomeBar);
      for (final word in ['Reservations', 'Orders ahead', 'Deliveries', 'Waitlist', 'Floor', 'Checks']) {
        expect(
          find.descendant(of: row, matching: find.text(word)),
          findsOneWidget,
          reason: word,
        );
      }
      await stop(tester);

      await pumpHome(tester, mike, onItsSide);
      expect(tester.takeException(), isNull);
      expect(inRow(tester), ['reservations', 'ahead', 'deliveries']);
      expect(find.descendant(of: find.byType(HomeBar), matching: find.text('Orders ahead')), findsNothing);
      expect(find.byTooltip('Orders ahead'), findsOneWidget); // the icon says its name when pointed at
      await stop(tester);
    });

    testWidgets('where even the icons do not fit, the last are in the menu only, and nothing runs off', (tester) async {
      // the narrowest screen that is not a phone, large type, and a long name beside the picture
      const long = Staff(staffId: 's3', name: 'Bartholomew', role: 'manager', method: 'pin');
      await pumpHome(tester, long, const Size(600, 900), scale: 1.6);
      expect(tester.takeException(), isNull);
      final shown = inRow(tester);
      expect(shown.length, lessThan(3));
      expect(['reservations', 'ahead', 'deliveries'].take(shown.length), shown); // the first ones stay
      expect(key('waitlist-open'), findsOneWidget);
      expect(tester.getRect(key('home-more')).right, lessThanOrEqualTo(600));
      await openMore(tester);
      expect(tiles(tester), containsAll(['reservations', 'ahead', 'deliveries']));
      await stop(tester);
    });

    testWidgets('the smallest phone at the largest type: nothing runs off, with the waitlist in the row', (
      tester,
    ) async {
      await pumpHome(tester, mike, smallPhone, scale: 1.5);
      expect(tester.takeException(), isNull);
      expect(key('waitlist-open'), findsOneWidget);
      expect(tester.getRect(key('home-more')).right, lessThanOrEqualTo(smallPhone.width));
      await openMore(tester);
      expect(tester.takeException(), isNull);
      // every tile can be brought up and none is cut off at the side
      for (final id in everything) {
        await tester.ensureVisible(homeTile(id));
        await tester.pumpAndSettle();
        final box = tester.getRect(homeTile(id));
        expect(box.left, greaterThanOrEqualTo(0), reason: id);
        expect(box.right, lessThanOrEqualTo(smallPhone.width), reason: id);
      }
      expect(tester.takeException(), isNull);
      await stop(tester);
    });

    testWidgets('the switch shows which is up, and a tap on the other half goes there', (tester) async {
      final t = await pumpHome(tester, mike, onItsSide);
      t.hub.orders.add(takeout('o1'));
      bool floorUp() => tester.widget<ViewSwitch>(find.byType(ViewSwitch)).floor;
      expect(find.byType(FloorView), findsOneWidget);
      expect(floorUp(), isTrue);

      await tester.tap(key('home-view:checks'));
      await tester.pumpAndSettle();
      expect(find.byType(FloorView), findsNothing);
      expect(floorUp(), isFalse);

      // the half that is up: nothing changes
      await tester.tap(key('home-view:checks'));
      await tester.pumpAndSettle();
      expect(find.byType(FloorView), findsNothing);

      await tester.tap(find.byTooltip('Floor map'));
      await tester.pumpAndSettle();
      expect(find.byType(FloorView), findsOneWidget);
      expect(floorUp(), isTrue);
      await stop(tester);
    });

    testWidgets('a short name is whole, with the device under it on a tablet', (tester) async {
      // "Amy" takes less room than a name is kept: it is whole all the same, never its first letter alone
      final t = await pumpHome(tester, amy, onItsSide);
      expect(tester.widget<Text>(key('home-name')).data, 'Amy');
      expect(find.descendant(of: find.byType(HomeBar), matching: find.text(t.settings.device)), findsOneWidget);
      await stop(tester);

      await pumpHome(tester, amy, phone);
      expect(tester.widget<Text>(key('home-name')).data, 'Amy');
      await stop(tester);
    });

    testWidgets('a screen turned on its side gains and loses the words at once, with nothing run off', (tester) async {
      await pumpHome(tester, mike, upright);
      expect(tester.widget<ViewSwitch>(find.byType(ViewSwitch)).labeled, isTrue);
      for (final size in [phone, onItsSide, smallPhone, upright]) {
        tester.view.physicalSize = size;
        await tester.pump(); // the first frame of the new size, before anything has settled
        expect(tester.takeException(), isNull, reason: '$size');
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '$size');
        expect(tester.getRect(key('home-more')).right, lessThanOrEqualTo(size.width), reason: '$size');
      }
      await stop(tester);
    });

    testWidgets('Sign out is one tap beside the name on a tablet', (tester) async {
      final t = await pumpHome(tester, mike, onItsSide);
      await tester.tap(find.byTooltip('Sign out'));
      await tester.pump();
      expect(t.session.staff, isNull);
      await stop(tester);
    });

    testWidgets('a button of the row opens what its tile opens', (tester) async {
      await pumpHome(tester, mike, onItsSide);
      await tester.tap(key('home-quick:ahead'));
      await tester.pumpAndSettle();
      expect(find.byType(OrdersAheadScreen), findsOneWidget);
      await stop(tester);

      await pumpHome(tester, mike, onItsSide);
      await tester.tap(key('home-quick:reservations'));
      await tester.pumpAndSettle();
      expect(find.byType(ReservationsScreen), findsOneWidget);
      await stop(tester);
    });

    testWidgets('More has a dot while online orders want a look, and its tile says so', (tester) async {
      Badge dot() => tester.widget<Badge>(find.descendant(of: key('home-more'), matching: find.byType(Badge)));
      await pumpHome(tester, mike, phone);
      expect(dot().isLabelVisible, isFalse);
      await stop(tester);

      await pumpHome(
        tester,
        mike,
        phone,
        hub: (hub) => hub.online = Hub.onlineStatus(
          came: 6,
          placed: 5,
          failed: 1,
          look: [Hub.onlineLook('g1', atMs: hub.clockNow)],
        ),
      );
      expect(dot().isLabelVisible, isTrue);
      await openMore(tester);
      expect(find.descendant(of: homeTile('online'), matching: find.text('Take a look')), findsOneWidget);
      await stop(tester);
    });
  });

  group('the menu behind More', () {
    testWidgets('a manager finds every way out, by its group', (tester) async {
      await pumpHome(tester, mike, phone);
      await openMore(tester);
      expect(tester.takeException(), isNull);
      expect(tiles(tester), everything);
      for (final group in ['Guests & orders', 'Shift', 'Manager', 'This device']) {
        expect(find.text(group), findsOneWidget);
      }
      // who is signed in, on what
      expect(tester.widget<Text>(key('home-menu-who')).data, 'Manager · t1');
      await stop(tester);
    });

    testWidgets('a server has no Manager group, and nothing of a manager\'s', (tester) async {
      await pumpHome(tester, amy, phone);
      await openMore(tester);
      expect(tiles(tester), [
        'waitlist',
        'reservations',
        'ahead',
        'deliveries',
        'clock',
        'notes',
        'contests',
        'waste',
        'closed',
        'display',
        'settings',
      ]);
      expect(find.text('Manager'), findsNothing);
      expect(tester.widget<Text>(key('home-menu-who')).data, 'Server · t1');
      await stop(tester);
    });

    testWidgets('what is not in use takes no room', (tester) async {
      await pumpHome(
        tester,
        amy,
        phone,
        hub: (hub) => hub
          ..parties = null
          ..olderThanDrivers()
          ..timeClock = {'enabled': false, 'breaks_paid': false, 'week_starts': 'mon'}
          ..shiftNotes = []
          ..contests = [],
      );
      await openMore(tester);
      expect(tiles(tester), ['reservations', 'ahead', 'waste', 'closed', 'display', 'settings']);
      await stop(tester);
    });

    testWidgets('the tiles say what is going on: who waits, what is booked, the notes up', (tester) async {
      await pumpHome(tester, mike, phone);
      await openMore(tester);
      Finder on(String id, String words) => find.descendant(of: homeTile(id), matching: find.text(words));
      expect(on('waitlist', '3 waiting'), findsOneWidget);
      expect(on('reservations', '2 to come'), findsOneWidget);
      expect(on('notes', '1 up'), findsOneWidget);
      expect(on('closed', 'Hidden'), findsOneWidget);
      expect(key('home-count:waitlist:ok'), findsOneWidget);
      expect(key('home-count:reservations:ok'), findsOneWidget);
      expect(tester.widget<HomeTile>(homeTile('closed')).entry.on, isFalse);
      await stop(tester);
    });

    testWidgets('a tile closes the menu and opens its screen', (tester) async {
      await pumpHome(tester, mike, phone);
      await openMore(tester);
      await tester.tap(homeTile('waste'));
      await tester.pumpAndSettle();
      expect(find.byType(HomeMenu), findsNothing);
      expect(find.byType(WasteScreen), findsOneWidget);
      await stop(tester);

      await pumpHome(tester, mike, onItsSide);
      await openHome(tester, 'settings');
      await tester.pumpAndSettle();
      expect(find.byType(HomeMenu), findsNothing);
      expect(find.byType(SettingsScreen), findsOneWidget);
      await stop(tester);
    });

    testWidgets('Sign out is at its top on every screen', (tester) async {
      for (final size in [phone, onItsSide]) {
        final t = await pumpHome(tester, amy, size);
        await openMore(tester);
        await tester.tap(key('home-menu-sign-out'));
        await tester.pumpAndSettle();
        expect(t.session.staff, isNull, reason: '$size');
        await stop(tester);
      }
    });

    testWidgets('a tap beside it closes it with nothing done', (tester) async {
      final t = await pumpHome(tester, mike, onItsSide);
      await openMore(tester);
      expect(find.byType(HomeMenu), findsOneWidget);
      await tester.tapAt(const Offset(20, 700));
      await tester.pumpAndSettle();
      expect(find.byType(HomeMenu), findsNothing);
      expect(find.byType(FloorView), findsOneWidget);
      expect(t.session.staff, isNotNull);
      await stop(tester);
    });

    testWidgets('Closed checks is a switch: turned on from the floor map, the list comes up with them', (tester) async {
      final t = await pumpHome(tester, mike, phone);
      t.hub.orders.add(takeout('o1'));
      expect(find.byType(FloorView), findsOneWidget);
      await openHome(tester, 'closed');
      await tester.pumpAndSettle();
      expect(find.byType(FloorView), findsNothing);
      expect(key('orders-list'), findsOneWidget);
      expect(t.hub.requests.last, isNot(contains('status=open'))); // the closed ones are asked for too

      await openMore(tester);
      final tile = tester.widget<HomeTile>(homeTile('closed')).entry;
      expect(tile.on, isTrue);
      expect(tile.note, 'Shown in the list');
      // turned off again: the list stays up
      await tester.tap(homeTile('closed'));
      await tester.pumpAndSettle();
      expect(key('orders-list'), findsOneWidget);
      await openMore(tester);
      expect(tester.widget<HomeTile>(homeTile('closed')).entry.on, isFalse);
      await stop(tester);
    });

    testWidgets('with a keyboard: it opens on its first tile, arrows move, Enter opens, Escape closes', (tester) async {
      await pumpHome(tester, mike, onItsSide);
      await openMore(tester);
      expect(focusedTile(), 'waitlist');
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(focusedTile(), 'reservations');
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(focusedTile(), 'ahead');
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focusedTile(), isNot('ahead'));

      await press(tester, LogicalKeyboardKey.escape);
      expect(find.byType(HomeMenu), findsNothing);
      expect(find.byType(FloorView), findsOneWidget);

      await openMore(tester);
      await press(tester, LogicalKeyboardKey.arrowRight);
      await press(tester, LogicalKeyboardKey.arrowRight);
      await press(tester, LogicalKeyboardKey.enter);
      expect(find.byType(HomeMenu), findsNothing);
      expect(find.byType(OrdersAheadScreen), findsOneWidget);
      await stop(tester);
    });

    testWidgets('larger type gives a tile more room: fewer to a row, and no name cut short', (tester) async {
      await pumpHome(tester, mike, phone);
      await openMore(tester);
      expect(tester.getTopLeft(homeTile('waitlist')).dy, tester.getTopLeft(homeTile('reservations')).dy);
      await stop(tester);

      await pumpHome(tester, mike, phone, scale: 1.5);
      await openMore(tester);
      expect(tester.takeException(), isNull);
      expect(tester.getTopLeft(homeTile('reservations')).dy, greaterThan(tester.getTopLeft(homeTile('waitlist')).dy));
      await stop(tester);
    });
  });
}
