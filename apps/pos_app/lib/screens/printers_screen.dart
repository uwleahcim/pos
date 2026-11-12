import 'dart:io';

import 'package:flutter/material.dart';

import '../api.dart';
import '../printers.dart';

/// The kitchen printers, for a manager: each prints for one station of the menu or several, by its address
/// (typed, or picked from the printers the hub finds on the LAN: the magnifier), in the language the printer
/// itself answers with (Auto) or one set by hand, with the printers that take its tickets when it is down,
/// in order. The screen says which stations the menu prints at and have no printer yet (one tap adds it)
/// and sets the station a to-go order prints whole at. The hub keeps it all and routes the next ticket by
/// it. Behind the manager PIN, from Location settings.
class PrintersScreen extends StatefulWidget {
  const PrintersScreen({super.key, required this.api, required this.token, this.addresses});

  final PosApi api;
  final String token;

  /// Addresses that name the subnets to look for printers on: this terminal's own and the hub's. Found by
  /// the screen itself when left out.
  final List<String>? addresses;

  @override
  State<PrintersScreen> createState() => _PrintersScreenState();
}

/// One printer as the screen edits it. Every row has an id, the hub's or one made here, since the other
/// printers' fallbacks name it.
class _PrinterRow {
  _PrinterRow({
    required this.id,
    List<String>? stations,
    required String address,
    required this.dialect,
    this.detected,
    List<String>? fallbacks,
  }) : stations = List.of(stations ?? const []),
       address = TextEditingController(text: address),
       fallbacks = List.of(fallbacks ?? const []);

  final String id;
  final List<String> stations;
  bool stationTyped = false; // a station the menu does not list yet is being typed
  final TextEditingController address;
  final TextEditingController stationCode = TextEditingController();
  final FocusNode addressFocus = FocusNode();
  bool picking = false; // the address is picked from the printers found, not typed
  bool looking = false; // the hub is looking for printers because this row asked
  String dialect; // auto, escpos or star
  String? detected; // the language the printer answered with, which Auto prints in
  final List<String> fallbacks;
  FoundPrinter? identity; // what the hub last said about the address
  bool identifying = false;

  String get where => address.text.trim();

  PrinterConfig get config => PrinterConfig(
    id: id,
    stations: List.of(stations),
    address: where,
    dialect: dialect,
    detected: detected,
    fallbacks: List.of(fallbacks),
  );

  void dispose() {
    address.dispose();
    stationCode.dispose();
    addressFocus.dispose();
  }
}

