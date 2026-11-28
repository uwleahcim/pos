import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../live.dart';
import '../shipday.dart';
import '../takeout.dart' show clockTime;
import 'theme.dart';

/// Shipday on one screen (docs/shipday.md): the drivers who are on shift with how much each has, and the
/// deliveries Shipday has, by how far along they are: the ones nobody has yet, the ones a driver was given,
/// the ones on their way, and under a fold the ones that finished today. Beside each delivery is the check
/// it is on the POS, which a tap opens; one the hub finds no check for says so.
///
/// A delivery nobody has is given to a driver here, one a driver has not picked up yet is taken back, and
/// one is marked as it goes (started, picked up, delivered, ...): each by a tap that says so, on a hub that
/// does it ([ShipdayBoard.givesToDrivers], [ShipdayBoard.marks]). The hub reads Shipday's list before it
/// sends anything and again after, and the screen says what came of it.
///
/// It reads the hub's picture when the hub says it changed (or a check did, which may be the one a
/// delivery is), and now and then while the hub cannot say. Every read tells the hub that somebody is
/// looking, which makes it ask Shipday oftener. With the hub away it keeps its last picture and says it
/// may be behind.
class ShipdayScreen extends StatefulWidget {
  const ShipdayScreen({super.key, required this.api, required this.onOpen, this.board, this.staffId});

  final PosApi api;

  /// Who is signed in: the one who asks for a change in Shipday. Without one nothing is offered.
  final String? staffId;

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
  final _changing = <int>{}; // the deliveries a change is under way for
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

  /// Who takes it: a driver is picked, and the delivery is given to them in Shipday.
  Future<void> _give(ShipdayOrder order) async {
    final board = _board;
    if (board == null) return;
    final driver = await ShipdayDriverPicker.ask(context, order: order, board: board);
    if (driver == null || !mounted) return;
    await _change(
      order,
      (staffId) => widget.api.shipdayGive(order.id, driver.id, staffId: staffId),
      'Given to ${driver.called}.',
    );
  }

