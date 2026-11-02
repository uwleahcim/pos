import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;

import '../api.dart';
import '../check_order.dart';
import '../coursing.dart';
import '../line_ops.dart';
import '../local_order.dart';
import '../menu.dart';
import '../outbox.dart';
import '../photos.dart';
import '../pricing.dart';
import '../takeout.dart';
import 'compact.dart';
import 'discount_sheet.dart';
import 'menu_panel.dart';
import 'pay_dialog.dart';
import 'status_bar.dart';
import 'theme.dart';

/// One order: its check as the backend prices it, and the menu whose taps append to it.
class OrderScreen extends StatefulWidget {
  const OrderScreen({
    super.key,
    required this.api,
    required this.outbox,
    required this.photos,
    required this.orderId,
    this.coursing = Coursing.defaults,
    this.staffName,
  });

  final PosApi api;
  final Outbox outbox;
  final PhotoQueue photos;
  final String orderId;

  /// The location's coursing: whether dishes are coursed, the courses by name, where a new dish goes.
  final Coursing coursing;

  /// Who is signed in, named on each discount they apply.
  final String? staffName;

  @override
  State<OrderScreen> createState() => _OrderScreenState();
}

class _OrderScreenState extends State<OrderScreen> {
  Order? _read; // what the backend last returned
  Check? _readCheck;
  final _local = <String, LocalLine>{}; // line id -> what this screen knew when it added the line
  String? _lastAdded; // the check scrolls to it
  bool _reading = false;
  Timer? _timer;
  int? _seat; // null: for the table, shared
  late String? _course = widget.coursing.enabled ? widget.coursing.defaultCourse : null; // null: not coursed

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

  static const _photographed = {
    'fire',
    'close',
    'reopen',
    'void_line',
    'void_order',
    'discount',
    'remove_discount',
    'charge',
    'remove_charge',
    'pay',
  };

  Future<void> _append(String kind, [Map<String, dynamic> data = const {}]) => _appendAll([(kind, data)]);

  /// Operations that belong together go in one batch, so the kitchen gets one ticket for a change.
  Future<void> _appendAll(List<(String, Map<String, dynamic>)> ops) async {
    final ids = await widget.outbox.addAll(widget.orderId, ops);
    final i = ops.indexWhere((op) => _photographed.contains(op.$1));
    if (i >= 0) unawaited(widget.photos.capture(ops[i].$1, opId: ids[i]));
  }

