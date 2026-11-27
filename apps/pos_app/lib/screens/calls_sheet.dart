import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../call_player.dart';
import '../calls.dart';
import '../customers.dart' show dayLabel;
import '../live.dart';
import '../takeout.dart' show clockTime;
import 'menu_editor.dart' show ManagerPinDialog;
import 'theme.dart';

/// The session somebody opened to listen to an order's calls, kept by the order's screen while it is open:
/// the second call, and the sheet opened again, do not ask for the PIN again.
class CallsAccess {
  String? token;
}

/// Opens the recorded calls of an order (docs/call-recordings.md): who called whom, when and for how long,
/// each with a button that plays it. Listening takes the PIN of somebody who may (a manager's to start; the
/// location hands it out under "Who may do what").
Future<void> showCalls(
  BuildContext context, {
  required PosApi api,
  required String orderId,
  required OrderCalls calls,
  required CallsAccess access,
  CallPlayer Function()? player,
  DateTime Function()? now,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true, // as tall as its calls, on a phone held sideways too
  constraints: const BoxConstraints(maxWidth: 560),
  builder: (_) => CallsSheet(api: api, orderId: orderId, calls: calls, access: access, player: player, now: now),
);

/// The line on an order that says it has recorded calls; a tap opens them. Only there when there are any, so
/// an order with none gives no room to it.
class CallsStrip extends StatelessWidget {
  const CallsStrip({super.key, required this.calls, required this.onTap});

  final OrderCalls calls;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final style = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurface, fontWeight: FontWeight.w600);
    return Material(
      key: const ValueKey('calls-strip'),
      color: scheme.surfaceContainerHighest, // plain, like the customer's line: red is the allergy strip's
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Row(
            children: [
              Icon(Icons.graphic_eq, size: 16, color: scheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Expanded(
                child: Text(callsCount(calls.calls.length), maxLines: 1, overflow: TextOverflow.ellipsis, style: style),
              ),
              Text('Listen', style: style?.copyWith(color: scheme.primary)),
              Icon(Icons.chevron_right, size: 16, color: scheme.primary),
            ],
          ),
        ),
      ),
    );
  }
}

class CallsSheet extends StatefulWidget {
  const CallsSheet({
    super.key,
    required this.api,
    required this.orderId,
    required this.calls,
    required this.access,
    this.player,
    this.now,
  });

  final PosApi api;
  final String orderId;

  /// The calls as the order's screen last read them; the sheet reads them again when the hub says so.
  final OrderCalls calls;
  final CallsAccess access;

  /// What plays a call: the device's speaker, unless a test stands in for it.
  final CallPlayer Function()? player;
  final DateTime Function()? now;

  @override
  State<CallsSheet> createState() => _CallsSheetState();
}

class _CallsSheetState extends State<CallsSheet> {
  late OrderCalls _calls = widget.calls;
  CallPlayer? _player;
  StreamSubscription<LiveChange>? _live;
  String? _current; // the call the player holds
  String? _loading; // the call being fetched
  String? _message; // why the last press played nothing

  @override
  void initState() {
    super.initState();
    _live = widget.api.live.changes.listen((change) {
      if (change.calls || change.everything) unawaited(_read());
    });
  }

  @override
  void dispose() {
    unawaited(_live?.cancel());
    unawaited(_player?.close());
    super.dispose();
  }

  Future<void> _read() async {
    final calls = await widget.api.orderCalls(widget.orderId);
    if (!mounted || calls == null || calls == _calls) return;
    setState(() => _calls = calls);
  }

  /// The session to listen with: the one this order's screen already has, or a PIN now.
  Future<String?> _token() async {
    final have = widget.access.token;
    if (have != null) return have;
    final token = await showDialog<String>(
      context: context,
      builder: (_) => ManagerPinDialog(
        api: widget.api,
        device: widget.api.settings.device,
        action: 'Listen',
        what: 'listen to recorded calls',
        power: 'calls',
      ),
    );
    widget.access.token = token;
    return token;
  }