class _PrintersScreenState extends State<PrintersScreen> {
  PrinterSettings? _settings;
  StationList? _stations;
  String? _loadError;
  List<_PrinterRow> _rows = [];
  String? _takeout;
  bool _busy = false;
  String? _message;
  bool _scanning = false;
  List<FoundPrinter>? _found; // the printers the hub last found, for the list and for every row's pick
  int _scans = 0;
  bool _listShown = false;
  String? _scanMessage;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final row in _rows) {
      row.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loadError = null);
    try {
      final settings = await widget.api.printerSettings();
      if (!mounted) return;
      setState(() {
        _settings = settings;
        _apply(settings);
      });
    } on ApiException catch (err) {
      if (mounted) setState(() => _loadError = err.message);
      return;
    }
    await _loadStations();
  }

  Future<void> _loadStations() async {
    try {
      final stations = await widget.api.printStations();
      if (mounted) setState(() => _stations = stations);
    } on ApiException {
      // an older hub lists no stations: the station is typed
    }
  }

  void _apply(PrinterSettings settings) {
    for (final row in _rows) {
      row.dispose();
    }
    _rows = [];
    for (final p in settings.printers) {
      final row = _PrinterRow(
        id: p.id ?? _freshId(),
        stations: p.stations,
        address: p.address,
        dialect: p.dialect,
        detected: p.detected,
        fallbacks: p.fallbacks,
      );
      // Two printers saved with one address (an older app let that be) are one printer with both stations.
      final same = row.where.isEmpty ? null : _rows.where((r) => r.where == row.where).firstOrNull;
      _rows.add(row);
      if (same != null) _absorb(row, same);
    }
    _takeout = settings.takeoutStation;
  }

  /// An id no printer here has: p1, p2, ... (the hub keeps whatever it is given).
  String _freshId() {
    final taken = {for (final r in _rows) r.id};
    var n = 1;
    while (taken.contains('p$n')) {
      n++;
    }
    return 'p$n';
  }

  _PrinterRow _add({String? station, String address = '', FoundPrinter? identity}) {
    final row = _PrinterRow(
      id: _freshId(),
      stations: [?station],
      address: address,
      dialect: autoDialect,
      detected: identity?.dialect,
    )..identity = identity;
    setState(() {
      _rows.add(row);
      _message = null;
    });
    if (address.isEmpty) WidgetsBinding.instance.addPostFrameCallback((_) => row.addressFocus.requestFocus());
    return row;
  }

  void _remove(_PrinterRow row) => setState(() {
    _rows.remove(row);
    for (final other in _rows) {
      other.fallbacks.remove(row.id);
    }
    row.dispose();
  });

  /// [row] turns out to be the printer [into] already is: its stations and fallbacks move there, whoever
  /// fell back to it falls back to [into], and the row goes.
  void _absorb(_PrinterRow row, _PrinterRow into) {
    _rows.remove(row);
    for (final code in row.stations) {
      if (!into.stations.contains(code)) into.stations.add(code);
    }
    for (final other in _rows) {
      final at = other.fallbacks.indexOf(row.id);
      if (at >= 0) other.fallbacks[at] = into.id;
    }
    into.fallbacks.addAll(row.fallbacks);
    for (final other in _rows) {
      final kept = <String>{};
      other.fallbacks.retainWhere((id) => id != other.id && kept.add(id));
    }
    row.dispose();
  }

  /// Takes a station code typed for a station the menu does not list yet.
  void _commitStation(_PrinterRow row) {
    final code = row.stationCode.text.trim().toLowerCase();
    if (code.isNotEmpty && !row.stations.contains(code)) row.stations.add(code);
    row.stationCode.clear();
    row.stationTyped = false;
  }

  Future<void> _save() async {
    setState(() {
      for (final row in _rows) {
        _commitStation(row);
      }
    });
    for (final row in _rows) {
      if (row.stations.isEmpty) {
        setState(() => _message = 'Every printer needs a station it prints for.');
        return;
      }
      if (row.where.isEmpty) {
        setState(() => _message = 'The ${_title(row)} needs its address.');
        return;
      }
      final same = _rows.where((r) => r != row && r.where == row.where).firstOrNull;
      if (same != null) {
        setState(
          () => _message =
              'The ${_title(same)} and the ${_title(row)} have the same address, ${row.where}. One printer can '
              'print for several stations: put them on one card.',
        );
        return;
      }
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    // A printer left on Auto that has not been asked yet is asked now, so its language is saved with it.
    await Future.wait([
      for (final row in _rows)
        if (row.dialect == autoDialect && row.detected == null && row.identity == null) _identify(row),
    ]);
    if (!mounted) return;
    try {
      final saved = await widget.api.savePrinterSettings(
        widget.token,
        PrinterSettings(printers: [for (final row in _rows) row.config], takeoutStation: _takeout),
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _message = null;
        _settings = saved;
        final known = {for (final row in _rows) row.id: row.identity};
        _apply(saved);
        for (final row in _rows) {
          row.identity = known[row.id];
        }
      });
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Printers saved')));
      await _loadStations();
    } on ApiException catch (err) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _message = err.detail?['message'] as String? ?? err.message;
      });
    }
  }

  Future<void> _test(_PrinterRow row) async {
    setState(() => _message = null);
    try {
      await widget.api.testPrint(row.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Demo ticket queued for the ${_title(row)}')));
    } on ApiException catch (err) {
      if (!mounted) return;
      final unknown = err.status == 404;
      setState(() => _message = unknown ? 'Save the printers first, then test.' : err.message);
    }
  }

  /// Asks the hub what the printer at the row's address is; Auto prints in the language it answers with.
  Future<void> _identify(_PrinterRow row) async {
    final address = row.where;
    if (address.isEmpty) return;
    setState(() => row.identifying = true);
    try {
      final found = await widget.api.identifyPrinter(widget.token, address);
      if (!mounted || !_rows.contains(row)) return;
      setState(() {
        row.identifying = false;
        if (row.where != address) return; // the address changed while the hub was asking
        row.identity = found;
        if (found.dialect != null) row.detected = found.dialect;
      });
    } on ApiException catch (err) {
      if (!mounted || !_rows.contains(row)) return;
      setState(() {
        row.identifying = false;
        _message = err.message;
      });
    }
  }

  /// This terminal's addresses and the hub's, which name the subnets to look on.
  Future<List<String>> _scanHints() async {
    final hints = <String>[
      ...?widget.addresses,
      for (final endpoint in widget.api.settings.endpoints)
        if (Uri.tryParse(endpoint)?.host case final host? when host.isNotEmpty) host,
    ];
    if (widget.addresses == null) {
      try {
        for (final interface in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
          hints.addAll(interface.addresses.map((a) => a.address));
        }
      } on Object {
        // a platform without interface listing: the hub's own addresses still name a subnet
      }
    }
    return hints;
  }

  /// Has the hub look for printers. What it finds serves the list at the foot of the screen and every
  /// row's pick, and tells the rows already at one of those addresses what their printer is. Returns what
  /// went wrong, or null.
  Future<String?> _scan() async {
    setState(() {
      _scanning = true;
      _scanMessage = null;
    });
    try {
      final found = await widget.api.discoverPrinters(widget.token, addresses: await _scanHints());
      if (!mounted) return null;
      setState(() {
        _scanning = false;
        _found = found;
        _scans++;
        _scanMessage = found.isEmpty ? 'No printer answered on port 9100 on the networks the hub looked at.' : null;
        for (final row in _rows) {
          final one = found.where((f) => f.address == row.where).firstOrNull;
          if (one == null) continue;
          row.identity = one;
          if (one.dialect != null) row.detected = one.dialect;
        }
      });
      return null;
    } on ApiException catch (err) {
      if (!mounted) return err.message;
      setState(() {
        _scanning = false;
        _scanMessage = err.message;
      });
      return err.message;
    }
  }

  /// The magnifier: the address turns into a list of the printers on the network to pick from. The hub
  /// looks for them the first time, and again when "Look again" is picked.
  Future<void> _pick(_PrinterRow row, {bool again = false}) async {
    if (_found == null || again) {
      setState(() => row.looking = true);
      final failed = await _scan();
      if (!mounted || !_rows.contains(row)) return;
      setState(() => row.looking = false);
      if (failed != null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(failed)));
        if (_found == null) return;
      }
    }
    setState(() => row.picking = true);
  }

  /// A choice from the list of printers found: an address, "Look again", or "Other" (back to typing).
  void _picked(_PrinterRow row, String? value) {
    if (value == null) return;
    if (value == _other) {
      setState(() => row.picking = false);
      WidgetsBinding.instance.addPostFrameCallback((_) => row.addressFocus.requestFocus());
      return;
    }
    if (value == _again) {
      _pick(row, again: true);
      return;
    }
    final found = _found?.where((f) => f.address == value).firstOrNull;
    final same = _rows.where((r) => r != row && r.where == value).firstOrNull;
    if (same != null) {
      // That printer has a card already: this one's stations go on it.
      final moved = [
        for (final code in row.stations)
          if (!same.stations.contains(code)) _nameOf(code),
      ];
      final was = _stationsOf(same);
      setState(() => _absorb(row, same));
      final what = was.isEmpty ? value : '$value already prints for $was';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            moved.isEmpty
                ? '$what: add the station on its card.'
                : '$what: ${moved.join(' and ')} ${moved.length == 1 ? 'was' : 'were'} added to it.',
          ),
        ),
      );
      return;
    }
    if (value == row.where) return;
    setState(() {
      row.address.text = value;
      row.identity = found;
      row.detected = found?.dialect;
    });
    if (found?.dialect == null && row.dialect == autoDialect) _identify(row);
  }

  String _nameOf(String code) => _stations?.nameOf(code) ?? code;

  /// "Wok 1 + Wok 2": every station the printer prints for.
  String _stationsOf(_PrinterRow row) => row.stations.map(_nameOf).join(' + ');

  /// "Wok 1 + Wok 2 printer", or "new printer" before it has a station.
  String _title(_PrinterRow row) => row.stations.isEmpty ? 'new printer' : '${_stationsOf(row)} printer';

  /// The stations the menu knows, the printers' own among them even when the menu does not (typed).
  List<StationInfo> get _stationChoices {
    final known = _stations?.stations ?? const <StationInfo>[];
    final extra = <StationInfo>[
      for (final code in {for (final r in _rows) ...r.stations, ?_takeout})
        if (code.isNotEmpty && !known.any((s) => s.code == code)) StationInfo(code: code, name: code, known: false),
    ];
    return [...known, ...extra];
  }

  /// Stations the menu prints at that no printer here serves, as the hub lists them, less the rows added
  /// since (unsaved), for the suggestions.
  List<StationInfo> get _missing {
    final stations = _stations;
    if (stations == null) return const [];
    final served = {for (final r in _rows) ...r.stations};
    return [
      for (final code in stations.missing)
        if (!served.contains(code)) ?stations.byCode(code),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final Widget body;
    if (_loadError != null) {
      body = Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_loadError!, style: TextStyle(color: scheme.error)),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: _load, child: const Text('Try again')),
          ],
        ),
      );
    } else if (_settings == null) {
      body = const Center(child: CircularProgressIndicator());
    } else {
      final missing = _missing;
      body = ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (missing.isNotEmpty) ...[_missingCard(context, missing), const SizedBox(height: 12)],
          if (_settings!.source == 'env' && _rows.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
              child: Text(
                'These printers come from the hub\'s POS_PRINTERS setting. Save to keep them here, where they can '
                'be changed from any screen.',
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
          if (_rows.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 4, 12),
              child: Text(
                'No printer yet. Add one by its address, or find the printers on the network.',
                style: theme.textTheme.bodyMedium,
              ),
            ),
          for (var i = 0; i < _rows.length; i++) ...[_printerCard(context, i), const SizedBox(height: 12)],
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              TextButton.icon(
                key: const ValueKey('printer-add'),
                onPressed: () => _add(),
                icon: const Icon(Icons.add),
                label: const Text('Add printer'),
              ),
              TextButton.icon(
                key: const ValueKey('printer-scan'),
                onPressed: _scanning
                    ? null
                    : () async {
                        await _scan();
                        if (mounted) setState(() => _listShown = true);
                      },
                icon: _scanning
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.wifi_find_outlined),
                label: Text(_scanning ? 'Looking…' : 'Find printers on the network'),
              ),
            ],
          ),
          if (_scanMessage != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
              child: Text(_scanMessage!, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
            ),
          if (_listShown && _found != null && _found!.isNotEmpty) ...[const SizedBox(height: 12), _foundCard(context)],
          const SizedBox(height: 12),
          _takeoutCard(context),
          if (_message != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 12, 4, 0),
              child: Text(_message!, style: TextStyle(color: scheme.error)),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(0, 16, 0, 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                FilledButton(
                  key: const ValueKey('printers-save'),
                  onPressed: _busy ? null : _save,
                  child: const Text('Save'),
                ),
              ],
            ),
          ),
        ],
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Printers')),
      body: Center(
        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 640), child: body),
      ),
    );
  }

  /// The stations the menu prints at with no printer: one tap adds the printer, the address to be typed.
  Widget _missingCard(BuildContext context, List<StationInfo> missing) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      color: scheme.errorContainer.withValues(alpha: 0.35),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.warning_amber_rounded, color: scheme.error),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    missing.length == 1
                        ? 'The menu prints at a station with no printer'
                        : 'The menu prints at ${missing.length} stations with no printer',
                    style: theme.textTheme.titleSmall,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Until each has a printer, its dishes print on the first printer in the list. Tap one to add its printer.',
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final station in missing)
                  ActionChip(
                    key: ValueKey('missing:${station.code}'),
                    avatar: const Icon(Icons.add, size: 18),
                    label: Text(station.why.isEmpty ? station.name : '${station.name} · ${station.why}'),
                    onPressed: () => _add(station: station.code),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// What the hub found on the LAN: each receipt printer with an Add button (or the station it already
  /// prints for), and whatever else answers on the printer port by its name, so it is not a mystery.
  Widget _foundCard(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            leading: const Icon(Icons.print_outlined),
            title: Text('${_found!.length} ${_found!.length == 1 ? 'printer' : 'printers'} on the network'),
            trailing: IconButton(
              tooltip: 'Close the list',
              icon: const Icon(Icons.close),
              onPressed: () => setState(() => _listShown = false),
            ),
          ),
          for (final found in _found!)
            ListTile(
              key: ValueKey('found:${found.address}'),
              dense: true,
              title: Text(found.address),
              subtitle: Text(found.line, style: theme.textTheme.bodySmall),
              trailing: switch (_rows.where((r) => r.where == found.address).firstOrNull) {
                final row? => Text(row.stations.isEmpty ? 'Added' : _stationsOf(row)),
                null when found.other => null, // an office printer: listed so it is not a mystery, not offered
                null => TextButton(
                  key: ValueKey('found-add:${found.address}'),
                  onPressed: () => _add(address: found.address, identity: found),
                  child: const Text('Add'),
                ),
              },
            ),
        ],
      ),
    );
  }

  /// The station a to-go order prints whole at, besides each dish's own station.
  Widget _takeoutCard(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final choices = _stationChoices;
    final value = choices.any((s) => s.code == _takeout) ? _takeout : null;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('To-go orders', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              'A counter, phone, online, delivery or catering order prints whole at this station too, for the bag to '
              'be packed and checked; each dish still prints where it is cooked.',
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<String?>(
              key: const ValueKey('takeout-station'),
              initialValue: value,
              decoration: const InputDecoration(
                labelText: 'Print whole at',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              items: [
                const DropdownMenuItem(value: null, child: Text('Nowhere else')),
                for (final s in choices) DropdownMenuItem(value: s.code, child: Text(s.name)),
              ],
              onChanged: (v) => setState(() => _takeout = v),
            ),
          ],
        ),
      ),
    );
  }

  /// One printer: the stations it prints for, its address (typed, or picked from the printers found),
  /// language, fallbacks, test and bin.
  Widget _printerCard(BuildContext context, int i) {
    final row = _rows[i];
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final others = [
      for (final r in _rows)
        if (r != row && !row.fallbacks.contains(r.id)) r,
    ];
    final (note, alarming) = _languageNote(row);
    return Card(
      key: ValueKey('printer:${row.id}'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    row.stations.isEmpty ? 'New printer' : _title(row),
                    key: ValueKey('printer-title:${row.id}'),
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                if (i == 0 && _rows.length > 1)
                  Tooltip(
                    message: 'The first printer also takes every station that has no printer of its own',
                    child: Text('first', style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
                  ),
                IconButton(
                  key: ValueKey('printer-delete:${row.id}'),
                  tooltip: 'Remove this printer',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => _remove(row),
                ),
              ],
            ),
            _stationsField(context, row),
            const SizedBox(height: 12),
            Padding(padding: const EdgeInsets.only(right: 8), child: _addressField(context, row)),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text('Language', style: theme.textTheme.labelLarge),
                ChoiceChip(
                  key: ValueKey('printer-dialect-auto:${row.id}'),
                  showCheckmark: false,
                  avatar: row.identifying
                      ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                      : null,
                  label: Text(row.detected == null ? 'Auto' : 'Auto: ${dialectShort[row.detected] ?? row.detected}'),
                  selected: row.dialect == autoDialect,
                  // a tap asks the printer, whether Auto was already picked or not
                  onSelected: (_) {
                    setState(() => row.dialect = autoDialect);
                    _identify(row);
                  },
                ),
                for (final language in dialectShort.entries)
                  ChoiceChip(
                    key: ValueKey('printer-dialect-${language.key}:${row.id}'),
                    showCheckmark: false,
                    label: Text(language.value),
                    selected: row.dialect == language.key,
                    onSelected: (_) => setState(() => row.dialect = language.key),
                  ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(0, 6, 8, 0),
              child: Text(
                note,
                key: ValueKey('printer-identity:${row.id}'),
                style: theme.textTheme.bodySmall?.copyWith(color: alarming ? scheme.error : scheme.onSurfaceVariant),
              ),
            ),
            const SizedBox(height: 12),
            Text('When it is down, print its tickets at', style: theme.textTheme.labelLarge),
            if (row.fallbacks.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(0, 4, 0, 0),
                child: Text(
                  'No fallback: its tickets wait until it answers again.',
                  style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
            ReorderableListView.builder(
              key: ValueKey('printer-fallbacks:${row.id}'),
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false,
              itemCount: row.fallbacks.length,
              onReorderItem: (from, to) => setState(() => row.fallbacks.insert(to, row.fallbacks.removeAt(from))),
              itemBuilder: (context, j) => _fallbackRow(context, row, j),
            ),
            Row(
              children: [
                if (others.isNotEmpty)
                  DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      key: ValueKey('fallback-add:${row.id}'),
                      hint: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [Icon(Icons.add, size: 18), SizedBox(width: 4), Text('Add fallback')],
                      ),
                      items: [
                        for (final other in others)
                          DropdownMenuItem(
                            value: other.id,
                            child: Text(other.stations.isEmpty ? 'New printer' : _stationsOf(other)),
                          ),
                      ],
                      onChanged: (picked) => setState(() {
                        if (picked != null) row.fallbacks.add(picked);
                      }),
                    ),
                  ),
                const Spacer(),
                TextButton.icon(
                  key: ValueKey('printer-test:${row.id}'),
                  onPressed: () => _test(row),
                  icon: const Icon(Icons.print_outlined, size: 18),
                  label: const Text('Test print'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// The stations the printer prints for, each a chip with its own bin, and a list to add another from: the
  /// stations no printer has yet, or a new one by its code.
  Widget _stationsField(BuildContext context, _PrinterRow row) {
    final theme = Theme.of(context);
    final taken = {for (final r in _rows) ...r.stations};
    final free = [
      for (final s in _stationChoices)
        if (!taken.contains(s.code)) s,
    ];
    final typed = row.stationTyped || (_stationChoices.isEmpty && row.stations.isEmpty);
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('Prints for', style: theme.textTheme.labelLarge),
              for (final code in row.stations)
                InputChip(
                  key: ValueKey('printer-station:${row.id}:$code'),
                  label: Text(_nameOf(code)),
                  deleteButtonTooltipMessage: 'Take ${_nameOf(code)} off this printer',
                  onDeleted: () => setState(() => row.stations.remove(code)),
                ),
              if (!typed)
                DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    key: ValueKey('printer-station-add:${row.id}'),
                    isDense: true,
                    hint: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.add, size: 18),
                        const SizedBox(width: 4),
                        Text(row.stations.isEmpty ? 'Pick the station' : 'Add a station'),
                      ],
                    ),
                    items: [
                      for (final s in free)
                        DropdownMenuItem(
                          value: s.code,
                          child: Text(
                            s.known && s.dishes == 0 && s.choices == 0 && !s.takeout
                                ? '${s.name} (nothing prints here yet)'
                                : s.name,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      const DropdownMenuItem(value: _other, child: Text('A new station…')),
                    ],
                    onChanged: (v) => setState(() {
                      if (v == _other) {
                        row.stationCode.clear();
                        row.stationTyped = true;
                      } else if (v != null) {
                        row.stations.add(v);
                      }
                    }),
                  ),
                ),
            ],
          ),
          if (typed)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: TextField(
                key: ValueKey('printer-station-code:${row.id}'),
                controller: row.stationCode,
                autocorrect: false,
                textInputAction: TextInputAction.done,
                decoration: InputDecoration(
                  isDense: true,
                  labelText: 'Station code',
                  hintText: 'dessert',
                  helperText: 'Letters and digits, as the menu editor will show it under Prints at',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    key: ValueKey('printer-station-commit:${row.id}'),
                    tooltip: 'Add this station',
                    icon: const Icon(Icons.check),
                    onPressed: () => setState(() => _commitStation(row)),
                  ),
                ),
                onSubmitted: (_) => setState(() => _commitStation(row)),
              ),
            ),
        ],
      ),
    );
  }

  /// The printer's address: typed, with the magnifier that turns the field into a list of the printers on
  /// the network; "Other" in that list turns it back.
  Widget _addressField(BuildContext context, _PrinterRow row) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    if (row.looking) {
      return InputDecorator(
        decoration: const InputDecoration(isDense: true, labelText: 'Printer', border: OutlineInputBorder()),
        child: Row(
          children: [
            const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 12),
            Expanded(child: Text('Looking for printers on the network…', style: theme.textTheme.bodyMedium)),
          ],
        ),
      );
    }
    if (!row.picking) {
      return TextField(
        key: ValueKey('printer-address:${row.id}'),
        controller: row.address,
        focusNode: row.addressFocus,
        autocorrect: false,
        keyboardType: TextInputType.url,
        decoration: InputDecoration(
          isDense: true,
          labelText: 'IP address',
          hintText: '172.19.1.162',
          border: const OutlineInputBorder(),
          suffixIcon: IconButton(
            key: ValueKey('printer-detect:${row.id}'),
            tooltip: 'Pick from the printers on the network',
            icon: const Icon(Icons.search),
            onPressed: () => _pick(row),
          ),
        ),
        onChanged: (_) => setState(() {
          row.identity = null;
          row.detected = null;
        }),
        onSubmitted: (_) {
          if (row.dialect == autoDialect) _identify(row);
        },
      );
    }
    final found = _found ?? const <FoundPrinter>[];
    final here = row.where;
    final faint = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    // Each choice: what the list shows (two lines where there is more to say) and what the closed field shows.
    final choices = <(String, bool, String, String?)>[
      if (here.isNotEmpty && !found.any((f) => f.address == here)) (here, true, here, 'not found on the network'),
      for (final f in found) (f.address, !f.other, f.pick, _choiceNote(row, f)),
      (_again, true, 'Look again', null),
      (_other, true, 'Other: type the address', null),
    ];
    return KeyedSubtree(
      // a new list, or an address set from elsewhere, starts the field afresh on what stands now
      key: ValueKey('printer-pick-at:${row.id}:$here:$_scans'),
      child: DropdownButtonFormField<String>(
        key: ValueKey('printer-pick:${row.id}'),
        initialValue: here.isEmpty ? null : here,
        isExpanded: true,
        hint: Text(found.isEmpty ? 'No printer found' : 'Pick a printer'),
        decoration: const InputDecoration(isDense: true, labelText: 'Printer', border: OutlineInputBorder()),
        selectedItemBuilder: (context) => [
          for (final (_, _, line, _) in choices)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: Text(line, overflow: TextOverflow.ellipsis),
            ),
        ],
        items: [
          for (final (value, enabled, line, note) in choices)
            DropdownMenuItem(
              value: value,
              enabled: enabled, // an office printer is named so it is not a mystery, and is not to be picked
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    line,
                    overflow: TextOverflow.ellipsis,
                    style: enabled ? null : TextStyle(color: scheme.onSurface.withValues(alpha: 0.38)),
                  ),
                  if (note != null) Text(note, overflow: TextOverflow.ellipsis, style: faint),
                ],
              ),
            ),
        ],
        onChanged: (value) => _picked(row, value),
      ),
    );
  }

  /// What a row's list says under a found printer: that it cannot print tickets, or the stations it prints
  /// for already when another card has it ("prints for Wok 1 + Wok 2").
  String? _choiceNote(_PrinterRow row, FoundPrinter found) {
    if (found.other) return 'not a receipt printer';
    final user = _rows.where((r) => r != row && r.where == found.address).firstOrNull;
    return user == null || user.stations.isEmpty ? null : 'prints for ${_stationsOf(user)}';
  }

  /// The line under the language: what the printer answered, or what to do; and whether it is a warning.
  (String, bool) _languageNote(_PrinterRow row) {
    final identity = row.identity;
    final auto = row.dialect == autoDialect;
    const untold = 'Until it answers, its tickets go out as ESC/POS.';
    if (row.identifying) return ('Asking the printer…', false);
    if (identity != null) {
      if (!identity.reachable) return ('Nothing answers at ${identity.address}.${auto ? ' $untold' : ''}', true);
      if (identity.other) return ('The printer says: ${identity.line}', true);
      final says = 'The printer says: ${identity.line}';
      if (identity.dialect == null) return (auto ? '$says. $untold' : says, auto);
      if (!auto && identity.dialect != row.dialect) {
        return ('$says, and ${dialectShort[row.dialect] ?? row.dialect} is set here.', true);
      }
      return (says, false);
    }
    if (!auto) return ('ESC/POS for an Epson and most others, Star for a Star printer in StarPRNT mode.', false);
    if (row.detected != null) {
      return ('Auto prints in the language the printer answered with. Tap Auto to ask it again.', false);
    }
    return ('Tap Auto to ask the printer which language it speaks. $untold', false);
  }

  /// One fallback: the handle to move it (the order is the order tried), its name and the bin.
  Widget _fallbackRow(BuildContext context, _PrinterRow row, int j) {
    final id = row.fallbacks[j];
    final other = _rows.where((r) => r.id == id).firstOrNull;
    final scheme = Theme.of(context).colorScheme;
    return Row(
      key: ValueKey('fallback:${row.id}:$id'),
      children: [
        ReorderableDragStartListener(
          index: j,
          child: Padding(
            key: ValueKey('fallback-handle:${row.id}:$id'),
            padding: const EdgeInsets.all(10),
            child: Icon(Icons.drag_handle, color: scheme.onSurfaceVariant),
          ),
        ),
        Text('${j + 1}.', style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            other == null
                ? '$id (no longer a printer)'
                : other.stations.isEmpty
                ? 'New printer'
                : '${_title(other)} · ${other.address.text}',
            overflow: TextOverflow.ellipsis,
          ),
        ),
        IconButton(
          key: ValueKey('fallback-delete:${row.id}:$id'),
          tooltip: 'Remove this fallback',
          icon: const Icon(Icons.close, size: 18),
          onPressed: () => setState(() => row.fallbacks.remove(id)),
        ),
      ],
    );
  }

  static const _other = '\u0000other';
  static const _again = '\u0000again';
}
