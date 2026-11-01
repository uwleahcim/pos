import 'package:flutter/material.dart';

import '../local_order.dart';
import '../takeout.dart';

/// Counter mode pays before the kitchen sees the order (architecture section 12, "Fast tender"): exact
/// cash or the next bill up with the change worked out, paid elsewhere with a note, or pay at pickup where
/// the location allows it for the channel (a phone order). Cards come with the payments phase.
class PayDialog extends StatefulWidget {
  const PayDialog({super.key, required this.due, required this.channel, this.payAtPickup = false});

  final String due;
  final String channel;
  final bool payAtPickup;

  @override
  State<PayDialog> createState() => _PayDialogState();
}

class _PayDialogState extends State<PayDialog> {
  String _method = 'cash';
  final _tendered = TextEditingController();
  final _note = TextEditingController();

  @override
  void initState() {
    super.initState();
    _tendered.text = widget.due;
  }

  @override
  void dispose() {
    _tendered.dispose();
    _note.dispose();
    super.dispose();
  }

  /// Exact, then the next bill up for each note in the drawer: 10.71 due offers 10.71, 15, 20, 50, 100.
  List<int> get _bills {
    final due = cents(widget.due);
    final out = <int>[due];
    for (final bill in [500, 1000, 2000, 5000, 10000]) {
      final up = (due + bill - 1) ~/ bill * bill;
      if (up > due && !out.contains(up)) out.add(up);
    }
    return out;
  }

  int? get _change {
    if (_method != 'cash') return null;
    final tendered = double.tryParse(_tendered.text.trim());
    if (tendered == null) return null;
    final change = cents(tendered.toStringAsFixed(2)) - cents(widget.due);
    return change < 0 ? null : change;
  }

  bool get _ready => switch (_method) {
    'cash' => _change != null,
    _ => true,
  };

  void _done() {
    Navigator.of(context).pop(switch (_method) {
      'cash' => PayChoice(
        method: 'cash',
        tendered: money(cents(double.parse(_tendered.text.trim()).toStringAsFixed(2))),
      ),
      'elsewhere' => PayChoice(method: 'elsewhere', note: _note.text.trim()),
      _ => const PayChoice(),
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final change = _change;
    return AlertDialog(
      title: Text('Due \$${widget.due}'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SegmentedButton<String>(
              segments: [
                const ButtonSegment(
                  value: 'cash',
                  label: Text('Cash', key: ValueKey('pay:cash')),
                ),
                const ButtonSegment(
                  value: 'elsewhere',
                  label: Text('Paid elsewhere', key: ValueKey('pay:elsewhere')),
                ),
                if (widget.payAtPickup)
                  const ButtonSegment(
                    value: 'later',
                    label: Text('At pickup', key: ValueKey('pay:later')),
                  ),
              ],
              selected: {_method},
              showSelectedIcon: false,
              onSelectionChanged: (s) => setState(() => _method = s.first),
            ),
            const SizedBox(height: 12),
            if (_method == 'cash') ...[
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  for (final bill in _bills)
                    ChoiceChip(
                      key: ValueKey('tender:${money(bill)}'),
                      label: Text(bill == cents(widget.due) ? 'Exact' : '\$${bill ~/ 100}'),
                      selected: _tendered.text == money(bill),
                      onSelected: (_) => setState(() => _tendered.text = money(bill)),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              TextField(
                key: const ValueKey('tendered'),
                controller: _tendered,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Cash tendered', prefixText: '\$ '),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 10),
              Text(
                change == null ? 'Not enough' : 'Change \$${money(change)}',
                key: const ValueKey('change'),
                style: theme.textTheme.titleMedium?.copyWith(color: change == null ? scheme.error : null),
              ),
            ],
            if (_method == 'elsewhere')
              TextField(
                key: const ValueKey('pay-note'),
                controller: _note,
                decoration: const InputDecoration(labelText: 'Paid how? (optional)', hintText: 'e.g. by phone'),
              ),
            if (_method == 'later')
              Text('Nothing taken now; the ready text says to pay at pickup.', style: theme.textTheme.bodyMedium),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('pay-send'),
          onPressed: _ready ? _done : null,
          child: Text(_method == 'later' ? 'Send' : 'Pay & send'),
        ),
      ],
    );
  }
}
