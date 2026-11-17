import 'package:flutter/material.dart';

import '../api.dart';
import '../kitchen_screen.dart';
import 'theme.dart';

/// The colours of a ticket on the stations' screens, as a manager sets them for the location: the minutes a
/// ticket has been in the kitchen when it turns amber, and when it turns red. Saved on the hub; every
/// station's screen follows at once.
class KitchenMinutesDialog extends StatefulWidget {
  const KitchenMinutesDialog({super.key, required this.api, required this.token, required this.minutes});

  final PosApi api;
  final String token;
  final KitchenMinutes minutes;

  @override
  State<KitchenMinutesDialog> createState() => _KitchenMinutesDialogState();
}

class _KitchenMinutesDialogState extends State<KitchenMinutesDialog> {
  late final _warn = TextEditingController(text: '${widget.minutes.warn}');
  late final _late = TextEditingController(text: '${widget.minutes.late}');
  String? _message;
  bool _busy = false;

  @override
  void dispose() {
    _warn.dispose();
    _late.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final warn = int.tryParse(_warn.text.trim()), late = int.tryParse(_late.text.trim());
    if (warn == null || late == null || warn < 0 || late < 0) {
      setState(() => _message = 'The minutes must be whole numbers, 0 for never');
      return;
    }
    if (late > 0 && late <= warn) {
      setState(() => _message = 'Red must come after amber');
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final saved = await widget.api.saveKitchenMinutes(widget.token, KitchenMinutes(warn: warn, late: late));
      if (mounted) Navigator.of(context).pop(saved);
    } on ApiException catch (err) {
      if (mounted) {
        setState(() {
          _busy = false;
          _message = err.detail?['message'] as String? ?? err.message;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = PosColors.of(context);
    Widget row(String key, String title, String says, TextEditingController controller, Color fill, Color ink) =>
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              Container(
                width: 58,
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(vertical: 3),
                decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(10)),
                child: Text(
                  title,
                  style: theme.textTheme.labelMedium?.copyWith(color: ink, fontWeight: FontWeight.w700),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(child: Text(says, style: theme.textTheme.bodyMedium)),
              const SizedBox(width: 8),
              SizedBox(
                width: 58,
                child: TextField(
                  key: ValueKey(key),
                  controller: controller,
                  keyboardType: TextInputType.number,
                  textAlign: TextAlign.center,
                  decoration: const InputDecoration(isDense: true),
                ),
              ),
            ],
          ),
        );
    return AlertDialog(
      title: const Text('Kitchen screens'),
      contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      content: SizedBox(
        width: 340,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'A ticket on a station\'s screen changes colour by the minutes it has been in the kitchen. 0 is '
                'never.',
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 8),
              row('kitchen-warn', 'Amber', 'Minutes until amber', _warn, colors.timerWarn, colors.timerWarnText),
              row('kitchen-late', 'Red', 'Minutes until red', _late, colors.timerLate, colors.timerLateText),
              if (_message != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(_message!, style: TextStyle(color: scheme.error)),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('kitchen-minutes-save'),
          onPressed: _busy ? null : _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
