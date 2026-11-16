/// The order as this screen should show it right now: what the backend last returned, with this device's
/// own operations that it may not show yet laid on top. Taps show at once; the outbox sends them in the
/// background, and the next read from the backend replaces the guess with the real thing.
///
/// The rules mirror the backend's replay (pos.sync.oplog) for the operations a terminal sends. Only the
/// backend prices lines and computes tax: the totals here are an estimate, marked as such, until it answers.
library;

import 'dart:math' as math;

import 'allergies.dart';
import 'api.dart';
import 'floor.dart';
import 'menu.dart';
import 'outbox.dart';

/// What the screen knew about a line it added: the price the menu showed, the choices picked, and the dish,
/// so the line can be shown priced and reopened before the backend has answered.
class LocalLine {
  const LocalLine({this.unitPrice, this.modifiers = const [], this.itemId, this.entryId});
  final String? unitPrice;

  /// Its choices with the price of each; the estimate works out what they add for the quantity.
  final List<CheckModifier> modifiers;
  final String? itemId;
  final String? entryId;
}

Order withLocalOps(Order order, List<Map<String, dynamic>> ops) {
  if (ops.isEmpty) return order;
  var status = order.status;
  final fields = {...order.fields};
  final lines = {for (final l in order.lines) l.lineId: l};
  final payments = [...order.payments];
  final allergies = [...order.allergies];
  for (final op in ops) {
    final data = (op['data'] as Map?)?.cast<String, dynamic>() ?? const {};
    switch (op['kind']) {
      case 'create' || 'set_field':
        fields.addAll(data);
      case 'add_line':
        final id = data['line_id'] as String;
        if (lines.containsKey(id)) continue; // the backend has it already
        final request = data['request'];
        final req = request is Map ? LineRequest.fromJson(request.cast<String, dynamic>()) : null;
        lines[id] = Line(
          lineId: id,
          item: data['item'] as String? ?? '',
          qty: data['qty'] as int? ?? 1,
          status: 'active',
          seat: data['seat'] as int?,
          course: data['course'] as String?,
          note: data['note'] as String? ?? '',
          // after everything on the check, as the hub places it
          rank: (data['rank'] as num?)?.toDouble() ?? lines.values.fold(0.0, (top, l) => math.max(top, l.rank)) + 1,
          entryId: req?.entryId,
          request: req,
          replaces: data['replaces'] as String?,
          by: data['by'] as String? ?? '',
          byId: data['by_id'] as String?,
          // an edit voids a dish and adds the changed one: it stays on the checks the dish was put on
          checks: checkNumbers(data['checks']) ?? lines[data['replaces']]?.checks,
          // a dish that came from another check already sent: the kitchen has it
          fired: data['from'] is Map && data['sent'] != null,
          pending: true,
        );
      case 'set_line':
        final line = lines[data['line_id']];
        if (line != null && line.isActive) {
          lines[line.lineId] = line.copyWith(
            qty: data['qty'] as int?,
            note: data['note'] as String?,
            seat: data['seat'] as int?,
            course: data['course'] as String?,
            clearCourse: data.containsKey('course') && data['course'] == null,
            rank: (data['rank'] as num?)?.toDouble(),
            checks: checkNumbers(data['checks']),
            clearChecks: data.containsKey('checks') && checkNumbers(data['checks']) == null,
            pending: true,
          );
        }
      case 'void_line':
        final line = lines[data['line_id']];
        if (line != null && line.isActive) {
          lines[line.lineId] = line.copyWith(status: line.fired ? 'void' : 'removed', pending: true);
        }
      case 'move_line':
        // gone to another check: off this one, sent or not, and no void
        final line = lines[data['line_id']];
        if (line != null && line.isActive && data['to'] is Map) {
          lines[line.lineId] = line.copyWith(status: 'removed', pending: true);
        }
      case 'allergy':
        // the latest word on a seat stands; one with nothing in it takes the seat's allergy off
        final told = Allergy.fromJson(data);
        allergies.removeWhere((a) => a.seat == told.seat);
        if (!told.isEmpty) allergies.add(told);
      case 'fire':
        final course = data['course'] as String? ?? '*';
        // sent when this screen stamped it, as the hub will say once it has it
        final at = int.tryParse((op['hlc'] as String? ?? '').split('-').first);
        for (final line in lines.values.toList()) {
          if (line.isActive && !line.fired && (course == '*' || line.course == course)) {
            lines[line.lineId] = line.copyWith(fired: true, sentMs: at, pending: true);
          }
        }
      case 'close':
        if (status != 'void') status = 'closed';
      case 'reopen':
        if (status == 'closed') status = 'open';
      case 'void_order':
        status = 'void';
      case 'pay':
        final id = data['payment_id'] as String? ?? '';
        if (id.isNotEmpty && !payments.any((p) => p.paymentId == id)) {
          payments.add(
            Payment(
              paymentId: id,
              method: data['method'] as String? ?? 'cash',
              amount: data['amount']?.toString() ?? '0',
              tendered: data['tendered']?.toString(),
              note: data['note'] as String? ?? '',
              by: data['by'] as String? ?? '',
              pending: true,
            ),
          );
        }
    }
  }
  return Order(
    orderId: order.orderId,
    status: status,
    fields: fields,
    lines: lines.values.toList(),
    fired: order.fired,
    payments: payments,
    allergies: allergies..sort((a, b) => (a.seat ?? 0).compareTo(b.seat ?? 0)),
    discounts: order.discounts,
    openedMs: order.openedMs,
  );
}

