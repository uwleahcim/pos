import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../live.dart';
import '../prep_list.dart';
import '../takeout.dart';
import 'theme.dart';

/// The prep list of one day (docs/catering.md): what the day's orders ahead need made, added up dish by
/// dish for each station that cooks them, with the day's orders at its head. The dishes are in the kitchen's
/// own words, as its tickets have them. Print sends the same list to paper.
///
/// It reads the list again when the hub says an order changed, and now and then while the hub cannot say.
class PrepListScreen extends StatefulWidget {
  const PrepListScreen({super.key, required this.api, required this.day, required this.heading});

  final PosApi api;

  /// The day of service, `2026-11-21`, and what Orders ahead calls it ("Tomorrow", "Sat 21 Nov").
  final String day;
  final String heading;

  @override
  State<PrepListScreen> createState() => _PrepListScreenState();
}

class _PrepListScreenState extends State<PrepListScreen> {
  PrepList? _list;
  bool _read = false; // the hub answered once
  bool _old = false; // a hub from before the prep list
  bool _away = false; // the last read got no answer
  bool _printing = false;
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
    try {
      final list = await widget.api.prepList(widget.day);
      if (!mounted) return;
      // the same answer as last time comes back as the same object: nothing to draw again
      if (_read && !_away && identical(list, _list)) return;
      setState(() {
        _list = list;
        _old = list == null;
        _read = true;
        _away = false;
      });
    } on ApiException {
      if (mounted && !_away) setState(() => _away = true);
    }
  }

  Future<void> _print() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _printing = true);
    String said;
    try {
      final own = widget.api.settings.billPrinter;
      final at = await widget.api.printPrep(widget.day, printer: own.isEmpty ? null : own);
      said = at.isEmpty ? 'The prep list is printing' : 'The prep list is printing at $at';
    } on ApiException catch (err) {
      said = switch (err.status) {
        null => 'The hub is not answering: nothing was printed',
        404 || 405 => 'This hub does not print prep lists yet: update it',
        _ => (err.detail?['message'] as String?) ?? 'Could not print: ${err.message}',
      };
    }
    if (!mounted) return;
    setState(() => _printing = false);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(said, key: const ValueKey('prep-printed'))));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final list = _list;
    final Widget body;
    if (_old) {
      body = const _Says('This hub does not make prep lists yet. Update the hub.');
    } else if (list == null) {
      body = _away ? const _Says('The hub is not answering.') : const Center(child: CircularProgressIndicator());
    } else if (list.dishes == 0) {
      body = const _Says('No dishes are on an order for this day.', key: ValueKey('prep-none'));
    } else {
      final faint = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant, fontFeatures: PosTheme.tabular);
      body = ListView(
        key: const ValueKey('prep-list'),
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 28),
        children: [
          Text(list.summed, key: const ValueKey('prep-summed'), style: theme.textTheme.titleSmall),
          if (list.unsent > 0) Padding(padding: const EdgeInsets.only(top: 8), child: _Notice(list.unsentWords)),
          const SizedBox(height: 10),
          for (final order in list.orders)
            Padding(
              key: ValueKey('prep-order:${order.orderId}'),
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(clockTime(order.promisedMs), style: faint?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(width: 10),
                  Expanded(child: Text(order.words, style: faint)),
                  const SizedBox(width: 8),
                  Text(order.dishes == 1 ? '1 dish' : '${order.dishes} dishes', style: faint),
                ],
              ),
            ),
          for (final station in list.stations) ...[
            Padding(
              padding: const EdgeInsets.only(top: 18, bottom: 2),
              child: Text(
                station.name,
                key: ValueKey('prep-station:${station.station ?? ''}'),
                style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
              ),
            ),
            const Divider(height: 8),
            for (final row in station.rows) _DishRow(row: row, byWhen: list.manyTimes),
          ],
        ],
      );
    }
    return Scaffold(
      appBar: AppBar(
        // the day first: it is what a narrow bar must not cut off
        title: Text('${widget.heading} · Prep list'),
        actions: [
          if (list != null && list.dishes > 0)
            IconButton(
              key: const ValueKey('prep-print'),
              tooltip: 'Print the prep list',
              onPressed: _printing ? null : _print,
              icon: const Icon(Icons.print_outlined),
            ),
        ],
      ),
      body: Column(
        children: [
          if (_away && list != null)
            Material(
              color: scheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'The hub is not answering: this list may be behind.',
                        key: const ValueKey('prep-away'),
                        style: theme.textTheme.bodySmall?.copyWith(color: scheme.onErrorContainer),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          Expanded(child: body),
        ],
      ),
    );
  }
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

/// Something the reader must not miss: dishes on the day's orders that nobody sent.
class _Notice extends StatelessWidget {
  const _Notice(this.words);

  final String words;

  @override
  Widget build(BuildContext context) {
    final posColors = PosColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(color: posColors.timerLate, borderRadius: BorderRadius.circular(8)),
      child: Text(
        words,
        key: const ValueKey('prep-unsent'),
        style: Theme.of(context).textTheme.bodyMedium
            ?.copyWith(color: posColors.timerLateText, fontWeight: FontWeight.w700),
      ),
    );
  }
}

/// One dish: how many, what, and by when the first; under it the combination it is a part of, and how some
/// of them are wanted when not plain.
class _DishRow extends StatelessWidget {
  const _DishRow({required this.row, required this.byWhen});

  final PrepRow row;
  final bool byWhen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final faint = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final count = theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800, fontFeatures: PosTheme.tabular);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // the counts stand in a column of their own, so the eye runs down them
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 40),
            child: Text('${row.qty}', textAlign: TextAlign.right, style: count),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(row.label, style: theme.textTheme.titleMedium),
                if (row.header.isNotEmpty) Text('with ${row.header}', style: faint),
                for (final way in row.ways)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text('${way.qty} × ${way.words}', style: theme.textTheme.bodyMedium),
                  ),
              ],
            ),
          ),
          if (byWhen)
            Padding(
              padding: const EdgeInsets.only(left: 8, top: 3),
              child: Text('by ${clockTime(row.firstMs)}', style: faint?.copyWith(fontFeatures: PosTheme.tabular)),
            ),
        ],
      ),
    );
  }
}