  Future<void> _press(RecordedCall call) async {
    if (_loading != null) return;
    final player = _player ??= (widget.player ?? DeviceCallPlayer.new)();
    if (_current == call.id) {
      player.playback.value.playing ? await player.pause() : await player.resume();
      return;
    }
    if (_message != null) setState(() => _message = null);
    String? message;
    for (var tries = 0; tries < 2; tries++) {
      final token = await _token();
      if (token == null || !mounted) return; // the PIN box was closed: nothing plays
      setState(() => _loading = call.id);
      try {
        final mp3 = await widget.api.callAudio(token, widget.orderId, call.id);
        if (!mounted) return;
        await player.play(mp3);
        if (!mounted) return;
        _current = call.id;
        break;
      } on ApiException catch (err) {
        if (!mounted) return;
        if (err.status == 401 && tries == 0) {
          widget.access.token = null; // the hour of that session is over: the PIN again
          setState(() => _loading = null);
          continue;
        }
        message = switch (err.status) {
          401 || 403 => 'Only ${widget.api.powers.value.whose('calls')} can listen to recorded calls.',
          404 when err.detail?['error'] == 'gone' => 'The phone server no longer has that recording.',
          404 => 'That call is not on this order any more.',
          424 => 'The phone server did not answer. Try again in a moment.',
          null => 'The hub is not answering.',
          _ => (err.detail?['message'] as String?) ?? err.message,
        };
        if (err.status == 403) widget.access.token = null;
        if (err.status == 404) unawaited(_read());
        break;
      } on Object {
        if (!mounted) return;
        message = 'This device could not play the recording.';
        break;
      }
    }
    setState(() {
      _loading = null;
      _message = message;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final now = (widget.now ?? DateTime.now)();
    final calls = _calls.calls;
    final small = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
          child: Column(
            key: const ValueKey('calls-sheet'),
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(child: Text('Recorded calls', style: theme.textTheme.titleLarge)),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              if (calls.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text('No recorded calls with this number.', style: theme.textTheme.bodyMedium),
                ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.only(right: 8),
                  children: [
                    for (final call in calls)
                      _CallRow(
                        key: ValueKey('call-${call.id}'),
                        call: call,
                        now: now,
                        loading: _loading == call.id,
                        player: _current == call.id ? _player : null,
                        onPress: () => unawaited(_press(call)),
                      ),
                  ],
                ),
              ),
              if (_message != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8, right: 8),
                  child: Text(
                    _message!,
                    key: const ValueKey('calls-message'),
                    style: theme.textTheme.bodyMedium?.copyWith(color: scheme.error),
                  ),
                ),
              if (calls.any((call) => call.stereo))
                Padding(
                  padding: const EdgeInsets.only(top: 8, right: 8),
                  child: Text('Stereo: the customer is on the left, the restaurant on the right.', style: small),
                ),
              if (_calls.problem != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8, right: 8),
                  child: Text(
                    'The phone server did not answer the hub just now: a call of the last few minutes may be missing.',
                    key: const ValueKey('calls-behind'),
                    style: small,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One call: its button, when it was and who called, how long it runs, and under it, while it is the one in
/// the player, where the playing stands.
class _CallRow extends StatelessWidget {
  const _CallRow({
    super.key,
    required this.call,
    required this.now,
    required this.loading,
    required this.player,
    required this.onPress,
  });

  final RecordedCall call;
  final DateTime now;
  final bool loading;

  /// The player, while this call is the one it holds.
  final CallPlayer? player;
  final VoidCallback onPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final day = dayLabel(call.startedMs, now);
    final when = day == 'today' ? clockTime(call.startedMs) : '$day ${clockTime(call.startedMs)}';
    final seconds = call.seconds;
    final under = [
      if (seconds != null) callLength(Duration(seconds: seconds)),
      if (call.opened) 'the order was opened on this call',
      if (call.stereo) 'stereo',
    ].join(' · ');
    final player = this.player;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              SizedBox.square(
                dimension: 48,
                child: loading
                    ? const Padding(padding: EdgeInsets.all(14), child: CircularProgressIndicator(strokeWidth: 2.5))
                    : player == null
                    ? _PlayButton(id: call.id, playing: false, onPress: onPress)
                    : ValueListenableBuilder<CallPlayback>(
                        valueListenable: player.playback,
                        builder: (_, playback, _) =>
                            _PlayButton(id: call.id, playing: playback.playing, onPress: onPress),
                      ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '$when · ${call.who}',
                      style: theme.textTheme.titleSmall?.copyWith(fontFeatures: PosTheme.tabular),
                    ),
                    if (under.isNotEmpty)
                      Text(
                        under,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          fontFeatures: PosTheme.tabular,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          if (player != null)
            _Scrubber(
              player: player,
              known: seconds == null ? null : Duration(seconds: seconds),
            ),
        ],
      ),
    );
  }
}

class _PlayButton extends StatelessWidget {
  const _PlayButton({required this.id, required this.playing, required this.onPress});

  final String id;
  final bool playing;
  final VoidCallback onPress;

  @override
  Widget build(BuildContext context) => IconButton.filledTonal(
    key: ValueKey('call-play-$id'),
    tooltip: playing ? 'Pause' : 'Play',
    onPressed: onPress,
    icon: Icon(playing ? Icons.pause : Icons.play_arrow),
  );
}

/// Where the playing stands, as a bar that can be dragged, with the time in and the whole length.
class _Scrubber extends StatefulWidget {
  const _Scrubber({required this.player, required this.known});

  final CallPlayer player;

  /// The length the hub said, until the player has read its own.
  final Duration? known;

  @override
  State<_Scrubber> createState() => _ScrubberState();
}

class _ScrubberState extends State<_Scrubber> {
  double? _drag; // where the thumb is held, in milliseconds, while a finger is on it

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      fontFeatures: PosTheme.tabular,
    );
    return ValueListenableBuilder<CallPlayback>(
      valueListenable: widget.player.playback,
      builder: (context, playback, _) {
        final length = playback.length ?? widget.known ?? Duration.zero;
        final most = length.inMilliseconds <= 0 ? 1.0 : length.inMilliseconds.toDouble();
        final at = (_drag ?? playback.position.inMilliseconds.toDouble()).clamp(0.0, most);
        return Row(
          children: [
            Text(
              callLength(Duration(milliseconds: at.round())),
              key: const ValueKey('call-at'),
              style: style,
            ),
            Expanded(
              child: Slider(
                key: const ValueKey('call-seek'),
                value: at,
                max: most,
                onChanged: (to) => setState(() => _drag = to),
                onChangeEnd: (to) {
                  setState(() => _drag = null);
                  unawaited(widget.player.seek(Duration(milliseconds: to.round())));
                },
              ),
            ),
            Text(callLength(length), key: const ValueKey('call-length'), style: style),
          ],
        );
      },
    );
  }
}