/// The backend's check, adjusted for lines this screen added or took off since: `estimated` until the backend
/// has priced them. Tax uses the backend's own rates and rounding (half up, per component, on the check).
///
/// The discounts and charges the backend last applied are worked out again on the new lines in its order:
/// on a line first (a comp is the line, a percentage of it, an amount up to it), then on the check, then
/// charges on what is left, then tax on the discounted lines and the taxed charges.
Check estimateCheck(Check? check, Order order, Map<String, LocalLine> local) {
  final active = order.activeLines;
  final known = {for (final l in check?.lines ?? const <CheckLine>[]) l.lineId: l};
  final changed =
      active.any((l) => known[l.lineId]?.qty != l.qty) ||
      known.keys.any((id) => !active.any((l) => l.lineId == id)) ||
      order.payments.length != (check?.payments.length ?? 0);
  if (check != null && !changed) return check;

  final lines = <CheckLine>[];
  var subtotal = 0;
  for (final line in active) {
    final priced = known[line.lineId];
    if (priced != null) {
      // the backend's price for one, times the quantity on this screen
      final total = priced.qty == line.qty || priced.qty == 0
          ? cents(priced.total)
          : cents(priced.total) ~/ priced.qty * line.qty;
      lines.add(
        priced.qty == line.qty
            ? priced
            : priced.withQty(line.qty, money(total), modifiers: _forQty(priced.modifiers, line.qty)),
      );
      subtotal += total;
      continue;
    }
    final price = local[line.lineId]?.unitPrice;
    if (price == null) continue; // added on another device: its price comes with the next read
    final total = cents(price) * line.qty;
    subtotal += total;
    lines.add(
      CheckLine(
        lineId: line.lineId,
        name: line.item,
        qty: line.qty,
        total: money(total),
        seat: line.seat,
        modifiers: _forQty(local[line.lineId]!.modifiers, line.qty),
      ),
    );
  }

  final net = {for (final l in lines) l.lineId: cents(l.total)}; // what each line is worth after its discounts
  final off = {for (final l in lines) l.lineId: 0};
  var checkOff = 0;
  final discounts = <CheckDiscount>[];
  for (final d in check?.discounts ?? const <CheckDiscount>[]) {
    // an edit voids a line and adds the changed dish as a new one: a comp on the old line is on the new
    final lineId = d.lineId == null ? null : order.currentLine(d.lineId!);
    if (lineId != null && !net.containsKey(lineId)) continue; // its line came off
    final base = lineId == null ? net.values.fold(0, (a, b) => a + b) - checkOff : net[lineId]!;
    var amount = switch (d.kind) {
      'comp' => base,
      'percent' => _percentOf(base, d.value),
      _ => cents(d.value),
    };
    amount = amount.clamp(0, base);
    if (lineId == null) {
      checkOff += amount;
    } else {
      net[lineId] = base - amount;
      off[lineId] = off[lineId]! + amount;
    }
    discounts.add(d.withAmount(money(amount), lineId: lineId));
  }
  final discounted = net.values.fold(0, (a, b) => a + b) - checkOff;
  final charges = <CheckCharge>[];
  var chargeTotal = 0;
  var taxedCharges = 0;
  for (final c in check?.charges ?? const <CheckCharge>[]) {
    final amount = c.kind == 'percent' ? _percentOf(discounted, c.value) : cents(c.value);
    chargeTotal += amount;
    if (c.taxed) taxedCharges += amount;
    charges.add(c.withAmount(money(amount)));
  }

  final rates = [for (final t in check?.taxLines ?? const <TaxLine>[]) t.ratePct];
  if (rates.isEmpty && (check?.taxRatePct ?? '').isNotEmpty) rates.add(check!.taxRatePct);
  final tax = rates.fold(0, (sum, rate) => sum + _percentOf(discounted + taxedCharges, rate));
  final total = discounted + chargeTotal + tax;
  final paid = order.payments.fold(0, (sum, p) => sum + cents(p.amount));
  return Check(
    lines: [
      for (final l in lines)
        off[l.lineId] == 0 && !l.isDiscounted ? l : l.withQty(l.qty, l.total, discount: money(off[l.lineId]!)),
    ],
    subtotal: money(subtotal),
    discounts: discounts,
    discountTotal: money(subtotal - discounted),
    charges: charges,
    chargeTotal: money(chargeTotal),
    taxLines: check?.taxLines ?? const [],
    tax: money(tax),
    taxRatePct: check?.taxRatePct ?? '',
    total: money(total),
    payments: check?.payments ?? const [],
    paid: money(paid),
    due: money(total - paid < 0 ? 0 : total - paid),
    estimated: true,
    // what each check of a split table comes to is the hub's to say: none here until it answers
    split: check?.split ?? SplitMode.one,
    splits: check?.splits ?? false,
    moves: check?.moves ?? false,
  );
}

