import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/camera.dart';
import 'package:pos_app/outbox.dart';
import 'package:pos_app/photos.dart';
import 'package:pos_app/queue_store.dart';
import 'package:pos_app/screens/order_screen.dart';
import 'package:pos_app/seated.dart';
import 'package:pos_app/session.dart';
import 'package:pos_app/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'counter_test.dart' show takeout;
import 'customers_test.dart' show tagsIn;
import 'hub.dart';
import 'table_moves_test.dart' show checkAt;
import 'table_servers_test.dart' show amy;
import 'waitlist_test.dart' show key, pumpFloorWith, seatFromList, tapKey;

/// At the table (the Toast comparison, 2026-11-24): a party the host seats from its reservation or from the
/// waitlist is known at its table. The table's check says, in the strip under the bar, whose table it is,
/// the tags that guest carries in the guest list ("VIP") and the note written on the reservation or the
/// party ("Window table, birthday"), for whoever serves the table. The check itself carries none of it: the
/// hub finds the party through the reservation or the line of the waitlist it was seated from
/// (`GET /orders/{id}/seated`; from a hub that says the tags and not yet who, `GET /orders/{id}/tags`).

const linda = '7815550101';
const omar = '7815550102';
const strip = 'customer-note-strip';

/// Monday at seven in the evening on the hub's clock.
final seven = DateTime(2026, 11, 16, 19).millisecondsSinceEpoch;

/// A reservation whose party sits at [table] on the check [orderId].
Map<String, dynamic> seatedBooking(
  String id,
  String name,
  String phone,
  String orderId, {
  String table = 'A7',
  String note = '',
  int? seatedMs,
}) => {
  ...Hub.booking(id, name, 2, time: '18:30', phone: phone, note: note),
  'status': 'seated',
  'seated_ms': seatedMs ?? seven,
  'seated_table': table,
  'seated_label': table,
  'order_id': orderId,
};