  Map<String, dynamic> _lineData(ChosenLine line, {required int? seat, required String? course}) {
    final id = widget.outbox.newId();
    _lastAdded = id;
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

  /// A discount or a charge from the location's rules. The hub refuses what its rules do not allow, so the
  /// sheet shows them first; a reason that needs a manager asks for the PIN before anything is sent.
  Future<void> _discount() async {
    if (!widget.api.connection.value.isOnline) {
      _say('Discounts need a hub or the cloud, and none answers now.');
      return;
    }
    final PricingRules rules;
    try {
      rules = await widget.api.pricingRules();
    } on ApiException catch (err) {
      _say(err.message);
      return;
    }
    if (!mounted) return;
    final check = _readCheck;
    final choice = await showDialog<Adjustment>(
      context: context,
      builder: (_) =>
          DiscountSheet(rules: rules, lines: check?.lines ?? const [], existing: check?.discounts ?? const []),
    );
    if (choice == null || !mounted) return;
    String? approval;
    if (choice.needsManager) {
      approval = await _approve(choice.label);
      if (approval == null) return;
    }
    final id = widget.outbox.newId();
    await _append(choice.op, {
      choice.op == 'discount' ? 'discount_id' : 'charge_id': id,
      ...choice.data,
      'applied_by': ?widget.staffName,
      'approval': ?approval,
    });
  }

  /// A manager's PIN for one adjustment on this order; null when they walk away.
  Future<String?> _approve(String what) => showDialog<String>(
    context: context,
    builder: (_) =>
        ApprovalDialog(api: widget.api, device: widget.api.settings.device, orderId: widget.orderId, what: what),
  );

  Future<void> _removeDiscount(CheckDiscount discount) =>
      _append('remove_discount', {'discount_id': discount.discountId});

  /// An automatic charge (the gratuity on a large party) comes off only with a manager when the rules say
  /// so; one that staff put on comes off freely.
  Future<void> _removeCharge(CheckCharge charge) async {
    String? approval;
    if (charge.automatic) {
      final bool needsManager;
      try {
        needsManager = (await widget.api.pricingRules()).charge(charge.chargeId)?.needsManagerToRemove ?? true;
      } on ApiException catch (err) {
        _say(err.message);
        return;
      }
      if (!mounted) return;
      if (needsManager) {
        approval = await _approve('Taking off ${charge.name}');
        if (approval == null) return;
      }
    }
    await _append('remove_charge', {'charge_id': charge.chargeId, 'approval': ?approval});
  }

  /// Sends a held course (or everything) to the kitchen. Sending has two forms: stay on the check for the
  /// next round, or leave it for the next table.
  Future<void> _fire(String course, {bool leave = false}) async {
    await _append('fire', {'course': course});
    if (leave && mounted) Navigator.of(context).pop();
  }

  /// Counter mode (architecture section 12): the check is paid before the kitchen sees it, the change shows,
  /// and the screen goes back for the next customer. Where the location lets the channel pay at pickup (a
  /// phone order), the order can go to the kitchen unpaid and the ready text says so.
  Future<void> _payAndSend(Order order, Check check) async {
    var payAtPickup = false;
    try {
      payAtPickup = (await widget.api.quotes()).mayPayAtPickup(order.channel);
    } on ApiException {
      // nothing answers: cash and paid elsewhere need nothing from a backend
    }
    if (!mounted) return;
    final choice = await showDialog<PayChoice>(
      context: context,
      builder: (_) => PayDialog(due: check.due, channel: order.channel, payAtPickup: payAtPickup),
    );
    if (choice == null || !mounted) return;
    await _appendAll([
      if (choice.takesMoney)
        (
          'pay',
          {
            'payment_id': widget.outbox.newId(),
            'method': choice.method,
            'amount': check.due,
            'tendered': ?choice.tendered,
            if (choice.note.isNotEmpty) 'note': choice.note,
            'by': ?widget.staffName,
          },
        ),
      ('fire', {'course': '*'}),
    ]);
    if (!mounted) return;
    final change = choice.tendered == null ? 0 : cents(choice.tendered!) - cents(check.due);
    if (change > 0) {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Change \$${money(change)}', key: const ValueKey('change-due')),
          actions: [FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Done'))],
        ),
      );
      if (!mounted) return;
    }
    Navigator.of(context).pop();
  }

