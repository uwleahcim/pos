import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/phone.dart';

import 'counter_test.dart';
import 'phone_test.dart';

/// The caller's number into a to-go order: while a call is on, and for a while after it, the orders screen's
/// To go button names the caller and the order starts with the number, the channel and the caller-ID name.
void main() {
  late FakeStack stack;
  late PhoneClient phone;
  var now = DateTime(2026, 11, 3, 18, 0, 0);

  setUp(() async {
    stack = FakeStack();
    now = DateTime(2026, 11, 3, 18, 0, 0);
    phone = PhoneClient(stack, clock: () => now);
    await phone.apply(active);
    stack.events!.registered();
  });

  Future<void> onCall(WidgetTester tester, {String? name}) async {
    stack.events!.incomingCall('c1', number: '+17815551234', name: name);
    stack.events!.callAccepted('c1');
    await tester.pump();
  }

  testWidgets('while a call is on, To go names the caller and starts the order with the number', (tester) async {
    final t = await pumpOrders(tester, const [], phone: phone);
    expect(find.text('To go'), findsOneWidget);
    await onCall(tester, name: 'Linda Chen');
    expect(find.text('To go · 781 555 1234'), findsOneWidget);

    await tester.tap(find.text('To go · 781 555 1234'));
    await tester.pumpAndSettle();
    expect(find.text('To-go order'), findsOneWidget);
    expect(tester.widget<TextField>(find.byKey(const ValueKey('takeout-name'))).controller!.text, 'Linda Chen');
    expect(tester.widget<TextField>(find.byKey(const ValueKey('takeout-phone'))).controller!.text, '781 555 1234');
    expect(tester.widget<ChoiceChip>(find.byKey(const ValueKey('channel:phone'))).selected, isTrue);
    expect(find.text('Ready in about 20 min'), findsOneWidget); // the phone channel's quote

    await tester.tap(find.byKey(const ValueKey('takeout-start')));
    await tester.pumpAndSettle();
    final (_, create) = t.hub.sent.single;
    final data = create['data'] as Map<String, dynamic>;
    expect(
      (data['order_type'], data['channel'], data['customer_name'], data['phone']),
      ('takeout', 'phone', 'Linda Chen', '781 555 1234'),
    );
    expect(find.textContaining('#… Linda Chen'), findsOneWidget); // the check is open
    await stop(tester);
  });

  testWidgets('a caller without a name leaves the name to type, the number filled in', (tester) async {
    await pumpOrders(tester, const [], phone: phone);
    await onCall(tester, name: 'WIRELESS CALLER');
    await tester.tap(find.text('To go · 781 555 1234'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byKey(const ValueKey('takeout-name'))).controller!.text, 'WIRELESS CALLER');
    await stop(tester);
  });

  testWidgets('To go on the call strip opens the order on the orders screen', (tester) async {
    await pumpOrders(tester, const [], phone: phone);
    await onCall(tester);
    phone.startOrder(); // what the strip's button does, through main.dart
    await tester.pumpAndSettle();
    expect(find.text('To-go order'), findsOneWidget);
    expect(tester.widget<TextField>(find.byKey(const ValueKey('takeout-phone'))).controller!.text, '781 555 1234');
    expect(tester.widget<TextField>(find.byKey(const ValueKey('takeout-name'))).controller!.text, '');
    // a second tap while the form is open does not stack a second form
    phone.startOrder();
    await tester.pumpAndSettle();
    expect(find.text('To-go order'), findsOneWidget);
    await stop(tester);
  });

  testWidgets('after the call ends the caller is still offered for a while, then not', (tester) async {
    await pumpOrders(tester, const [], phone: phone);
    await onCall(tester);
    stack.events!.callEnded('c1', 'Terminated');
    await tester.pump();
    expect(find.text('To go · 781 555 1234'), findsOneWidget);
    now = now.add(const Duration(minutes: 11));
    await tester.pump(const Duration(seconds: 2)); // the list's refresh rebuilds the screen
    await tester.pump();
    expect(find.text('To go'), findsOneWidget);
    expect(find.text('To go · 781 555 1234'), findsNothing);
    await stop(tester);
  });

  testWidgets('without a phone the button is the plain To go', (tester) async {
    await pumpOrders(tester, const []);
    expect(find.text('To go'), findsOneWidget);
    await stop(tester);
  });
}
