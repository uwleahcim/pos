import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../api.dart';
import '../camera.dart';
import '../face_signin.dart';
import '../live.dart';
import '../session.dart';
import '../settings.dart';
import '../timeclock.dart';
import 'compact.dart';
import 'face_guide.dart';
import 'theme.dart';
import 'time_clock_card.dart';

/// PIN pad with the camera preview beside it. While the location signs staff in by face, the preview looks
/// for an enrolled face (the hub recognises it) and the pad works all the same; a tag held to the terminal's
/// reader signs in too. The looking itself runs for as long as the app does ([FaceSignIn]); this screen shows
/// what it says.
///
/// Where the location uses the time clock (docs/time-clock.md) the bar has a Time clock button: the pad then
/// takes a PIN for the clock instead of signing in, and the person's card, with their punches, takes the
/// pad's place. It is drawn here and not as a dialog, so it works on a locked screen too.
class SignInScreen extends StatefulWidget {
  const SignInScreen({
    super.key,
    required this.session,
    required this.settings,
    required this.camera,
    this.onSettings,
    this.faces,
    this.lockedNote,
  });

  final Session session;
  final Settings settings;
  final EventCamera camera;
  final VoidCallback? onSettings;

  /// The app's face sign-in, which runs on after this screen goes; the screen makes and runs its own when
  /// none is given.
  final FaceSignIn? faces;

  /// On a screen that locked itself for standing idle: why the pad is here and that nothing was closed,
  /// shown above the pad. Null on the plain sign-in screen.
  final String? lockedNote;

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> with SingleTickerProviderStateMixin {
  String _pin = '';
  String? _message;
  bool _busy = false;
  late final AnimationController _shake = AnimationController(vsync: this, duration: const Duration(milliseconds: 420));
  late final FaceSignIn _faces =
      widget.faces ?? FaceSignIn(widget.session.api, widget.settings, widget.camera, widget.session);
  // The time clock: whether the location uses it (null until the hub says, and from a hub older than it),
  // whether the pad is taking a PIN for it, and the person at it with the PIN they typed.
  ClockSetting? _clock;
  bool _clocking = false;
  (String, ClockStand)? _atClock;
  StreamSubscription<LiveChange>? _live;

  @override
  void initState() {
    super.initState();
    _faces.addListener(_changed);
    // A phone's camera comes up after the first build: the ready dot (and the preview) follow it.
    widget.camera.addListener(_changed);
    if (widget.camera is! NoCamera) _faces.start();
    unawaited(_readClock());
    // A manager turning the clock on or off at another screen shows here without anybody signing in.
    _live = widget.session.api.live.changes.listen((change) {
      if (change.settings || change.everything) unawaited(_readClock());
    });
  }

  Future<void> _readClock() async {
    try {
      final clock = await widget.session.api.clockSetting();
      if (!mounted || (clock?.enabled ?? false) == (_clock?.enabled ?? false)) return;
      setState(() {
        _clock = clock;
        if (!(clock?.enabled ?? false)) {
          _clocking = false;
          _atClock = null;
        }
      });
    } on ApiException {
      // nothing answers: the pad stays as it was
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    unawaited(_live?.cancel());
    widget.camera.removeListener(_changed);
    _faces.removeListener(_changed);
    if (widget.faces == null) _faces.dispose();
    _shake.dispose();
    super.dispose();
  }

  /// The guide's colour: how the face sign-in stands.
  Color _guideColor(ColorScheme scheme) => switch (_faces.state) {
    FaceState.holding => scheme.primary,
    FaceState.signedIn => scheme.tertiary,
    FaceState.unknown => _faces.unknownInARow >= 3 ? scheme.error : scheme.outline,
    _ => scheme.outline,
  };

  Future<void> _submit() async {
    if (_pin.length < 4 || _busy) return;
    if (_clocking) return _submitClock();
    setState(() => _busy = true);
    final message = await widget.session.signInWithPin(widget.settings.device, _pin);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _message = message;
      _pin = '';
    });
    if (message != null) _shake.forward(from: 0);
  }

