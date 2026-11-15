import 'dart:async';

import 'package:flutter/services.dart';

/// A badge reader in keyboard mode (USB or Bluetooth: an NFC or RFID reader of the kind a Mac, an iPad, an
/// iPhone or an Android tablet all take) types a tag's id and Enter, far faster than fingers. A burst of
/// [minLength] or more letters and digits with no more than [gap] between keys, ended by Enter within the
/// same gap, is a tag; keys at a human pace are left to whatever has the focus. A burst typed while a text
/// field has the focus still lands in the field (rare: a badge tapped mid-name), and is a tag all the same.
class BurstDetector {
  BurstDetector({this.gap = const Duration(milliseconds: 60), this.minLength = 4, this.maxLength = 64});

  final Duration gap;
  final int minLength;
  final int maxLength;
  final _buffer = StringBuffer();
  DateTime? _last;

  /// Whether the key fed last came on the heels of a tag's characters, at the reader's pace: the reader is
  /// most likely still typing.
  bool midBurst = false;

  static final _tagChar = RegExp(r'^[A-Za-z0-9]$');
  static final _separator = RegExp(r'^[ :\-]$'); // some readers type the id in groups

  /// One key down: its printable [character], or [enter]. The tag's id once a burst ends in Enter, else null.
  String? feed({String? character, bool enter = false, required DateTime at}) {
    final last = _last;
    final continues = last != null && at.difference(last) <= gap;
    if (!continues) _buffer.clear();
    midBurst = continues && _buffer.isNotEmpty;
    if (enter) {
      final text = _buffer.toString();
      _buffer.clear();
      _last = null;
      return continues && text.length >= minLength && text.length <= maxLength ? text.toUpperCase() : null;
    }
    _last = at;
    if (character == null || character.length != 1) {
      _buffer.clear();
      return null;
    }
    if (_separator.hasMatch(character)) return null;
    if (!_tagChar.hasMatch(character)) {
      _buffer.clear();
      return null;
    }
    _buffer.write(character);
    if (_buffer.length > maxLength) _buffer.clear();
    return null;
  }
}

/// Where tags come from: the reads go to the sign-in, except the one an enrollment is waiting for.
abstract class TagReader {
  /// The next tag read, for an enrollment; null when none came within [timeout] or [cancel] was called.
  Future<String?> next({Duration timeout = const Duration(seconds: 30)});

  /// Lets go of a pending [next]: its tag, if one still comes, signs in as any other.
  void cancel();
}

/// The reader on this terminal's keyboard: every hardware key goes through [BurstDetector], and a tag goes to
/// [onTag] (the sign-in) unless an enrollment asked for it with [next].
class WedgeTagReader implements TagReader {
  WedgeTagReader({required this.onTag, DateTime Function()? clock, BurstDetector? bursts})
    : clock = clock ?? DateTime.now,
      bursts = bursts ?? BurstDetector();

  final void Function(String uid) onTag;
  final DateTime Function() clock;
  final BurstDetector bursts;
  Completer<String?>? _waiting;
  bool _installed = false;
  KeyEvent? _typed;

  /// Starts listening to the keyboard, for as long as the app runs.
  void install() {
    if (_installed) return;
    _installed = true;
    HardwareKeyboard.instance.addHandler(handle);
  }

  void uninstall() {
    if (!_installed) return;
    _installed = false;
    HardwareKeyboard.instance.removeHandler(handle);
  }

  /// One key event; never swallowed, so typing is unaffected.
  bool handle(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    final enter = event.logicalKey == LogicalKeyboardKey.enter || event.logicalKey == LogicalKeyboardKey.numpadEnter;
    final uid = bursts.feed(character: enter ? null : event.character, enter: enter, at: clock());
    // The Enter that ends a tag, and a space the reader types inside one: keys that would press a button.
    final presses = enter ? uid != null : event.logicalKey == LogicalKeyboardKey.space && bursts.midBurst;
    _typed = presses ? event : null;
    if (uid != null) read(uid);
    return false;
  }

  /// Whether [event] is a key the reader typed that would press whatever button has the keyboard's focus:
  /// the Enter that ends a tag, or a space inside one. The app keeps these from the buttons
  /// (`ReaderKeysPressNothing`): a badge tapped at the reader signs its owner in, it must not also repeat
  /// the last thing touched on the screen. True only while that same key is being handled.
  bool typed(KeyEvent event) => identical(event, _typed);

  /// A tag as the reader typed it (or as something else says it did).
  void read(String uid) {
    final waiting = _waiting;
    if (waiting != null && !waiting.isCompleted) {
      _waiting = null;
      waiting.complete(uid);
      return;
    }
    onTag(uid);
  }

  @override
  Future<String?> next({Duration timeout = const Duration(seconds: 30)}) {
    cancel();
    final waiting = _waiting = Completer<String?>();
    return waiting.future.timeout(
      timeout,
      onTimeout: () {
        if (identical(_waiting, waiting)) _waiting = null;
        return null;
      },
    );
  }

  @override
  void cancel() {
    final waiting = _waiting;
    _waiting = null;
    if (waiting != null && !waiting.isCompleted) waiting.complete(null);
  }
}
