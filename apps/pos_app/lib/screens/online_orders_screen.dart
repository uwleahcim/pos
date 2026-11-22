import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../live.dart';
import '../online_orders.dart';
import '../shift_notes.dart' show dayWords, whenWords;
import '../takeout.dart' show clockTime;
import 'span_report.dart';

/// How the online orders are doing (docs/online-orders.md, "Under Location"): what is wrong right now, how
/// the orders arrive and when the last one did, today's by what became of them, and the ones a person should
/// look at, each by the website's own number. It is what `hubctl online status` says, on a screen.
///
/// Read only, and nothing of a customer is on it. Opening it is the looking: the hub is told that somebody
/// looked ([PosApi.onlineSeen]), and no screen alerts for those any more. They stay listed, and the ones that
/// were new when this screen came up keep their mark while it is open. What is wrong stays until it is mended.
///
/// With [opensChecks], a row that is a check on the POS closes the screen with that check's id, for the
/// screen underneath to open.
class OnlineOrdersScreen extends StatefulWidget {
  const OnlineOrdersScreen({super.key, required this.api, this.by = '', this.status, this.opensChecks = false});

  final PosApi api;

  /// Who is at the screen, by name: who looked.
  final String by;

  /// How they stood when the screen underneath last read it: shown until this one has read.
  final OnlineStatus? status;

  final bool opensChecks;

  @override
  State<OnlineOrdersScreen> createState() => _OnlineOrdersScreenState();
}

class _OnlineOrdersScreenState extends State<OnlineOrdersScreen> {
  late OnlineStatus? _status = widget.status;
  final _fresh = <String>{}; // the ones that were new while this screen was open, by the website's number
  String? _error; // nothing to show, and why
  bool _away = false; // no hub answers: what shows is as last read
  bool _older = false; // the hub that answers has no online orders
  bool _asking = false; // somebody pressed "Ask now" and the hub has not said what came of it
  OnlineAsked? _asked; // what came of the last asking from this screen
  String? _askError; // or why it could not be asked
  Timer? _timer;
  late final _reader = Paced(const Duration(seconds: 10), _read);
  StreamSubscription<LiveChange>? _live;

