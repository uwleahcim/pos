import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../api.dart';
import '../check_history.dart';
import 'theme.dart';

/// A check's whole history, for a manager (docs/check-history.md): every step the hub keeps of it, oldest
/// first, each with when it happened, who did it and at which screen, the manager who approved it where one
/// was asked, and the picture taken with it while the hub still has one. A dish that came from or went to
/// another check opens that check's history on a tap. Nothing here changes the check. One column, so it
/// reads the same on a phone.
class CheckHistoryScreen extends StatefulWidget {
  const CheckHistoryScreen({super.key, required this.api, required this.token, required this.orderId});

  final PosApi api;

  /// The manager's session (`POST /admin/session`): the history is read with it.
  final String token;
  final String orderId;

  @override
  State<CheckHistoryScreen> createState() => _CheckHistoryScreenState();
}

class _CheckHistoryScreenState extends State<CheckHistoryScreen> {
  CheckHistory? _history;
  String? _error;
  int _asked = 0;

  /// Each picture is asked for once, however often its row is built.
  final _photos = <String, Future<Uint8List?>>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final ask = ++_asked;
    setState(() => _error = null);
    try {
      final history = await widget.api.checkHistory(widget.token, widget.orderId);
      if (mounted && ask == _asked) setState(() => _history = history);
    } on ApiException catch (err) {
      if (!mounted || ask != _asked) return;
      setState(
        () => _error = switch (err.status) {
          401 || 403 => "The manager's hour here is over: go back and ask for the history again.",
          404 when err.detail?['error'] == 'unknown_id' =>
            'The hub has not heard of this check yet. If it was only just rung in, wait until it is sent.',
          404 => 'This hub is older than the check history. Update the hub to see it here.',
          null => 'The hub is not answering',
          _ => (err.detail?['message'] as String?) ?? err.message,
        },
      );
    }
  }

  Future<Uint8List?> _photo(String id) => _photos.putIfAbsent(id, () => widget.api.eventPhoto(id));

  String _time(int ms) => TimeOfDay.fromDateTime(DateTime.fromMillisecondsSinceEpoch(ms)).format(context);

  /// A time of day; with the day in front when it is not the day of [beside] (an order rung for tomorrow).
  String _timeBeside(int ms, int beside) {
    final at = DateTime.fromMillisecondsSinceEpoch(ms), other = DateTime.fromMillisecondsSinceEpoch(beside);
    final sameDay = at.year == other.year && at.month == other.month && at.day == other.day;
    return sameDay ? _time(ms) : '${MaterialLocalizations.of(context).formatShortMonthDay(at)}, ${_time(ms)}';
  }

  void _open(String orderId) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => CheckHistoryScreen(api: widget.api, token: widget.token, orderId: orderId),
    ),
  );

  Future<void> _enlarge(HistoryStep step, Uint8List bytes, StepWords words) => showDialog<void>(
    context: context,
    builder: (context) => Dialog(
      key: const ValueKey('history-picture'),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Flexible(
              child: Image.memory(bytes, fit: BoxFit.contain, errorBuilder: (_, _, _) => const SizedBox(height: 120)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(words.title, style: Theme.of(context).textTheme.titleMedium),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text([_time(step.atMs), whoLine(step)].where((part) => part.isNotEmpty).join(' · ')),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close')),
              ),
            ),
          ],
        ),
      ),
    ),
  );

  List<Widget> _body(BuildContext context, CheckHistory history) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final small = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final local = MaterialLocalizations.of(context);
    final order = history.order;
    final opened = order.openedMs;
    final guests = order.guests;
    final count = history.steps.length;
    DateTime? day;
    final rows = <Widget>[];
    for (final (i, step) in history.steps.indexed) {
      final at = DateTime.fromMillisecondsSinceEpoch(step.atMs);
      final its = DateTime(at.year, at.month, at.day);
      if (its != day) {
        day = its;
        rows.add(
          Padding(
            key: ValueKey('history-day:${isoDay(its)}'),
            padding: EdgeInsets.only(top: rows.isEmpty ? 2 : 14, bottom: 2),
            child: Text(local.formatFullDate(its), style: theme.textTheme.labelLarge?.copyWith(color: scheme.primary)),
          ),
        );
      }
      final words = wordsOf(step, time: (ms) => _timeBeside(ms, step.atMs));
      final photo = step.photo;
      rows.add(
        _StepRow(
          key: ValueKey('history-step:$i'),
          time: _time(step.atMs),
          words: words,
          who: whoLine(step),
          warn: step.cameOff,
          onTap: step.other == null ? null : () => _open(step.other!),
          photo: photo == null
              ? null
              : _Photo(
                  key: ValueKey('history-photo:$i'),
                  bytes: _photo(photo),
                  onTap: (bytes) => _enlarge(step, bytes, words),
                ),
        ),
      );
    }
    return [
      Text(order.where, key: const ValueKey('history-where'), style: theme.textTheme.titleLarge),
      Text(
        [
          order.standing,
          if (order.server.isNotEmpty) 'server ${order.server}',
          if (guests != null) '$guests ${guests == 1 ? 'guest' : 'guests'}',
          if (opened != null)
            'opened ${local.formatShortMonthDay(DateTime.fromMillisecondsSinceEpoch(opened))}, ${_time(opened)}',
        ].join(' · '),
        key: const ValueKey('history-standing'),
        style: small,
      ),
      Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Text(
          count == 0
              ? 'Nothing is kept of this check.'
              : '$count ${count == 1 ? 'step' : 'steps'}, the oldest first. Nothing can be changed here.',
          key: const ValueKey('history-count'),
          style: small,
        ),
      ),
      const Divider(height: 20),
      ...rows,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final history = _history;
    final Widget body;
    if (_error != null) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!, key: const ValueKey('history-error'), textAlign: TextAlign.center),
              const SizedBox(height: 12),
              OutlinedButton(onPressed: _load, child: const Text('Try again')),
            ],
          ),
        ),
      );
    } else if (history == null) {
      body = const Center(child: CircularProgressIndicator());
    } else {
      body = ListView(
        key: const ValueKey('history-list'),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: _body(context, history),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('History'),
        actions: [
          IconButton(
            key: const ValueKey('history-refresh'),
            tooltip: 'Read again',
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 640), child: body),
      ),
    );
  }
}

