import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'ringer.dart';

/// The ring on a device, every platform alike: the bundled ring (assets/sounds/ring.wav, made by tool/make_ring.py)
/// looped through the speaker while a call rings. Should the player refuse (no audio device, a plugin error), the
/// system alert sound once a second stands in, which is what the Mac did in the spike.
class AssetRinger implements Ringer {
  AssetRinger({this.asset = 'sounds/ring.wav'});

  final String asset;
  AudioPlayer? _player;
  Timer? _fallback;
  int _ring = 0; // which start() is current, so a stop() during start() wins

  /// Android plays it on the ring stream (the ring volume; a tablet on silent stays silent, like a phone would)
  /// over whatever else plays. iOS plays it over other audio and over the ring/silent switch: a terminal that is a
  /// phone has to ring. The Mac has no such settings and ignores this.
  static final _context = AudioContext(
    android: const AudioContextAndroid(
      contentType: AndroidContentType.sonification,
      usageType: AndroidUsageType.notificationRingtone,
      audioFocus: AndroidAudioFocus.gainTransientMayDuck,
    ),
    iOS: AudioContextIOS(
      category: AVAudioSessionCategory.playback,
      options: const {AVAudioSessionOptions.mixWithOthers, AVAudioSessionOptions.duckOthers},
    ),
  );

  @override
  Future<void> start() async {
    final ring = ++_ring;
    _fallback?.cancel();
    _fallback = null;
    try {
      var player = _player;
      if (player == null) {
        player = _player = AudioPlayer();
        await player.setReleaseMode(ReleaseMode.loop);
      }
      await player.setAudioContext(_context);
      if (ring != _ring) return;
      await player.play(AssetSource(asset));
      if (ring != _ring) await player.stop(); // stopped while the play call was on its way
    } catch (err) {
      debugPrint('ringer: $err');
      if (ring != _ring) return;
      _fallback ??= Timer.periodic(const Duration(seconds: 1), (_) => SystemSound.play(SystemSoundType.alert));
      unawaited(SystemSound.play(SystemSoundType.alert));
    }
  }

  @override
  Future<void> stop() async {
    _ring++;
    _fallback?.cancel();
    _fallback = null;
    try {
      await _player?.stop();
    } catch (err) {
      debugPrint('ringer: $err');
    }
  }
}
