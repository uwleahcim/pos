import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/call_screen.dart';
import 'package:pos_app/phone.dart';
import 'package:pos_app/ringer.dart';

import 'phone_test.dart' show FakeStack, active;

/// Stands in for the device's own call screen: records what the phone asked of it.
class FakeScreen implements CallScreen {
  FakeScreen({this.routesActions = false});

  @override
  final bool routesActions;
  final awake = <bool>[];
  final shown = <(String, String?, String?)>[];
  final answered = <String>[];
  final endedByApp = <String>[];
  final connectedIds = <String>[];
  final over = <(String, String)>[];
  final woken = <(String, String)>[];
  CallScreenEvents? events;
  bool readied = false;

  @override
  void keepAwake(bool on) => awake.add(on);
  @override
  void incoming(String id, {String? number, String? name}) => shown.add((id, number, name));
  @override
  void answer(String id) => answered.add(id);
  @override
  void end(String id) => endedByApp.add(id);
  @override
  void connected(String id) => connectedIds.add(id);
  @override
  void ended(String id, {required String reason}) => over.add((id, reason));
  @override
  void wake({required String title, required String body}) => woken.add((title, body));
  @override
  Future<Map<String, bool>> readiness() async => const {'notifications': false};
  @override
  Future<void> prepare() async {}
  @override
  void ready() => readied = true;
}

class FakeRinger implements Ringer {
  int starts = 0;
  int stops = 0;
  @override
  Future<void> start() async => starts++;
  @override
  Future<void> stop() async => stops++;
}

const number = '+16175551234';

