import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../deliveries.dart';
import '../live.dart';
import '../local_order.dart';
import '../outbox.dart';
import '../roster.dart';
import '../session.dart';
import '../shipday.dart';
import '../takeout.dart';
import '../to_go_stages.dart';
import 'driver_picker.dart';
import 'hand_over.dart';
import 'runs_screen.dart';

/// The deliveries (docs/delivery.md): the orders that are brought to the customer, on one screen. At the
/// top the ones that have not left: tap the bags that are leaving together and hand them to a driver.
/// Under them, for each driver, what they have out, each with where it goes and the number to call, and
/// the two things that can become of it: it was delivered (the check closes, and money still due is asked
/// for first, as "Picked up" asks), or it came back.
///
/// A driver who is signed in sees their own bags first. Nothing here is about money beyond what the list
/// of checks already says of an order.
///
/// "Runs" in the bar opens what each driver took out over the day ([RunsScreen]).
///
/// It reads the open orders when the hub says one changed, and now and then while the hub cannot say. With
/// the hub away it keeps its last picture and says it may be behind; what is tapped here is queued like
/// any change to a check.
class DeliveriesScreen extends StatefulWidget {
  const DeliveriesScreen({
    super.key,
    required this.api,
    required this.outbox,
    required this.session,
    required this.roster,
    required this.onOpen,
    this.now = DateTime.now,
  });

  final PosApi api;
  final Outbox outbox;
  final Session session;

  /// The staff as the list of checks last read them: who a delivery can be handed to. Read again here.
  final Roster roster;

  /// Opens the order tapped; the deliveries are read again when it comes back.
  final Future<void> Function(String orderId) onOpen;
  final DateTime Function() now;

  @override
  State<DeliveriesScreen> createState() => _DeliveriesScreenState();
}

