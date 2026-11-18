import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../live.dart';
import '../runs.dart';
import '../session.dart';
import 'theme.dart';

/// The drivers' runs of a day of service (docs/delivery.md, "Runs"): for each driver who took a delivery
/// out, their runs in the order they left, and what became of every bag. It opens on the day that is
/// running; the arrows step to the days before. A driver who is signed in sees their own runs first.
///
/// The hub reads all of it off the orders' own logs. No money is here: what a delivery came to is the
/// check's and the reports'.
///
/// It reads again when the hub says an order changed, and now and then while the hub cannot say.
class RunsScreen extends StatefulWidget {
  const RunsScreen({super.key, required this.api, required this.session});

  final PosApi api;
  final Session session;

  @override
  State<RunsScreen> createState() => _RunsScreenState();
}

class _RunsScreenState extends State<RunsScreen> {
  RunsReport? _report;
  String? _day; // the day asked for; none is the one that is running
  String? _today; // the day that is running, as the hub last named it
  bool _read = false; // the hub answered once for this day
  bool _old = false; // a hub from before the runs
  bool _away = false; // the last read got no answer
  late final _poll = SafetyPoll(widget.api.live);
  late final _reader = Paced(const Duration(seconds: 1), _load);
  StreamSubscription<LiveChange>? _live;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (_poll.due()) unawaited(_reader.now(must: false));
    });
    _live = widget.api.live.changes.listen((change) {
      if (change.anyOrder) _reader();
    });
    unawaited(_reader.now());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _live?.cancel();
    _reader.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    _poll.asked();
    final asked = _day;
    try {
      final report = await widget.api.runs(day: asked);
      if (!mounted || asked != _day) return; // another day was asked for meanwhile: its own read follows
      // the same answer as last time comes back as the same object: nothing to draw again
      if (_read && !_away && identical(report, _report)) return;
      setState(() {
        _report = report;
        _old = report == null;
        if (asked == null && report != null) _today = report.day;
        _read = true;
        _away = false;
      });
    } on ApiException {
      if (mounted && asked == _day && !_away) setState(() => _away = true);
    }
  }

  /// Steps to the day before ([by] -1) or after the one shown, never past the day that is running.
  void _step(int by) {
    final today = _today;
    if (today == null) return;
    final next = dayFrom(_day ?? today, by);
    if (next.compareTo(today) > 0) return;
    setState(() {
      _day = next == today ? null : next;
      _report = null;
      _read = false;
      _away = false;
    });
    unawaited(_reader.now());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final report = _report;
    final today = _today;
    final shown = _day ?? today;
    final Widget body;
    if (_old) {
      body = const _Says('This hub does not list runs yet. Update the hub.', key: ValueKey('runs-old'));
    } else if (report == null) {
      body = _away ? const _Says('The hub is not answering.') : const Center(child: CircularProgressIndicator());
    } else {
      final me = widget.session.staff?.staffId;
      final drivers = report.mineFirst(me);
      body = LayoutBuilder(
        builder: (context, box) {
          // the drivers side by side where there is the width; one under the other on a phone
          final across = (box.maxWidth ~/ 380).clamp(1, 3);
          return ListView(
            key: const ValueKey('runs-list'),
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
            children: [
              if (report.drivers.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 20),
                  child: Text(
                    _day == null
                        ? 'No delivery has left with a driver today.'
                        : 'No delivery left with a driver on this day.',
                    key: const ValueKey('runs-none'),
                    textAlign: TextAlign.center,
                  ),
                )
              else
                Text(
                  report.summed,
                  key: const ValueKey('runs-summed'),
                  style: theme.textTheme.titleSmall?.copyWith(fontFeatures: PosTheme.tabular),
                ),
              if (report.noDriver > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    report.noDriverWords,
                    key: const ValueKey('runs-no-driver'),
                    style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ),
              for (var at = 0; at < drivers.length; at += across)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var i = at; i < at + across; i++) ...[
                      if (i > at) const SizedBox(width: 16),
                      Expanded(
                        child: i < drivers.length
                            ? _Driver(driver: drivers[i], mine: me != null && drivers[i].driverId == me)
                            : const SizedBox.shrink(),
                      ),
                    ],
                  ],
                ),
            ],
          );
        },
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Runs')),
      body: Column(
        children: [
          if (!_old)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(
                children: [
                  IconButton(
                    key: const ValueKey('runs-earlier'),
                    tooltip: 'The day before',
                    onPressed: today == null ? null : () => _step(-1),
                    icon: const Icon(Icons.chevron_left),
                  ),
                  Expanded(
                    child: Text(
                      shown == null || today == null ? 'Today' : _dayTitle(shown, today),
                      key: const ValueKey('runs-day'),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('runs-later'),
                    tooltip: 'The day after',
                    onPressed: _day == null ? null : () => _step(1),
                    icon: const Icon(Icons.chevron_right),
                  ),
                ],
              ),
            ),
          if (_away && report != null)
            Container(
              key: const ValueKey('runs-away'),
              width: double.infinity,
              color: scheme.errorContainer,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Text(
                'This list may be behind: the hub is not answering.',
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.onErrorContainer),
              ),
            ),
          Expanded(child: body),
        ],
      ),
    );
  }
}

