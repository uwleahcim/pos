import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/phone.dart';
import 'package:pos_app/screens/phone_bar.dart';

import 'phone_test.dart';

void main() {
  late FakeStack stack;
  late PhoneClient phone;

  setUp(() {
    stack = FakeStack();
    phone = PhoneClient(stack);
  });

  Future<void> pumpBar(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: PhoneBar(
          client: phone,
          child: const Scaffold(body: Text('orders')),
        ),
      ),
    );
    await phone.apply(active);
    stack.events!.registered();
    await tester.pump();
  }

  testWidgets('shows nothing while no call is on', (tester) async {
    await pumpBar(tester);
    expect(find.text('orders'), findsOneWidget);
    expect(find.text('Answer'), findsNothing);
    expect(find.byIcon(Icons.call_end), findsNothing);
  });

  testWidgets('rings with the caller and answers on tap', (tester) async {
    await pumpBar(tester);
    stack.events!.incomingCall('c1', number: '7815551234', name: 'Mike');
    await tester.pump();
    expect(find.text('781 555 1234'), findsOneWidget);
    expect(find.text('Mike'), findsOneWidget);
    expect(find.text('orders'), findsOneWidget);
    await tester.tap(find.text('Answer'));
    await tester.pump();
    expect(stack.answered, ['c1']);
  });

  testWidgets('declines on tap', (tester) async {
    await pumpBar(tester);
    stack.events!.incomingCall('c1', number: '7815551234');
    await tester.pump();
    await tester.tap(find.text('Decline'));
    expect(stack.declined, ['c1']);
  });

  testWidgets('the strip survives a mouse hover above the navigator, where main.dart mounts it', (tester) async {
    // main.dart mounts the bar through MaterialApp.builder, above the navigator and its overlay.
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => PhoneBar(client: phone, child: child ?? const SizedBox.shrink()),
        home: const Scaffold(body: Text('orders')),
      ),
    );
    await phone.apply(active);
    stack.events!.registered();
    stack.events!.incomingCall('c1', number: '7815551234');
    stack.events!.callAccepted('c1');
    await tester.pump();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer();
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.byIcon(Icons.mic)));
    await tester.pump(const Duration(seconds: 2));
    expect(tester.takeException(), isNull);
    await tester.tap(find.byIcon(Icons.mic));
    await tester.pump();
    expect(stack.muted, [('c1', true)]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('in a call shows the number, mute and hang up', (tester) async {
    await pumpBar(tester);
    stack.events!.incomingCall('c1', number: '7815551234');
    stack.events!.callAccepted('c1');
    await tester.pump();
    expect(find.text('Answer'), findsNothing);
    expect(find.text('781 555 1234'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.mic));
    await tester.pump();
    expect(stack.muted, [('c1', true)]);
    expect(find.byIcon(Icons.mic_off), findsOneWidget);
    await tester.tap(find.byIcon(Icons.call_end));
    expect(stack.hungUp, ['c1']);
    stack.events!.callEnded('c1', 'Terminated');
    await tester.pump();
    expect(find.byIcon(Icons.call_end), findsNothing);
  });
}
