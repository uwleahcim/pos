import 'package:flutter/material.dart';

import '../api.dart';
import '../dish_names.dart';
import '../local_order.dart';
import '../menu.dart';
import '../split.dart';
import 'theme.dart';

/// The order and its check as the order screen has them at this moment, and whether a bill is on its way.
class SplitView {
  const SplitView({required this.order, required this.check, this.billing = false});

  final Order order;
  final Check? check;
  final bool billing;
}

/// Splitting a check: how the table pays. Three ways stand at the top as buttons: **By seat** (a check for
/// each seat in one tap, the table's dishes shared), **Evenly** (the total in equal parts) and **One check**.
/// Below, each check with its dishes and what it comes to. A tap picks a dish (any number of them); the foot
/// of the screen then offers where they go: a check there is, a new one, or shared between several.
///
/// The dishes stay on the one order: a dish that changes checks keeps its seat and the kitchen hears nothing.
/// Which dish is on which check shows at once, worked out here the hub's way; what a check comes to is the
/// hub's to say, and reads "…" until it has.
///
/// Where the location's tables have no seats ([bySeat] false) there are two ways at the top, Evenly and One
/// check: By seat is left out, unless dishes are on seats all the same (rung in before the switch).
class SplitScreen extends StatefulWidget {
  const SplitScreen({
    super.key,
    required this.changes,
    required this.read,
    required this.onOps,
    required this.onBill,
    this.bySeat = true,
  });

  /// Whether a table has seats here (the location's setting): By seat is offered.
  final bool bySeat;

  /// Tells when [read] has something new.
  final Listenable changes;
  final SplitView? Function() read;

  /// Appends these operations to the order.
  final Future<void> Function(List<SplitOp> ops) onOps;

  /// Prints the bill of one check (by number), or of every check of the table (null).
  final Future<void> Function(int? check) onBill;

  @override
  State<SplitScreen> createState() => _SplitScreenState();
}

class _SplitScreenState extends State<SplitScreen> {
  final _picked = <String>{}; // the dishes in hand, by line id

  Future<void> _send(List<SplitOp> ops) async {
    setState(_picked.clear);
    if (ops.isNotEmpty) await widget.onOps(ops);
  }

  List<Line> _inHand(Order order) => [
    for (final line in order.activeLines)
      if (_picked.contains(line.lineId)) line,
  ];