  /// Taken back from the driver who has it, after a tap that says so: nobody has it then.
  Future<void> _takeBack(ShipdayOrder order) async {
    final driver = order.driver;
    if (driver == null) return;
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const ValueKey('shipday-back'),
        title: Text('Take it back from ${driver.called}?'),
        content: Text(
          "${order.title}'s delivery goes back to Need a driver. Shipday tells ${driver.called}.",
          key: const ValueKey('shipday-back-words'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(
            key: const ValueKey('shipday-back-yes'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Take it back'),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    await _change(
      order,
      (staffId) => widget.api.shipdayTakeBack(order.id, driver.id, staffId: staffId),
      'Taken back from ${driver.called}. Nobody has it now.',
    );
  }

  /// Marked as it goes: one of the steps the hub lists for it is picked, and Shipday is told. A mark that
  /// ends the delivery (delivered, failed, incomplete) asks first: it cannot be taken back from here.
  Future<void> _mark(ShipdayOrder order) async {
    final step = await ShipdayStepPicker.ask(context, order: order);
    if (step == null || !mounted) return;
    if (shipdayEnds.contains(step)) {
      final as = shipdayStateWords(step).toLowerCase();
      final sure = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          key: const ValueKey('shipday-end'),
          title: Text('Mark it $as?'),
          content: Text(
            "${order.title}'s delivery leaves Shipday's active deliveries as ${shipdayStateWords(step)}. "
            'That cannot be taken back from the POS.',
            key: const ValueKey('shipday-end-words'),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
            FilledButton(
              key: const ValueKey('shipday-end-yes'),
              onPressed: () => Navigator.of(context).pop(true),
              child: Text('Mark $as'),
            ),
          ],
        ),
      );
      if (sure != true || !mounted) return;
    }
    await _change(
      order,
      (staffId) => widget.api.shipdayMark(order.id, step, was: order.state, staffId: staffId),
      shipdayMarkedWords(step),
    );
  }

  /// One change in Shipday that a tap asked for: the hub is asked, the screen takes the picture it answers
  /// with, and says what came of it.
  Future<void> _change(ShipdayOrder order, Future<ShipdayChanged> Function(String staffId) ask, String did) async {
    final staffId = widget.staffId;
    if (staffId == null || _changing.contains(order.id)) return;
    setState(() => _changing.add(order.id));
    String words;
    var bad = false;
    try {
      final changed = await ask(staffId);
      if (!mounted) return;
      final board = changed.board;
      if (board != null) setState(() => _board = board);
      final now = board?.orders.where((each) => each.id == order.id).firstOrNull;
      words = changed.words(did, order: now);
      bad = changed.bad;
    } on ApiException catch (err) {
      if (!mounted) return;
      bad = true;
      words = switch ((err.status, err.detail?['error'])) {
        (409, _) => 'This hub has no key for Shipday. Nothing was changed.',
        (404, 'unknown_staff') => 'The hub does not know who is signed in. Nothing was changed.',
        (404 || 405, _) => 'This hub only reads Shipday. Update it first (sudo hubctl update).',
        (null, _) => 'The hub did not answer. Look at the list before trying again: it may have been done.',
        _ => 'Nothing was changed: ${err.message}.',
      };
    } finally {
      if (mounted) setState(() => _changing.remove(order.id));
    }
    if (!mounted) return;
    final scheme = Theme.of(context).colorScheme;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          key: const ValueKey('shipday-said'),
          backgroundColor: bad ? scheme.errorContainer : null,
          duration: Duration(seconds: bad ? 8 : 4),
          content: Text(
            words,
            key: const ValueKey('shipday-said-words'),
            style: bad ? TextStyle(color: scheme.onErrorContainer) : null,
          ),
        ),
      );
    unawaited(_reader.now());
  }

  List<Widget> _cards(List<ShipdayOrder> orders) {
    final acts = widget.staffId != null && (_board?.givesToDrivers ?? false);
    final marks = widget.staffId != null && (_board?.marks ?? false);
    return [
      for (final order in orders)
        _DeliveryCard(
          key: ValueKey('shipday-order-${order.id}'),
          order: order,
          onOpen: _open,
          onGive: acts && order.canBeGiven ? () => _give(order) : null,
          onTakeBack: acts && order.canBeTakenBack ? () => _takeBack(order) : null,
          onMark: marks && order.canBeMarked ? () => _mark(order) : null,
          busy: _changing.contains(order.id),
        ),
    ];
  }

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
            if (board.givesToDrivers && board.marks)
              "A delivery is given to a driver and marked as it goes (picked up, delivered) here or in Shipday's "
                  'own app. A mark made by mistake is put right in Shipday.'
            else if (board.marks)
              "A delivery is marked as it goes (picked up, delivered) here or in Shipday's own app, and given to "
                  "a driver in Shipday's app."
            else if (board.givesToDrivers)
              "A delivery is given to a driver here or in Shipday's own app. It is marked as it goes (picked up, "
                  "delivered) in Shipday's app for now."
            else
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
/// and the check it is on the POS. One nobody has can be given to a driver, one a driver has not picked up
/// can be taken back, and one can be marked as it goes, where the screen lets it ([onGive], [onTakeBack],
/// [onMark]).
class _DeliveryCard extends StatelessWidget {
  const _DeliveryCard({
    super.key,
    required this.order,
    required this.onOpen,
    this.onGive,
    this.onTakeBack,
    this.onMark,
    this.busy = false,
  });

  final ShipdayOrder order;
  final Future<void> Function(ShipdayCheck check) onOpen;

  /// Opens the list of drivers to give it to one; null where it cannot be given.
  final VoidCallback? onGive;

  /// Asks whether to take it back from its driver; null where it cannot be.
  final VoidCallback? onTakeBack;

  /// Opens what it can be marked as from where it stands; null where it cannot be marked.
  final VoidCallback? onMark;

