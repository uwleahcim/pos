import 'dart:async';

import 'package:flutter/foundation.dart';

import 'api.dart';
import 'camera.dart';
import 'faces.dart';
import 'session.dart';
import 'settings.dart';

/// Where the face sign-in stands, for the sign-in screen.
enum FaceState {
  /// Not looking: the location has it off, the hub has no models, nobody is enrolled, or no camera here.
  off,

  /// Looking: no face in front of the camera yet.
  looking,

  /// A face, but not one the hub knows.
  unknown,

  /// A face the hub knows: one more frame must agree.
  holding,

  /// Signed in; the session has the person.
  signedIn,
}

/// Looks for an enrolled face while the sign-in screen is up: frames off the camera go to the hub, which
/// does the recognising, until it signs someone in or the screen goes. The PIN pad works meanwhile.
///
/// A frame goes every [quick] while someone is in front of the camera, every [slow] once nobody has been
/// for [idleFrames] frames in a row, so twenty idle terminals do not keep the hub busy. When the hub says it
/// is not looking (off, no models, nobody enrolled) it is asked again every [recheck].
class FaceSignIn extends ChangeNotifier {
  FaceSignIn(
    this.api,
    this.settings,
    this.camera,
    this.session, {
    this.quick = const Duration(milliseconds: 500),
    this.slow = const Duration(seconds: 2),
    this.recheck = const Duration(seconds: 15),
    this.idleFrames = 12,
  });

  final PosApi api;
  final Settings settings;
  final EventCamera camera;
  final Session session;
  final Duration quick;
  final Duration slow;
  final Duration recheck;

  /// After this many frames in a row with nobody in front of the camera, frames go at the slow pace.
  final int idleFrames;

  FaceState state = FaceState.off;
  FaceStatus? status;

  /// What the screen says under the preview, or null for nothing.
  String? message;
  int frames = 0;
  int unknownInARow = 0;
  int noFaceInARow = 0;

  Timer? _timer;
  bool _running = false;
  bool _busy = false;

  bool get running => _running;

  /// Starts looking, or asks the hub whether it should.
  void start() {
    if (_running) return;
    _running = true;
    _schedule(Duration.zero);
  }

  void stop() {
    _running = false;
    _timer?.cancel();
    _timer = null;
  }

  void _schedule(Duration after) {
    _timer?.cancel();
    if (!_running) return;
    _timer = Timer(after, () => unawaited(_step()));
  }

  /// One step: the status when not looking, else one frame to the hub.
  Future<void> _step() async {
    if (!_running || _busy) return;
    _busy = true;
    try {
      if (state == FaceState.off || status == null) {
        await _checkStatus();
      } else {
        await _sendFrame();
      }
    } finally {
      _busy = false;
    }
  }

  Future<void> _checkStatus() async {
    try {
      final found = await api.faceStatus();
      status = found;
      if (found.active) {
        _become(FaceState.looking, 'Look at the camera, or tap your PIN');
        noFaceInARow = 0;
        _schedule(Duration.zero);
      } else {
        _become(FaceState.off, null);
        _schedule(recheck);
      }
    } on ApiException {
      _become(FaceState.off, null);
      _schedule(recheck);
    }
  }

  Future<void> _sendFrame() async {
    final jpeg = await camera.frame();
    if (!_running) return;
    if (jpeg == null) {
      _schedule(const Duration(seconds: 1)); // the camera is not up yet, or the app is in the background
      return;
    }
    final FaceFrame answer;
    try {
      answer = await api.faceFrame(device: settings.device, jpeg: jpeg);
    } on ApiException {
      _schedule(const Duration(seconds: 3));
      return;
    }
    if (!_running) return;
    frames += 1;
    noFaceInARow = answer.face ? 0 : noFaceInARow + 1;
    final signed = answer.signedIn;
    if (signed != null) {
      _become(FaceState.signedIn, 'Hi ${signed['name'] ?? ''}');
      stop();
      session.applySignIn(signed);
      return;
    }
    switch (answer.reason) {
      case 'off' || 'not_ready':
        status = null;
        _become(FaceState.off, null);
        _schedule(recheck);
        return;
      case 'again':
        unknownInARow = 0;
        _become(FaceState.holding, 'Hold still…');
      case 'too_small':
        unknownInARow = 0;
        _become(FaceState.looking, 'Come closer');
      case 'unknown':
        unknownInARow += 1;
        _become(FaceState.unknown, unknownInARow >= 3 ? 'Not recognised: tap your PIN' : 'Looking…');
      default: // no_face
        unknownInARow = 0;
        _become(FaceState.looking, 'Look at the camera, or tap your PIN');
    }
    _schedule(noFaceInARow >= idleFrames ? slow : quick);
  }

  void _become(FaceState next, String? text) {
    if (state == next && message == text) return;
    state = next;
    message = text;
    notifyListeners();
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}
