import 'package:flutter/material.dart';

import '../api.dart';
import '../takeout.dart';

/// The quote times a manager sets by hand per channel until kitchen pacing quotes them (architecture
/// section 12, "Quote times"), and which channels may pay at pickup. Saved on the hub for every terminal.
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
  late final Map<String, TextEditingController> _minutes = {
    for (final c in _channels) c: TextEditingController(text: '${widget.quotes.minutesFor(c)}'),
  };
  late final Set<String> _payAtPickup = {...widget.quotes.payAtPickup};
  String? _message;
  bool _busy = false;

  @override
  void dispose() {
    for (final c in _minutes.values) {
      c.dispose();
    }
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
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final saved = await widget.api.saveQuotes(
        widget.token,
        Quotes(minutes: minutes, payAtPickup: _payAtPickup.toList()..sort()),
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
      content: SizedBox(
        width: 340,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Minutes promised for a new order, per channel.', style: theme.textTheme.bodyMedium),
            const SizedBox(height: 8),
            for (final channel in _channels)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    SizedBox(width: 90, child: Text(channelLabel(channel))),
                    SizedBox(
                      width: 90,
                      child: TextField(
                        key: ValueKey('quote:$channel'),
                        controller: _minutes[channel],
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(suffixText: 'min', isDense: true),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: CheckboxListTile(
                        key: ValueKey('pickup:$channel'),
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        title: const Text('Pay at pickup'),
                        value: _payAtPickup.contains(channel),
                        onChanged: (on) =>
                            setState(() => on! ? _payAtPickup.add(channel) : _payAtPickup.remove(channel)),
                      ),
                    ),
                  ],
                ),
              ),
            if (_message != null) Text(_message!, style: TextStyle(color: theme.colorScheme.error)),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(key: const ValueKey('quotes-save'), onPressed: _busy ? null : _save, child: const Text('Save')),
      ],
    );
  }
}