  /// A change is under way for it: the hub is asking Shipday.
  final bool busy;

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
                if (busy)
                  Padding(
                    key: ValueKey('shipday-busy-${order.id}'),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                        const SizedBox(width: 8),
                        Text('Asking Shipday…', style: theme.textTheme.labelLarge?.copyWith(color: soft)),
                      ],
                    ),
                  )
                else ...[
                  if (onGive != null)
                    FilledButton.tonalIcon(
                      key: ValueKey('shipday-give-${order.id}'),
                      style: FilledButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                      ),
                      onPressed: onGive,
                      icon: const Icon(Icons.person_add_alt_1_outlined, size: 18),
                      label: const Text('Give to a driver'),
                    ),
                  if (onMark != null)
                    // the step a delivery with a driver takes next is what is mostly wanted: it stands out
                    // there, and is quiet on one that waits for a driver first
                    onGive == null
                        ? FilledButton.tonalIcon(
                            key: ValueKey('shipday-mark-${order.id}'),
                            style: FilledButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              padding: const EdgeInsets.symmetric(horizontal: 12),
                            ),
                            onPressed: onMark,
                            icon: const Icon(Icons.flag_outlined, size: 18),
                            label: const Text('Mark…'),
                          )
                        : TextButton.icon(
                            key: ValueKey('shipday-mark-${order.id}'),
                            style: TextButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              padding: const EdgeInsets.symmetric(horizontal: 8),
                            ),
                            onPressed: onMark,
                            icon: const Icon(Icons.flag_outlined, size: 18),
                            label: const Text('Mark…'),
                          ),
                  if (onTakeBack != null)
                    TextButton.icon(
                      key: ValueKey('shipday-take-${order.id}'),
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                      onPressed: onTakeBack,
                      icon: const Icon(Icons.undo, size: 18),
                      label: const Text('Take it back'),
                    ),
                ],
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

/// Who takes it: the drivers who are on shift in Shipday, as buttons, each with how many deliveries they
/// have that are not finished, the one with the least first. A tap on a name gives the delivery to that
/// driver. Like the POS's own picker for its own deliveries (`DriverPicker`), with Shipday's drivers.
class ShipdayDriverPicker extends StatelessWidget {
  const ShipdayDriverPicker({super.key, required this.order, required this.board});

  final ShipdayOrder order;
  final ShipdayBoard board;

  /// Asks, and answers who was tapped: null when nobody was.
  static Future<ShipdayDriver?> ask(BuildContext context, {required ShipdayOrder order, required ShipdayBoard board}) =>
      showDialog<ShipdayDriver>(
        context: context,
        builder: (_) => ShipdayDriverPicker(order: order, board: board),
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final quiet = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final working = board.onShift;
    final off = board.offShift;
    return AlertDialog(
      key: const ValueKey('shipday-picker'),
      title: const Text('Who takes it?'),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                [order.title, if (order.address.trim().isNotEmpty) order.address.trim()].join(' · '),
                key: const ValueKey('shipday-picker-order'),
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 12),
              if (working.isEmpty)
                Text(
                  "No driver is on shift in Shipday. A driver goes on shift in Shipday's own app.",
                  key: const ValueKey('shipday-picker-none'),
                  style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                )
              else
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final driver in working)
                      _PickTile(
                        key: ValueKey('shipday-pick-${driver.id}'),
                        driver: driver,
                        onTap: () => Navigator.of(context).pop(driver),
                      ),
                  ],
                ),
              const SizedBox(height: 12),
              Text(
                [
                  if (working.isNotEmpty) 'A tap gives it to that driver, and Shipday tells them.',
                  if (off.isNotEmpty)
                    'Off shift: ${[for (final driver in off.take(8)) driver.called].join(', ')}'
                        '${off.length > 8 ? ' and ${off.length - 8} more' : ''}.',
                ].join(' '),
                key: const ValueKey('shipday-picker-hint'),
                style: quiet,
              ),
            ],
          ),
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel'))],
    );
  }
}

