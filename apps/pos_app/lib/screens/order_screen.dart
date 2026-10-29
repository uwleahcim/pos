import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../floor.dart';
import '../line_ops.dart';
import '../local_order.dart';
import '../menu.dart';
import '../outbox.dart';
import '../photos.dart';
import 'compact.dart';
import 'menu_panel.dart';
import 'status_bar.dart';

/// One order: its check as the backend prices it, and the menu whose taps append to it.
class OrderScreen extends StatefulWidget {
  const OrderScreen({
    super.key,
    required this.api,
    required this.outbox,
    required this.photos,
    required this.orderId,
    this.courses = Course.defaults,
  });

  final PosApi api;
  final Outbox outbox;
  final PhotoQueue photos;
  final String orderId;
  final List<Course> courses;

  @override
  State<OrderScreen> createState() => _OrderScreenState();
}

class _OrderScreenState extends State<OrderScreen> {
  Order? _read; // what the backend last returned
  Check? _readCheck;
  final _local = <String, LocalLine>{}; // line id -> what this screen knew when it added the line
  bool _reading = false;
  Timer? _timer;
  int? _seat; // null: for the table, shared
  late String _course = widget.courses.length > 1 ? widget.courses[1].id : widget.courses.first.id;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _refresh());
    widget.outbox.addListener(_onOutbox);
    _refresh();
  }

  @override
  void dispose() {
    _timer?.cancel();
    widget.outbox.removeListener(_onOutbox);
    super.dispose();
  }

  /// A tap queued or the hub accepted something: redraw now, and read back once nothing is left to send.
  void _onOutbox() {
    if (!mounted) return;
    setState(() {});
    final waiting = widget.outbox.pendingOps.any((op) => op['order_id'] == widget.orderId);
    if (!waiting && widget.outbox.localOps(widget.orderId).isNotEmpty) _refresh();
  }

  Future<void> _refresh() async {
    if (_reading) return;
    _reading = true;
    final mark = widget.outbox.readMark;
    try {
      final order = await widget.api.order(widget.orderId);
      final check = await widget.api.check(widget.orderId);
      widget.outbox.seen(widget.orderId, mark);
      if (mounted) {
        setState(() {
          _read = order;
          _readCheck = check;
        });
      }
    } on ApiException {
      // 404 until the create op lands; the status bar shows outages.
    } finally {
      _reading = false;
    }
  }

  /// The order as it stands on this screen: the last read plus this device's operations not yet in it.
  Order? get _order {
    final local = widget.outbox.localOps(widget.orderId);
    final base = _read ?? (local.isEmpty ? null : Order.empty(widget.orderId));
    return base == null ? null : withLocalOps(base, local);
  }

  static const _photographed = {'fire', 'close', 'reopen', 'void_line', 'void_order'};

  Future<void> _append(String kind, [Map<String, dynamic> data = const {}]) => _appendAll([(kind, data)]);

  /// Operations that belong together go in one batch, so the kitchen gets one ticket for a change.
  Future<void> _appendAll(List<(String, Map<String, dynamic>)> ops) async {
    final ids = await widget.outbox.addAll(widget.orderId, ops);
    final i = ops.indexWhere((op) => _photographed.contains(op.$1));
    if (i >= 0) unawaited(widget.photos.capture(ops[i].$1, opId: ids[i]));
  }

  Map<String, dynamic> _lineData(ChosenLine line, {required int? seat, required String? course}) {
    final id = widget.outbox.newId();
    _local[id] = LocalLine(
      unitPrice: line.unitPrice,
      modifiers: line.modifiers,
      itemId: line.itemId,
      entryId: line.request.entryId,
    );
    return {
      'line_id': id,
      'item': line.name,
      'qty': line.qty,
      'seat': ?seat,
      'course': ?course,
      if (line.note.isNotEmpty) 'note': line.note,
      'request': line.request.toJson(),
    };
  }

  Future<void> _add(ChosenLine line) => _append('add_line', _lineData(line, seat: _seat, course: _course));

  Future<void> _fire(String course) => _append('fire', {'course': course});

  void _say(String message) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));

  /// Makes a line hold `qty` of its dish: one more from a tap on the quantity, one fewer from a tap on the
  /// bin, any number typed after holding the quantity, none after holding the bin. Before the kitchen has the
  /// line it simply changes. After, more is a new line of the extra, held until fired like any new dish; fewer
  /// or none voids it (and sends the rest again), so a VOID ticket prints and the operator confirms first.
  Future<void> _setQty(Line line, int qty) async {
    final change = qtyChange(line, qty, newId: widget.outbox.newId);
    if (change.isEmpty) return;
    if (change.voidsFired) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(qty == 0 ? 'Void ${line.item}?' : 'Void ${line.item} and send $qty again?'),
          content: Text(
            qty == 0
                ? 'It has gone to the kitchen. A VOID ticket prints so they stop making it.'
                : 'It has gone to the kitchen. A VOID ticket prints for the ${line.qty}, and a new one for $qty.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Keep it')),
            FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Void')),
          ],
        ),
      );
      if (ok != true) return;
    }
    final copy = change.newLineId;
    if (copy != null) _local[copy] = _localFor(line);
    await _appendAll(change.ops);
  }

  /// What this screen knows of a line, to price a copy of it before the backend does.
  LocalLine _localFor(Line line) {
    final known = _local[line.lineId];
    if (known != null) return known;
    final priced = _readCheck?.line(line.lineId);
    return LocalLine(
      unitPrice: priced == null || priced.qty == 0 ? null : money(cents(priced.total) ~/ priced.qty),
      modifiers: priced?.modifiers ?? const [],
      itemId: line.itemId,
      entryId: line.entryId,
    );
  }

  Future<void> _typeQty(Line line) async {
    final qty = await showDialog<int>(
      context: context,
      builder: (_) => _QtyDialog(name: line.item, qty: line.qty),
    );
    if (qty != null) await _setQty(line, qty);
  }

  /// Reopens a line's choices. The changed dish replaces the old one: an unfired line just comes off, a
  /// fired one is voided and the new one fired with it, so the kitchen gets both on one ticket.
  Future<void> _edit(Line line) async {
    final itemId = line.itemId ?? _local[line.lineId]?.itemId;
    final entryId = line.entryId ?? _local[line.lineId]?.entryId;
    if (!line.isActive || line.request == null || itemId == null) {
      _say('This line has no menu choices to change. Remove it and add it again.');
      return;
    }
    final ItemDetail detail;
    try {
      detail = await widget.api.item(itemId, entryId: entryId);
    } on ApiException catch (err) {
      _say('Could not open the dish: $err');
      return;
    }
    if (!mounted) return;
    final chosen = await showDialog<ChosenLine>(
      context: context,
      builder: (_) => ItemSheet(
        api: widget.api,
        entry: MenuEntry.fromDetail(detail, entryId: entryId),
        initial: ChosenLine(name: line.item, request: line.request!, qty: line.qty, note: line.note),
        warning: line.fired ? 'Already sent to the kitchen: updating voids it and fires the new one.' : null,
      ),
    );
    if (chosen == null) return;
    await _appendAll([
      ('void_line', {'line_id': line.lineId, 'reason': 'changed'}),
      ('add_line', _lineData(chosen, seat: line.seat, course: line.course)),
      if (line.fired) ('fire', {'course': line.course ?? '*'}),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final order = _order;
    final check = order == null ? null : estimateCheck(_readCheck, order, _local);
    final open = order?.isOpen ?? true;
    final ticket = _TicketPanel(
      order: order,
      check: check,
      open: open,
      courses: widget.courses,
      onEdit: _edit,
      onQty: _setQty,
      onTypeQty: _typeQty,
    );
    final menu = open
        ? Column(
            children: [
              _SeatCourseBar(
                guests: (order?.fields['guests'] as int?) ?? 0,
                seat: _seat,
                course: _course,
                courses: widget.courses,
                onSeat: (seat) => setState(() => _seat = seat),
                onCourse: (course) => setState(() => _course = course),
              ),
              Expanded(
                child: MenuPanel(api: widget.api, onChosen: _add),
              ),
            ],
          )
        : const Center(child: Text('This check is closed. Reopen it to add items.'));
    return Scaffold(
      appBar: AppBar(
        title: Text(order == null ? 'Order' : 'Table ${order.table} · ${order.status}'),
        actions: [
          StatusIcon(api: widget.api, outbox: widget.outbox),
          if (order != null && open) _FireMenu(order: order, courses: widget.courses, onFire: _fire),
          if (order != null && open) _Action('Close', Icons.check, () => _append('close')),
          if (order != null && order.status == 'closed') _Action('Reopen', Icons.undo, () => _append('reopen')),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                if (constraints.maxWidth >= 720) {
                  // Mac and iPad: the check on the left, the menu on the right.
                  return Row(
                    children: [
                      SizedBox(width: constraints.maxWidth * 0.38, child: ticket),
                      const VerticalDivider(width: 1),
                      Expanded(child: menu),
                    ],
                  );
                }
                // iPhone: the check and the menu as two tabs.
                return DefaultTabController(
                  length: 2,
                  initialIndex: 1,
                  child: Column(
                    children: [
                      TabBar(
                        tabs: [
                          Tab(text: 'Check ${check == null ? '' : '\$${check.total}'}'),
                          const Tab(text: 'Menu'),
                        ],
                      ),
                      Expanded(child: TabBarView(children: [ticket, menu])),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// The lines on the check with their prices, and the totals the backend computed.
class _TicketPanel extends StatelessWidget {
  const _TicketPanel({
    required this.order,
    required this.check,
    required this.open,
    required this.courses,
    required this.onEdit,
    required this.onQty,
    required this.onTypeQty,
  });

  final Order? order;
  final Check? check;
  final bool open;
  final List<Course> courses;
  final ValueChanged<Line> onEdit;
  final void Function(Line line, int qty) onQty;
  final ValueChanged<Line> onTypeQty;

  @override
  Widget build(BuildContext context) {
    final order = this.order;
    final theme = Theme.of(context);
    if (order == null) return const Center(child: CircularProgressIndicator());
    if (order.shownLines.isEmpty) return const Center(child: Text('Nothing ordered yet.'));
    final check = this.check;
    return Column(
      children: [
        Expanded(
          child: ListView(
            children: [
              for (final group in _byCourse(order)) ...[
                _CourseHeader(name: group.$1, state: group.$2),
                for (final line in group.$3)
                  Builder(
                    builder: (context) {
                      final priced = check?.line(line.lineId);
                      final changeable = open && line.isActive;
                      return ListTile(
                        dense: true,
                        onTap: changeable ? () => onEdit(line) : null,
                        leading: _Hold(
                          key: ValueKey('qty-${line.lineId}'),
                          tooltip: 'Tap for one more, hold to type how many',
                          onTap: changeable ? () => onQty(line, line.qty + 1) : null,
                          onLongPress: changeable ? () => onTypeQty(line) : null,
                          child: SizedBox(
                            width: 44,
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text('${line.qty}×', style: theme.textTheme.titleMedium),
                                  Text(
                                    line.seat == null ? 'table' : 'seat ${line.seat}',
                                    style: theme.textTheme.labelSmall,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        title: Text(
                          priced?.name ?? line.item,
                          style: line.isVoid ? const TextStyle(decoration: TextDecoration.lineThrough) : null,
                        ),
                        subtitle: Text(
                          [
                            ...?priced?.modifiers,
                            if (line.isVoid) 'void',
                            if (line.isActive && !line.fired && group.$2 != 'held') 'not sent yet',
                            if (line.isActive && line.modifiedAfterFire) 'added after fire',
                            if (line.note.isNotEmpty) line.note,
                          ].join(' · '),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (line.pending)
                              const Padding(
                                padding: EdgeInsets.only(right: 4),
                                child: Icon(Icons.cloud_upload_outlined, size: 14),
                              ),
                            if (priced != null) Text(priced.total),
                            if (changeable)
                              _Hold(
                                key: ValueKey('bin-${line.lineId}'),
                                tooltip: line.qty > 1
                                    ? 'Tap for one fewer, hold to take them all off'
                                    : (line.fired ? 'Void (sent to the kitchen)' : 'Remove'),
                                onTap: () => onQty(line, line.qty - 1),
                                onLongPress: () => onQty(line, 0),
                                child: Padding(
                                  padding: const EdgeInsets.all(10),
                                  child: Icon(line.fired ? Icons.block : Icons.delete_outline),
                                ),
                              ),
                          ],
                        ),
                      );
                    },
                  ),
              ],
            ],
          ),
        ),
        if (check != null)
          Material(
            color: theme.colorScheme.surfaceContainerHigh,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Column(
                children: [
                  _TotalRow('Subtotal', check.subtotal),
                  _TotalRow('Sales tax ${_rate(check.taxRatePct)}%', check.tax),
                  _TotalRow(check.estimated ? 'Total (updating)' : 'Total', check.total, strong: true),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

extension on _TicketPanel {
  /// Lines grouped by course in service order: (course name, held | fired | "N to fire", lines by seat).
  List<(String, String, List<Line>)> _byCourse(Order order) {
    final known = [for (final c in courses) c.id];
    final shown = order.shownLines;
    final ids = {for (final l in shown) l.course ?? ''}.toList()
      ..sort((a, b) {
        final ia = known.indexOf(a), ib = known.indexOf(b);
        return (ia < 0 ? 99 : ia).compareTo(ib < 0 ? 99 : ib);
      });
    String state(List<Line> lines) {
      final active = lines.where((l) => l.isActive);
      final waiting = active.where((l) => !l.fired).length;
      if (waiting == 0) return 'fired';
      return waiting == active.length ? 'held' : '$waiting to fire';
    }

    (String, String, List<Line>) group(String id) {
      final lines = shown.where((l) => (l.course ?? '') == id).toList()
        ..sort((a, b) => (a.seat ?? 0).compareTo(b.seat ?? 0));
      final name = courses.where((c) => c.id == id).firstOrNull?.name ?? (id.isEmpty ? 'No course' : id);
      return (name, state(lines), lines);
    }

    return [for (final id in ids) group(id)];
  }
}

/// An app bar button: icon and label, or the icon alone on a phone.
class _Action extends StatelessWidget {
  const _Action(this.label, this.icon, this.onPressed);

  final String label;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => compact(context)
      ? IconButton(tooltip: label, onPressed: onPressed, icon: Icon(icon))
      : TextButton.icon(onPressed: onPressed, icon: Icon(icon), label: Text(label));
}

/// A tap target that also answers holding it down, which an [IconButton] does not.
class _Hold extends StatelessWidget {
  const _Hold({super.key, required this.tooltip, required this.onTap, required this.onLongPress, required this.child});

  final String tooltip;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (onTap == null && onLongPress == null) return child;
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(seconds: 1),
      child: InkResponse(onTap: onTap, onLongPress: onLongPress, radius: 24, child: child),
    );
  }
}

/// How many of a dish, typed. Zero takes the line off.
class _QtyDialog extends StatefulWidget {
  const _QtyDialog({required this.name, required this.qty});

  final String name;
  final int qty;

  @override
  State<_QtyDialog> createState() => _QtyDialogState();
}

class _QtyDialogState extends State<_QtyDialog> {
  late final _text = TextEditingController(text: '${widget.qty}')
    ..selection = TextSelection(baseOffset: 0, extentOffset: '${widget.qty}'.length);

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  int? get _qty {
    final qty = int.tryParse(_text.text.trim());
    return qty == null || qty < 0 || qty > 999 ? null : qty;
  }

  void _done() {
    final qty = _qty;
    if (qty != null) Navigator.of(context).pop(qty);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('How many ${widget.name}?'),
      content: TextField(
        key: const ValueKey('qty-field'),
        controller: _text,
        autofocus: true,
        keyboardType: TextInputType.number,
        decoration: const InputDecoration(helperText: '0 takes it off the check'),
        onChanged: (_) => setState(() {}),
        onSubmitted: (_) => _done(),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(onPressed: _qty == null ? null : _done, child: const Text('Set')),
      ],
    );
  }
}

class _CourseHeader extends StatelessWidget {
  const _CourseHeader({required this.name, required this.state});
  final String name;
  final String state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fired = state == 'fired';
    return Container(
      color: theme.colorScheme.surfaceContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          Text(name, style: theme.textTheme.titleSmall),
          const Spacer(),
          Icon(fired ? Icons.local_fire_department : Icons.pause_circle_outline, size: 16),
          const SizedBox(width: 4),
          Text(state, style: theme.textTheme.labelMedium),
        ],
      ),
    );
  }
}

/// Which seat and course the next dish goes to. Seats run to the party size, plus one more on demand.
class _SeatCourseBar extends StatefulWidget {
  const _SeatCourseBar({
    required this.guests,
    required this.seat,
    required this.course,
    required this.courses,
    required this.onSeat,
    required this.onCourse,
  });

  final int guests;
  final int? seat;
  final String course;
  final List<Course> courses;
  final ValueChanged<int?> onSeat;
  final ValueChanged<String> onCourse;

  @override
  State<_SeatCourseBar> createState() => _SeatCourseBarState();
}

class _SeatCourseBarState extends State<_SeatCourseBar> {
  int _extra = 0;

  @override
  Widget build(BuildContext context) {
    final seats = widget.guests + _extra;
    Widget chip(String label, bool selected, VoidCallback onTap) => Padding(
      padding: const EdgeInsets.only(right: 6),
      child: ChoiceChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) => onTap(),
        visualDensity: VisualDensity.compact,
      ),
    );
    final seatChips = [
      const Text('Seat  '),
      chip('Table', widget.seat == null, () => widget.onSeat(null)),
      for (var i = 1; i <= seats; i++) chip('$i', widget.seat == i, () => widget.onSeat(i)),
      IconButton(
        tooltip: 'Add a seat',
        icon: const Icon(Icons.add_circle_outline),
        onPressed: () {
          setState(() => _extra++);
          widget.onSeat(widget.guests + _extra);
        },
      ),
    ];
    final courseChips = [
      const Text('Course  '),
      for (final c in widget.courses) chip(c.name, widget.course == c.id, () => widget.onCourse(c.id)),
    ];
    Widget row(List<Widget> children) => SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: children),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      child: compact(context)
          // a phone: both on one line that scrolls, to leave the screen to the menu
          ? row([...seatChips, const SizedBox(width: 8), ...courseChips])
          : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [row(seatChips), row(courseChips)]),
    );
  }
}

/// Fire one held course, or everything at once.
class _FireMenu extends StatelessWidget {
  const _FireMenu({required this.order, required this.courses, required this.onFire});

  final Order order;
  final List<Course> courses;
  final ValueChanged<String> onFire;

  @override
  Widget build(BuildContext context) {
    final waiting = order.heldCourses;
    final held = [
      for (final c in courses)
        if (waiting.contains(c.id)) c,
    ];
    return PopupMenuButton<String>(
      tooltip: 'Fire',
      onSelected: onFire,
      itemBuilder: (_) => [
        for (final c in held) PopupMenuItem(value: c.id, child: Text('Fire ${c.name}')),
        const PopupMenuItem(value: '*', child: Text('Fire everything')),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: compact(context)
            ? Badge(
                isLabelVisible: held.isNotEmpty,
                label: Text('${held.length}'),
                child: const Icon(Icons.local_fire_department),
              )
            : Row(
                children: [
                  const Icon(Icons.local_fire_department),
                  const SizedBox(width: 4),
                  Text(held.isEmpty ? 'Fire' : 'Fire (${held.length} held)'),
                ],
              ),
      ),
    );
  }
}

/// 7.00 -> 7, 6.25 -> 6.25.
String _rate(String pct) {
  final value = double.tryParse(pct);
  if (value == null) return pct;
  return value == value.roundToDouble() ? value.toStringAsFixed(0) : value.toString();
}

class _TotalRow extends StatelessWidget {
  const _TotalRow(this.label, this.amount, {this.strong = false});

  final String label;
  final String amount;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    final style = strong ? Theme.of(context).textTheme.titleMedium : Theme.of(context).textTheme.bodyMedium;
    return Row(
      children: [
        Text(label, style: style),
        const Spacer(),
        Text(amount, style: style),
      ],
    );
  }
}
