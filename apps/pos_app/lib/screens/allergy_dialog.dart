import 'package:flutter/material.dart';

import '../allergies.dart';

/// An allergy a guest told of: who has it (the whole table or one seat; a to-go order has no seats, so it is
/// the order's), the menu's allergens as buttons to tap on and off, and a line for whatever else was said.
/// Each seat keeps its own, so two guests' allergies can be noted in one visit. Save hands back only what
/// changed, an allergy with nothing left in it among them: that one takes the seat's allergy off.
///
/// The buttons are small on purpose, three across: the nine or so allergens and the line under them fit a
/// phone without scrolling.
class AllergyDialog extends StatefulWidget {
  const AllergyDialog({
    super.key,
    required this.allergens,
    required this.told,
    required this.seated,
    this.seats = 0,
    this.seat,
    this.bySeat = true,
  });

  /// What the menu names, in its order.
  final List<Allergen> allergens;

  /// What the order carries now.
  final List<Allergy> told;

  /// A table, whose allergy is the table's or a seat's; false for a to-go order.
  final bool seated;
  final int seats;

  /// The seat it opens on: the one the next dish goes to. Null is the table.
  final int? seat;

  /// Whether a table has seats here. Off, an allergy is the whole table's and nothing asks whose it is;
  /// [seats] then reaches only as far as the seats that have one noted all the same, so those can still be
  /// changed and taken off.
  final bool bySeat;

  @override
  State<AllergyDialog> createState() => _AllergyDialogState();
}

class _AllergyDialogState extends State<AllergyDialog> {
  /// What each seat has as it stands in the dialog, by seat (0: the table).
  late final _picked = <int, Set<String>>{
    for (final a in widget.told) a.seat ?? 0: {...a.allergens},
  };
  late final _notes = <int, String>{for (final a in widget.told) a.seat ?? 0: a.note};
  late int _who = widget.seated && (widget.seat ?? 0) <= widget.seats ? widget.seat ?? 0 : 0;
  late final _note = TextEditingController(text: _notes[_who] ?? '');

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  /// The menu's allergens, then any the order carries that the menu no longer names (shown by their code, so
  /// they can still be seen and taken off).
  List<Allergen> get _offered {
    final known = {for (final a in widget.allergens) a.code};
    return [
      ...widget.allergens,
      for (final code in {for (final a in widget.told) ...a.allergens})
        if (!known.contains(code)) Allergen(code: code, name: code),
    ];
  }

  Allergy _now(int who) {
    final picked = _picked[who] ?? const <String>{};
    return Allergy(
      seat: who == 0 ? null : who,
      allergens: [
        for (final a in _offered)
          if (picked.contains(a.code)) a.code,
      ],
      note: Allergy.cleanNote(_notes[who] ?? ''),
    );
  }

  Allergy _before(int who) =>
      widget.told.where((a) => (a.seat ?? 0) == who).firstOrNull ?? Allergy(seat: who == 0 ? null : who);

  List<Allergy> get _changed => [
    for (final who in {..._picked.keys, ..._notes.keys}.toList()..sort())
      if (!_now(who).same(_before(who))) _now(who),
  ];

  void _show(int who) => setState(() {
    _who = who;
    _note.text = _notes[who] ?? '';
  });

  void _toggle(String code) => setState(() {
    final picked = _picked.putIfAbsent(_who, () => {});
    if (!picked.remove(code)) picked.add(code);
  });

  void _clear() => setState(() {
    _picked[_who] = {};
    _notes[_who] = '';
    _note.clear();
  });

  void _save() {
    final changed = _changed;
    if (changed.isNotEmpty) Navigator.of(context).pop(changed);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final picked = _picked[_who] ?? const <String>{};
    Widget who(int seat) {
      final has = !_now(seat).isEmpty;
      return ChoiceChip(
        key: ValueKey('allergy-who:$seat'),
        label: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(seat == 0 ? 'Table' : 'Seat $seat'),
            if (has) ...[const SizedBox(width: 3), Icon(Icons.warning_amber_rounded, size: 15, color: scheme.error)],
          ],
        ),
        selected: _who == seat,
        onSelected: (_) => _show(seat),
        visualDensity: VisualDensity.compact,
      );
    }

    final offered = _offered;
    return AlertDialog(
      title: const Text('Allergy'),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (widget.seated && (widget.bySeat || widget.seats > 0)) ...[
                Wrap(
                  spacing: 6,
                  runSpacing: 2,
                  children: [who(0), for (var seat = 1; seat <= widget.seats; seat++) who(seat)],
                ),
                const SizedBox(height: 10),
              ],
              Text(
                !widget.seated
                    ? 'This order cannot have'
                    : _who == 0
                    ? 'The whole table cannot have'
                    : 'Seat $_who cannot have',
                style: theme.textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
              if (offered.isNotEmpty)
                LayoutBuilder(
                  builder: (context, constraints) => GridView(
                    shrinkWrap: true,
                    padding: EdgeInsets.zero,
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: constraints.maxWidth < 260 ? 2 : 3, // nine allergens: three rows of three
                      mainAxisSpacing: 8,
                      crossAxisSpacing: 8,
                      mainAxisExtent: 52,
                    ),
                    children: [
                      for (final a in offered)
                        _AllergenButton(
                          key: ValueKey('allergen:${a.code}'),
                          name: a.name,
                          selected: picked.contains(a.code),
                          onTap: () => _toggle(a.code),
                        ),
                    ],
                  ),
                ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('allergy-note'),
                controller: _note,
                maxLength: allergyNoteMax,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Anything else, in words',
                  hintText: 'no oyster sauce',
                  counterText: '',
                  isDense: true,
                ),
                onChanged: (text) => setState(() => _notes[_who] = text),
                onSubmitted: (_) => _save(),
              ),
              const SizedBox(height: 8),
              Text(
                'The kitchen reads it on every ticket. A dish is only marked when the menu lists what is in it.',
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('allergy-clear'),
          onPressed: _now(_who).isEmpty ? null : _clear,
          child: const Text('No allergy'),
        ),
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('allergy-save'),
          onPressed: _changed.isEmpty ? null : _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// One allergen: a button that stays down, red, while the guest cannot have it.
class _AllergenButton extends StatelessWidget {
  const _AllergenButton({super.key, required this.name, required this.selected, required this.onTap});

  final String name;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Semantics(
      selected: selected,
      child: Material(
        color: selected ? scheme.errorContainer : scheme.surfaceContainerLowest,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: selected ? scheme.error : scheme.outlineVariant, width: selected ? 2 : 1),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Text(
                name,
                maxLines: 2,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: selected ? scheme.onErrorContainer : scheme.onSurface,
                  fontWeight: selected ? FontWeight.w700 : null,
                  height: 1.15,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
