import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/camera.dart';
import 'package:pos_app/outbox.dart';
import 'package:pos_app/photos.dart';
import 'package:pos_app/queue_store.dart';
import 'package:pos_app/screens/order_screen.dart';
import 'package:pos_app/session.dart';
import 'package:pos_app/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'counter_test.dart' show takeout;
import 'customers_test.dart' show tagsIn;
import 'hub.dart';
import 'table_moves_test.dart' show checkAt;
import 'table_servers_test.dart' show amy;
import 'waitlist_test.dart' show key, pumpFloorWith, seatFromList, tapKey;

/// Tags at the table (the Toast comparison, 2026-11-24): a guest who carries a tag in the guest list ("VIP")
/// and is seated from their reservation or the waitlist brings the tag to the table's check, where whoever
/// serves the table sees it in the strip under the bar. The check itself carries no number and no name: the
/// hub finds the guest through the reservation or the party the host sat down on the check
/// (`GET /orders/{id}/tags`).

const linda = '7815550101';
const omar = '7815550102';
const strip = 'customer-note-strip';

/// Monday at seven in the evening on the hub's clock.
final seven = DateTime(2026, 11, 16, 19).millisecondsSinceEpoch;

/// A reservation whose party sits at [table] on the check [orderId].
Map<String, dynamic> seatedBooking(String id, String name, String phone, String orderId, {String table = 'A7'}) => {
  ...Hub.booking(id, name, 2, time: '18:30', phone: phone),
  'status': 'seated',
  'seated_ms': seven,
  'seated_table': table,
  'seated_label': table,
  'order_id': orderId,
};

/// A party of the waitlist that sits at [table] on the check [orderId].
Map<String, dynamic> seatedParty(String id, String name, String phone, String orderId, {String table = 'A7'}) => {
  ...Hub.waitParty(id, name, 2, atMs: seven - 20 * 60000, phone: phone),
  'status': 'seated',
  'seated_ms': seven,
  'table': table,
  'table_label': table,
  'order_id': orderId,
};

/// A7's check with an egg roll on it.
Map<String, dynamic> a7([Map<String, dynamic> fields = const {}]) {
  final check = checkAt('o1', 'A7', {'M1': line('Egg roll', rank: 1)});
  return {
    ...check,
    'fields': <String, dynamic>{...check['fields'] as Map, ...fields},
  };
}

/// A hub where Linda (a VIP and a catering client) booked and sits at A7 on the check `o1`.
void lindaAtA7(Hub hub) => hub
  ..ringTags = {
    linda: ['Catering client', 'VIP'],
  }
  ..bookings = [seatedBooking('b1', 'Linda P.', '781 555 0101', 'o1')]
  ..parties = [];

/// The check `o1` on the screen, on a hub that [hub] set up.
Future<Terminal> pumpCheck(
  WidgetTester tester, {
  void Function(Hub hub)? hub,
  Map<String, dynamic>? order,
  Size? size,
  double textScale = 1,
  bool dark = false,
}) async {
  final t = await terminal(tester);
  if (size != null) tester.view.physicalSize = size;
  t.hub
    ..clockNow = seven
    ..orders.add(order ?? a7());
  hub?.call(t.hub);
  await tester.pumpWidget(
    MaterialApp(
      theme: dark ? ThemeData.dark() : null,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: OrderScreen(api: t.api, outbox: t.outbox, photos: t.photos, orderId: 'o1', staffName: 'Amy'),
    ),
  );
  await tester.pumpAndSettle();
  return t;
}