/// One step: when, what happened and the lines that say the rest, who did it and where; at the edge the
/// picture taken with it, or an arrow when a tap opens the other check's history.
class _StepRow extends StatelessWidget {
  const _StepRow({
    super.key,
    required this.time,
    required this.words,
    required this.who,
    required this.warn,
    this.onTap,
    this.photo,
  });

  final String time;
  final StepWords words;
  final String who;

  /// It took something off the check: said in the colour of a void.
  final bool warn;
  final VoidCallback? onTap;
  final Widget? photo;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final small = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 68,
            child: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(time, style: small?.copyWith(fontFeatures: PosTheme.tabular)),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  words.title,
                  style: TextStyle(fontWeight: FontWeight.w600, color: warn ? scheme.error : null),
                ),
                for (final line in words.under) Text(line),
                if (who.isNotEmpty) Text(who, style: small),
              ],
            ),
          ),
          if (photo != null) Padding(padding: const EdgeInsets.only(left: 8), child: photo),
          if (onTap != null)
            Padding(
              padding: const EdgeInsets.only(left: 4, top: 2),
              child: Icon(Icons.chevron_right, size: 20, color: scheme.onSurfaceVariant),
            ),
        ],
      ),
    );
    return onTap == null ? row : InkWell(onTap: onTap, child: row);
  }
}

/// The picture taken with a step, small; a tap shows it large. A quiet mark once the hub no longer has it.
class _Photo extends StatelessWidget {
  const _Photo({super.key, required this.bytes, required this.onTap});

  final Future<Uint8List?> bytes;
  final void Function(Uint8List bytes) onTap;

  static const _side = 44.0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget box(Widget? child) => Container(
      width: _side,
      height: _side,
      decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(6)),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
    final gone = Tooltip(
      message: 'The picture is no longer kept',
      child: box(Icon(Icons.no_photography_outlined, size: 20, color: scheme.outline)),
    );
    return FutureBuilder<Uint8List?>(
      future: bytes,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) return box(null);
        final jpeg = snapshot.data;
        if (jpeg == null) return gone;
        return Tooltip(
          message: 'Who was at the screen. Tap to see it large',
          child: InkWell(
            onTap: () => onTap(jpeg),
            child: box(
              Image.memory(
                jpeg,
                width: _side,
                height: _side,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => Icon(Icons.no_photography_outlined, size: 20, color: scheme.outline),
              ),
            ),
          ),
        );
      },
    );
  }
}
