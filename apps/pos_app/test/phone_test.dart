import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/phone.dart';
import 'package:pos_app/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Stands in for the SIP stack: records what the phone asked of it and lets a test raise the PBX's events.
class FakeStack implements SipStack {
  final started = <PhoneSettings>[];
  int stops = 0;
  SipEvents? events;
  final answered = <String>[];
  final hungUp = <String>[];
  final declined = <String>[];
  final muted = <(String, bool)>[];

  @override
  Future<void> start(PhoneSettings settings, SipEvents events) async {
    started.add(settings);
    this.events = events;
  }

  @override
  Future<void> stop() async {
    stops++;
    events = null;
  }

  @override
  void answer(String callId) => answered.add(callId);

  @override
  void hangUp(String callId) => hungUp.add(callId);

  @override
  void decline(String callId) => declined.add(callId);

  @override
  void setMuted(String callId, bool on) => muted.add((callId, on));
}

const active = PhoneSettings(
  enabled: true,
  server: 'pbx.example.com',
  extension: '301',
  secret: 's3cret',
  displayName: 'mac1',
);

void main() {
  group('PhoneSettings', () {
    test('builds the WebSocket and SIP addresses from the server and the extension', () {
      expect(active.webSocketUrl, 'wss://pbx.example.com:8089/ws');
      expect(active.sipUri, 'sip:301@pbx.example.com');
    });

    test('is only active when switched on and complete', () {
      expect(active.active, isTrue);
      expect(active.copyWith(enabled: false).active, isFalse);
      expect(active.copyWith(secret: '').active, isFalse);
      expect(const PhoneSettings().active, isFalse);
    });

    test('cleans what was typed: scheme, spaces and slashes off the server, spaces off the rest', () {
      final s = PhoneSettings.clean(
        enabled: true,
        server: ' https://pbx.example.com/ ',
        extension: ' 301 ',
        secret: ' s3cret ',
      );
      expect(s.server, 'pbx.example.com');
      expect(s.extension, '301');
      expect(s.secret, 's3cret');
      expect(s.port, 8089);
    });
  });

  group('formatPhoneNumber', () {
    test('groups a North American number and leaves anything else alone', () {
      expect(formatPhoneNumber('7815551234'), '781 555 1234');
      expect(formatPhoneNumber('+17815551234'), '781 555 1234');
      expect(formatPhoneNumber('17815551234'), '781 555 1234');
      expect(formatPhoneNumber('301'), '301');
      expect(formatPhoneNumber('anonymous'), 'anonymous');
      expect(formatPhoneNumber(null), 'Unknown number');
      expect(formatPhoneNumber(''), 'Unknown number');
    });
  });

  group('Settings', () {
    test('remembers the phone settings', () async {
      SharedPreferences.setMockInitialValues({});
      final settings = await Settings.load();
      await settings.savePhone(active);
      final again = await Settings.load();
      expect(again.phone.enabled, isTrue);
      expect(again.phone.server, 'pbx.example.com');
      expect(again.phone.extension, '301');
      expect(again.phone.secret, 's3cret');
    });

    test('uses the device name as the phone display name', () async {
      SharedPreferences.setMockInitialValues({});
      final settings = await Settings.load();
      await settings.save(device: 'mac1', endpoints: ['http://hub']);
      await settings.savePhone(active.copyWith(displayName: ''));
      expect(settings.phone.displayName, 'mac1');
    });
  });

  group('PhoneClient', () {
    late FakeStack stack;
    late PhoneClient phone;
    var now = DateTime(2026, 11, 3, 12, 0, 0);

    setUp(() {
      stack = FakeStack();
      now = DateTime(2026, 11, 3, 12, 0, 0);
      phone = PhoneClient(stack, clock: () => now);
    });

    Future<void> register() async {
      await phone.apply(active);
      stack.events!.registered();
    }

    test('stays off when the phone is not set up', () async {
      await phone.apply(const PhoneSettings());
      expect(phone.state, PhoneState.off);
      expect(stack.started, isEmpty);
    });

    test('connects, then registers', () async {
      await phone.apply(active);
      expect(phone.state, PhoneState.connecting);
      expect(stack.started.single, active);
      stack.events!.registered();
      expect(phone.state, PhoneState.registered);
      expect(phone.problem, isNull);
    });

    test('does not restart the stack when the same settings are applied again', () async {
      await register();
      await phone.apply(active);
      expect(stack.started, hasLength(1));
      expect(stack.stops, 0);
      expect(phone.state, PhoneState.registered);
    });

    test('restarts when the settings change', () async {
      await register();
      await phone.apply(active.copyWith(extension: '302'));
      expect(stack.stops, 1);
      expect(stack.started, hasLength(2));
      expect(stack.started.last.extension, '302');
      expect(phone.state, PhoneState.connecting);
    });

    test('reports a failed registration', () async {
      await phone.apply(active);
      stack.events!.registrationFailed('401 Unauthorized');
      expect(phone.state, PhoneState.failed);
      expect(phone.problem, '401 Unauthorized');
    });

    test('shows a dropped connection as connecting again', () async {
      await register();
      stack.events!.disconnected('socket closed');
      expect(phone.state, PhoneState.connecting);
      expect(phone.problem, 'socket closed');
      stack.events!.registered();
      expect(phone.state, PhoneState.registered);
      expect(phone.problem, isNull);
    });

    test('rings with the caller shown, then answers', () async {
      await register();
      stack.events!.incomingCall('c1', number: '7815551234', name: 'Mike');
      expect(phone.state, PhoneState.ringing);
      expect(phone.callerNumber, '7815551234');
      expect(phone.callerName, 'Mike');
      phone.answer();
      expect(stack.answered, ['c1']);
      stack.events!.callAccepted('c1');
      expect(phone.state, PhoneState.inCall);
      expect(phone.answeredAt, now);
    });

    test('knows it is answering from the tap until the PBX confirms', () async {
      await register();
      stack.events!.incomingCall('c1', number: '7815551234');
      expect(phone.answering, isFalse);
      phone.answer();
      expect(phone.answering, isTrue);
      expect(phone.state, PhoneState.ringing);
      stack.events!.callAccepted('c1');
      expect(phone.answering, isFalse);
      expect(phone.state, PhoneState.inCall);
    });

    test('an answer the PBX never confirms is over when the call ends', () async {
      await register();
      stack.events!.incomingCall('c1', number: '7815551234');
      phone.answer();
      stack.events!.callEnded('c1', '488 Not Acceptable Here');
      expect(phone.answering, isFalse);
      expect(phone.state, PhoneState.registered);
    });

    test('a refreshed registration during a call changes nothing', () async {
      await register();
      stack.events!.incomingCall('c1', number: '7815551234');
      stack.events!.callAccepted('c1');
      stack.events!.registered();
      expect(phone.state, PhoneState.inCall);
      expect(phone.callerNumber, '7815551234');
    });

    test('hangs up and goes back to registered', () async {
      await register();
      stack.events!.incomingCall('c1', number: '7815551234');
      stack.events!.callAccepted('c1');
      phone.hangUp();
      expect(stack.hungUp, ['c1']);
      stack.events!.callEnded('c1', 'Terminated');
      expect(phone.state, PhoneState.registered);
      expect(phone.callerNumber, isNull);
      expect(phone.answeredAt, isNull);
    });

    test('declines a ringing call', () async {
      await register();
      stack.events!.incomingCall('c1', number: '7815551234');
      phone.decline();
      expect(stack.declined, ['c1']);
      stack.events!.callEnded('c1', 'Rejected');
      expect(phone.state, PhoneState.registered);
    });

    test('a call the caller abandons stops ringing', () async {
      await register();
      stack.events!.incomingCall('c1', number: '7815551234');
      stack.events!.callEnded('c1', 'Canceled');
      expect(phone.state, PhoneState.registered);
      expect(phone.callerNumber, isNull);
    });

    test('a second call during a call is declined as busy', () async {
      await register();
      stack.events!.incomingCall('c1', number: '7815551234');
      stack.events!.callAccepted('c1');
      stack.events!.incomingCall('c2', number: '6175550000');
      expect(stack.declined, ['c2']);
      expect(phone.state, PhoneState.inCall);
      expect(phone.callerNumber, '7815551234');
      stack.events!.callEnded('c2', 'Rejected');
      expect(phone.state, PhoneState.inCall);
    });

    test('mutes and unmutes', () async {
      await register();
      stack.events!.incomingCall('c1', number: '7815551234');
      stack.events!.callAccepted('c1');
      phone.toggleMute();
      expect(phone.muted, isTrue);
      phone.toggleMute();
      expect(phone.muted, isFalse);
      expect(stack.muted, [('c1', true), ('c1', false)]);
    });

    test('the mute comes off with the call', () async {
      await register();
      stack.events!.incomingCall('c1', number: '7815551234');
      stack.events!.callAccepted('c1');
      phone.toggleMute();
      stack.events!.callEnded('c1', 'Terminated');
      expect(phone.muted, isFalse);
    });

    test('counts the call time from the answer', () async {
      await register();
      stack.events!.incomingCall('c1', number: '7815551234');
      stack.events!.callAccepted('c1');
      now = now.add(const Duration(seconds: 42));
      expect(phone.callDuration, const Duration(seconds: 42));
    });

    test('stop turns the phone off', () async {
      await register();
      await phone.stop();
      expect(stack.stops, 1);
      expect(phone.state, PhoneState.off);
    });

    test('tells listeners about every change', () async {
      var changes = 0;
      phone.addListener(() => changes++);
      await register();
      stack.events!.incomingCall('c1', number: '7815551234');
      expect(changes, 3);
    });
  });
}
