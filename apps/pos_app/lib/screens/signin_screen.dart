import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../camera.dart';
import '../face_signin.dart';
import '../session.dart';
import '../settings.dart';
import 'face_guide.dart';
import 'theme.dart';

/// PIN pad with the camera preview beside it. While the location signs staff in by face, the preview looks
/// for an enrolled face (the hub recognises it) and the pad works all the same; a tag held to the terminal's
/// reader signs in too. The looking itself runs for as long as the app does ([FaceSignIn]); this screen shows
/// what it says.
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

  @override
  void initState() {
    super.initState();
    _faces.addListener(_changed);
    // A phone's camera comes up after the first build: the ready dot (and the preview) follow it.
    widget.camera.addListener(_changed);
    if (widget.camera is! NoCamera) _faces.start();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
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
            Flexible(child: Text('${widget.lockedNote == null ? 'Sign in' : 'Locked'} · ${widget.settings.device}')),
          ],
        ),
        actions: [
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
            child: _withNote(
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
                              color: _faces.state == FaceState.signedIn ? scheme.tertiary : scheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 6),
                          ],
                          Text(
                            _faces.notice ??
                                (_faces.state == FaceState.off
                                    ? 'Tap your 4-digit staff PIN to unlock'
                                    : _faces.message ?? 'Look at the camera, or tap your PIN'),
                            key: const ValueKey('sign-in-hint'),
                            style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
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
                                                foregroundColor: key == 'C' ? scheme.error : scheme.onSurfaceVariant,
                                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
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
                                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
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

  /// The pad with the lock's note above it, on a locked screen; the pad alone otherwise.
  Widget _withNote(ThemeData theme, Widget pad) {
    final note = widget.lockedNote;
    if (note == null) return pad;
    final scheme = theme.colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          key: const ValueKey('locked-note'),
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(color: scheme.secondaryContainer, borderRadius: BorderRadius.circular(12)),
          child: Row(
            children: [
              Icon(Icons.lock_outline, size: 16, color: scheme.onSecondaryContainer),
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