/// This screen's own price for a configured line, from the menu it has: the size's price plus every chosen
/// extra that costs something (a choice marked "no" is free and one marked Extra is charged again where the
/// menu says so, as the backend has it), the choices on a
/// chosen dish included, with a problem for each required choice still missing. Used only while no backend
/// answers (ADR 6); the backend prices the line for real once it is back.
Priced localPrice(String name, List<VariantOffer> variants, ItemDetail? detail, LineRequest request) {
  final variant = variants.where((v) => v.variantId == request.variantId).firstOrNull ?? variants.firstOrNull;
  final problems = <String>[];
  final unit =
      (variant == null ? 0 : cents(variant.price)) + choicesPrice(detail?.groups ?? const [], request, problems);
  return Priced(name: name, unitPrice: money(unit), problems: problems, estimated: true);
}

/// What the choices add to one of a dish, in cents, down through the choices on any chosen dish; a problem
/// goes on [problems] for each required group still short ("Choose sauce for Kappa Maki" one level down).
int choicesPrice(List<GroupDetail> groups, Choices choices, List<String> problems, {String? on}) {
  var total = 0;
  for (final g in groups) {
    final picked = choices.selections[g.groupId] ?? const <String>[];
    if (g.required && choices.units(g.groupId) < g.minSelect) {
      problems.add(on == null ? 'Choose ${g.name.toLowerCase()}' : 'Choose ${g.name.toLowerCase()} for $on');
    }
    for (final o in g.options) {
      if (!picked.contains(o.optionId)) continue;
      total += choiceCents(g, o, choices.prefixes[o.optionId], choices.qty(o.optionId));
      if (o.groups.isNotEmpty) {
        total += choicesPrice(o.groups, choices.nested[o.optionId] ?? Choices(), problems, on: o.name);
      }
    }
  }
  return total;
}

/// Orders this device opened that no backend has heard of yet (their `create` is still queued): the list
/// and the floor map show them while the screen is capturing only, so a check can be reopened to add to it.
List<Order> queuedOrders(Outbox outbox) {
  final byOrder = <String, List<Map<String, dynamic>>>{};
  for (final op in outbox.pendingOps) {
    byOrder.putIfAbsent(op['order_id'] as String, () => []).add(op);
  }
  return [
    for (final MapEntry(key: id, value: ops) in byOrder.entries)
      if (ops.any((op) => op['kind'] == 'create')) withLocalOps(Order.empty(id), ops),
  ];
}

