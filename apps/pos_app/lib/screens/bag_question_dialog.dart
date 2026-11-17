import 'package:flutter/material.dart';

import '../api.dart';
import '../bag.dart';

/// The to-go question a manager sets for the location (docs/to-go-question.md): whether a to-go order is
/// asked about before it is sent, the question's words, and what it offers, in the order the buttons show.
/// Saved on the hub; every screen asks by it from its next to-go order.
class BagQuestionDialog extends StatefulWidget {
  const BagQuestionDialog({super.key, required this.api, required this.token, required this.question});

  final PosApi api;
  final String token;
  final BagQuestion question;

  @override
  State<BagQuestionDialog> createState() => _BagQuestionDialogState();
}

/// One choice as the dialog edits it: its id once the hub has it, a key for the row either way.
class _Choice {
  _Choice(this.key, this.id, String name) : controller = TextEditingController(text: name);
  final int key;
  final String? id;
  final TextEditingController controller;
}

class _BagQuestionDialogState extends State<BagQuestionDialog> {
  late bool _enabled = widget.question.enabled;
  late final _words = TextEditingController(text: widget.question.question);
  final _choices = <_Choice>[];
  final _removed = <_Choice>[]; // off the list, their text boxes still leaving the screen
  int _added = 0; // rows made so far: the next row's key, never one a removed row had
  String? _message;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    for (final choice in widget.question.choices) {
      _choices.add(_Choice(_added++, choice.id, choice.name));
    }
  }

  @override
  void dispose() {
    _words.dispose();
    for (final choice in [..._choices, ..._removed]) {
      choice.controller.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final names = [for (final choice in _choices) choice.controller.text.trim()];
    String? problem;
    if (_enabled && names.isEmpty) {
      problem = 'List at least one thing to offer, or turn the question off';
    } else if (names.any((name) => name.isEmpty)) {
      problem = 'Every choice needs a name';
    } else if (names.map((name) => name.toLowerCase()).toSet().length != names.length) {
      problem = 'Two choices have the same name';
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
      final saved = await widget.api.saveBagQuestion(
        widget.token,
        BagQuestion(
          enabled: _enabled,
          question: _words.text.trim(),
          choices: [for (final (i, choice) in _choices.indexed) BagChoice(id: choice.id, name: names[i])],
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
      title: const Text('To-go question'),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24), // a phone keeps its width
      contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SwitchListTile(
                key: const ValueKey('bag-enabled'),
                contentPadding: EdgeInsets.zero,
                value: _enabled,
                onChanged: (on) => setState(() => _enabled = on),
                title: const Text('Ask before a to-go order is sent'),
                subtitle: Text(
                  _enabled
                      ? 'Once an order. It is not sent until somebody answers, and "Nothing" is an answer'
                      : 'To-go orders are sent with nothing asked',
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                key: const ValueKey('bag-words'),
                controller: _words,
                maxLength: BagQuestion.questionMax,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  isDense: true,
                  counterText: '',
                  labelText: 'The question',
                  hintText: BagQuestion.standardWords,
                ),
              ),
              const SizedBox(height: 12),
              Text('What it offers', style: theme.textTheme.titleSmall),
              Text(
                "One button each, in this order. The answer prints on the takeout station's ticket.",
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
              for (final choice in _choices)
                Padding(
                  key: ValueKey('bag-choice-row:${choice.key}'),
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          key: ValueKey('bag-choice-name:${choice.key}'),
                          controller: choice.controller,
                          maxLength: BagQuestion.nameMax,
                          textCapitalization: TextCapitalization.sentences,
                          decoration: const InputDecoration(isDense: true, counterText: '', hintText: 'Choice'),
                        ),
                      ),
                      IconButton(
                        key: ValueKey('bag-choice-remove:${choice.key}'),
                        tooltip: 'Remove this choice',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => setState(() {
                          _choices.remove(choice);
                          _removed.add(choice);
                        }),
                      ),
                    ],
                  ),
                ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const ValueKey('bag-choice-add'),
                  icon: const Icon(Icons.add),
                  label: const Text('Add choice'),
                  onPressed: _choices.length >= BagQuestion.mostChoices
                      ? null
                      : () => setState(() => _choices.add(_Choice(_added++, null, ''))),
                ),
              ),
              if (_message != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    _message!,
                    key: const ValueKey('bag-problem'),
                    style: TextStyle(color: scheme.error),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(key: const ValueKey('bag-save'), onPressed: _busy ? null : _save, child: const Text('Save')),
      ],
    );
  }
}
