import 'package:flutter/material.dart';

import '../api.dart';
import '../guests_report.dart';

/// What the restaurant keeps about a guest, written from the guest list (docs/guest-list.md, "Tags and the
/// note"): their tags, a button each, and the one line of the note. A tag is put on or taken off with a
/// tap; one that is not among the buttons yet is typed once and is a button from then on. The hub keeps
/// both by the guest's number with who wrote them, and hands back what it kept ([GuestKept]), which is what
/// this closes with. Both are shown where that guest's call and order are taken, and the box says so.
///
/// [GuestEditDialog.tags] is the same box with the tags alone, for a guest tagged from their reservation
/// or their line of the waitlist (`tag_guest.dart`): the note there is the reservation's own, so the
/// customer's line is neither shown nor written.
class GuestEditDialog extends StatefulWidget {
  GuestEditDialog({
    super.key,
    required this.api,
    required this.token,
    required Guest guest,
    required this.offered,
    this.noteMax = 120,
    this.tagMax = 24,
    this.tagsMost = 6,
  }) : called = guest.called,
       phone = guest.phone,
       tags = guest.tags,
       note = guest.note,
       name = null,
       withNote = true;

  const GuestEditDialog.tags({
    super.key,
    required this.api,
    required this.token,
    required this.called,
    required this.phone,
    required this.tags,
    required this.offered,
    this.name,
    this.tagMax = 24,
    this.tagsMost = 6,
  }) : note = '',
       noteMax = 120,
       withNote = false;

  final PosApi api;

  /// The session of whoever opened the guest list, or gave their PIN to tag a guest: the hub writes their
  /// name beside what they keep.
  final String token;

  /// The guest, as the box's title calls them, their number, and what the restaurant keeps about them now.
  final String called;
  final String phone;
  final List<String> tags;
  final String note;

  /// What the guest is called on the reservation or the party they are tagged from; null in the guest
  /// list. It goes to the hub with the tags, which keeps it while the number carries one: a guest who
  /// never ordered has no other name for the guest list to call them.
  final String? name;

  /// Whether the note is shown and written with the tags (the guest list), or the tags alone.
  final bool withNote;

  /// Every tag there is to offer, in the order the buttons show: the ones guests carry and the standard
  /// ones.
  final List<String> offered;
  final int noteMax;
  final int tagMax;
  final int tagsMost;

  @override
  State<GuestEditDialog> createState() => _GuestEditDialogState();
}

class _GuestEditDialogState extends State<GuestEditDialog> {
  /// The buttons, and the ones that are on (by their small letters: a tag is the same whatever its
  /// capitals).
  late final List<String> _offered = tidyOffered();
  late final Set<String> _on = {for (final tag in widget.tags) tag.toLowerCase()};
  late final _note = TextEditingController(text: widget.note);
  final _another = TextEditingController();
  String? _message;
  bool _busy = false;

  /// The tags offered and the guest's own, each once: one of theirs that is no button yet becomes one.
  List<String> tidyOffered() {
    final known = <String>[];
    for (final tag in [...widget.offered, ...widget.tags]) {
      if (known.every((one) => one.toLowerCase() != tag.toLowerCase())) known.add(tag);
    }
    return known;
  }

  @override
  void dispose() {
    _note.dispose();
    _another.dispose();
    super.dispose();
  }

  bool get _full => _on.length >= widget.tagsMost;

  List<String> get _picked => [
    for (final tag in _offered)
      if (_on.contains(tag.toLowerCase())) tag,
  ];

  void _toggle(String tag) => setState(() {
    final key = tag.toLowerCase();
    _message = null;
    if (!_on.remove(key)) _on.add(key);
  });

  /// Puts the tag typed on the guest: one of the buttons when it is one already, a new button otherwise.
  /// False when it could not be (the guest carries as many as one may).
  bool _add() {
    final words = tidyTags([_another.text]).firstOrNull;
    if (words == null) {
      _another.clear();
      return true;
    }
    final key = words.toLowerCase();
    if (!_on.contains(key) && _full) {
      setState(() => _message = 'A guest carries ${widget.tagsMost} tags at most. Take one off first.');
      return false;
    }
    setState(() {
      _message = null;
      if (_offered.every((tag) => tag.toLowerCase() != key)) _offered.add(words);
      _on.add(key);
      _another.clear();
    });
    return true;
  }

  Future<void> _save() async {
    // a tag typed and not yet added is meant too
    if (_busy || !_add()) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final kept = await widget.api.keepGuest(
        widget.token,
        widget.phone,
        note: widget.withNote ? _note.text : null, // the tags alone: the note stays as it is
        tags: _picked,
        name: (widget.name ?? '').trim().isEmpty ? null : widget.name!.trim(),
      );
      if (mounted) Navigator.of(context).pop(kept);
    } on ApiException catch (err) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _message = switch (err.status) {
          null => 'The hub is not answering, so nothing was saved.',
          401 ||
          403 when !widget.withNote => "The manager's PIN is no longer good here: close this and tap Tags again.",
          401 || 403 => "The manager's hour here is over: go back and open Location again.",
          404 || 405 => 'This hub is older than tags. Update the hub, then save again.',
          _ => err.detail?['message'] as String? ?? err.message,
        };
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final small = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final label = theme.textTheme.labelLarge?.copyWith(color: scheme.primary);
    return AlertDialog(
      title: Text(widget.called, key: const ValueKey('guest-edit-title')),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24), // a phone keeps its width
      contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Tags', style: label),
              const SizedBox(height: 4),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  for (final tag in _offered)
                    FilterChip(
                      key: ValueKey('guest-tag:$tag'),
                      label: Text(tag),
                      selected: _on.contains(tag.toLowerCase()),
                      // as many as a guest may carry: the rest wait until one is taken off
                      onSelected: _busy || (_full && !_on.contains(tag.toLowerCase())) ? null : (_) => _toggle(tag),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const ValueKey('guest-tag-new'),
                      controller: _another,
                      maxLength: widget.tagMax,
                      textCapitalization: TextCapitalization.sentences,
                      textInputAction: TextInputAction.done,
                      decoration: const InputDecoration(isDense: true, counterText: '', hintText: 'Another tag'),
                      onSubmitted: (_) => _add(),
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('guest-tag-add'),
                    tooltip: 'Put this tag on',
                    icon: const Icon(Icons.add),
                    onPressed: _busy ? null : _add,
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  widget.withNote
                      ? 'Whoever takes this guest\'s call or order sees their tags, as they see the note.'
                      : 'Whoever takes this guest\'s call, order or table sees their tags.',
                  style: small,
                ),
              ),
              if (widget.withNote) ...[
                const SizedBox(height: 12),
                Text('Note', style: label),
                TextField(
                  key: const ValueKey('guest-note-words'),
                  controller: _note,
                  maxLength: widget.noteMax,
                  minLines: 1,
                  maxLines: 3,
                  // one line, however it wraps here: Enter saves and starts no new one
                  keyboardType: TextInputType.text,
                  textInputAction: TextInputAction.done,
                  textCapitalization: TextCapitalization.sentences,
                  // the hint stays one line on a narrow phone, so the empty box is no taller than a full one
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: 'One line: "No MSG, side door"',
                    hintMaxLines: 1,
                  ),
                  onSubmitted: (_) => _save(),
                ),
                Text('The to-go form shows this line to whoever takes their call.', style: small),
              ],
              if (_message != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    _message!,
                    key: const ValueKey('guest-edit-problem'),
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
          key: const ValueKey('guest-edit-save'),
          onPressed: _busy ? null : _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