/// "Today · Mon 16 Nov", "Yesterday · Sun 15 Nov", "Sat 14 Nov"
String _dayTitle(String day, String today) {
  final called = runsDayWords(day, today);
  final dated = runsDayWords(day, '');
  return called == dated ? dated : '$called · $dated';
}

class _Says extends StatelessWidget {
  const _Says(this.words, {super.key});

  final String words;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Text(words, textAlign: TextAlign.center),
    ),
  );
}

/// One driver: who, what their day came to, and their runs in the order they left.
class _Driver extends StatelessWidget {
  const _Driver({required this.driver, required this.mine});

  final DriverRuns driver;
  final bool mine;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final id = driver.driverId.isEmpty ? driver.driver : driver.driverId;
    return Column(
      key: ValueKey('runs-driver:$id'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 16, 4, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                mine
                    ? 'You'
                    : driver.driver.isEmpty
                    ? 'No driver named'
                    : driver.driver,
                style: theme.textTheme.titleMedium?.copyWith(color: scheme.primary, fontWeight: FontWeight.w800),
              ),
              Text(
                driver.summed,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontFeatures: PosTheme.tabular,
                ),
              ),
            ],
          ),
        ),
        for (final (index, run) in driver.list.indexed)
          Card(
            key: ValueKey('run:$id:${index + 1}'),
            margin: const EdgeInsets.symmetric(vertical: 4),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: BorderSide(color: run.isOut ? scheme.primary : scheme.outlineVariant, width: run.isOut ? 2 : 1),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Run ${index + 1} · ${run.words}',
                    style: theme.textTheme.titleSmall?.copyWith(fontFeatures: PosTheme.tabular),
                  ),
                  for (final bag in run.bags) _Bag(bag: bag),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// One bag of a run: the order, where it went, and what became of it.
class _Bag extends StatelessWidget {
  const _Bag({required this.bag});

  final RunBag bag;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final said = theme.textTheme.bodyMedium?.copyWith(
      fontFeatures: PosTheme.tabular,
      color: switch (bag.outcome) {
        'delivered' => scheme.onSurface,
        'back' => scheme.tertiary,
        'void' => scheme.error,
        'handed' => scheme.onSurfaceVariant,
        _ => scheme.primary,
      },
      fontWeight: bag.isOut ? FontWeight.w800 : null,
    );
    return Padding(
      key: ValueKey('run-bag:${bag.orderId}:${bag.leftMs}'),
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // what became of it beside the order where there is the width, under it where there is not
          SizedBox(
            width: double.infinity,
            child: Wrap(
              spacing: 12,
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(bag.title, style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w700)),
                Text(bag.words, style: said),
              ],
            ),
          ),
          if (bag.address.isNotEmpty)
            Text(bag.address, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}