  /// The PIN was for the time clock: the hub says who it is and where they stand, and their card takes the
  /// pad's place. Nobody is signed in by it.
  Future<void> _submitClock() async {
    final pin = _pin;
    setState(() => _busy = true);
    ClockStand? stand;
    String? message;
    var off = false;
    try {
      stand = await widget.session.api.clockPunch(device: widget.settings.device, pin: pin);
    } on ApiException catch (err) {
      message = clockPinRefusal(err);
      off = err.status == 409 && err.message == 'off';
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _message = message;
      _pin = '';
      if (stand != null) _atClock = (pin, stand);
      if (off) _clocking = false;
    });
    if (message != null) unawaited(_shake.forward(from: 0));
    if (off) unawaited(_readClock());
  }

  /// The card is done with: the pad signs in again. With [staff], the person asked to go on to the orders,
  /// and the hub's answer to their PIN at the clock is their sign-in.
  void _leaveClock(Map<String, dynamic>? staff) {
    setState(() {
      _atClock = null;
      _clocking = false;
      _message = null;
      _pin = '';
    });
    if (staff != null) widget.session.applySignIn(staff);
  }

  void _toggleClock() => setState(() {
    _clocking = !_clocking;
    _atClock = null;
    _message = null;
    _pin = '';
  });

  void _tap(String key) {
    setState(() {
      _message = null;
      if (key == 'C') {
        _pin = '';
      } else if (key == '⌫') {
        if (_pin.isNotEmpty) _pin = _pin.substring(0, _pin.length - 1);
      } else if (_pin.length < 6) {
        _pin += key;
      }
    });
    if (_pin.length == 4) _submit();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final clockOn = _clock?.enabled ?? false;
    final atClock = _atClock;
    final heading = _clocking || atClock != null
        ? 'Time clock'
        : widget.lockedNote == null
        ? 'Sign in'
        : 'Locked';
    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(color: scheme.primaryContainer, borderRadius: BorderRadius.circular(8)),
              child: Icon(Icons.restaurant_rounded, size: 18, color: scheme.onPrimaryContainer),
            ),
            const SizedBox(width: 10),
            Flexible(child: Text('$heading · ${widget.settings.device}')),
          ],
        ),
        actions: [
          // The way to the time clock and back, where the location uses it. A phone keeps only the icon.
          if (clockOn && compact(context))
            // (no tooltip: over a locked screen the pad has no overlay for one to open in)
            IconButton(
              key: const ValueKey('time-clock'),
              icon: Icon(
                _clocking ? Icons.dialpad : Icons.punch_clock_outlined,
                semanticLabel: _clocking ? 'Back to sign in' : 'Time clock',
              ),
              onPressed: _busy ? null : _toggleClock,
            )
          else if (clockOn)
            TextButton.icon(
              key: const ValueKey('time-clock'),
              icon: Icon(_clocking ? Icons.dialpad : Icons.punch_clock_outlined),
              label: Text(_clocking ? 'Back to sign in' : 'Time clock'),
              onPressed: _busy ? null : _toggleClock,
            ),
          if (widget.onSettings != null)
            IconButton(tooltip: 'Settings', icon: const Icon(Icons.settings_outlined), onPressed: widget.onSettings),
        ],
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 680),
            padding: const EdgeInsets.all(28),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLowest,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: scheme.outlineVariant),
              boxShadow: [
                BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 24, offset: const Offset(0, 8)),
              ],
            ),
            child: atClock != null
                ? ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 340),
                    child: TimeClockCard(
                      key: const ValueKey('clock-card'),
                      api: widget.session.api,
                      device: widget.settings.device,
                      pin: atClock.$1,
                      stand: atClock.$2,
                      offerOrders: true,
                      onClose: _leaveClock,
                    ),
                  )
                : _withNote(
                    theme,
                    Wrap(
                      alignment: WrapAlignment.center,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 40,
                      runSpacing: 28,
                      children: [
                        Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 280,
                              height: 210,
                              decoration: BoxDecoration(
                                color: scheme.surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(color: scheme.outlineVariant, width: 1.5),
                              ),
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  ClipRRect(borderRadius: BorderRadius.circular(14.5), child: widget.camera.preview()),
                                  if (_faces.state != FaceState.off) FaceGuide(color: _guideColor(scheme)),
                                  Positioned(
                                    left: 10,
                                    bottom: 10,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                      decoration: BoxDecoration(
                                        color: Colors.black.withValues(alpha: 0.55),
                                        borderRadius: BorderRadius.circular(20),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Container(
                                            width: 7,
                                            height: 7,
                                            decoration: BoxDecoration(
                                              color: widget.camera.ready ? Colors.greenAccent : Colors.orangeAccent,
                                              shape: BoxShape.circle,
                                            ),
                                          ),
                                          const SizedBox(width: 6),
                                          Text(
                                            widget.settings.device,
                                            style: theme.textTheme.labelSmall?.copyWith(color: Colors.white),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 12),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (_faces.state != FaceState.off) ...[
                                  Icon(
                                    _faces.state == FaceState.signedIn ? Icons.check_circle : Icons.face_outlined,
                                    size: 16,
                                    color: _faces.state == FaceState.signedIn
                                        ? scheme.tertiary
                                        : scheme.onSurfaceVariant,
                                  ),
                                  const SizedBox(width: 6),
                                ],
                                // (it wraps on a narrow phone rather than run off the card)
                                Flexible(
                                  child: Text(
                                    _clocking
                                        ? 'Tap your PIN for the time clock'
                                        : _faces.notice ??
                                              (_faces.state == FaceState.off
                                                  ? 'Tap your 4-digit staff PIN to unlock'
                                                  : _faces.message ?? 'Look at the camera, or tap your PIN'),
                                    key: const ValueKey('sign-in-hint'),
                                    textAlign: TextAlign.center,
                                    style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                        SizedBox(
                          width: 268,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              AnimatedBuilder(
                                animation: _shake,
                                builder: (context, child) {
                                  final t = _shake.value;
                                  final dx = math.sin(t * math.pi * 4) * (1 - t) * 10;
                                  return Transform.translate(offset: Offset(dx, 0), child: child);
                                },
                                child: Column(
                                  children: [
                                    Text(
                                      _pin.isEmpty ? 'Enter your PIN' : '●' * _pin.length,
                                      style: theme.textTheme.titleMedium?.copyWith(
                                        color: _pin.isEmpty ? scheme.onSurface : Colors.transparent,
                                        height: _pin.isEmpty ? null : 0.01,
                                        fontSize: _pin.isEmpty ? null : 1,
                                      ),
                                    ),
                                    const SizedBox(height: 10),
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        for (var i = 0; i < 4; i++)
                                          AnimatedContainer(
                                            duration: const Duration(milliseconds: 160),
                                            curve: Curves.easeOutBack,
                                            margin: const EdgeInsets.symmetric(horizontal: 7),
                                            width: i < _pin.length ? 16 : 13,
                                            height: i < _pin.length ? 16 : 13,
                                            decoration: BoxDecoration(
                                              color: i < _pin.length
                                                  ? scheme.primary
                                                  : (_message != null
                                                        ? scheme.errorContainer
                                                        : scheme.surfaceContainerHighest),
                                              shape: BoxShape.circle,
                                              border: Border.all(
                                                color: i < _pin.length
                                                    ? scheme.primary
                                                    : (_message != null ? scheme.error : scheme.outlineVariant),
                                                width: 1.5,
                                              ),
                                            ),
                                          ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 10),
                              SizedBox(
                                height: 28,
                                child: AnimatedSwitcher(
                                  duration: const Duration(milliseconds: 180),
                                  child: _busy
                                      ? SizedBox(
                                          key: const ValueKey('busy'),
                                          width: 18,
                                          height: 18,
                                          child: CircularProgressIndicator(strokeWidth: 2.2, color: scheme.primary),
                                        )
                                      : Text(
                                          _message ?? '',
                                          key: ValueKey(_message ?? ''),
                                          style: theme.textTheme.labelMedium?.copyWith(
                                            color: scheme.error,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                ),
                              ),
                              const SizedBox(height: 6),
                              for (final row in const [
                                ['1', '2', '3'],
                                ['4', '5', '6'],
                                ['7', '8', '9'],
                                ['C', '0', '⌫'],
                              ])
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    for (final key in row)
                                      Padding(
                                        padding: const EdgeInsets.all(5),
                                        child: PressableScale(
                                          enabled: !_busy,
                                          pressedScale: 0.92,
                                          child: SizedBox(
                                            width: 76,
                                            height: 62,
                                            child: key == 'C' || key == '⌫'
                                                ? OutlinedButton(
                                                    style: OutlinedButton.styleFrom(
                                                      padding: EdgeInsets.zero,
                                                      backgroundColor: scheme.surfaceContainerLow,
                                                      foregroundColor: key == 'C'
                                                          ? scheme.error
                                                          : scheme.onSurfaceVariant,
                                                      shape: RoundedRectangleBorder(
                                                        borderRadius: BorderRadius.circular(14),
                                                      ),
                                                    ),
                                                    onPressed: _busy ? null : () => _tap(key),
                                                    child: Text(
                                                      key,
                                                      style: theme.textTheme.titleMedium?.copyWith(
                                                        fontWeight: FontWeight.w700,
                                                        color: key == 'C' ? scheme.error : scheme.onSurfaceVariant,
                                                      ),
                                                    ),
                                                  )
                                                : FilledButton.tonal(
                                                    style: FilledButton.styleFrom(
                                                      padding: EdgeInsets.zero,
                                                      backgroundColor: scheme.surfaceContainer,
                                                      foregroundColor: scheme.onSurface,
                                                      shape: RoundedRectangleBorder(
                                                        borderRadius: BorderRadius.circular(14),
                                                      ),
                                                    ),
                                                    onPressed: _busy ? null : () => _tap(key),
                                                    child: Text(
                                                      key,
                                                      style: theme.textTheme.titleLarge?.copyWith(
                                                        fontWeight: FontWeight.w700,
                                                        fontFeatures: PosTheme.tabular,
                                                      ),
                                                    ),
                                                  ),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
        ),
      ),
    );
  }

  /// The pad with a note above it: that the PIN is for the time clock, while it is, or the lock's note on a
  /// locked screen. The pad alone otherwise.
  Widget _withNote(ThemeData theme, Widget pad) {
    final note = _clocking
        ? 'Time clock: your PIN shows your hours, where you clock in or out and start or end a break. '
              'It does not sign you in.'
        : widget.lockedNote;
    if (note == null) return pad;
    final scheme = theme.colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          key: ValueKey(_clocking ? 'clock-note' : 'locked-note'),
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(color: scheme.secondaryContainer, borderRadius: BorderRadius.circular(12)),
          child: Row(
            children: [
              Icon(
                _clocking ? Icons.punch_clock_outlined : Icons.lock_outline,
                size: 16,
                color: scheme.onSecondaryContainer,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(note, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSecondaryContainer)),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        pad,
      ],
    );
  }
}