  /// The dishes in hand, shared between checks picked on a sheet: the checks there are, and as many new
  /// ones as are asked for.
  Future<void> _share(Order order, List<int> numbers) async {
    final lines = _inHand(order);
    if (lines.isEmpty) return;
    final placed = placedOn(order);
    final now = placed.on[lines.first.lineId] ?? numbers;
    final between = await showModalBottomSheet<List<int>>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _ShareSheet(numbers: numbers, selected: now.length > 1 ? now : numbers),
    );
    if (between == null || !mounted) return;
    await _send(putOps(order, lines, between));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.changes,
      builder: (context, _) {
        final view = widget.read();
        if (view == null) {
          return Scaffold(
            appBar: AppBar(title: const Text('Split the check')),
            body: const Center(child: CircularProgressIndicator()),
          );
        }
        final order = view.order;
        final check = view.check;
        final open = order.isOpen;
        final mode = splitOf(order);
        final placed = placedOn(order);
        final live = {for (final line in order.activeLines) line.lineId};
        _picked.removeWhere((id) => !live.contains(id)); // a dish another screen took off is in no hand
        // the checks to show: the split's, or the one check every dish is on
        final numbers = placed.isSplit ? placed.numbers : [placed.numbers.firstOrNull ?? 1];
        final seated = !order.isTakeout && order.activeLines.any((l) => l.seat != null);
        final count = checksOf(order);
        return Scaffold(
          appBar: AppBar(
            title: Text(
              order.isTakeout
                  ? 'Split the check'
                  : order.isTab
                  ? 'Split · ${order.tabLabel}'
                  : 'Split · Table ${order.table}',
            ),
          ),
          body: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
                child: Row(
                  children: [
                    if (!order.isTakeout && (widget.bySeat || seated)) ...[
                      Expanded(
                        child: _Way(
                          key: const ValueKey('split-by-seat'),
                          label: 'By seat',
                          icon: Icons.event_seat_outlined,
                          chosen: mode.by == 'seat' && placed.isSplit,
                          onTap: open && seated ? () => _send(bySeatOps(order)) : null,
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                    Expanded(
                      child: _Way(
                        key: const ValueKey('split-evenly'),
                        label: 'Evenly',
                        icon: Icons.drag_handle,
                        chosen: mode.isEven,
                        onTap: open && !mode.isEven ? () => _send(evenOps(order, _guests(order))) : null,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _Way(
                        key: const ValueKey('split-one'),
                        label: 'One check',
                        icon: Icons.receipt_outlined,
                        chosen: count == 1,
                        onTap: open && count > 1 ? () => _send(oneCheckOps(order)) : null,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: mode.isEven
                    ? _EvenParts(
                        ways: mode.ways,
                        check: check,
                        onWays: open ? (ways) => _send(evenOps(order, ways)) : null,
                        onBill: view.billing ? null : widget.onBill,
                      )
                    : _checks(context, view, placed, numbers, seated),
              ),
              _foot(context, view, numbers, count),
            ],
          ),
        );
      },
    );
  }

  /// How many parts an even split starts with: the party, or two.
  int _guests(Order order) {
    final guests = order.fields['guests'];
    return guests is int && guests >= 2 ? guests.clamp(2, maxChecks) : 2;
  }

  /// The checks side by side on a wide screen, one under the other on a phone.
  Widget _checks(BuildContext context, SplitView view, Placed placed, List<int> numbers, bool seated) {
    final order = view.order;
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = 10.0;
        final across = (constraints.maxWidth / 340).floor().clamp(1, numbers.length.clamp(1, 4));
        final width = (constraints.maxWidth - 24 - gap * (across - 1)) / across;
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (order.isOpen && !placed.isSplit)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    order.isTakeout || seated || !widget.bySeat
                        ? 'Tap dishes to pick them, then put them on a new check or share them.'
                        : 'Tap dishes to pick them, then put them on a new check or share them. '
                              'By seat needs dishes rung in on seats.',
                    style: hint,
                  ),
                ),
              Wrap(
                spacing: gap,
                runSpacing: gap,
                children: [
                  for (final number in numbers)
                    SizedBox(width: width, child: _card(context, view, placed, number, numbers)),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  /// One check: its number and what it comes to, a button for its own bill, and its dishes. A shared dish
  /// shows with this check's part of it.
  Widget _card(BuildContext context, SplitView view, Placed placed, int number, List<int> numbers) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final order = view.order;
    final check = view.check;
    final split = placed.isSplit;
    final lines = [
      for (final line in order.activeLines)
        if (!split || (placed.on[line.lineId] ?? const []).contains(number)) line,
    ];
    final total = split ? _reckoned(check, placed, number, lines) : check?.total;
    final part = split ? check?.part(number) : null;
    final owes = total != null && part != null && cents(part.paid) > 0 ? part.due : null;
    return Material(
      key: ValueKey('split-check:$number'),
      color: PosColors.of(context).checkPaper,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 6, 4, 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    split ? 'Check $number' : 'One check',
                    style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      total == null ? '…' : '\$$total',
                      key: ValueKey('split-total:$number'),
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                        fontFeatures: PosTheme.tabular,
                      ),
                    ),
                    if (owes != null)
                      Text(
                        cents(owes) > 0 ? 'due $owes' : 'paid',
                        style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                  ],
                ),
                if (split)
                  IconButton(
                    key: ValueKey('split-bill:$number'),
                    tooltip: 'Print the bill of check $number',
                    icon: const Icon(Icons.receipt_long_outlined),
                    onPressed: view.billing ? null : () => widget.onBill(number),
                  )
                else
                  const SizedBox(width: 10),
              ],
            ),
          ),
          const Divider(height: 1),
          for (final line in lines) _dish(context, view, placed, number, line),
          if (lines.isEmpty) const Padding(padding: EdgeInsets.all(14), child: Text('Nothing on this check.')),
        ],
      ),
    );
  }

  /// What the hub says check [number] comes to, once it has reckoned the same dishes on it as this screen
  /// shows; null until then.
  String? _reckoned(Check? check, Placed placed, int number, List<Line> lines) {
    final part = check?.part(number);
    if (check == null || part == null || check.estimated) return null;
    final mine = {for (final line in lines) line.lineId: placed.on[line.lineId]!.where((n) => n != number).join(',')};
    final hubs = {for (final line in part.lines) line.lineId: line.shared.join(',')};
    if (mine.length != hubs.length || mine.entries.any((e) => hubs[e.key] != e.value)) return null;
    return part.total;
  }

  /// A dish on a check: a tap picks it up or puts it back. Its amount is this check's part of it.
  Widget _dish(BuildContext context, SplitView view, Placed placed, int number, Line line) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final priced = view.check?.line(line.lineId);
    final on = placed.isSplit ? placed.on[line.lineId] ?? [number] : [number];
    final others = [
      for (final n in on)
        if (n != number) n,
    ];
    final picked = _picked.contains(line.lineId);
    final words = [
      if (line.seat != null) 'seat ${line.seat}',
      if (others.isNotEmpty)
        '1/${on.length}${priced == null ? '' : ' of ${priced.total}'}, shared with check${others.length == 1 ? '' : 's'} '
            '${others.join(', ')}',
    ];
    return InkWell(
      key: ValueKey('split-line:$number:${line.lineId}'),
      onTap: view.order.isOpen
          ? () => setState(() => picked ? _picked.remove(line.lineId) : _picked.add(line.lineId))
          : null,
      child: Container(
        color: picked ? scheme.secondaryContainer : null,
        padding: const EdgeInsets.fromLTRB(10, 8, 14, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 26,
              child: Icon(
                picked ? Icons.check_circle : Icons.circle_outlined,
                size: 20,
                color: picked ? scheme.primary : scheme.outlineVariant,
              ),
            ),
            SizedBox(
              width: 30,
              child: Text(
                '${line.qty}×',
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  fontFeatures: PosTheme.tabular,
                ),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    (DishLanguage.chineseOf(context) ? line.zhName : null) ?? priced?.name ?? line.item,
                    style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  if (words.isNotEmpty)
                    Text(words.join(' · '), style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              priced == null ? '' : partOf(priced.total, on, number),
              style: theme.textTheme.bodyMedium?.copyWith(fontFeatures: PosTheme.tabular),
            ),
          ],
        ),
      ),
    );
  }

  /// The foot of the screen. With dishes in hand: where they go. Otherwise the table's total and its bills.
  Widget _foot(BuildContext context, SplitView view, List<int> numbers, int count) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final order = view.order;
    final check = view.check;
    final inHand = _inHand(order);
    final placed = placedOn(order);
    final Widget child;
    if (inHand.isEmpty || splitOf(order).isEven) {
      child = Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  count > 1 ? 'The table, on $count checks' : 'The table',
                  style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
                Text(
                  check == null ? '…' : '\$${check.total}',
                  key: const ValueKey('split-table-total'),
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    fontFeatures: PosTheme.tabular,
                  ),
                ),
              ],
            ),
          ),
          FilledButton.icon(
            key: const ValueKey('split-bill-all'),
            onPressed: view.billing || order.activeLines.isEmpty ? null : () => widget.onBill(null),
            icon: const Icon(Icons.receipt_long_outlined),
            label: Text(count > 1 ? 'Print $count bills' : 'Print the bill'),
          ),
        ],
      );
    } else {
      final style = OutlinedButton.styleFrom(
        minimumSize: const Size(0, 44),
        padding: const EdgeInsets.symmetric(horizontal: 14),
      );
      child = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${inHand.length == 1 ? '1 dish' : '${inHand.length} dishes'} picked. Put ${inHand.length == 1 ? 'it' : 'them'} on:',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              TextButton(
                key: const ValueKey('split-clear'),
                onPressed: () => setState(_picked.clear),
                child: const Text('Put back'),
              ),
            ],
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              // a table still on one check has nowhere else to go yet: a new check, or shared
              for (final number in placed.isSplit ? numbers : const <int>[])
                OutlinedButton(
                  key: ValueKey('split-to:$number'),
                  style: style,
                  onPressed: () => _send(putOps(order, inHand, [number])),
                  child: Text('Check $number'),
                ),
              FilledButton.tonalIcon(
                key: const ValueKey('split-to:new'),
                style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
                onPressed: () => _send(putOps(order, inHand, [placed.isSplit ? placed.next : numbers.last + 1])),
                icon: const Icon(Icons.add),
                label: const Text('New check'),
              ),
              OutlinedButton.icon(
                key: const ValueKey('split-share'),
                style: style,
                onPressed: () => _share(order, numbers),
                icon: const Icon(Icons.call_split),
                label: const Text('Share'),
              ),
            ],
          ),
        ],
      );
    }
    return Material(
      color: PosColors.of(context).checkFooter,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: scheme.outlineVariant, width: 1.5)),
        ),
        child: SafeArea(
          top: false,
          child: Padding(padding: const EdgeInsets.fromLTRB(14, 10, 14, 12), child: child),
        ),
      ),
    );
  }
}

