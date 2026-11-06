import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/camera.dart';
import 'package:pos_app/faces.dart';
import 'package:pos_app/screens/settings_screen.dart';
import 'package:pos_app/settings.dart';

import 'hub.dart';

/// A camera that comes up when told, as a phone's does after the screen's first build.
class LateCamera extends EventCamera {
  bool live = false;
  @override
  bool get ready => live;
  @override
  String? get error => null;
  @override
  Widget preview() => const SizedBox();
  @override
  Future<Uint8List?> snap() async => null;

  void up() {
    live = true;
    notifyListeners();
  }
}

const twoEnrolledOff = {
  'enabled': false,
  'ready': true,
  'active': false,
  'enrolled': 2,
  'model': 'w600k_r50',
  'error': null,
};

Future<Hub> pumpSettings(
  WidgetTester tester, {
  EventCamera? camera,
  bool olderHub = false,
  Map<String, dynamic>? status,
}) async {
  final settings = Settings(device: 't1', endpoints: ['http://hub:8000']);
  final hub = Hub()..faces = !olderHub;
  if (status != null) hub.faceStatus = Map.of(status);
  final api = PosApi(settings, client: MockClient(hub.handle));
  tester.view
    ..physicalSize = const Size(900, 1800)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: SettingsScreen(settings: settings, api: api, camera: camera),
    ),
  );
  await tester.pump(); // the hub's answer
  return hub;
}

String faceLine(WidgetTester tester) => tester.widget<Text>(find.byKey(const ValueKey('face-line'))).data!;

void main() {
  test('the status line says what keeps the sign-in screens from looking', () {
    expect(
      FaceStatus.fromJson(twoEnrolledOff).line,
      'Hub ready · 2 enrolled · switched off: no screen looks until the switch is on',
    );
    expect(
      FaceStatus.fromJson({...twoEnrolledOff, 'enabled': true, 'active': true}).line,
      'Hub ready · 2 enrolled · the sign-in screens are looking',
    );
    expect(FaceStatus.fromJson({...twoEnrolledOff, 'enrolled': 0}).line, 'Hub ready, nobody enrolled yet');
    expect(
      FaceStatus.fromJson({...twoEnrolledOff, 'ready': false, 'model': null}).line,
      'The hub has no face models yet (update the hub, or wait while they load)',
    );
    expect(
      FaceStatus.fromJson({...twoEnrolledOff, 'ready': false, 'error': 'no such file'}).line,
      'The hub could not load its face models: no such file',
    );
  });

  testWidgets('the settings screen says how face sign-in stands, and follows the camera', (tester) async {
    final camera = LateCamera();
    await pumpSettings(tester, camera: camera, status: twoEnrolledOff);
    expect(
      faceLine(tester),
      "Hub ready · 2 enrolled · switched off: no screen looks until the switch is on. This terminal's camera: starting.",
    );
    camera.up();
    await tester.pump();
    expect(faceLine(tester), endsWith("This terminal's camera is up."));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('an older hub, and a terminal without a camera', (tester) async {
    await pumpSettings(tester, camera: NoCamera(), olderHub: true);
    expect(faceLine(tester), startsWith('The hub has not answered about face sign-in: '));
    expect(faceLine(tester), endsWith('This terminal has no camera: PIN only.'));
    await tester.pumpWidget(const SizedBox());
  });
}
