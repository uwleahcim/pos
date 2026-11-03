import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/phone.dart';
import 'package:pos_app/ringer.dart';

import 'phone_test.dart';

/// Stands in for the device's sound: remembers whether it is ringing and how often it was started.
class FakeRinger implements Ringer {
  int starts = 0;
  int stops = 0;
  bool ringing = false;

  @override
  Future<void> start() async {
    starts++;
    ringing = true;
  }

  @override
  Future<void> stop() async {
    stops++;
    ringing = false;
  }
}

void main() {
  late FakeStack stack;
  late PhoneClient phone;
  late FakeRinger bell;
  late CallRinger ringer;

  setUp(() async {
    stack = FakeStack();
    phone = PhoneClient(stack);
    bell = FakeRinger();
    ringer = CallRinger(phone, bell);
    await phone.apply(active);
    stack.events!.registered();
  });

  tearDown(() => ringer.dispose());

  test('rings from the moment a call comes in until it is answered', () {
    expect(bell.ringing, isFalse);
    stack.events!.incomingCall('c1', number: '7815551234');
    expect(bell.ringing, isTrue);
    stack.events!.callAccepted('c1');
    expect(bell.ringing, isFalse);
    expect(bell.starts, 1);
  });

  test('stops the moment Answer is tapped, before the PBX confirms the call', () {
    stack.events!.incomingCall('c1', number: '7815551234');
    phone.answer();
    expect(bell.ringing, isFalse);
    stack.events!.callAccepted('c1');
    expect(bell.starts, 1);
    expect(bell.stops, 1);
  });

  test('stops when the caller gives up before anyone answers', () {
    stack.events!.incomingCall('c1', number: '7815551234');
    stack.events!.callEnded('c1', 'Canceled');
    expect(bell.ringing, isFalse);
    expect(bell.stops, 1);
  });

  test('stops when the call is declined', () {
    stack.events!.incomingCall('c1', number: '7815551234');
    phone.decline();
    stack.events!.callEnded('c1', '486 Busy Here');
    expect(bell.ringing, isFalse);
  });

  test('starts once however much else the phone reports while it rings', () {
    stack.events!.incomingCall('c1', number: '7815551234');
    stack.events!.disconnected('connection lost');
    stack.events!.registered();
    expect(bell.starts, 1);
    expect(bell.ringing, isTrue);
  });

  test('a second call while one rings changes nothing', () {
    stack.events!.incomingCall('c1', number: '7815551234');
    stack.events!.incomingCall('c2', number: '6175550000');
    expect(bell.starts, 1);
    expect(bell.stops, 0);
  });

  test('a call that is already on when the ringer is made rings at once', () {
    stack.events!.incomingCall('c1', number: '7815551234');
    final late = FakeRinger();
    final second = CallRinger(phone, late);
    expect(late.ringing, isTrue);
    second.dispose();
    expect(late.ringing, isFalse);
  });

  test('disposing in the middle of a ring stops the sound', () {
    stack.events!.incomingCall('c1', number: '7815551234');
    ringer.dispose();
    expect(bell.ringing, isFalse);
    // and the phone's later events no longer reach the disposed ringer
    stack.events!.callEnded('c1', 'Canceled');
    expect(bell.stops, 1);
  });
}
