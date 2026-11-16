import 'package:flutter/material.dart';

import '../floor.dart';
import '../roster.dart';
import 'lot_comp_dialog.dart' show dishes;
import 'server_picker.dart';
import 'theme.dart';

/// What was chosen on a seated table that was held down: move it to another table, or hand it to [server]
/// (with [all], together with every other table its present server has).
class Held {
  const Held.move() : server = null, all = false;
  const Held.server(StaffMember this.server, {this.all = false});

  final StaffMember? server;
  final bool all;

  bool get move => server == null;
}

/// The sheet a host or manager gets on a seated table held down: move it, or say who serves it now. With
/// more than one table in the present server's hands, all of them can go at once (a shift change).
class HeldSheet extends StatefulWidget {
  const HeldSheet({
    super.key,
    required this.table,
    required this.plan,
    required this.servers,
    required this.current,
    required this.moves,
  });

  final TableSpot table;
  final FloorPlan plan;
  final List<StaffMember> servers;

  /// Who serves the table now, when the staff list knows them.
  final StaffMember? current;

  /// Whether the hub can move a table's check: one older than moving cannot, and the button is not shown.
  final bool moves;

  @override
  State<HeldSheet> createState() => _HeldSheetState();
}

class _HeldSheetState extends State<HeldSheet> {
  bool _all = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final current = widget.current;
    final theirs = current == null ? 0 : ServerLoad.of(widget.plan, current).tables;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.moves) ...[
              SizedBox(
                width: double.infinity,
                child: FilledButton.tonalIcon(
                  key: const ValueKey('move-table'),
                  onPressed: () => Navigator.of(context).pop(const Held.move()),
                  icon: const Icon(Icons.open_with_rounded),
                  label: Text('Move ${widget.table.label} to another table'),
                ),
              ),
              const SizedBox(height: 16),
            ],
            Text(
              _all && current != null
                  ? 'Who takes ${current.name}\'s $theirs tables?'
                  : 'Who serves ${widget.table.label}?',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 10),
            ServerPicker(
              servers: widget.servers,
              plan: widget.plan,
              picked: current,
              onPicked: (server) => Navigator.of(context).pop(Held.server(server, all: _all)),
            ),
            if (current != null && theirs > 1) ...[
              const SizedBox(height: 10),
              FilterChip(
                key: const ValueKey('all-tables'),
                selected: _all,
                onSelected: (on) => setState(() => _all = on),
                label: Text('All $theirs of ${current.name}\'s tables'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The strip above the floor map while a table is being moved: the next table tapped is where it goes.
/// The same strip seats a bar tab ([MovingBar.words]): the next table tapped is where the party sits down.
class MovingBar extends StatelessWidget {
  MovingBar({super.key, required TableSpot table, required this.onCancel})
    : words = 'Moving ${table.label}. Tap the table it goes to.';

  const MovingBar.words(this.words, {super.key, required this.onCancel});

  /// What the strip says is going on.
  final String words;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      key: const ValueKey('moving-bar'),
      color: scheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 2, 4, 2),
        child: Row(
          children: [
            Icon(Icons.open_with_rounded, size: 20, color: scheme.onPrimaryContainer),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                words,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onPrimaryContainer,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            TextButton(key: const ValueKey('move-cancel'), onPressed: onCancel, child: const Text('Cancel')),
          ],
        ),
      ),
    );
  }
}

/// What to do with a check that lands on a table that already has one.
enum Landing { merge, apart }

/// Asked when a table is moved onto one that is seated: one check for both, or two checks at one table.
/// [blocked] says why the two cannot become one, when they cannot; [note] is anything else worth knowing
/// before choosing (a discount that stays behind).
class LandingDialog extends StatelessWidget {
  LandingDialog({super.key, required TableSpot from, required this.to, this.blocked, this.note}) : from = from.label;

  /// A bar tab sits down at a seated table: [tab] is what the tab is called ("Linda's tab").
  const LandingDialog.tab(String tab, {super.key, required this.to, this.blocked, this.note}) : from = tab;

  /// What is landing, by name: a table's label, or a tab.
  final String from;
  final TableSpot to;
  final String? blocked;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final small = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    return AlertDialog(
      title: Text('${to.label} is seated'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Put $from and ${to.label} on one check, or keep two checks at ${to.label}?'),
            if (blocked != null) ...[const SizedBox(height: 10), Text(blocked!, style: small)],
            if (note != null && blocked == null) ...[const SizedBox(height: 10), Text(note!, style: small)],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        OutlinedButton(
          key: const ValueKey('keep-apart'),
          onPressed: () => Navigator.of(context).pop(Landing.apart),
          child: const Text('Keep apart'),
        ),
        FilledButton(
          key: const ValueKey('one-check'),
          onPressed: blocked != null ? null : () => Navigator.of(context).pop(Landing.merge),
          child: const Text('One check'),
        ),
      ],
    );
  }
}

/// Table names the way a person counts them: A2 before A10, and the A's before the B's.
int compareLabels(String a, String b) {
  final parts = RegExp(r'^(\D*)(\d*)');
  final x = parts.firstMatch(a)!, y = parts.firstMatch(b)!;
  final byName = x.group(1)!.compareTo(y.group(1)!);
  if (byName != 0) return byName;
  final byNumber = (int.tryParse(x.group(2)!) ?? 0).compareTo(int.tryParse(y.group(2)!) ?? 0);
  return byNumber != 0 ? byNumber : a.compareTo(b);
}

/// The other tables' checks as buttons: where dishes in hand can go. Each says whose check it is and how
/// many guests it has; where a table has several checks, each also says what is on it, to tell them apart.
class CheckPicker extends StatelessWidget {
  const CheckPicker({super.key, required this.plan, required this.except, required this.onPicked});

  final FloorPlan plan;

  /// The check the dishes are on now: no place to move them to.
  final String except;
  final void Function(TableSpot table, TableCheck check) onPicked;

  /// Every check on the floor but [except], table by table in the order of [compareLabels].
  static List<(TableSpot, TableCheck)> places(FloorPlan plan, String except) {
    final tables = [...plan.tables]..sort((a, b) => compareLabels(a.label, b.label));
    return [
      for (final table in tables)
        for (final check in plan.checksAt(table.id))
          if (check.orderId != except) (table, check),
    ];
  }

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      for (final (table, check) in places(plan, except))
        _CheckTile(
          key: ValueKey('move-to:${check.orderId}'),
          table: table,
          check: check,
          several: plan.checksAt(table.id).length > 1,
          onTap: () => onPicked(table, check),
        ),
    ],
  );
}

class _CheckTile extends StatelessWidget {
  const _CheckTile({super.key, required this.table, required this.check, required this.several, required this.onTap});

  final TableSpot table;
  final TableCheck check;
  final bool several;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final small = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant, fontFeatures: PosTheme.tabular);
    final guests = check.guests;
    final who = [
      if ((check.server ?? '').isNotEmpty) shortName(check.server),
      if (guests != null) '$guests ${guests == 1 ? 'guest' : 'guests'}',
    ].join(' · ');
    final what = [
      check.items == 0 ? 'no dishes yet' : dishes(check.items),
      if (check.total != null) '\$${check.total}',
    ];
    return Material(
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 104, minHeight: 52),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  table.label,
                  style: theme.textTheme.titleSmall?.copyWith(color: scheme.onSurface, fontWeight: FontWeight.w700),
                ),
                if (who.isNotEmpty) Text(who, style: small),
                if (several || who.isEmpty) Text(what.join(' · '), style: small),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