void main() {
  group('the call', () {
    test('the tags of the guests seated on a check, and what an older hub and no hub answer', () async {
      SharedPreferences.setMockInitialValues({});
      final settings = Settings(
        device: 't1',
        endpoints: ['http://hub:8000'],
        prefs: await SharedPreferences.getInstance(),
      );
      final hub = Hub();
      lindaAtA7(hub);
      final api = PosApi(settings, client: MockClient(hub.handle));
      expect(await api.tableTags('o1'), ['Catering client', 'VIP']);
      expect(await api.tableTags('o2'), isEmpty); // a check nobody was seated on
      expect(hub.requests.where((r) => r.contains('/tags')), ['GET /orders/o1/tags', 'GET /orders/o2/tags']);
      hub.tableTagsDown = true;
      expect(await api.tableTags('o1'), isNull); // nothing answers: a screen keeps what it has
      hub
        ..tableTagsDown = false
        ..ringTags = null;
      expect(await api.tableTags('o1'), isEmpty); // a hub older than this: no tags, as before
      expect(hub.tableTagAsks, ['o1', 'o2']);
    });
  });

  group('on the check of a table', () {
    testWidgets('a party seated from its reservation: the check says the guest\'s tags and nothing else', (
      tester,
    ) async {
      final t = await pumpCheck(tester, hub: lindaAtA7);
      expect(key(strip), findsOneWidget);
      expect(tagsIn(tester, strip), ['Catering client', 'VIP']);
      // the words alone: no name, no number and no note of the guest
      expect(find.textContaining('Customer note'), findsNothing);
      expect(find.textContaining('Linda'), findsNothing);
      expect(find.textContaining('0101'), findsNothing);
      expect(t.hub.tableTagAsks, ['o1']);
      expect(t.hub.requests.where((r) => r.contains('/customers/')), isEmpty); // the check has no number to ask about
      // the check is read again and again: its guests' tags once, then every half minute
      await tester.pump(const Duration(seconds: 20));
      await tester.pump();
      expect(t.hub.tableTagAsks, ['o1']);
      await tester.pump(const Duration(seconds: 10));
      await tester.pump();
      expect(t.hub.tableTagAsks, ['o1', 'o1']);
      expect(t.hub.sent, isEmpty); // seeing them wrote nothing onto the check
      await stop(tester);
    });

    testWidgets('a party seated from the waitlist brings its tags the same way', (tester) async {
      await pumpCheck(
        tester,
        hub: (hub) => hub
          ..ringTags = {
            omar: ['Regular'],
          }
          ..bookings = []
          ..parties = [seatedParty('p1', 'Omar', '781-555-0102', 'o1')],
      );
      expect(tagsIn(tester, strip), ['Regular']);
      await stop(tester);
    });

    testWidgets('a party that joined the table adds its tags, each tag once', (tester) async {
      await pumpCheck(
        tester,
        hub: (hub) => hub
          ..ringTags = {
            linda: ['Catering client', 'VIP'],
            omar: ['Regular', 'VIP'],
          }
          ..bookings = [seatedBooking('b1', 'Linda P.', linda, 'o1')]
          ..parties = [seatedParty('p1', 'Omar', omar, 'o1')],
      );
      expect(tagsIn(tester, strip), ['Catering client', 'Regular', 'VIP']);
      await stop(tester);
    });

    testWidgets('nobody was seated on the check, or nobody tagged them: no strip', (tester) async {
      // Linda sits at another table, and the party at this one left no number
      var t = await pumpCheck(
        tester,
        hub: (hub) => hub
          ..ringTags = {
            linda: ['VIP'],
          }
          ..bookings = [seatedBooking('b1', 'Linda P.', linda, 'o2', table: 'A8'), seatedBooking('b2', 'Wu', '', 'o1')]
          ..parties = [],
      );
      expect(key(strip), findsNothing);
      expect(t.hub.tableTagAsks, ['o1']);
      await stop(tester);
      // a walk-in: no reservation and no party behind the check
      t = await pumpCheck(
        tester,
        hub: (hub) => hub
          ..ringTags = {
            linda: ['VIP'],
          }
          ..bookings = []
          ..parties = [],
      );
      expect(key(strip), findsNothing);
      expect(tester.takeException(), isNull);
      await stop(tester);
    });

    testWidgets('a to-go order and a bar tab have nobody seated: they do not ask', (tester) async {
      var t = await pumpCheck(
        tester,
        hub: lindaAtA7,
        order: takeout('o1', no: 12, name: 'Linda', channel: 'phone'),
      );
      await tester.pump(const Duration(seconds: 31));
      await tester.pump();
      expect(t.hub.tableTagAsks, isEmpty);
      expect(key(strip), findsNothing);
      await stop(tester);
      t = await pumpCheck(
        tester,
        hub: lindaAtA7,
        order: {
          'order_id': 'o1',
          'status': 'open',
          'fields': {'tab': true, 'order_type': 'dine_in', 'customer_name': 'Linda'},
          'lines': <String, dynamic>{},
          'fired': <String, dynamic>{},
        },
      );
      await tester.pump(const Duration(seconds: 31));
      await tester.pump();
      expect(t.hub.tableTagAsks, isEmpty);
      await stop(tester);
    });

    testWidgets('a check that has a number too: the customer\'s tags and note, then the table\'s, each once', (
      tester,
    ) async {
      await pumpCheck(
        tester,
        order: a7({'phone': '781 555 0102', 'customer_name': 'Omar'}),
        hub: (hub) {
          lindaAtA7(hub);
          hub.customers[omar] = {
            'phone': omar,
            'known': true,
            'name': 'Omar',
            'note': 'no MSG',
            'tags': ['Regular', 'vip'],
            'orders': 3,
            'recent': <dynamic>[],
          };
        },
      );
      expect(tagsIn(tester, strip), ['Regular', 'vip', 'Catering client']);
      expect(find.text('Customer note: no MSG'), findsOneWidget);
      await stop(tester);
    });

    testWidgets('a hub older than this: the check is as it was', (tester) async {
      final t = await pumpCheck(
        tester,
        hub: (hub) => hub
          ..bookings = [seatedBooking('b1', 'Linda P.', linda, 'o1')]
          ..parties = [],
      );
      expect(key(strip), findsNothing);
      expect(find.text('Egg roll'), findsWidgets);
      expect(tester.takeException(), isNull);
      expect(t.hub.tableTagAsks, isEmpty); // it asked, and the hub had no word for it
      expect(t.hub.requests, contains('GET /orders/o1/tags'));
      await stop(tester);
    });

    testWidgets('tags changed in the guest list show on the check within half a minute', (tester) async {
      final t = await pumpCheck(tester, hub: lindaAtA7);
      expect(tagsIn(tester, strip), ['Catering client', 'VIP']);
      t.hub.ringTags![linda] = ['Allergy: shellfish', 'VIP'];
      await tester.pump(const Duration(seconds: 30));
      await tester.pump();
      expect(tagsIn(tester, strip), ['Allergy: shellfish', 'VIP']);
      // the party is put back in the book: the check is nobody's again
      t.hub.bookings!.single.addAll({'status': 'booked', 'seated_ms': null, 'order_id': ''});
      await tester.pump(const Duration(seconds: 30));
      await tester.pump();
      expect(key(strip), findsNothing);
      await stop(tester);
    });

    testWidgets('the hub does not answer for a while: the check keeps the tags it has', (tester) async {
      final t = await pumpCheck(tester, hub: lindaAtA7);
      t.hub.tableTagsDown = true;
      await tester.pump(const Duration(seconds: 30));
      await tester.pump();
      expect(tagsIn(tester, strip), ['Catering client', 'VIP']);
      expect(tester.takeException(), isNull);
      await stop(tester);
    });

    testWidgets('on a small phone, in the dark and with large type, six long tags all stay on the strip', (
      tester,
    ) async {
      const tags = [
        'Allergy: shellfish',
        'Catering client',
        'Friend of the house',
        'Knows the owner well',
        'Sushi counter regular',
        'VIP',
      ];
      for (final (dark, scale) in [(false, 1.0), (true, 1.0), (false, 1.5)]) {
        await pumpCheck(
          tester,
          size: const Size(320, 568),
          dark: dark,
          textScale: scale,
          hub: (hub) => hub
            ..ringTags = {linda: tags}
            ..bookings = [seatedBooking('b1', 'Linda P.', linda, 'o1')]
            ..parties = [],
        );
        expect(tester.takeException(), isNull, reason: 'dark $dark, type $scale'); // nothing runs off the screen
        final whole = tester.getRect(key(strip));
        expect(whole.width, 320);
        expect(tagsIn(tester, strip), tags);
        for (final tag in tags) {
          final mark = tester.getRect(key('customer-tag:$tag'));
          expect(mark.left >= whole.left && mark.right <= whole.right, isTrue, reason: '$tag at $mark');
          expect(mark.top >= whole.top && mark.bottom <= whole.bottom, isTrue, reason: '$tag at $mark');
        }
        await stop(tester);
      }
    });
  });

  group('told by the hub', () {
    Future<(LiveHub, Terminal)> liveCheck(WidgetTester tester, void Function(Hub hub) setUp) async {
      SharedPreferences.setMockInitialValues({});
      final settings = Settings(
        device: 't1',
        endpoints: ['http://hub:8000'],
        prefs: await SharedPreferences.getInstance(),
      );
      final hub = Hub()
        ..clockNow = seven
        ..orders.add(a7());
      setUp(hub);
      final live = LiveHub(hub);
      final api = PosApi(settings, client: live.client);
      final session = Session(api)..staff = const Staff(staffId: 's1', name: 'Amy', role: 'server', method: 'pin');
      final outbox = Outbox(api, settings, store: MemoryStore());
      final photos = PhotoQueue(api, settings, NoCamera(), session, store: MemoryStore());
      tester.view
        ..physicalSize = const Size(1100, 800)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      api.live.start();
      await tester.pumpWidget(
        MaterialApp(
          home: OrderScreen(api: api, outbox: outbox, photos: photos, orderId: 'o1', staffName: 'Amy'),
        ),
      );
      await tester.pumpAndSettle();
      live.hello();
      live.beats();
      await tester.pumpAndSettle();
      expect(api.live.isLive, isTrue);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      return (live, Terminal(hub, api, outbox, photos, session, settings));
    }

    Future<void> finish(WidgetTester tester, LiveHub live, Terminal t) async {
      await stop(tester);
      live.close();
      t.api.dispose();
      await tester.pump();
    }

    testWidgets('a party sits down on a check that is open: its tags are there at once', (tester) async {
      final (live, t) = await liveCheck(
        tester,
        (hub) => hub
          ..ringTags = {
            linda: ['VIP'],
            omar: ['Regular'],
          }
          ..bookings = []
          ..parties = [],
      );
      expect(key(strip), findsNothing);

      // the host seats Linda's reservation on this check: the hub says the book changed
      t.hub.bookings!.add(seatedBooking('b1', 'Linda P.', linda, 'o1'));
      live.changed(topics: ['reservations']);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));
      expect(tagsIn(tester, strip), ['VIP']);

      // a party of the waitlist joins the table
      t.hub.parties!.add(seatedParty('p1', 'Omar', omar, 'o1'));
      live.changed(topics: ['waitlist']);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));
      expect(tagsIn(tester, strip), ['Regular', 'VIP']);

      // a manager takes Linda's tag off in the guest list: the hub tells the book and the list to read again
      t.hub.ringTags!.remove(linda);
      live.changed(topics: ['reservations', 'waitlist']);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));
      expect(tagsIn(tester, strip), ['Regular']);

      // what is none of this check's business asks nothing
      final asks = t.hub.tableTagAsks.length;
      live.changed(topics: ['menu', 'settings', 'notes']);
      live.changed(orders: ['o9']);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));
      expect(t.hub.tableTagAsks.length, asks);
      await finish(tester, live, t);
    });
  });

  group('from the door to the table', () {
    testWidgets('a server seats a tagged party from the waitlist: the check that opens says their tags', (
      tester,
    ) async {
      final t = await pumpFloorWith(
        tester,
        amy,
        hub: (hub) => hub
          ..bookings = []
          ..ringTags = {
            omar: ['Regular', 'VIP'],
          },
      );
      await seatFromList(tester, 'p1'); // Garcia, who left the number 781 555 0102
      await tester.tap(find.text('A8'));
      await tester.pumpAndSettle();
      await tapKey(tester, 'seat');
      expect(find.byType(OrderScreen), findsOneWidget);
      final seated = t.hub.parties!.firstWhere((p) => p['id'] == 'p1');
      expect(t.hub.tableTagAsks, contains(seated['order_id']));
      expect(tagsIn(tester, strip), ['Regular', 'VIP']);
      // the check was opened as every table's is: nothing of the guest went onto it
      final create = t.hub.sent.firstWhere((sent) => sent.$2['kind'] == 'create').$2;
      expect(create.toString(), isNot(contains('0102')));
      expect(create.toString(), isNot(contains('Garcia')));
      expect(create.toString(), isNot(contains('VIP')));
      await stop(tester);
    });
  });
}
