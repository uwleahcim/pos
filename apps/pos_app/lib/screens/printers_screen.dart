import 'dart:io';

import 'package:flutter/material.dart';

import '../api.dart';
import '../printers.dart';

/// The kitchen printers, for a manager: each prints for one station of the menu, by its address, in ESC/POS
/// or StarPRNT, with the printers that take its tickets when it is down, in order. The screen says which
/// stations the menu prints at and have no printer yet (one tap adds it), finds the printers on the LAN and
/// tells their language, and sets the station a to-go order prints whole at. The hub keeps it all and
/// routes the next ticket by it. Behind the manager PIN, from Location settings.
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
    required this.station,
    required String address,
    required this.dialect,
    List<String>? fallbacks,
  }) : address = TextEditingController(text: address),
       fallbacks = List.of(fallbacks ?? const []);

  final String id;
  String station;
  bool stationTyped = false;
  final TextEditingController address;
  final TextEditingController stationCode = TextEditingController();
  final FocusNode addressFocus = FocusNode();
  String dialect;
  final List<String> fallbacks;
  FoundPrinter? identity; // what the hub last said about the address
  bool identifying = false;

  PrinterConfig get config => PrinterConfig(
    id: id,
    station: station.trim(),
    address: address.text.trim(),
    dialect: dialect,
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
  List<FoundPrinter>? _found;
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
    _rows = [
      for (final p in settings.printers)
        _PrinterRow(
          id: p.id ?? _freshId(),
          station: p.station,
          address: p.address,
          dialect: p.dialect,
          fallbacks: p.fallbacks,
        ),
    ];
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

  _PrinterRow _add({String station = '', String address = '', String? dialect, FoundPrinter? identity}) {
    final row = _PrinterRow(id: _freshId(), station: station, address: address, dialect: dialect ?? 'escpos')
      ..identity = identity;
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

  Future<void> _save() async {
    for (final row in _rows) {
      if (row.station.trim().isEmpty) {
        setState(() => _message = 'Every printer needs the station it prints for.');
        return;
      }
      if (row.address.text.trim().isEmpty) {
        setState(() => _message = 'The ${_nameOf(row.station)} printer needs its address.');
        return;
      }
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final saved = await widget.api.savePrinterSettings(
        widget.token,
        PrinterSettings(printers: [for (final row in _rows) row.config], takeoutStation: _takeout),
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _settings = saved;
        _apply(saved);
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
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Demo ticket queued for the ${_nameOf(row.station)} printer')));
    } on ApiException catch (err) {
      if (!mounted) return;
      final unknown = err.status == 404;
      setState(() => _message = unknown ? 'Save the printers first, then test.' : err.message);
    }
  }

  /// Asks the hub what the printer at the row's address is, and takes its language.
  Future<void> _identify(_PrinterRow row) async {
    final address = row.address.text.trim();
    if (address.isEmpty) return;
    setState(() {
      row.identifying = true;
      row.identity = null;
    });
    try {
      final found = await widget.api.identifyPrinter(widget.token, address);
      if (!mounted) return;
      setState(() {
        row.identifying = false;
        row.identity = found;
        if (found.dialect != null) row.dialect = found.dialect!;
      });
    } on ApiException catch (err) {
      if (!mounted) return;
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

  Future<void> _scan() async {
    setState(() {
      _scanning = true;
      _scanMessage = null;
    });
    try {
      final found = await widget.api.discoverPrinters(widget.token, addresses: await _scanHints());
      if (!mounted) return;
      setState(() {
        _scanning = false;
        _found = found;
        _scanMessage = found.isEmpty ? 'No printer answered on port 9100 on the networks the hub looked at.' : null;
      });
    } on ApiException catch (err) {
      if (!mounted) return;
      setState(() {
        _scanning = false;
        _scanMessage = err.message;
      });
    }
  }

  String _nameOf(String code) => _stations?.nameOf(code) ?? code;

  /// The stations the menu knows, the printers' own among them even when the menu does not (typed).
  List<StationInfo> get _stationChoices {
    final known = _stations?.stations ?? const <StationInfo>[];
    final extra = <StationInfo>[
      for (final code in {for (final r in _rows) r.station, ?_takeout})
        if (code.isNotEmpty && !known.any((s) => s.code == code)) StationInfo(code: code, name: code, known: false),
    ];
    return [...known, ...extra];
  }

  /// Stations the menu prints at that no printer here serves, as the hub lists them, less the rows added
  /// since (unsaved), for the suggestions.
  List<StationInfo> get _missing {
    final stations = _stations;
    if (stations == null) return const [];
    final served = {for (final r in _rows) r.station.trim()};
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
                onPressed: _scanning ? null : _scan,
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
          if (_found != null && _found!.isNotEmpty) ...[const SizedBox(height: 12), _foundCard(context)],
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

  /// The printers the hub found on the LAN, each with an Add button (or the station it already prints for).
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
              onPressed: () => setState(() => _found = null),
            ),
          ),
          for (final found in _found!)
            ListTile(
              key: ValueKey('found:${found.address}'),
              dense: true,
              title: Text(found.address),
              subtitle: Text(found.line, style: theme.textTheme.bodySmall),
              trailing: switch (_rows.where((r) => r.address.text.trim() == found.address).firstOrNull) {
                final row? => Text(_nameOf(row.station).isEmpty ? 'Added' : _nameOf(row.station)),
                null => TextButton(
                  key: ValueKey('found-add:${found.address}'),
                  onPressed: () => _add(address: found.address, dialect: found.dialect, identity: found),
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

  /// One printer: its station, address with the Detect button, language, fallbacks, test and bin.
  Widget _printerCard(BuildContext context, int i) {
    final row = _rows[i];
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final choices = _stationChoices;
    final others = [
      for (final r in _rows)
        if (r != row && !row.fallbacks.contains(r.id)) r,
    ];
    final identity = row.identity;
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
                    row.station.isEmpty ? 'New printer' : '${_nameOf(row.station)} printer',
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
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: row.stationTyped || (choices.isEmpty && row.station.isEmpty)
                  ? TextField(
                      key: ValueKey('printer-station-code:${row.id}'),
                      controller: row.stationCode,
                      autocorrect: false,
                      decoration: InputDecoration(
                        isDense: true,
                        labelText: 'Station code',
                        hintText: 'dessert',
                        helperText: 'Letters and digits, as the menu editor will show it under Prints at',
                        border: const OutlineInputBorder(),
                        suffixIcon: choices.isEmpty
                            ? null
                            : IconButton(
                                tooltip: 'Pick from the list',
                                icon: const Icon(Icons.arrow_drop_down),
                                onPressed: () => setState(() => row.stationTyped = false),
                              ),
                      ),
                      onChanged: (t) => setState(() => row.station = t.trim().toLowerCase()),
                    )
                  : DropdownButtonFormField<String>(
                      key: ValueKey('printer-station:${row.id}'),
                      initialValue: choices.any((s) => s.code == row.station) ? row.station : null,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        isDense: true,
                        labelText: 'Prints for the station',
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        for (final s in choices)
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
                          row.station = '';
                          row.stationCode.clear();
                          row.stationTyped = true;
                        } else if (v != null) {
                          row.station = v;
                        }
                      }),
                    ),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: TextField(
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
                  suffixIcon: row.identifying
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                        )
                      : IconButton(
                          key: ValueKey('printer-detect:${row.id}'),
                          tooltip: 'Ask the printer what it is',
                          icon: const Icon(Icons.search),
                          onPressed: () => _identify(row),
                        ),
                ),
                onChanged: (_) => setState(() => row.identity = null),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Text('Language', style: theme.textTheme.labelLarge),
                const SizedBox(width: 12),
                Expanded(
                  child: SegmentedButton<String>(
                    key: ValueKey('printer-dialect:${row.id}'),
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: 'escpos', label: Text('ESC/POS')),
                      ButtonSegment(value: 'star', label: Text('Star')),
                    ],
                    selected: {row.dialect},
                    onSelectionChanged: (picked) => setState(() => row.dialect = picked.first),
                  ),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(0, 6, 8, 0),
              child: Text(
                identity != null
                    ? identity.reachable
                          ? 'The printer says: ${identity.line}'
                          : 'Nothing answers at ${identity.address}'
                    : 'ESC/POS for an Epson and most others, Star for a Star printer in StarPRNT mode; the magnifier '
                          'asks the printer itself.',
                key: ValueKey('printer-identity:${row.id}'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: identity != null && !identity.reachable ? scheme.error : scheme.onSurfaceVariant,
                ),
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
                            child: Text(other.station.isEmpty ? 'New printer' : _nameOf(other.station)),
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
                : other.station.isEmpty
                ? 'New printer'
                : '${_nameOf(other.station)} printer · ${other.address.text}',
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
}
