import 'package:flutter/material.dart';

import '../api.dart';
import '../powers.dart';
import 'save_bar.dart';

/// Who may do what (docs/roles.md): each power with the roles it is handed to, as buttons. A manager or an
/// owner taps a role to hand it a power or to take it back, and saves with the bar that comes up at the
/// bottom of the screen ([SaveBarScaffold]); the hub holds it from then on, for every screen. Managers and
/// owners hold every power always and have no buttons: nothing here can leave the location with nobody who
/// may void a dish or open this screen.
class PowersScreen extends StatefulWidget {
  const PowersScreen({super.key, required this.api, required this.token, required this.powers});

  final PosApi api;
  final String token;

  /// The table as the hub has it.
  final Powers powers;

  @override
  State<PowersScreen> createState() => _PowersScreenState();
}

class _PowersScreenState extends State<PowersScreen> {
  late Powers _now = widget.powers;
  String? _message;
  bool _busy = false;

  /// How many buttons stand differently from the table as the hub has it.
  int get _changes {
    var count = 0;
    for (final power in powersById.keys) {
      if (!_now.knows(power)) continue;
      final was = widget.powers.handedTo(power).toSet();
      final now = _now.handedTo(power).toSet();
      count += was.difference(now).length + now.difference(was).length;
    }
    return count;
  }

  /// The table as it started, before anybody changed it: what the standard one hands out, and no more.
  Powers get _asItStarted => _now.asItStarted;

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final saved = await widget.api.savePowers(widget.token, _now);
      if (mounted) Navigator.of(context).pop(saved);
    } on ApiException catch (err) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _message = switch (err.status) {
          401 => 'The PIN has run out. Go back and open Location again.',
          403 => 'Only a manager or an owner changes who may do what.',
          _ => err.detail?['message'] as String? ?? err.message,
        };
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final changes = _changes;
    final started = _now == _asItStarted;
    return SaveBarScaffold(
      appBar: AppBar(title: const Text('Who may do what')),
      changed: changes > 0,
      onSave: _busy ? null : _save,
      saveKey: const ValueKey('powers-save'),
      waiting: '$changes ${changes == 1 ? 'change' : 'changes'} not saved',
      problems: [if (_message != null) (about: null, text: _message!)],
      unsaved: 'Your changes to who may do what are not saved.',
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            children: [
              Text(
                'Managers and owners may do all of this, always. Tap a role to hand it a power, or to '
                'take it back.',
                key: const ValueKey('powers-intro'),
                style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
              ),
              // a power this hub has never heard of (it is older than the app) has no row
              for (final group in powerGroups.where((g) => g.powers.any((p) => _now.knows(p.id)))) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 16, 4, 6),
                  child: Text(group.name, style: theme.textTheme.titleSmall?.copyWith(color: scheme.primary)),
                ),
                Card(
                  margin: EdgeInsets.zero,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final (index, power) in group.powers.where((p) => _now.knows(p.id)).indexed) ...[
                        if (index > 0) const Divider(height: 1),
                        _row(context, power),
                      ],
                    ],
                  ),
                ),
              ],
              // at the foot of the list, out of the way: it undoes every hand-out at once
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: TextButton.icon(
                    key: const ValueKey('powers-reset'),
                    onPressed: _busy || started ? null : () => setState(() => _now = _asItStarted),
                    icon: const Icon(Icons.restart_alt),
                    label: const Text('Put it back as it started'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// One power: what it is, a line on what it lets a person do, and a button per role.
  Widget _row(BuildContext context, Power power) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      key: ValueKey('power:${power.id}'),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(power.name, style: theme.textTheme.titleMedium),
          Text(power.about, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              // a lit button is filled and ticked: who holds a power has to read at a glance
              for (final role in _now.offered)
                FilterChip(
                  key: ValueKey('power:${power.id}:$role'),
                  label: Text(roleLabel(role)),
                  selected: _now.holds(role, power.id),
                  showCheckmark: true,
                  checkmarkColor: scheme.onPrimary,
                  selectedColor: scheme.primary,
                  labelStyle: _now.holds(role, power.id)
                      ? theme.chipTheme.labelStyle?.copyWith(color: scheme.onPrimary, fontWeight: FontWeight.w700)
                      : null,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  onSelected: _busy ? null : (on) => setState(() => _now = _now.hand(power.id, role, on: on)),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
