import 'package:flutter/material.dart';

import '../api.dart';
import '../voids.dart';

/// The most reasons a location lists, as the hub holds it: a screenful of buttons on a phone.
const maxVoidReasons = 12;

/// The void rules a manager sets for the location: whether voiding a dish the kitchen already has takes a
/// manager's PIN, and the reasons the person voiding picks from, in the order the buttons show. Saved on
/// the hub, which holds every void to them from the next one on.
class VoidRulesDialog extends StatefulWidget {
  const VoidRulesDialog({super.key, required this.api, required this.token, required this.rules});

  final PosApi api;
  final String token;
  final VoidRules rules;

  @override
  State<VoidRulesDialog> createState() => _VoidRulesDialogState();
}

/// One reason as the dialog edits it: its id once the hub has it, a key for the row either way.
class _Reason {
  _Reason(this.key, this.id, String name) : controller = TextEditingController(text: name);
  final int key;
  final String? id;
  final TextEditingController controller;
}

class _VoidRulesDialogState extends State<VoidRulesDialog> {
  late bool _needsManager = widget.rules.needsManager;
  final _reasons = <_Reason>[];
  final _removed = <_Reason>[]; // off the list, their text boxes still leaving the screen
  int _added = 0; // rows made so far: the next row's key, never one a removed row had
  String? _message;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    for (final reason in widget.rules.reasons) {
      _reasons.add(_Reason(_added++, reason.id, reason.name));
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
    final names = [for (final reason in _reasons) reason.controller.text.trim()];
    String? problem;
    if (names.isEmpty) {
      problem = 'List at least one reason to pick from';
    } else if (names.any((name) => name.isEmpty)) {
      problem = 'Every reason needs a name';
    } else if (names.map((name) => name.toLowerCase()).toSet().length != names.length) {
      problem = 'Two reasons have the same name';
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
      final saved = await widget.api.saveVoidRules(
        widget.token,
        VoidRules(
          needsManager: _needsManager,
          reasons: [for (final (i, reason) in _reasons.indexed) VoidReason(id: reason.id, name: names[i])],
        ),
      );
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
    return AlertDialog(
      title: const Text('Voids'),
      contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SwitchListTile(
                key: const ValueKey('voids-manager'),
                contentPadding: EdgeInsets.zero,
                value: _needsManager,
                onChanged: (on) => setState(() => _needsManager = on),
                title: const Text('A manager approves each void'),
                subtitle: Text(
                  _needsManager
                      ? "A manager's PIN is typed for every dish voided after it went to the kitchen"
                      : 'Whoever is on the check voids a sent dish with a reason alone',
                ),
              ),
              const SizedBox(height: 8),
              Text('Reasons', style: theme.textTheme.titleSmall),
              Text(
                'The person voiding picks one. A dish the kitchen has not seen comes off with nothing asked.',
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
              for (final reason in _reasons)
                Padding(
                  key: ValueKey('void-reason-row:${reason.key}'),
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          key: ValueKey('void-reason-name:${reason.key}'),
                          controller: reason.controller,
                          maxLength: 40,
                          textCapitalization: TextCapitalization.sentences,
                          decoration: const InputDecoration(isDense: true, counterText: '', hintText: 'Reason'),
                        ),
                      ),
                      IconButton(
                        key: ValueKey('void-reason-remove:${reason.key}'),
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
                  key: const ValueKey('void-reason-add'),
                  icon: const Icon(Icons.add),
                  label: const Text('Add reason'),
                  onPressed: _reasons.length >= maxVoidReasons
                      ? null
                      : () => setState(() => _reasons.add(_Reason(_added++, null, ''))),
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
        FilledButton(key: const ValueKey('voids-save'), onPressed: _busy ? null : _save, child: const Text('Save')),
      ],
    );
  }
}
