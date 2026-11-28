import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../live.dart';
import '../shipday.dart';
import '../takeout.dart' show clockTime;

/// Shipday on one screen (docs/shipday.md): the drivers who are on shift with how much each has, and the
/// deliveries Shipday has, by how far along they are: the ones nobody has yet, the ones a driver was given,
/// the ones on their way, and under a fold the ones that finished today. Beside each delivery is the check
/// it is on the POS, which a tap opens; one the hub finds no check for says so.
///
/// It reads and nothing else. Giving a delivery to a driver and saying how far along it is are still done
/// in Shipday's own apps, and the screen says so.
///
/// It reads the hub's picture when the hub says it changed (or a check did, which may be the one a
/// delivery is), and now and then while the hub cannot say. Every read tells the hub that somebody is
/// looking, which makes it ask Shipday oftener. With the hub away it keeps its last picture and says it
/// may be behind.
class ShipdayScreen extends StatefulWidget {
  const ShipdayScreen({super.key, required this.api, required this.onOpen, this.board});

  final PosApi api;

  /// The picture as the list of checks last read it, to start from.
  final ShipdayBoard? board;

  /// Opens the check tapped; the picture is read again when it comes back.
  final Future<void> Function(String orderId) onOpen;

  @override
  State<ShipdayScreen> createState() => _ShipdayScreenState();
}

