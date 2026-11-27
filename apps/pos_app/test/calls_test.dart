import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/call_player.dart';
import 'package:pos_app/calls.dart';
import 'package:pos_app/outbox.dart';
import 'package:pos_app/photos.dart';
import 'package:pos_app/camera.dart';
import 'package:pos_app/powers.dart';
import 'package:pos_app/queue_store.dart';
import 'package:pos_app/screens/calls_sheet.dart';
import 'package:pos_app/screens/order_screen.dart';
import 'package:pos_app/session.dart';
import 'package:pos_app/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'counter_test.dart' show takeout;
import 'hub.dart';

/// Call recordings on phone orders (docs/call-recordings.md): the hub lists the recorded calls with an
/// order's phone number; the order says it has some, lists them in a sheet, and plays one for whoever may
/// listen. The hub finds and fetches the recordings; these tests are about the screens.

/// Stands in for the device's speaker: keeps what it was told, and the test moves the playing along.
class FakePlayer implements CallPlayer {
  final _playback = ValueNotifier<CallPlayback>(CallPlayback.idle);
  final played = <List<int>>[];
  final did = <String>[];
  bool closed = false;

  @override
  ValueListenable<CallPlayback> get playback => _playback;

  @override
  Future<void> play(Uint8List mp3) async {
    played.add(mp3);
    _playback.value = const CallPlayback(length: Duration(seconds: 95), playing: true);
  }

  @override
  Future<void> pause() async {
    did.add('pause');
    _playback.value = _playback.value.copyWith(playing: false);
  }

  @override
  Future<void> resume() async {
    did.add('resume');
    _playback.value = _playback.value.copyWith(playing: true);
  }

  @override
  Future<void> seek(Duration to) async {
    did.add('seek ${to.inSeconds}');
    _playback.value = _playback.value.copyWith(position: to);
  }

  @override
  Future<void> close() async => closed = true;

  /// The playing came this far.
  void at(Duration position) => _playback.value = _playback.value.copyWith(position: position);
}

/// Today at that time, on the device's own clock: a call of today is said by its hour alone.
int today(int hour, [int minute = 0]) {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day, hour, minute).millisecondsSinceEpoch;
}

/// Linda's phone order, with her number on it.
Map<String, dynamic> phoneOrder(String id, {String phone = '(781) 555-1234'}) {
  final order = takeout(id, channel: 'phone');
  return {
    ...order,
    'fields': {...order['fields'] as Map<String, dynamic>, 'phone': phone},
  };
}

const first = '1795735800.101';
const second = '1795737900.202';

/// The call the order was taken on, in stereo, and a call back to her later.
List<Map<String, dynamic>> twoCalls() => [
  Hub.recorded(first, today(18, 30), stereo: true, opened: true),
  Hub.recorded(second, today(19, 5), out: true, seconds: 30),
];

Future<(Terminal, FakePlayer)> pumpOrder(
  WidgetTester tester,
  Map<String, dynamic> order, {
  List<Map<String, dynamic>>? calls,
  void Function(Hub hub)? before,
  Size size = const Size(1100, 800),
  double textScale = 1,
  PosApi Function(Hub hub, Settings settings)? api,
}) async {
  SharedPreferences.setMockInitialValues({});
  final settings = Settings(device: 't1', endpoints: ['http://hub:8000'], prefs: await SharedPreferences.getInstance());
  final hub = Hub();
  final made = api?.call(hub, settings);
  final t = made == null
      ? await terminal(tester)
      : Terminal(
          hub,
          made,
          Outbox(made, settings, store: MemoryStore()),
          PhotoQueue(made, settings, NoCamera(), Session(made), store: MemoryStore()),
          Session(made),
          settings,
        );
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  t.hub.orders.add(order);
  if (calls != null) t.hub.calls![order['order_id'] as String] = calls;
  t.hub.callAudio[first] = [1, 2, 3];
  t.hub.callAudio[second] = [4, 5, 6];
  before?.call(t.hub);
  final player = FakePlayer();
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: OrderScreen(
        api: t.api,
        outbox: t.outbox,
        photos: t.photos,
        orderId: order['order_id'] as String,
        staffName: 'Amy',
        callPlayer: () => player,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (t, player);
}

Future<void> openCalls(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('calls-strip')));
  await tester.pumpAndSettle();
}

Future<void> press(WidgetTester tester, String call) async {
  await tester.tap(find.byKey(ValueKey('call-play-$call')));
  await tester.pumpAndSettle();
}

