import 'package:flutter/material.dart';

import '../api.dart';
import '../printers.dart';

/// A device name as the app keeps it: letters and digits only.
final _deviceName = RegExp(r'^[A-Za-z0-9]{1,40}$');

/// What a row of Location settings says about the screens that skip a station: "bar1: no ticket at Bar", the
/// first two screens and how many more; every screen prints everywhere when none is listed.
String ticketSkipsLine(TicketSkips skips, StationList? stations) {
  String one(MapEntry<String, List<String>> screen) =>
      '${screen.key}: no ticket at ${[for (final code in screen.value) stations?.nameOf(code) ?? code].join(', ')}';
  final listed = [
    for (final screen in skips.screens.entries)
      if (screen.value.isNotEmpty) screen,
  ];
  if (listed.isEmpty) return 'Every screen prints at every station';
  return [
    for (final screen in listed.take(2)) one(screen),
    if (listed.length > 2) '${listed.length - 2} more',
  ].join(' · ');
}

/// The screens that print no ticket at a station, for a manager: the bar's own screen and the bar printer,
/// since whoever rings a drink in there makes it. Each screen is named (picked from the ones the hub hears
/// from, or typed) and its stations are buttons; a screen left with none prints everywhere and drops off the
/// list. Saved on the hub, which prints the next send by it.
class TicketSkipsDialog extends StatefulWidget {
  const TicketSkipsDialog({
    super.key,
    required this.api,
    required this.token,
    required this.skips,
    required this.stations,
    this.devices = const [],
    this.device,
  });

  final PosApi api;
  final String token;
  final TicketSkips skips;

  /// The stations a screen can skip, by the names the menu gives them.
  final List<StationInfo> stations;

  /// The screens the hub has heard from, by device name, and this one's own name.
  final List<String> devices;
  final String? device;

  @override
  State<TicketSkipsDialog> createState() => _TicketSkipsDialogState();
}

class _TicketSkipsDialogState extends State<TicketSkipsDialog> {
  late final Map<String, Set<String>> _screens = {
    for (final MapEntry(:key, :value) in widget.skips.screens.entries) key: {...value},
  };
  final _typed = TextEditingController();
  final _typedFocus = FocusNode(debugLabel: 'a screen typed');
  bool _typing = false;
  String? _message;
  bool _busy = false;

  @override
  void dispose() {
    _typed.dispose();
    _typedFocus.dispose();
    super.dispose();
  }

  bool _listed(String device) => _screens.keys.any((name) => name.toLowerCase() == device.toLowerCase());

  /// The screens that can still be added: this one first, then the ones the hub has heard from, by name.
  List<String> get _toAdd {
    final here = widget.device?.trim() ?? '';
    final others = {
      for (final device in widget.devices)
        if (device.toLowerCase() != here.toLowerCase()) device,
    }.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return [
      for (final device in [if (here.isNotEmpty) here, ...others])
        if (!_listed(device)) device,
    ];
  }

  void _add(String device) => setState(() {
    _screens[device] = {};
    _message = null;
  });

  void _addTyped() {
    final name = _typed.text.trim();
    if (name.isEmpty) return;
    if (!_deviceName.hasMatch(name)) {
      return setState(() => _message = 'A device name is letters and digits, as its Settings show it');
    }
    if (_listed(name)) return setState(() => _message = '$name is already listed');
    setState(() {
      _screens[name] = {};
      _typed.clear();
      _typing = false;
      _message = null;
    });
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    // the stations in the order the menu lists them, whatever order they were tapped in
    final order = [for (final station in widget.stations) station.code];
    final next = TicketSkips({
      for (final MapEntry(:key, :value) in _screens.entries)
        key: [
          for (final code in order)
            if (value.contains(code)) code,
          for (final code in value)
            if (!order.contains(code)) code,
        ],
    });
    try {
      final saved = await widget.api.saveTicketSkips(widget.token, next);
      if (mounted) Navigator.of(context).pop(saved);
    } on ApiException catch (err) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _message = err.detail?['message'] as String? ?? err.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hint = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final here = widget.device?.trim().toLowerCase() ?? '';
    final toAdd = _toAdd;
    return AlertDialog(
      title: const Text('Screens that skip a station'),
      contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Dishes sent or voided from a screen listed here print no ticket at the stations picked for '
                'it: whoever rings them in there makes them, like drinks at the bar\'s own screen. They stay on '
                'the check and everything else prints as usual.',
                style: hint,
              ),
              if (_screens.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 14),
                  child: Text(
                    'No screen skips a station: every screen prints at every station.',
                    key: const ValueKey('skips-none'),
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              for (final MapEntry(key: device, value: skipped) in _screens.entries) ...[
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        device.toLowerCase() == here ? '$device (this device)' : device,
                        key: ValueKey('skips-screen:$device'),
                        style: theme.textTheme.titleSmall,
                      ),
                    ),
                    IconButton(
                      key: ValueKey('skips-remove:$device'),
                      tooltip: 'Take $device off the list',
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.delete_outline),
                      onPressed: _busy ? null : () => setState(() => _screens.remove(device)),
                    ),
                  ],
                ),
                Text(
                  skipped.isEmpty
                      ? 'Tap the stations it prints no ticket at. With none, it prints everywhere.'
                      : 'Prints no ticket at:',
                  style: hint,
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final station in [
                      ...widget.stations,
                      // a station it skips that the menu no longer lists: still shown, to be taken off
                      for (final code in skipped)
                        if (!widget.stations.any((s) => s.code == code)) StationInfo(code: code, name: code),
                    ])
                      FilterChip(
                        key: ValueKey('skips:$device:${station.code}'),
                        label: Text(station.name),
                        selected: skipped.contains(station.code),
                        onSelected: _busy
                            ? null
                            : (on) => setState(() => on ? skipped.add(station.code) : skipped.remove(station.code)),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 16),
              Text('Add a screen', style: theme.textTheme.titleSmall),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final device in toAdd)
                    ActionChip(
                      key: ValueKey('skips-add:$device'),
                      avatar: const Icon(Icons.add, size: 18),
                      label: Text(device.toLowerCase() == here ? '$device (this device)' : device),
                      onPressed: _busy ? null : () => _add(device),
                    ),
                  if (!_typing)
                    ActionChip(
                      key: const ValueKey('skips-add-other'),
                      avatar: const Icon(Icons.edit_outlined, size: 18),
                      label: const Text('Other…'),
                      onPressed: _busy
                          ? null
                          : () {
                              setState(() => _typing = true);
                              WidgetsBinding.instance.addPostFrameCallback((_) => _typedFocus.requestFocus());
                            },
                    ),
                ],
              ),
              if (_typing)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: TextField(
                    key: const ValueKey('skips-typed'),
                    controller: _typed,
                    focusNode: _typedFocus,
                    autocorrect: false,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _addTyped(),
                    decoration: InputDecoration(
                      isDense: true,
                      border: const OutlineInputBorder(),
                      labelText: 'Device name',
                      hintText: 'bar1',
                      helperText: 'As the screen shows it under Settings',
                      suffixIcon: IconButton(
                        key: const ValueKey('skips-typed-add'),
                        tooltip: 'Add',
                        icon: const Icon(Icons.add),
                        onPressed: _addTyped,
                      ),
                    ),
                  ),
                ),
              if (_message != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    _message!,
                    key: const ValueKey('skips-message'),
                    style: TextStyle(color: scheme.error),
                  ),
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(key: const ValueKey('skips-save'), onPressed: _busy ? null : _save, child: const Text('Save')),
      ],
    );
  }
}
