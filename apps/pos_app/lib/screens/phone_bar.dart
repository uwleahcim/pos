import 'dart:async';

import 'package:flutter/material.dart';

import '../phone.dart';
import 'guest_tag_mark.dart';

/// How far from the top of the screen (under the status bar) a form that opens during a call starts, so
/// that its title is not behind the call strip.
const callStripRoom = 64.0;

/// Sits over every screen. While a call rings: a banner with the caller, the tags the restaurant keeps on
/// that number ("VIP", where somebody is signed in to see them), Answer and Decline. During a call:
/// a small strip at the top with the caller, the call time, Hold, Hang up, More and, with [onOrder], To go: a
/// to-go order for the caller. More opens a panel under the strip with the keypad (tones to the other side, or
/// the extension to transfer to) and Mute. Otherwise nothing. The ring itself is the [CallRinger]'s, wired
/// beside the phone in main.dart.
class PhoneBar extends StatefulWidget {
  const PhoneBar({super.key, required this.client, required this.child, this.onOrder, this.tagsOf});

  final PhoneClient client;
  final Widget child;

  /// The tags a manager put on a number in the guest list (docs/guest-list.md, "Where the tags show"),
  /// asked once for each call that rings and shown on its banner, so whoever picks up knows who it is.
  /// Null where nobody is signed in: a screen at its sign-in pad or locked shows the number and no more.
  final Future<List<String>> Function(String number)? tagsOf;

  /// To go on the call strip: starts a to-go order for the caller on the orders screen. Null hides the button
  /// (nobody signed in, so no screen to take the order).
  final VoidCallback? onOrder;

  @override
  State<PhoneBar> createState() => _PhoneBarState();
}

class _PhoneBarState extends State<PhoneBar> {
  Timer? _tick;
  bool _more = false; // the keypad panel is open

  /// The number that rings and whose tags were asked for, and what came back for it: one question a call.
  String? _asked;
  List<String> _tags = const [];

  @override
  void initState() {
    super.initState();
    widget.client.addListener(_onPhone);
    _askTags();
  }

  @override
  void didUpdateWidget(PhoneBar old) {
    super.didUpdateWidget(old);
    // Somebody signed in or out while it rings: the tags are for a person signed in, so ask now, or put
    // them away.
    if ((old.tagsOf == null) != (widget.tagsOf == null)) {
      _asked = null;
      _tags = const [];
      _askTags();
    }
  }