  void _say(String message) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));

  /// Makes a line hold `qty` of its dish: one more from a tap on the quantity, one fewer from a tap on the
  /// bin, any number typed after holding the quantity, none after holding the bin. Before the kitchen has the
  /// line it simply changes. After, more is a new line of the extra, held until fired like any new dish; fewer
  /// or none voids it (and sends the rest again), so a VOID ticket prints and the operator confirms first.
  Future<void> _setQty(Line line, int qty) async {
    final change = qtyChange(line, qty, newId: widget.outbox.newId);
    if (change.isEmpty) return;
    if (change.voidsFired) {
      final ok = await _confirmVoid(
        title: qty == 0 ? 'Void ${line.item}?' : 'Void ${line.item} and send $qty again?',
        body: qty == 0
            ? 'It has gone to the kitchen. A VOID ticket prints so they stop making it.'
            : 'It has gone to the kitchen. A VOID ticket prints for the ${line.qty}, and a new one for $qty.',
        action: 'Void',
      );
      if (!ok) return;
    }
    await _send(change, line);
  }

  /// A line dragged on the check: to another place in its course, or under another course. A dish the
  /// kitchen already has is voided (a VOID ticket prints) and goes again with the new course, so the
  /// operator confirms first.
  Future<void> _move(Line line, {required String? course, required double rank}) async {
    final change = moveChange(line, course: course, rank: rank, newId: widget.outbox.newId);
    if (change.isEmpty) return;
    if (change.voidsFired) {
      final from = line.course == null ? '' : ' with ${widget.coursing.nameOf(line.course!)}';
      final to = course == null ? 'no course' : widget.coursing.nameOf(course);
      final again = course == null ? 'with the next Fire everything' : 'when you fire $to';
      final ok = await _confirmVoid(
        title: 'Void ${line.item} and send it with $to?',
        body: 'It has gone to the kitchen$from. A VOID ticket prints, and it goes again $again.',
        action: 'Void and move',
      );
      if (!ok) return;
    }
    await _send(change, line);
  }

  /// Sends a change; the line it adds, if any, is priced like the line it copies and scrolled into view.
  Future<void> _send(LineChange change, Line line) async {
    final copy = change.newLineId;
    if (copy != null) {
      _local[copy] = _localFor(line);
      _lastAdded = copy;
    }
    await _appendAll(change.ops);
  }

  /// A VOID ticket is about to print: the operator's word first.
  Future<bool> _confirmVoid({required String title, required String body, required String action}) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Keep it')),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(action),
          ),
        ],
      ),
    );
    return ok == true;
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

  /// The party size, or more when a dish is on a higher seat.
  int _seats(Order? order) {
    var seats = (order?.fields['guests'] as int?) ?? 0;
    for (final line in order?.activeLines ?? const <Line>[]) {
      if ((line.seat ?? 0) > seats) seats = line.seat!;
    }
    return seats;
  }

  bool _lineMatchesEntry(Line line, MenuEntry entry) {
    final local = _local[line.lineId];
    final lineEntryId = line.entryId ?? line.request?.entryId ?? local?.entryId;
    if (lineEntryId != null && lineEntryId.isNotEmpty && entry.entryId.isNotEmpty) {
      return lineEntryId == entry.entryId;
    }
    final lineItemId = line.itemId ?? local?.itemId;
    if (lineItemId != null && lineItemId.isNotEmpty && entry.item.isNotEmpty) {
      return lineItemId == entry.item;
    }
    final variantId = line.request?.variantId;
    if (variantId != null && variantId.isNotEmpty && entry.variants.isNotEmpty) {
      return entry.variants.any((v) => v.variantId == variantId);
    }
    return line.item == entry.name || line.item.startsWith('${entry.name} (');
  }

  /// Total quantity of `entry` across all active lines on the check.
  int _entryQty(Order? order, MenuEntry entry) {
    if (order == null) return 0;
    var total = 0;
    for (final line in order.activeLines) {
      if (_lineMatchesEntry(line, entry)) total += line.qty;
    }
    return total;
  }

  /// Seats are the order's party size, so every screen on the order shows the same ones. A seat comes off
  /// only from the end, and only once its dishes are off it or moved.
  Future<void> _setSeats(Order? order, int seats) async {
    if (order == null || seats < 0) return;
    final current = _seats(order);
    if (seats < current) {
      final left = order.activeLines.where((l) => l.seat == current).length;
      if (left > 0) {
        _say(
          'Seat $current still has ${left == 1 ? 'a dish' : '$left dishes'}. Take ${left == 1 ? 'it' : 'them'} off first.',
        );
        return;
      }
    }
    setState(() {
      if (seats > current) {
        _seat = seats;
      } else if ((_seat ?? 0) > seats) {
        _seat = seats == 0 ? null : seats;
      }
    });
    await _append('set_field', {'guests': seats});
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final order = _order;
    // With no check from a backend yet (a check opened while nothing answers), the tax comes from the rates
    // the last priced check carried, and the total shows as an estimate until a backend prices it.
    final check = order == null ? null : estimateCheck(_readCheck ?? widget.api.savedTaxes, order, _local);
    final open = order?.isOpen ?? true;
    final seats = _seats(order);
    final ticket = _TicketPanel(
      order: order,
      check: check,
      open: open,
      coursing: widget.coursing,
      lastAdded: _lastAdded,
      onEdit: _edit,
      onQty: _setQty,
      onTypeQty: _typeQty,
      onRemoveDiscount: _removeDiscount,
      onRemoveCharge: _removeCharge,
      onMove: _move,
    );
    final menu = open
        ? Column(
            children: [
              if (order?.isTakeout != true) // a table's seats and courses; a to-go order has neither
                _SeatCourseBar(
                  seats: seats,
                  seat: _seat,
                  course: _course,
                  courses: widget.coursing.active,
                  onSeat: (seat) => setState(() => _seat = seat),
                  onAddSeat: () => _setSeats(order, seats + 1),
                  onRemoveSeat: () => _setSeats(order, seats - 1),
                  onCourse: (course) => setState(() => _course = course),
                ),
              Expanded(
                child: MenuPanel(api: widget.api, onChosen: _add, qtyOf: (entry) => _entryQty(order, entry)),
              ),
            ],
          )
        : Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.lock_outline_rounded, size: 36, color: scheme.outline),
                const SizedBox(height: 12),
                const Text('This check is closed. Reopen it to add items.'),
              ],
            ),
          );
    return Scaffold(
      appBar: AppBar(
        title: Text(
          order == null
              ? 'Order'
              : order.isTakeout
              ? _takeoutTitle(order)
              : 'Table ${order.table} · ${order.status}',
        ),
        actions: [
          StatusIcon(api: widget.api, outbox: widget.outbox),
          if (order != null && open && !order.isTakeout)
            _FireMenu(order: order, coursing: widget.coursing, onFire: _fire),
          // Counter mode: pay first, then everything goes to the kitchen at once and the screen comes back.
          if (order != null && open && order.isTakeout && order.heldCourses.isNotEmpty)
            check != null && cents(check.due) > 0
                ? _Action('Pay & send', Icons.point_of_sale, () => _payAndSend(order, check))
                : _Action('Send', Icons.send, () => _fire('*', leave: true)),
          if (order != null && open) _Action('Discount', Icons.percent, _discount),
          if (order != null && open) _Action('Close', Icons.check, () => _append('close')),
          if (order != null && order.status == 'closed') _Action('Reopen', Icons.undo, () => _append('reopen')),
        ],
      ),
      body: Column(
        children: [
          CaptureBanner(api: widget.api, outbox: widget.outbox),
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

/// The lines on the check with their prices, and the totals the backend computed. The line added last
/// scrolls into view, so the operator sees what the last tap did.
class _TicketPanel extends StatefulWidget {
  const _TicketPanel({
    required this.order,
    required this.check,
    required this.open,
    required this.coursing,
    required this.lastAdded,
    required this.onEdit,
    required this.onQty,
    required this.onTypeQty,
    required this.onRemoveDiscount,
    required this.onRemoveCharge,
    required this.onMove,
  });

  final Order? order;
  final Check? check;
  final bool open;
  final Coursing coursing;
  final String? lastAdded;
  final ValueChanged<Line> onEdit;
  final void Function(Line line, int qty) onQty;
  final ValueChanged<Line> onTypeQty;
  final ValueChanged<CheckDiscount> onRemoveDiscount;
  final ValueChanged<CheckCharge> onRemoveCharge;

  /// A line dragged to another place or course on the check.
  final Future<void> Function(Line line, {required String? course, required double rank}) onMove;

  @override
  State<_TicketPanel> createState() => _TicketPanelState();
}

class _TicketPanelState extends State<_TicketPanel> {
  final _keys = <String, GlobalKey>{};
  List<CheckRow>? _rows; // where a dropped row shows until its move lands

  @override
  void initState() {
    super.initState();
    _showLastAdded(); // the phone's Check tab opens on it too
  }

  @override
  void didUpdateWidget(_TicketPanel old) {
    super.didUpdateWidget(old);
    if (widget.lastAdded != old.lastAdded) _showLastAdded();
  }

  void _showLastAdded() {
    final id = widget.lastAdded;
    if (id == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final line = _keys[id]?.currentContext;
      if (!mounted || line == null) return;
      Scrollable.ensureVisible(
        line,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final order = widget.order;
    final open = widget.open;
    final scheme = Theme.of(context).colorScheme;
    final posColors = PosColors.of(context);
    if (order == null) return const Center(child: CircularProgressIndicator());
    if (order.shownLines.isEmpty) {
      return Material(
        color: posColors.checkPaper,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.receipt_outlined, size: 34, color: scheme.outline),
              const SizedBox(height: 10),
              const Text('Nothing ordered yet.'),
            ],
          ),
        ),
      );
    }
    final shown = {for (final l in order.shownLines) l.lineId};
    _keys.removeWhere((id, _) => !shown.contains(id));
    final check = widget.check;
    final rows = _rows ?? checkRows(order, widget.coursing);
    return Material(
      color: posColors.checkPaper,
      child: Column(
        children: [
          Expanded(
            // Every row is built (a check is short), so the line added last exists to scroll to. A line is
            // held and dragged to another place, or under another course's header.
            child: ReorderableListView.builder(
              key: const ValueKey('check-rows'),
              buildDefaultDragHandles: false,
              scrollCacheExtent: const ScrollCacheExtent.pixels(10000),
              itemCount: rows.length,
              onReorderItem: (from, to) => _dropped(rows, from, to),
              proxyDecorator: (child, _, animation) => AnimatedBuilder(
                animation: animation,
                builder: (context, child) =>
                    Material(color: posColors.checkPaper, elevation: 6 * animation.value, child: child),
                child: child,
              ),
              itemBuilder: (context, i) => switch (rows[i]) {
                CourseRow(:final id, :final name, :final state) => _CourseHeader(
                  key: ValueKey('course-row:$id'),
                  name: name,
                  state: state,
                ),
                final LineRow row => _lineTile(context, i, row),
              },
            ),
          ),
          if (check != null)
            Container(
              decoration: BoxDecoration(
                color: posColors.checkFooter,
                border: Border(top: BorderSide(color: scheme.outlineVariant, width: 1.5)),
              ),
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
              child: Column(
                children: [
                  _TotalRow('Subtotal', check.subtotal),
                  // Each discount and charge is its own row; a tap takes it off (a manager's PIN when the
                  // rules ask for one). The receipt shows them the same way.
                  for (final d in check.discounts)
                    _TotalRow(
                      _discountLabel(d, check),
                      '−${d.amount}',
                      key: ValueKey('discount-${d.discountId}'),
                      onTap: open ? () => widget.onRemoveDiscount(d) : null,
                    ),
                  for (final c in check.charges)
                    _TotalRow(
                      c.name,
                      c.amount,
                      key: ValueKey('charge-${c.chargeId}'),
                      onTap: open ? () => widget.onRemoveCharge(c) : null,
                    ),
                  const SizedBox(height: 2),
                  _TotalRow('Sales tax ${_rate(check.taxRatePct)}%', check.tax),
                  const Padding(padding: EdgeInsets.symmetric(vertical: 6), child: Divider(height: 1)),
                  _TotalRow(check.estimated ? 'Total (updating)' : 'Total', check.total, strong: true),
                  for (final p in order.payments)
                    _TotalRow(_paymentLabel(p), '−${p.amount}', key: ValueKey('paid-${p.paymentId}')),
                  if (order.payments.isNotEmpty) _TotalRow('Due', check.due, strong: true, key: const ValueKey('due')),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// A line: its quantity and seat, the dish, its price and the bin. Held by the dish, it can be dragged to
  /// another place or course (the quantity and the bin keep their own tap and hold).
  Widget _lineTile(BuildContext context, int index, LineRow row) {
    final line = row.line;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final posColors = PosColors.of(context);
    final priced = widget.check?.line(line.lineId);
    final changeable = widget.open && line.isActive;
    final isLatest = line.lineId == widget.lastAdded;
    Widget held(Widget child) => changeable
        ? ReorderableDelayedDragStartListener(
            index: index,
            child: SizedBox(width: double.infinity, child: child),
          )
        : child;
    final tile = ListTile(
      key: _keys.putIfAbsent(line.lineId, GlobalKey.new),
      dense: true,
      onTap: changeable ? () => widget.onEdit(line) : null,
      leading: _Hold(
        key: ValueKey('qty-${line.lineId}'),
        tooltip: 'Tap for one more, hold to type how many',
        onTap: changeable ? () => widget.onQty(line, line.qty + 1) : null,
        onLongPress: changeable ? () => widget.onTypeQty(line) : null,
        // the sync mark has its own fixed slot on the far left, so nothing moves when it shows
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 14,
              child: line.pending
                  ? Icon(
                      Icons.cloud_upload_outlined,
                      key: ValueKey('sending-${line.lineId}'),
                      size: 12,
                      color: scheme.primary,
                    )
                  : null,
            ),
            SizedBox(
              width: 40,
              height: 34,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: line.isVoid ? scheme.surfaceContainerHighest : scheme.surfaceContainer,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: scheme.outlineVariant),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          '${line.qty}×',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                            fontFeatures: PosTheme.tabular,
                          ),
                        ),
                        Text(
                          line.seat == null ? 'table' : 'seat ${line.seat}',
                          style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      title: held(
        Text(
          priced?.name ?? line.item,
          style: line.isVoid
              ? TextStyle(decoration: TextDecoration.lineThrough, color: scheme.onSurfaceVariant)
              : theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
      subtitle: held(
        Text(
          [
            ...?priced?.modifiers,
            if (line.isVoid) 'void',
            if (line.isActive && !line.fired && row.courseState != 'held') 'not sent yet',
            if (line.isActive && line.modifiedAfterFire) 'added after fire',
            if (line.note.isNotEmpty) line.note,
          ].join(' · '),
          style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // a fixed width, so a longer price does not push the name onto another line
          SizedBox(
            width: 60,
            child: Text(
              priced?.total ?? '',
              textAlign: TextAlign.end,
              maxLines: 1,
              style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600, fontFeatures: PosTheme.tabular),
            ),
          ),
          if (changeable)
            _Hold(
              key: ValueKey('bin-${line.lineId}'),
              tooltip: line.qty > 1
                  ? 'Tap for one fewer, hold to take them all off'
                  : (line.fired ? 'Void (sent to the kitchen)' : 'Remove'),
              onTap: () => widget.onQty(line, line.qty - 1),
              onLongPress: () => widget.onQty(line, 0),
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Icon(
                  line.fired ? Icons.block : Icons.delete_outline,
                  size: 20,
                  color: line.fired ? scheme.error : scheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
    if (!isLatest) return tile;
    return TweenAnimationBuilder<Color?>(
      key: ValueKey('flash-${line.lineId}'),
      tween: ColorTween(begin: posColors.highlightFlash, end: posColors.checkPaper),
      duration: const Duration(milliseconds: 650),
      curve: Curves.easeOutCubic,
      builder: (context, color, child) => Material(color: color ?? posColors.checkPaper, child: child),
      child: tile,
    );
  }

  /// A row let go at [to]: the check shows it there while its move is sent, or until the operator keeps it.
  Future<void> _dropped(List<CheckRow> rows, int from, int to) async {
    final row = rows[from];
    if (row is! LineRow) return;
    final where = placement(rows, from, to);
    final shown = [...rows]..removeAt(from);
    shown.insert(to.clamp(0, shown.length), row);
    setState(() => _rows = shown);
    try {
      await widget.onMove(row.line, course: where.course, rank: where.rank);
    } finally {
      if (mounted) setState(() => _rows = null);
    }
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

/// A course on the check: its name and state, or the name alone, dimmed, while nothing is under it (a
/// line can be dragged there).
class _CourseHeader extends StatelessWidget {
  const _CourseHeader({super.key, required this.name, required this.state});
  final String name;
  final String state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final posColors = PosColors.of(context);
    final fired = state == 'fired';
    final empty = state.isEmpty;
    final badgeBg = fired ? posColors.fired : posColors.waiting;
    final badgeFg = fired ? posColors.firedText : posColors.waitingText;
    final badgeBorder = fired ? posColors.firedBorder : posColors.waitingBorder;
    return Container(
      decoration: BoxDecoration(
        color: posColors.checkHeader,
        border: Border.symmetric(horizontal: BorderSide(color: theme.colorScheme.outlineVariant, width: 0.7)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      child: Row(
        children: [
          Text(
            name,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
              color: empty ? theme.colorScheme.onSurfaceVariant : null,
            ),
          ),
          const Spacer(),
          if (empty)
            const SizedBox(height: 20) // the row keeps the height of the state it will show
          else
            AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: badgeBg,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: badgeBorder.withValues(alpha: 0.5)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(fired ? Icons.local_fire_department : Icons.pause_circle_outline, size: 14, color: badgeFg),
                  const SizedBox(width: 4),
                  Text(
                    state,
                    style: theme.textTheme.labelSmall?.copyWith(color: badgeFg, fontWeight: FontWeight.w700),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Which seat and course the next dish goes to, and the seats at the table: + adds one, − takes the last
/// one away once nothing is on it. With coursing off ([courses] empty) the row is the seats alone.
class _SeatCourseBar extends StatelessWidget {
  const _SeatCourseBar({
    required this.seats,
    required this.seat,
    required this.course,
    required this.courses,
    required this.onSeat,
    required this.onAddSeat,
    required this.onRemoveSeat,
    required this.onCourse,
  });

  final int seats;
  final int? seat;
  final String? course;
  final List<Course> courses;
  final ValueChanged<int?> onSeat;
  final VoidCallback onAddSeat;
  final VoidCallback onRemoveSeat;
  final ValueChanged<String> onCourse;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
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
      chip('Table', seat == null, () => onSeat(null)),
      for (var i = 1; i <= seats; i++) chip('$i', seat == i, () => onSeat(i)),
      IconButton(
        tooltip: 'Remove seat $seats',
        visualDensity: VisualDensity.compact,
        icon: const Icon(Icons.remove_circle_outline),
        onPressed: seats > 0 ? onRemoveSeat : null,
      ),
      IconButton(
        tooltip: 'Add a seat',
        visualDensity: VisualDensity.compact,
        icon: const Icon(Icons.add_circle_outline),
        onPressed: onAddSeat,
      ),
    ];
    final courseChips = [
      if (courses.isNotEmpty) const Text('Course  '),
      for (final c in courses) chip(c.name, course == c.id, () => onCourse(c.id)),
    ];
    Widget row(List<Widget> children) => SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: children),
    );
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
      ),
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: compact(context) || courseChips.isEmpty
          // a phone: both on one line that scrolls, to leave the screen to the menu
          ? row([...seatChips, if (courseChips.isNotEmpty) const SizedBox(width: 8), ...courseChips])
          : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [row(seatChips), row(courseChips)]),
    );
  }
}

/// Fire one held course, or everything at once: and stay on the check, or leave it. With coursing off
/// (or dishes not coursed) only everything can go, and the button counts the dishes still to send.
class _FireMenu extends StatelessWidget {
  const _FireMenu({required this.order, required this.coursing, required this.onFire});

  final Order order;
  final Coursing coursing;
  final void Function(String course, {bool leave}) onFire;

  @override
  Widget build(BuildContext context) {
    final posColors = PosColors.of(context);
    final waiting = order.heldCourses;
    final held = [
      for (final c in coursing.courses)
        if (waiting.contains(c.id)) c,
    ];
    final unsent = order.activeLines.where((l) => !l.fired).length;
    final anyHeld = unsent > 0;
    final label = held.isNotEmpty
        ? 'Fire (${held.length} held)'
        : anyHeld
        ? 'Fire ($unsent to send)'
        : 'Fire';
    return PopupMenuButton<(String, bool)>(
      tooltip: 'Fire',
      onSelected: (choice) => onFire(choice.$1, leave: choice.$2),
      itemBuilder: (_) => [
        for (final c in held)
          PopupMenuItem(
            value: (c.id, false),
            child: Row(
              children: [
                Icon(Icons.local_fire_department, size: 18, color: posColors.waitingBorder),
                const SizedBox(width: 8),
                Flexible(child: Text('Fire ${c.name}', overflow: TextOverflow.ellipsis)),
              ],
            ),
          ),
        if (held.isNotEmpty) const PopupMenuDivider(),
        const PopupMenuItem(value: ('*', false), child: Text('Fire everything')),
        const PopupMenuItem(
          key: ValueKey('fire-and-leave'),
          value: ('*', true),
          child: Row(
            children: [
              Icon(Icons.logout, size: 18),
              SizedBox(width: 8),
              Flexible(child: Text('Fire everything and leave', overflow: TextOverflow.ellipsis)),
            ],
          ),
        ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: compact(context)
            ? Badge(
                isLabelVisible: anyHeld,
                label: Text('${held.isNotEmpty ? held.length : unsent}'),
                child: const Icon(Icons.local_fire_department),
              )
            : AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: anyHeld ? posColors.waiting : Colors.transparent,
                  borderRadius: BorderRadius.circular(10),
                  border: anyHeld ? Border.all(color: posColors.waitingBorder.withValues(alpha: 0.6)) : null,
                ),
                child: Row(
                  children: [
                    Icon(Icons.local_fire_department, size: 18, color: anyHeld ? posColors.waitingText : null),
                    const SizedBox(width: 4),
                    Text(
                      label,
                      style: anyHeld ? TextStyle(color: posColors.waitingText, fontWeight: FontWeight.w700) : null,
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}

/// "#42 Linda · 18:05" for the app bar of a to-go order; the hub gives the number when the create lands.
String _takeoutTitle(Order order) => [
  '#${order.orderNo ?? '…'} ${order.customerName.isEmpty ? 'To go' : order.customerName}',
  if (order.promisedAt != null) clockTime(order.promisedAt!),
  if (!order.isOpen) order.status,
].join(' · ');

/// "Paid cash (tendered 20.00)", "Paid elsewhere · sending".
String _paymentLabel(Payment p) =>
    ['Paid ${p.method}${p.tendered != null ? ' (tendered ${p.tendered})' : ''}', if (p.pending) 'sending'].join(' · ');

/// "Manager comp · on Peking Duck · Mike approved".
String _discountLabel(CheckDiscount d, Check check) {
  final on = d.lineId == null ? null : check.line(d.lineId!)?.name;
  return [d.name, if (on != null) 'on $on', if (d.approvedBy != null) '${d.approvedBy} approved'].join(' · ');
}

/// 7.00 -> 7, 6.25 -> 6.25.
String _rate(String pct) {
  final value = double.tryParse(pct);
  if (value == null) return pct;
  return value == value.roundToDouble() ? value.toStringAsFixed(0) : value.toString();
}

class _TotalRow extends StatelessWidget {
  const _TotalRow(this.label, this.amount, {super.key, this.strong = false, this.onTap});

  final String label;
  final String amount;
  final bool strong;

  /// Set on a discount or charge row: a tap takes it off.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final baseStyle = strong
        ? theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)
        : theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final row = Row(
      children: [
        Expanded(
          child: Text(label, style: baseStyle, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        Text(amount, style: baseStyle?.copyWith(fontFeatures: PosTheme.tabular)),
        if (onTap != null)
          Padding(
            padding: const EdgeInsets.only(left: 6),
            child: Icon(Icons.close, size: 14, color: theme.colorScheme.onSurfaceVariant),
          ),
      ],
    );
    if (onTap == null) return row;
    return InkWell(
      onTap: onTap,
      child: Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: row),
    );
  }
}
