import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/camera.dart';
import 'package:pos_app/face_signin.dart';
import 'package:pos_app/screens/signin_screen.dart';
import 'package:pos_app/session.dart';
import 'package:pos_app/settings.dart';

import 'hub.dart';

/// A camera that always has a frame; its preview is up from the start, or comes up when told, as a phone's
/// does after the screen's first build.
class FrameCamera extends EventCamera {
  FrameCamera({this.live = true, this.watchable = true});
  int frames = 0;
  int snaps = 0;
  bool live;

  /// Whether it keeps frames coming and reports a change in its view (a phone), or not (the Mac).
  final bool watchable;
  int watching = 0;
  @override
  bool get ready => live;
  @override
  String? get error => null;
  @override
  Widget preview() => Text(live ? 'live preview' : 'camera starting');

  void up() {
    live = true;
    notifyListeners();
  }

  @override
  Future<bool> watch() async {
    watching += 1;
    return watchable;
  }

  @override
  void unwatch() => watching -= 1;

  /// Someone steps in front of the camera.
  void move() {
    motion += 1;
    notifyListeners();
  }

  @override
  Future<Uint8List?> snap() async {
    snaps += 1;
    return Uint8List.fromList([0xff, 0xd8, 0xff, 0xe0, 1]);
  }

  @override
  Future<Uint8List?> frame({int maxSide = 480}) async {
    frames += 1;
    return Uint8List.fromList([0xff, 0xd8, 0xff, 0xe0, 4, 8, 0]);
  }
}

const noFace = {'face': false, 'reason': 'no_face', 'candidate': null, 'score': null, 'signed_in': null};
const again = {'face': true, 'reason': 'again', 'candidate': 's1', 'score': 0.71, 'signed_in': null};
const unknown = {'face': true, 'reason': 'unknown', 'candidate': null, 'score': null, 'signed_in': null};
const same = {'face': true, 'reason': 'same', 'candidate': 's1', 'score': 0.8, 'present': true, 'signed_in': null};
const off = {'face': false, 'reason': 'off', 'candidate': null, 'score': null, 'signed_in': null};
const amy = {
  'face': true,
  'reason': null,
  'candidate': 's1',
  'score': 0.72,
  'signed_in': {
    'staff_id': 's1',
    'name': 'Amy',
    'role': 'server',
    'method': 'face',
    'preferences': {'text_scale': 1.15, 'high_contrast': false, 'locale': 'en'},
  },
};
const ben = {
  'face': true,
  'reason': null,
  'candidate': 's2',
  'score': 0.77,
  'present': false,
  'signed_in': {
    'staff_id': 's2',
    'name': 'Ben',
    'role': 'bartender',
    'method': 'face',
    'preferences': {'text_scale': 1.0, 'high_contrast': false, 'locale': 'en'},
  },
};
const benTag = {
  'staff_id': 's2',
  'name': 'Ben',
  'role': 'bartender',
  'preferences': {'text_scale': 1.0, 'high_contrast': false, 'locale': 'en'},
};

const active = {'enabled': true, 'ready': true, 'active': true, 'enrolled': 2, 'model': 'w600k_r50', 'error': null};

class Screen {
  Screen(this.hub, this.session, this.camera, this.faces, this.settings);
  final Hub hub;
  final Session session;
  final FrameCamera camera;
  final FaceSignIn faces;
  final Settings settings;

  /// The clock the loop reads: a test moves it, since flutter_test does not.
  DateTime now = DateTime(2026, 11, 6, 18);

  /// The loop runs for as long as the app does, so a test stops it itself when done.
  Future<void> done(WidgetTester tester) async {
    faces.stop();
    await tester.pumpWidget(const SizedBox());
  }
}

