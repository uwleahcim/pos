import 'dart:async';

import 'package:flutter/material.dart';

import '../customers.dart';
import '../points.dart';
import 'guest_tag_mark.dart';

/// What whoever serves a table typed for the guest who left a number: the number as it was typed, and the
/// name (empty where none was given, and on a bar tab, which has its own).
typedef GuestNumber = ({String phone, String name});

/// What the dialog was closed with when the number was taken off the check again.
const guestNumberOff = (phone: '', name: '');

/// The phone number of a guest who sits at a table without a reservation (docs/guest-list.md, "A walk-in's
/// number"): typed on the table's check, it makes the check that guest's visit in the guest list, and where
/// the owner set a rate they earn points on it (docs/points.md). As the number is typed the hub says who
/// it is, the way the to-go form does: the name they ordered under, how often they came, and their points.
///
/// Closed with the number and the name to keep, with [guestNumberOff] to take the number off, or with
/// nothing when it was left.
class GuestNumberDialog extends StatefulWidget {
  const GuestNumberDialog({
    super.key,
    this.phone = '',
    this.name = '',
    this.named = true,
    this.where = 'the check',
    required this.lookup,
  });

  /// The number on the check now; empty for a check with none.
  final String phone;

  /// The name on the check now.
  final String name;

  /// Whether a name is asked for: a bar tab has the name it is called by, and keeps it.
  final bool named;

  /// What the number goes on, in words: "Table A7", "Dana's tab".
  final String where;

  /// What the hub knows of the customer at a number, null when it knows nothing or does not answer.
  final Future<CustomerCard?> Function(String phone) lookup;

  /// The longest name a guest is kept under: a line of the guest list.
  static const nameMax = 40;

  @override
  State<GuestNumberDialog> createState() => _GuestNumberDialogState();
}

class _GuestNumberDialogState extends State<GuestNumberDialog> {
  late final _phone = TextEditingController(text: widget.phone);
  late final _name = TextEditingController(text: widget.name);
  final _nameFocus = FocusNode();

  /// Whether somebody typed in the name box: a name that was typed is not written over by the hub's.
  bool _nameTyped = false;

  /// The number the card below is of, as its digits, and the card.
  String _askedFor = '';
  CustomerCard? _card;

  @override
  void initState() {
    super.initState();
    _nameTyped = widget.name.trim().isNotEmpty;
    unawaited(_look());
  }

  @override
  void dispose() {
    _phone.dispose();
    _name.dispose();
    _nameFocus.dispose();
    super.dispose();
  }

  String get _digits => phoneDigits(_phone.text);
  bool get _isNumber => _digits.length >= customerDigits;
  String get _typedName => _name.text.trim().replaceAll(RegExp(r'\s+'), ' ');

  /// Asks the hub who is at the number, once it is long enough to be one. The answer for a number that was
  /// typed over since is dropped.
  Future<void> _look() async {
    final digits = _digits;
    if (digits == _askedFor) return;
    _askedFor = digits;
    if (_card != null) setState(() => _card = null);
    if (digits.length < customerDigits) return;
    final card = await widget.lookup(digits);
    if (!mounted || _askedFor != digits) return;
    setState(() {
      _card = card;
      // the name they ordered under, unless one was typed here
      if (widget.named && !_nameTyped && (card?.name ?? '').isNotEmpty) _name.text = card!.name;
    });
  }

  void _done() {
    if (!_isNumber) return;
    Navigator.of(context).pop<GuestNumber>((phone: _phone.text.trim(), name: widget.named ? _typedName : ''));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final faint = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final had = widget.phone.trim().isNotEmpty;
    final card = _card;
    return AlertDialog(
      // a phone's width less a finger at each side: the boxes and the buttons keep their room at large type
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      title: const Text("Guest's number"),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'The guest who pays ${widget.where} is counted in the guest list by this number.',
                key: const ValueKey('guest-number-why'),
                style: faint,
              ),
              const SizedBox(height: 8),
              TextField(
                key: const ValueKey('guest-number-phone'),
                controller: _phone,
                autofocus: true,
                keyboardType: TextInputType.phone,
                textInputAction: widget.named ? TextInputAction.next : TextInputAction.done,
                decoration: InputDecoration(
                  labelText: 'Phone number',
                  helperText: _phone.text.trim().isEmpty || _isNumber ? null : 'At least $customerDigits digits',
                ),
                onChanged: (_) {
                  setState(() {});
                  unawaited(_look());
                },
                onSubmitted: (_) => widget.named ? _nameFocus.requestFocus() : _done(),
              ),
              if (widget.named) ...[
                const SizedBox(height: 8),
                TextField(
                  key: const ValueKey('guest-number-name'),
                  controller: _name,
                  focusNode: _nameFocus,
                  maxLength: GuestNumberDialog.nameMax,
                  textCapitalization: TextCapitalization.words,
                  textInputAction: TextInputAction.done,
                  decoration: const InputDecoration(labelText: 'Name (if they give one)', counterText: ''),
                  onChanged: (_) => setState(() => _nameTyped = true),
                  onSubmitted: (_) => _done(),
                ),
              ],
              // who the hub says it is, as the to-go form says a caller
              if (_isNumber && card != null) ...[
                const SizedBox(height: 8),
                // a tab has no name box to say it in
                if (!widget.named && card.name.trim().isNotEmpty)
                  Text(
                    card.name.trim(),
                    key: const ValueKey('guest-number-known'),
                    style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
                  ),
                Text(card.summary(DateTime.now()), key: const ValueKey('guest-number-summary'), style: faint),
                if (card.points case final points?)
                  Text(
                    points > 0 ? 'They have ${pointsWords(points)}' : 'No points yet',
                    key: const ValueKey('guest-number-points'),
                    style: faint,
                  ),
                if (card.tags.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 2,
                      children: [
                        for (final tag in card.tags) GuestTagMark(tag, key: ValueKey('guest-number-tag:$tag')),
                      ],
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
      actionsOverflowButtonSpacing: 4,
      actions: [
        if (had)
          TextButton(
            key: const ValueKey('guest-number-off'),
            onPressed: () => Navigator.of(context).pop<GuestNumber>(guestNumberOff),
            child: const Text('Take off'),
          ),
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('guest-number-save'),
          onPressed: _isNumber ? _done : null,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
