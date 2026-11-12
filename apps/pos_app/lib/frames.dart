import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

/// A frame that reached the screen late, and where its time went.
class LateFrame {
  const LateFrame({required this.at, required this.build, required this.paint});

  final DateTime at;

  /// The app's own work for the frame: building the screen and laying it out.
  final Duration build;

  /// Painting it, on the engine's raster thread.
  final Duration paint;
}

/// How smoothly this device draws.
///
/// The engine times every frame: the app's own work (building the screen and laying it out) and the
/// painting. At sixty frames a second each of the two has 16.7 ms; a frame where either took longer reached
/// the screen late, and that is the stutter an operator sees. This counts the frames and the late ones since
/// the app started (or since [reset]) and keeps the latest of them, so that a slow tablet can be asked where
/// it struggles instead of guessed at: Settings shows it under Smoothness.
///
/// Watching costs nothing worth naming: the engine hands the timings over in batches, about once a second,
/// and a batch is a few additions.
class FrameWatch extends ChangeNotifier {
  FrameWatch({DateTime Function()? now}) : _now = now ?? DateTime.now {
    since = _now();
  }

  /// The one the app runs, started in `main`.
  static final shared = FrameWatch();

  /// What a frame may take at sixty frames a second.
  static const budget = Duration(microseconds: 16667);

  /// How many of the latest late frames are kept.
  static const keep = 12;

  final DateTime Function() _now;

  /// When the counting began.
  late DateTime since;
  int frames = 0;
  int late = 0;

  /// The longest a frame's building or painting took.
  Duration worst = Duration.zero;

  /// The latest late frames, newest first.
  final List<LateFrame> latest = [];

  bool _started = false;

  /// Begins watching the frames this app draws. Asked twice, it watches once.
  void start() {
    if (_started) return;
    _started = true;
    SchedulerBinding.instance.addTimingsCallback(add);
  }

  /// Takes a batch of timings from the engine. Listeners hear of late frames only: a screen showing these
  /// numbers must not draw a frame for every batch of frames, its own among them, without end.
  void add(List<FrameTiming> timings) {
    var wasLate = false;
    for (final timing in timings) {
      frames += 1;
      final build = timing.buildDuration;
      final paint = timing.rasterDuration;
      final longer = build > paint ? build : paint;
      if (longer > worst) worst = longer;
      if (longer <= budget) continue;
      late += 1;
      wasLate = true;
      latest.insert(0, LateFrame(at: _now(), build: build, paint: paint));
      if (latest.length > keep) latest.removeLast();
    }
    if (wasLate) notifyListeners();
  }

  /// Starts the count over, e.g. before trying one thing on a device to see what it costs.
  void reset() {
    since = _now();
    frames = 0;
    late = 0;
    worst = Duration.zero;
    latest.clear();
    notifyListeners();
  }

  /// A timing as the engine would report it, for tests: a frame whose building took `build` and whose
  /// painting took `paint`.
  @visibleForTesting
  static FrameTiming timing({required Duration build, required Duration paint}) => FrameTiming(
    vsyncStart: 0,
    buildStart: 0,
    buildFinish: build.inMicroseconds,
    rasterStart: build.inMicroseconds,
    rasterFinish: build.inMicroseconds + paint.inMicroseconds,
    rasterFinishWallTime: build.inMicroseconds + paint.inMicroseconds,
  );
}

/// Milliseconds as a screen says them: "41 ms", and one decimal under ten ("8.3 ms").
String millis(Duration d) {
  final ms = d.inMicroseconds / 1000;
  return '${ms >= 10 ? ms.round() : ms.toStringAsFixed(1)} ms';
}
