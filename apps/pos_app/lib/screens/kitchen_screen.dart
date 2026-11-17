import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../kitchen_screen.dart';
import '../live.dart';
import '../outbox.dart';
import 'theme.dart';

/// A station's screen (docs/kitchen-screens.md): the tickets the station still has to make, the longest in
/// the kitchen first, each in the words its paper ticket uses and coloured by how long it has waited. A
/// cook taps a dish when it is made, or Done for the whole ticket; a finished ticket leaves, and Recall
/// brings one of the last ones back.
///
/// Nobody is signed in on it. A mark is the kitchen's own word on the order: it goes through the outbox like
/// every other change, so a tap is never lost, and it changes no dish, price or payment.
///
/// It reads its tickets when the hub says an order changed, and now and then while the hub cannot say. With
/// the hub away it keeps its last picture and says it may be behind. It stands where the sign-in pad does,
/// over a locked screen too, so it opens nothing over itself: no dialog, no sheet, no tooltip.
class KitchenScreen extends StatefulWidget {
  const KitchenScreen({
    super.key,
    required this.api,
    required this.outbox,
    required this.stations,
    this.onStaff,
    this.now = DateTime.now,
  });

  final PosApi api;
  final Outbox outbox;

  /// The stations this screen stands at, by their codes.
  final List<String> stations;

  /// One of the staff wants the sign-in pad.
  final VoidCallback? onStaff;
  final DateTime Function() now;

  @override
  State<KitchenScreen> createState() => _KitchenScreenState();
}