void main() {
  var now = DateTime(2026, 11, 6, 12, 0, 0);
  var foreground = true;
  CallOnHub onHub = const CallOnHub(CallProgress.ringing);

  setUp(() {
    now = DateTime(2026, 11, 6, 12, 0, 0);
    foreground = true;
    onHub = const CallOnHub(CallProgress.ringing);
  });

  /// A registered phone on an iPhone-like screen (the system's call screen owns Answer and End).
  (PhoneClient, FakeStack, FakeScreen) phone({bool routes = true, bool on = true}) {
    final stack = FakeStack();
    final screen = FakeScreen(routesActions: routes);
    final client = PhoneClient(
      stack,
      clock: () => now,
      screen: screen,
      callState: (id) async => onHub,
      isForeground: () => foreground,
    );
    if (on) {
      client.apply(active);
      stack.events!.registered();
    }
    return (client, stack, screen);
  }

  group('a push for a call', () {
    test('rings on the screen before the invite, which then attaches to it', () {
      fakeAsync((async) {
        final (client, stack, screen) = phone();
        client.pushed('L1', number: number, name: 'LINDA CHEN');
        expect(client.state, PhoneState.ringing);
        expect(client.pushedId, 'L1');
        expect(client.screenRings, isTrue);
        expect(client.caller, const Caller(number: number, name: 'LINDA CHEN'));
        expect(stack.started, hasLength(1)); // registered and in front: the invite is given a moment
        async.elapse(const Duration(seconds: 1));
        stack.events!.incomingCall('sip1', number: '617-555-1234', name: 'CID');
        expect(client.state, PhoneState.ringing);
        expect(client.pushedId, 'L1');
        expect(client.callerName, 'LINDA CHEN'); // the push's words stay
        async.elapse(const Duration(seconds: 10));
        expect(stack.started, hasLength(1)); // the invite came: no need to register anew
        expect(client.state, PhoneState.ringing);
        // Answer in the app goes through the screen, which owns the call; the stack hears from the screen.
        client.answer();
        expect(client.answering, isTrue);
        expect(screen.answered, ['L1']);
        expect(stack.answered, isEmpty);
        client.screenAnswered('L1');
        expect(stack.answered, ['sip1']);
        stack.events!.callAccepted('sip1');
        expect(client.state, PhoneState.inCall);
        expect(screen.connectedIds, ['L1']);
        client.screenMuted('L1', true);
        expect(client.muted, isTrue);
        expect(stack.muted, [('sip1', true)]);
        client.hangUp();
        expect(screen.endedByApp, ['L1']);
        expect(stack.hungUp, isEmpty);
        client.screenEnded('L1');
        expect(stack.hungUp, ['sip1']);
        stack.events!.callEnded('sip1', null);
        expect(client.state, PhoneState.registered);
        expect(screen.over, [('L1', 'remoteEnded')]);
        expect(client.recentCaller, const Caller(number: number, name: 'LINDA CHEN'));
      });
    });

    test('answered on the screen before the invite is answered the moment the invite arrives', () {
      fakeAsync((async) {
        final (client, stack, screen) = phone();
        client.pushed('L1', number: number);
        client.screenAnswered('L1');
        expect(client.answering, isTrue);
        expect(stack.answered, isEmpty);
        stack.events!.incomingCall('sip1', number: number);
        expect(stack.answered, ['sip1']);
        expect(client.answering, isTrue);
        stack.events!.callAccepted('sip1');
        expect(client.state, PhoneState.inCall);
        expect(screen.over, isEmpty);
      });
    });

    test('registers anew when the invite does not follow a push on a phone that believes itself registered', () {
      fakeAsync((async) {
        final (client, stack, _) = phone();
        client.pushed('L1', number: number);
        async.elapse(PhoneClient.graceFor);
        async.flushMicrotasks();
        expect(stack.stops, 1);
        expect(stack.started, hasLength(2));
        expect(client.state, PhoneState.ringing); // the ring stays through the registration
        stack.events!.registered();
        expect(client.state, PhoneState.ringing);
        stack.events!.incomingCall('sip1', number: number);
        expect(client.pushedId, 'L1');
      });
    });

    test('registers anew at once when the app was in the background or the connection dropped', () {
      fakeAsync((async) {
        foreground = false;
        final (client, stack, _) = phone();
        client.pushed('L1', number: number);
        async.flushMicrotasks();
        expect(stack.started, hasLength(2));
        foreground = true;
        final (client2, stack2, _) = phone();
        stack2.events!.disconnected('connection lost');
        client2.pushed('L2', number: number);
        async.flushMicrotasks();
        expect(stack2.started, hasLength(2));
        final (client3, stack3, _) = phone();
        client3.paused();
        client3.pushed('L3', number: number);
        async.flushMicrotasks();
        expect(stack3.started, hasLength(2));
      });
    });

    test('is given up when the invite never comes', () {
      fakeAsync((async) {
        final (client, stack, screen) = phone();
        client.pushed('L1', number: number);
        async.elapse(PhoneClient.expectFor);
        expect(client.state, PhoneState.registered);
        expect(client.pushedId, isNull);
        expect(screen.over, [('L1', 'unanswered')]);
        stack.events!.incomingCall('sip1', number: number); // a late invite rings as any call
        expect(client.state, PhoneState.ringing);
        expect(client.pushedId, isNull);
      });
    });

    test('comes down when the hub says another phone answered, or the caller gave up', () {
      fakeAsync((async) {
        final (client, _, screen) = phone();
        client.pushed('L1', number: number);
        onHub = const CallOnHub(CallProgress.answered, answered: ['301']); // this phone's own extension
        async.elapse(const Duration(seconds: 2));
        expect(client.state, PhoneState.ringing);
        onHub = const CallOnHub(CallProgress.answered, answered: ['200']);
        async.elapse(const Duration(seconds: 2));
        expect(client.state, PhoneState.registered);
        expect(screen.over, [('L1', 'answeredElsewhere')]);
        client.pushed('L2', number: number);
        onHub = const CallOnHub(CallProgress.ended);
        async.elapse(const Duration(seconds: 2));
        expect(screen.over.last, ('L2', 'remoteEnded'));
        expect(client.state, PhoneState.registered);
      });
    });

    test('declined on the screen is remembered, so the late invite of the same call is turned away', () {
      fakeAsync((async) {
        final (client, stack, screen) = phone();
        client.pushed('L1', number: number);
        client.screenEnded('L1');
        expect(client.state, PhoneState.registered);
        expect(screen.over, isEmpty); // the screen ended it itself
        stack.events!.incomingCall('sip1', number: '617-555-1234');
        expect(stack.declined, ['sip1']);
        expect(client.state, PhoneState.registered);
        client.pushed('L1', number: number); // the next ring-group pass pushes again
        expect(screen.over, [('L1', 'declinedElsewhere')]);
        expect(client.state, PhoneState.registered);
        now = now.add(PhoneClient.declinedFor + const Duration(seconds: 1));
        stack.events!.incomingCall('sip2', number: number);
        expect(client.state, PhoneState.ringing);
      });
    });

    test('for a phone that is off here, or busy, is sent back at once', () {
      fakeAsync((async) {
        final (client, _, screen) = phone(on: false);
        client.pushed('L1', number: number);
        expect(client.state, PhoneState.off);
        expect(screen.over, [('L1', 'failed')]);
        final (busy, stack, screen2) = phone();
        stack.events!.incomingCall('sip1', number: number);
        busy.pushed('L2', number: '+16175550000');
        expect(screen2.over, [('L2', 'unanswered')]);
        expect(busy.state, PhoneState.ringing);
        expect(busy.pushedId, isNull);
      });
    });

    test('that is a test call rings and goes away by itself, at once when answered', () {
      fakeAsync((async) {
        final (client, _, screen) = phone(on: false);
        client.pushed('t1', name: 'POS test call', test: true);
        expect(client.state, PhoneState.ringing);
        expect(client.testCall, isTrue);
        expect(client.callerName, 'POS test call');
        async.elapse(PhoneClient.testRingsFor);
        expect(client.state, PhoneState.off);
        expect(screen.over, [('t1', 'unanswered')]);
        client.pushed('t2', name: 'POS test call', test: true);
        client.screenAnswered('t2');
        expect(screen.over.last, ('t2', 'remoteEnded'));
        expect(client.state, PhoneState.off);
      });
    });

    test('switching the phone off takes a pushed call down with it', () {
      fakeAsync((async) {
        final (client, _, screen) = phone();
        client.pushed('L1', number: number);
        client.apply(active.copyWith(enabled: false));
        expect(screen.over, [('L1', 'failed')]);
        expect(client.state, PhoneState.off);
      });
    });
  });

  group('the screen for a call the invite brought', () {
    test('owns Answer and End on iOS, and rings instead of the app', () {
      fakeAsync((async) {
        final (client, stack, screen) = phone();
        stack.events!.incomingCall('sip1', number: number, name: 'LINDA CHEN');
        expect(screen.shown, [('sip1', number, 'LINDA CHEN')]);
        expect(client.screenRings, isTrue);
        client.decline();
        expect(screen.endedByApp, ['sip1']);
        expect(stack.declined, isEmpty);
        client.screenEnded('sip1');
        expect(stack.declined, ['sip1']);
        stack.events!.callEnded('sip1', '486 Busy Here');
        expect(screen.over, [('sip1', 'unanswered')]);
        stack.events!.incomingCall('sip2', number: number); // declining a plain call turns no later one away
        expect(client.state, PhoneState.ringing);
        client.answer();
        expect(screen.answered, ['sip2']);
        client.screenAnswered('sip2');
        expect(stack.answered, ['sip2']);
      });
    });

    test('that it refuses after all is rung and answered by the app itself', () {
      fakeAsync((async) {
        final (client, stack, screen) = phone();
        stack.events!.incomingCall('sip1', number: number);
        expect(client.screenRings, isTrue);
        client.screenGone('sip1'); // a Focus mode kept the system's screen from showing it
        expect(client.screenRings, isFalse);
        client.answer();
        expect(stack.answered, ['sip1']);
        expect(screen.answered, isEmpty);
        stack.events!.callAccepted('sip1');
        client.hangUp();
        expect(stack.hungUp, ['sip1']);
        client.screenGone('sip2'); // not the call on: nothing
      });
    });

    test('is only told on Android and Mac: the app rings and acts itself', () {
      fakeAsync((async) {
        final (client, stack, screen) = phone(routes: false);
        stack.events!.incomingCall('sip1', number: number);
        expect(screen.shown, [('sip1', number, null)]);
        expect(client.screenRings, isFalse);
        client.answer();
        expect(stack.answered, ['sip1']);
        expect(screen.answered, isEmpty);
        stack.events!.callAccepted('sip1');
        expect(screen.connectedIds, ['sip1']);
        client.hangUp();
        expect(stack.hungUp, ['sip1']);
        stack.events!.callEnded('sip1', null);
        expect(screen.over, [('sip1', 'remoteEnded')]);
        stack.events!.incomingCall('sip2', number: number);
        client.decline();
        expect(stack.declined, ['sip2']);
        stack.events!.callEnded('sip2', '486');
        expect(screen.over.last, ('sip2', 'unanswered'));
      });
    });
  });

  group('the app coming back', () {
    test('starts the connection over after a long pause, not a short one, never on a call', () {
      fakeAsync((async) {
        final (client, stack, _) = phone();
        client.paused();
        now = now.add(const Duration(seconds: 5));
        client.resumed();
        async.flushMicrotasks();
        expect(stack.started, hasLength(1));
        client.paused();
        now = now.add(const Duration(minutes: 5));
        client.resumed();
        async.flushMicrotasks();
        expect(stack.started, hasLength(2));
        expect(client.state, PhoneState.connecting);
        stack.events!.registered();
        stack.events!.incomingCall('sip1', number: number);
        client.paused();
        now = now.add(const Duration(minutes: 5));
        client.resumed();
        async.flushMicrotasks();
        expect(stack.started, hasLength(2));
      });
    });
  });

  group('the ringer', () {
    test('keeps quiet while the device\'s screen rings', () {
      fakeAsync((async) {
        final (client, stack, _) = phone();
        final ringer = FakeRinger();
        CallRinger(client, ringer);
        stack.events!.incomingCall('sip1', number: number); // the system's screen rings for it
        async.flushMicrotasks();
        expect(ringer.starts, 0);
        stack.events!.callEnded('sip1', null);
        final (android, stack2, _) = phone(routes: false);
        CallRinger(android, ringer);
        stack2.events!.incomingCall('sip1', number: number);
        async.flushMicrotasks();
        expect(ringer.starts, 1);
        android.answer();
        async.flushMicrotasks();
        expect(ringer.stops, 1);
      });
    });
  });

  group('the native screen over its channel', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    const channel = MethodChannel('org.chinasky.pos/calls');

    test('sends the phone\'s calls and hands the device\'s events on', () async {
      final sent = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        sent.add(call);
        if (call.method == 'readiness') return {'notifications': true, 'battery': false};
        return null;
      });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null),
      );
      final screen = NativeCallScreen(routesActions: true);
      final heard = <String>[];
      screen.events = _Events(heard);
      screen.ready();
      screen.keepAwake(true);
      screen.incoming('sip1', number: number, name: 'LINDA CHEN');
      screen.answer('sip1');
      screen.connected('sip1');
      screen.end('sip1');
      screen.ended('sip1', reason: 'remoteEnded');
      screen.wake(title: 'Phone 200 picked up', body: '(617) 555-1234');
      expect(await screen.readiness(), {'notifications': true, 'battery': false});
      await screen.prepare();
      expect(
        [for (final c in sent) c.method],
        ['ready', 'keepAwake', 'incoming', 'answer', 'connected', 'end', 'ended', 'wake', 'readiness', 'prepare'],
      );
      expect(sent[1].arguments, {'on': true});
      expect(sent[2].arguments, {'id': 'sip1', 'number': number, 'name': 'LINDA CHEN'});
      expect(sent[6].arguments, {'id': 'sip1', 'reason': 'remoteEnded'});
      expect(sent[7].arguments, {'title': 'Phone 200 picked up', 'body': '(617) 555-1234'});

      Future<void> fromNative(String method, Map<String, Object?> args) async {
        await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
          channel.name,
          channel.codec.encodeMethodCall(MethodCall(method, args)),
          (_) {},
        );
      }

      await fromNative('token', {'kind': 'voip', 'token': 'abcd'});
      await fromNative('pushed', {'id': 'L1', 'number': number, 'name': '', 'test': false});
      await fromNative('pushed', {'id': 't1', 'number': '', 'name': 'POS test call', 'test': true});
      await fromNative('answer', {'id': 'L1'});
      await fromNative('mute', {'id': 'L1', 'on': true});
      await fromNative('end', {'id': 'L1'});
      await fromNative('gone', {'id': 'L1'});
      await fromNative('opened', {});
      expect(heard, [
        'token voip abcd',
        'pushed L1 $number null',
        'pushed t1 null POS test call test',
        'answered L1',
        'muted L1 true',
        'ended L1',
        'gone L1',
        'opened',
      ]);
    });
  });
}

class _Events implements CallScreenEvents {
  _Events(this.heard);
  final List<String> heard;
  @override
  void pushToken(String kind, String token) => heard.add('token $kind $token');
  @override
  void pushed(String id, {String? number, String? name, bool test = false}) =>
      heard.add('pushed $id $number $name${test ? ' test' : ''}');
  @override
  void screenAnswered(String id) => heard.add('answered $id');
  @override
  void screenEnded(String id) => heard.add('ended $id');
  @override
  void screenMuted(String id, bool on) => heard.add('muted $id $on');
  @override
  void screenGone(String id) => heard.add('gone $id');
  @override
  void opened() => heard.add('opened');
}
