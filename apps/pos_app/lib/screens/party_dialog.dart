import 'package:flutter/material.dart';

import '../api.dart';
import '../waitlist.dart';
import 'guests_picker.dart';

/// A party for the waitlist (docs/waitlist.md): asked when one is put on the list, and again to put right
/// what it told the host. A name and how many they are; the wait they were told, a phone number and a note
/// when there is one. The hub keeps it and says what it does not take. Pops the list as the hub has it
/// afterwards; nothing when it was closed.
class PartyDialog extends StatefulWidget {
  const PartyDialog({
    super.key,
    required this.api,
    required this.staffId,
    this.list = const Waitlist(),
    this.party,
    this.nowMs,
  });

  final PosApi api;

  /// Who is at the screen: the list keeps who put a party on it.
  final String staffId;

  /// The list as it was last read: the waits it offers, and how long a name and a note may be.
  final Waitlist list;

  /// The party being put right; null for a new one.
  final WaitParty? party;

  /// The hub's clock, for how long a party being put right has waited; the app's reading of it when null.
  final int Function()? nowMs;

  @override
  State<PartyDialog> createState() => _PartyDialogState();
}

class _PartyDialogState extends State<PartyDialog> {
  late final _name = TextEditingController(text: widget.party?.name ?? '');
  late final _phone = TextEditingController(text: widget.party?.phone ?? '');
  late final _note = TextEditingController(text: widget.party?.note ?? '');
  late int _size = widget.party?.size ?? 2;
  late int? _quoted = widget.party?.quotedMinutes;
  bool _busy = false;
  String? _message;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _note.dispose();
    super.dispose();
  }

  String get _typedName => _name.text.trim().replaceAll(RegExp(r'\s+'), ' ');

  Future<void> _save() async {
    final name = _typedName;
    if (name.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    final api = widget.api;
    final party = widget.party;
    try {
      final saved = party == null
          ? await api.addParty(
              widget.staffId,
              name: name,
              size: _size,
              phone: _phone.text.trim(),
              quotedMinutes: _quoted,
              note: _note.text.trim(),
            )
          : await api.changeParty(
              widget.staffId,
              party.id,
              name: name,
              size: _size,
              phone: _phone.text.trim(),
              quotedMinutes: _quoted,
              note: _note.text.trim(),
            );
      if (mounted) Navigator.of(context).pop(saved);
    } on ApiException catch (err) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _message = err.status == null
            ? 'The hub cannot be reached, and the list is kept there. Try again in a moment.'
            : err.detail?['message'] as String? ?? err.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final party = widget.party;
    final list = widget.list;
    final label = theme.textTheme.labelLarge?.copyWith(color: scheme.onSurfaceVariant);
    final quotes = {...list.quotes, ?party?.quotedMinutes}.toList()..sort();
    final waited = party?.waitedAt((widget.nowMs ?? widget.api.nowMs)());
    return AlertDialog(
      title: Text(party == null ? 'Add to the waitlist' : 'Change ${party.name}'),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24), // a phone keeps its width
      contentPadding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          padding: const EdgeInsets.only(top: 8), // the name's label stands above its box, and is not cut off
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                key: const ValueKey('party-name'),
                controller: _name,
                autofocus: party == null,
                maxLength: list.nameMax,
                textCapitalization: TextCapitalization.words,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(labelText: 'Name', counterText: ''),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 12),
              GuestsPicker(
                prefix: 'party',
                size: _size,
                most: list.mostGuests,
                onChanged: (size) => setState(() => _size = size),
              ),
              const SizedBox(height: 14),
              Text('Wait told', style: label),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                children: [
                  ChoiceChip(
                    key: const ValueKey('party-quote:none'),
                    label: const Text('No time'),
                    visualDensity: VisualDensity.compact,
                    showCheckmark: false,
                    selected: _quoted == null,
                    onSelected: (_) => setState(() => _quoted = null),
                  ),
                  for (final minutes in quotes)
                    ChoiceChip(
                      key: ValueKey('party-quote:$minutes'),
                      label: Text(waitWords(minutes)),
                      visualDensity: VisualDensity.compact,
                      showCheckmark: false,
                      selected: _quoted == minutes,
                      onSelected: (_) => setState(() => _quoted = minutes),
                    ),
                ],
              ),
              if (waited != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'Counted from when they came, ${waitWords(waited)} ago.',
                    style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('party-phone'),
                controller: _phone,
                keyboardType: TextInputType.phone,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(labelText: 'Phone (if they give one)', isDense: true),
              ),
              const SizedBox(height: 10),
              TextField(
                key: const ValueKey('party-note'),
                controller: _note,
                maxLength: list.noteMax,
                textCapitalization: TextCapitalization.sentences,
                textInputAction: TextInputAction.done,
                decoration: const InputDecoration(
                  labelText: 'Note',
                  hintText: 'High chair, booth, birthday',
                  isDense: true,
                  counterText: '',
                ),
                onSubmitted: (_) => _save(),
              ),
              if (_message != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    _message!,
                    key: const ValueKey('party-problem'),
                    style: theme.textTheme.bodyMedium?.copyWith(color: scheme.error),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('party-save'),
          onPressed: _typedName.isEmpty || _busy ? null : _save,
          child: Text(party == null ? 'Add to the list' : 'Save'),
        ),
      ],
    );
  }
}
