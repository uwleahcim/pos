import 'package:flutter/material.dart';

import '../api.dart';
import '../takeout.dart';

/// The quote times a manager sets by hand per channel until kitchen pacing quotes them (architecture
/// section 12, "Quote times"), which channels may pay at pickup, and how many more minutes a big order is
/// promised. Saved on the hub for every terminal. Tonight's rush is not set here: it is a button on the
/// orders screen, and saving this leaves it as it is.
class QuotesDialog extends StatefulWidget {
  const QuotesDialog({super.key, required this.api, required this.token, required this.quotes});

  final PosApi api;
  final String token;
  final Quotes quotes;

  @override
  State<QuotesDialog> createState() => _QuotesDialogState();
}

class _QuotesDialogState extends State<QuotesDialog> {
  static const _channels = ['counter', 'phone', 'online', 'delivery'];
  static const _tickWidth = 76.0; // the column of "pay at pickup" ticks, under its heading
  late final Map<String, TextEditingController> _minutes = {
    for (final c in _channels) c: TextEditingController(text: '${widget.quotes.baseFor(c)}'),
  };
  late final Set<String> _payAtPickup = {...widget.quotes.payAtPickup};
  late final _bigDishes = TextEditingController(text: _shown(widget.quotes.bigDishes));
  late final _bigMinutes = TextEditingController(text: _shown(widget.quotes.bigMinutes));

  static String _shown(int n) => n > 0 ? '$n' : '';
  String? _message;
  bool _busy = false;

  @override
  void dispose() {
    for (final c in _minutes.values) {
      c.dispose();
    }
    _bigDishes.dispose();
    _bigMinutes.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final minutes = <String, int>{};
    for (final e in _minutes.entries) {
      final n = int.tryParse(e.value.text.trim());
      if (n == null || n < 0) {
        setState(() => _message = 'Minutes for ${channelLabel(e.key).toLowerCase()} must be a whole number');
        return;
      }
      minutes[e.key] = n;
    }
    // Both boxes filled make the rule; both empty (or 0) take it off. One alone would do nothing, so say so.
    final dishes = _bigDishes.text.trim().isEmpty ? 0 : int.tryParse(_bigDishes.text.trim());
    final more = _bigMinutes.text.trim().isEmpty ? 0 : int.tryParse(_bigMinutes.text.trim());
    if (dishes == null || more == null || dishes < 0 || more < 0 || (dishes > 0) != (more > 0)) {
      setState(() => _message = 'For big orders, fill in both the dishes and the minutes, or leave both empty');
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final saved = await widget.api.saveQuotes(
        widget.token,
        Quotes(
          minutes: minutes,
          payAtPickup: _payAtPickup.toList()..sort(),
          bigDishes: dishes,
          bigMinutes: more,
          takesBigOrders: widget.quotes.takesBigOrders,
        ),
      );
      if (mounted) Navigator.of(context).pop(saved);
    } on ApiException catch (err) {
      if (mounted) {
        setState(() {
          _busy = false;
          _message = err.message;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Quote times'),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24), // a phone keeps its width
      content: SizedBox(
        width: 340,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Minutes promised for a new order, per channel.', style: theme.textTheme.bodyMedium),
              const SizedBox(height: 8),
              // One row per channel under one heading for the tick, so a phone fits name, minutes and tick.
              Align(
                alignment: Alignment.centerRight,
                child: SizedBox(
                  width: _tickWidth,
                  child: Text(
                    'Pay at pickup',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
              ),
              for (final channel in _channels)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: [
                      Expanded(child: Text(channelLabel(channel), maxLines: 1, overflow: TextOverflow.ellipsis)),
                      SizedBox(
                        width: 90,
                        child: TextField(
                          key: ValueKey('quote:$channel'),
                          controller: _minutes[channel],
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(suffixText: 'min', isDense: true),
                        ),
                      ),
                      SizedBox(
                        width: _tickWidth,
                        child: Center(
                          child: Checkbox(
                            key: ValueKey('pickup:$channel'),
                            semanticLabel: '${channelLabel(channel)} may pay at pickup',
                            value: _payAtPickup.contains(channel),
                            onChanged: (on) =>
                                setState(() => on! ? _payAtPickup.add(channel) : _payAtPickup.remove(channel)),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              if (widget.quotes.takesBigOrders) ...[
                const Divider(height: 16),
                Text('Big orders', style: theme.textTheme.titleSmall),
                const SizedBox(height: 2),
                Text(
                  'An order with this many dishes or more is promised later. The time moves when the order is '
                  'sent, and the order screen shows it before. Leave both empty for no extra time.',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        key: const ValueKey('big-dishes'),
                        controller: _bigDishes,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: 'From', suffixText: 'dishes', isDense: true),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        key: const ValueKey('big-minutes'),
                        controller: _bigMinutes,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: 'Add', suffixText: 'min', isDense: true),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
              ],
              if (_message != null) Text(_message!, style: TextStyle(color: theme.colorScheme.error)),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(key: const ValueKey('quotes-save'), onPressed: _busy ? null : _save, child: const Text('Save')),
      ],
    );
  }
}
