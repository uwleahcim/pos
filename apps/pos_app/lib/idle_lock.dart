import 'dart:async';

import 'package:flutter/services.dart';

import 'session.dart';
import 'settings.dart';

/// What a locked screen says above the sign-in pad: why the pad is there, who was signed in, and that
/// nothing was closed. Short, since on a phone the pad under it needs the room.
String lockedNote(int minutes, String name) {
  final after = minutes == 1 ? '1 minute' : '$minutes minutes';
  final who = name.isEmpty ? '' : ' $name was signed in.';
  return 'Locked after $after untouched.$who Nothing was closed.';
}

/// Locks a screen nobody has touched for the minutes the device was given ([Settings.lockMinutes]; 0, how
/// a device starts, never locks). A touch, a click, the mouse moving, the wheel and a key on the keyboard
/// (a badge reader types too) are someone at the screen ([touched]). The lock is [Session.lock]: the
/// sign-in pad comes over whatever was open, and nothing under it is closed or lost.
///
/// It keeps no timer per touch: a touch only notes the time, and the clock is looked at every [every] while
/// somebody is signed in and the device has minutes set, and again when the app comes back to the front, so
/// a device that slept through its minutes is locked the moment it wakes.
class IdleLock {
  IdleLock(this.settings, this.session, {int Function()? now, this.every = const Duration(seconds: 5)})
    : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final Settings settings;
  final Session session;

  /// How often the clock is looked at: a screen locks at most this long after its minutes are up.
  final Duration every;
  final int Function() _now;

  Timer? _timer;
  int _touchedMs = 0;
  bool _started = false;
  String? _staffId;
  int _minutes = 0;

  /// The minutes this device locks after; 0 for never.
  int get minutes => settings.lockMinutes;

  /// Whether the clock is being looked at: somebody is signed in on a device with minutes set.
  bool get watching => _timer != null;

  void start() {
    if (_started) return;
    _started = true;
    _touchedMs = _now();
    _staffId = session.staff?.staffId;
    _minutes = minutes;
    session.addListener(_changed);
    settings.addListener(_changed);
    HardwareKeyboard.instance.addHandler(_key);
    _arm();
  }

  /// Someone is at the screen: the minutes count from now.
  void touched() => _touchedMs = _now();

  bool _key(KeyEvent event) {
    touched();
    return false; // only noted: the key goes where it was going
  }

  /// A sign-in, a switch to another person or other minutes set on the device: the minutes count from now.
  /// (The session and the settings tell of other things too, which are not somebody at the screen.)
  void _changed() {
    final id = session.staff?.staffId;
    if (id != _staffId || minutes != _minutes) {
      if (id != null) touched();
      _staffId = id;
      _minutes = minutes;
    }
    _arm();
  }

  void _arm() {
    final wanted = _started && minutes > 0 && session.signedIn;
    if (!wanted) {
      _timer?.cancel();
      _timer = null;
    } else {
      _timer ??= Timer.periodic(every, (_) => check());
    }
  }

  /// Locks the screen when its minutes are up. Asked every [every], and when the app comes back in front.
  void check() {
    if (!_started || minutes <= 0 || !session.signedIn) return;
    if (_now() - _touchedMs >= minutes * Duration.millisecondsPerMinute) session.lock();
  }

  void dispose() {
    if (!_started) return;
    _started = false;
    session.removeListener(_changed);
    settings.removeListener(_changed);
    HardwareKeyboard.instance.removeHandler(_key);
    _timer?.cancel();
    _timer = null;
  }
}