  /// Asks for the tags of the number that rings, once: the answer is shown when it comes, unless the call
  /// is another one by then. Nothing is asked where [PhoneBar.tagsOf] is null, and for a call with no
  /// number.
  void _askTags() {
    final client = widget.client;
    final number = client.state == PhoneState.ringing ? (client.callerNumber?.trim() ?? '') : '';
    final ask = widget.tagsOf;
    if (number.isEmpty || ask == null) {
      _asked = null;
      _tags = const [];
      return;
    }
    if (number == _asked) return;
    _asked = number;
    _tags = const [];
    unawaited(
      ask(number).then(
        (tags) {
          if (mounted && _asked == number && tags.isNotEmpty) setState(() => _tags = tags);
        },
        onError: (Object _) {}, // no answer: the banner is the number, as before
      ),
    );
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
      _more = false; // the panel goes with the call
    }
    _askTags();
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
            child: SafeArea(
              bottom: false,
              child: _RingingBanner(client: client, tags: _tags),
            ),
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
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _CallStrip(
                      client: client,
                      onOrder: widget.onOrder,
                      more: _more,
                      onMore: () => setState(() => _more = !_more),
                    ),
                    if (_more)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: _MorePanel(client: client),
                      ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _RingingBanner extends StatelessWidget {
  const _RingingBanner({required this.client, this.tags = const []});

  final PhoneClient client;

  /// The tags on the caller's number, under it.
  final List<String> tags;

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
                // Flexible, so that a line of tags wraps inside the banner on a narrow phone.
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        formatPhoneNumber(client.callerNumber),
                        style: theme.textTheme.titleMedium?.copyWith(color: scheme.onInverseSurface),
                      ),
                      if (name.isNotEmpty)
                        Text(name, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onInverseSurface)),
                      if (tags.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Wrap(
                            key: const ValueKey('ringing-tags'),
                            spacing: 6,
                            runSpacing: 4,
                            children: [for (final tag in tags) GuestTagMark(tag, key: ValueKey('ringing-tag:$tag'))],
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            // A Wrap, so that on a narrow phone with large type Decline goes under Answer and not off the
            // screen.
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: waiting ? null : client.answer,
                  style: FilledButton.styleFrom(backgroundColor: Colors.green.shade700, foregroundColor: Colors.white),
                  icon: const Icon(Icons.call),
                  label: Text(waiting ? 'Answering…' : 'Answer'),
                ),
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
  const _CallStrip({required this.client, this.onOrder, required this.more, required this.onMore});

  final PhoneClient client;
  final VoidCallback? onOrder;
  final bool more;
  final VoidCallback onMore;

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
              Text(
                client.held ? 'On hold' : _clock(client.callDuration),
                style: theme.textTheme.bodySmall?.copyWith(color: client.held ? scheme.inversePrimary : onDark),
              ),
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
                onPressed: client.toggleHold,
                color: client.held ? scheme.inversePrimary : onDark,
                icon: Icon(
                  client.held ? Icons.play_arrow : Icons.pause,
                  semanticLabel: client.held ? 'Resume' : 'Hold',
                ),
              ),
              IconButton(
                onPressed: client.hangUp,
                color: Colors.red.shade300,
                icon: const Icon(Icons.call_end, semanticLabel: 'Hang up'),
              ),
              IconButton(
                onPressed: onMore,
                color: more ? scheme.inversePrimary : onDark,
                icon: const Icon(Icons.more_horiz, semanticLabel: 'More'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Under the strip: the keypad, what it typed, and what to do with it (play it to the other side as tones, or
/// transfer the call to that extension), plus Mute. Everything here works above the navigator too: no
/// tooltips, no text fields (their selection handles need an overlay), only buttons.
class _MorePanel extends StatelessWidget {
  const _MorePanel({required this.client});

  final PhoneClient client;

  static const _keys = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '*', '0', '#'];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final typed = client.typed;
    return Material(
      elevation: 4,
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 12, 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 3 * 52,
              child: Wrap(
                children: [
                  for (final key in _keys)
                    SizedBox(
                      width: 52,
                      height: 44,
                      child: TextButton(
                        key: ValueKey('key:$key'),
                        onPressed: () => client.type(key),
                        style: TextButton.styleFrom(foregroundColor: scheme.onSurface),
                        child: Text(key, style: theme.textTheme.titleMedium),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 164,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          typed.isEmpty ? 'Type a number' : typed,
                          overflow: TextOverflow.ellipsis,
                          style: typed.isEmpty
                              ? theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)
                              : theme.textTheme.titleMedium?.copyWith(letterSpacing: 1.5),
                        ),
                      ),
                      IconButton(
                        onPressed: typed.isEmpty ? null : client.backspace,
                        icon: const Icon(Icons.backspace_outlined, semanticLabel: 'Backspace'),
                      ),
                    ],
                  ),
                  FilledButton(onPressed: typed.isEmpty ? null : client.transfer, child: const Text('Transfer')),
                  const SizedBox(height: 6),
                  OutlinedButton(onPressed: typed.isEmpty ? null : client.sendTones, child: const Text('Send tones')),
                  const SizedBox(height: 6),
                  TextButton.icon(
                    onPressed: client.toggleMute,
                    icon: Icon(client.muted ? Icons.mic_off : Icons.mic),
                    label: Text(client.muted ? 'Unmute' : 'Mute'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
