import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'kitchen_bell.dart';

/// The kitchen screen's chime on a device, every platform alike: the bundled one (assets/sounds/ticket.wav,
/// made by tool/make_chime.py) played once through the speaker. Should the player refuse (no audio device, a
/// plugin error), the system alert sound stands in.
class AssetChime implements Chime {
  AssetChime({this.asset = 'sounds/ticket.wav'});

  final String asset;
  AudioPlayer? _player;
  bool _played = false; // it has sounded before: the one before may still be sounding

  /// Android plays it as media, which is the volume the device's own buttons turn up and down, over
  /// whatever else plays. iOS plays it over other audio and over the ring/silent switch: a tablet on the
  /// kitchen wall has to be heard. The Mac has no such settings and ignores this.
  static final _context = AudioContext(
    android: const AudioContextAndroid(
      contentType: AndroidContentType.sonification,
      usageType: AndroidUsageType.media,
      audioFocus: AndroidAudioFocus.gainTransientMayDuck,
    ),
    iOS: AudioContextIOS(
      category: AVAudioSessionCategory.playback,
      options: const {AVAudioSessionOptions.mixWithOthers},
    ),
  );

  @override
  Future<void> play() async {
    try {
      var player = _player;
      if (player == null) {
        player = _player = AudioPlayer();
        await player.setReleaseMode(ReleaseMode.stop);
      }
      await player.setAudioContext(_context);
      // (a chime still sounding starts over: the latest ticket is the one to be heard)
      if (_played) await player.stop();
      _played = true;
      await player.play(AssetSource(asset));
    } catch (err) {
      debugPrint('chime: $err');
      unawaited(SystemSound.play(SystemSoundType.alert));
    }
  }
}
