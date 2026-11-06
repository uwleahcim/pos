import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/session.dart';
import 'package:pos_app/settings.dart';
import 'package:pos_app/switching.dart';

import 'hub.dart';

Map<String, dynamic> person(String id, String name, String method) => {
  'staff_id': id,
  'name': name,
  'role': 'server',
  'method': method,
  'preferences': {'text_scale': 1.0, 'high_contrast': false, 'locale': 'en'},
};

void main() {
  testWidgets('a change of person closes what the last one had open, and a hands-free one says hello', (tester) async {
    final settings = Settings(device: 't1', endpoints: ['http://hub:8000']);
    final session = Session(PosApi(settings, client: MockClient(Hub().handle)));
    final navigator = GlobalKey<NavigatorState>();
    final messenger = GlobalKey<ScaffoldMessengerState>();
    final watcher = SessionWatcher(session, navigator: navigator, messenger: messenger);
    addTearDown(watcher.dispose);
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        scaffoldMessengerKey: messenger,
        home: const Scaffold(body: Text('home')),
      ),
    );
    session.applySignIn(person('s1', 'Amy', 'pin'));
    await tester.pump();
    expect(find.text('Hi Amy'), findsNothing, reason: 'a PIN sign-in from nobody: no hello');
    navigator.currentState!.push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('an order'))));
    await tester.pumpAndSettle();
    expect(find.text('an order'), findsOneWidget);
    session.applySignIn(person('s2', 'Ben', 'face'));
    await tester.pumpAndSettle();
    expect(find.text('an order'), findsNothing, reason: 'Amy\'s order screen went with her');
    expect(find.text('home'), findsOneWidget);
    expect(find.text('Hi Ben'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(find.text('Hi Ben'), findsNothing);
    navigator.currentState!.push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('settings'))));
    await tester.pumpAndSettle();
    session.signOut();
    await tester.pumpAndSettle();
    expect(find.text('settings'), findsNothing, reason: 'a sign-out closes it too');
    expect(find.textContaining('Hi '), findsNothing);
    session.applySignIn(person('s2', 'Ben', 'tag'));
    await tester.pumpAndSettle();
    expect(find.text('Hi Ben'), findsNothing, reason: 'from nobody signed in, a tag is a plain sign-in');
    session.applySignIn(person('s1', 'Amy', 'tag'));
    await tester.pumpAndSettle();
    expect(find.text('Hi Amy'), findsOneWidget, reason: 'a switch by tag says hello');
  });
}
