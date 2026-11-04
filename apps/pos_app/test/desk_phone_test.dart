import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/desk_phone.dart';
import 'package:pos_app/desk_phone_watcher.dart';
import 'package:pos_app/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'counter_test.dart';
import 'coursing_test.dart' show pumpLocation;
import 'phone_test.dart' show active;

/// Desk phones linked to screens: a call taken on a desk phone opens the caller's order on the linked screen
/// as if the screen had taken the call itself. The hub keeps the answers (`GET /phones/answered?device=`); the
/// app asks for them and opens the caller's last order of the day, or the to-go form with the number. A
/// manager links the phones under Location settings (`PUT /settings/desk_phones`).
void main() {
  var now = DateTime(2026, 11, 4, 18, 0, 0);

  Map<String, dynamic> call({String id = '1730000000.123:200', String extension = '200', int ageMs = 800}) => {
    'id': id,
    'extension': extension,
    'number': '+16175551234',
    'name': 'LINDA CHEN',
    'dialed': '+17817296899',
    'at': 1730000000000,
    'age_ms': ageMs,
  };

  setUp(() => now = DateTime(2026, 11, 4, 18, 0, 0));

  /// A watcher on a hub of its own, polled by hand.
  Future<(Hub, DeskPhoneWatcher)> watcher({DateTime Function()? clock}) async {
    SharedPreferences.setMockInitialValues({});
    final settings = Settings(
      device: 'tab1',
      endpoints: ['http://hub:8000'],
      prefs: await SharedPreferences.getInstance(),
    );
    final hub = Hub();
    final api = PosApi(settings, client: MockClient(hub.handle));
    final w = DeskPhoneWatcher(api, settings, clock: clock ?? () => now);
    addTearDown(w.stop);
    return (hub, w);
  }

  group('the watcher', () {
    test('reports a call once and offers it while it is fresh', () async {
      final (hub, w) = await watcher();
      hub.linked = true;
      hub.answered.add(call());
      var told = 0;
      w.addListener(() => told++);
      await w.poll();
      expect((w.calls, told, w.linked), (1, 1, true));
      final taken = w.take()!;
      expect(
        (taken.id, taken.extension, taken.caller.number, taken.caller.name),
        ('1730000000.123:200', '200', '+16175551234', 'LINDA CHEN'),
      );
      expect(taken.answeredAt, now.subtract(const Duration(milliseconds: 800))); // the hub's age, not its clock
      expect(w.take(), isNull); // taken once
      await w.poll(); // the hub still lists it for two minutes
      expect((w.calls, told), (1, 1));
      expect(hub.answeredAsked, ['tab1', 'tab1']);
    });

    test('a call answered more than 45 seconds ago is too old to open anything', () async {
      final (hub, w) = await watcher();
      hub.answered.add(call(ageMs: 46000));
      await w.poll();
      expect(w.calls, 1);
      expect(w.take(), isNull);
      hub.answered.add(call(id: 'x:201', extension: '201'));
      await w.poll();
      now = now.add(const Duration(seconds: 30));
      expect(w.take()?.extension, '201');
    });

    test('a newer call takes the place of one not yet taken', () async {
      final (hub, w) = await watcher();
      hub.answered.add(call());
      await w.poll();
      hub.answered.add(call(id: 'y:201', extension: '201'));
      await w.poll();
      expect(w.take()?.extension, '201');
      expect(w.take(), isNull);
    });

    test('asks the hub every second while a phone is linked, every ten seconds when none is', () async {
      late FakeAsync fake;
      final (hub, w) = await watcher(clock: () => now.add(fake.elapsed));
      fakeAsync((async) {
        fake = async;
        w.start();
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 30));
        expect(hub.answeredAsked.length, inInclusiveRange(3, 5)); // at 0, 10, 20, 30
        hub.linked = true;
        async.elapse(const Duration(seconds: 10)); // the next answer says linked: from then on every second
        final before = hub.answeredAsked.length;
        async.elapse(const Duration(seconds: 10));
        expect(hub.answeredAsked.length - before, inInclusiveRange(9, 11));
        w.stop();
      });
    });

    test('a hub that does not answer is asked again later, quietly', () async {
      final (hub, w) = await watcher();
      hub.answeredDown = true;
      await w.poll();
      expect((w.calls, w.linked), (0, false));
      hub.answeredDown = false;
      hub.answered.add(call());
      await w.poll();
      expect(w.calls, 1);
    });
  });

  group('a desk phone answers', () {
    /// The hub lists the call for this device, and the watcher sees it on its next poll.
    Future<void> pickedUp(WidgetTester tester, Terminal t, DeskPhoneWatcher w, {String extension = '200'}) async {
      t.hub.answered.add(call(extension: extension, id: 'c:$extension'));
      await w.poll();
      await tester.pumpAndSettle();
    }

    testWidgets('brings up the last order the number opened today', (tester) async {
      final order = takeout('o5', no: 12, name: 'Linda', channel: 'phone');
      final t = await pumpOrders(tester, [
        order,
      ], deskPhones: (api, settings) => DeskPhoneWatcher(api, settings, clock: () => now));
      t.hub.lastOrder = order;
      await pickedUp(tester, t, t.deskPhones!);
      expect(t.hub.lastOrderAsked, ['+16175551234']);
      expect(find.textContaining('#12 Linda'), findsOneWidget); // the check is open
      expect(find.text('To-go order'), findsNothing);
      await stop(tester);
    });

    testWidgets('with no order today it opens the to-go form with the number and the name', (tester) async {
      final t = await pumpOrders(
        tester,
        const [],
        deskPhones: (api, settings) => DeskPhoneWatcher(api, settings, clock: () => now),
      );
      await pickedUp(tester, t, t.deskPhones!);
      expect(find.text('To-go order'), findsOneWidget);
      expect(tester.widget<TextField>(find.byKey(const ValueKey('takeout-name'))).controller!.text, 'LINDA CHEN');
      expect(tester.widget<TextField>(find.byKey(const ValueKey('takeout-phone'))).controller!.text, '617 555 1234');
      expect(tester.widget<ChoiceChip>(find.byKey(const ValueKey('channel:phone'))).selected, isTrue);
      // the same call listed again on the next poll opens nothing more
      await t.deskPhones!.poll();
      await tester.pumpAndSettle();
      expect(find.text('To-go order'), findsOneWidget);
      await stop(tester);
    });

    testWidgets('a call this terminal took in the app is left to the app', (tester) async {
      final t = await pumpOrders(
        tester,
        const [],
        deskPhones: (api, settings) => DeskPhoneWatcher(api, settings, clock: () => now),
      );
      await t.settings.savePhone(active.copyWith(extension: '200')); // this terminal is extension 200 itself
      await pickedUp(tester, t, t.deskPhones!, extension: '200');
      expect(find.text('To-go order'), findsNothing);
      expect(t.hub.lastOrderAsked, isEmpty);
      await pickedUp(tester, t, t.deskPhones!, extension: '201'); // a desk phone linked here: the usual
      expect(find.text('To-go order'), findsOneWidget);
      await stop(tester);
    });

    testWidgets('a call answered just before someone signs in opens when the orders screen comes up', (tester) async {
      late DeskPhoneWatcher w;
      final t = await pumpOrders(
        tester,
        const [],
        deskPhones: (api, settings) => w = DeskPhoneWatcher(api, settings, clock: () => now),
        before: (hub) async {
          hub.answered.add(call(ageMs: 20000)); // picked up 20 s ago, while the sign-in screen was showing
          await w.poll();
        },
        showList: false, // the form is already up; a tap outside it would put it away
      );
      expect(find.text('To-go order'), findsOneWidget);
      expect(tester.widget<TextField>(find.byKey(const ValueKey('takeout-phone'))).controller!.text, '617 555 1234');
      await stop(tester);
      expect(t.hub.lastOrderAsked, ['+16175551234']);
    });

    testWidgets('a call answered long before is not', (tester) async {
      late DeskPhoneWatcher w;
      await pumpOrders(
        tester,
        const [],
        deskPhones: (api, settings) => w = DeskPhoneWatcher(api, settings, clock: () => now),
        before: (hub) async {
          hub.answered.add(call(ageMs: 90000));
          await w.poll();
        },
        showList: false,
      );
      expect(find.text('To-go order'), findsNothing);
      await stop(tester);
    });
  });

  group('Location settings', () {
    /// The whole screen in view, so the Desk phones card at the bottom needs no scrolling.
    Future<void> tall(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1100, 1700);
      await tester.pumpAndSettle();
    }

    testWidgets('a manager links a desk phone to a screen', (tester) async {
      final t = await pumpLocation(tester);
      await tall(tester);
      expect(find.textContaining('not linked to the PBX'), findsOneWidget);
      expect(find.text('No desk phone is linked yet.'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('desk-add')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('desk-ext:0')), '200');
      await tester.tap(find.byKey(const ValueKey('desk-this-device:0'))); // the device this screen runs on
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(find.byKey(const ValueKey('desk-dev:0'))).controller!.text, 't1');
      await tester.tap(find.byKey(const ValueKey('desk-add')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('desk-ext:1')), '201');
      await tester.enterText(find.byKey(const ValueKey('desk-dev:1')), 'ipad1');
      await tester.tap(find.byKey(const ValueKey('desk-phones-save')));
      await tester.pumpAndSettle();
      expect(t.hub.deskPhones, {
        'links': [
          {'extension': '200', 'device': 't1'},
          {'extension': '201', 'device': 'ipad1'},
        ],
      });
      expect(t.hub.deskPhonesAuth, 'Bearer tok-admin');
      expect(find.text('Desk phones saved'), findsOneWidget);
      await stop(tester);
    });

    testWidgets('the links come back from the hub, a row can go, and a refusal shows', (tester) async {
      final t = await pumpLocation(
        tester,
        setUp: (hub) {
          hub.deskPhones = {
            'links': [
              {'extension': '200', 'device': 'tab1'},
              {'extension': '201', 'device': 'mac1'},
            ],
          };
          hub.pbxStatus = {'configured': true, 'connected': true, 'host': 'pbx', 'answers': 3, 'pops': 2, 'links': 2};
        },
      );
      await tall(tester);
      expect(find.textContaining('watching pbx'), findsOneWidget);
      expect(tester.widget<TextField>(find.byKey(const ValueKey('desk-dev:1'))).controller!.text, 'mac1');
      await tester.tap(find.byKey(const ValueKey('desk-delete:0')));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(find.byKey(const ValueKey('desk-ext:0'))).controller!.text, '201');
      t.hub.refuseDeskPhones = 'extension 201 is linked twice';
      await tester.tap(find.byKey(const ValueKey('desk-phones-save')));
      await tester.pumpAndSettle();
      expect(find.text('extension 201 is linked twice'), findsOneWidget);
      await stop(tester);
    });
  });

  test('the links parse and serialize', () {
    final links = DeskPhoneLinks.fromJson({
      'links': [
        {'extension': '200', 'device': 'tab1'},
      ],
    });
    expect(links.links.single.extension, '200');
    expect(links.toJson(), {
      'links': [
        {'extension': '200', 'device': 'tab1'},
      ],
    });
    expect(DeskPhoneLinks.fromJson({}).links, isEmpty);
  });
}
