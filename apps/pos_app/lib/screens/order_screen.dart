import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../floor.dart';
import '../menu.dart';
import '../outbox.dart';
import '../photos.dart';
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
  Order? _order;
  Check? _check;
  Timer? _timer;
  int? _seat; // null: for the table, shared
  late String _course = widget.courses.length > 1 ? widget.courses[1].id : widget.courses.first.id;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _refresh());
    _refresh();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final order = await widget.api.order(widget.orderId);
      final check = await widget.api.check(widget.orderId);
      if (mounted) {
        setState(() {
          _order = order;
          _check = check;
        });
      }
    } on ApiException {
      // 404 until the create op lands; the status bar shows outages.
    }
  }

  static const _photographed = {'fire', 'close', 'reopen', 'void_line', 'void_order'};

  Future<void> _append(String kind, [Map<String, dynamic> data = const {}]) async {
    final opId = await widget.outbox.add(widget.orderId, kind, data);
    if (_photographed.contains(kind)) unawaited(widget.photos.capture(kind, opId: opId));
    _refresh();
  }

  Future<void> _add(ChosenLine line) => _append('add_line', {
    'line_id': widget.outbox.newId(),
    'item': line.name,
    'qty': line.qty,
    'seat': ?_seat,
    'course': _course,
    if (line.note.isNotEmpty) 'note': line.note,
    'request': line.request.toJson(),
  });

  Future<void> _fire(String course) => _append('fire', {'course': course});

  @override
  Widget build(BuildContext context) {
    final order = _order;
    final open = order?.isOpen ?? true;
    final ticket = _TicketPanel(
      order: order,
      check: _check,
      open: open,
      courses: widget.courses,
      onVoid: (line) => _append('void_line', {'line_id': line.lineId}),
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
          if (order != null && open) _FireMenu(order: order, courses: widget.courses, onFire: _fire),
          if (order != null && open)
            TextButton.icon(
              onPressed: () => _append('close'),
              icon: const Icon(Icons.check),
              label: const Text('Close'),
            ),
          if (order != null && order.status == 'closed')
            TextButton.icon(
              onPressed: () => _append('reopen'),
              icon: const Icon(Icons.undo),
              label: const Text('Reopen'),
            ),
        ],
      ),
      body: Column(
        children: [
          StatusBar(api: widget.api, outbox: widget.outbox),
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
                          Tab(text: 'Check ${_check == null ? '' : '\$${_check!.total}'}'),
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
    required this.onVoid,
  });

  final Order? order;
  final Check? check;
  final bool open;
  final List<Course> courses;
  final ValueChanged<Line> onVoid;

  @override
  Widget build(BuildContext context) {
    final order = this.order;
    final theme = Theme.of(context);
    if (order == null) return const Center(child: CircularProgressIndicator());
    if (order.lines.isEmpty) return const Center(child: Text('Nothing ordered yet.'));
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
                      return ListTile(
                        dense: true,
                        leading: SizedBox(
                          width: 44,
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
                        title: Text(
                          priced?.name ?? line.item,
                          style: line.isVoid ? const TextStyle(decoration: TextDecoration.lineThrough) : null,
                        ),
                        subtitle: Text(
                          [
                            ...?priced?.modifiers,
                            if (line.isVoid) 'void',
                            if (line.modifiedAfterFire) 'changed after fire',
                            if (line.note.isNotEmpty) line.note,
                          ].join(' · '),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (priced != null) Text(priced.total),
                            if (open && !line.isVoid)
                              IconButton(
                                tooltip: 'Void line',
                                icon: const Icon(Icons.delete_outline),
                                onPressed: () => onVoid(line),
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
                  _TotalRow('Total', check.total, strong: true),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

extension on _TicketPanel {
  /// Lines grouped by course in service order: (course name, held | fired, lines sorted by seat).
  List<(String, String, List<Line>)> _byCourse(Order order) {
    final known = [for (final c in courses) c.id];
    final ids = {for (final l in order.lines) l.course ?? ''}.toList()
      ..sort((a, b) {
        final ia = known.indexOf(a), ib = known.indexOf(b);
        return (ia < 0 ? 99 : ia).compareTo(ib < 0 ? 99 : ib);
      });
    return [
      for (final id in ids)
        (
          courses.where((c) => c.id == id).firstOrNull?.name ?? (id.isEmpty ? 'No course' : id),
          order.fired.containsKey(id) || order.fired.containsKey('*') ? 'fired' : 'held',
          order.lines.where((l) => (l.course ?? '') == id).toList()
            ..sort((a, b) => (a.seat ?? 0).compareTo(b.seat ?? 0)),
        ),
    ];
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
          Text(fired ? 'fired' : 'held', style: theme.textTheme.labelMedium),
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
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
              ],
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                const Text('Course  '),
                for (final c in widget.courses) chip(c.name, widget.course == c.id, () => widget.onCourse(c.id)),
              ],
            ),
          ),
        ],
      ),
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
    final withLines = {for (final l in order.activeLines) l.course ?? ''};
    final held = [
      for (final c in courses)
        if (withLines.contains(c.id) && !order.fired.containsKey(c.id) && !order.fired.containsKey('*')) c,
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
        child: Row(
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
