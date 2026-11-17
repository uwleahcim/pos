import 'package:flutter/material.dart';

import '../api.dart';
import '../session.dart' show Staff;
import '../shift_notes.dart';
import 'menu_editor.dart' show ManagerPinDialog;
import 'shift_notes_dialog.dart' show NoteWords;
import 'span_report.dart' show reportError;

/// What a manager typed for a note: its words and how long it is up (`tonight` or `stays`).
typedef NoteDraft = ({String text, String lasts});

/// The notes for the shift (docs/shift-notes.md).
///
/// For everybody: the notes that are up, to read again after the one time each came up by itself.
///
/// For a manager, once their PIN is typed (or the screen was opened from Location, which has it already):
/// writing a note, changing one, taking one down, who has seen each and who has not yet, and the notes that
/// came down in the last two weeks. The hub makes the rules; a note is never deleted, only taken down.
class ShiftNotesScreen extends StatefulWidget {
  const ShiftNotesScreen({super.key, required this.api, required this.device, this.staff, this.token, this.now});

  final PosApi api;
  final String device;

  /// Who is reading: the notes are read for them, and a manager among them is offered the changes.
  final Staff? staff;

  /// A manager's session (`POST /admin/session`), when the screen was opened from Location. Without one a
  /// manager types their PIN before the first change.
  final String? token;

  /// The clock the days are worded against; the terminal's own when left out.
  final DateTime Function()? now;

  @override
  State<ShiftNotesScreen> createState() => _ShiftNotesScreenState();
}

class _ShiftNotesScreenState extends State<ShiftNotesScreen> {
  late String? _token = widget.token;
  MyNotes? _mine;
  NotesBoard? _board;
  String? _error;
  bool _old = false; // the hub is older than the notes
  int _asked = 0;