Future<Screen> pumpSignIn(
  WidgetTester tester, {
  bool withCamera = true,
  bool cameraUp = true,
  bool watchable = true,
  Map<String, dynamic>? status,
  List<Map<String, dynamic>> answers = const [],
  Map<String, dynamic>? handsFree,
}) async {
  final settings = Settings(device: 't1', endpoints: ['http://hub:8000']);
  final hub = Hub();
  if (status != null) hub.faceStatus = Map.of(status);
  hub.faceAnswers = answers;
  if (handsFree != null) hub.handsFree = handsFree;
  final api = PosApi(settings, client: MockClient(hub.handle));
  final session = Session(api);
  final camera = FrameCamera(live: cameraUp, watchable: watchable);
  late final Screen s;
  final faces = FaceSignIn(
    api,
    settings,
    camera,
    session,
    quick: const Duration(milliseconds: 100),
    slow: const Duration(milliseconds: 400),
    slowUnwatched: const Duration(milliseconds: 250),
    recheck: const Duration(seconds: 5),
    idleFrames: 3,
    clock: () => s.now,
  );
  s = Screen(hub, session, camera, faces, settings);
  tester.view
    ..physicalSize = const Size(1100, 800)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: SignInScreen(session: session, settings: settings, camera: withCamera ? camera : NoCamera(), faces: faces),
    ),
  );
  return s;
}

String hint(WidgetTester tester) => tester.widget<Text>(find.byKey(const ValueKey('sign-in-hint'))).data!;

Future<void> tapPin(WidgetTester tester, String pin) async {
  for (final digit in pin.split('')) {
    await tester.tap(find.widgetWithText(FilledButton, digit));
    await tester.pump();
  }
  await tester.pump();
}