/// What a delivery is marked as: the steps the hub lists for it from where it stands, as buttons, in the
/// order a delivery goes, each in the word Shipday's own apps show for it. The ones that say it will not be
/// delivered stand apart. A tap answers the step; nothing is sent from here.
class ShipdayStepPicker extends StatelessWidget {
  const ShipdayStepPicker({super.key, required this.order});

  final ShipdayOrder order;

  /// Asks, and answers the step that was tapped (Shipday's own word): null when none was.
  static Future<String?> ask(BuildContext context, {required ShipdayOrder order}) => showDialog<String>(
    context: context,
    builder: (_) => ShipdayStepPicker(order: order),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final quiet = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    const bad = {'FAILED_DELIVERY', 'INCOMPLETE'};
    final along = [
      for (final step in order.steps)
        if (!bad.contains(step)) step,
    ];
    final not = [
      for (final step in order.steps)
        if (bad.contains(step)) step,
    ];
    final ends = [
      for (final step in order.steps)
        if (shipdayEnds.contains(step)) step,
    ];
    final who = order.driver?.called;
    Widget tile(String step) => _StepTile(
      key: ValueKey('shipday-step-$step'),
      words: shipdayStateWords(step),
      bad: bad.contains(step),
      strong: step == 'ALREADY_DELIVERED',
      onTap: () => Navigator.of(context).pop(step),
    );
    return AlertDialog(
      key: const ValueKey('shipday-steps'),
      title: const Text('Mark it as…'),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                [
                  order.title,
                  who == null ? 'nobody has it' : '$who has it',
                  'now: ${shipdayStateWords(order.state).toLowerCase()}',
                ].join(' · '),
                key: const ValueKey('shipday-steps-order'),
                style: theme.textTheme.bodyMedium,
              ),
              if (along.isNotEmpty) ...[
                const SizedBox(height: 12),
                Wrap(spacing: 8, runSpacing: 8, children: [for (final step in along) tile(step)]),
              ],
              if (not.isNotEmpty) ...[
                const SizedBox(height: 14),
                Text('It will not be delivered:', style: quiet),
                const SizedBox(height: 6),
                Wrap(spacing: 8, runSpacing: 8, children: [for (final step in not) tile(step)]),
              ],
              const SizedBox(height: 12),
              Text(
                [
                  if (along.any((step) => !shipdayEnds.contains(step)))
                    "A tap marks it in Shipday at once, as the driver's app does.",
                  if (ends.isNotEmpty)
                    '${[for (final step in ends) shipdayStateWords(step)].join(', ')} '
                        '${ends.length == 1 ? 'ends the delivery and asks' : 'end the delivery and ask'} first.',
                ].join(' '),
                key: const ValueKey('shipday-steps-hint'),
                style: quiet,
              ),
            ],
          ),
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel'))],
    );
  }
}

class _StepTile extends StatelessWidget {
  const _StepTile({super.key, required this.words, required this.onTap, this.bad = false, this.strong = false});

  final String words;
  final VoidCallback onTap;

  /// It says the delivery will not be made.
  final bool bad;

  /// It says the delivery was made.
  final bool strong;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (fill, ink, edge) = bad
        ? (scheme.surface, scheme.error, scheme.error)
        : strong
        ? (scheme.primaryContainer, scheme.onPrimaryContainer, scheme.primaryContainer)
        : (scheme.surfaceContainerLow, scheme.onSurface, scheme.outlineVariant);
    return Material(
      color: fill,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: edge),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 104, minHeight: 52),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Flexible(
                  child: Text(
                    words,
                    style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700, color: ink),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PickTile extends StatelessWidget {
  const _PickTile({super.key, required this.driver, required this.onTap});

  final ShipdayDriver driver;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 104, minHeight: 52),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(driver.called, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                Text(
                  driver.orders == 0 ? 'free' : '${driver.orders} out',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontFeatures: PosTheme.tabular,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
