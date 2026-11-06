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

/// A camera that always has a frame.
class FrameCamera extends EventCamera {
  int frames = 0;
  int snaps = 0;
  @override
  bool get ready => true;
  @override
  String? get error => null;
  @override
  Widget preview() => const SizedBox();
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

const active = {'enabled': true, 'ready': true, 'active': true, 'enrolled': 2, 'model': 'w600k_r50', 'error': null};

class Screen {
  Screen(this.hub, this.session, this.camera, this.faces);
  final Hub hub;
  final Session session;
  final FrameCamera camera;
  final FaceSignIn faces;
}

Future<Screen> pumpSignIn(
  WidgetTester tester, {
  bool withCamera = true,
  Map<String, dynamic>? status,
  List<Map<String, dynamic>> answers = const [],
}) async {
  final settings = Settings(device: 't1', endpoints: ['http://hub:8000']);
  final hub = Hub();
  if (status != null) hub.faceStatus = Map.of(status);
  hub.faceAnswers = answers;
  final api = PosApi(settings, client: MockClient(hub.handle));
  final session = Session(api);
  final camera = FrameCamera();
  final faces = FaceSignIn(
    api,
    settings,
    camera,
    session,
    quick: const Duration(milliseconds: 100),
    slow: const Duration(milliseconds: 400),
    recheck: const Duration(seconds: 5),
    idleFrames: 3,
  );
  tester.view
    ..physicalSize = const Size(1100, 800)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: SignInScreen(session: session, settings: settings, camera: withCamera ? camera : NoCamera(), faces: faces),
    ),
  );
  return Screen(hub, session, camera, faces);
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
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the screen looks for a face and signs in when two frames agree', (tester) async {
    final s = await pumpSignIn(tester, status: active, answers: [noFace, again, amy]);
    await tester.pump(const Duration(milliseconds: 10)); // the status comes back: looking; the first frame goes
    expect(hint(tester), 'Look at the camera, or tap your PIN');
    expect(find.byIcon(Icons.face_outlined), findsOneWidget);
    expect(s.hub.frames.length, 1, reason: 'the first frame: nobody there');
    expect(s.hub.frames.first['device'], 't1');
    expect(base64Decode(s.hub.frames.first['jpeg_b64'] as String).take(2), [0xff, 0xd8]);
    await tester.pump(const Duration(milliseconds: 100)); // the second: Amy, once
    expect(hint(tester), 'Hold still…');
    expect(s.faces.state, FaceState.holding);
    await tester.pump(const Duration(milliseconds: 100)); // the third: Amy, agreed
    expect(hint(tester), 'Hi Amy');
    expect(s.faces.state, FaceState.signedIn);
    expect(s.session.staff?.name, 'Amy');
    expect(s.session.staff?.method, 'face');
    expect(s.session.prefs.textScale, 1.15, reason: 'her display settings come along, as with a PIN');
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    final sent = s.hub.frames.length;
    await tester.pump(const Duration(seconds: 2));
    expect(s.hub.frames.length, sent, reason: 'signed in: no more frames');
    expect(s.faces.running, isFalse);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('an unknown face says so after three frames, and the PIN still works', (tester) async {
    final s = await pumpSignIn(tester, status: active, answers: [unknown]);
    await tester.pump(const Duration(milliseconds: 10));
    expect(hint(tester), 'Looking…');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(hint(tester), 'Not recognised: tap your PIN');
    expect(s.faces.state, FaceState.unknown);
    await tapPin(tester, '1111');
    expect(s.session.staff?.name, 'Amy');
    // The screen goes with the sign-in; the frames stop with it.
    await tester.pumpWidget(const SizedBox());
    final sent = s.hub.frames.length;
    await tester.pump(const Duration(seconds: 2));
    expect(s.hub.frames.length, sent);
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
    s.hub.faceAnswers = [noFace, noFace, noFace, noFace, again];
    await tester.pump(const Duration(milliseconds: 400)); // frame 5: someone
    expect(s.hub.frames.length, 5);
    await tester.pump(const Duration(milliseconds: 100)); // quick again
    expect(s.hub.frames.length, 6);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the hub saying off mid-way stops the looking and asks again later', (tester) async {
    final s = await pumpSignIn(
      tester,
      status: active,
      answers: [
        {'face': false, 'reason': 'off', 'candidate': null, 'score': null, 'signed_in': null},
      ],
    );
    await tester.pump(const Duration(milliseconds: 10));
    expect(s.faces.state, FaceState.off);
    expect(hint(tester), 'Tap your 4-digit staff PIN to unlock');
    s.hub.faceStatus = {...active, 'active': false};
    await tester.pump(const Duration(seconds: 6)); // the recheck
    expect(s.faces.state, FaceState.off);
    expect(s.hub.frames.length, 1, reason: 'no frame while the hub is not looking');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a screen without a camera never looks', (tester) async {
    final s = await pumpSignIn(tester, withCamera: false, status: active);
    await tester.pump(const Duration(seconds: 1));
    expect(s.faces.running, isFalse);
    expect(s.hub.frames, isEmpty);
    expect(hint(tester), 'Tap your 4-digit staff PIN to unlock');
    await tester.pumpWidget(const SizedBox());
  });
}
