import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/camera.dart';
import 'package:pos_app/online_orders.dart';
import 'package:pos_app/outbox.dart';
import 'package:pos_app/photos.dart';
import 'package:pos_app/queue_store.dart';
import 'package:pos_app/screens/location_settings_screen.dart';
import 'package:pos_app/screens/online_orders_screen.dart';
import 'package:pos_app/screens/order_screen.dart';
import 'package:pos_app/session.dart';
import 'package:pos_app/settings.dart';
import 'package:pos_app/takeout.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'hub.dart';
import 'location_rows.dart';

/// How the online orders are doing, on the screens (docs/online-orders.md, "Under Location"): a manager's
/// screen is alerted when there is one to look at or when none is reaching the POS, the screen Online orders
/// says how they arrive, today's by what became of them and the ones to look at, and opening it is the
/// looking, for every screen.

final _now = DateTime.now();

/// A time today that is surely past: [minutes] before the test started, kept within today.
int ago(int minutes) {
  final at = _now.subtract(Duration(minutes: minutes));
  final midnight = DateTime(_now.year, _now.month, _now.day);
  return (at.isBefore(midnight) ? midnight : at).millisecondsSinceEpoch;
}

/// An order that could not be put on the POS, and nobody has looked yet.
Map<String, dynamic> lost({bool isNew = true}) =>
    Hub.onlineLook('7781', atMs: ago(4), said: 'it could not be put on the POS (KeyError)', isNew: isNew);

/// One that is a check on the POS with something to say of it.
Map<String, dynamic> short({bool isNew = true}) => Hub.onlineLook(
  '7790',
  atMs: ago(2),
  state: 'placed',
  orderId: 'o1',
  said: 'the website charged \$1.00 more than the POS: it is a row on the check',
  isNew: isNew,
);

/// The website does not answer the hub, and nothing else brings the orders.
Map<String, dynamic> silent({bool urgent = true}) => {
  'code': 'not_answering',
  'since_ms': ago(9),
  'reason': 'GloriaFood did not answer',
  'urgent': urgent,
};

Finder key(String name) => find.byKey(ValueKey(name));

/// How many widgets with this key are on the screen.
int shown(String name) => key(name).evaluate().length;

Future<void> tapKey(WidgetTester tester, String name) async {
  await tester.tap(key(name));
  await tester.pumpAndSettle();
}

String alertWords(WidgetTester tester) => tester.widget<Text>(key('online-alert-words')).data!;

String rowWords(WidgetTester tester, String name) {
  final row = tester.widget<ListTile>(key(name));
  final subtitle = row.subtitle! as Text;
  return subtitle.data ?? subtitle.textSpan!.toPlainText();
}