class _DeliveriesScreenState extends State<DeliveriesScreen> {
  List<Order> _orders = const [];
  Deliveries _deliveries = const Deliveries();
  late Roster _roster = widget.roster;
  final _leaving = <String>{}; // the waiting orders tapped to leave together
  String _drawn = ''; // what the screen says now, to tell whether it has to be drawn again
  bool _read = false; // the hub answered once
  bool _away = false; // the last read got no answer
  bool _busy = false; // a tap is being written
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
    unawaited(_readRoster());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _live?.cancel();
    _reader.cancel();
    super.dispose();
  }

  Future<void> _readRoster() async {
    try {
      final roster = await widget.api.staff();
      if (mounted) setState(() => _roster = roster);
    } on ApiException {
      // keeps what the list of checks read
    }
  }

  Future<void> _load() async {
    _poll.asked();
    try {
      // what this device wrote before the read began is in it: only what came after is laid on top
      final mark = widget.outbox.readMark;
      final orders = await widget.api.listOrders(status: 'open');
      if (!mounted) return;
      for (final order in orders) {
        widget.outbox.seen(order.orderId, mark);
      }
      _orders = orders;
      _read = true;
      _away = false;
    } on ApiException {
      if (!mounted) return;
      _away = true;
    }
    _draw();
  }

  /// Works out the deliveries, with what was tapped on this device and is not on the hub yet, and draws
  /// them again only when they read differently: a table's check changing is nothing to this screen.
  void _draw() {
    final now = widget.now();
    final deliveries = deliveriesOf([
      for (final order in _orders) withLocalOps(order, widget.outbox.localOps(order.orderId)),
    ], now);
    _leaving.removeWhere((id) => !deliveries.waiting.any((o) => o.orderId == id && canLeave(o, now)));
    final says = [
      _read,
      _away,
      _leaving.join(','),
      for (final o in deliveries.waiting)
        [
          o.orderId,
          o.orderNo,
          o.customerName,
          o.event.words,
          waitingWords(o, now),
          o.promisedAt,
          moneyWords(o),
          o.shipdaySays,
        ],
      for (final load in deliveries.out)
        for (final o in load.orders)
          [
            o.orderId,
            load.driverId,
            load.name,
            o.orderNo,
            o.customerName,
            o.event.words,
            o.outAt,
            moneyWords(o),
            o.shipdaySays,
          ],
    ].join('\x1e');
    if (says == _drawn) return;
    setState(() {
      _deliveries = deliveries;
      _drawn = says;
    });
  }

  String? get _by => widget.session.staff?.name;

  Map<String, dynamic> get _who => {'by': ?_by, 'by_id': ?widget.session.staff?.staffId};

  Future<void> _write(Future<void> Function() change) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await change();
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        _draw();
        unawaited(_reader.now());
      }
    }
  }

  /// The bags tapped leave together with whoever is picked: one run, so they carry the same moment.
  Future<void> _sendOut() async {
    final going = [
      for (final order in _deliveries.waiting)
        if (_leaving.contains(order.orderId)) order,
    ];
    if (going.isEmpty) return;
    final driver = await DriverPicker.ask(
      context,
      drivers: _roster.drivers,
      deliveries: _deliveries,
      bags: going.length,
    );
    if (driver == null || !mounted) return;
    final at = widget.now().millisecondsSinceEpoch;
    await _write(() async {
      for (final order in going) {
        await widget.outbox.addAll(order.orderId, [
          ('set_field', {...outFields(driver, at), ..._who}),
        ]);
      }
      _leaving.clear();
    });
    if (!mounted) return;
    final bags = going.length == 1 ? '#${going.single.orderNo ?? '…'}' : '${going.length} orders';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        key: const ValueKey('deliveries-said'),
        content: Text('$bags out with ${driver.name}.', key: const ValueKey('deliveries-said-words')),
      ),
    );
  }

  Future<void> _delivered(Order order) =>
      _write(() => setToGoStage(context, outbox: widget.outbox, order: order, stage: 'picked_up', by: _by));

  Future<void> _cameBack(Order order) => _write(
    () => widget.outbox.addAll(order.orderId, [
      ('set_field', {...backFields, ..._who}),
    ]),
  );

  Future<void> _open(Order order) async {
    await widget.onOpen(order.orderId);
    if (mounted) unawaited(_reader.now());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final now = widget.now();
    final deliveries = _deliveries;
    final me = widget.session.staff?.staffId;
    final waiting = [
      _Heading(
        key: const ValueKey('deliveries-waiting'),
        title: 'Waiting',
        count: deliveries.waiting.length,
        under: deliveries.waiting.isEmpty
            ? 'Nothing is waiting to leave.'
            : _leaving.isEmpty
            ? 'Tap the bags that are leaving, then hand them to a driver.'
            : null,
      ),
      for (final order in deliveries.waiting)
        _WaitingCard(
          key: ValueKey('waiting-${order.orderId}'),
          order: order,
          now: now,
          leaving: _leaving.contains(order.orderId),
          onTap: !canLeave(order, now) || _busy
              ? null
              : () {
                  setState(
                    () =>
                        _leaving.contains(order.orderId) ? _leaving.remove(order.orderId) : _leaving.add(order.orderId),
                  );
                  _draw();
                },
          onOpen: () => _open(order),
        ),
    ];
    final out = [
      _Heading(
        key: const ValueKey('deliveries-out'),
        title: 'Out',
        count: deliveries.outCount,
        under: deliveries.out.isEmpty ? 'No driver has anything out.' : null,
      ),
      for (final load in deliveries.mineFirst(me)) ...[
        Padding(
          key: ValueKey('driver-load:${load.driverId}'),
          padding: const EdgeInsets.fromLTRB(4, 10, 4, 4),
          child: Text(
            [
              load.driverId == me && me != null
                  ? 'You'
                  : load.name.isEmpty
                  ? 'No driver named'
                  : driverCalled(load.name, load.driverId),
              '${load.orders.length} out',
              if (load.since != null) 'since ${clockTime(load.since!)}',
            ].join(' · '),
            style: theme.textTheme.titleSmall,
          ),
        ),
        for (final order in load.orders)
          _OutCard(
            key: ValueKey('out-${order.orderId}'),
            order: order,
            busy: _busy,
            onDelivered: () => _delivered(order),
            onBack: () => _cameBack(order),
            onOpen: () => _open(order),
          ),
      ],
    ];
    return Scaffold(
      appBar: AppBar(
        title: const Text('Deliveries'),
        actions: [
          // what each driver took out over the day, bag by bag
          TextButton(
            key: const ValueKey('deliveries-runs'),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => RunsScreen(api: widget.api, session: widget.session),
              ),
            ),
            child: const Text('Runs'),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: !_read && !_away
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                if (_away)
                  Container(
                    key: const ValueKey('deliveries-away'),
                    width: double.infinity,
                    color: scheme.errorContainer,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                    child: Text(
                      'This list may be behind: the hub is not answering.',
                      style: theme.textTheme.bodySmall?.copyWith(color: scheme.onErrorContainer),
                    ),
                  ),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, box) {
                      // side by side where there is the width for two lists; one under the other on a phone
                      if (box.maxWidth >= 760) {
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 8, 96), children: waiting),
                            ),
                            Expanded(
                              child: ListView(padding: const EdgeInsets.fromLTRB(8, 8, 16, 96), children: out),
                            ),
                          ],
                        );
                      }
                      return ListView(
                        key: const ValueKey('deliveries-list'),
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
                        children: [...waiting, const SizedBox(height: 8), ...out],
                      );
                    },
                  ),
                ),
              ],
            ),
      // the one thing to do with the bags tapped, where a thumb reaches it
      floatingActionButton: _leaving.isEmpty
          ? null
          : FloatingActionButton.extended(
              key: const ValueKey('deliveries-send'),
              onPressed: _busy ? null : _sendOut,
              icon: const Icon(Icons.delivery_dining_outlined),
              label: Text(_leaving.length == 1 ? 'Out with…' : '${_leaving.length} out with…'),
            ),
    );
  }
}

