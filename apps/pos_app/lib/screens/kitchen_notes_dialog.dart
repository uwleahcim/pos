import 'package:flutter/material.dart';

import '../api.dart';
import '../kitchen_notes.dart';

/// The one-tap notes to the kitchen a manager lists for the location (docs/kitchen-notes.md): short words,
/// in the order a dish's sheet shows them as buttons. Saved on the hub; every screen offers them on the next
/// dish opened.
class KitchenNotesDialog extends StatefulWidget {
  const KitchenNotesDialog({super.key, required this.api, required this.token, required this.notes});

  final PosApi api;
  final String token;
  final KitchenNotes notes;

  @override
  State<KitchenNotesDialog> createState() => _KitchenNotesDialogState();
}

/// One note as the dialog edits it, with a key for its row.
class _Note {
  _Note(this.key, String words) : controller = TextEditingController(text: words);
  final int key;
  final TextEditingController controller;
}

class _KitchenNotesDialogState extends State<KitchenNotesDialog> {
  final _notes = <_Note>[];
  final _removed = <_Note>[]; // off the list, their text boxes still leaving the screen
  int _added = 0; // rows made so far: the next row's key, never one a removed row had
  String? _message;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    for (final note in widget.notes.notes) {
      _notes.add(_Note(_added++, note));
    }
  }

  @override
  void dispose() {
    for (final note in [..._notes, ..._removed]) {
      note.controller.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final words = [for (final note in _notes) note.controller.text.trim().replaceAll(RegExp(r'\s+'), ' ')];
    String? problem;
    if (words.any((note) => note.isEmpty)) {
      problem = 'Every note needs its words';
    } else if (words.any((note) => note.contains(','))) {
      problem = 'A note holds no comma: two notes on a dish are told apart by one';
    } else if (words.map((note) => note.toLowerCase()).toSet().length != words.length) {
      problem = 'Two notes say the same';
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
      final saved = await widget.api.saveKitchenNotes(widget.token, KitchenNotes(words));
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
      title: const Text('Kitchen notes'),
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
                "One button each over a dish's note, in this order. A tap puts the words in the note, which "
                'prints under the dish.',
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
              if (_notes.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text('No note is listed: a note to the kitchen is typed.', style: theme.textTheme.bodyMedium),
                ),
              for (final note in _notes)
                Padding(
                  key: ValueKey('kitchen-note-row:${note.key}'),
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          key: ValueKey('kitchen-note-words:${note.key}'),
                          controller: note.controller,
                          maxLength: KitchenNotes.noteMax,
                          textCapitalization: TextCapitalization.sentences,
                          decoration: const InputDecoration(isDense: true, counterText: '', hintText: 'Note'),
                        ),
                      ),
                      IconButton(
                        key: ValueKey('kitchen-note-remove:${note.key}'),
                        tooltip: 'Remove this note',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => setState(() {
                          _notes.remove(note);
                          _removed.add(note);
                        }),
                      ),
                    ],
                  ),
                ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const ValueKey('kitchen-note-add'),
                  icon: const Icon(Icons.add),
                  label: const Text('Add note'),
                  onPressed: _notes.length >= KitchenNotes.most
                      ? null
                      : () => setState(() => _notes.add(_Note(_added++, ''))),
                ),
              ),
              if (_message != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    _message!,
                    key: const ValueKey('kitchen-notes-problem'),
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
          key: const ValueKey('kitchen-notes-save'),
          onPressed: _busy ? null : _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