/// The same orders as checks on their tables, for the floor map. Each carries a timer worked out here the
/// way the hub does once it hears of the check, near enough for a countdown ring while it has not: sat since
/// the check was opened, dishes unsent since the first was added, a course held or everything sent since
/// the last fire.
Map<String, List<TableCheck>> queuedChecks(Outbox outbox) {
  final out = <String, List<TableCheck>>{};
  final opened = <String, int>{}; // order id -> when its create was stamped
  final firstLine = <String, int>{}; // -> when its first dish was added
  final lastFire = <String, int>{}; // -> when it was last fired
  final firedCourses = <String, Set<String>>{};
  for (final op in outbox.pendingOps) {
    final id = op['order_id'] as String;
    final wall = int.tryParse((op['hlc'] as String? ?? '').split('-').first);
    if (op['kind'] == 'create' && wall != null) opened[id] = wall;
    if (op['kind'] == 'add_line' && wall != null) firstLine.putIfAbsent(id, () => wall);
    if (op['kind'] == 'fire') {
      firedCourses.putIfAbsent(id, () => {}).add((op['data'] as Map?)?['course'] as String? ?? '*');
      if (wall != null) lastFire[id] = wall;
    }
  }
  for (final order in queuedOrders(outbox)) {
    if (order.table.isEmpty || !order.isOpen) continue;
    final id = order.orderId;
    final held = order.heldCourses.toList();
    final (stage, since) = order.activeLines.isEmpty
        ? ('sat', opened[id])
        : !firedCourses.containsKey(id)
        ? ('unsent', firstLine[id])
        : (held.isEmpty ? 'fired' : 'held', lastFire[id]);
    out
        .putIfAbsent(order.table, () => [])
        .add(
          TableCheck(
            orderId: id,
            guests: order.fields['guests'] as int?,
            server: order.fields['server'] as String?,
            serverId: order.fields['server_id'] as String?,
            openedMs: opened[id],
            items: order.activeLines.fold(0, (n, l) => n + l.qty),
            fired: [...?firedCourses[id]],
            held: held,
            timer: since == null ? null : TableTimer(stage: stage, sinceMs: since),
          ),
        );
  }
  return out;
}

/// The checks handed to another server on this device that no backend has heard of yet: order id -> the
/// server's name and id, the last hand-over winning.
Map<String, (String?, String?)> queuedServers(Outbox outbox) => {
  for (final op in outbox.pendingOps)
    if (op['kind'] == 'set_field')
      if (op['data'] case {'server': final String? name, 'server_id': final String? id})
        op['order_id'] as String: (name, id),
};

/// The checks this device moved to another table that no backend has heard of yet (order id -> table id,
/// the last move winning), and the ones it emptied into another check and closed.
(Map<String, String>, Set<String>) queuedTables(Outbox outbox) {
  final moved = <String, String>{};
  final gone = <String>{};
  final created = <String>{};
  for (final op in outbox.pendingOps) {
    final id = op['order_id'] as String;
    final data = (op['data'] as Map?) ?? const {};
    if (op['kind'] == 'create') created.add(id); // a check opened here: `queuedChecks` puts it on the map
    if (op['kind'] != 'set_field') continue;
    if (data['table'] != null && !created.contains(id)) moved[id] = data['table'].toString();
    if (data['merged_into'] != null) gone.add(id);
  }
  return (moved, gone);
}

/// What a choice changes on a line, with its sign: "+0.50"; a choice that takes something off reads the
/// accounting way, "(2.00)"; one that changes nothing reads as nothing.
String priceChange(String amount) {
  final value = cents(amount);
  if (value == 0) return '';
  return value > 0 ? '+${money(value)}' : inParens(amount);
}

/// What a discount took off, the accounting way: "(30.00)".
String inParens(String amount) => '(${money(cents(amount).abs())})';

/// A line's choices with what each adds for [qty] of the dish.
List<CheckModifier> _forQty(List<CheckModifier> modifiers, int qty) => [
  for (final m in modifiers)
    CheckModifier(m.label, price: m.price, amount: money(cents(m.price) * qty), depth: m.depth),
];

/// "17.95" -> 1795.
int cents(String amount) {
  final negative = amount.startsWith('-');
  final parts = amount.replaceFirst('-', '').split('.');
  final whole = int.tryParse(parts[0]) ?? 0;
  final frac = parts.length > 1 ? int.tryParse(parts[1].padRight(2, '0').substring(0, 2)) ?? 0 : 0;
  final value = whole * 100 + frac;
  return negative ? -value : value;
}

/// 1795 -> "17.95".
String money(int cents) {
  final sign = cents < 0 ? '-' : '';
  final abs = cents.abs();
  return '$sign${abs ~/ 100}.${(abs % 100).toString().padLeft(2, '0')}';
}

/// `rate` percent of `amount` cents, rounded half up: "6.25" of 1795 -> 112.
int _percentOf(int amount, String rate) {
  final basisPoints = cents(rate); // 6.25 % -> 625
  return (amount * basisPoints + 5000) ~/ 10000;
}
