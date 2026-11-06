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
/// The pace. While a face is in view the next frame leaves as soon as the hub answers the last one: a
/// strong match signs in on one frame, a weaker one on the next frame that agrees. After a few frames with
/// a face but no sign-in the pace drops to one every [quick], after many to one every [slow] (a bystander
/// facing the camera). With nobody in view a frame goes every [quick], then every [slow] once [idleFrames]
/// in a row were empty, so twenty idle terminals do not keep the hub busy; a camera that can
/// [EventCamera.watch] reports a change in its view (someone stepping up to the screen) and the next frame
/// goes at once, one that cannot (the Mac) idles at [slowUnwatched] instead. When the hub says it is not
/// looking (off, no models, nobody enrolled) it is asked again every [recheck].
class FaceSignIn extends ChangeNotifier {
  FaceSignIn(
    this.api,
    this.settings,
    this.camera,
    this.session, {
    this.quick = const Duration(milliseconds: 500),
    this.slow = const Duration(seconds: 2),
    this.slowUnwatched = const Duration(seconds: 1),
    this.recheck = const Duration(seconds: 15),
    this.idleFrames = 12,
  });

  final PosApi api;
  final Settings settings;
  final EventCamera camera;
  final Session session;
  final Duration quick;
  final Duration slow;

  /// The idle pace for a camera that cannot report a change in its view.
  final Duration slowUnwatched;
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

  /// Frames in a row with a face in them and no sign-in: the pace drops as this grows.
  int faceInARow = 0;

  /// What went wrong last (no hub answers, an answer this app could not read), for the settings screen;
  /// null once a call goes through again.
  String? lastError;

  Timer? _timer;
  bool _running = false;
  bool _busy = false;
  bool _watching = false; // the camera was asked to keep its frames coming; unwatch is owed
  bool _watched = false; // and it does, reporting a change in its view
  int _seenMotion = 0;

  bool get running => _running;

  /// Whether the camera keeps its frames coming and reports a change in its view.
  bool get watched => _watched;

  /// Starts looking, or asks the hub whether it should.
  void start() {
    if (_running) return;
    _running = true;
    camera.addListener(_cameraChanged);
    _schedule(Duration.zero);
  }

  void stop() {
    _running = false;
    _timer?.cancel();
    _timer = null;
    camera.removeListener(_cameraChanged);
    _unwatch();
  }

  Future<void> _watch() async {
    if (_watching) return;
    _watching = true;
    _seenMotion = camera.motion;
    _watched = await camera.watch();
  }

  void _unwatch() {
    if (!_watching) return;
    _watching = false;
    _watched = false;
    camera.unwatch();
  }

  /// The camera saw its view change: a frame now, unless one is on its way or the hub is not looking.
  void _cameraChanged() {
    if (camera.motion == _seenMotion) return;
    _seenMotion = camera.motion;
    if (!_running || state == FaceState.off || _busy) return;
    _schedule(Duration.zero);
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
    } catch (err) {
      // An answer in a shape this app does not know, or a fault in the camera code: not looking for now, and
      // the hub is asked again later. The loop must never just stop, since nothing would start it again.
      lastError = '$err';
      status = null;
      _unwatch();
      _become(FaceState.off, null);
      _schedule(recheck);
    } finally {
      _busy = false;
    }
  }

  Future<void> _checkStatus() async {
    try {
      final found = await api.faceStatus();
      status = found;
      lastError = null;
      if (found.active) {
        _become(FaceState.looking, 'Look at the camera, or tap your PIN');
        noFaceInARow = 0;
        faceInARow = 0;
        await _watch();
        _schedule(Duration.zero);
      } else {
        _unwatch();
        _become(FaceState.off, null);
        _schedule(recheck);
      }
    } on ApiException catch (err) {
      lastError = '$err';
      _unwatch();
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
    } on ApiException catch (err) {
      lastError = '$err';
      _schedule(const Duration(seconds: 3));
      return;
    }
    if (!_running) return;
    lastError = null;
    frames += 1;
    noFaceInARow = answer.face ? 0 : noFaceInARow + 1;
    faceInARow = answer.face ? faceInARow + 1 : 0;
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
        _unwatch();
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
    _schedule(_pace(answer));
  }

  /// How long until the next frame, by what the hub just said (the pace in the class comment).
  Duration _pace(FaceFrame answer) {
    if (answer.reason == 'again') return faceInARow < 12 ? Duration.zero : quick;
    if (answer.face) return faceInARow < 3 ? Duration.zero : (faceInARow < 12 ? quick : slow);
    if (noFaceInARow < idleFrames) return quick;
    return _watched ? slow : slowUnwatched;
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
