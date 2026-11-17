import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../live.dart';
import '../local_order.dart';
import '../orders_ahead.dart';
import '../takeout.dart';
import 'theme.dart';

/// Orders ahead (docs/catering.md): every to-go order a customer named a time for that has not been handed
/// over, by the day it is for. Each says when and for whom, what its event needs, its dishes, and the
/// money: what it comes to, what was paid on it (a deposit) and what is still to collect. An order nobody
/// sent says so, since no ticket prints for it when its time comes. Each day adds its orders up. A tap on
/// an order opens it.
///
/// It reads the list when the hub says an order changed, and now and then while the hub cannot say. With
/// the hub away it keeps its last picture and says it may be behind.
class OrdersAheadScreen extends StatefulWidget {
  const OrdersAheadScreen({super.key, required this.api, required this.onOpen});

  final PosApi api;

  /// Opens the order tapped; the list is read again when it comes back.
  final Future<void> Function(String orderId) onOpen;

  @override
  State<OrdersAheadScreen> createState() => _OrdersAheadScreenState();
}

class _OrdersAheadScreenState extends State<OrdersAheadScreen> {
  OrdersAhead? _list;
  bool _read = false; // the hub answered once
  bool _old = false; // a hub from before the list
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
    try {
      final list = await widget.api.ordersAhead();
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

  Future<void> _open(AheadOrder order) async {
    await widget.onOpen(order.orderId);
    if (mounted) unawaited(_reader.now());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final list = _list;
    final Widget body;
    if (_old) {
      body = const _Says('This hub does not list the orders ahead yet. Update the hub.');
    } else if (list == null) {
      body = _away ? const _Says('The hub is not answering.') : const Center(child: CircularProgressIndicator());
    } else if (list.days.isEmpty) {
      body = const _Says('No orders are waiting for a later time.', key: ValueKey('ahead-none'));
    } else {
      body = ListView(
        key: const ValueKey('ahead-list'),
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
        children: [
          for (final day in list.days) ...[
            _DayHead(key: ValueKey('ahead-day:${day.day}'), heading: list.heading(day), day: day),
            for (final order in day.orders)
              _AheadCard(key: ValueKey('ahead:${order.orderId}'), order: order, onTap: () => _open(order)),
          ],
        ],
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Orders ahead')),
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
                        key: const ValueKey('ahead-away'),
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

/// A day's heading: the day, how many orders and guests, and what its orders add up to.
class _DayHead extends StatelessWidget {
  const _DayHead({super.key, required this.heading, required this.day});

  final String heading;
  final AheadDay day;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final orders = day.orders.length;
    final faint = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant, fontFeatures: PosTheme.tabular);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 14, 4, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // the day and its count wrap apart on a narrow phone with large type
          Wrap(
            spacing: 10,
            crossAxisAlignment: WrapCrossAlignment.end,
            children: [
              Text(heading, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
              Text(
                [
                  orders == 1 ? '1 order' : '$orders orders',
                  if (day.guests > 0) day.guests == 1 ? '1 guest' : '${day.guests} guests',
                ].join(' · '),
                style: faint,
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            [
              'Total \$${day.total}',
              if (cents(day.paid) > 0) 'paid \$${day.paid}',
              if (cents(day.paid) > 0) 'due \$${day.due}',
            ].join(' · '),
            key: ValueKey('ahead-day-money:${day.day}'),
            style: faint,
          ),
        ],
      ),
    );
  }
}

/// One order: its time and whose it is with what it comes to, what its event needs, its dishes, and the
/// money paid and due. Everything under the first line wraps, so nothing is cut on a phone.
class _AheadCard extends StatelessWidget {
  const _AheadCard({super.key, required this.order, required this.onTap});

  final AheadOrder order;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final posColors = PosColors.of(context);
    final faint = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final paid = cents(order.paid);
    final due = cents(order.due);
    final event = order.eventWords;
    final dishes = order.dishWords();
    final money = paid == 0
        ? 'Nothing paid'
        : due > 0
        ? 'Paid \$${order.paid} · due \$${order.due}'
        : 'Paid';
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    clockTime(order.promisedMs),
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      fontFeatures: PosTheme.tabular,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      [
                        order.customerName.isEmpty ? 'To go' : order.customerName,
                        if (order.channel.isNotEmpty) channelLabel(order.channel).toLowerCase(),
                        if (order.orderNo != null) '#${order.orderNo}',
                      ].join(' · '),
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '\$${order.total}',
                    style: theme.textTheme.titleMedium?.copyWith(fontFeatures: PosTheme.tabular),
                  ),
                ],
              ),
              if (event.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(event, key: ValueKey('ahead-event:${order.orderId}'), style: theme.textTheme.bodyMedium),
                ),
              if (order.phone.isNotEmpty || dishes.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    [if (dishes.isNotEmpty) dishes, if (order.phone.isNotEmpty) order.phone].join(' · '),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: faint,
                  ),
                ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (order.dishes == 0)
                    _Mark('No dishes yet', posColors.timerWarn, posColors.timerWarnText)
                  else if (order.unsent > 0)
                    _Mark(
                      order.unsent == order.dishes ? 'Not sent' : '${order.unsent} not sent',
                      posColors.timerLate,
                      posColors.timerLateText,
                      key: ValueKey('ahead-unsent:${order.orderId}'),
                    ),
                  if (order.stage == 'ready') _Mark('Ready', posColors.fired, posColors.firedText),
                  Text(
                    money,
                    key: ValueKey('ahead-money:${order.orderId}'),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: due > 0 && paid > 0 ? FontWeight.w700 : null,
                      fontFeatures: PosTheme.tabular,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Mark extends StatelessWidget {
  const _Mark(this.words, this.fill, this.text, {super.key});

  final String words;
  final Color fill;
  final Color text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(8)),
    child: Text(
      words,
      style: Theme.of(context).textTheme.labelMedium?.copyWith(color: text, fontWeight: FontWeight.w700),
    ),
  );
}
