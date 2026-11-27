import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/camera.dart';
import 'package:pos_app/desk_phone_watcher.dart';
import 'package:pos_app/face_signin.dart';
import 'package:pos_app/idle_lock.dart';
import 'package:pos_app/main.dart';
import 'package:pos_app/outbox.dart';
import 'package:pos_app/phone.dart';
import 'package:pos_app/photos.dart';
import 'package:pos_app/print_relay.dart';
import 'package:pos_app/queue_store.dart';
import 'package:pos_app/screens/kitchen_screen.dart';
import 'package:pos_app/screens/orders_screen.dart';
import 'package:pos_app/screens/pickup_board_screen.dart';
import 'package:pos_app/screens/signin_screen.dart';
import 'package:pos_app/session.dart';
import 'package:pos_app/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'face_signin_test.dart' show FrameCamera, active, amy, noFace;
import 'hub.dart';
import 'kitchen_screen_test.dart' as kitchen;
import 'phone_test.dart' show FakeStack;
import 'pickup_board_test.dart' as board;

/// A device that stands as something while nobody is signed in (a station's kitchen screen, the pickup
/// board) with face sign-in on at the location: the camera signs nobody in while the tickets or the board
/// show, whoever stands in front of it, so the screen stays what it was set to be. Staff brings the pad, and
/// there a face signs in as on any screen (docs/kitchen-screens.md, docs/pickup-board.md, docs/face-signin.md).

/// The hub's answer while the person signed in is the one at the screen.
const stillThere = {
  'face': true,
  'reason': 'same',
  'candidate': 's1',
  'score': 0.8,
  'present': true,
  'signed_in': null,
};

class Device {
  Device(this.hub, this.session, this.settings, this.camera);
  final Hub hub;
  final Session session;
  final Settings settings;
  final FrameCamera camera;
  late final FaceSignIn faces;

  /// The clock the face loop reads.
  DateTime now = DateTime(2026, 11, 27, 18);

  /// While set, a frame sent to the hub waits there until the test lets it answer.
  Completer<void>? atHub;

  /// The face loop and the screens' timers run for as long as the app does: a test takes them down itself.
  Future<void> done(WidgetTester tester) async {
    faces.stop();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 4));
  }
}

/// The whole app on a device set to be the kitchen screen of [stations] (or, with [pickup], the pickup
/// board), its camera on, the location signing in by face, and the hub answering every frame with [answers]
/// (the last one repeating): Amy, standing in front of the screen, when none are given.
Future<Device> pumpDevice(
  WidgetTester tester, {
  List<String> stations = const ['wok'],
  bool pickup = false,
  int lockMinutes = 0,
  List<Map<String, dynamic>> answers = const [amy],
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final settings = Settings(device: 't1', endpoints: ['http://hub:8000'], prefs: prefs);
  if (pickup) {
    await settings.savePickupBoard(true);
  } else {
    await settings.saveKitchenStations(stations);
  }
  await settings.saveLockMinutes(lockMinutes);
  final hub = Hub()
    ..faceStatus = Map.of(active)
    ..faceAnswers = answers
    ..stations = {...kitchen.names}
    ..kitchen = kitchen.evening();
  hub.orders.addAll(board.evening());
  late final Device d;
  final api = PosApi(
    settings,
    client: MockClient((request) async {
      final held = d.atHub;
      if (held != null && request.url.path == '/signin/face') await held.future;
      return hub.handle(request);
    }),
  );
  final session = Session(api);
  final camera = FrameCamera();
  d = Device(hub, session, settings, camera);
  // as main() does: one loop for as long as the app runs
  d.faces = FaceSignIn(
    api,
    settings,
    camera,
    session,
    quick: const Duration(milliseconds: 100),
    slow: const Duration(milliseconds: 400),
    recheck: const Duration(seconds: 5),
    idleFrames: 3,
    clock: () => d.now,
  )..start();
  final lock = IdleLock(settings, session)..start();
  addTearDown(lock.dispose);
  tester.view
    ..physicalSize = const Size(1100, 800)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    PosApp(
      settings: settings,
      api: api,
      outbox: Outbox(api, settings, store: MemoryStore()),
      session: session,
      camera: camera,
      photos: PhotoQueue(api, settings, NoCamera(), session, store: MemoryStore()),
      relay: PrintRelay(api, settings),
      phone: PhoneClient(FakeStack()),
      deskPhones: DeskPhoneWatcher(api, settings),
      faces: d.faces,
      idleLock: lock,
    ),
  );
  await tester.pumpAndSettle();
  return d;
}

