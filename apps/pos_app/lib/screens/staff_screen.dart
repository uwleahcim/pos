import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api.dart';
import '../staff_list.dart';

/// What the hub's refusal of a change to the staff means, in words for whoever typed.
String _refusal(ApiException err) {
  final words = err.detail?['message'] as String?;
  return switch (err.status) {
    401 => 'The PIN has run out. Go back and open Location again.',
    403 => words ?? 'Only a manager or an owner changes the staff.',
    404 || 405 when words == null => 'This hub is older than the staff kept in the app. Update it first.',
    null => 'The hub did not answer. Look whether it changed before trying again.',
    _ => words ?? err.message,
  };
}

/// Staff and PINs (docs/staff.md): everybody who signs in at this location, each with their role, and for
/// a manager the way to add somebody, change a name, a role or a PIN, and take somebody off. What used to
/// be a line in the hub's terminal. The hub keeps the list and checks every PIN; a PIN typed here goes to
/// the hub and is never shown again, here or anywhere.
class StaffScreen extends StatefulWidget {
  const StaffScreen({
    super.key,
    required this.api,
    required this.token,
    required this.staff,
    this.onChanged,
    this.now = DateTime.now,
  });

  final PosApi api;
  final String token;

  /// The list as the hub has it.
  final StaffList staff;

  /// Told the list after every change, so the row that led here says how it stands.
  final ValueChanged<StaffList>? onChanged;

  /// The time, for "today" on a PIN's line.
  final DateTime Function() now;

  @override
  State<StaffScreen> createState() => _StaffScreenState();
}

class _StaffScreenState extends State<StaffScreen> {
  late StaffList _staff = widget.staff;

