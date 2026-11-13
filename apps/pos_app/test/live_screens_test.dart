import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/camera.dart';
import 'package:pos_app/coursing.dart';
import 'package:pos_app/outbox.dart';
import 'package:pos_app/photos.dart';
import 'package:pos_app/queue_store.dart';
import 'package:pos_app/screens/menu_panel.dart';
import 'package:pos_app/screens/order_screen.dart';
import 'package:pos_app/screens/orders_screen.dart';
import 'package:pos_app/screens/status_bar.dart';
import 'package:pos_app/session.dart';
import 'package:pos_app/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'hub.dart';

/// The screens under the hub's change feed: they stop asking every two seconds, read the moment they are
/// told, and go back to asking the moment the feed is not there.
void main() {
  Future<(LiveHub, Terminal)> liveTerminal(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final settings = Settings(
      device: 't1',
      endpoints: ['http://hub:8000'],
      prefs: await SharedPreferences.getInstance(),
    );
    final hub = Hub();
    final live = LiveHub(hub);
    final api = PosApi(settings, client: live.client);
    final session = Session(api)..staff = const Staff(staffId: 's3', name: 'Mike', role: 'manager', method: 'pin');
    final outbox = Outbox(api, settings, store: MemoryStore());
    final photos = PhotoQueue(api, settings, NoCamera(), session, store: MemoryStore());
    tester.view
      ..physicalSize = const Size(1100, 800)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    api.live.start(); // as the app does when it starts
    return (live, Terminal(hub, api, outbox, photos, session, settings));
  }

  /// The feed comes up: the hub greets the screen and writes its heartbeat from then on.
  Future<void> goLive(WidgetTester tester, LiveHub live, Terminal t) async {
    expect(live.opened, 1); // opened as soon as a backend answered the screen's first read
    live.hello();
    live.beats();
    await tester.pumpAndSettle();
    expect(t.api.live.isLive, isTrue);
    // Connected, every screen reads once (whatever changed before nobody told it), paced like any told read.
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
  }

  /// Ends a test: the screens' timers, the pretend hub's heartbeat, the feed's own.
  Future<void> finish(WidgetTester tester, LiveHub live, Terminal t) async {
    await stop(tester);
    live.close();
    t.api.dispose();
    await tester.pump();
  }

  int reads(Hub hub, String path) => hub.requests.where((r) => r == 'GET $path' || r.startsWith('GET $path?')).length;

  testWidgets('an open check waits to be told, reads when its order changes, and polls when the feed is gone', (
    tester,
  ) async {
    final (live, t) = await liveTerminal(tester);
    t.hub.orders.add(table('o1', {'L1': line('Egg Roll', course: '1')}));
    await tester.pumpWidget(
      MaterialApp(
        home: OrderScreen(
          api: t.api,
          outbox: t.outbox,
          photos: t.photos,
          orderId: 'o1',
          coursing: Coursing.fromJson(t.hub.coursing),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Egg Roll'), findsWidgets);
    await goLive(tester, live, t);

    // Twenty seconds in which nothing changes: ten polls before, not one request now.
    t.hub.requests.clear();
    await tester.pump(const Duration(seconds: 20));
    await tester.pump();
    expect(t.hub.requests, isEmpty);

    // Another terminal adds a dish to this table: the hub says so and the dish is on this screen at once,
    // not at the next two-second tick.
    (t.hub.orders.single['lines'] as Map)['L2'] = line('Tsingtao', course: '1');
    live.changed(orders: ['o1']);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
    expect(find.text('Tsingtao'), findsWidgets);
    expect((reads(t.hub, '/orders/o1'), reads(t.hub, '/orders/o1/check')), (1, 1));

    // Somebody else's table changes: nothing for this screen to read.
    t.hub.requests.clear();
    live.changed(orders: ['o9']);
    live.changed(topics: ['settings']);
    await tester.pump(const Duration(seconds: 2));
    expect(t.hub.requests, isEmpty);

    // By itself it still asks once in thirty seconds, in case the hub never said.
    await tester.pump(const Duration(seconds: 30));
    await tester.pump();
    expect(reads(t.hub, '/orders/o1'), 1);

    // The feed ends (the hub restarts): the screen asks every two seconds again, as it always did.
    t.hub.requests.clear();
    live.drop();
    await tester.pump();
    expect(t.api.live.isLive, isFalse);
    await tester.pump(const Duration(seconds: 6));
    await tester.pump();
    expect(reads(t.hub, '/orders/o1'), greaterThanOrEqualTo(2));
    await finish(tester, live, t);
  });

  testWidgets('the list of checks and the floor read when the hub says an order changed, a burst as two reads', (
    tester,
  ) async {
    final (live, t) = await liveTerminal(tester);
    t.hub.orders.add(table('o1', {'L1': line('Egg Roll')}));
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
    await goLive(tester, live, t);

    t.hub.requests.clear();
    await tester.pump(const Duration(seconds: 20));
    await tester.pump();
    expect(t.hub.requests, isEmpty); // the floor and the list, both quiet

    // A table is seated on another terminal.
    t.hub.orders.add({
      ...table('o2', {'L1': line('Tsingtao')}),
      'fields': {'table': 'B7', 'guests': 4, 'order_type': 'dine_in'},
    });
    live.changed(orders: ['o2']);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
    expect((reads(t.hub, '/orders'), reads(t.hub, '/floor')), (1, 1));
    await tester.tap(find.byTooltip('List of checks'));
    await tester.pumpAndSettle();
    expect(find.text('Table B7'), findsOneWidget);

    // A rush: ten changes inside a second are one read now and one a second later, not ten.
    await tester.pump(const Duration(seconds: 2));
    t.hub.requests.clear();
    for (var i = 0; i < 10; i++) {
      live.changed(orders: ['o$i']);
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pump(const Duration(seconds: 3));
    expect(reads(t.hub, '/orders'), 2);

    // An older hub's terminal, or a feed that is down: every two seconds, as before.
    t.hub.requests.clear();
    live.drop();
    await tester.pump();
    await tester.pump(const Duration(seconds: 6));
    await tester.pump();
    expect(reads(t.hub, '/orders'), greaterThanOrEqualTo(2));
    await finish(tester, live, t);
  });

  testWidgets('an 86 on another terminal reaches an open menu at once, and the revision is no longer polled', (
    tester,
  ) async {
    final (live, t) = await liveTerminal(tester);
    t.hub.revision = 3;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MenuPanel(api: t.api, onChosen: (_) {}),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Appetizers'));
    await tester.pumpAndSettle();
    expect(find.text('Egg roll'), findsOneWidget);
    expect(find.text('86'), findsNothing);

    t.hub.requests.clear();
    await goLive(tester, live, t);
    expect(t.hub.requests, ['GET /menu/revision']); // connected: asked once whether it missed a save

    // Fifty seconds of service: ten revision checks before, none now.
    t.hub.requests.clear();
    await tester.pump(const Duration(seconds: 50));
    await tester.pump();
    expect(t.hub.requests, isEmpty);

    // The kitchen runs out of egg rolls and someone 86s them on another terminal. The revision does not move
    // for an 86, so polling never showed this before the five-minute reload.
    final menu = fixture('menu');
    final eggRoll = (((menu['menus'] as List)[0]['sections'] as List)[0]['entries'] as List)[0] as Map;
    ((eggRoll['variants'] as List)[0] as Map)['status'] = 'sold_out';
    t.hub.menu = menu;
    live.changed(topics: ['menu']);
    await tester.pump();
    await tester.pumpAndSettle();
    expect(reads(t.hub, '/menu'), 1);
    expect(find.text('86'), findsOneWidget);
    expect(find.text('Egg roll'), findsOneWidget); // still in the category it had open

    // An order changing is nothing to the menu.
    t.hub.requests.clear();
    live.changed(orders: ['o1']);
    await tester.pump(const Duration(seconds: 1));
    expect(t.hub.requests, isEmpty);
    await finish(tester, live, t);
  });

  testWidgets('the status sheet says whether changes are pushed or asked for', (tester) async {
    final (live, t) = await liveTerminal(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showStatusDetails(context, api: t.api, outbox: t.outbox),
              child: const Text('status'),
            ),
          ),
        ),
      ),
    );
    await t.api.health();
    await tester.pump();
    await tester.tap(find.text('status'));
    await tester.pumpAndSettle();
    expect(find.text('Asking for changes every 2 seconds'), findsOneWidget);
    expect(find.text('Connecting to live updates'), findsOneWidget);

    live.hello();
    live.beats();
    await tester.pumpAndSettle();
    expect(find.text('Changes arrive as they happen'), findsOneWidget);
    expect(find.text('Asking for changes every 2 seconds'), findsNothing);
    await finish(tester, live, t);
  });

  testWidgets('against a hub from before the feed the status sheet says to update it', (tester) async {
    final (live, t) = await liveTerminal(tester);
    live.refuse = 404;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showStatusDetails(context, api: t.api, outbox: t.outbox),
              child: const Text('status'),
            ),
          ),
        ),
      ),
    );
    await t.api.health();
    await tester.pump();
    await tester.tap(find.text('status'));
    await tester.pumpAndSettle();
    expect(find.text('Asking for changes every 2 seconds'), findsOneWidget);
    expect(find.text('This backend has no live updates yet: update the hub'), findsOneWidget);
    await finish(tester, live, t);
  });
}
