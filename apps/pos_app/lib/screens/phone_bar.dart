import 'dart:async';

import 'package:flutter/material.dart';

import '../phone.dart';

/// Sits over every screen. While a call rings: a banner with the caller, Answer and Decline. During a call:
/// a small strip at the top with the caller, the call time, mute, hang up and, with [onOrder], To go: a to-go
/// order for the caller. Otherwise nothing. The ring itself is the [CallRinger]'s, wired beside the phone in
/// main.dart.
class PhoneBar extends StatefulWidget {
  const PhoneBar({super.key, required this.client, required this.child, this.onOrder});

  final PhoneClient client;
  final Widget child;

  /// To go on the call strip: starts a to-go order for the caller on the orders screen. Null hides the button
  /// (nobody signed in, so no screen to take the order).
  final VoidCallback? onOrder;

  @override
  State<PhoneBar> createState() => _PhoneBarState();
}

class _PhoneBarState extends State<PhoneBar> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    widget.client.addListener(_onPhone);
  }

  @override
  void dispose() {
    widget.client.removeListener(_onPhone);
    _tick?.cancel();
    super.dispose();
  }

  void _onPhone() {
    if (widget.client.onCall) {
      _tick ??= Timer.periodic(const Duration(seconds: 1), (_) => _onTick());
    } else {
      _tick?.cancel();
      _tick = null;
    }
    if (mounted) setState(() {});
  }

  void _onTick() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final client = widget.client;
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        if (client.state == PhoneState.ringing)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(bottom: false, child: _RingingBanner(client: client)),
          )
        else if (client.state == PhoneState.inCall)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: Align(
                alignment: Alignment.topCenter,
                child: _CallStrip(client: client, onOrder: widget.onOrder),
              ),
            ),
          ),
      ],
    );
  }
}

class _RingingBanner extends StatelessWidget {
  const _RingingBanner({required this.client});

  final PhoneClient client;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final name = client.callerName?.trim() ?? '';
    // Once Answer is tapped the buttons wait for the PBX, so a second tap (or a Decline on top) does nothing.
    final waiting = client.answering;
    return Material(
      elevation: 6,
      color: scheme.inverseSurface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        child: Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 16,
          runSpacing: 8,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.ring_volume, color: scheme.inversePrimary),
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      formatPhoneNumber(client.callerNumber),
                      style: theme.textTheme.titleMedium?.copyWith(color: scheme.onInverseSurface),
                    ),
                    if (name.isNotEmpty)
                      Text(name, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onInverseSurface)),
                  ],
                ),
              ],
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                FilledButton.icon(
                  onPressed: waiting ? null : client.answer,
                  style: FilledButton.styleFrom(backgroundColor: Colors.green.shade700, foregroundColor: Colors.white),
                  icon: const Icon(Icons.call),
                  label: Text(waiting ? 'Answering…' : 'Answer'),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: waiting ? null : client.decline,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: scheme.onInverseSurface,
                    side: BorderSide(color: scheme.onInverseSurface.withValues(alpha: 0.5)),
                  ),
                  icon: const Icon(Icons.call_end),
                  label: const Text('Decline'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _CallStrip extends StatelessWidget {
  const _CallStrip({required this.client, this.onOrder});

  final PhoneClient client;
  final VoidCallback? onOrder;

  static String _clock(Duration? d) {
    if (d == null) return '0:00';
    final s = d.inSeconds;
    final mm = (s ~/ 60) % 60;
    final ss = (s % 60).toString().padLeft(2, '0');
    if (s >= 3600) return '${s ~/ 3600}:${mm.toString().padLeft(2, '0')}:$ss';
    return '$mm:$ss';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final onDark = scheme.onInverseSurface;
    return Material(
      elevation: 4,
      color: scheme.inverseSurface,
      shape: const StadiumBorder(),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 2, 4, 2),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.phone_in_talk, size: 18, color: scheme.inversePrimary),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  formatPhoneNumber(client.callerNumber),
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(color: onDark),
                ),
              ),
              const SizedBox(width: 8),
              Text(_clock(client.callDuration), style: theme.textTheme.bodySmall?.copyWith(color: onDark)),
              const SizedBox(width: 4),
              // No tooltips: the strip sits above the navigator (MaterialApp.builder), where a tooltip finds no
              // overlay to open in, which is a red box in a debug build and an exception on hover in a release.
              if (onOrder != null)
                IconButton(
                  onPressed: onOrder,
                  color: onDark,
                  icon: const Icon(Icons.shopping_bag_outlined, semanticLabel: 'To go'),
                ),
              IconButton(
                onPressed: client.toggleMute,
                color: client.muted ? scheme.inversePrimary : onDark,
                icon: Icon(client.muted ? Icons.mic_off : Icons.mic, semanticLabel: client.muted ? 'Unmute' : 'Mute'),
              ),
              IconButton(
                onPressed: client.hangUp,
                color: Colors.red.shade300,
                icon: const Icon(Icons.call_end, semanticLabel: 'Hang up'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
