import 'package:flutter/material.dart';

import '../api.dart';
import '../waste.dart';

/// The reasons of the waste log a manager lists for the location (docs/waste-log.md): short words, in the
/// order the buttons show when an entry is written. Saved on the hub. An entry keeps the words it was
/// written with, so rewording or removing a reason changes nothing in the log as it stands.
class WasteReasonsDialog extends StatefulWidget {
  const WasteReasonsDialog({super.key, required this.api, required this.token, required this.reasons});

  final PosApi api;
  final String token;
  final WasteReasons reasons;

  @override
  State<WasteReasonsDialog> createState() => _WasteReasonsDialogState();
}

/// One reason as the dialog edits it, with a key for its row.
class _Reason {
  _Reason(this.key, String words) : controller = TextEditingController(text: words);
  final int key;
  final TextEditingController controller;
}

class _WasteReasonsDialogState extends State<WasteReasonsDialog> {
  final _reasons = <_Reason>[];
  final _removed = <_Reason>[]; // off the list, their text boxes still leaving the screen
  int _added = 0; // rows made so far: the next row's key, never one a removed row had
  String? _message;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    for (final reason in widget.reasons.reasons) {
      _reasons.add(_Reason(_added++, reason));
    }
  }

  @override
  void dispose() {
    for (final reason in [..._reasons, ..._removed]) {
      reason.controller.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final words = [for (final reason in _reasons) reason.controller.text.trim().replaceAll(RegExp(r'\s+'), ' ')];
    String? problem;
    if (words.isEmpty) {
      problem = 'The log needs at least one reason to pick from';
    } else if (words.any((reason) => reason.isEmpty)) {
      problem = 'Every reason needs its words';
    } else if (words.map((reason) => reason.toLowerCase()).toSet().length != words.length) {
      problem = 'Two reasons say the same';
    }
    if (problem != null) {
      setState(() => _message = problem);
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final saved = await widget.api.saveWasteReasons(widget.token, words);
      if (mounted) Navigator.of(context).pop(saved);
    } on ApiException catch (err) {
      if (mounted) {
        setState(() {
          _busy = false;
          _message = err.status == null
              ? 'The hub is not answering, so the list was not saved.'
              : err.detail?['message'] as String? ?? err.message;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return AlertDialog(
      title: const Text('Waste reasons'),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24), // a phone keeps its width
      contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Why food goes into the waste log, one button each, in this order. A dish given to a guest is '
                'not waste: it is a comp, on the check.',
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
              for (final reason in _reasons)
                Padding(
                  key: ValueKey('waste-reason-row:${reason.key}'),
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          key: ValueKey('waste-reason-words:${reason.key}'),
                          controller: reason.controller,
                          maxLength: widget.reasons.reasonMax,
                          textCapitalization: TextCapitalization.sentences,
                          decoration: const InputDecoration(isDense: true, counterText: '', hintText: 'Reason'),
                        ),
                      ),
                      IconButton(
                        key: ValueKey('waste-reason-remove:${reason.key}'),
                        tooltip: 'Remove this reason',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => setState(() {
                          _reasons.remove(reason);
                          _removed.add(reason);
                        }),
                      ),
                    ],
                  ),
                ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const ValueKey('waste-reason-add'),
                  icon: const Icon(Icons.add),
                  label: const Text('Add reason'),
                  onPressed: _reasons.length >= widget.reasons.most
                      ? null
                      : () => setState(() => _reasons.add(_Reason(_added++, ''))),
                ),
              ),
              if (_message != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    _message!,
                    key: const ValueKey('waste-reasons-problem'),
                    style: TextStyle(color: scheme.error),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('waste-reasons-save'),
          onPressed: _busy ? null : _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
