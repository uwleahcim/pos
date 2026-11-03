import 'dart:async';

import 'phone.dart';

/// Something that can make the ringing sound: the asset player on a device, a fake in tests.
abstract interface class Ringer {
  Future<void> start();
  Future<void> stop();
}

/// Rings while the phone rings. Starts the sound the moment a call comes in, stops it the moment Answer is tapped
/// (before the PBX confirms: the call's audio must not find the ring still holding the device's audio session),
/// when the call is declined or given up, and when disposed. Whatever else the phone reports in between (a
/// dropped connection, a second call turned away) leaves a ring that is on alone.
class CallRinger {
  CallRinger(this._phone, this._ringer) {
    _phone.addListener(_onPhone);
    _onPhone();
  }

  final PhoneClient _phone;
  final Ringer _ringer;
  bool _ringing = false;

  void _onPhone() {
    final shouldRing = _phone.state == PhoneState.ringing && !_phone.answering;
    if (shouldRing == _ringing) return;
    _ringing = shouldRing;
    unawaited(shouldRing ? _ringer.start() : _ringer.stop());
  }

  void dispose() {
    _phone.removeListener(_onPhone);
    if (_ringing) {
      _ringing = false;
      unawaited(_ringer.stop());
    }
  }
}
