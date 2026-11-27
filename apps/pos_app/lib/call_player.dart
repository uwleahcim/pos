import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Where the playing of a recorded call stands.
@immutable
class CallPlayback {
  const CallPlayback({this.position = Duration.zero, this.length, this.playing = false});

  /// Nothing loaded.
  static const idle = CallPlayback();

  /// How far in.
  final Duration position;

  /// How long the recording runs, once the player has read it.
  final Duration? length;

  /// Sounding now; otherwise paused, at its end, or not started.
  final bool playing;

  CallPlayback copyWith({Duration? position, Duration? length, bool? playing}) => CallPlayback(
    position: position ?? this.position,
    length: length ?? this.length,
    playing: playing ?? this.playing,
  );

  @override
  bool operator ==(Object other) =>
      other is CallPlayback && other.position == position && other.length == length && other.playing == playing;

  @override
  int get hashCode => Object.hash(position, length, playing);
}

/// Plays one recorded call at a time (docs/call-recordings.md). The calls sheet talks to this and never to
/// the speaker itself, so a test can stand in for it.
abstract class CallPlayer {
  /// Where the playing stands; it changes a few times a second while a call plays.
  ValueListenable<CallPlayback> get playback;

  /// Plays a call's MP3 from its start, in place of whatever played before.
  Future<void> play(Uint8List mp3);

  Future<void> pause();

  /// Goes on from where it was paused, or from the start once it has played to its end.
  Future<void> resume();

  Future<void> seek(Duration to);

  /// Stops and lets go of the recording: nothing of it is left on the device.
  Future<void> close();
}

/// The speaker of a device, every platform alike. The recording is put in a file of the device's own folder
/// for passing things, since not every platform's player takes sound from memory, played from there, and
/// removed when the sheet closes.
class DeviceCallPlayer implements CallPlayer {
  final _playback = ValueNotifier<CallPlayback>(CallPlayback.idle);
  final _hears = <StreamSubscription<Object?>>[];
  AudioPlayer? _player;
  File? _file;
  int _turn = 0; // which play() is current: an older one that is still loading gives way
  bool _ended = false;
  bool _closed = false;

  @override
  ValueListenable<CallPlayback> get playback => _playback;

  void _say(CallPlayback next) {
    if (!_closed) _playback.value = next;
  }

  AudioPlayer _ready() {
    var player = _player;
    if (player != null) return player;
    player = _player = AudioPlayer();
    _hears
      ..add(player.onPositionChanged.listen((at) => _say(_playback.value.copyWith(position: at))))
      ..add(player.onDurationChanged.listen((length) => _say(_playback.value.copyWith(length: length))))
      ..add(
        player.onPlayerStateChanged.listen(
          (state) => _say(_playback.value.copyWith(playing: state == PlayerState.playing)),
        ),
      )
      ..add(
        player.onPlayerComplete.listen((_) {
          _ended = true;
          final length = _playback.value.length;
          _say(_playback.value.copyWith(playing: false, position: length));
        }),
      );
    return player;
  }

  @override
  Future<void> play(Uint8List mp3) async {
    final turn = ++_turn;
    final player = _ready();
    await player.stop();
    _say(CallPlayback.idle);
    final folder = await getTemporaryDirectory();
    final file = File('${folder.path}/pos-call-${DateTime.now().microsecondsSinceEpoch}.mp3');
    await file.writeAsBytes(mp3, flush: true);
    final before = _file;
    _file = file;
    if (before != null) unawaited(_remove(before));
    if (turn != _turn || _closed) return;
    _ended = false;
    await player.setReleaseMode(ReleaseMode.stop);
    await player.play(DeviceFileSource(file.path, mimeType: 'audio/mpeg'));
  }

  @override
  Future<void> pause() async => _player?.pause();

  @override
  Future<void> resume() async {
    final player = _player;
    final file = _file;
    if (player == null || file == null) return;
    if (_ended) {
      _ended = false;
      await player.play(DeviceFileSource(file.path, mimeType: 'audio/mpeg'));
    } else {
      await player.resume();
    }
  }

  @override
  Future<void> seek(Duration to) async {
    final player = _player;
    if (player == null) return;
    _ended = false;
    await player.seek(to);
    _say(_playback.value.copyWith(position: to));
  }

  @override
  Future<void> close() async {
    _closed = true;
    _turn++;
    for (final hears in _hears) {
      unawaited(hears.cancel());
    }
    _hears.clear();
    final player = _player;
    _player = null;
    try {
      await player?.stop();
      await player?.dispose();
    } catch (err) {
      debugPrint('call player: $err');
    }
    final file = _file;
    _file = null;
    if (file != null) await _remove(file);
  }

  static Future<void> _remove(File file) async {
    try {
      await file.delete();
    } on FileSystemException {
      // already gone, or the folder was cleared: nothing is left either way
    }
  }
}