class _ShipdayScreenState extends State<ShipdayScreen> {
  late ShipdayBoard? _board = widget.board;
  bool _asked = false; // the hub was asked once and answered
  bool _old = false; // the hub answered that it knows nothing of Shipday
  bool _away = false; // the last read got no answer
  bool _asking = false; // "Ask now" is under way
  bool _showDone = false;
  late final _poll = SafetyPoll(widget.api.live);
  late final _reader = Paced(const Duration(seconds: 2), _load);
  StreamSubscription<LiveChange>? _live;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (_poll.due()) unawaited(_reader.now(must: false));
    });
    _live = widget.api.live.changes.listen((change) {
      // a check that changed may be the one a delivery is: the hub puts the two together when it is asked
      if (change.shipday || change.anyOrder) _reader();
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
      final board = await widget.api.shipday(looking: true);
      if (!mounted) return;
      // the same object as last time while nothing changed: nothing to draw then
      if (_asked && !_away && identical(board, _board) && _old == (board == null)) return;
      setState(() {
        _asked = true;
        _away = false;
        _old = board == null;
        _board = board;
      });
    } on ApiException {
      if (!mounted || _away) return;
      setState(() => _away = true);
    }
  }

  /// Shipday is asked now, out of the hub's own turn, and the screen says what came of it.
  Future<void> _askNow() async {
    if (_asking) return;
    setState(() => _asking = true);
    String words;
    try {
      final asked = await widget.api.shipdayAsk();
      if (!mounted) return;
      words = asked.words;
      if (asked.board != null) setState(() => _board = asked.board);
    } on ApiException catch (err) {
      if (!mounted) return;
      words = switch (err.status) {
        409 => 'This hub has no key for Shipday.',
        404 || 405 => 'This hub is older than reading Shipday. Update it first.',
        null => 'The hub did not answer.',
        _ => 'Shipday was not asked: ${err.message}.',
      };
    } finally {
      if (mounted) setState(() => _asking = false);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          key: const ValueKey('shipday-said'),
          content: Text(words, key: const ValueKey('shipday-said-words')),
        ),
      );
    unawaited(_reader.now());
  }

  Future<void> _open(ShipdayCheck check) async {
    await widget.onOpen(check.orderId);
    if (mounted) unawaited(_reader.now());
  }

  List<Widget> _cards(List<ShipdayOrder> orders) => [
    for (final order in orders) _DeliveryCard(key: ValueKey('shipday-order-${order.id}'), order: order, onOpen: _open),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final board = _board;
    final Widget body;
    if (board == null && !_asked && !_away) {
      body = const Center(child: CircularProgressIndicator());
    } else if (board == null || !board.on) {
      body = _Nothing(
        key: const ValueKey('shipday-off'),
        words: _old
            ? 'This hub is older than reading Shipday. Update it first (sudo hubctl update).'
            : board == null
            ? 'The hub is not answering.'
            : 'This hub has no key for Shipday. A manager types it under Location, Keys and connections.',
      );
    } else {
      body = _lists(context, board);
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Shipday'),
        actions: [
          if (board != null && board.on)
            _asking
                ? const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 14),
                    child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                  )
                : IconButton(
                    key: const ValueKey('shipday-ask'),
                    tooltip: 'Ask Shipday now',
                    onPressed: _askNow,
                    icon: const Icon(Icons.refresh),
                  ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: [
          if (_away && board != null)
            _Banner(
              key: const ValueKey('shipday-away'),
              words: 'This may be behind: the hub is not answering.',
              color: scheme.errorContainer,
              on: scheme.onErrorContainer,
            ),
          if (board != null && board.on && board.trouble != null)
            _Banner(
              key: const ValueKey('shipday-trouble'),
              words: [
                board.trouble!.words,
                if (board.read)
                  board.trouble!.sinceMs == null
                      ? 'What is listed here is what it last said.'
                      : 'What is listed here is what it said before ${clockTime(board.trouble!.sinceMs!)}.',
              ].join(' '),
              color: scheme.errorContainer,
              on: scheme.onErrorContainer,
            ),
          Expanded(child: body),
        ],
      ),
    );
  }

  Widget _lists(BuildContext context, ShipdayBoard board) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final quiet = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    if (!board.read) {
      // a key that Shipday has not answered with yet: the banner above says why, where it has said
      return _Nothing(
        key: const ValueKey('shipday-unread'),
        words: board.trouble == null ? 'Asking Shipday…' : 'Shipday has not answered yet.',
      );
    }
    final working = board.onShift;
    final off = board.offShift;
    final drivers = <Widget>[
      _Heading(
        key: const ValueKey('shipday-drivers'),
        title: 'Drivers on shift',
        count: working.length,
        under: board.drivers.isEmpty
            ? 'Shipday lists no driver.'
            : working.isEmpty
            ? 'No driver is on shift in Shipday.'
            : null,
      ),
      if (working.isNotEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
          child: Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [for (final driver in working) _DriverChip(key: ValueKey('shipday-driver-${driver.id}'), driver)],
          ),
        ),
      if (off.isNotEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 2, 4, 4),
          child: Text(
            'Off shift: ${[for (final driver in off.take(8)) driver.called].join(', ')}'
            '${off.length > 8 ? ' and ${off.length - 8} more' : ''}',
            key: const ValueKey('shipday-off-shift'),
            style: quiet,
          ),
        ),
    ];
    final need = board.needDriver, given = board.withDriver, way = board.onTheWay, others = board.others;
    final waiting = <Widget>[
      _Heading(
        key: const ValueKey('shipday-need'),
        title: 'Need a driver',
        count: need.length,
        under: need.isEmpty ? 'Every delivery has a driver.' : null,
      ),
      ..._cards(need),
    ];
    final out = <Widget>[
      _Heading(
        key: const ValueKey('shipday-given'),
        title: 'With a driver',
        count: given.length,
        under: given.isEmpty ? 'Nothing is waiting to be picked up.' : null,
      ),
      ..._cards(given),
      _Heading(
        key: const ValueKey('shipday-way'),
        title: 'On the way',
        count: way.length,
        under: way.isEmpty ? 'Nothing is on its way.' : null,
      ),
      ..._cards(way),
      if (others.isNotEmpty) ...[
        _Heading(key: const ValueKey('shipday-others'), title: 'Other', count: others.length),
        ..._cards(others),
      ],
    ];
    final done = <Widget>[
      InkWell(
        key: const ValueKey('shipday-done'),
        onTap: board.done.isEmpty ? null : () => setState(() => _showDone = !_showDone),
        borderRadius: BorderRadius.circular(8),
        child: Row(
          children: [
            Expanded(
              child: _Heading(
                title: 'Finished today',
                count: board.done.length,
                under: board.done.isEmpty ? 'Nothing has finished yet.' : null,
              ),
            ),
            if (board.done.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Icon(_showDone ? Icons.expand_less : Icons.expand_more, color: scheme.onSurfaceVariant),
              ),
          ],
        ),
      ),
      if (_showDone) ..._cards(board.done),
    ];
    final foot = <Widget>[
      const SizedBox(height: 12),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Text(
          [
            "This screen only reads Shipday. A delivery is given to a driver, and marked as it goes, in Shipday's "
                'own app for now.',
            if (board.eta == 'plan')
              "Shipday does not tell this account how far away a delivery is: that is part of Shipday's higher plans.",
          ].join(' '),
          key: const ValueKey('shipday-foot'),
          style: quiet,
        ),
      ),
    ];
    return LayoutBuilder(
      builder: (context, box) {
        // side by side where there is the width for two lists, what waits for a driver beside the drivers
        // and what the drivers have beside that; one under the other on a phone
        if (box.maxWidth >= 760) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: ListView(
                  key: const ValueKey('shipday-left'),
                  padding: const EdgeInsets.fromLTRB(16, 8, 8, 24),
                  children: [...drivers, ...waiting, ...foot],
                ),
              ),
              Expanded(
                child: ListView(
                  key: const ValueKey('shipday-right'),
                  padding: const EdgeInsets.fromLTRB(8, 8, 16, 24),
                  children: [...out, ...done],
                ),
              ),
            ],
          );
        }
        return ListView(
          key: const ValueKey('shipday-list'),
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
          children: [...drivers, ...waiting, ...out, ...done, ...foot],
        );
      },
    );
  }
}

/// A line across the top of the screen: something is wrong, and what is shown may be behind.
class _Banner extends StatelessWidget {
  const _Banner({super.key, required this.words, required this.color, required this.on});

  final String words;
  final Color color;
  final Color on;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    color: color,
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
    child: Text(words, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: on)),
  );
}