class _KitchenScreenState extends State<KitchenScreen> {
  KitchenBoard? _hub; // the board as the hub last said it
  KitchenBoard _board = const KitchenBoard(); // the same with this screen's own marks laid over it
  bool _asked = false; // the hub answered once
  bool _old = false; // the hub is older than the screens
  bool _away = false; // the last read got no answer: the screen may be behind
  bool _recall = false; // looking at the last ones finished
  String _ages = ''; // every ticket's colour and minutes as drawn
  final _marked = <String>{}; // the orders this screen marked and the hub has not shown yet
  String _laid = ''; // its own marks as they were laid over the last picture
  late final _poll = SafetyPoll(widget.api.live);
  late final _reader = Paced(const Duration(seconds: 1), _read);
  StreamSubscription<LiveChange>? _live;
  Timer? _timer;
  Timer? _clock;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (_poll.due()) unawaited(_reader.now(must: false));
    });
    // the minutes: looked at now and then, drawn again only when one of them reads differently
    _clock = Timer.periodic(const Duration(seconds: 10), (_) {
      if (mounted && _said(_board) != _ages) setState(() => _ages = _said(_board));
    });
    _live = widget.api.live.changes.listen((change) {
      if (change.anyOrder) _reader();
    });
    widget.outbox.addListener(_onOutbox);
    unawaited(_reader.now());
  }

  /// This screen's marks the hub may not show yet, by name: what is laid over the picture.
  String get _own => [
    for (final orderId in _marked)
      for (final op in widget.outbox.localOps(orderId)) op['op_id'],
  ].join(' ');

  // A mark the hub refused is no longer this screen's to show: the dish is to make again.
  void _onOutbox() {
    if (mounted && _own != _laid) _draw();
  }

  @override
  void didUpdateWidget(KitchenScreen old) {
    super.didUpdateWidget(old);
    if (old.stations.join(',') != widget.stations.join(',')) unawaited(_reader.now());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _clock?.cancel();
    _live?.cancel();
    _reader.cancel();
    widget.outbox.removeListener(_onOutbox);
    super.dispose();
  }

  /// Each ticket's minutes, as the screen says them: what the clock alone can change.
  String _said(KitchenBoard board) {
    final now = widget.now();
    return [for (final ticket in board.tickets) '${ticket.id}:${ticket.minutes(now)}'].join(' ');
  }

  Future<void> _read() async {
    _poll.asked();
    final mark = widget.outbox.readMark;
    try {
      final board = await widget.api.kitchenScreen(widget.stations);
      if (!mounted) return;
      // what this screen marked before the read began is in it: no longer its own to lay over
      var settled = false;
      for (final orderId in _marked.toList()) {
        if (widget.outbox.seen(orderId, mark)) settled = true;
        if (widget.outbox.localOps(orderId).isEmpty) _marked.remove(orderId);
      }
      final news = !identical(board, _hub) || settled || !_asked || _away || _old != (board == null);
      _hub = board;
      _asked = true;
      _old = board == null;
      _away = false;
      if (news) _draw();
    } on ApiException {
      if (mounted && !_away) setState(() => _away = true);
    }
  }

  void _draw() {
    final now = widget.now();
    final board = (_hub ?? const KitchenBoard()).withLocal(widget.outbox.localOps, nowMs: now.millisecondsSinceEpoch);
    _laid = _own;
    setState(() {
      _board = board;
      _ages = _said(board);
      if (board.recent.isEmpty) _recall = false;
    });
  }

  /// Says these dishes of a ticket are made, or takes that back. Drawn at once; the hub hears as soon as it
  /// can.
  Future<void> _mark(KitchenTicket ticket, Iterable<KitchenLine> lines, {required bool made}) async {
    final ops = markOps(lines, made: made);
    if (ops.isEmpty) return;
    _marked.add(ticket.orderId);
    await widget.outbox.addAll(ticket.orderId, ops);
    if (mounted) _draw();
  }

  /// A tap on a dish: made, or not after all. A dish of several parts is one dish: all of them go together.
  void _tapped(KitchenTicket ticket, KitchenLine line) {
    final whole = [
      for (final other in ticket.lines)
        if (other.lineId == line.lineId) other,
    ];
    unawaited(_mark(ticket, whole, made: !line.done));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final board = _board;
    final now = widget.now();
    final names = board.title.isNotEmpty ? board.title : widget.stations.join(' · ');
    final shown = _recall ? board.recent : board.tickets;
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, box) {
            final narrow = box.maxWidth < 520;
            // as many columns as fit tickets a cook can read from where the food is: one on a phone
            final columns = (box.maxWidth / 300).floor().clamp(1, 6);
            const gap = 10.0;
            // (whole pixels, so the last ticket of a row is never a hair too wide for it)
            final width = ((box.maxWidth - gap * (columns + 1)) / columns).floorToDouble();
            final count = board.tickets.length;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 4, 4, 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Row(
                          children: [
                            Flexible(
                              child: Text(
                                _recall ? 'Finished at $names' : names,
                                key: const ValueKey('kitchen-title'),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                              ),
                            ),
                            if (!_recall) ...[
                              const SizedBox(width: 10),
                              if (narrow)
                                // (no room for the words beside large text: the number, in a pill)
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
                                  decoration: BoxDecoration(
                                    color: scheme.surfaceContainerHighest,
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Text(
                                    '$count',
                                    key: const ValueKey('kitchen-count'),
                                    semanticsLabel: count == 1 ? '1 ticket' : '$count tickets',
                                    style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
                                  ),
                                )
                              else
                                Text(
                                  count == 1 ? '1 ticket' : '$count tickets',
                                  key: const ValueKey('kitchen-count'),
                                  maxLines: 1,
                                  style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                                ),
                            ],
                          ],
                        ),
                      ),
                      if (_recall)
                        TextButton.icon(
                          key: const ValueKey('kitchen-back'),
                          icon: const Icon(Icons.arrow_back),
                          label: const Text('Back'),
                          onPressed: () => setState(() => _recall = false),
                        )
                      else if (board.recent.isNotEmpty && narrow)
                        IconButton(
                          key: const ValueKey('kitchen-recall'),
                          icon: const Icon(Icons.history, semanticLabel: 'Recall'),
                          onPressed: () => setState(() => _recall = true),
                        )
                      else if (board.recent.isNotEmpty)
                        TextButton.icon(
                          key: const ValueKey('kitchen-recall'),
                          icon: const Icon(Icons.history),
                          label: const Text('Recall'),
                          onPressed: () => setState(() => _recall = true),
                        ),
                      if (widget.onStaff != null)
                        TextButton(
                          key: const ValueKey('kitchen-staff'),
                          style: TextButton.styleFrom(foregroundColor: scheme.onSurfaceVariant),
                          onPressed: widget.onStaff,
                          child: const Text('Staff'),
                        ),
                    ],
                  ),
                ),
                if (_away)
                  Container(
                    key: const ValueKey('kitchen-away'),
                    color: scheme.errorContainer,
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                    child: Text(
                      'This screen may be behind: the hub is not answering.',
                      style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onErrorContainer),
                    ),
                  ),
                Divider(height: 1, color: scheme.outlineVariant),
                Expanded(
                  child: shown.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(
                              _old
                                  ? 'This hub is older than the kitchen screens. Update the hub and the tickets '
                                        'show here.'
                                  : !_asked
                                  ? (_away ? 'The hub is not answering yet.' : '')
                                  : 'Nothing to make right now.',
                              key: const ValueKey('kitchen-none'),
                              textAlign: TextAlign.center,
                              style: theme.textTheme.titleMedium?.copyWith(color: scheme.onSurfaceVariant),
                            ),
                          ),
                        )
                      : SingleChildScrollView(
                          padding: const EdgeInsets.fromLTRB(gap, gap, gap, 0),
                          // Across, then down: the first ticket of each column is the oldest of its row.
                          // Each column packs its own, so a short ticket leaves no gap under it.
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              for (var column = 0; column < columns; column++) ...[
                                if (column > 0) const SizedBox(width: gap),
                                SizedBox(
                                  width: width,
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      for (var i = column; i < shown.length; i += columns)
                                        Padding(
                                          padding: const EdgeInsets.only(bottom: gap),
                                          child: KeyedSubtree(
                                            key: ValueKey('kitchen-ticket:${shown[i].id}'),
                                            child: _TicketCard(
                                              ticket: shown[i],
                                              // one screen for two stations: each dish says whose it is
                                              stations: board.stations.length > 1
                                                  ? {for (final station in board.stations) station.code: station.name}
                                                  : const {},
                                              age: _recall ? TicketAge.fresh : board.age(shown[i], now),
                                              minutes: shown[i].minutes(now),
                                              finished: _recall,
                                              onLine: _recall ? null : (line) => _tapped(shown[i], line),
                                              onAll: () => unawaited(_mark(shown[i], shown[i].lines, made: !_recall)),
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// One ticket: whose it is and for how long, what the cook must know first (an allergy), and its dishes.
class _TicketCard extends StatelessWidget {
  const _TicketCard({
    required this.ticket,
    required this.stations,
    required this.age,
    required this.minutes,
    required this.finished,
    required this.onLine,
    required this.onAll,
  });

  final KitchenTicket ticket;

  /// The screen's stations by name, when it stands for more than one; empty on a screen for one.
  final Map<String, String> stations;
  final TicketAge age;
  final int minutes;

  /// Among the last ones finished: the button brings it back.
  final bool finished;
  final void Function(KitchenLine line)? onLine;
  final VoidCallback onAll;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = PosColors.of(context);
    final (fill, ink) = switch (age) {
      TicketAge.late => (colors.timerLate, colors.timerLateText),
      TicketAge.warn => (colors.timerWarn, colors.timerWarnText),
      TicketAge.fresh => (scheme.surfaceContainerHighest, scheme.onSurface),
    };
    final edge = age == TicketAge.fresh ? scheme.outlineVariant : fill;
    final detail = ticket.detail;
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: edge, width: 2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            key: ValueKey('kitchen-head:${ticket.id}:${age.name}'),
            color: fill,
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        ticket.title,
                        style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800, color: ink),
                      ),
                      if (detail.isNotEmpty) Text(detail, style: theme.textTheme.bodySmall?.copyWith(color: ink)),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (!finished)
                  Text(
                    '$minutes min',
                    key: ValueKey('kitchen-age:${ticket.id}'),
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: ink,
                      fontFeatures: PosTheme.tabular,
                    ),
                  ),
              ],
            ),
          ),
          for (final told in ticket.allergies)
            Container(
              color: scheme.errorContainer,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              child: Row(
                children: [
                  Icon(Icons.warning_amber_rounded, size: 18, color: scheme.onErrorContainer),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Allergy · $told',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: scheme.onErrorContainer,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          if (ticket.alsoAt.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 10, 0),
              child: Text(
                'Also at: ${ticket.alsoAt.join(', ')}',
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
          const SizedBox(height: 2),
          for (final (index, line) in ticket.lines.indexed)
            _LineRow(
              key: ValueKey('kitchen-line:${ticket.id}:${line.lineId}:$index'),
              line: line,
              where: [for (final code in line.stations) stations[code] ?? code].join(', '),
              named: stations.isNotEmpty,
              onTap: onLine == null ? null : () => onLine!(line),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
            child: finished
                ? OutlinedButton.icon(
                    key: ValueKey('kitchen-bring-back:${ticket.id}'),
                    icon: const Icon(Icons.undo),
                    label: const Text('Bring back'),
                    onPressed: onAll,
                  )
                // green, as a dish that went to the kitchen is on the check: the one colour here that is good news
                : FilledButton.icon(
                    key: ValueKey('kitchen-done:${ticket.id}'),
                    style: FilledButton.styleFrom(
                      backgroundColor: colors.fired,
                      foregroundColor: colors.firedText,
                      side: BorderSide(color: colors.firedBorder),
                    ),
                    icon: const Icon(Icons.done_all),
                    label: const Text('Done'),
                    onPressed: onAll,
                  ),
          ),
        ],
      ),
    );
  }
}