Future<void> typePin(WidgetTester tester, String pin) async {
  await tester.enterText(find.byType(TextField).last, pin);
  await tester.tap(find.widgetWithText(FilledButton, 'Listen'));
  await tester.pumpAndSettle();
}

void main() {
  group('the words', () {
    test('a call reads as the hub lists it', () {
      final calls = OrderCalls.fromJson({
        'order_id': 'o1',
        'phone': '7815551234',
        'linked': true,
        'problem': null,
        'calls': twoCalls(),
      });
      expect((calls.linked, calls.problem, calls.calls.length), (true, null, 2));
      final taken = calls.calls.first;
      expect((taken.id, taken.out, taken.seconds, taken.stereo, taken.opened), (first, false, 95, true, true));
      expect((taken.who, calls.calls.last.who, calls.calls.last.extension), ('They called', 'We called them', '200'));
      // the same list read twice is the same: a screen that hears nothing new draws nothing again
      expect(calls, OrderCalls.fromJson({'linked': true, 'calls': twoCalls()}));
      expect(calls == OrderCalls.fromJson({'linked': true, 'calls': twoCalls().sublist(1)}), isFalse);
      expect(OrderCalls.fromJson(const {}), OrderCalls.none);
      // a hub that says something this build does not know of a call is read all the same
      expect(RecordedCall.fromJson(const {'id': 'x'}).seconds, isNull);
    });

    test('a length reads as a player shows it, and the calls are counted', () {
      expect(callLength(const Duration(seconds: 7)), '0:07');
      expect(callLength(const Duration(seconds: 95)), '1:35');
      expect(callLength(const Duration(seconds: 3725)), '1:02:05');
      expect(callLength(const Duration(seconds: -3)), '0:00');
      expect((callsCount(1), callsCount(3)), ('1 recorded call', '3 recorded calls'));
    });

    test('listening is a power of its own, a manager\'s to start', () {
      expect(powersById['calls']?.name, 'Listen to recorded calls');
      expect(sessionPowers, contains('calls'));
      expect(Powers.standard.handedTo('calls'), isEmpty);
      expect(Powers.standard.whose('calls'), 'a manager');
    });
  });

  group('on the order', () {
    testWidgets('a phone order with recorded calls says so, in one line', (tester) async {
      final (t, _) = await pumpOrder(tester, phoneOrder('o1'), calls: twoCalls());
      expect(find.byKey(const ValueKey('calls-strip')), findsOneWidget);
      expect(find.text('2 recorded calls'), findsOneWidget);
      expect(t.hub.callsAsks, ['o1']); // asked once for the number, not with every read of the order
      await stop(tester);
    });

    testWidgets('an order with no recorded calls gives no room to them', (tester) async {
      final (t, _) = await pumpOrder(tester, phoneOrder('o1'));
      expect(find.byKey(const ValueKey('calls-strip')), findsNothing);
      expect(t.hub.callsAsks, ['o1']);
      await stop(tester);
    });

    testWidgets('an order without a number asks nobody', (tester) async {
      final (t, _) = await pumpOrder(tester, takeout('o1'));
      expect(find.byKey(const ValueKey('calls-strip')), findsNothing);
      expect(t.hub.callsAsks, isEmpty);
      await stop(tester);
    });

    testWidgets('a hub older than call recordings is asked once and shows nothing', (tester) async {
      final (t, _) = await pumpOrder(tester, phoneOrder('o1'), before: (hub) => hub.calls = null);
      expect(find.byKey(const ValueKey('calls-strip')), findsNothing);
      await tester.pump(const Duration(seconds: 10));
      expect(t.hub.requests.where((r) => r == 'GET /orders/o1/calls').length, 1);
      await stop(tester);
    });

    testWidgets('the hub says when the phone server has a new recording, and the order shows its call', (tester) async {
      late LiveHub live;
      final (t, _) = await pumpOrder(
        tester,
        phoneOrder('o1'),
        api: (hub, settings) {
          live = LiveHub(hub);
          return PosApi(settings, client: live.client)..live.start();
        },
      );
      live.hello();
      live.beats();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(find.byKey(const ValueKey('calls-strip')), findsNothing);
      final asked = t.hub.callsAsks.length;
      // the call ends, the hub finds its recording and tells the screens
      t.hub.calls!['o1'] = [Hub.recorded(first, today(18, 30), opened: true)];
      live.changed(topics: ['calls']);
      await tester.pumpAndSettle();
      expect(find.text('1 recorded call'), findsOneWidget);
      expect(t.hub.callsAsks.length, asked + 1);
      // something else changed: the calls are not asked for again
      live.changed(topics: ['menu']);
      await tester.pumpAndSettle();
      expect(t.hub.callsAsks.length, asked + 1);
      await stop(tester);
      live.close();
      t.api.dispose();
      await tester.pump();
    });
  });

  group('the calls', () {
    testWidgets('each call says when it was, who called and how long it runs', (tester) async {
      await pumpOrder(tester, phoneOrder('o1'), calls: twoCalls());
      await openCalls(tester);
      expect(find.text('Recorded calls'), findsOneWidget);
      expect(find.text('18:30 · They called'), findsOneWidget);
      expect(find.text('1:35 · the order was opened on this call · stereo'), findsOneWidget);
      expect(find.text('19:05 · We called them'), findsOneWidget);
      expect(find.text('0:30'), findsOneWidget);
      expect(find.text('Stereo: the customer is on the left, the restaurant on the right.'), findsOneWidget);
      expect(find.byKey(const ValueKey('call-seek')), findsNothing); // nothing plays until somebody presses
      await stop(tester);
    });

    testWidgets('a call of another day says its day', (tester) async {
      final t = await terminal(tester);
      final now = DateTime(2026, 11, 26, 19, 30);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CallsSheet(
              api: t.api,
              orderId: 'o1',
              access: CallsAccess(),
              now: () => now,
              calls: OrderCalls(
                linked: true,
                problem: 'unreachable',
                calls: [
                  RecordedCall(id: 'a', startedMs: DateTime(2026, 11, 24, 11).millisecondsSinceEpoch, seconds: 61),
                  RecordedCall(id: 'b', startedMs: DateTime(2026, 11, 25, 15, 5).millisecondsSinceEpoch),
                  RecordedCall(id: 'c', startedMs: DateTime(2026, 11, 26, 10).millisecondsSinceEpoch, out: true),
                ],
              ),
            ),
          ),
        ),
      );
      expect(find.text('24 Nov 11:00 · They called'), findsOneWidget);
      expect(find.text('yesterday 15:05 · They called'), findsOneWidget);
      expect(find.text('10:00 · We called them'), findsOneWidget);
      expect(find.text('1:01'), findsOneWidget);
      // no call is in stereo: nothing is said of left and right
      expect(find.textContaining('Stereo:'), findsNothing);
      // the phone server did not answer the hub's last look: the list may be behind, and says so
      expect(find.byKey(const ValueKey('calls-behind')), findsOneWidget);
    });

    testWidgets('listening takes a PIN once, then the call plays and can be paused and moved', (tester) async {
      final (t, player) = await pumpOrder(tester, phoneOrder('o1'), calls: twoCalls());
      await openCalls(tester);
      await press(tester, first);
      expect(find.text('PIN'), findsWidgets); // the box asks: nothing was fetched yet
      expect(t.hub.audioAsks, isEmpty);
      await typePin(tester, '9999');
      expect(t.hub.sessionsFor.last, 'calls');
      expect(t.hub.audioAsks, [first]);
      expect(t.hub.audioAuth, 'Bearer tok-admin');
      expect(player.played, [
        [1, 2, 3],
      ]);
      // it plays: the button pauses, and the bar says how far in and how long
      expect(find.byTooltip('Pause'), findsOneWidget);
      expect(find.byKey(const ValueKey('call-seek')), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const ValueKey('call-length'))).data, '1:35');
      player.at(const Duration(seconds: 12));
      await tester.pump();
      expect(tester.widget<Text>(find.byKey(const ValueKey('call-at'))).data, '0:12');
      await press(tester, first);
      expect(player.did, ['pause']);
      expect(find.byTooltip('Pause'), findsNothing);
      await press(tester, first);
      expect(player.did, ['pause', 'resume']);
      // dragged to its middle
      await tester.tap(find.byKey(const ValueKey('call-seek')));
      await tester.pumpAndSettle();
      expect(player.did.last, startsWith('seek 4')); // the middle of 95 seconds
      // the other call: no PIN again, and the bar moves under it
      await press(tester, second);
      expect(t.hub.pins, ['9999']);
      expect(t.hub.audioAsks, [first, second]);
      expect(player.played.last, [4, 5, 6]);
      expect(find.byKey(const ValueKey('call-seek')), findsOneWidget);
      // closed, the speaker is let go; opened again from the same order, the PIN is not asked again
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(player.closed, isTrue);
      await openCalls(tester);
      await press(tester, first);
      expect(t.hub.pins, ['9999']);
      expect(t.hub.audioAsks, [first, second, first]);
      await stop(tester);
    });

    testWidgets('a PIN that may not listen is told whose can, until the location hands it out', (tester) async {
      final (t, player) = await pumpOrder(tester, phoneOrder('o1'), calls: twoCalls());
      await openCalls(tester);
      await press(tester, first);
      await typePin(tester, '1111'); // Amy, a server
      expect(find.text('Only a manager can listen to recorded calls'), findsOneWidget);
      expect(t.hub.audioAsks, isEmpty);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(player.played, isEmpty);
      expect(find.byType(CircularProgressIndicator), findsNothing); // the button is a button again
      // "Who may do what" hands it to the servers
      t.hub.powers!['calls'] = ['server'];
      await press(tester, first);
      await typePin(tester, '1111');
      expect(t.hub.audioAuth, 'Bearer tok-s1');
      expect(player.played, hasLength(1));
      await stop(tester);
    });

    testWidgets('a recording the phone server no longer has says so, and goes off the list', (tester) async {
      final (t, player) = await pumpOrder(
        tester,
        phoneOrder('o1'),
        calls: twoCalls(),
        before: (hub) => hub.refuseAudio = (404, 'gone'),
      );
      await openCalls(tester);
      await press(tester, first);
      t.hub.calls!['o1'] = twoCalls().sublist(1); // the hub took it off as it answered
      await typePin(tester, '9999');
      expect(find.text('The phone server no longer has that recording.'), findsOneWidget);
      expect(player.played, isEmpty);
      expect(find.byKey(const ValueKey('call-$first')), findsNothing);
      expect(find.byKey(const ValueKey('call-$second')), findsOneWidget);
      await stop(tester);
    });

    testWidgets('a phone server that does not answer says to try again, and the next press plays', (tester) async {
      final (t, player) = await pumpOrder(
        tester,
        phoneOrder('o1'),
        calls: twoCalls(),
        before: (hub) => hub
          ..refuseAudio = (424, 'pbx_unreachable')
          ..refuseAudioOnce = true,
      );
      await openCalls(tester);
      await press(tester, first);
      await typePin(tester, '9999');
      expect(find.text('The phone server did not answer. Try again in a moment.'), findsOneWidget);
      // the hub itself is well: the screen does not take it for one that is down
      expect(t.api.connection.value.isOnline, isTrue);
      await press(tester, first);
      expect(find.byKey(const ValueKey('calls-message')), findsNothing);
      expect(player.played, hasLength(1));
      await stop(tester);
    });

    testWidgets('a session whose hour is over asks for the PIN again and then plays', (tester) async {
      final (t, player) = await pumpOrder(
        tester,
        phoneOrder('o1'),
        calls: twoCalls(),
        before: (hub) => hub
          ..refuseAudio = (401, 'sign_in')
          ..refuseAudioOnce = true,
      );
      await openCalls(tester);
      await press(tester, first);
      await typePin(tester, '9999');
      expect(player.played, isEmpty);
      await typePin(tester, '9999'); // asked again, by itself
      expect(t.hub.pins, ['9999', '9999']);
      expect(player.played, hasLength(1));
      await stop(tester);
    });

    testWidgets('with no hub answering, a press says so and plays nothing', (tester) async {
      final (t, player) = await pumpOrder(tester, phoneOrder('o1'), calls: twoCalls());
      await openCalls(tester);
      await press(tester, first);
      await typePin(tester, '9999');
      expect(player.played, hasLength(1));
      t.hub.down = true;
      await press(tester, second);
      expect(find.text('The hub is not answering.'), findsOneWidget);
      expect(player.played, hasLength(1));
      await stop(tester);
    });

    testWidgets('on a small phone with large type, the line and the sheet fit', (tester) async {
      final (_, player) = await pumpOrder(
        tester,
        phoneOrder('o1'),
        calls: [...twoCalls(), Hub.recorded('1795739000.303', today(19, 40), seconds: 4000, stereo: true)],
        size: const Size(320, 568),
        textScale: 1.5,
      );
      expect(find.text('3 recorded calls'), findsOneWidget);
      await openCalls(tester);
      await press(tester, first);
      await typePin(tester, '9999');
      expect(player.played, hasLength(1));
      expect(find.byKey(const ValueKey('call-seek')), findsOneWidget);
      expect(tester.takeException(), isNull); // nothing overflows
      await stop(tester);
    });
  });
}