/// Somebody stands in front of the screen for a while: the loop has every chance to look.
Future<void> stand(WidgetTester tester, [Duration time = const Duration(seconds: 12)]) async {
  await tester.pump(time);
  await tester.pumpAndSettle();
}

Future<void> pin(WidgetTester tester, String digits) async {
  for (final digit in digits.split('')) {
    await tester.tap(find.widgetWithText(FilledButton, digit));
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a device that stands as nothing signs in whoever steps up, as before', (tester) async {
    final d = await pumpDevice(tester, stations: const []);
    expect(d.session.staff?.name, 'Amy');
    expect(d.session.staff?.method, 'face');
    expect(find.byType(OrdersScreen), findsOneWidget);
    await d.done(tester);
  });

  testWidgets('a kitchen screen stays the kitchen screen with an enrolled face in front of it', (tester) async {
    final d = await pumpDevice(tester);
    await stand(tester);
    expect(find.byType(KitchenScreen), findsOneWidget, reason: 'the tickets are what this screen is for');
    expect(find.byType(OrdersScreen), findsNothing);
    expect(d.session.staff, isNull, reason: 'the cook reading the tickets is not signing in');
    expect(d.hub.frames, isEmpty, reason: 'no frame leaves the device while the tickets show');
    expect(d.camera.frames, 0);
    expect(d.camera.watching, 0, reason: 'the camera is not kept running for it');
    await d.done(tester);
  });

  testWidgets('Staff brings the pad, and there the face signs in at once', (tester) async {
    final d = await pumpDevice(tester);
    await stand(tester);
    await tester.tap(find.byKey(const ValueKey('kitchen-staff')));
    await tester.pump();
    expect(find.byType(SignInScreen), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 10));
    expect(d.session.staff?.name, 'Amy', reason: 'asking for the pad is asking to sign in');
    expect(d.session.staff?.method, 'face');
    await tester.pumpAndSettle();
    expect(find.byType(OrdersScreen), findsOneWidget);
    await d.done(tester);
  });

  testWidgets('signing out puts the tickets back, and they stay with the person still in front', (tester) async {
    final d = await pumpDevice(tester);
    await tester.tap(find.byKey(const ValueKey('kitchen-staff')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
    await tester.pumpAndSettle();
    expect(d.session.staff?.name, 'Amy');
    d.session.signOut();
    await tester.pumpAndSettle();
    final sent = d.hub.frames.length;
    await stand(tester);
    expect(find.byType(KitchenScreen), findsOneWidget);
    expect(d.session.staff, isNull, reason: 'a sign-out is not undone by the camera');
    expect(d.hub.frames.length, sent);
    expect(d.camera.watching, 0);
    await d.done(tester);
  });

  testWidgets('a person the camera stops seeing is signed out, and the tickets come back for good', (tester) async {
    final d = await pumpDevice(tester, answers: const [amy, stillThere, noFace]);
    await tester.tap(find.byKey(const ValueKey('kitchen-staff')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
    await tester.pumpAndSettle();
    expect(d.session.staff?.name, 'Amy');
    d.now = d.now.add(const Duration(seconds: 61)); // she walked off a minute ago
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(d.session.staff, isNull);
    expect(find.byType(KitchenScreen), findsOneWidget);
    d.hub.faceAnswers = const [amy]; // and walks past again
    final sent = d.hub.frames.length;
    await stand(tester);
    expect(d.session.staff, isNull);
    expect(d.hub.frames.length, sent);
    await d.done(tester);
  });

  testWidgets('a pad left alone goes back to the tickets, and the looking stops with it', (tester) async {
    final d = await pumpDevice(tester, answers: const [noFace]);
    await tester.tap(find.byKey(const ValueKey('kitchen-staff')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
    expect(d.hub.frames, isNotEmpty, reason: 'the pad looks for a face, as on any screen');
    expect(d.camera.watching, 1);
    await tester.pump(const Duration(seconds: 61)); // nobody touched the pad for a minute
    await tester.pumpAndSettle();
    expect(find.byType(KitchenScreen), findsOneWidget);
    expect(d.camera.watching, 0);
    d.hub.faceAnswers = const [amy]; // the cook is back at the tickets
    final sent = d.hub.frames.length;
    await stand(tester);
    expect(d.hub.frames.length, sent);
    expect(d.session.staff, isNull);
    expect(find.byType(KitchenScreen), findsOneWidget);
    await d.done(tester);
  });

  testWidgets('a frame still at the hub when the pad goes back signs nobody in', (tester) async {
    final d = await pumpDevice(tester);
    d.atHub = Completer<void>();
    await tester.tap(find.byKey(const ValueKey('kitchen-staff')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10)); // a frame is on its way
    expect(d.camera.frames, 1);
    await tester.tap(find.byKey(const ValueKey('board-back'))); // back to the tickets, from the pad's bar
    await tester.pumpAndSettle();
    expect(find.byType(KitchenScreen), findsOneWidget);
    d.atHub!.complete(); // the hub answers now: it was Amy
    d.atHub = null;
    await stand(tester);
    expect(d.hub.frames.length, 1);
    expect(d.session.staff, isNull, reason: 'what the camera saw before the tickets came back counts for nothing');
    expect(find.byType(KitchenScreen), findsOneWidget);
    expect(d.camera.watching, 0);
    await d.done(tester);
  });

  testWidgets('the pickup board stays the board; its Staff brings the pad and the face signs in', (tester) async {
    final d = await pumpDevice(tester, pickup: true);
    await stand(tester);
    expect(find.byType(PickupBoardScreen), findsOneWidget, reason: 'a customer or a server walking by changes nothing');
    expect(d.session.staff, isNull);
    expect(d.hub.frames, isEmpty);
    await tester.tap(find.byKey(const ValueKey('board-staff')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
    expect(d.session.staff?.name, 'Amy');
    await tester.pumpAndSettle();
    expect(find.byType(OrdersScreen), findsOneWidget);
    d.session.signOut();
    await tester.pumpAndSettle();
    await stand(tester);
    expect(find.byType(PickupBoardScreen), findsOneWidget);
    expect(d.session.staff, isNull);
    await d.done(tester);
  });

  testWidgets('a kitchen screen that locked itself is not unlocked by a face walking by', (tester) async {
    final d = await pumpDevice(tester, lockMinutes: 5, answers: const [noFace]);
    await tester.tap(find.byKey(const ValueKey('kitchen-staff')));
    await tester.pumpAndSettle();
    await pin(tester, '1111'); // by PIN: nobody the camera would sign out
    expect(find.byType(OrdersScreen), findsOneWidget);
    d.session.lock(); // nobody touched it for five minutes
    await tester.pumpAndSettle();
    expect(find.byType(KitchenScreen), findsOneWidget, reason: 'the tickets stand over the lock');
    d.hub.faceAnswers = const [amy];
    final sent = d.hub.frames.length;
    await stand(tester);
    expect((d.session.signedIn, d.session.locked), (false, true), reason: 'still locked, the tickets still up');
    expect(d.hub.frames.length, sent);
    expect(find.byType(KitchenScreen), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('kitchen-staff')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
    await tester.pumpAndSettle();
    expect((d.session.staff?.name, d.session.locked), ('Amy', false), reason: 'at the pad her face unlocks it');
    expect(find.byType(KitchenScreen), findsNothing);
    d.session.signOut();
    await tester.pumpAndSettle();
    await d.done(tester);
  });

  testWidgets('a tag held to the reader still signs in from the tickets: that is somebody asking', (tester) async {
    final d = await pumpDevice(tester, answers: const [noFace]);
    d.hub.tags['04AABB'] = {'staff_id': 's2', 'name': 'Ben', 'role': 'bartender'};
    await tester.runAsync(() => d.faces.tag('04AABB'));
    await tester.pumpAndSettle();
    expect(d.session.staff?.name, 'Ben');
    expect(d.session.staff?.method, 'tag');
    expect(find.byType(OrdersScreen), findsOneWidget);
    await d.done(tester);
  });
}
