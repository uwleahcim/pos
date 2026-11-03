import 'package:sip_ua/sip_ua.dart';

import 'phone.dart';

/// The SIP stack behind the phone: sip_ua (a Dart port of JsSIP) over a secure WebSocket to Asterisk, with the
/// audio as WebRTC media. One helper per registration; the calls are kept by id for the phone's commands.
class SipUaStack implements SipStack, SipUaHelperListener {
  SIPUAHelper? _helper;
  SipEvents? _events;
  final Map<String, Call> _calls = {};

  @override
  Future<void> start(PhoneSettings settings, SipEvents events) async {
    await stop();
    _events = events;
    final helper = SIPUAHelper()..addSipUaHelperListener(this);
    _helper = helper;
    final ua = UaSettings()
      ..transportType = TransportType.WS
      ..webSocketUrl = settings.webSocketUrl
      ..uri = settings.sipUri
      ..authorizationUser = settings.extension
      ..password = settings.secret
      ..displayName = settings.displayName.isEmpty ? settings.extension : settings.displayName
      ..userAgent = 'POS app'
      ..register = true
      ..dtmfMode = DtmfMode.RFC2833;
    ua.webSocketSettings.userAgent = 'POS app';
    try {
      await helper.start(ua);
    } catch (err) {
      _events?.registrationFailed('$err');
    }
  }

  @override
  Future<void> stop() async {
    final helper = _helper;
    _helper = null;
    _events = null;
    _calls.clear();
    if (helper != null) {
      helper.removeSipUaHelperListener(this);
      helper.stop();
    }
  }

  @override
  void answer(String callId) {
    final helper = _helper;
    final call = _calls[callId];
    if (helper == null || call == null) return;
    call.answer(helper.buildCallOptions(true));
  }

  @override
  void hangUp(String callId) => _calls[callId]?.hangup();

  @override
  void decline(String callId) => _calls[callId]?.hangup({'status_code': 486});

  @override
  void setMuted(String callId, bool on) {
    final call = _calls[callId];
    if (call == null) return;
    if (on) {
      call.mute(true, false);
    } else {
      call.unmute(true, false);
    }
  }

  @override
  void setHeld(String callId, bool on) {
    final call = _calls[callId];
    if (call == null) return;
    if (on) {
      call.hold();
    } else {
      call.unhold();
    }
  }

  @override
  void sendDtmf(String callId, String tones) => _calls[callId]?.sendDTMF(tones);

  /// A plain extension or number: sip_ua completes it with the PBX's domain and sends the REFER; when the PBX
  /// accepts, sip_ua ends this side of the call.
  @override
  void transfer(String callId, String target) => _calls[callId]?.refer(target);

  @override
  void transportStateChanged(TransportState state) {
    if (state.state == TransportStateEnum.DISCONNECTED) {
      _events?.disconnected(
        _reason(state.cause?.status_code, state.cause?.reason_phrase, state.cause?.cause) ?? 'connection lost',
      );
    }
  }

  @override
  void registrationStateChanged(RegistrationState state) {
    switch (state.state) {
      case RegistrationStateEnum.REGISTERED:
        _events?.registered();
      case RegistrationStateEnum.REGISTRATION_FAILED:
        _events?.registrationFailed(
          _reason(state.cause?.status_code, state.cause?.reason_phrase, state.cause?.cause) ?? 'registration refused',
        );
      case RegistrationStateEnum.UNREGISTERED:
        _events?.disconnected(
          _reason(state.cause?.status_code, state.cause?.reason_phrase, state.cause?.cause) ?? 'unregistered',
        );
      case RegistrationStateEnum.NONE:
      case null:
        break;
    }
  }

  @override
  void callStateChanged(Call call, CallState state) {
    final id = call.id ?? '';
    switch (state.state) {
      case CallStateEnum.CALL_INITIATION:
        _calls[id] = call;
        if (call.direction == Direction.incoming) {
          _events?.incomingCall(id, number: call.remote_identity, name: call.remote_display_name);
        }
      case CallStateEnum.ACCEPTED:
      case CallStateEnum.CONFIRMED:
        _events?.callAccepted(id);
      case CallStateEnum.ENDED:
      case CallStateEnum.FAILED:
        _calls.remove(id);
        _events?.callEnded(id, _reason(state.cause?.status_code, state.cause?.reason_phrase, state.cause?.cause));
      default:
        break;
    }
  }

  @override
  void onNewMessage(SIPMessageRequest msg) {}

  @override
  void onNewNotify(Notify ntf) {}

  @override
  void onNewReinvite(ReInvite event) {}

  /// `486 Busy Here`, `Busy`, or nothing: the SIP status and reason phrase when there is one, else sip_ua's cause.
  static String? _reason(int? code, String? phrase, String? cause) {
    final text = phrase ?? cause;
    if (code != null && text != null) return '$code $text';
    return text ?? code?.toString();
  }
}
