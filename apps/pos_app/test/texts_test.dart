import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/powers.dart';
import 'package:pos_app/screens/order_screen.dart';
import 'package:pos_app/screens/texts_screen.dart';
import 'package:pos_app/session.dart';
import 'package:pos_app/settings.dart';
import 'package:pos_app/texts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'counter_test.dart' show takeout;
import 'hub.dart';
import 'table_servers_test.dart' show amy, mike;

/// Texts with customers (docs/text-inbox.md): what a customer texts the restaurant shows on the POS by
/// their number, the staff answer and start a conversation, and from a conversation an order is started
/// or a table booked. The hub keeps the texts and talks to Twilio; these tests are about the screens.

const pat = '+17815550142';
const lee = '+17815550177';

/// That time on the day of the pretend hub's clock (16 November 2026, 16:02).
int at(int hour, [int minute = 0]) => DateTime(2026, 11, 16, hour, minute).millisecondsSinceEpoch;

/// The smallest picture there is: one clear dot, as a PNG.
final dot = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

Finder key(String name) => find.byKey(ValueKey(name));

Future<void> tapKey(WidgetTester tester, String name) async {
  await tester.tap(key(name));
  await tester.pumpAndSettle();
}

/// Pat asked for egg rolls and was answered; Lee wrote a minute ago and nobody has looked.
void twoConversations(Hub hub) {
  hub.conversation(pat, name: 'Pat', [
    Hub.aText('t1', pat, 'Can I get two egg rolls for pickup?', atMs: at(15, 40)),
    Hub.aText('t2', pat, 'Sure! Ready in 15 minutes.', atMs: at(15, 41), inbound: false, by: 'Amy'),
  ]);
  hub.conversation(lee, unread: 1, [Hub.aText('t3', lee, 'Do you have a table for 6 tonight?', atMs: at(16, 1))]);
}