/// The title of one of the two lists with how many are in it, and a line under it when there is one to say.
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
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 6),
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

/// What every card says of an order: its number and name, where it goes, and the note for the driver.
List<Widget> _whereTo(ThemeData theme, Order order) {
  final event = order.event;
  final soft = theme.colorScheme.onSurfaceVariant;
  return [
    Text(
      event.address.isEmpty ? 'No address was given' : event.address,
      style: theme.textTheme.bodyMedium?.copyWith(color: event.address.isEmpty ? theme.colorScheme.error : null),
    ),
    if (event.note.isNotEmpty) Text(event.note, style: theme.textTheme.bodySmall?.copyWith(color: soft)),
  ];
}

String _title(Order order) =>
    ['#${order.orderNo ?? '…'}', if (order.customerName.trim().isNotEmpty) order.customerName.trim()].join(' ');

/// What Shipday said of a delivery that its check does not say itself (docs/shipday.md, "Shipday moves the
/// check"): delivered while the check stays open for its money, failed, or picked up while the POS never sent
/// it out. Somebody has to do something about each, so it stands out from the grey of the line above.
List<Widget> _shipdaySays(ThemeData theme, Order order) => [
  if (order.shipdaySays case final said?)
    Text(
      said,
      key: ValueKey('shipday-says-${order.orderId}'),
      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.primary, fontWeight: FontWeight.w600),
    ),
];

/// A delivery that has not left: a tap picks it to leave (or lets it go again); the arrow opens the order.
class _WaitingCard extends StatelessWidget {
  const _WaitingCard({
    super.key,
    required this.order,
    required this.now,
    required this.leaving,
    required this.onTap,
    required this.onOpen,
  });

  final Order order;
  final DateTime now;
  final bool leaving;
  final VoidCallback? onTap;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final stage = waitingStage(order, now);
    final promised = order.promisedAt;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      color: leaving ? scheme.secondaryContainer : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: leaving ? scheme.secondary : scheme.outlineVariant, width: leaving ? 2 : 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2, right: 10),
                child: Icon(
                  leaving
                      ? Icons.check_circle
                      : onTap == null
                      ? Icons.schedule
                      : Icons.radio_button_unchecked,
                  color: leaving ? scheme.secondary : scheme.outline,
                  semanticLabel: leaving ? 'Leaving' : null,
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(_title(order), style: theme.textTheme.titleMedium),
                        Text(
                          waitingWords(order, now),
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: stage == Waiting.ready ? scheme.primary : scheme.onSurfaceVariant,
                            fontWeight: stage == Waiting.ready ? FontWeight.w800 : null,
                          ),
                        ),
                      ],
                    ),
                    ..._whereTo(theme, order),
                    Text(
                      [
                        if (promised != null && !order.forLater) 'there ${clockTime(promised)}',
                        moneyWords(order),
                      ].join(' · '),
                      style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                    ..._shipdaySays(theme, order),
                  ],
                ),
              ),
              IconButton(
                key: ValueKey('open-${order.orderId}'),
                tooltip: 'Open the order',
                onPressed: onOpen,
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A delivery that is out: where it goes, the number to call, when it left, and what became of it.
class _OutCard extends StatelessWidget {
  const _OutCard({
    super.key,
    required this.order,
    required this.busy,
    required this.onDelivered,
    required this.onBack,
    required this.onOpen,
  });

  final Order order;
  final bool busy;
  final VoidCallback onDelivered;
  final VoidCallback onBack;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final left = order.outAt;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_title(order), style: theme.textTheme.titleMedium),
                      ..._whereTo(theme, order),
                      Text(
                        [
                          if (order.phone.trim().isNotEmpty) order.phone.trim(),
                          if (left != null) 'left ${clockTime(left)}',
                          moneyWords(order),
                        ].join(' · '),
                        style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                      ..._shipdaySays(theme, order),
                    ],
                  ),
                ),
                IconButton(
                  key: ValueKey('open-${order.orderId}'),
                  tooltip: 'Open the order',
                  onPressed: onOpen,
                  icon: const Icon(Icons.chevron_right),
                ),
              ],
            ),
            // buttons that wrap: side by side they do not fit the narrowest phone with large type
            Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton.tonal(
                  key: ValueKey('delivered-${order.orderId}'),
                  onPressed: busy ? null : onDelivered,
                  child: const Text('Delivered'),
                ),
                TextButton(
                  key: ValueKey('back-${order.orderId}'),
                  onPressed: busy ? null : onBack,
                  child: const Text('Came back'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