  bool get _mayManage => _token != null || const {'manager', 'owner'}.contains(widget.staff?.role);
  DateTime get _now => widget.now?.call() ?? DateTime.now();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final ask = ++_asked;
    setState(() => _error = null);
    try {
      final token = _token;
      if (token != null) {
        final board = await widget.api.notesBoard(token);
        if (!mounted || ask != _asked) return;
        setState(() => _board = board);
        return;
      }
      final staff = widget.staff;
      final mine = staff == null ? const MyNotes() : await widget.api.shiftNotes(staff.staffId);
      if (!mounted || ask != _asked) return;
      setState(() {
        _mine = mine ?? const MyNotes();
        _old = mine == null;
      });
    } on ApiException catch (err) {
      if (!mounted || ask != _asked) return;
      if (_expired(err)) return;
      setState(() => _error = reportError(err, 'the notes for the shift'));
    }
  }

  /// The manager's hour ran out on a screen that asked for the PIN itself: it goes back to reading, and the
  /// next change asks for the PIN again.
  bool _expired(ApiException err) {
    if (widget.token != null || _token == null || (err.status != 401 && err.status != 403)) return false;
    setState(() {
      _token = null;
      _board = null;
    });
    _say("The manager's hour is over. Type the PIN again to change the notes.");
    _load();
    return true;
  }

  void _say(String words, {String? key}) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.hideCurrentSnackBar();
    messenger?.showSnackBar(SnackBar(key: key == null ? null : ValueKey(key), content: Text(words)));
  }

  /// A manager's PIN, once: the screen then shows who has seen each note and offers the changes.
  Future<bool> _unlock() async {
    if (_token != null) return true;
    final token = await showDialog<String>(
      context: context,
      builder: (_) => ManagerPinDialog(
        api: widget.api,
        device: widget.device,
        action: 'Change the notes',
        what: 'write or change the notes',
      ),
    );
    if (token == null || !mounted) return false;
    setState(() => _token = token);
    await _load();
    return mounted && _token != null;
  }

  Future<void> _change(Future<void> Function(String token) call, String said, String key) async {
    final token = _token;
    if (token == null) return;
    try {
      await call(token);
      if (!mounted) return;
      _say(said, key: key);
    } on ApiException catch (err) {
      if (!mounted || _expired(err)) return;
      _say(reportError(err, 'the notes for the shift'), key: 'notes-refused');
    }
    if (mounted) await _load();
  }

  Future<void> _write() async {
    final typed = await showDialog<NoteDraft>(
      context: context,
      builder: (_) => NoteFormDialog(textMax: _board?.textMax ?? 500),
    );
    if (typed == null || !mounted) return;
    await _change(
      (token) => widget.api.writeNote(token, text: typed.text, lasts: typed.lasts),
      'The note is up. Everybody sees it once.',
      'note-up',
    );
  }

  Future<void> _edit(ShiftNote note) async {
    final typed = await showDialog<NoteDraft>(
      context: context,
      builder: (_) => NoteFormDialog(note: note, textMax: _board?.textMax ?? 500),
    );
    if (typed == null || !mounted) return;
    final again = typed.text != note.text;
    await _change(
      (token) => widget.api.changeNote(token, note.id, text: typed.text, lasts: typed.lasts),
      again ? 'Changed. Everybody sees it again.' : 'Changed.',
      'note-changed',
    );
  }

  Future<void> _takeDown(ShiftNote note) async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        title: const Text('Take this note down?'),
        content: const Text('Nobody is shown it any more. It stays in the list of notes that came down.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Keep it up')),
          FilledButton(
            key: const ValueKey('note-down-sure'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Take down'),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    await _change((token) => widget.api.takeNoteDown(token, note.id), 'Taken down.', 'note-down');
  }

  /// Who has seen a note and when, and who has not yet.
  Future<void> _whoSaw(ShiftNote note, NotesBoard board) => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) {
      final theme = Theme.of(context);
      final scheme = theme.colorScheme;
      final label = theme.textTheme.labelLarge?.copyWith(color: scheme.primary);
      final now = _now;
      return SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.7),
          child: ListView(
            key: const ValueKey('note-who'),
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            children: [
              Text(seenWords(note, board.staff), style: theme.textTheme.titleMedium),
              if (note.waiting.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text('Not yet', style: label),
                const SizedBox(height: 2),
                Text(note.waiting.join(', '), key: const ValueKey('note-waiting'), style: theme.textTheme.bodyLarge),
              ],
              if (note.seenBy.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text('Seen', style: label),
                for (final seen in note.seenBy)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Row(
                      children: [
                        Expanded(child: Text(seen.name, style: theme.textTheme.bodyLarge)),
                        Text(
                          whenWords(seen.atMs, now),
                          style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
              ],
            ],
          ),
        ),
      );
    },
  );

  Widget _managed(ShiftNote note, NotesBoard board) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final waiting = note.waiting;
    final seen = [seenWords(note, board.staff), if (waiting.isNotEmpty) 'not yet: ${waiting.join(', ')}'].join(' · ');
    return Card(
      key: ValueKey('note:${note.id}'),
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 6, 2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: NoteWords(note: note, now: _now),
            ),
            InkWell(
              key: ValueKey('note-seen:${note.id}'),
              onTap: () => _whoSaw(note, board),
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: const EdgeInsets.only(top: 6, bottom: 4, right: 8),
                child: Row(
                  children: [
                    Icon(Icons.visibility_outlined, size: 16, color: scheme.primary),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        seen,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(color: scheme.primary),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: OverflowBar(
                spacing: 4,
                alignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    key: ValueKey('note-change:${note.id}'),
                    onPressed: () => _edit(note),
                    child: const Text('Change'),
                  ),
                  TextButton(
                    key: ValueKey('note-down:${note.id}'),
                    onPressed: () => _takeDown(note),
                    child: const Text('Take down'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _read(ShiftNote note, {String? under, bool faded = false}) => Card(
    key: ValueKey('note:${note.id}'),
    margin: const EdgeInsets.only(bottom: 10),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: SizedBox(
        width: double.infinity,
        child: NoteWords(note: note, now: _now, under: under, faded: faded),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final board = _board;
    final mine = _mine;
    final Widget body;
    if (_error != null && board == null && mine == null) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!, key: const ValueKey('notes-error'), textAlign: TextAlign.center),
              const SizedBox(height: 12),
              OutlinedButton(onPressed: _load, child: const Text('Try again')),
            ],
          ),
        ),
      );
    } else if (board == null && mine == null) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_old) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'This hub is older than the notes for the shift. Update the hub to use them.',
            key: const ValueKey('notes-old'),
            textAlign: TextAlign.center,
            style: small,
          ),
        ),
      );
    } else {
      final up = board?.notes ?? mine!.notes;
      final now = _now;
      body = ListView(
        key: const ValueKey('notes-list'),
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
        children: [
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(_error!, key: const ValueKey('notes-error'), style: small),
            ),
          if (up.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 12, 4, 12),
              child: Text(
                _mayManage
                    ? 'No note is up. Write one, and everybody sees it once, the next time they sign in.'
                    : 'No note is up.',
                key: const ValueKey('notes-none'),
                style: small,
              ),
            ),
          for (final note in up) board != null ? _managed(note, board) : _read(note),
          if (board != null && board.earlier.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 10, 4, 8),
              child: Text(
                'Came down in the last ${board.earlierDays} days',
                key: const ValueKey('notes-earlier'),
                style: theme.textTheme.titleSmall,
              ),
            ),
            for (final note in board.earlier)
              _read(note, faded: true, under: [endedWords(note, now), 'seen by ${note.seenCount}'].join(' · ')),
          ],
        ],
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Notes for the shift')),
      body: body,
      bottomNavigationBar: !_mayManage || _old || (board == null && mine == null)
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: board != null
                    ? FilledButton.icon(
                        key: const ValueKey('note-write'),
                        onPressed: _write,
                        icon: const Icon(Icons.add),
                        label: const Text('Write a note'),
                      )
                    : FilledButton.tonalIcon(
                        key: const ValueKey('notes-unlock'),
                        onPressed: _unlock,
                        icon: const Icon(Icons.lock_outline),
                        label: const Text('Write or change notes'),
                      ),
              ),
            ),
    );
  }
}

