/// The order as this screen should show it right now: what the backend last returned, with this device's
/// own operations that it may not show yet laid on top. Taps show at once; the outbox sends them in the
/// background, and the next read from the backend replaces the guess with the real thing.
///
/// The rules mirror the backend's replay (pos.sync.oplog) for the operations a terminal sends. Only the
/// backend prices lines and computes tax: the totals here are an estimate, marked as such, until it answers.
library;

import 'api.dart';
import 'floor.dart';
import 'menu.dart';
import 'outbox.dart';

/// What the screen knew about a line it added: the price the menu showed, the choices picked, and the dish,
/// so the line can be shown priced and reopened before the backend has answered.
class LocalLine {
  const LocalLine({this.unitPrice, this.modifiers = const [], this.itemId, this.entryId});
  final String? unitPrice;
  final List<String> modifiers;
  final String? itemId;
  final String? entryId;
}

Order withLocalOps(Order order, List<Map<String, dynamic>> ops) {
  if (ops.isEmpty) return order;
  var status = order.status;
  final fields = {...order.fields};
  final lines = {for (final l in order.lines) l.lineId: l};
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
          entryId: req?.entryId,
          request: req,
          pending: true,
        );
      case 'set_line':
        final line = lines[data['line_id']];
        if (line != null && line.isActive) {
          lines[line.lineId] = line.copyWith(qty: data['qty'] as int?, note: data['note'] as String?, pending: true);
        }
      case 'void_line':
        final line = lines[data['line_id']];
        if (line != null && line.isActive) {
          lines[line.lineId] = line.copyWith(status: line.fired ? 'void' : 'removed', pending: true);
        }
      case 'fire':
        final course = data['course'] as String? ?? '*';
        for (final line in lines.values.toList()) {
          if (line.isActive && !line.fired && (course == '*' || line.course == course)) {
            lines[line.lineId] = line.copyWith(fired: true, pending: true);
          }
        }
      case 'close':
        if (status != 'void') status = 'closed';
      case 'reopen':
        if (status == 'closed') status = 'open';
      case 'void_order':
        status = 'void';
    }
  }
  return Order(
    orderId: order.orderId,
    status: status,
    fields: fields,
    lines: lines.values.toList(),
    fired: order.fired,
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
      active.any((l) => known[l.lineId]?.qty != l.qty) || known.keys.any((id) => !active.any((l) => l.lineId == id));
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
      lines.add(priced.qty == line.qty ? priced : priced.withQty(line.qty, money(total)));
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
        modifiers: local[line.lineId]!.modifiers,
      ),
    );
  }

  final net = {for (final l in lines) l.lineId: cents(l.total)}; // what each line is worth after its discounts
  final off = {for (final l in lines) l.lineId: 0};
  var checkOff = 0;
  final discounts = <CheckDiscount>[];
  for (final d in check?.discounts ?? const <CheckDiscount>[]) {
    final lineId = d.lineId;
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
    discounts.add(d.withAmount(money(amount)));
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
    total: money(discounted + chargeTotal + tax),
    estimated: true,
  );
}

/// This screen's own price for a configured line, from the menu it has: the size's price plus every chosen
/// extra that costs something (a choice marked "no" is free, as the backend makes it), with a problem for
/// each required choice still missing. Used only while no backend answers (ADR 6); the backend prices the
/// line for real once it is back.
Priced localPrice(String name, List<VariantOffer> variants, ItemDetail? detail, LineRequest request) {
  final variant = variants.where((v) => v.variantId == request.variantId).firstOrNull ?? variants.firstOrNull;
  var unit = variant == null ? 0 : cents(variant.price);
  final problems = <String>[];
  for (final g in detail?.groups ?? const <GroupDetail>[]) {
    final picked = request.selections[g.groupId] ?? const <String>[];
    if (g.required && picked.length < g.minSelect) problems.add('Choose ${g.name.toLowerCase()}');
    for (final o in g.options) {
      if (picked.contains(o.optionId) && !o.free && request.prefixes[o.optionId] != 'no') unit += cents(o.price);
    }
  }
  return Priced(name: name, unitPrice: money(unit), problems: problems, estimated: true);
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

/// The same orders as checks on their tables, for the floor map.
Map<String, List<TableCheck>> queuedChecks(Outbox outbox) {
  final out = <String, List<TableCheck>>{};
  final opened = <String, int>{}; // order id -> when its create was stamped
  final firedCourses = <String, Set<String>>{};
  for (final op in outbox.pendingOps) {
    final id = op['order_id'] as String;
    final wall = int.tryParse((op['hlc'] as String? ?? '').split('-').first);
    if (op['kind'] == 'create' && wall != null) opened[id] = wall;
    if (op['kind'] == 'fire') {
      firedCourses.putIfAbsent(id, () => {}).add((op['data'] as Map?)?['course'] as String? ?? '*');
    }
  }
  for (final order in queuedOrders(outbox)) {
    if (order.table.isEmpty || !order.isOpen) continue;
    out
        .putIfAbsent(order.table, () => [])
        .add(
          TableCheck(
            orderId: order.orderId,
            guests: order.fields['guests'] as int?,
            server: order.fields['server'] as String?,
            openedMs: opened[order.orderId],
            items: order.activeLines.fold(0, (n, l) => n + l.qty),
            fired: [...?firedCourses[order.orderId]],
            held: order.heldCourses.toList(),
          ),
        );
  }
  return out;
}

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
