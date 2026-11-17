import 'package:flutter/material.dart';

import '../shift_notes.dart';

/// A note's words, and under them who wrote it, when, and how long it is up.
class NoteWords extends StatelessWidget {
  const NoteWords({super.key, required this.note, this.now, this.faded = false, this.under});

  final ShiftNote note;

  /// The clock the days are worded against ("today", "yesterday"); the terminal's own when left out.
  final DateTime? now;

  /// A note that has come down: its words are greyed.
  final bool faded;

  /// What stands under the words in place of who wrote it and how long it is up.
  final String? under;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final at = now ?? DateTime.now();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          note.text,
          style: theme.textTheme.bodyLarge?.copyWith(color: faded ? scheme.onSurfaceVariant : scheme.onSurface),
        ),
        const SizedBox(height: 4),
        Text(
          under ?? '${noteByWords(note, at)} · ${lastsWords(note)}',
          style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

/// The notes somebody has not seen yet, shown once after they sign in (docs/shift-notes.md): the specials,
/// what is out. One button, "Got it", which pops true; the screen under it then tells the hub this person
/// has seen them. It does not close on a tap beside it: a note is read, not brushed away.
class ShiftNotesDialog extends StatelessWidget {
  const ShiftNotesDialog({super.key, required this.notes, this.now});

  /// The notes to read, the newest first.
  final List<ShiftNote> notes;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      key: const ValueKey('shift-notes'),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24), // a phone keeps its width
      icon: const Icon(Icons.sticky_note_2_outlined),
      title: Text(notes.length == 1 ? 'A note for the shift' : '${notes.length} notes for the shift'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (at, note) in notes.indexed) ...[
                if (at > 0) Divider(height: 20, color: theme.colorScheme.outlineVariant),
                NoteWords(key: ValueKey('shift-note:${note.id}'), note: note, now: now),
              ],
            ],
          ),
        ),
      ),
      actions: [
        FilledButton(
          key: const ValueKey('shift-notes-got-it'),
          autofocus: true,
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Got it'),
        ),
      ],
    );
  }
}
