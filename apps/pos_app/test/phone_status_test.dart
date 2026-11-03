import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/phone.dart';
import 'package:pos_app/screens/status_bar.dart';

import 'counter_test.dart';
import 'phone_test.dart';

/// The phone's state in the status icon: nothing while the phone is off or registered, a red phone mark while it
/// is on but cannot register, and a Phone row in the details sheet whenever the phone is on.
void main() {
  late FakeStack stack;
  late PhoneClient phone;

  setUp(() {
    stack = FakeStack();
    phone = PhoneClient(stack);
  });

  test('the status line says what the phone is doing', () async {
    expect(phoneStatusLine(phone), 'Off. Switch on, fill in the PBX, extension and secret, then save');
    await phone.apply(active);
    expect(phoneStatusLine(phone), 'Connecting to pbx.example.com');
    stack.events!.registered();
    expect(phoneStatusLine(phone), 'Registered as 301 on pbx.example.com');
    stack.events!.incomingCall('c1', number: '7815551234');
    expect(phoneStatusLine(phone), 'Ringing · 781 555 1234');
    stack.events!.callAccepted('c1');
    expect(phoneStatusLine(phone), 'On a call · 781 555 1234');
    stack.events!.callEnded('c1', 'Terminated');
    stack.events!.disconnected('socket closed');
    expect(phoneStatusLine(phone), 'Connecting to pbx.example.com · socket closed');
    stack.events!.registrationFailed('401 Unauthorized');
    expect(phoneStatusLine(phone), 'Not registered: 401 Unauthorized');
  });

  Future<void> pumpIcon(WidgetTester tester) async {
    final t = await terminal(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(
            actions: [StatusIcon(api: t.api, outbox: t.outbox, phone: phone)],
          ),
        ),
      ),
    );
    await tester.pump();
  }

  final mark = find.byKey(const ValueKey('phone-status'));

  testWidgets('a phone that is off, connecting or registered takes no space in the bar', (tester) async {
    await pumpIcon(tester);
    expect(mark, findsNothing);
    await phone.apply(active); // connecting, nothing wrong yet
    await tester.pump();
    expect(mark, findsNothing);
    stack.events!.registered();
    await tester.pump();
    expect(mark, findsNothing);
    expect(find.byKey(const ValueKey('status')), findsOneWidget);
  });

  testWidgets('a phone that cannot register shows a red phone mark that opens the details', (tester) async {
    await pumpIcon(tester);
    await phone.apply(active);
    stack.events!.registrationFailed('401 Unauthorized');
    await tester.pump();
    expect(mark, findsOneWidget);
    await tester.tap(mark);
    await tester.pumpAndSettle();
    expect(find.text('Phone'), findsOneWidget);
    expect(find.text('Not registered: 401 Unauthorized'), findsOneWidget);
    // registering again clears the mark and the row follows
    stack.events!.registered();
    await tester.pumpAndSettle();
    expect(find.text('Registered as 301 on pbx.example.com'), findsOneWidget);
    Navigator.of(tester.element(find.text('Phone'))).pop();
    await tester.pumpAndSettle();
    expect(mark, findsNothing);
  });

  testWidgets('a dropped connection with a reason shows the mark as well', (tester) async {
    await pumpIcon(tester);
    await phone.apply(active);
    stack.events!.registered();
    stack.events!.disconnected('socket closed');
    await tester.pump();
    expect(mark, findsOneWidget);
  });

  testWidgets('the details sheet lists the phone while it is on, and not while it is off', (tester) async {
    await pumpIcon(tester);
    await tester.tap(find.byKey(const ValueKey('status')));
    await tester.pumpAndSettle();
    expect(find.text('Phone'), findsNothing);
    Navigator.of(tester.element(find.text('Everything is sent'))).pop();
    await tester.pumpAndSettle();

    await phone.apply(active);
    stack.events!.registered();
    await tester.tap(find.byKey(const ValueKey('status')));
    await tester.pumpAndSettle();
    expect(find.text('Phone'), findsOneWidget);
    expect(find.text('Registered as 301 on pbx.example.com'), findsOneWidget);
  });
}