void main() {
  group('what the hub says of the online orders', () {
    test('how they arrive, today\'s by what became of them, and the ones to look at', () {
      final status = OnlineStatus.fromJson(
        Hub.onlineStatus(
          answeredMs: ago(1),
          pushedMs: ago(3),
          came: 12,
          byPush: 11,
          placed: 10,
          kept: 1,
          failed: 1,
          unread: 1,
          waiting: 2,
          look: [short(), lost(isNew: false)],
        ),
      );
      expect(
        (status.isOn, status.asks, status.takesPushes, status.running, status.writable),
        (true, true, true, true, true),
      );
      expect((status.answeredMs, status.pushedMs), (ago(1), ago(3)));
      expect(
        (status.came, status.byPush, status.byPoll, status.placed, status.kept, status.failed),
        (12, 11, 1, 10, 1, 1),
      );
      expect((status.unread, status.waiting, status.news, status.trouble.length), (1, 2, 1, 0));

      final [onPos, gone] = status.look;
      expect(
        (onPos.name, onPos.stateWords, onPos.onThePos, onPos.orderId, onPos.isNew),
        ('Order 7790', 'On the POS', true, 'o1', true),
      );
      expect(
        (gone.name, gone.stateWords, gone.onThePos, gone.isNew, gone.atMs),
        ('Order 7781', 'NOT ON THE POS', false, false, ago(4)),
      );
      expect(status.alert, 'Online orders: 1 to look at');
      expect(status.summary, 'Online orders: 1 to look at');
    });

    test('a row says what it is when it has no number of the website\'s', () {
      OnlineLook row(String kind, String state) =>
          OnlineLook.fromJson(Hub.onlineLook('x-1', atMs: 5, kind: kind, state: state));
      expect(
        (row('unreadable', 'failed').name, row('unreadable', 'failed').stateWords),
        ('Something the website sent', 'Could not be read'),
      );
      expect(
        (row('several', 'kept').name, row('several', 'kept').stateWords),
        ('Orders from earlier days', 'Not on the POS'),
      );
      // one that came a day late was kept off the POS on purpose: it does not shout
      expect((row('delivery', 'kept').name, row('delivery', 'kept').stateWords), ('Order x-1', 'Not on the POS'));
      // a check that is said to be on the POS and names none cannot be opened
      expect(row('pickup', 'placed').onThePos, isFalse);
      expect(const OnlineLook().name, 'An order');
      // a hub from before "since when" says when it came
      expect(OnlineLook.fromJson({'id': '9', 'fetched_ms': 77}).atMs, 77);
    });

    test('the one line of the row under Location', () {
      String summary(Map<String, dynamic> json) => OnlineStatus.fromJson(json).summary;
      expect(summary(Hub.onlineStatus(asks: false, pushes: false)), 'Off: the hub has no key from GloriaFood');
      expect(summary(Hub.onlineStatus()), 'None yet today');
      expect(summary(Hub.onlineStatus(came: 12, placed: 12)), 'Today 12 came, 12 on the POS');
      // looked at already: listed, and no alert
      expect(
        summary(Hub.onlineStatus(came: 12, placed: 11, failed: 1, look: [lost(isNew: false)])),
        'Today 12 came, 11 on the POS · 1 to look at',
      );
      expect(summary(Hub.onlineStatus(came: 3, placed: 1, look: [lost(), short()])), 'Online orders: 2 to look at');
      // none reaching the POS comes before everything else
      expect(
        summary(Hub.onlineStatus(look: [lost()], trouble: [silent()])),
        'Online orders are not reaching the POS since ${clockTime(ago(9))}',
      );
      // the net is gone while the orders still arrive: said, and nobody is alerted
      final late = OnlineStatus.fromJson(Hub.onlineStatus(came: 2, placed: 2, trouble: [silent(urgent: false)]));
      expect((late.summary, late.alert, late.urgent), ('GloriaFood does not answer the hub', null, null));
      expect(summary(Hub.onlineStatus(writable: false)), 'This hub is the standby: it takes no online orders now');
      expect(summary(Hub.onlineStatus(running: false)), 'The hub has stopped asking GloriaFood: sudo hubctl restart');
    });

    test('what is wrong is said with what to do about it', () {
      final at = clockTime(ago(9));
      final urgent = OnlineTrouble.fromJson(silent());
      expect(urgent.headline, 'Online orders are not reaching the POS');
      expect(
        urgent.words,
        'GloriaFood has not answered the hub since $at (GloriaFood did not answer). Until it does, look for new '
        'orders in GloriaFood\'s own app and ring them in by hand.',
      );
      final net = OnlineTrouble.fromJson(silent(urgent: false));
      expect(net.headline, 'GloriaFood does not answer the hub');
      expect(
        net.words,
        startsWith('The hub\'s asking has had no answer since $at (GloriaFood did not answer). Orders'),
      );
      OnlineTrouble refused(int count) => OnlineTrouble.fromJson({
        'code': 'pushes_refused',
        'since_ms': ago(9),
        'reason': 'the key is not the hub\'s',
        'urgent': false,
        'count': count,
      });
      expect(refused(1).headline, 'Online orders arrive a minute late');
      expect(refused(1).words, contains('1 sent by GloriaFood was turned away (the key is not the hub\'s)'));
      expect(refused(3).words, contains('3 sent by GloriaFood were turned away'));
      expect(refused(3).words, endsWith('The key in GloriaFood\'s admin is probably not the one on the hub.'));
      // something a newer hub says and this build does not know: the hub's own words
      final other = OnlineTrouble.fromJson({'code': 'tunnel_down', 'reason': 'the tunnel is not connected'});
      expect((other.headline, other.words), ('Online orders: something is wrong', 'the tunnel is not connected'));
      expect(const OnlineTrouble().words, 'The hub says something is wrong with the online orders.');
    });

    test('what came of asking now is said in a sentence or two', () {
      OnlineAsked asked(Map<String, dynamic> more) => OnlineAsked.fromJson({...Hub().onlineFetched, ...more});
      expect((asked({}).words, asked({}).bad), ('GloriaFood has no new order.', false));
      expect(asked({'came': 1, 'placed': 1}).words, '1 order came. 1 put on the POS.');
      expect(asked({'came': 1, 'known': 1}).words, '1 order came, and it was here already.');
      expect(asked({'came': 2, 'known': 2}).words, '2 orders came, all of them here already.');
      expect(asked({'came': 1, 'kept': 1}).words, '1 order came. 1 not for the POS.');
      final mixed = asked({'came': 3, 'known': 1, 'placed': 1, 'failed': 1});
      expect(
        mixed.words,
        '3 orders came, 1 of them here already. 1 put on the POS, 1 could not be put on (see To look at).',
      );
      expect(mixed.bad, isTrue);
      // one that waited from an earlier round went on with this one
      expect(asked({'placed': 1}).words, 'GloriaFood has no new order. 1 put on the POS.');
      final silence = asked({'answered': false, 'reason': 'GloriaFood did not answer in time'});
      expect(
        (silence.words, silence.bad),
        ('GloriaFood did not answer in time. The hub asks again by itself within the minute.', true),
      );
      final soon = asked({'asked': false, 'answered': false, 'soon': true});
      expect((soon.words, soon.bad), ('GloriaFood was asked a few seconds ago. Wait a moment and ask again.', false));
      final standby = asked({'asked': false, 'answered': false});
      expect(standby.words, 'This hub cannot write orders down now, so it asked for none.');
      // a hub from before the button says only what the round did: whether the website answered is in its status
      const before = {'asked': true, 'came': 1, 'known': 0, 'placed': 1, 'kept': 0, 'failed': 0};
      final fine = OnlineAsked.fromJson({...before, 'status': Hub.onlineStatus(came: 1, placed: 1)});
      expect((fine.answered, fine.words, fine.status?.placed), (true, '1 order came. 1 put on the POS.', 1));
      final refused = OnlineAsked.fromJson({
        ...before,
        'came': 0,
        'placed': 0,
        'status': {
          ...Hub.onlineStatus(),
          'last_failure': {'at_ms': 1, 'reason': 'GloriaFood refused the key'},
        },
      });
      expect(
        (refused.answered, refused.words),
        (false, 'GloriaFood refused the key. The hub asks again by itself within the minute.'),
      );
    });

    test('an answer that is no status, and one from before the count of new ones, alert nobody wrongly', () {
      final nothing = OnlineStatus.fromJson({'revision': 0});
      expect((nothing.isOn, nothing.alert, nothing.look.length, nothing.trouble.length), (false, null, 0, 0));
      expect(
        OnlineStatus.fromJson({
          'configured': true,
          'look': ['x', lost(), short(isNew: false)],
          'trouble': 'none',
          'today': 5,
          'push': null,
        }).news,
        1,
      );
    });
  });

  group('the calls', () {
    Future<Terminal> ready(WidgetTester tester) => terminal(tester);

    testWidgets('a hub older than online orders has no status; who looked is told by name, clipped', (tester) async {
      final t = await ready(tester);
      expect(await t.api.onlineStatus(), isNull);

      t.hub.online = Hub.onlineStatus(look: [lost()]);
      final first = await t.api.onlineStatus();
      expect((first!.news, t.hub.onlineAsks), (1, 1));
      // nothing changed: the very same object, so a screen redraws nothing
      expect(identical(await t.api.onlineStatus(), first), isTrue);

      final after = await t.api.onlineSeen('Mike');
      expect((after.news, after.look.single.isNew), (0, false));
      expect(t.hub.onlineSeenBy, ['Mike']);
      await t.api.onlineSeen('M' * 200);
      expect(t.hub.onlineSeenBy.last, 'M' * 80);
    });
  });

  group('a manager\'s list of checks', () {
    testWidgets('is alerted to an order to look at; opening Online orders is the looking, for every screen', (
      tester,
    ) async {
      final t = await terminal(tester);
      t.hub.online = Hub.onlineStatus(came: 3, byPush: 3, placed: 2, failed: 1, look: [lost()]);
      await pumpOrdersOn(tester, t);
      expect(alertWords(tester), 'Online orders: 1 to look at');
      expect(t.hub.onlineSeenBy, isEmpty); // the alert alone is nobody looking

      await tapKey(tester, 'online-alert');
      expect(find.byType(OnlineOrdersScreen), findsOneWidget);
      expect(t.hub.onlineSeenBy, ['Mike']);
      // it stays listed, and keeps its mark while this screen is open
      expect(rowWords(tester, 'online-look:7781'), 'NOT ON THE POS: it could not be put on the POS (KeyError)');
      expect(find.text('Order 7781 · ${clockTime(ago(4))}'), findsOneWidget);
      expect(key('online-new:7781'), findsOneWidget);
      expect(find.text('3 sent by GloriaFood, 0 asked for by the hub'), findsOneWidget);
      // one that should be on the POS and is not is no check to open
      expect(tester.widget<ListTile>(key('online-look:7781')).onTap, isNull);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(key('online-alert'), findsNothing);
      // the way back to them is in the menu, for as long as the hub takes online orders
      expect(find.byTooltip('Online orders'), findsOneWidget);
      await tester.tap(find.byTooltip('Online orders'));
      await tester.pumpAndSettle();
      expect(key('online-look:7781'), findsOneWidget);
      expect(key('online-new:7781'), findsNothing); // somebody looked: it is new on no screen
      expect(t.hub.onlineSeenBy, ['Mike']); // and nothing new is nothing to tell the hub
      await stop(tester);
    });

    testWidgets('a row that is a check on the POS opens that check', (tester) async {
      final t = await terminal(tester);
      t.hub.orders.add(table('o1', {'L1': line('Egg Roll', course: '1')}));
      t.hub.online = Hub.onlineStatus(came: 1, byPush: 1, placed: 1, look: [short()]);
      await pumpOrdersOn(tester, t);
      await tapKey(tester, 'online-alert');
      expect(
        rowWords(tester, 'online-look:7790'),
        'On the POS: the website charged \$1.00 more than the POS: it is a row on the check',
      );
      await tapKey(tester, 'online-look:7790');
      expect(find.byType(OnlineOrdersScreen), findsNothing);
      expect(find.byType(OrderScreen), findsOneWidget);
      expect(find.text('Egg Roll'), findsWidgets);
      await stop(tester);
    });

    testWidgets('is told in red while none is reaching the POS, and looking does not end that', (tester) async {
      final t = await terminal(tester);
      t.hub.online = Hub.onlineStatus(came: 4, byPush: 0, placed: 4, pushes: false, trouble: [silent()]);
      await pumpOrdersOn(tester, t);
      final words = 'Online orders are not reaching the POS since ${clockTime(ago(9))}';
      expect(alertWords(tester), words);
      final scheme = Theme.of(tester.element(key('online-alert'))).colorScheme;
      final strip = find.descendant(of: key('online-alert'), matching: find.byType(Material)).first;
      expect(tester.widget<Material>(strip).color, scheme.errorContainer);

      await tapKey(tester, 'online-alert');
      expect(key('online-trouble:not_answering'), findsOneWidget);
      expect(find.textContaining('look for new orders in GloriaFood\'s own app'), findsOneWidget);
      expect(rowWords(tester, 'online-pushes'), 'Off: the hub has no key for it. Orders come by the asking alone.');
      expect(t.hub.onlineSeenBy, isEmpty); // there was no order to look at
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(alertWords(tester), words); // it holds until it is mended

      // the website answers again: within the half minute the alert is over by itself
      t.hub.online = Hub.onlineStatus(came: 4, placed: 4, pushes: false, answeredMs: ago(0));
      await tester.pump(const Duration(seconds: 31));
      await tester.pumpAndSettle();
      expect(key('online-alert'), findsNothing);
      await stop(tester);
    });

    testWidgets('a server is alerted to nothing, and the hub is not asked for them', (tester) async {
      final t = await terminal(tester, role: 'server');
      t.hub.online = Hub.onlineStatus(look: [lost()], trouble: [silent()]);
      await pumpOrdersOn(tester, t);
      expect(key('online-alert'), findsNothing);
      await tester.pump(const Duration(seconds: 31));
      await tester.pumpAndSettle();
      expect((shown('online-alert'), t.hub.onlineAsks), (0, 0));

      // a manager signs in on the same screen: alerted at once
      t.session.applySignIn({'staff_id': 's9', 'name': 'Holly', 'role': 'owner', 'method': 'pin'});
      await tester.pumpAndSettle();
      expect(key('online-alert'), findsOneWidget);
      await stop(tester);
    });

    testWidgets('a hub that takes no online orders, or is older than them, shows nothing of them', (tester) async {
      final t = await terminal(tester);
      await pumpOrdersOn(tester, t); // older: 404
      expect((shown('online-alert'), find.byTooltip('Online orders').evaluate().length), (0, 0));
      await stop(tester);

      final off = await terminal(tester);
      off.hub.online = Hub.onlineStatus(asks: false, pushes: false);
      await pumpOrdersOn(tester, off);
      expect((shown('online-alert'), find.byTooltip('Online orders').evaluate().length), (0, 0));
      await stop(tester);
    });

    testWidgets('a hub that cannot write down who looked goes on alerting', (tester) async {
      final t = await terminal(tester);
      t.hub.online = Hub.onlineStatus(came: 1, failed: 1, look: [lost()]);
      t.hub.onlineReadOnly = true;
      await pumpOrdersOn(tester, t);
      await tapKey(tester, 'online-alert');
      expect((shown('online-look:7781'), shown('online-new:7781')), (1, 1));
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(alertWords(tester), 'Online orders: 1 to look at');
      await stop(tester);
    });
  });

  group('the feed', () {
    testWidgets('the hub says there is one to look at: a manager is alerted then, not at the next half minute', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final settings = Settings(
        device: 't1',
        endpoints: ['http://hub:8000'],
        prefs: await SharedPreferences.getInstance(),
      );
      final hub = Hub()..online = Hub.onlineStatus(came: 2, placed: 2);
      final live = LiveHub(hub);
      final api = PosApi(settings, client: live.client);
      final session = Session(api)..staff = const Staff(staffId: 's3', name: 'Mike', role: 'manager', method: 'pin');
      final outbox = Outbox(api, settings, store: MemoryStore());
      final photos = PhotoQueue(api, settings, NoCamera(), session, store: MemoryStore());
      tester.view
        ..physicalSize = const Size(1100, 800)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      api.live.start();
      await pumpOrdersOn(tester, Terminal(hub, api, outbox, photos, session, settings));
      live.hello();
      live.beats();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(key('online-alert'), findsNothing);

      hub.online = Hub.onlineStatus(came: 3, placed: 2, failed: 1, look: [lost()]);
      live.changed(topics: ['online']);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));
      expect(alertWords(tester), 'Online orders: 1 to look at');

      // another manager looked, on another screen: the hub says so, and the alert is over here too
      hub.online = Hub.onlineStatus(came: 3, placed: 2, failed: 1, look: [lost(isNew: false)]);
      live.changed(topics: ['online']);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));
      expect(key('online-alert'), findsNothing);

      await stop(tester);
      live.close();
      api.dispose();
      await tester.pump();
    });
  });

  group('the screen Online orders', () {
    Future<Terminal> pumpScreen(WidgetTester tester, Map<String, dynamic>? status, {Size? size}) async {
      final t = await terminal(tester);
      t.hub.online = status;
      if (size != null) tester.view.physicalSize = size;
      await tester.pumpWidget(
        MaterialApp(
          home: OnlineOrdersScreen(api: t.api, by: 'Mike'),
        ),
      );
      await tester.pumpAndSettle();
      return t;
    }

    testWidgets('says how they arrive, today\'s by what became of them, and that there is nothing to look at', (
      tester,
    ) async {
      final t = await pumpScreen(
        tester,
        Hub.onlineStatus(answeredMs: ago(1), pushedMs: ago(3), came: 12, byPush: 11, placed: 12),
      );
      expect(rowWords(tester, 'online-pushes'), 'On · the last one came ${clockTime(ago(3))}');
      expect(rowWords(tester, 'online-asking'), 'On · GloriaFood last answered ${clockTime(ago(1))}');
      final today = find.descendant(of: key('online-today'), matching: find.byType(Text));
      expect(tester.widgetList<Text>(today).map((text) => text.data), [
        '12',
        'came',
        '12',
        'on the POS',
        '11 sent by GloriaFood, 1 asked for by the hub',
      ]);
      expect(key('online-nothing'), findsOneWidget);
      expect(t.hub.onlineSeenBy, isEmpty);
      await stop(tester);
    });

    testWidgets('lists what did not go on, what could not be read and what waits, on a phone', (tester) async {
      await pumpScreen(
        tester,
        Hub.onlineStatus(
          asks: false,
          pushedMs: ago(3),
          came: 5,
          byPush: 5,
          placed: 2,
          kept: 1,
          failed: 1,
          unread: 1,
          waiting: 1,
          look: [
            lost(),
            Hub.onlineLook(
              'unread-1',
              atMs: ago(6),
              kind: 'unreadable',
              said: 'GloriaFood sent something that is no list of orders: its orders are in GloriaFood\'s app',
            ),
            Hub.onlineLook(
              '7702',
              atMs: ago(30),
              kind: 'delivery',
              state: 'kept',
              said: 'it was for yesterday and reached the hub only now',
              isNew: false,
            ),
          ],
        ),
        size: const Size(360, 780),
      );
      expect(tester.takeException(), isNull); // nothing overflows on the narrowest phone
      expect(
        rowWords(tester, 'online-asking'),
        'Off: the hub has no key for it. Nothing brings an order that gets lost on the way.',
      );
      final today = find.descendant(of: key('online-today'), matching: find.byType(Text));
      expect(tester.widgetList<Text>(today).map((text) => text.data), [
        '5',
        'came',
        '2',
        'on the POS',
        '1',
        'not for the POS',
        '1',
        'could not be put on',
        '1',
        'waiting',
        '5 sent by GloriaFood, 0 asked for by the hub',
        '1 thing the website sent could not be read (below)',
      ]);
      await tester.scrollUntilVisible(key('online-look:7702'), 200, scrollable: find.byType(Scrollable).first);
      expect(rowWords(tester, 'online-look:unread-1'), startsWith('Could not be read: GloriaFood sent something'));
      expect(find.textContaining('Something the website sent · '), findsOneWidget);
      expect(rowWords(tester, 'online-look:7702'), 'Not on the POS: it was for yesterday and reached the hub only now');
      expect((shown('online-new:7781'), shown('online-new:unread-1'), shown('online-new:7702')), (1, 1, 0));
      // opened by itself (from Location), a row opens nothing
      expect(tester.widget<ListTile>(key('online-look:7781')).onTap, isNull);
      await stop(tester);
    });

    String askedWords(WidgetTester tester) => tester.widget<Text>(key('online-asked')).data!;
    bool askedInRed(WidgetTester tester) {
      final text = tester.widget<Text>(key('online-asked'));
      return text.style?.color == Theme.of(tester.element(key('online-asked'))).colorScheme.error;
    }

    testWidgets('Ask now asks the website this moment and says what came of it', (tester) async {
      final t = await pumpScreen(tester, Hub.onlineStatus(answeredMs: ago(2), came: 1, placed: 1));
      expect((shown('online-ask'), shown('online-asked')), (1, 0));
      expect(find.descendant(of: key('online-ask'), matching: find.text('Ask now')), findsOneWidget);
      // the hub asks, an order comes and goes on the POS; while it asks, the button is a spinner
      t.hub.onlineFetched = {...t.hub.onlineFetched, 'came': 1, 'placed': 1};
      t.hub.onlineOnFetch = () => t.hub.online = Hub.onlineStatus(answeredMs: ago(0), came: 2, placed: 2);
      final held = t.hub.onlineFetchHeld = Completer<void>();
      final reads = t.hub.onlineAsks;
      await tester.tap(key('online-ask'));
      await tester.pump();
      expect((tester.widget<TextButton>(key('online-ask')).onPressed, shown('online-ask-busy')), (null, 1));
      expect(find.text('Asking GloriaFood'), findsOneWidget);
      await tester.tap(key('online-ask'), warnIfMissed: false); // a second press while it asks is no second asking
      await tester.pump();
      held.complete();
      t.hub.onlineFetchHeld = null;
      await tester.pumpAndSettle();
      expect((tester.widget<TextButton>(key('online-ask')).onPressed != null, shown('online-ask-busy')), (true, 0));
      expect(t.hub.onlineFetches, 1);
      expect((askedWords(tester), askedInRed(tester)), ('1 order came. 1 put on the POS.', false));
      // how they stand now came with the answer: the figures move with no second read
      final today = find.descendant(of: key('online-today'), matching: find.byType(Text));
      expect(tester.widgetList<Text>(today).map((text) => text.data).take(4), ['2', 'came', '2', 'on the POS']);
      expect(rowWords(tester, 'online-asking'), 'On · GloriaFood last answered ${clockTime(ago(0))}');
      expect(t.hub.onlineAsks, reads);
      // asked again: nothing new this time, and the words say that
      t.hub.onlineFetched = {...t.hub.onlineFetched, 'came': 0, 'placed': 0};
      await tapKey(tester, 'online-ask');
      expect((t.hub.onlineFetches, askedWords(tester)), (2, 'GloriaFood has no new order.'));
      await stop(tester);
    });

    testWidgets('Ask now says so when the website was just asked, did not answer, or no hub answers', (tester) async {
      final t = await pumpScreen(tester, Hub.onlineStatus(answeredMs: ago(1)));
      t.hub.onlineFetched = {...t.hub.onlineFetched, 'asked': false, 'answered': false, 'soon': true};
      await tapKey(tester, 'online-ask');
      expect(
        (askedWords(tester), askedInRed(tester)),
        ('GloriaFood was asked a few seconds ago. Wait a moment and ask again.', false),
      );
      t.hub.onlineFetched = {
        ...t.hub.onlineFetched,
        'asked': true,
        'soon': false,
        'reason': 'GloriaFood could not be reached (ConnectError)',
      };
      await tapKey(tester, 'online-ask');
      expect(
        (askedWords(tester), askedInRed(tester)),
        ('GloriaFood could not be reached (ConnectError). The hub asks again by itself within the minute.', true),
      );
      // an order that came and could not be put on the POS: in red, it is new, and looking is told the hub
      t.hub.onlineFetched = {...Hub().onlineFetched, 'came': 1, 'failed': 1};
      t.hub.onlineOnFetch = () => t.hub.online = Hub.onlineStatus(came: 1, failed: 1, look: [lost()]);
      await tapKey(tester, 'online-ask');
      expect((askedWords(tester), askedInRed(tester)), ('1 order came. 1 could not be put on (see To look at).', true));
      expect((shown('online-look:7781'), shown('online-new:7781')), (1, 1));
      expect(t.hub.onlineSeenBy, ['Mike']);
      // no hub answers: said, and what was read stays
      t.hub.onlineDown = true;
      final presses = t.hub.onlineFetches;
      await tapKey(tester, 'online-ask');
      expect(
        (askedWords(tester), askedInRed(tester), t.hub.onlineFetches),
        ('The hub is not answering, so GloriaFood was not asked.', true, presses),
      );
      expect(shown('online-look:7781'), 1);
      await stop(tester);
    });

    testWidgets('only a hub that asks has the button, and it fits a small phone', (tester) async {
      // orders are sent by GloriaFood only: the hub has no key to ask with
      await pumpScreen(tester, Hub.onlineStatus(asks: false, pushedMs: ago(3)));
      expect((shown('online-asking'), shown('online-ask')), (1, 0));
      await stop(tester);
      await pumpScreen(tester, Hub.onlineStatus(asks: false, pushes: false)); // off altogether
      expect(shown('online-ask'), 0);
      await stop(tester);
      // the minute's round has stopped: asking by hand is what is left
      final t = await pumpScreen(tester, Hub.onlineStatus(running: false), size: const Size(320, 568));
      expect(rowWords(tester, 'online-asking'), 'NOT RUNNING. On the hub: sudo hubctl restart');
      t.hub.onlineFetched = {...t.hub.onlineFetched, 'came': 12, 'known': 3, 'placed': 8, 'kept': 1, 'failed': 1};
      await tapKey(tester, 'online-ask');
      expect(t.hub.onlineFetches, 1);
      expect(
        askedWords(tester),
        '12 orders came, 3 of them here already. 8 put on the POS, 1 not for the POS, 1 could not be put on (see To '
        'look at).',
      );
      expect(tester.takeException(), isNull);
      await stop(tester);
    });

    testWidgets('says so when online orders are off, when the hub is older, and when no hub answers', (tester) async {
      await pumpScreen(tester, Hub.onlineStatus(asks: false, pushes: false));
      expect(key('online-off'), findsOneWidget);
      expect((shown('online-pushes'), shown('online-today'), shown('online-nothing')), (0, 0, 0));
      await stop(tester);

      await pumpScreen(tester, null);
      expect(key('online-older'), findsOneWidget);
      await stop(tester);

      final t = await terminal(tester);
      t.hub.online = Hub.onlineStatus(came: 1, placed: 1);
      t.hub.onlineDown = true;
      await tester.pumpWidget(
        MaterialApp(
          home: OnlineOrdersScreen(api: t.api, by: 'Mike'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('The hub is not answering'), findsOneWidget);
      t.hub.onlineDown = false;
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(key('online-today'), findsOneWidget);
      // it goes away again: what was read stays, and the screen says how old it is
      t.hub.onlineDown = true;
      await tapKey(tester, 'online-refresh');
      expect((shown('online-away'), shown('online-today')), (1, 1));
      await stop(tester);
    });

    testWidgets('one that comes while the screen is open is marked new, and the hub is told again', (tester) async {
      final t = await pumpScreen(tester, Hub.onlineStatus(came: 1, placed: 1));
      expect(key('online-nothing'), findsOneWidget);
      t.hub.online = Hub.onlineStatus(came: 2, placed: 1, failed: 1, look: [lost()]);
      await tester.pump(const Duration(seconds: 31));
      await tester.pumpAndSettle();
      expect((shown('online-look:7781'), shown('online-new:7781')), (1, 1));
      expect(t.hub.onlineSeenBy, ['Mike']);
      await stop(tester);
    });
  });

  group('under Location', () {
    Future<Terminal> pumpLocation(WidgetTester tester, Map<String, dynamic>? status) async {
      final t = await terminal(tester);
      t.hub.online = status;
      await tester.pumpWidget(
        MaterialApp(
          home: LocationSettingsScreen(api: t.api, token: 'tok-admin', device: 't1', by: 'Mike'),
        ),
      );
      await tester.pumpAndSettle();
      await bringUp(tester, 'online-orders');
      return t;
    }

    testWidgets('the row says how they stand and opens the screen; coming back, it says it again', (tester) async {
      final t = await pumpLocation(tester, Hub.onlineStatus(came: 3, placed: 2, failed: 1, look: [lost()]));
      expect(rowWords(tester, 'online-orders'), 'Online orders: 1 to look at');
      await tapKey(tester, 'online-orders');
      expect(find.byType(OnlineOrdersScreen), findsOneWidget);
      expect(key('online-new:7781'), findsOneWidget); // new until this very look
      expect(t.hub.onlineSeenBy, ['Mike']);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(rowWords(tester, 'online-orders'), 'Today 3 came, 2 on the POS · 1 to look at');
      await stop(tester);
    });

    testWidgets('a hub older than online orders says so, and the row opens nothing', (tester) async {
      await pumpLocation(tester, null);
      expect(
        rowWords(tester, 'online-orders'),
        'The hub has not answered about online orders (an older hub: update it)',
      );
      expect(tester.widget<ListTile>(key('online-orders')).onTap, isNull);
      await stop(tester);
    });
  });
}