/// The Texts screen by itself, for [who], over a button that keeps what it was left with.
Future<(Terminal, List<Object?>)> pumpTexts(
  WidgetTester tester, {
  Staff who = amy,
  void Function(Hub hub)? hub = twoConversations,
  Size size = const Size(1100, 800),
  String? open,
  bool only = false,
}) async {
  final t = await terminal(tester);
  tester.view.physicalSize = size;
  t.session.staff = who;
  hub?.call(t.hub);
  final popped = <Object?>[];
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () async => popped.add(
                await Navigator.of(context).push<Object?>(
                  MaterialPageRoute(
                    builder: (_) => TextsScreen(
                      api: t.api,
                      staffId: who.staffId,
                      device: 't1',
                      open: open,
                      only: only,
                      nowMs: () => t.hub.clockNow,
                    ),
                  ),
                ),
              ),
              child: const Text('open the texts'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open the texts'));
  await tester.pumpAndSettle();
  return (t, popped);
}

/// The conversations in the list, top to bottom, by their numbers.
List<String> listed(WidgetTester tester) {
  final rows = [
    for (final element in find.byWidgetPredicate((w) {
      final k = w.key;
      return k is ValueKey<String> && k.value.startsWith('text-thread:');
    }).evaluate())
      (
        tester.getTopLeft(find.byWidget(element.widget)).dy,
        (element.widget.key! as ValueKey<String>).value.substring(12),
      ),
  ]..sort((a, b) => a.$1.compareTo(b.$1));
  return [for (final row in rows) row.$2];
}

void main() {
  group('the words', () {
    test('a number is kept the way the hub keeps conversations', () {
      expect(textNumber('781 555 0142'), pat);
      expect(textNumber('(781) 555-0142'), pat);
      expect(textNumber('1 781 555 0142'), pat);
      expect(textNumber('+44 20 7946 0958'), '+442079460958');
      expect(textNumber('555 0142'), isNull);
      expect(textNumber('081 555 0142'), isNull);
      expect(textNumber(''), isNull);
    });

    test("a conversation's line says who wrote last, and what a text carried besides words", () {
      expect(lastWords(const TextLast(body: 'Two egg\nrolls', inbound: true)), 'Two egg rolls');
      expect(lastWords(const TextLast(body: 'Sure', state: 'delivered')), 'You: Sure');
      expect(lastWords(const TextLast(body: 'Sure', state: 'failed')), 'Not sent: Sure');
      expect(lastWords(const TextLast(inbound: true, picturesN: 1)), 'A picture');
      expect(lastWords(const TextLast(inbound: true, picturesN: 3)), '3 pictures');
    });

    test('under a text: who, when, and what became of it', () {
      final now = DateTime(2026, 11, 16, 16, 2);
      TextMessage text({bool inbound = false, String state = 'delivered', String kind = '', String said = ''}) =>
          TextMessage(id: 't', inbound: inbound, atMs: at(15, 41), state: state, kind: kind, by: 'Amy', said: said);
      expect(underWords(text(), now), 'Amy · 15:41 · Delivered');
      expect(underWords(text(inbound: true, state: 'received'), now), '15:41');
      expect(underWords(text(state: 'waiting'), now), 'Amy · 15:41 · Sending');
      expect(underWords(text(state: 'read'), now), 'Amy · 15:41 · Read');
      expect(
        underWords(text(state: 'failed', said: 'the customer answered STOP'), now),
        'Amy · 15:41 · Not sent: the customer answered STOP',
      );
      expect(underWords(text(kind: 'ready'), now), 'The POS: order ready · 15:41 · Delivered');
      expect(underWords(text(kind: 'elsewhere'), now), "From the restaurant's number, not the POS · 15:41 · Delivered");
      final yesterday = TextMessage(id: 't', inbound: true, atMs: at(15, 41) - 86400000, state: 'received');
      expect(underWords(yesterday, now), 'yesterday 15:41');
    });

    test('the texts fetched from further back stay when the conversation is read again', () {
      TextMessage text(String id, int minute) => TextMessage(id: id, atMs: at(15, minute));
      const thread = TextThread(phone: pat);
      final newest = TextPage(thread: thread, texts: [text('c', 3), text('d', 4)], more: true);
      final older = TextPage(thread: thread, texts: [text('a', 1), text('b', 2)]);
      final both = newest.withOlder(older);
      expect([for (final t in both.texts) t.id], ['a', 'b', 'c', 'd']);
      expect(both.more, isFalse);
      final again = TextPage(thread: thread, texts: [text('d', 4), text('e', 5)], more: true).keeping(both);
      expect([for (final t in again.texts) t.id], ['a', 'b', 'c', 'd', 'e']);
      expect(again.more, isFalse);
    });
  });

  group('the Texts screen', () {
    testWidgets('lists the conversations, the newest first, with a dot on the one nobody has read', (tester) async {
      final (t, _) = await pumpTexts(tester);
      expect(listed(tester), [lee, pat]);
      expect(key('text-unread:$lee'), findsOneWidget);
      expect(key('text-unread:$pat'), findsNothing);
      expect(find.text('781 555 0177'), findsOneWidget); // a number the POS has no name for
      expect(find.text('Do you have a table for 6 tonight?'), findsOneWidget);
      expect(find.text('Pat'), findsOneWidget);
      expect(find.text('You: Sure! Ready in 15 minutes.'), findsOneWidget);
      expect(find.text('The restaurant is 781 555 0100'), findsOneWidget);
      expect(key('texts-pick'), findsOneWidget);
      expect(t.hub.textReads, isEmpty, reason: 'nothing is read before somebody opens it');
      await stop(tester);
    });

    testWidgets('a conversation opened is read for everybody, and an answer goes with who sent it', (tester) async {
      final (t, _) = await pumpTexts(tester);
      await tapKey(tester, 'text-thread:$lee');
      expect(find.text('Do you have a table for 6 tonight?'), findsNWidgets(2)); // its line and the text itself
      expect(t.hub.textReads, [(lee, 's1')]);
      expect(key('text-unread:$lee'), findsNothing);
      expect(key('text-goes-as'), findsNothing);
      expect(tester.widget<IconButton>(key('text-send')).onPressed, isNull, reason: 'nothing typed yet');
      await tester.enterText(key('text-box'), 'Yes, at 7:30. Shall I book it?');
      await tester.pumpAndSettle();
      expect(key('text-goes-as'), findsNothing, reason: 'only the first text to a number is wrapped');
      await tapKey(tester, 'text-send');
      final (to, sent) = t.hub.textPosts.single;
      expect(to, lee);
      expect(sent['staff_id'], 's1');
      expect(sent['body'], 'Yes, at 7:30. Shall I book it?');
      expect(sent['device'], 't1');
      expect(sent['id'], matches(RegExp(r'^[A-Za-z0-9_-]{8,64}$')));
      expect(find.text('Yes, at 7:30. Shall I book it?'), findsOneWidget); // the text itself
      expect(find.text('You: Yes, at 7:30. Shall I book it?'), findsOneWidget); // and its line of the list
      expect(find.text('Amy · 16:02 · Sending'), findsOneWidget);
      expect(tester.widget<TextField>(key('text-box')).controller!.text, isEmpty);
      await stop(tester);
    });

    testWidgets('New text starts a conversation, and shows what the first text goes as', (tester) async {
      final (t, _) = await pumpTexts(tester);
      await tapKey(tester, 'text-new');
      expect(tester.widget<FilledButton>(key('text-new-open')).onPressed, isNull);
      await tester.enterText(key('text-new-number'), '781 555');
      await tester.pumpAndSettle();
      expect(find.text('Ten digits, like 781 555 0142'), findsOneWidget);
      await tester.enterText(key('text-new-number'), '781 555 0199');
      await tester.enterText(key('text-new-name'), 'Sam');
      await tester.pumpAndSettle();
      await tapKey(tester, 'text-new-open');
      expect(tester.widget<Text>(key('text-thread-title')).data, 'Sam');
      expect(find.text('No texts with Sam yet.'), findsOneWidget);
      await tester.enterText(key('text-box'), 'Your order is on the shelf.');
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(key('text-goes-as')).data,
        endsWith('It goes as:\nChina Sky: Your order is on the shelf.\nReply STOP to opt out.'),
      );
      await tapKey(tester, 'text-send');
      final (to, sent) = t.hub.textPosts.single;
      expect((to, sent['body'], sent['name']), ('+17815550199', 'Your order is on the shelf.', 'Sam'));
      // the hub wrote it down as it went, and the screen shows that
      expect(find.text('China Sky: Your order is on the shelf.\nReply STOP to opt out.'), findsOneWidget);
      expect(listed(tester).first, '+17815550199');
      await stop(tester);
    });

    testWidgets('a customer who answered STOP is sent nothing', (tester) async {
      await pumpTexts(
        tester,
        hub: (hub) =>
            hub.conversation(pat, name: 'Pat', stoppedMs: at(15, 50), [Hub.aText('t1', pat, 'STOP', atMs: at(15, 50))]),
      );
      expect(find.text('STOP'), findsNWidgets(2)); // the mark on the line, and the text on the line
      await tapKey(tester, 'text-thread:$pat');
      expect(key('text-stopped'), findsOneWidget);
      expect(find.text('Pat answered STOP. No text goes to them until they text START.'), findsOneWidget);
      expect(key('text-box'), findsNothing);
      await stop(tester);
    });

    testWidgets('what the hub refuses is said, and the words stay in the box', (tester) async {
      final (t, _) = await pumpTexts(tester);
      await tapKey(tester, 'text-thread:$pat');
      await tester.enterText(key('text-box'), 'Are you coming?');
      await tester.pumpAndSettle();
      t.hub.refuseText = (409, 'stopped', 'This customer answered STOP.');
      await tapKey(tester, 'text-send');
      expect(key('text-not-sent'), findsOneWidget);
      expect(find.text('This customer answered STOP: no text goes to them until they text START.'), findsOneWidget);
      expect(tester.widget<TextField>(key('text-box')).controller!.text, 'Are you coming?');
      await stop(tester);
    });

    testWidgets('a hub with no Twilio account says so, and offers nothing to send with', (tester) async {
      await pumpTexts(
        tester,
        hub: (hub) => hub
          ..textThreads = []
          ..textsOn = false,
      );
      expect(key('texts-note'), findsOneWidget);
      expect(find.textContaining('This hub has no Twilio account yet'), findsOneWidget);
      expect(key('text-new'), findsNothing);
      expect(find.text('No texts yet.'), findsOneWidget);
      await stop(tester);
    });

    testWidgets('Twilio not answering the hub is said over the list', (tester) async {
      await pumpTexts(
        tester,
        hub: (hub) {
          twoConversations(hub);
          hub.textsListening = {'ok': false, 'at_ms': at(15), 'said': 'Twilio does not know the key (20003)'};
        },
      );
      expect(
        find.text(
          'Twilio is not answering the hub, so new texts are not showing yet. (Twilio does not know the key (20003))',
        ),
        findsOneWidget,
      );
      expect(listed(tester), [lee, pat]);
      await stop(tester);
    });

    testWidgets('an older hub, and somebody who may not read the texts, are told why nothing shows', (tester) async {
      await pumpTexts(tester, hub: null);
      expect(find.text('This hub is older than texts with customers. Update the hub for them.'), findsOneWidget);
      await stop(tester);
    });

    testWidgets('finding narrows the list to the conversations that hold the words', (tester) async {
      final (t, _) = await pumpTexts(tester);
      await tester.enterText(key('texts-find'), 'egg rolls');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(listed(tester), [pat]);
      expect(t.hub.requests.where((r) => r.startsWith('GET /texts?')).last, contains('q=egg+rolls'));
      await tester.enterText(key('texts-find'), 'noodles');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.text('No conversation has that in it.'), findsOneWidget);
      await stop(tester);
    });

    testWidgets('on a phone the list comes first, the conversation over it, and back is the list', (tester) async {
      final (_, popped) = await pumpTexts(tester, size: const Size(390, 800));
      expect(listed(tester), [lee, pat]);
      expect(key('text-box'), findsNothing);
      await tapKey(tester, 'text-thread:$pat');
      expect(key('texts-list'), findsNothing);
      expect(tester.widget<Text>(key('text-thread-title')).data, 'Pat');
      expect(find.text('781 555 0142'), findsOneWidget);
      expect(find.text('Can I get two egg rolls for pickup?'), findsOneWidget);
      expect(find.text('Amy · 15:41 · Delivered'), findsOneWidget);
      expect(tester.takeException(), isNull); // nothing runs off a narrow screen
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(listed(tester), [lee, pat]);
      expect(popped, isEmpty, reason: 'the screen itself stays');
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(popped, [null]);
      await stop(tester);
    });

    testWidgets('Start order and Book a table leave with the number and the name', (tester) async {
      final (_, popped) = await pumpTexts(tester);
      await tapKey(tester, 'text-thread:$pat');
      await tapKey(tester, 'text-start-order');
      final order = popped.single! as StartOrderFor;
      expect((order.phone, order.name), ('7815550142', 'Pat'));
      await tester.tap(find.text('open the texts'));
      await tester.pumpAndSettle();
      await tapKey(tester, 'text-thread:$lee');
      await tapKey(tester, 'text-book-table');
      final table = popped.last! as BookTableFor;
      expect((table.phone, table.name), ('7815550177', ''));
      await stop(tester);
    });

    testWidgets('a picture a customer sent shows in the conversation; what is no picture is named', (tester) async {
      final (t, _) = await pumpTexts(
        tester,
        hub: (hub) {
          hub.conversation(pat, name: 'Pat', [
            Hub.aText('t1', pat, 'Is this the dish?', atMs: at(15, 40), channel: 'mms', pictures: ['image/png']),
            Hub.aText('t2', pat, '', atMs: at(15, 42), channel: 'mms', pictures: ['text/vcard']),
          ]);
          hub.textPictures['t1/0'] = dot;
        },
      );
      expect(find.text('A picture'), findsOneWidget); // the last text's line: it has no words
      await tapKey(tester, 'text-thread:$pat');
      expect(t.hub.requests, contains('GET /texts/picture/t1/0?staff_id=s1'));
      expect(find.descendant(of: key('text-picture:t1/0'), matching: find.byType(Image)), findsOneWidget);
      expect(find.text('A file the POS does not show (text/vcard)'), findsOneWidget);
      expect(t.hub.requests.where((r) => r.startsWith('GET /texts/picture/t2')), isEmpty);
      await stop(tester);
    });

    testWidgets('told by the hub that a text came, the screen reads again', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final settings = Settings(
        device: 't1',
        endpoints: ['http://hub:8000'],
        prefs: await SharedPreferences.getInstance(),
      );
      final hub = Hub();
      twoConversations(hub);
      final live = LiveHub(hub);
      final api = PosApi(settings, client: live.client);
      tester.view
        ..physicalSize = const Size(1100, 800)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      api.live.start();
      await tester.pumpWidget(
        MaterialApp(
          home: TextsScreen(api: api, staffId: 's1', device: 't1', nowMs: () => hub.clockNow),
        ),
      );
      await tester.pumpAndSettle();
      live.hello();
      live.beats();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      int reads() => hub.requests.where((r) => r.startsWith('GET /texts?')).length;
      final before = reads();
      await tester.pump(const Duration(seconds: 10));
      expect(reads(), before, reason: 'nobody asks while the hub can tell');
      hub.conversation(pat, name: 'Pat', unread: 1, [
        ...hub.textsOf[pat]!,
        Hub.aText('t9', pat, 'On my way', atMs: at(16, 2)),
      ]);
      live.changed(topics: ['texts']);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      expect(reads(), before + 1);
      expect(find.text('On my way'), findsOneWidget);
      expect(listed(tester), [pat, lee]);
      await stop(tester);
      live.close();
      api.dispose();
      await tester.pump();
    });
  });

  group('the Orders screen', () {
    Future<Terminal> pumpOrdersFor(
      WidgetTester tester,
      Staff who, {
      void Function(Hub hub)? hub,
      Size size = const Size(1100, 800),
    }) async {
      final t = await terminal(tester);
      tester.view.physicalSize = size;
      t.session.staff = who;
      (hub ?? twoConversations)(t.hub); // its table hands the texts to whoever is out front, as a hub starts
      await pumpOrdersOn(tester, t);
      return t;
    }

    /// Whether More carries the dot that says something behind it wants a look.
    bool moreSaysLook(WidgetTester tester) =>
        tester.widget<Badge>(find.descendant(of: key('home-more'), matching: find.byType(Badge))).isLabelVisible;

    testWidgets('whoever may read the texts has the tile, with how many conversations wait', (tester) async {
      await pumpOrdersFor(tester, amy);
      expect(homeIds(tester), contains('texts'));
      expect(key('home-quick:texts'), findsNothing, reason: 'the row keeps its room: Texts is a tile');
      expect(moreSaysLook(tester), isTrue);
      await openMore(tester);
      expect(find.descendant(of: homeTile('texts'), matching: find.text('Texts')), findsOneWidget);
      expect(find.descendant(of: homeTile('texts'), matching: find.text('1 not read')), findsOneWidget);
      expect(find.descendant(of: key('home-count:texts:ok'), matching: find.text('1')), findsOneWidget);
      await tester.tap(homeTile('texts'));
      await tester.pumpAndSettle();
      expect(listed(tester), [lee, pat]);
      await stop(tester);
    });

    testWidgets('nobody is offered the texts who may not read them, and nothing is asked for them', (tester) async {
      const ken = Staff(staffId: 's5', name: 'Ken', role: 'kitchen', method: 'pin');
      final t = await pumpOrdersFor(tester, ken);
      expect(homeIds(tester), isNot(contains('texts')));
      expect(moreSaysLook(tester), isFalse);
      expect(t.hub.textAsks, 0);
      await stop(tester);
    });

    testWidgets('a hub older than the texts shows no tile', (tester) async {
      await pumpOrdersFor(tester, mike, hub: (_) {});
      expect(homeIds(tester), isNot(contains('texts')));
      await stop(tester);
    });

    testWidgets('on a phone More says so while something waits, and the tile is there with nothing waiting', (
      tester,
    ) async {
      final t = await pumpOrdersFor(tester, amy, size: const Size(390, 800));
      expect(moreSaysLook(tester), isTrue);
      await stop(tester);
      t.hub.textThreads = [
        for (final thread in t.hub.textThreads!) {...thread, 'unread': 0},
      ];
      await pumpOrdersOn(tester, t);
      expect(moreSaysLook(tester), isFalse);
      await openMore(tester);
      expect(find.descendant(of: homeTile('texts'), matching: find.text('Texts')), findsOneWidget);
      expect(find.textContaining('not read'), findsNothing);
      expect(key('home-count:texts:ok'), findsNothing);
      await tester.ensureVisible(homeTile('texts'));
      await tester.pumpAndSettle();
      await tester.tap(homeTile('texts'));
      await tester.pumpAndSettle();
      expect(listed(tester), [lee, pat]);
      await stop(tester);
    });

    testWidgets('Start order from a conversation brings the to-go form up with the number and the name', (
      tester,
    ) async {
      await pumpOrdersFor(tester, amy);
      await openHome(tester, 'texts');
      await tester.pumpAndSettle();
      await tapKey(tester, 'text-thread:$pat');
      await tapKey(tester, 'text-start-order');
      expect(tester.widget<TextField>(key('takeout-name')).controller!.text, 'Pat');
      expect(tester.widget<TextField>(key('takeout-phone')).controller!.text, '781 555 0142');
      await stop(tester);
    });
  });

  group('a to-go order', () {
    Map<String, dynamic> pats(String id) {
      final order = takeout(id, name: 'Pat', channel: 'phone');
      return {
        ...order,
        'fields': {...order['fields'] as Map<String, dynamic>, 'phone': '(781) 555-0142'},
      };
    }

    Future<Terminal> pumpOrder(WidgetTester tester, {void Function(Hub hub)? hub, Staff who = mike}) async {
      final t = await terminal(tester);
      t.session.staff = who;
      t.hub.orders.add(pats('o1'));
      hub?.call(t.hub);
      await t.api.readPowers();
      await tester.pumpWidget(
        MaterialApp(
          home: OrderScreen(api: t.api, outbox: t.outbox, photos: t.photos, orderId: 'o1', session: t.session),
        ),
      );
      await tester.pumpAndSettle();
      return t;
    }

    testWidgets('has a Text button that opens the conversation with its customer, and only that', (tester) async {
      final t = await pumpOrder(tester, hub: (hub) => hub.textThreads = []);
      expect(key('text-strip'), findsOneWidget);
      expect(find.text('Text Pat'), findsOneWidget);
      await tapKey(tester, 'text-strip');
      expect(tester.widget<Text>(key('text-thread-title')).data, 'Pat');
      expect(key('text-start-order'), findsNothing, reason: 'the order is the one it came from');
      expect(key('texts-list'), findsNothing);
      await tester.enterText(key('text-box'), 'Your order is ready.');
      await tester.pumpAndSettle();
      await tapKey(tester, 'text-send');
      final (to, sent) = t.hub.textPosts.single;
      expect((to, sent['name'], sent['staff_id']), (pat, 'Pat', 's3'));
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.textContaining('You: China Sky: Your order is ready.'), findsOneWidget);
      await stop(tester);
    });

    testWidgets('says when the customer wrote something nobody has read', (tester) async {
      await pumpOrder(
        tester,
        hub: (hub) => hub.conversation(pat, name: 'Pat', unread: 1, [
          Hub.aText('t1', pat, 'Running 10 minutes late', atMs: at(15, 58)),
        ]),
      );
      expect(find.text('New text: Running 10 minutes late'), findsOneWidget);
      expect(find.text('Read'), findsOneWidget);
      await stop(tester);
    });

    testWidgets('has none where the hub has no Twilio account, is older, or the person may not text', (tester) async {
      await pumpOrder(
        tester,
        hub: (hub) => hub
          ..textThreads = []
          ..textsOn = false,
      );
      expect(key('text-strip'), findsNothing);
      await stop(tester);
      await pumpOrder(tester);
      expect(key('text-strip'), findsNothing);
      await stop(tester);
      final t = await pumpOrder(
        tester,
        who: amy,
        hub: (hub) => hub
          ..textThreads = []
          ..powers = {...?hub.powers, 'texts': []},
      );
      expect(key('text-strip'), findsNothing, reason: 'this location took the texts from its servers');
      expect(t.hub.requests.where((r) => r.startsWith('GET /texts')), isEmpty);
      await stop(tester);
    });
  });

  test('the power is on the screen that hands the powers out, and starts with whoever is out front', () {
    final power = powerGroups.expand((group) => group.powers).singleWhere((power) => power.id == 'texts');
    expect(power.name, 'Text with customers');
    expect(Powers.standard.handedTo('texts'), ['server', 'bartender', 'host', 'cashier']);
    expect(Powers.standard.holds('kitchen', 'texts'), isFalse);
    expect(Powers.standard.holds('manager', 'texts'), isTrue);
    // put back as it started, a table that took the texts from everybody hands them out front again
    const taken = Powers({'texts': <String>[]}, handed: handedRoles);
    expect(taken.holds('server', 'texts'), isFalse);
    expect(taken.asItStarted.handedTo('texts'), ['server', 'bartender', 'host', 'cashier']);
  });

  test('what the tile says of the conversations not read', () {
    expect(unreadNote(0), isNull);
    expect(unreadNote(1), '1 not read');
    expect(unreadNote(4), '4 not read');
  });
}
