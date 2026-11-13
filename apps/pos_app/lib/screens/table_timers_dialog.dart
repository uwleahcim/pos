import 'package:flutter/material.dart';

import '../api.dart';
import '../table_timers.dart';
import 'floor_view.dart' show stageIcon;
import 'theme.dart';

/// The table timers a manager sets for the location: whether each table on the floor map gets a countdown
/// ring, and for each thing a table can be waiting on the minutes until its ring turns amber and until it
/// runs out. Saved on the hub; every floor map follows at once.
class TableTimersDialog extends StatefulWidget {
  const TableTimersDialog({super.key, required this.api, required this.token, required this.timers});

  final PosApi api;
  final String token;
  final TableTimers timers;

  @override
  State<TableTimersDialog> createState() => _TableTimersDialogState();
}

class _TableTimersDialogState extends State<TableTimersDialog> {
  /// What each stage counts from, under its name.
  static const _from = {
    'sat': 'From when the table is seated',
    'unsent': 'From the first dish nobody sent',
    'held': 'From when the course before it went',
    'fired': 'From the last dish sent: a nudge to look in',
  };

  late bool _enabled = widget.timers.enabled;
  late final Map<String, TextEditingController> _warn = {
    for (final stage in timerStages) stage: TextEditingController(text: '${widget.timers.timesFor(stage).warn}'),
  };
  late final Map<String, TextEditingController> _late = {
    for (final stage in timerStages) stage: TextEditingController(text: '${widget.timers.timesFor(stage).late}'),
  };
  String? _message;
  bool _busy = false;

  @override
  void dispose() {
    for (final c in [..._warn.values, ..._late.values]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final stages = <String, StageTimes>{};
    for (final stage in timerStages) {
      final warn = int.tryParse(_warn[stage]!.text.trim()), late = int.tryParse(_late[stage]!.text.trim());
      final name = timerStageLabel(stage).toLowerCase();
      if (warn == null || late == null || warn < 0 || late < 0) {
        setState(() => _message = 'The minutes for "$name" must be whole numbers, 0 for never');
        return;
      }
      if (late > 0 && late <= warn) {
        setState(() => _message = 'For "$name", red must come after amber');
        return;
      }
      stages[stage] = StageTimes(warn: warn, late: late);
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final saved = await widget.api.saveTableTimers(widget.token, TableTimers(enabled: _enabled, stages: stages));
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

  Widget _minutes(String key, TextEditingController controller) => SizedBox(
    width: 58,
    child: TextField(
      key: ValueKey(key),
      controller: controller,
      enabled: _enabled,
      keyboardType: TextInputType.number,
      textAlign: TextAlign.center,
      decoration: const InputDecoration(isDense: true),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = PosColors.of(context);
    Widget heading(String text, Color fill, Color ink) => SizedBox(
      width: 58,
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(10)),
          child: Text(
            text,
            style: theme.textTheme.labelSmall?.copyWith(color: ink, fontWeight: FontWeight.w700),
          ),
        ),
      ),
    );
    return AlertDialog(
      title: const Text('Table timers'),
      contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SwitchListTile(
                key: const ValueKey('timers-enabled'),
                contentPadding: EdgeInsets.zero,
                value: _enabled,
                onChanged: (on) => setState(() => _enabled = on),
                title: const Text('Countdown ring on each table'),
              ),
              Text(
                'The ring starts whole and unwinds counter-clockwise, like a timer. It turns amber after the first '
                'number of minutes and runs out, flashing red, after the second. 0 is never.',
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  heading('Amber', colors.timerWarn, colors.timerWarnText),
                  const SizedBox(width: 8),
                  heading('Red', colors.timerLate, colors.timerLateText),
                ],
              ),
              for (final stage in timerStages)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    children: [
                      Icon(stageIcon(stage), size: 20, color: scheme.onSurfaceVariant),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(timerStageLabel(stage), style: theme.textTheme.bodyMedium),
                            Text(
                              _from[stage] ?? '',
                              style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      _minutes('timer-warn:$stage', _warn[stage]!),
                      const SizedBox(width: 8),
                      _minutes('timer-late:$stage', _late[stage]!),
                    ],
                  ),
                ),
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
        FilledButton(key: const ValueKey('timers-save'), onPressed: _busy ? null : _save, child: const Text('Save')),
      ],
    );
  }
}
