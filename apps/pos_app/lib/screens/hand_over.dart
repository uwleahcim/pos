import 'package:flutter/material.dart';

import '../api.dart';
import '../local_order.dart';
import '../outbox.dart';
import '../takeout.dart';
import 'pay_dialog.dart';

/// A to-go order's next step, from whichever screen it is tapped on (the list of checks, the deliveries):
/// Ready sends the customer their text (the hub does, once); picked up, or delivered, closes the check. An
/// order with money still due is asked for it as it is handed over (docs/catering.md): cash or paid
/// elsewhere, or not now, which closes the check with the rest still due, as an order nothing was paid on
/// always closed. [also] goes with the step in the same change: who a delivery left with.
///
/// False when whoever was asked for the money backed out: nothing was written.
Future<bool> setToGoStage(
  BuildContext context, {
  required Outbox outbox,
  required Order order,
  required String stage,
  String? by,
  Map<String, dynamic> also = const {},
}) async {
  PayChoice? paying;
  final due = order.due;
  if (stage == 'picked_up' && due != null && cents(due) > 0) {
    paying = await showDialog<PayChoice>(
      context: context,
      builder: (_) => PayDialog(due: due, channel: order.channel, payAtPickup: true, sends: false, handover: true),
    );
    if (paying == null || !context.mounted) return false;
  }
  await outbox.addAll(order.orderId, [
    if (paying != null && paying.takesMoney)
      (
        'pay',
        {
          'payment_id': outbox.newId(),
          'method': paying.method,
          'amount': paying.amount ?? due,
          'tendered': ?paying.tendered,
          if (paying.note.isNotEmpty) 'note': paying.note,
          'by': ?by,
        },
      ),
    ('set_field', {'stage': stage, ...also}),
    if (stage == 'picked_up') ('close', {}),
  ]);
  final tendered = paying?.tendered;
  final change = tendered == null ? 0 : cents(tendered) - cents(paying?.amount ?? due ?? '0');
  if (change > 0 && context.mounted) {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Change \$${money(change)}', key: const ValueKey('change-due')),
        actions: [FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Done'))],
      ),
    );
  }
  return true;
}