/// A note being written, or one being changed: its words, and how long it is up. Pops a [NoteDraft], or
/// nothing when it was closed.
class NoteFormDialog extends StatefulWidget {
  const NoteFormDialog({super.key, this.note, this.textMax = 500});

  /// The note being changed; null writes a new one.
  final ShiftNote? note;
  final int textMax;

  @override
  State<NoteFormDialog> createState() => _NoteFormDialogState();
}

class _NoteFormDialogState extends State<NoteFormDialog> {
  late final _text = TextEditingController(text: widget.note?.text ?? '');
  late String _lasts = widget.note?.lasts ?? 'tonight';

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  String get _words => _text.text.trim();

  bool get _ok {
    if (_words.isEmpty) return false;
    final note = widget.note;
    return note == null || _words != note.text || _lasts != note.lasts;
  }

  void _done() {
    if (_ok) Navigator.of(context).pop((text: _words, lasts: _lasts));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final changing = widget.note != null;
    Widget lasts(String value, String words) => ChoiceChip(
      key: ValueKey('note-lasts:$value'),
      label: Text(words),
      selected: _lasts == value,
      onSelected: (_) => setState(() => _lasts = value),
    );
    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24), // a phone keeps its width
      title: Text(changing ? 'Change the note' : 'A note for the shift'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                key: const ValueKey('note-text'),
                controller: _text,
                autofocus: true,
                minLines: 3,
                maxLines: 8,
                maxLength: widget.textMax,
                keyboardType: TextInputType.multiline,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  hintText: 'The specials, what is out, a big party…',
                  border: OutlineInputBorder(),
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [lasts('tonight', 'For tonight'), lasts('stays', 'Until taken down')],
              ),
              const SizedBox(height: 6),
              Text(
                _lasts == 'tonight'
                    ? 'It comes down by itself when the night is over.'
                    : 'It stays up until a manager takes it down.',
                style: small,
              ),
              if (changing)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text('New words show the note to everybody again.', style: small),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('note-save'),
          onPressed: _ok ? _done : null,
          child: Text(changing ? 'Save' : 'Put it up'),
        ),
      ],
    );
  }
}
