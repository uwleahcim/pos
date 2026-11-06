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

  /// Someone is signed in; the camera keeps an eye on who is at the screen.
  signedIn,
}

/// Looks for the person at this screen for as long as the app runs: frames off the camera go to the hub,
/// which does the recognising. With nobody signed in, the first enrolled face the hub is sure of signs in,
/// and the PIN pad works meanwhile. With someone signed in, each frame says who, and the hub answers `same`
/// while that person is the one at the screen; another enrolled person stepping up takes the screen over at
/// once while the location's hands-free [switching] is on, and a person the camera has not seen for
/// [awaySeconds] is signed out (once the camera has recognised them at the screen at all, so a person who
/// signed in by PIN and is not enrolled stays). A tag held to a reader does the same by its id ([tag]).
/// While something [hold]s the loop (an enrollment, a manager typing a PIN for an approval), nothing is sent
/// and nothing switches.
///
/// The pace. While a face is in view the next frame leaves as soon as the hub answers the last one: a
/// strong match signs in on one frame, a weaker one on the next frame that agrees. After a few frames with
/// a face but no sign-in (or the same person, signed in) the pace drops to one every [quick], after many to
/// one every [slow]. With nobody in view a frame goes every [quick], then every [slow] once [idleFrames]
/// in a row were empty, so twenty idle terminals do not keep the hub busy; a camera that can
/// [EventCamera.watch] reports a change in its view (someone stepping up to the screen) and the next frame
/// goes at once, one that cannot (the Mac) idles at [slowUnwatched] instead. When the hub says it is not
/// looking (off, no models, nobody enrolled) it is asked again every [recheck], as are the location's
/// hands-free settings.
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
    DateTime Function()? clock,
  }) : clock = clock ?? DateTime.now;

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
  final DateTime Function() clock;

  FaceState state = FaceState.off;
  FaceStatus? status;

  /// The location's hands-free switching, as the hub last said.
  HandsFree handsFree = const HandsFree();
  bool get switching => handsFree.switching;
  int get awaySeconds => handsFree.awaySeconds;

  /// What the screen says under the preview, or null for nothing.
  String? message;

  /// A word about a tag just read ("Unknown tag"), for a few seconds, whatever else the screen says.
  String? notice;
  int frames = 0;
  int unknownInARow = 0;
  int noFaceInARow = 0;

  /// Frames in a row with a face in them and no sign-in: the pace drops as this grows.
  int faceInARow = 0;

  /// What went wrong last (no hub answers, an answer this app could not read), for the settings screen;
  /// null once a call goes through again.
  String? lastError;

  /// How many things hold every loop: while above zero, no frame goes and no tag signs anyone in.
  static final ValueNotifier<int> holds = ValueNotifier(0);

  static void hold() => holds.value += 1;

  static void release() => holds.value = holds.value > 0 ? holds.value - 1 : 0;

  static bool get held => holds.value > 0;

  Timer? _timer;
  Timer? _noticeTimer;
  bool _running = false;
  bool _busy = false;
  bool _watching = false; // the camera was asked to keep its frames coming; unwatch is owed
  bool _watched = false; // and it does, reporting a change in its view
  int _seenMotion = 0;
  String? _staffId; // the session's person as last noticed, to see it change
  DateTime? _seenAt; // when the hub last saw the signed-in person
  bool _recognised = false; // the hub has recognised the signed-in person at the screen at least once
  DateTime? _settingsAt;

  bool get running => _running;

  /// Whether the camera keeps its frames coming and reports a change in its view.
  bool get watched => _watched;

  /// Starts looking, or asks the hub whether it should.
  void start() {
    if (_running) return;
    _running = true;
    _staffId = session.staff?.staffId;
    _seenAt = clock();
    _recognised = session.staff?.method == 'face';
    camera.addListener(_cameraChanged);
    session.addListener(_sessionChanged);
    holds.addListener(_holdChanged);
    _schedule(Duration.zero);
  }

  void stop() {
    _running = false;
    _timer?.cancel();
    _timer = null;
    _noticeTimer?.cancel();
    _noticeTimer = null;
    camera.removeListener(_cameraChanged);
    session.removeListener(_sessionChanged);
    holds.removeListener(_holdChanged);
    _unwatch();
  }

  /// Someone the hub is sure of, by face or by tag: signed in when nobody is, switched to when someone else
  /// is and the location switches hands-free, left alone otherwise (or when it is the person signed in).
  /// Whether the session changed.
  bool arrive(Map<String, dynamic> signedIn) {
    final id = signedIn['staff_id'] as String?;
    if (id == null) return false;
    final current = session.staff?.staffId;
    if (current == id) {
      _seenAt = clock();
      if (signedIn['method'] == 'face') _recognised = true;
      return false;
    }
    if (current != null && !switching) return false;
    session.applySignIn(signedIn);
    return true;
  }

  /// A tag held to this screen's reader: the hub says whose it is, and they are signed in or switched to as a
  /// face would be. "Unknown tag" shows for one nobody's.
  Future<void> tag(String uid) async {
    if (held) return;
    try {
      final json = await api.signIn(device: settings.device, tagUid: uid);
      if (!arrive(json) && session.staff?.staffId != json['staff_id']) {
        _notify('Switching is off here: sign out first');
      }
    } on ApiException catch (err) {
      _notify(err.status == 401 ? 'Unknown tag' : err.message);
    }
  }

  void _notify(String text) {
    notice = text;
    notifyListeners();
    _noticeTimer?.cancel();
    _noticeTimer = Timer(const Duration(seconds: 4), () {
      notice = null;
      notifyListeners();
    });
  }

  /// The session changed under the loop (a PIN, a tag, a sign-out, a switch): the counters start over and the
  /// next frame goes at once, saying who is signed in now.
  void _sessionChanged() {
    final staff = session.staff;
    if (staff?.staffId == _staffId) return;
    _staffId = staff?.staffId;
    _seenAt = clock();
    _recognised = staff?.method == 'face';
    unknownInARow = 0;
    faceInARow = 0;
    noFaceInARow = 0;
    if (state != FaceState.off) {
      if (staff != null) {
        _become(FaceState.signedIn, 'Hi ${staff.name}');
      } else {
        _become(FaceState.looking, 'Look at the camera, or tap your PIN');
      }
    }
    if (_running && !_busy && state != FaceState.off) _schedule(Duration.zero);
  }

  void _holdChanged() {
    if (!held && _running && !_busy) _schedule(Duration.zero);
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

  /// Whether frames go while someone is signed in: to let someone else take over, or to sign out a person
  /// the camera no longer sees.
  bool get _watchesSignedIn => switching || (awaySeconds > 0 && _recognised);

  /// One step: the status when not looking, else one frame to the hub.
  Future<void> _step() async {
    if (!_running || _busy) return;
    _busy = true;
    try {
      if (held) {
        _schedule(recheck); // released: a frame goes at once (the hold's listener)
      } else if (state == FaceState.off || status == null) {
        await _checkStatus();
      } else {
        await _refreshHandsFree();
        if (session.signedIn && !_watchesSignedIn) {
          _unwatch();
          _schedule(recheck);
        } else {
          await _sendFrame();
        }
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

  /// The location's hands-free settings, asked for every [recheck]; an older hub without them leaves the
  /// defaults.
  Future<void> _refreshHandsFree() async {
    final at = _settingsAt;
    final now = clock();
    if (at != null && now.difference(at) < recheck) return;
    _settingsAt = now;
    try {
      handsFree = await api.handsFree();
    } on ApiException {
      // the defaults stand
    }
  }

  Future<void> _checkStatus() async {
    try {
      final found = await api.faceStatus();
      status = found;
      lastError = null;
      if (found.active) {
        _settingsAt = null;
        await _refreshHandsFree();
        final staff = session.staff;
        if (staff != null) {
          _become(FaceState.signedIn, 'Hi ${staff.name}');
        } else {
          _become(FaceState.looking, 'Look at the camera, or tap your PIN');
        }
        noFaceInARow = 0;
        faceInARow = 0;
        if (!session.signedIn || _watchesSignedIn) await _watch();
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
    await _watch();
    final jpeg = await camera.frame();
    if (!_running) return;
    if (jpeg == null) {
      _schedule(const Duration(seconds: 1)); // the camera is not up yet, or the app is in the background
      return;
    }
    final current = session.staff?.staffId;
    final FaceFrame answer;
    try {
      answer = await api.faceFrame(device: settings.device, jpeg: jpeg, current: current);
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
    final now = clock();
    if (answer.present && session.staff?.staffId == current) {
      _seenAt = now;
      _recognised = true;
    }
    final signed = answer.signedIn;
    if (signed != null && arrive(signed)) {
      _schedule(_pace(answer));
      return;
    }
    final signedIn = session.signedIn;
    switch (answer.reason) {
      case 'off' || 'not_ready':
        status = null;
        _unwatch();
        _become(FaceState.off, null);
        _schedule(recheck);
        return;
      case 'same':
        unknownInARow = 0;
      case 'again':
        unknownInARow = 0;
        if (!signedIn) _become(FaceState.holding, 'Hold still…');
      case 'too_small':
        unknownInARow = 0;
        if (!signedIn) _become(FaceState.looking, 'Come closer');
      case 'unknown':
        unknownInARow += 1;
        if (!signedIn) _become(FaceState.unknown, unknownInARow >= 3 ? 'Not recognised: tap your PIN' : 'Looking…');
      default: // no_face, or someone else the switch is off for
        unknownInARow = 0;
        if (!signedIn) _become(FaceState.looking, 'Look at the camera, or tap your PIN');
    }
    if (_away(now)) {
      session.signOut(); // the session's listener puts the screen back to looking
      return;
    }
    _schedule(_pace(answer));
  }

  /// Whether the person signed in has been out of the camera's sight for [awaySeconds].
  bool _away(DateTime now) {
    final seen = _seenAt;
    if (!session.signedIn || !_recognised || awaySeconds <= 0 || seen == null) return false;
    return now.difference(seen).inSeconds >= awaySeconds;
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
    _noticeTimer?.cancel();
    super.dispose();
  }
}
