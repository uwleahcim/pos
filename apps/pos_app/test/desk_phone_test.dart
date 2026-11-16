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

  Map<String, dynamic> call({
    String id = '1730000000.123:200',
    String extension = '200',
    int ageMs = 800,
    int seq = 1,
  }) => {
    'id': id,
    'extension': extension,
    'number': '+16175551234',
    'name': 'LINDA CHEN',
    'dialed': '+17817296899',
    'at': 1730000000000,
    'age_ms': ageMs,
    'seq': seq,
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

    test('keeps one request waiting at the hub and asks again the moment it is answered', () async {
      late FakeAsync fake;
      final (hub, w) = await watcher(clock: () => now.add(fake.elapsed));
      fakeAsync((async) {
        fake = async;
        w.start();
        async.flushMicrotasks();
        expect(hub.answeredAsked, ['tab1']);
        expect(hub.answeredWait, [15]); // the hub may hold it for 15 seconds
        expect(hub.answeredAfter, [0]);
        async.elapse(const Duration(seconds: 40));
        expect(hub.answeredAsked.length, 3); // held 15 s each, asked again at once: at 0, 15 and 30 s
        hub.pickUp(call(seq: 1)); // at 40 s, while the third request waits
        async.flushMicrotasks();
        expect(w.calls, 1); // the waiting request came back with it right away
        expect(w.take()?.extension, '200');
        expect((hub.answeredAsked.length, hub.answeredAfter.last), (4, 1)); // asked again at once, from the cursor
        w.stop();
      });
    });

    test('woken up, it asks the hub at once beside the request the hub may still hold', () async {
      late FakeAsync fake;
      final (hub, w) = await watcher(clock: () => now.add(fake.elapsed));
      fakeAsync((async) {
        fake = async;
        w.wakeUp(); // not running yet: nothing to ask
        expect(hub.answeredAsked, isEmpty);
        w.start();
        async.flushMicrotasks();
        expect(hub.answeredAsked, ['tab1']); // held at the hub
        async.elapse(const Duration(seconds: 5));
        w.wakeUp(); // the app is back in front: the held request may be dead, so a second one goes out
        async.flushMicrotasks();
        expect(hub.answeredAsked, ['tab1', 'tab1']);
        hub.pickUp(call(seq: 1));
        async.flushMicrotasks();
        expect(w.calls, 1); // both came back with it; the call is reported once
        async.elapse(const Duration(seconds: 1));
        expect(w.calls, 1);
        w.stop();
      });
    });

    test('says when the links change, so the screen can keep itself awake for its phones', () async {
      final (hub, w) = await watcher();
      var told = 0;
      w.addListener(() => told++);
      await w.poll();
      expect((w.linked, told), (false, 0));
      hub.linked = true;
      await w.poll();
      expect((w.linked, told), (true, 1));
      await w.poll();
      expect(told, 1);
    });

    test('a hub from before held requests answers at once and is asked once a second, not in a loop', () async {
      late FakeAsync fake;
      final (hub, w) = await watcher(clock: () => now.add(fake.elapsed));
      hub.holds = false;
      fakeAsync((async) {
        fake = async;
        w.start();
        async.elapse(const Duration(seconds: 10));
        expect(hub.answeredAsked.length, inInclusiveRange(10, 11));
        w.stop();
      });
    });

    test('a hub that is down is asked again a second later', () async {
      late FakeAsync fake;
      final (hub, w) = await watcher(clock: () => now.add(fake.elapsed));
      hub.answeredDown = true;
      fakeAsync((async) {
        fake = async;
        w.start();
        async.elapse(const Duration(seconds: 5));
        expect(hub.answeredAsked.length, inInclusiveRange(5, 6));
        hub.answeredDown = false;
        hub.pickUp(call(seq: 1));
        async.elapse(const Duration(seconds: 1));
        expect(w.calls, 1);
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
      tester.view.physicalSize = const Size(1100, 2000);
      await tester.pumpAndSettle();
    }

    /// Opens the pull-down under [key] and picks the item reading [label].
    Future<void> pick(WidgetTester tester, String key, String label) async {
      await tester.tap(find.byKey(ValueKey(key)));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();
    }

    DropdownButton<String> pullDown(WidgetTester tester, String key) =>
        tester.widget<DropdownButton<String>>(find.byKey(ValueKey(key)));

    List<String> labels(DropdownButton<String> pullDown) => [
      for (final item in pullDown.items!) (item.child as Text).data!,
    ];

    /// Whether the text field under [key] has the focus (and so, on a touch screen, the keyboard).
    bool focused(WidgetTester tester, String key) => tester
        .widget<EditableText>(find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(EditableText)))
        .focusNode
        .hasFocus;

    testWidgets('a manager picks each phone from the PBX\'s extensions and its screen from the hub\'s devices', (
      tester,
    ) async {
      final t = await pumpLocation(
        tester,
        setUp: (hub) {
          hub.extensions = [
            {'extension': '200', 'online': true},
            {'extension': '201', 'online': false},
          ];
          hub.extensionsConnected = true;
          hub.devices = ['mac1', 'ipad1', 't1'];
        },
      );
      await tall(tester);
      expect(find.text('No desk phone is linked yet.'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('desk-add')));
      await tester.pumpAndSettle();
      expect(labels(pullDown(tester, 'desk-ext-pick:0')), ['200', '201 (offline)', 'Other…']);
      // this screen first and marked, the others by name, and Other to type a name
      expect(labels(pullDown(tester, 'desk-dev-pick:0')), ['t1 (this device)', 'ipad1', 'mac1', 'Other…']);
      await pick(tester, 'desk-ext-pick:0', '200');
      await pick(tester, 'desk-dev-pick:0', 't1 (this device)');
      expect((pullDown(tester, 'desk-ext-pick:0').value, pullDown(tester, 'desk-dev-pick:0').value), ('200', 't1'));
      await tester.tap(find.byKey(const ValueKey('desk-add')));
      await tester.pumpAndSettle();
      await pick(tester, 'desk-ext-pick:1', '201 (offline)');
      await pick(tester, 'desk-dev-pick:1', 'ipad1');
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

    testWidgets('Other lets a manager type what the lists do not have', (tester) async {
      final t = await pumpLocation(
        tester,
        setUp: (hub) {
          hub.extensions = [
            {'extension': '200', 'online': true},
          ];
          hub.extensionsConnected = true;
        },
      );
      await tall(tester);
      await tester.tap(find.byKey(const ValueKey('desk-add')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('desk-ext:0')), findsNothing); // a pull-down until Other is picked
      await pick(tester, 'desk-ext-pick:0', 'Other…');
      // the field that appears has the focus, so one just types; a touch screen brings up its keyboard
      expect(focused(tester, 'desk-ext:0'), isTrue);
      expect(tester.testTextInput.isVisible, isTrue);
      await tester.enterText(find.byKey(const ValueKey('desk-ext:0')), '210');
      await pick(tester, 'desk-dev-pick:0', 'Other…');
      expect(focused(tester, 'desk-dev:0'), isTrue);
      expect(focused(tester, 'desk-ext:0'), isFalse);
      await tester.enterText(find.byKey(const ValueKey('desk-dev:0')), 'kiosk');
      await tester.tap(find.byKey(const ValueKey('desk-phones-save')));
      await tester.pumpAndSettle();
      expect(t.hub.deskPhones, {
        'links': [
          {'extension': '210', 'device': 'kiosk'},
        ],
      });
      await stop(tester);
    });

    testWidgets('without a PBX the extension is typed; the screen is still picked', (tester) async {
      await pumpLocation(tester);
      await tall(tester);
      expect(find.textContaining('not linked to the PBX'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('desk-add')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('desk-ext-pick:0')), findsNothing);
      expect(find.byKey(const ValueKey('desk-ext:0')), findsOneWidget);
      expect(labels(pullDown(tester, 'desk-dev-pick:0')), ['t1 (this device)', 'Other…']);
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
          hub.extensions = [
            {'extension': '200', 'online': true},
            {'extension': '201', 'online': true},
          ];
          hub.extensionsConnected = true;
          hub.devices = ['mac1']; // tab1 has not been heard from, yet its link still shows as it is
          hub.pbxStatus = {'configured': true, 'connected': true, 'host': 'pbx', 'answers': 3, 'pops': 2, 'links': 2};
        },
      );
      await tall(tester);
      expect(find.textContaining('watching pbx'), findsOneWidget);
      expect(pullDown(tester, 'desk-dev-pick:0').value, 'tab1');
      expect(labels(pullDown(tester, 'desk-dev-pick:0')), ['t1 (this device)', 'mac1', 'tab1', 'Other…']);
      expect(pullDown(tester, 'desk-dev-pick:1').value, 'mac1');
      await tester.tap(find.byKey(const ValueKey('desk-delete:0')));
      await tester.pumpAndSettle();
      expect(pullDown(tester, 'desk-ext-pick:0').value, '201');
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