/// The whole screen has one thing to say: there is no key, or Shipday has not answered yet.
class _Nothing extends StatelessWidget {
  const _Nothing({super.key, required this.words});

  final String words;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Text(words, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyLarge),
      ),
    ),
  );
}

/// The title of one list with how many are in it, and a line under it when there is one to say.
class _Heading extends StatelessWidget {
  const _Heading({super.key, required this.title, required this.count, this.under});

  final String title;
  final int count;
  final String? under;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 10, 4, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$title · $count', style: theme.textTheme.titleMedium?.copyWith(color: scheme.primary)),
          if (under != null) Text(under!, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}

/// A driver who is on shift, with how many deliveries they have that are not finished.
class _DriverChip extends StatelessWidget {
  const _DriverChip(this.driver, {super.key});

  final ShipdayDriver driver;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final free = driver.orders == 0;
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 5, 6, 5),
      decoration: BoxDecoration(
        color: free ? scheme.surface : scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: free ? scheme.outlineVariant : scheme.secondaryContainer),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(driver.called, overflow: TextOverflow.ellipsis, style: theme.textTheme.labelLarge),
          ),
          const SizedBox(width: 8),
          Container(
            constraints: const BoxConstraints(minWidth: 24),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: free ? scheme.surfaceContainerHighest : scheme.secondary,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              free ? 'free' : '${driver.orders}',
              textAlign: TextAlign.center,
              semanticsLabel: free ? 'free' : '${driver.orders} out',
              style: theme.textTheme.labelMedium?.copyWith(
                color: free ? scheme.onSurfaceVariant : scheme.onSecondary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One delivery: whose it is and where it goes, who has it and what happened last, when it is expected,
/// and the check it is on the POS.
class _DeliveryCard extends StatelessWidget {
  const _DeliveryCard({super.key, required this.order, required this.onOpen});

  final ShipdayOrder order;
  final Future<void> Function(ShipdayCheck check) onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final soft = scheme.onSurfaceVariant;
    final small = theme.textTheme.bodySmall?.copyWith(color: soft);
    final (pill, onPill) = switch (order.state) {
      'NOT_ASSIGNED' || 'FAILED_DELIVERY' || 'INCOMPLETE' => (scheme.errorContainer, scheme.onErrorContainer),
      'NOT_ACCEPTED' => (scheme.tertiaryContainer, scheme.onTertiaryContainer),
      'PICKED_UP' || 'READY_TO_DELIVER' => (scheme.primaryContainer, scheme.onPrimaryContainer),
      _ => (scheme.surfaceContainerHighest, scheme.onSurface),
    };
    final progress = order.progress;
    final expected = order.expected;
    final facts = order.facts;
    final check = order.check;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // the name and where it stands on one line, the second under the first where the two do not fit
            SizedBox(
              width: double.infinity,
              child: Wrap(
                spacing: 8,
                runSpacing: 2,
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(order.title, style: theme.textTheme.titleMedium),
                  Container(
                    key: ValueKey('shipday-state-${order.id}'),
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(color: pill, borderRadius: BorderRadius.circular(10)),
                    child: Text(
                      shipdayStateWords(order.state),
                      style: theme.textTheme.labelMedium?.copyWith(color: onPill, fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ),
            ),
            Text(
              order.address.trim().isEmpty ? 'No address was given' : order.address.trim(),
              style: theme.textTheme.bodyMedium?.copyWith(color: order.address.trim().isEmpty ? scheme.error : null),
            ),
            if (progress.isNotEmpty || expected != null)
              Text.rich(
                TextSpan(
                  children: [
                    if (progress.isNotEmpty) TextSpan(text: progress),
                    if (progress.isNotEmpty && expected != null) const TextSpan(text: ' · '),
                    if (expected != null)
                      TextSpan(
                        text: expected,
                        style: TextStyle(color: scheme.primary, fontWeight: FontWeight.w700),
                      ),
                  ],
                ),
                key: ValueKey('shipday-progress-${order.id}'),
                style: theme.textTheme.bodyMedium,
              ),
            // what a driver needs on the way; of one that finished, who had it and how it ended is enough
            if (facts.isNotEmpty && !order.finished) Text(facts, style: small),
            if (order.note.trim().isNotEmpty && !order.finished) Text(order.note.trim(), style: small),
            // the check it is on the POS, which opens with a tap, and the number Shipday's apps show it by
            Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (check != null)
                  TextButton.icon(
                    key: ValueKey('shipday-check-${order.id}'),
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    onPressed: () => onOpen(check),
                    icon: const Icon(Icons.receipt_long_outlined, size: 18),
                    label: Text(check.words),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      'Not on the POS',
                      key: ValueKey('shipday-nocheck-${order.id}'),
                      style: theme.textTheme.labelLarge?.copyWith(color: soft),
                    ),
                  ),
                Text(
                  [
                    if (order.number.isNotEmpty) 'Shipday no. ${order.number}',
                    if (check != null && check.by == 'phone') 'matched by phone number',
                  ].join(' · '),
                  style: small,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