  @override
  void initState() {
    super.initState();
    _mark(widget.status);
    // Every half minute by itself: that the website stopped answering is nothing the hub announces.
    _timer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!_older) unawaited(_reader.now(must: false));
    });
    _live = widget.api.live.changes.listen((change) {
      if (!_older && (change.online || change.everything)) _reader();
    });
    unawaited(_reader.now());
  }

  @override
  void dispose() {
    _timer?.cancel();
    unawaited(_live?.cancel());
    _reader.cancel();
    super.dispose();
  }

  void _mark(OnlineStatus? status) {
    for (final row in status?.look ?? const <OnlineLook>[]) {
      if (row.isNew) _fresh.add(row.id);
    }
  }

  Future<void> _read() async {
    try {
      final status = await widget.api.onlineStatus();
      if (!mounted) return;
      if (status == null) return setState(() => _older = true);
      _mark(status);
      setState(() {
        _status = status;
        _error = null;
        _away = false;
      });
      if (status.news > 0) await _looked();
    } on ApiException catch (err) {
      if (!mounted) return;
      setState(() {
        _away = err.status == null;
        if (_status == null) _error = err.status == null ? 'The hub is not answering' : err.message;
      });
    }
  }

  /// "Ask now": the hub asks the website for orders this moment, as it does every minute by itself, and
  /// says what came of it. It changes nothing a round of the hub's own would not.
  Future<void> _askNow() async {
    if (_asking) return;
    setState(() {
      _asking = true;
      _asked = null;
      _askError = null;
    });
    try {
      final asked = await widget.api.onlineFetch();
      if (!mounted) return;
      _mark(asked.status);
      setState(() {
        _asking = false;
        _asked = asked;
        if (asked.status != null) _status = asked.status;
        _away = false;
      });
      if ((asked.status?.news ?? 0) > 0) await _looked();
    } on ApiException catch (err) {
      if (!mounted) return;
      setState(() {
        _asking = false;
        _askError = err.status == null ? 'The hub is not answering, so GloriaFood was not asked.' : err.message;
      });
    }
  }

  /// Whoever has this screen open has looked: the hub writes that down, for every screen.
  Future<void> _looked() async {
    try {
      final after = await widget.api.onlineSeen(widget.by);
      if (mounted) setState(() => _status = after);
    } on ApiException {
      // not written down (nothing answers, or a hub that cannot write): they stay new and alert on
    }
  }

  /// "18:05" for today, "yesterday 22:10" before that.
  static String _at(int ms, DateTime now) =>
      dayWords(DateTime.fromMillisecondsSinceEpoch(ms), now) == 'today' ? clockTime(ms) : whenWords(ms, now);

  @override
  Widget build(BuildContext context) {
    final status = _status;
    final Widget body;
    if (_older) {
      body = const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'This hub is older than this screen. Update the hub to see the online orders here.',
            key: ValueKey('online-older'),
            textAlign: TextAlign.center,
          ),
        ),
      );
    } else if (status == null && _error != null) {
      body = SpanError(prefix: 'online', message: _error!, onRetry: () => unawaited(_reader.now()));
    } else if (status == null) {
      body = const Center(child: CircularProgressIndicator(key: ValueKey('online-reading')));
    } else {
      body = _list(context, status);
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Online orders'),
        actions: [
          IconButton(
            key: const ValueKey('online-refresh'),
            tooltip: 'Read again',
            icon: const Icon(Icons.refresh),
            onPressed: _older ? null : () => unawaited(_reader.now()),
          ),
        ],
      ),
      body: body,
    );
  }

  Widget _list(BuildContext context, OnlineStatus status) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final now = DateTime.now();
    Widget head(String words) => Padding(
      padding: const EdgeInsets.fromLTRB(4, 14, 4, 6),
      child: Text(words, style: theme.textTheme.titleSmall?.copyWith(color: scheme.onSurfaceVariant)),
    );
    return ListView(
      key: const ValueKey('online-list'),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      children: [
        if (_away)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              'The hub is not answering: this is how it stood when it last did.',
              key: const ValueKey('online-away'),
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
            ),
          ),
        for (final trouble in status.trouble) _trouble(context, trouble),
        if (!status.isOn)
          Card(
            key: const ValueKey('online-off'),
            child: const ListTile(
              leading: Icon(Icons.cloud_off_outlined),
              title: Text('Online orders are off'),
              subtitle: Text(
                'The hub has no key from GloriaFood, so no order from the website reaches the POS. The guide '
                '(docs/online-orders.md) has the steps.',
              ),
            ),
          )
        else ...[
          head('How they arrive'),
          Card(
            child: Column(
              children: [
                ListTile(
                  key: const ValueKey('online-pushes'),
                  leading: const Icon(Icons.bolt_outlined),
                  title: const Text('Sent by GloriaFood'),
                  subtitle: Text(_pushWords(status, now)),
                ),
                const Divider(height: 1),
                ListTile(
                  key: const ValueKey('online-asking'),
                  leading: const Icon(Icons.sync_outlined),
                  title: const Text('Asked for every minute'),
                  subtitle: Text(_askWords(status, now)),
                ),
                // Only a hub that has the key for asking can ask. Under the row and not beside it: on a
                // phone a button at the end of the row leaves its words a column a few letters wide.
                if (status.asks)
                  Padding(
                    padding: const EdgeInsetsDirectional.only(start: 44, end: 8),
                    child: Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: TextButton(
                        key: const ValueKey('online-ask'),
                        style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                        onPressed: _asking ? null : () => unawaited(_askNow()),
                        child: _asking
                            ? const Row(
                                key: ValueKey('online-ask-busy'),
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                                  SizedBox(width: 10),
                                  Text('Asking GloriaFood'),
                                ],
                              )
                            : const Text('Ask now'),
                      ),
                    ),
                  ),
                if (_asked != null || _askError != null)
                  Padding(
                    padding: const EdgeInsetsDirectional.only(start: 56, end: 16, bottom: 12),
                    child: Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: Text(
                        _askError ?? _asked!.words,
                        key: const ValueKey('online-asked'),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: _askError != null || _asked!.bad ? scheme.error : scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  )
                else if (status.asks)
                  const SizedBox(height: 4),
              ],
            ),
          ),
          if (!status.writable)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
              child: Text(
                'This hub cannot write orders down now (it is the standby), so it takes none.',
                key: const ValueKey('online-standby'),
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
              ),
            ),
          head('Today'),
          Card(
            key: const ValueKey('online-today'),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 20,
                    runSpacing: 10,
                    children: [
                      _figure(context, '${status.came}', 'came'),
                      _figure(context, '${status.placed}', 'on the POS'),
                      if (status.kept > 0) _figure(context, '${status.kept}', 'not for the POS'),
                      if (status.failed > 0) _figure(context, '${status.failed}', 'could not be put on', bad: true),
                      if (status.waiting > 0) _figure(context, '${status.waiting}', 'waiting'),
                    ],
                  ),
                  if (status.came > 0) ...[
                    const SizedBox(height: 8),
                    Text(
                      '${status.byPush} sent by GloriaFood, ${status.byPoll} asked for by the hub',
                      style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                  if (status.unread > 0) ...[
                    const SizedBox(height: 4),
                    Text(
                      status.unread == 1
                          ? '1 thing the website sent could not be read (below)'
                          : '${status.unread} things the website sent could not be read (below)',
                      style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
        if (status.isOn || status.look.isNotEmpty) ...[
          head('To look at'),
          Card(
            child: status.look.isEmpty
                ? const ListTile(
                    key: ValueKey('online-nothing'),
                    leading: Icon(Icons.check_circle_outline),
                    title: Text('Nothing to look at'),
                    subtitle: Text('Every order that reached the hub went on the POS as it came.'),
                  )
                : Column(
                    children: [
                      for (final (index, row) in status.look.indexed) ...[
                        if (index > 0) const Divider(height: 1),
                        _row(context, row, now),
                      ],
                    ],
                  ),
          ),
          if (status.look.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
              child: Text(
                'The number is GloriaFood\'s own: it finds the order in GloriaFood\'s app.',
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
        ],
      ],
    );
  }

  static String _pushWords(OnlineStatus status, DateTime now) {
    if (!status.takesPushes) return 'Off: the hub has no key for it. Orders come by the asking alone.';
    final last = status.pushedMs;
    return last == null ? 'On · none has come yet' : 'On · the last one came ${_at(last, now)}';
  }

  static String _askWords(OnlineStatus status, DateTime now) {
    if (!status.asks) {
      return status.takesPushes
          ? 'Off: the hub has no key for it. Nothing brings an order that gets lost on the way.'
          : 'Off: the hub has no key for it.';
    }
    if (!status.running) return 'NOT RUNNING. On the hub: sudo hubctl restart';
    final last = status.answeredMs;
    return last == null ? 'On · GloriaFood has not answered yet' : 'On · GloriaFood last answered ${_at(last, now)}';
  }

  Widget _figure(BuildContext context, String figure, String words, {bool bad = false}) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          figure,
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w700,
            color: bad ? scheme.error : scheme.onSurface,
          ),
        ),
        Text(words, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
      ],
    );
  }

  /// What is wrong right now, in a box of its own: red when no order is reaching the POS.
  Widget _trouble(BuildContext context, OnlineTrouble trouble) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (back, front) = trouble.urgent
        ? (scheme.errorContainer, scheme.onErrorContainer)
        : (scheme.tertiaryContainer, scheme.onTertiaryContainer);
    return Card(
      key: ValueKey('online-trouble:${trouble.code}'),
      color: back,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(trouble.urgent ? Icons.error_outline : Icons.info_outline, color: front),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    trouble.headline,
                    style: theme.textTheme.titleSmall?.copyWith(color: front, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 4),
                  Text(trouble.words, style: theme.textTheme.bodyMedium?.copyWith(color: front)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(BuildContext context, OnlineLook row, DateTime now) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final opens = widget.opensChecks && row.onThePos;
    final lost = row.state != 'placed' && row.state != 'kept'; // it should be on the POS, or be read, and is not
    return ListTile(
      key: ValueKey('online-look:${row.id}'),
      leading: Icon(
        row.onThePos
            ? Icons.receipt_long_outlined
            : lost
            ? Icons.error_outline
            : Icons.history,
        color: lost ? scheme.error : scheme.onSurfaceVariant,
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              row.atMs > 0 ? '${row.name} · ${_at(row.atMs, now)}' : row.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (_fresh.contains(row.id)) ...[
            const SizedBox(width: 8),
            Container(
              key: ValueKey('online-new:${row.id}'),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(color: scheme.tertiaryContainer, borderRadius: BorderRadius.circular(8)),
              child: Text(
                'New',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onTertiaryContainer,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ],
      ),
      subtitle: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: row.stateWords,
              style: TextStyle(fontWeight: FontWeight.w700, color: lost ? scheme.error : null),
            ),
            if (row.said.isNotEmpty) TextSpan(text: ': ${row.said}'),
          ],
        ),
      ),
      trailing: opens ? const Icon(Icons.chevron_right) : null,
      onTap: opens ? () => Navigator.of(context).pop(row.orderId) : null,
    );
  }
}

/// One slim line above the checks on a manager's screen while there is something about the online orders to
/// look at: red while none is reaching the POS, otherwise how many are new. A tap opens [OnlineOrdersScreen].
class OnlineAlertStrip extends StatelessWidget {
  const OnlineAlertStrip({super.key, required this.status, this.onTap});

  final OnlineStatus status;
  final VoidCallback? onTap;

  /// Whether [status] has anything to alert a manager to.
  static bool shows(OnlineStatus? status) => status?.alert != null;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final urgent = status.urgent != null;
    final (back, front) = urgent
        ? (scheme.errorContainer, scheme.onErrorContainer)
        : (scheme.tertiaryContainer, scheme.onTertiaryContainer);
    return Material(
      color: back,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          child: Row(
            children: [
              Icon(urgent ? Icons.error_outline : Icons.language, size: 16, color: front),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  status.alert ?? '',
                  key: const ValueKey('online-alert-words'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(color: front, fontWeight: FontWeight.w700),
                ),
              ),
              Icon(Icons.chevron_right, size: 16, color: front),
            ],
          ),
        ),
      ),
    );
  }
}
