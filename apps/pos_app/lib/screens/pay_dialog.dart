import 'package:flutter/material.dart';

import '../local_order.dart';
import '../takeout.dart';

/// Counter mode pays before the kitchen sees the order (architecture section 12, "Fast tender"): exact
/// cash or the next bill up with the change worked out, paid elsewhere with a note, or pay at pickup where
/// the location allows it for the channel (a phone order). Cards come with the payments phase.
///
/// With [partial], less than the whole may be taken (docs/catering.md): a deposit on an order for a later
/// day, with the rest still due. The same dialog takes money alone on an order ([sends] false), and asks
/// for what is still due as an order is handed over ([handover]).
class PayDialog extends StatefulWidget {
  const PayDialog({
    super.key,
    required this.due,
    required this.channel,
    this.payAtPickup = false,
    this.partial = false,
    this.sends = true,
    this.handover = false,
    this.delivery = false,
  });

  final String due;
  final String channel;

  /// Whether nothing may be taken now: the third way, beside cash and paid elsewhere.
  final bool payAtPickup;

  /// Whether a part of what is due may be taken: the amount can be typed.
  final bool partial;

  /// Whether the order goes to the kitchen with this ("Pay & send"); false takes the money and no more.
  final bool sends;

  /// Asked as the order is handed over: the third way closes the check with the money still due.
  final bool handover;

  /// The order is brought to the customer (docs/delivery.md): the third way is paid at the door, and no
  /// ready text says so.
  final bool delivery;

  @override
  State<PayDialog> createState() => _PayDialogState();
}

class _PayDialogState extends State<PayDialog> {
  String _method = 'cash';
  final _tendered = TextEditingController();
  final _note = TextEditingController();
  final _amount = TextEditingController();

  @override
  void initState() {
    super.initState();
    _tendered.text = widget.due;
    _amount.text = widget.due;
  }

  @override
  void dispose() {
    _tendered.dispose();
    _note.dispose();
    _amount.dispose();
    super.dispose();
  }

  /// What is taken now, in cents: the whole of what is due, or the part typed. Null while what is typed is
  /// no amount, nothing, or more than is due.
  int? get _taking {
    final whole = cents(widget.due);
    if (!widget.partial) return whole;
    final typed = double.tryParse(_amount.text.trim());
    if (typed == null) return null;
    final taking = cents(typed.toStringAsFixed(2));
    return taking > 0 && taking <= whole ? taking : null;
  }

  /// Exact, then the next bill up for each note in the drawer: 10.71 due offers 10.71, 15, 20, 50, 100.
  List<int> get _bills {
    final due = _taking ?? cents(widget.due);
    final out = <int>[due];
    for (final bill in [500, 1000, 2000, 5000, 10000]) {
      final up = (due + bill - 1) ~/ bill * bill;
      if (up > due && !out.contains(up)) out.add(up);
    }
    return out;
  }

  int? get _change {
    final taking = _taking;
    if (_method != 'cash' || taking == null) return null;
    final tendered = double.tryParse(_tendered.text.trim());
    if (tendered == null) return null;
    final change = cents(tendered.toStringAsFixed(2)) - taking;
    return change < 0 ? null : change;
  }

  bool get _ready => switch (_method) {
    'cash' => _change != null,
    'elsewhere' => _taking != null,
    _ => true,
  };

  void _done() {
    final amount = money(_taking ?? cents(widget.due));
    Navigator.of(context).pop(switch (_method) {
      'cash' => PayChoice(
        method: 'cash',
        amount: amount,
        tendered: money(cents(double.parse(_tendered.text.trim()).toStringAsFixed(2))),
      ),
      'elsewhere' => PayChoice(method: 'elsewhere', amount: amount, note: _note.text.trim()),
      _ => const PayChoice(),
    });
  }

  /// The amount typed: the cash handed over starts as exactly that.
  void _amountChanged(String _) => setState(() {
    final taking = _taking;
    if (taking != null) _tendered.text = money(taking);
  });

  /// The third way, where there is one: nothing is taken now.
  String get _laterLabel {
    if (widget.handover) return 'Not now';
    if (widget.channel == 'catering') return 'Later';
    return widget.delivery ? 'At the door' : 'At pickup';
  }

  String get _laterWords {
    if (widget.handover) return 'Nothing taken: the check closes with what is due still to pay.';
    if (widget.channel == 'catering') return 'Nothing taken now: it is paid when the order is handed over.';
    return widget.delivery
        ? 'Nothing taken now: it is paid at the door.'
        : 'Nothing taken now; the ready text says to pay at pickup.';
  }

  String get _doLabel {
    if (_method == 'later') return widget.handover ? 'Hand over' : 'Send';
    if (widget.sends) return 'Pay & send';
    return widget.handover ? 'Pay & hand over' : 'Pay';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final change = _change;
    final taking = _taking;
    final whole = cents(widget.due);
    return AlertDialog(
      title: Text('Due \$${widget.due}'),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // chips that wrap: three ways side by side do not fit a phone as one bar
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  for (final (method, label) in [
                    ('cash', 'Cash'),
                    ('elsewhere', 'Paid elsewhere'),
                    if (widget.payAtPickup) ('later', _laterLabel),
                  ])
                    ChoiceChip(
                      label: Text(label, key: ValueKey('pay:$method')),
                      selected: _method == method,
                      showCheckmark: false,
                      onSelected: (_) => setState(() => _method = method),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              // A deposit: the part taken now, with what stays due said under it.
              if (widget.partial && _method != 'later') ...[
                TextField(
                  key: const ValueKey('pay-amount'),
                  controller: _amount,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(
                    labelText: 'Amount taken now',
                    prefixText: '\$ ',
                    helperMaxLines: 2,
                    errorMaxLines: 2,
                    errorText: taking == null ? 'From 0.01 to ${widget.due}' : null,
                    helperText: taking != null && taking < whole
                        ? 'A deposit: \$${money(whole - taking)} stays due'
                        : null,
                  ),
                  onChanged: _amountChanged,
                ),
                const SizedBox(height: 12),
              ],
              if (_method == 'cash') ...[
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    for (final bill in _bills)
                      ChoiceChip(
                        key: ValueKey('tender:${money(bill)}'),
                        label: Text(bill == (taking ?? whole) ? 'Exact' : '\$${bill ~/ 100}'),
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
                if (taking != null)
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
              if (_method == 'later') Text(_laterWords, style: theme.textTheme.bodyMedium),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(key: const ValueKey('pay-send'), onPressed: _ready ? _done : null, child: Text(_doLabel)),
      ],
    );
  }
}