/// A party of the waitlist that sits at [table] on the check [orderId].
Map<String, dynamic> seatedParty(
  String id,
  String name,
  String phone,
  String orderId, {
  String table = 'A7',
  String note = '',
  int? seatedMs,
}) => {
  ...Hub.waitParty(id, name, 2, atMs: seven - 20 * 60000, phone: phone, note: note),
  'status': 'seated',
  'seated_ms': seatedMs ?? seven,
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

/// A hub where Linda (a VIP and a catering client) booked the window table for a birthday and sits at A7 on
/// the check `o1`.
void lindaAtA7(Hub hub) => hub
  ..ringTags = {
    linda: ['Catering client', 'VIP'],
  }
  ..bookings = [seatedBooking('b1', 'Linda P.', '781 555 0101', 'o1', note: 'Window table, birthday')]
  ..parties = [];

/// The same hub before it learnt to say who sits: it says the table's tags and no more.
void tagsAlone(Hub hub) {
  lindaAtA7(hub);
  hub.seatedCall = false;
}

String said(WidgetTester tester, String name) => tester.widget<Text>(key(name)).data!;

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
  group('the calls', () {
    Future<(Hub, PosApi)> hubAndApi() async {
      SharedPreferences.setMockInitialValues({});
      final settings = Settings(
        device: 't1',
        endpoints: ['http://hub:8000'],
        prefs: await SharedPreferences.getInstance(),
      );
      final hub = Hub();
      lindaAtA7(hub);
      return (hub, PosApi(settings, client: MockClient(hub.handle)));
    }

    test('who sits on a check: each party with its name, its note and its tags', () async {
      final (hub, api) = await hubAndApi();
      hub.parties!.add(seatedParty('p1', 'Omar', omar, 'o1', note: 'High chair', seatedMs: seven + 60000));
      final table = (await api.tableGuests('o1'))!;
      expect(table.parties, const [
        SeatedParty(
          name: 'Linda P.',
          size: 2,
          note: 'Window table, birthday',
          tags: ['Catering client', 'VIP'],
          booked: true,
        ),
        SeatedParty(name: 'Omar', size: 2, note: 'High chair'),
      ]);
      expect(table.tags, ['Catering client', 'VIP']);
      expect((await api.tableGuests('o2'))!.isEmpty, isTrue); // a check nobody was seated on
      expect(hub.seatedAsks, ['o1', 'o2']);
      expect(hub.tableTagAsks, isEmpty); // the one call says it all
    });

    test('a hub that says the tags and not who, an older one still, and none at all', () async {
      final (hub, api) = await hubAndApi();
      hub.seatedCall = false;
      expect(await api.tableGuests('o1'), const TableGuests(tags: ['Catering client', 'VIP']));
      expect(hub.requests.where((r) => r.contains('/o1/')), ['GET /orders/o1/seated', 'GET /orders/o1/tags']);
      hub.ringTags = null; // older than the tags at the table too
      expect(await api.tableGuests('o1'), TableGuests.none);
      hub
        ..seatedCall = true
        ..tableTagsDown = true;
      expect(await api.tableGuests('o1'), isNull); // nothing answers: a screen keeps what it has
    });

    test('the tags alone, as the call before this one answers them', () async {
      final (hub, api) = await hubAndApi();
      expect(await api.tableTags('o1'), ['Catering client', 'VIP']);
      expect(await api.tableTags('o2'), isEmpty);
      hub.tableTagsDown = true;
      expect(await api.tableTags('o1'), isNull);
      hub
        ..tableTagsDown = false
        ..ringTags = null;
      expect(await api.tableTags('o1'), isEmpty);
      expect(hub.tableTagAsks, ['o1', 'o2']);
    });

    test('what the hub sends is read with care', () {
      final table = TableGuests.fromJson({
        'parties': [
          {'from': 'waitlist', 'name': '  Chen ', 'size': 4, 'note': ' High chair ', 'tags': null},
          {'from': 'reservation', 'name': '', 'size': 2, 'note': '', 'tags': <String>[]}, // nothing to show
          'nonsense',
        ],
      });
      expect(table.parties, const [SeatedParty(name: 'Chen', size: 4, note: 'High chair')]);
      expect(table.tags, isEmpty);
      expect(TableGuests.fromJson(const {}), TableGuests.none);
    });
  });

  group('on the check of a table', () {
    testWidgets('a party seated from its reservation: whose table it is, their tags and the note', (tester) async {
      final t = await pumpCheck(tester, hub: lindaAtA7);
      expect(key(strip), findsOneWidget);
      expect(said(tester, 'seated-name:0'), 'Linda P.');
      expect(tagsIn(tester, 'seated-party:0'), ['Catering client', 'VIP']);
      expect(said(tester, 'seated-note:0'), 'Window table, birthday');
      // read from left to right: the name, the labels, the note
      final name = tester.getRect(key('seated-name:0'));
      final vip = tester.getRect(key('seated-tag:0:VIP'));
      final note = tester.getRect(key('seated-note:0'));
      expect(name.right <= vip.left && vip.right <= note.left, isTrue);
      expect(tester.getSize(key(strip)).height, lessThan(30)); // one line on a tablet
      // not the number, and not the line the restaurant keeps about a customer
      expect(find.textContaining('0101'), findsNothing);
      expect(find.textContaining('Customer note'), findsNothing);
      expect(t.hub.seatedAsks, ['o1']);
      expect(t.hub.requests.where((r) => r.contains('/customers/')), isEmpty); // the check has no number to ask about
      // the check is read again and again: who sits on it once, then every half minute
      await tester.pump(const Duration(seconds: 20));
      await tester.pump();
      expect(t.hub.seatedAsks, ['o1']);
      await tester.pump(const Duration(seconds: 10));
      await tester.pump();
      expect(t.hub.seatedAsks, ['o1', 'o1']);
      expect(t.hub.tableTagAsks, isEmpty);
      expect(t.hub.sent, isEmpty); // seeing them wrote nothing onto the check
      await stop(tester);
    });

    testWidgets('a party seated from the waitlist is named the same way', (tester) async {
      await pumpCheck(
        tester,
        hub: (hub) => hub
          ..ringTags = {
            omar: ['Regular'],
          }
          ..bookings = []
          ..parties = [seatedParty('p1', 'Omar', '781-555-0102', 'o1')],
      );
      expect(said(tester, 'seated-name:0'), 'Omar');
      expect(tagsIn(tester, strip), ['Regular']);
      expect(key('seated-note:0'), findsNothing); // listed with no note
      await stop(tester);
    });

    testWidgets('a party with no number and no tag is still named, with its note', (tester) async {
      await pumpCheck(
        tester,
        hub: (hub) => hub
          ..bookings = [seatedBooking('b2', 'Wu', '', 'o1', note: 'High chair')]
          ..parties = [],
      );
      expect(said(tester, 'seated-name:0'), 'Wu');
      expect(said(tester, 'seated-note:0'), 'High chair');
      expect(tagsIn(tester, strip), isEmpty);
      await stop(tester);
    });

    testWidgets('two parties at one table stand each on a line of its own, with its own tags', (tester) async {
      await pumpCheck(
        tester,
        hub: (hub) => hub
          ..ringTags = {
            linda: ['Catering client', 'VIP'],
            omar: ['Regular', 'VIP'],
          }
          ..bookings = [seatedBooking('b1', 'Linda P.', linda, 'o1', note: 'Window table')]
          ..parties = [seatedParty('p1', 'Omar', omar, 'o1', seatedMs: seven + 60000)],
      );
      expect((said(tester, 'seated-name:0'), said(tester, 'seated-name:1')), ('Linda P.', 'Omar'));
      expect(tagsIn(tester, 'seated-party:0'), ['Catering client', 'VIP']);
      expect(tagsIn(tester, 'seated-party:1'), ['Regular', 'VIP']); // whose VIP it is can be read
      expect(tester.getRect(key('seated-party:0')).bottom <= tester.getRect(key('seated-party:1')).top, isTrue);
      await stop(tester);
    });

    testWidgets('nobody was seated on the check: no strip', (tester) async {
      // Linda sits at another table, and this one is a walk-in's
      final t = await pumpCheck(
        tester,
        hub: (hub) => hub
          ..ringTags = {
            linda: ['VIP'],
          }
          ..bookings = [seatedBooking('b1', 'Linda P.', linda, 'o2', table: 'A8')]
          ..parties = [],
      );
      expect(key(strip), findsNothing);
      expect(t.hub.seatedAsks, ['o1']);
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
      expect(t.hub.seatedAsks, isEmpty);
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
      expect(t.hub.seatedAsks, isEmpty);
      expect(t.hub.tableTagAsks, isEmpty);
      await stop(tester);
    });

    testWidgets('a check that has a number too: that customer\'s tags and note first, then who sits', (tester) async {
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
            'tags': ['Regular'],
            'orders': 3,
            'recent': <dynamic>[],
          };
        },
      );
      expect(tagsIn(tester, strip), ['Regular', 'Catering client', 'VIP']);
      expect(find.text('Customer note: no MSG'), findsOneWidget);
      expect(said(tester, 'seated-name:0'), 'Linda P.');
      expect(
        tester.getRect(find.text('Customer note: no MSG')).bottom <= tester.getRect(key('seated-party:0')).top,
        isTrue,
      );
      await stop(tester);
    });

    testWidgets('a hub that says the tags and not who: the tags alone, as before', (tester) async {
      final t = await pumpCheck(tester, hub: tagsAlone);
      expect(tagsIn(tester, strip), ['Catering client', 'VIP']);
      expect(key('seated-name:0'), findsNothing);
      expect(find.textContaining('Linda'), findsNothing);
      expect(find.textContaining('Window'), findsNothing);
      expect(t.hub.tableTagAsks, ['o1']);
      await stop(tester);
    });

    testWidgets('such a hub, and a check with a number too: every tag once', (tester) async {
      await pumpCheck(
        tester,
        order: a7({'phone': '781 555 0102', 'customer_name': 'Omar'}),
        hub: (hub) {
          tagsAlone(hub);
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

    testWidgets('a hub older than all of it: the check is as it was', (tester) async {
      final t = await pumpCheck(
        tester,
        hub: (hub) => hub
          ..seatedCall = false
          ..bookings = [seatedBooking('b1', 'Linda P.', linda, 'o1', note: 'Window table')]
          ..parties = [],
      );
      expect(key(strip), findsNothing);
      expect(find.text('Egg roll'), findsWidgets);
      expect(tester.takeException(), isNull);
      expect(t.hub.seatedAsks, isEmpty);
      expect(t.hub.tableTagAsks, isEmpty); // it asked, and the hub had no word for it
      expect(t.hub.requests, containsAll(['GET /orders/o1/seated', 'GET /orders/o1/tags']));
      await stop(tester);
    });

    testWidgets('what changes in the guest list or the book shows on the check within half a minute', (tester) async {
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

    testWidgets('the hub does not answer for a while: the check keeps what it has', (tester) async {
      final t = await pumpCheck(tester, hub: lindaAtA7);
      t.hub.tableTagsDown = true;
      await tester.pump(const Duration(seconds: 30));
      await tester.pump();
      expect(said(tester, 'seated-name:0'), 'Linda P.');
      expect(tagsIn(tester, strip), ['Catering client', 'VIP']);
      expect(tester.takeException(), isNull);
      await stop(tester);
    });

    testWidgets('on a small phone, in the dark and with large type, a long name, six tags and a long note fit', (
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
      const name = 'Linda Papadopoulos-Chen';
      const note = 'Window table for her mother\'s 80th birthday, cake at nine, no shellfish please'; // 80 letters
      for (final (dark, scale) in [(false, 1.0), (true, 1.0), (false, 1.5)]) {
        await pumpCheck(
          tester,
          size: const Size(320, 568),
          dark: dark,
          textScale: scale,
          hub: (hub) => hub
            ..ringTags = {linda: tags}
            ..bookings = [seatedBooking('b1', name, linda, 'o1', note: note)]
            ..parties = [],
        );
        expect(tester.takeException(), isNull, reason: 'dark $dark, type $scale'); // nothing runs off the screen
        final whole = tester.getRect(key(strip));
        expect(whole.width, 320);
        // never more than a quarter of the screen, so the check and the menu keep their room
        expect(whole.height, lessThanOrEqualTo(568 / 4), reason: 'dark $dark, type $scale');
        expect(tagsIn(tester, strip), tags);
        bool across(Rect rect) => rect.left >= whole.left && rect.right <= whole.right;
        bool inside(Rect rect) => across(rect) && rect.top >= whole.top && rect.bottom <= whole.bottom;
        // the name is there to be read at once, and no label runs off the side
        expect(inside(tester.getRect(key('seated-name:0'))), isTrue);
        for (final tag in tags) {
          expect(across(tester.getRect(key('seated-tag:0:$tag'))), isTrue, reason: tag);
        }
        // the note is whole, on as many lines as it takes, under the labels
        expect(tester.getRect(key('seated-note:0')).top >= tester.getRect(key('seated-tag:0:VIP')).bottom, isTrue);
        final painted = tester.renderObject<RenderParagraph>(key('seated-note:0'));
        expect(painted.didExceedMaxLines, isFalse);
        // and what does not fit is a scroll away, inside the strip
        expect(inside(tester.getRect(key('seated-note:0'))), isFalse);
        await tester.drag(key('customer-note-strip-scroll'), const Offset(0, -600));
        await tester.pump();
        expect(tester.getRect(key(strip)), whole);
        final end = tester.getRect(key('seated-note:0')); // its last line is in the strip now
        expect(across(end) && end.bottom <= whole.bottom && end.bottom > whole.top, isTrue, reason: 'type $scale');
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

    Future<void> told(WidgetTester tester) async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));
    }

    testWidgets('a party sits down on a check that is open: it is named there at once', (tester) async {
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
      t.hub.bookings!.add(seatedBooking('b1', 'Linda P.', linda, 'o1', note: 'Window table'));
      live.changed(topics: ['reservations']);
      await told(tester);
      expect((said(tester, 'seated-name:0'), said(tester, 'seated-note:0')), ('Linda P.', 'Window table'));
      expect(tagsIn(tester, strip), ['VIP']);

      // a party of the waitlist joins the table
      t.hub.parties!.add(seatedParty('p1', 'Omar', omar, 'o1', seatedMs: seven + 60000));
      live.changed(topics: ['waitlist']);
      await told(tester);
      expect(said(tester, 'seated-name:1'), 'Omar');
      expect(tagsIn(tester, strip), ['VIP', 'Regular']);

      // a manager takes Linda's tag off in the guest list: the hub tells the book and the list to read again
      t.hub.ringTags!.remove(linda);
      live.changed(topics: ['reservations', 'waitlist']);
      await told(tester);
      expect(tagsIn(tester, strip), ['Regular']);
      expect(said(tester, 'seated-name:0'), 'Linda P.'); // she is still named

      // what is none of this check's business asks nothing
      final asks = t.hub.seatedAsks.length;
      live.changed(topics: ['menu', 'settings', 'notes']);
      live.changed(orders: ['o9']);
      await told(tester);
      expect(t.hub.seatedAsks.length, asks);
      await finish(tester, live, t);
    });
  });

  group('from the door to the table', () {
    testWidgets('a server seats a party from the waitlist: the check that opens says who they are', (tester) async {
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
      expect(t.hub.seatedAsks, contains(seated['order_id']));
      expect(said(tester, 'seated-name:0'), 'Garcia');
      expect(tagsIn(tester, strip), ['Regular', 'VIP']);
      // the check was opened as every table's is: nothing of the guest went onto it
      final create = t.hub.sent.firstWhere((sent) => sent.$2['kind'] == 'create').$2;
      expect(create.toString(), isNot(contains('0102')));
      expect(create.toString(), isNot(contains('Garcia')));
      expect(create.toString(), isNot(contains('VIP')));
      await stop(tester);
    });

    testWidgets('a party that left no number brings its name and its note all the same', (tester) async {
      await pumpFloorWith(tester, amy, hub: (hub) => hub.bookings = []);
      await seatFromList(tester, 'p2'); // Chen, party of 4, "High chair", no number
      await tester.tap(find.text('A8'));
      await tester.pumpAndSettle();
      await tapKey(tester, 'seat');
      expect(find.byType(OrderScreen), findsOneWidget);
      expect((said(tester, 'seated-name:0'), said(tester, 'seated-note:0')), ('Chen', 'High chair'));
      await stop(tester);
    });
  });
}