  void _took(StaffList staff, String said) {
    setState(() => _staff = staff);
    widget.onChanged?.call(staff);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(said)));
  }

  Future<void> _open(StaffPerson? person) async {
    final done = await showDialog<(StaffList, String)>(
      context: context,
      barrierDismissible: false,
      builder: (_) => StaffPersonDialog(api: widget.api, token: widget.token, staff: _staff, was: person),
    );
    if (done == null || !mounted) return;
    _took(done.$1, done.$2);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final quiet = theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant);
    final now = widget.now();
    final demo = _staff.demoPins;
    return Scaffold(
      appBar: AppBar(title: const Text('Staff and PINs')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: [
              Text(
                'Everybody who signs in here. Tap a person to change their name, role or PIN. A PIN is four '
                'digits, and once saved it is never shown again.',
                key: const ValueKey('staff-intro'),
                style: quiet,
              ),
              if (demo > 0) ...[
                const SizedBox(height: 10),
                Container(
                  key: const ValueKey('staff-demo'),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: scheme.errorContainer, borderRadius: BorderRadius.circular(12)),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.warning_amber_rounded, color: scheme.onErrorContainer),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          '${demo == 1 ? '1 person still signs' : '$demo people still sign'} in with a PIN from '
                          'the guide, which anybody can read. Give ${demo == 1 ? 'them' : 'each'} a PIN of their own.',
                          style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onErrorContainer),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              if (_staff.source != 'app') ...[
                const SizedBox(height: 10),
                Text(
                  _staff.source == 'hub'
                      ? "This list was typed in the hub's terminal. The first change made here moves it into the "
                            'app, everybody with the PIN they have, and the terminal\'s list is not read after that.'
                      : 'The first change made here keeps the list in the app from then on.',
                  key: const ValueKey('staff-source'),
                  style: quiet,
                ),
              ],
              const SizedBox(height: 12),
              Card(
                margin: EdgeInsets.zero,
                child: Column(
                  children: [
                    for (final (index, person) in _staff.people.indexed) ...[
                      if (index > 0) const Divider(height: 1),
                      ListTile(
                        key: ValueKey('person:${person.staffId}'),
                        leading: CircleAvatar(
                          radius: 18,
                          backgroundColor: person.demoPin ? scheme.errorContainer : scheme.primaryContainer,
                          foregroundColor: person.demoPin ? scheme.onErrorContainer : scheme.onPrimaryContainer,
                          child: Text(person.name.isEmpty ? '?' : person.name.characters.first.toUpperCase()),
                        ),
                        title: Text(person.you ? '${person.name} (you)' : person.name),
                        subtitle: Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(text: '${roleName(person.role)} · '),
                              TextSpan(
                                text: person.pinLine(now),
                                style: person.demoPin
                                    ? TextStyle(color: scheme.error, fontWeight: FontWeight.w600)
                                    : null,
                              ),
                            ],
                          ),
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _open(person),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.tonalIcon(
                  key: const ValueKey('staff-add'),
                  onPressed: () => _open(null),
                  icon: const Icon(Icons.person_add_alt_1_outlined),
                  label: const Text('Add a person'),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Somebody who forgot their PIN gets a new one here. If no manager can sign in any more, the '
                "hub's terminal sets one: sudo hubctl staff pin.",
                key: const ValueKey('staff-way-back'),
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One person: the name, the role and the PIN, to add them ([was] null) or to change them, and the way to
/// take them off the staff. Saves by itself, so that what the hub says of a name or a PIN it does not take
/// shows here with the boxes still filled. Pops with the list after it and a line on what was done.
class StaffPersonDialog extends StatefulWidget {
  const StaffPersonDialog({super.key, required this.api, required this.token, required this.staff, this.was});

  final PosApi api;
  final String token;

  /// The list as it stands: the roles this manager can give.
  final StaffList staff;

  /// The person who is changed; null to add one.
  final StaffPerson? was;

  @override
  State<StaffPersonDialog> createState() => _StaffPersonDialogState();
}

class _StaffPersonDialogState extends State<StaffPersonDialog> {
  late final _name = TextEditingController(text: widget.was?.name ?? '');
  final _pin = TextEditingController();
  late String _role = widget.was?.role ?? 'server';
  bool _hidden = true;
  bool _busy = false;
  String? _message;

  bool get _adding => widget.was == null;
  bool get _canChange => widget.was?.canChange ?? true;
  bool get _canRole => widget.was?.canRole ?? true;

  /// Whether a tap gives this role: one this manager can give. Their own role is only ever changed to an
  /// owner's (the first owner of a location has to come from somewhere), and back before it is saved.
  bool _gives(String role) {
    final was = widget.was;
    if (!_canChange || !_canRole || !widget.staff.roles.contains(role)) return false;
    return was == null || !was.you || role == 'owner' || role == was.role;
  }

  /// The roles on offer: the ones this manager can give, and the person's own, whatever it is.
  List<String> get _roles => [
    ...widget.staff.roles,
    if (!_adding && !widget.staff.roles.contains(widget.was!.role)) widget.was!.role,
  ];

  @override
  void dispose() {
    _name.dispose();
    _pin.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    final pin = _pin.text;
    final was = widget.was;
    if (name.isEmpty) {
      setState(() => _message = 'Everybody on the staff has a name.');
      return;
    }
    if ((_adding || pin.isNotEmpty) && !pinPattern.hasMatch(pin)) {
      setState(() => _message = 'A PIN is four digits.');
      return;
    }
    if (was != null && name == was.name && _role == was.role && pin.isEmpty) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final StaffList saved;
      final String said;
      if (was == null) {
        saved = await widget.api.addStaff(widget.token, name: name, role: _role, pin: pin);
        said = '$name is on the staff, and signs in with the PIN you typed';
      } else {
        saved = await widget.api.changeStaff(
          widget.token,
          was.staffId,
          name: name == was.name ? null : name,
          role: _role == was.role ? null : _role,
          pin: pin.isEmpty ? null : pin,
        );
        said = pin.isEmpty ? '$name saved' : '$name saved. The new PIN works now, and the old one does not';
      }
      if (mounted) Navigator.of(context).pop((saved, said));
    } on ApiException catch (err) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _message = _refusal(err);
      });
    }
  }

  Future<void> _remove() async {
    final was = widget.was!;
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Take ${was.name} off the staff?'),
        content: Text(
          '${was.name} signs in no more, by PIN, tag or face, and the hub forgets their tag and their face. '
          'What ${was.name} did stays under their name. To bring them back, add them again.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Keep')),
          FilledButton(
            key: const ValueKey('person-remove-sure'),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Take off the staff'),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final saved = await widget.api.removeStaff(widget.token, was.staffId);
      if (mounted) Navigator.of(context).pop((saved, '${was.name} is off the staff'));
    } on ApiException catch (err) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _message = _refusal(err);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final quiet = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final was = widget.was;
    final whyNot = was?.whyNot;
    return AlertDialog(
      title: Text(_adding ? 'Add a person' : was!.name),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          // room above the first box: its label stands half over its edge, more so with large text
          padding: const EdgeInsets.only(top: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (whyNot != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Text(whyNot, key: const ValueKey('person-why-not'), style: theme.textTheme.bodyMedium),
                ),
              TextField(
                key: const ValueKey('person-name'),
                controller: _name,
                enabled: _canChange && !_busy,
                autofocus: _adding,
                textCapitalization: TextCapitalization.words,
                inputFormatters: [LengthLimitingTextInputFormatter(40)],
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  isDense: true,
                  labelText: 'Name',
                  helperText: 'As it shows on a table, a ticket and a report',
                  helperMaxLines: 3,
                ),
              ),
              const SizedBox(height: 12),
              Text('Role', style: theme.textTheme.labelLarge),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final role in _roles)
                    ChoiceChip(
                      key: ValueKey('person-role:$role'),
                      label: Text(roleName(role)),
                      selected: _role == role,
                      showCheckmark: false,
                      selectedColor: scheme.primary,
                      labelStyle: _role == role
                          ? theme.chipTheme.labelStyle?.copyWith(color: scheme.onPrimary, fontWeight: FontWeight.w700)
                          : null,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      // a role this manager cannot give stays lit on its owner and takes no tap
                      onSelected: _gives(role) && !_busy ? (_) => setState(() => _role = role) : null,
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'Managers and owners may do everything. What the others may do is under Who may do what.',
                style: quiet,
              ),
              // a PIN is typed only for somebody this manager can change
              if (_canChange) ...[
                const SizedBox(height: 12),
                TextField(
                  key: const ValueKey('person-pin'),
                  controller: _pin,
                  enabled: _canChange && !_busy,
                  obscureText: _hidden,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(4)],
                  autocorrect: false,
                  enableSuggestions: false,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _busy ? null : _save(),
                  decoration: InputDecoration(
                    isDense: true,
                    labelText: _adding ? 'PIN' : 'New PIN',
                    helperText: _adding
                        ? 'Four digits, and nobody else\'s. Tell it to them: it is not shown again'
                        : 'Leave empty to keep the PIN ${was!.you ? 'you' : 'they'} have. Four digits, and nobody else\'s',
                    helperMaxLines: 5,
                    suffixIcon: IconButton(
                      key: const ValueKey('person-pin-show'),
                      tooltip: _hidden ? 'Show what is typed' : 'Hide what is typed',
                      icon: Icon(_hidden ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                      onPressed: () => setState(() => _hidden = !_hidden),
                    ),
                  ),
                ),
              ],
              if (_message != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _message!,
                    key: const ValueKey('person-problem'),
                    style: TextStyle(color: scheme.error),
                  ),
                ),
              if (!_adding && (was!.canRemove))
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      key: const ValueKey('person-remove'),
                      style: TextButton.styleFrom(foregroundColor: scheme.error),
                      onPressed: _busy ? null : _remove,
                      icon: const Icon(Icons.person_remove_outlined),
                      label: const Text('Take off the staff'),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: Text(_canChange ? 'Cancel' : 'Close'),
        ),
        if (_canChange)
          FilledButton(
            key: const ValueKey('person-save'),
            onPressed: _busy ? null : _save,
            child: Text(_adding ? 'Add' : 'Save'),
          ),
      ],
    );
  }
}