void main() {
  testWidgets('with face sign-in off the hub, the screen is the PIN pad alone', (tester) async {
    final s = await pumpSignIn(tester);
    await tester.pump(); // the status
    await tester.pump(const Duration(seconds: 1));
    expect(hint(tester), 'Tap your 4-digit staff PIN to unlock');
    expect(s.camera.frames, 0, reason: 'no frame goes to a hub that is not looking');
    expect(s.faces.state, FaceState.off);
    await tapPin(tester, '1111');
    expect(s.session.staff?.name, 'Amy');
    expect(s.session.staff?.method, 'pin');
    await s.done(tester);
  });

  testWidgets('the preview appears as soon as the camera is up, with no tap on the pad', (tester) async {
    final s = await pumpSignIn(tester, cameraUp: false);
    await tester.pump();
    expect(find.text('camera starting'), findsOneWidget);
    s.camera.up();
    await tester.pump();
    expect(find.text('live preview'), findsOneWidget, reason: 'the screen follows the camera');
    await s.done(tester);
  });

  testWidgets('a status the app cannot read does not stop the loop: the hub is asked again', (tester) async {
    final s = await pumpSignIn(tester, status: {...active, 'enabled': 'yes'}, answers: [noFace]);
    await tester.pump(const Duration(milliseconds: 10));
    expect(hint(tester), 'Tap your 4-digit staff PIN to unlock');
    expect(s.faces.state, FaceState.off);
    expect(s.faces.lastError, contains('bool'), reason: 'the cast that failed is kept for the settings screen');
    s.hub.faceStatus = Map.of(active);
    await tester.pump(const Duration(seconds: 5)); // the recheck
    await tester.pump(const Duration(milliseconds: 10));
    expect(hint(tester), 'Look at the camera, or tap your PIN');
    expect(s.faces.state, FaceState.looking);
    expect(s.faces.lastError, isNull);
    await s.done(tester);
  });

  testWidgets('the screen looks for a face and signs in when two frames agree', (tester) async {
    final s = await pumpSignIn(tester, status: active, answers: [noFace, again, amy]);
    await tester.pump(const Duration(milliseconds: 10)); // the status comes back: looking; the first frame goes
    expect(hint(tester), 'Look at the camera, or tap your PIN');
    expect(find.byIcon(Icons.face_outlined), findsOneWidget);
    expect(s.hub.frames.length, 1, reason: 'the first frame: nobody there');
    expect(s.hub.frames.first['device'], 't1');
    expect(s.hub.frames.first.containsKey('current'), isFalse, reason: 'nobody signed in');
    expect(base64Decode(s.hub.frames.first['jpeg_b64'] as String).take(2), [0xff, 0xd8]);
    expect(s.camera.watching, 1, reason: 'the camera keeps its frames coming while the screen looks');
    expect(s.faces.watched, isTrue);
    expect(s.faces.switching, isTrue, reason: 'the hands-free setting came with the status');
    await tester.pump(const Duration(milliseconds: 100)); // the second: Amy, once; the third at once: agreed
    expect(s.hub.frames.length, greaterThanOrEqualTo(3), reason: 'the frame that confirms her goes at once');
    expect(s.hub.frames[2]['signed_in'], isNull);
    expect(s.hub.frames[2].containsKey('current'), isFalse, reason: 'the third frame went before the sign-in');
    expect(hint(tester), 'Hi Amy');
    expect(s.faces.state, FaceState.signedIn);
    expect(s.session.staff?.name, 'Amy');
    expect(s.session.staff?.method, 'face');
    expect(s.session.prefs.textScale, 1.15, reason: 'her display settings come along, as with a PIN');
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    expect(s.camera.watching, 1, reason: 'signed in: the camera keeps watching who is at the screen');
    s.hub.faceAnswers = [same];
    final sent = s.hub.frames.length;
    await tester.pump(const Duration(milliseconds: 100));
    expect(s.hub.frames.length, greaterThan(sent), reason: 'frames go on, saying who is signed in');
    expect(s.hub.frames.last['current'], 's1');
    expect(s.faces.state, FaceState.signedIn);
    await s.done(tester);
  });

  testWidgets('an unknown face says so after three frames, and the PIN still works', (tester) async {
    final s = await pumpSignIn(tester, status: active, answers: [unknown]);
    await tester.pump(const Duration(milliseconds: 10)); // three frames back-to-back: a face, unknown
    expect(s.hub.frames.length, 3);
    expect(hint(tester), 'Not recognised: tap your PIN');
    expect(s.faces.state, FaceState.unknown);
    await tester.pump(const Duration(milliseconds: 100)); // then one every 100 ms
    expect(s.hub.frames.length, 4);
    await tester.pump(const Duration(milliseconds: 50));
    expect(s.hub.frames.length, 4);
    await tapPin(tester, '1111');
    expect(s.session.staff?.name, 'Amy');
    expect(s.faces.state, FaceState.signedIn);
    await tester.pump(const Duration(milliseconds: 10));
    expect(s.hub.frames.last['current'], 's1', reason: 'the frames now say who is signed in');
    await s.done(tester);
  });

  testWidgets('frames slow down once nobody has been in front of the camera for a while', (tester) async {
    final s = await pumpSignIn(tester, status: active, answers: [noFace]);
    await tester.pump(const Duration(milliseconds: 10)); // frame 1 at once
    await tester.pump(const Duration(milliseconds: 100)); // frame 2
    await tester.pump(const Duration(milliseconds: 100)); // frame 3: three in a row with nobody
    expect(s.hub.frames.length, 3, reason: 'quick at first');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(s.hub.frames.length, 3, reason: 'then one every 400 ms');
    await tester.pump(const Duration(milliseconds: 200));
    expect(s.hub.frames.length, 4);
    s.hub.faceAnswers = [noFace, noFace, noFace, noFace, again, noFace];
    await tester.pump(const Duration(milliseconds: 400)); // frame 5: someone; frame 6 at once: gone again
    expect(s.hub.frames.length, 6);
    await tester.pump(const Duration(milliseconds: 100)); // quick again
    expect(s.hub.frames.length, 7);
    await s.done(tester);
  });

  testWidgets('a change in front of an idle camera brings a frame at once', (tester) async {
    final s = await pumpSignIn(tester, status: active, answers: [noFace]);
    await tester.pump(const Duration(milliseconds: 10));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100)); // three empty frames: idle, one every 400 ms
    expect(s.hub.frames.length, 3);
    await tester.pump(const Duration(milliseconds: 100));
    s.camera.move(); // someone steps up
    await tester.pump(const Duration(milliseconds: 10));
    expect(s.hub.frames.length, 4, reason: 'a frame goes at once, not at the idle pace');
    await tester.pump(const Duration(milliseconds: 100));
    expect(s.hub.frames.length, 4, reason: 'nobody in it: back to the idle pace');
    await tester.pump(const Duration(milliseconds: 300));
    expect(s.hub.frames.length, 5);
    await s.done(tester);
  });

  testWidgets('a camera that cannot report a change idles a little faster', (tester) async {
    final s = await pumpSignIn(tester, status: active, answers: [noFace], watchable: false);
    await tester.pump(const Duration(milliseconds: 10));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(s.hub.frames.length, 3);
    expect(s.faces.watched, isFalse);
    await tester.pump(const Duration(milliseconds: 250)); // one every 250 ms instead of 400
    expect(s.hub.frames.length, 4);
    await s.done(tester);
  });

  testWidgets('the hub saying off mid-way stops the looking and asks again later', (tester) async {
    final s = await pumpSignIn(tester, status: active, answers: [off]);
    await tester.pump(const Duration(milliseconds: 10));
    expect(s.faces.state, FaceState.off);
    expect(hint(tester), 'Tap your 4-digit staff PIN to unlock');
    expect(s.camera.watching, 0, reason: 'not looking: the camera is let go');
    s.hub.faceStatus = {...active, 'active': false};
    await tester.pump(const Duration(seconds: 6)); // the recheck
    expect(s.faces.state, FaceState.off);
    expect(s.hub.frames.length, 1, reason: 'no frame while the hub is not looking');
    await s.done(tester);
  });

  testWidgets('a screen without a camera never looks', (tester) async {
    final s = await pumpSignIn(tester, withCamera: false, status: active);
    await tester.pump(const Duration(seconds: 1));
    expect(s.faces.running, isFalse);
    expect(s.hub.frames, isEmpty);
    expect(hint(tester), 'Tap your 4-digit staff PIN to unlock');
    await s.done(tester);
  });

  // Hands-free switching: the loop goes on after a sign-in. ----------------------------------------------

  testWidgets('someone else stepping up takes the screen over at once', (tester) async {
    final s = await pumpSignIn(tester, status: active, answers: [amy, same, same, same, same, same, ben]);
    await tester.pump(const Duration(milliseconds: 10)); // a strong match: Amy on the first frame, then same
    expect(s.session.staff?.name, 'Amy');
    expect(s.hub.frames.length, greaterThanOrEqualTo(2));
    expect(s.hub.frames[1]['current'], 's1', reason: 'the frames after say she is signed in');
    expect(s.faces.state, FaceState.signedIn);
    for (var i = 0; i < 6 && s.hub.frames.length < 7; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(s.hub.frames.length, greaterThanOrEqualTo(7));
    expect(s.session.staff?.name, 'Ben', reason: 'the screen is his without anyone signing out');
    expect(s.session.staff?.method, 'face');
    expect(s.session.prefs.textScale, 1.0, reason: 'his own display settings');
    expect(hint(tester), 'Hi Ben');
    await tester.pump(const Duration(milliseconds: 100));
    expect(s.hub.frames.last['current'], 's2', reason: 'the frames say so from then on');
    await s.done(tester);
  });

  testWidgets('with the switch off, another face is noted but changes nothing', (tester) async {
    final s = await pumpSignIn(
      tester,
      status: active,
      answers: [amy, ben],
      handsFree: {'switch': false, 'away_seconds': 60},
    );
    await tester.pump(const Duration(milliseconds: 10));
    expect(s.session.staff?.name, 'Amy');
    expect(s.faces.switching, isFalse);
    await tester.pump(const Duration(milliseconds: 10));
    await tester.pump(const Duration(milliseconds: 100));
    expect(s.hub.frames.length, greaterThan(1), reason: 'frames still go, to sign her out when she leaves');
    expect(s.session.staff?.name, 'Amy', reason: 'Ben does not take over');
    await s.done(tester);
  });

  testWidgets('with the switch off and no sign-out to watch for, no frame goes while someone is signed in', (
    tester,
  ) async {
    final s = await pumpSignIn(
      tester,
      status: active,
      answers: [noFace],
      handsFree: {'switch': false, 'away_seconds': 0},
    );
    await tester.pump(const Duration(milliseconds: 10));
    expect(s.hub.frames.length, 1);
    await tapPin(tester, '1111'); // by PIN: nobody to watch for
    await tester.pump(const Duration(milliseconds: 10));
    final sent = s.hub.frames.length;
    await tester.pump(const Duration(seconds: 2));
    expect(s.hub.frames.length, sent, reason: 'signed in: no frames');
    expect(s.camera.watching, 0, reason: 'the camera is let go');
    s.session.signOut();
    await tester.pump(const Duration(milliseconds: 10));
    expect(s.hub.frames.length, sent + 1, reason: 'signed out: looking again at once');
    expect(hint(tester), 'Look at the camera, or tap your PIN');
    await s.done(tester);
  });

  testWidgets('a person the camera has not seen for a while is signed out', (tester) async {
    final s = await pumpSignIn(tester, status: active, answers: [amy, same, noFace]);
    await tester.pump(const Duration(milliseconds: 10));
    expect(s.session.staff?.name, 'Amy');
    await tester.pump(const Duration(milliseconds: 10)); // same: seen now
    s.now = s.now.add(const Duration(seconds: 30));
    await tester.pump(const Duration(milliseconds: 100)); // gone, for 30 s
    expect(s.session.staff?.name, 'Amy', reason: 'not yet');
    s.now = s.now.add(const Duration(seconds: 31));
    await tester.pump(const Duration(milliseconds: 100));
    expect(s.session.staff, isNull, reason: 'a minute without her: signed out');
    expect(s.faces.state, FaceState.looking);
    expect(hint(tester), 'Look at the camera, or tap your PIN');
    await s.done(tester);
  });

  testWidgets('someone who signed in by PIN stays until the camera has recognised them', (tester) async {
    final s = await pumpSignIn(tester, status: active, answers: [unknown]);
    await tester.pump(const Duration(milliseconds: 10));
    await tapPin(tester, '1111');
    s.now = s.now.add(const Duration(minutes: 5));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(s.session.staff?.name, 'Amy', reason: 'not enrolled, perhaps: the camera cannot tell she left');
    s.hub.faceAnswers = [same];
    await tester.pump(const Duration(milliseconds: 100)); // recognised at the screen
    s.hub.faceAnswers = [noFace];
    s.now = s.now.add(const Duration(seconds: 61));
    await tester.pump(const Duration(milliseconds: 100));
    expect(s.session.staff, isNull, reason: 'now her leaving signs her out');
    await s.done(tester);
  });

  testWidgets('a hold (an enrollment, a manager approving) stops the frames; a release sends one at once', (
    tester,
  ) async {
    final s = await pumpSignIn(tester, status: active, answers: [noFace]);
    await tester.pump(const Duration(milliseconds: 10));
    expect(s.hub.frames.length, 1);
    FaceSignIn.hold();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(s.hub.frames.length, 1, reason: 'held: nothing goes');
    FaceSignIn.release();
    await tester.pump(const Duration(milliseconds: 10));
    expect(s.hub.frames.length, 2, reason: 'released: a frame at once');
    expect(FaceSignIn.held, isFalse);
    await s.done(tester);
  });

  testWidgets('a tag signs in, switches, or says it is unknown', (tester) async {
    final s = await pumpSignIn(tester, status: active, answers: [noFace]);
    s.hub.tags = {'04A2B3C4': Map.of(benTag)};
    await tester.pump(const Duration(milliseconds: 10));
    await s.faces.tag('0000');
    await tester.pump();
    expect(hint(tester), 'Unknown tag');
    expect(s.session.staff, isNull);
    await tester.pump(const Duration(seconds: 4));
    expect(hint(tester), 'Look at the camera, or tap your PIN', reason: 'the word about the tag goes after a while');
    await s.faces.tag('04a2b3c4');
    await tester.pump();
    expect(s.session.staff?.name, 'Ben');
    expect(s.session.staff?.method, 'tag');
    expect(hint(tester), 'Hi Ben');
    // Amy's face at the screen takes over from Ben's tag sign-in; Ben's tag takes it back.
    s.hub.faceAnswers = [amy];
    await tester.pump(const Duration(milliseconds: 10));
    expect(s.session.staff?.name, 'Amy');
    await s.faces.tag('04A2B3C4');
    expect(s.session.staff?.name, 'Ben');
    await s.done(tester);
  });

  testWidgets('with the switch off, a tag while someone is signed in says so', (tester) async {
    final s = await pumpSignIn(tester, status: active, answers: [amy], handsFree: {'switch': false, 'away_seconds': 0});
    s.hub.tags = {'04A2B3C4': Map.of(benTag)};
    await tester.pump(const Duration(milliseconds: 10));
    expect(s.session.staff?.name, 'Amy');
    await s.faces.tag('04A2B3C4');
    await tester.pump();
    expect(s.session.staff?.name, 'Amy');
    expect(hint(tester), 'Switching is off here: sign out first');
    await s.done(tester);
  });
}