/// A dish of a ticket, as the paper words it; a tap says it is made.
class _LineRow extends StatelessWidget {
  const _LineRow({super.key, required this.line, required this.where, required this.named, required this.onTap});

  final KitchenLine line;

  /// The stations of this screen that make it, by name; said when [named] (a screen for several stations).
  final String where;
  final bool named;
  final VoidCallback? onTap;

  static const indent = 12.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final made = line.done;
    final faint = scheme.onSurfaceVariant;
    final ink = made ? faint : scheme.onSurface;
    final struck = line.isVoid ? TextDecoration.lineThrough : null;
    Widget tag(String text, Color fill, Color on) => Container(
      margin: const EdgeInsets.only(right: 6),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(4)),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(color: on, fontWeight: FontWeight.w800),
      ),
    );
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 5, 10, 5),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 1, right: 8),
                child: Icon(
                  made ? Icons.check_circle : Icons.radio_button_unchecked,
                  size: 24,
                  color: made ? PosColors.of(context).firedBorder : scheme.outline,
                  semanticLabel: made ? 'Made' : 'To make',
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (line.isVoid || line.changed)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: Row(
                          children: [
                            // as the paper prints a void: white on black
                            if (line.isVoid) tag('VOID', scheme.inverseSurface, scheme.onInverseSurface),
                            if (line.changed) tag('CHANGED', scheme.tertiaryContainer, scheme.onTertiaryContainer),
                          ],
                        ),
                      ),
                    Text(
                      '${line.qty} × ${line.label}',
                      // (larger than a list's line: read from where the food is, not at arm's length)
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: ink,
                        decoration: struck,
                      ),
                    ),
                    if (line.header.isNotEmpty)
                      Text('with ${line.header}', style: theme.textTheme.bodySmall?.copyWith(color: faint)),
                    for (final (index, modifier) in line.modifiers.indexed)
                      Padding(
                        padding: EdgeInsets.only(left: (index < line.depths.length ? line.depths[index] : 0) * indent),
                        child: Text(
                          modifier,
                          style: theme.textTheme.bodyLarge?.copyWith(color: ink, decoration: struck),
                        ),
                      ),
                    if (line.note.isNotEmpty)
                      Text(
                        line.note,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: ink,
                          fontStyle: FontStyle.italic,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    if (line.allergy.isNotEmpty)
                      Text(
                        'Allergy: ${line.allergy}',
                        style: theme.textTheme.bodyMedium?.copyWith(color: scheme.error, fontWeight: FontWeight.w700),
                      ),
                  ],
                ),
              ),
              if (line.seat != null || named)
                Padding(
                  padding: const EdgeInsets.only(left: 6, top: 2),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      if (named)
                        Text(
                          where,
                          style: theme.textTheme.bodySmall?.copyWith(color: faint, fontWeight: FontWeight.w700),
                        ),
                      if (line.seat != null)
                        Text('Seat ${line.seat}', style: theme.textTheme.bodySmall?.copyWith(color: faint)),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