/// One of the ways a table pays, as a button at the top: filled while it is the way in force.
class _Way extends StatelessWidget {
  const _Way({super.key, required this.label, required this.icon, required this.chosen, required this.onTap});

  final String label;
  final IconData icon;
  final bool chosen;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final child = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(chosen ? Icons.check : icon, size: 20),
        const SizedBox(height: 2),
        Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      ],
    );
    final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(12));
    const padding = EdgeInsets.symmetric(horizontal: 6, vertical: 8);
    if (chosen) {
      // the way in force stays lit whether or not a tap on it does anything more
      return FilledButton.tonal(
        onPressed: onTap ?? () {},
        style: FilledButton.styleFrom(
          shape: shape,
          padding: padding,
          backgroundColor: scheme.secondaryContainer,
          foregroundColor: scheme.onSecondaryContainer,
        ),
        child: child,
      );
    }
    return OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(shape: shape, padding: padding),
      child: child,
    );
  }
}

/// An even split: how many ways (− and +), and what each part comes to with a button for its bill.
class _EvenParts extends StatelessWidget {
  const _EvenParts({required this.ways, required this.check, required this.onWays, required this.onBill});

  final int ways;
  final Check? check;
  final ValueChanged<int>? onWays;
  final Future<void> Function(int? check)? onBill;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final check = this.check;
    // the hub's parts once it has cut this total this many ways; until then the same sum done here
    final hubs = check != null && !check.estimated && check.split.isEven && check.parts.length == ways;
    final parts = check == null
        ? null
        : hubs
        ? [for (final part in check.parts) part.total]
        : [for (final part in equalParts(cents(check.total), ways)) money(part)];
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Column(
            children: [
              Text(
                'The dishes stay on one check. The total is cut in equal parts.',
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton.filledTonal(
                    key: const ValueKey('even-less'),
                    tooltip: 'One part fewer',
                    onPressed: onWays == null || ways <= 2 ? null : () => onWays!(ways - 1),
                    icon: const Icon(Icons.remove),
                  ),
                  SizedBox(
                    width: 120,
                    child: Text(
                      '$ways ways',
                      key: const ValueKey('even-ways'),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
                    ),
                  ),
                  IconButton.filledTonal(
                    key: const ValueKey('even-more'),
                    tooltip: 'One part more',
                    onPressed: onWays == null || ways >= maxChecks ? null : () => onWays!(ways + 1),
                    icon: const Icon(Icons.add),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Material(
                color: PosColors.of(context).checkPaper,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(color: scheme.outlineVariant),
                ),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    for (var n = 1; n <= ways; n++) ...[
                      if (n > 1) const Divider(height: 1),
                      Padding(
                        key: ValueKey('even-part:$n'),
                        padding: const EdgeInsets.fromLTRB(14, 2, 4, 2),
                        child: Row(
                          children: [
                            Expanded(child: Text('Part $n of $ways', style: theme.textTheme.bodyMedium)),
                            Text(
                              parts == null ? '…' : '\$${parts[n - 1]}',
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w800,
                                fontFeatures: PosTheme.tabular,
                              ),
                            ),
                            IconButton(
                              key: ValueKey('split-bill:$n'),
                              tooltip: 'Print the bill of part $n',
                              icon: const Icon(Icons.receipt_long_outlined),
                              onPressed: onBill == null ? null : () => onBill!(n),
                            ),
                          ],
                        ),
                      ),
                    ],
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

/// Which checks share the dishes in hand: a chip for each check there is, and "Another check" for one more.
class _ShareSheet extends StatefulWidget {
  const _ShareSheet({required this.numbers, required this.selected});

  final List<int> numbers;
  final List<int> selected;

  @override
  State<_ShareSheet> createState() => _ShareSheetState();
}

class _ShareSheetState extends State<_ShareSheet> {
  late final _numbers = [...widget.numbers];
  late final _between = {...widget.selected};

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ordered = _between.toList()..sort();
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Share between', style: theme.textTheme.titleMedium),
            Text(
              'Each check pays an equal part of the dish.',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final number in _numbers)
                  FilterChip(
                    key: ValueKey('share:$number'),
                    label: Text('Check $number'),
                    selected: _between.contains(number),
                    onSelected: (on) => setState(() => on ? _between.add(number) : _between.remove(number)),
                  ),
                if (_numbers.length < maxChecks)
                  ActionChip(
                    key: const ValueKey('share-more'),
                    avatar: const Icon(Icons.add, size: 18),
                    label: const Text('Another check'),
                    onPressed: () => setState(() {
                      final next = Placed(_numbers, const {}).next;
                      _numbers
                        ..add(next)
                        ..sort();
                      _between.add(next);
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                key: const ValueKey('share-done'),
                onPressed: ordered.length < 2 ? null : () => Navigator.of(context).pop(ordered),
                child: Text(ordered.length < 2 ? 'Pick two checks or more' : 'Share between ${ordered.length}'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
