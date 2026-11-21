import 'package:flutter/material.dart';

import '../api.dart';
import '../menu_admin.dart';
import '../printers.dart';
import '../settings.dart';

/// The menu editor, for managers: dishes by category on the left, the chosen dish, category or option
/// group on the right. Edits stay on this screen until Save; the backend checks the whole menu and saves
/// it in one go, or says what is wrong and saves nothing. Every terminal picks up a save within seconds.
class MenuEditorScreen extends StatefulWidget {
  const MenuEditorScreen({super.key, required this.api, required this.settings, this.token});

  final PosApi api;
  final Settings settings;

  /// A token from an earlier sign-in (tests); otherwise the screen asks for a manager PIN.
  final String? token;

  @override
  State<MenuEditorScreen> createState() => _MenuEditorScreenState();
}

enum _Pane { dishes, options }

class _Selection {
  const _Selection(this.kind, this.key);
  final String kind; // item | category | group | words (what Extra, On the side and Light charge: no key)
  final String key;
}

class _MenuEditorScreenState extends State<MenuEditorScreen> {
  String? _token;
  MenuCatalog? _catalog;
  StationList? _stations; // which stations have a printer, for the dish's Prints at line; null on an older hub
  String? _error;
  bool _busy = false;
  _Pane _pane = _Pane.dishes;
  _Selection? _selected;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _token = widget.token;
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  Future<void> _start() async {
    if (_token == null && !await _signIn()) {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    await _load();
  }

  Future<bool> _signIn() async {
    final token = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ManagerPinDialog(api: widget.api, device: widget.settings.device, power: 'menu'),
    );
    if (token == null) return false;
    _token = token;
    return true;
  }

  Future<void> _load() async {
    setState(() => _busy = true);
    try {
      final json = await widget.api.adminMenu(_token!);
      if (!mounted) return;
      setState(() {
        _catalog = MenuCatalog.fromJson(json);
        _error = null;
        final picked = _selected;
        if (picked != null && picked.kind != 'words' && _catalog!.get(picked.kind, picked.key) == null) {
          _selected = null;
        }
      });
    } on ApiException catch (err) {
      if (err.status == 401 && mounted && await _signIn()) return _load();
      if (mounted) setState(() => _error = err.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    try {
      final stations = await widget.api.printStations();
      if (mounted) setState(() => _stations = stations);
    } on ApiException {
      // an older hub: the dish says its station, not whether a printer serves it
    }
  }

  void _changed() => setState(() {});

  Future<void> _save({bool dryRun = false}) async {
    final catalog = _catalog;
    if (catalog == null || _busy) return;
    final changes = catalog.changes();
    if (changes.isEmpty && !dryRun) return;
    setState(() => _busy = true);
    try {
      final result = await widget.api.saveMenu(_token!, changes, revision: catalog.revision, dryRun: dryRun);
      if (!mounted) return;
      final warnings = problemsFrom(result['warnings']);
      if (dryRun) {
        setState(() => _busy = false); // no spinner behind a dialog
        await _showProblems('Menu check', const [], warnings, ok: 'Nothing stops a save.');
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Saved ${changes.length} changes. Every terminal has the new menu within seconds.')),
      );
      await _load();
    } on ApiException catch (err) {
      if (!mounted) return;
      setState(() => _busy = false); // no spinner behind a dialog
      if (err.status == 401 && await _signIn()) {
        return _save(dryRun: dryRun); // the hour is up: sign in again and send the same changes
      }
      if (!mounted) return;
      if (err.status == 409) {
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Someone else saved the menu'),
            content: const Text(
              'The menu changed since you opened it. Reload to see their changes, then make yours again.',
            ),
            actions: [
              TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Keep editing')),
              FilledButton(
                onPressed: () {
                  Navigator.of(context).pop();
                  _load();
                },
                child: const Text('Reload'),
              ),
            ],
          ),
        );
        return;
      }
      final errors = problemsFrom(err.detail?['errors']);
      final message = err.detail?['message'] as String?;
      await _showProblems(
        dryRun ? 'Menu check' : 'Not saved',
        errors.isEmpty ? [Problem(err.message, message ?? err.message)] : errors,
        problemsFrom(err.detail?['warnings']),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showProblems(String title, List<Problem> errors, List<Problem> warnings, {String? ok}) =>
      showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: SizedBox(
            width: 520,
            child: ListView(
              shrinkWrap: true,
              children: [
                if (errors.isEmpty && ok != null) ListTile(leading: const Icon(Icons.check_circle), title: Text(ok)),
                for (final p in errors)
                  ListTile(
                    leading: const Icon(Icons.error, color: Colors.red),
                    title: Text(p.message),
                  ),
                for (final p in warnings)
                  ListTile(
                    leading: const Icon(Icons.warning_amber, color: Colors.orange),
                    title: Text(p.message),
                  ),
              ],
            ),
          ),
          actions: [FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text('OK'))],
        ),
      );

  Future<void> _history() async {
    try {
      final changes = await widget.api.menuAudit(_token!);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Menu history'),
          content: SizedBox(
            width: 640,
            height: 480,
            child: changes.isEmpty
                ? const Center(child: Text('No saved changes yet.'))
                : ListView(children: [for (final c in changes) _AuditTile(change: c)]),
          ),
          actions: [FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close'))],
        ),
      );
    } on ApiException catch (err) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err.message)));
    }
  }

  Future<void> _newDish() async {
    final catalog = _catalog!;
    final made = await showDialog<_NewDish>(
      context: context,
      builder: (_) => _NewDishDialog(catalog: catalog),
    );
    if (made == null) return;
    final code = _uniqueCode(catalog, 'item', made.number.isNotEmpty ? made.number : 'D');
    final section = catalog.get('section', made.section)!;
    catalog.put('item', {
      'code': code,
      'category': made.category,
      'names': {'en': made.name, if (made.chinese.isNotEmpty) 'zh': made.chinese},
      'kind': 'standard',
      'aliases': [if (made.number.isNotEmpty) made.number],
      'description': <String, dynamic>{},
      'tax_class': null,
      'station': null,
      'prep_minutes': null,
      'tags': <String>[],
      'attrs': <String, dynamic>{},
      'active': true,
      'sort': catalog.itemsIn(made.category).length,
    });
    catalog.put('variant', newVariant(code, 'regular', 'Regular', made.price, 0));
    catalog.put('entry', newEntry(catalog, code, section, made.number));
    setState(() {
      _pane = _Pane.dishes;
      _selected = _Selection('item', code);
    });
  }

  Future<void> _newGroup() async {
    final catalog = _catalog!;
    final name = await showDialog<String>(
      context: context,
      builder: (_) => const _TextDialog(title: 'New option group', label: 'Name, e.g. "Choice of rice"'),
    );
    if (name == null || name.isEmpty) return;
    final code = _uniqueCode(catalog, 'group', _slug(name));
    catalog.put('group', {
      'code': code,
      'names': {'en': name},
      'min_select': 0,
      'max_select': 1,
      'free_count': 0,
      'allow_quantity': false,
      'allow_duplicates': false,
      'display': 'inline',
      'sort': catalog.groups().length,
    });
    setState(() {
      _pane = _Pane.options;
      _selected = _Selection('group', code);
    });
  }

  Future<bool> _confirmLeave() async {
    if (!(_catalog?.dirty ?? false)) return true;
    final leave = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Leave without saving?'),
        content: const Text('Your changes to the menu are not saved.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Keep editing')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Discard changes')),
        ],
      ),
    );
    return leave ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final catalog = _catalog;
    final count = catalog?.changes().length ?? 0;
    return PopScope(
      canPop: count == 0,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final navigator = Navigator.of(context);
        if (await _confirmLeave()) {
          _catalog = null;
          navigator.pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(catalog == null ? 'Menu editor' : 'Menu editor · revision ${catalog.revision}'),
          actions: [
            IconButton(
              tooltip: 'History',
              icon: const Icon(Icons.history),
              onPressed: catalog == null ? null : _history,
            ),
            IconButton(tooltip: 'Reload', icon: const Icon(Icons.refresh), onPressed: _busy ? null : _load),
            TextButton.icon(
              onPressed: catalog == null || _busy ? null : () => _save(dryRun: true),
              icon: const Icon(Icons.fact_check_outlined),
              label: const Text('Check'),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: FilledButton.icon(
                onPressed: count == 0 || _busy ? null : _save,
                icon: const Icon(Icons.save),
                label: Text(count == 0 ? 'Saved' : 'Save $count'),
              ),
            ),
          ],
        ),
        body: catalog == null
            ? Center(
                child: _error != null
                    ? Text(_error!)
                    : _token == null
                    ? const Text('Waiting for a manager PIN')
                    : const CircularProgressIndicator(),
              )
            : Column(
                children: [
                  if (_busy) const LinearProgressIndicator(minHeight: 2),
                  if (catalog.warnings.isNotEmpty)
                    MaterialBanner(
                      content: Text('${catalog.warnings.length} warnings: ${catalog.warnings.first.message}'),
                      actions: [
                        TextButton(
                          onPressed: () => _showProblems('Warnings', const [], catalog.warnings),
                          child: const Text('Show'),
                        ),
                      ],
                    ),
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(width: 340, child: _list(catalog)),
                        const VerticalDivider(width: 1),
                        Expanded(child: _detail(catalog)),
                      ],
                    ),
                  ),
                ],
              ),
        floatingActionButton: catalog == null
            ? null
            : FloatingActionButton.extended(
                onPressed: _pane == _Pane.dishes ? _newDish : _newGroup,
                icon: const Icon(Icons.add),
                label: Text(_pane == _Pane.dishes ? 'New dish' : 'New option group'),
              ),
      ),
    );
  }

  Widget _list(MenuCatalog catalog) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final q = _query.toLowerCase();
    bool matches(Map<String, dynamic> row) =>
        q.isEmpty ||
        '${row['code']}'.toLowerCase().contains(q) ||
        ((row['names'] as Map?)?.values.any((n) => '$n'.toLowerCase().contains(q)) ?? false);
    final tiles = <Widget>[];
    if (_pane == _Pane.dishes) {
      for (final category in catalog.categories()) {
        final items = catalog.itemsIn(category['code'] as String).where(matches).toList();
        if (items.isEmpty && q.isNotEmpty) continue;
        tiles.add(
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: ListTile(
              dense: true,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              selectedTileColor: scheme.primaryContainer.withValues(alpha: 0.55),
              title: Text(
                nameOf(category).toUpperCase(),
                style: theme.textTheme.labelLarge?.copyWith(color: scheme.primary, letterSpacing: 0.6),
              ),
              trailing: const Icon(Icons.tune, size: 18),
              selected: _selected?.kind == 'category' && _selected?.key == category['code'],
              onTap: () => setState(() => _selected = _Selection('category', category['code'] as String)),
            ),
          ),
        );
        for (final item in items) {
          final key = item['code'] as String;
          final sizes = catalog.variantsOf(key);
          tiles.add(
            ListTile(
              dense: true,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              selectedTileColor: scheme.primaryContainer.withValues(alpha: 0.55),
              contentPadding: const EdgeInsets.only(left: 28, right: 14),
              title: Text(
                nameOf(item),
                style: item['active'] == false
                    ? TextStyle(color: scheme.outline, decoration: TextDecoration.lineThrough)
                    : theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
              subtitle: Text(
                [
                  if (nameOf(item, 'zh') != nameOf(item)) nameOf(item, 'zh'),
                  sizes.map((v) => '\$${v['base_price']}').join(' / '),
                ].join(' · '),
              ),
              trailing: catalog.isChanged('item', key) || sizes.any((v) => catalog.isChanged('variant', v['id']))
                  ? Icon(Icons.edit, size: 16, color: scheme.primary)
                  : null,
              selected: _selected?.kind == 'item' && _selected?.key == key,
              onTap: () => setState(() => _selected = _Selection('item', key)),
            ),
          );
        }
      }
    } else {
      if (catalog.pricesWords && q.isEmpty) {
        // what the one-tap words charge on every group, ahead of the groups
        tiles.add(
          ListTile(
            key: const ValueKey('words-tile'),
            dense: true,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            selectedTileColor: scheme.primaryContainer.withValues(alpha: 0.55),
            leading: const Icon(Icons.price_change_outlined, size: 20),
            title: Text(
              pricedWords.values.join(', '),
              style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
            subtitle: Text(wordsLine(catalog), maxLines: 2, overflow: TextOverflow.ellipsis),
            trailing: pricedWords.keys.any((word) => catalog.isChanged('word', word))
                ? Icon(Icons.edit, size: 16, color: scheme.primary)
                : null,
            selected: _selected?.kind == 'words',
            onTap: () => setState(() => _selected = const _Selection('words', '')),
          ),
        );
      }
      for (final group in catalog.groups().where(matches)) {
        final key = group['code'] as String;
        tiles.add(
          ListTile(
            dense: true,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            selectedTileColor: scheme.primaryContainer.withValues(alpha: 0.55),
            title: Text(nameOf(group), style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
            subtitle: Text(
              catalog.optionsOf(key).map((o) => optionName(catalog, o)).join(', '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            selected: _selected?.kind == 'group' && _selected?.key == key,
            onTap: () => setState(() => _selected = _Selection('group', key)),
          ),
        );
      }
    }
    return Material(
      color: scheme.surfaceContainerLowest,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: SegmentedButton<_Pane>(
              segments: const [
                ButtonSegment(value: _Pane.dishes, label: Text('Dishes'), icon: Icon(Icons.restaurant_menu)),
                ButtonSegment(value: _Pane.options, label: Text('Option groups'), icon: Icon(Icons.checklist)),
              ],
              selected: {_pane},
              onSelectionChanged: (s) => setState(() => _pane = s.first),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: TextField(
              decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search', isDense: true),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          Expanded(
            child: ListView(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), children: tiles),
          ),
        ],
      ),
    );
  }

  Widget _detail(MenuCatalog catalog) {
    final s = _selected;
    final Widget child;
    if (s?.kind == 'words') {
      child = SingleChildScrollView(
        key: ValueKey('words/${catalog.revision}'),
        padding: const EdgeInsets.all(24),
        child: WordsEditor(catalog: catalog, onChanged: _changed),
      );
    } else if (s == null || catalog.get(s.kind, s.key) == null) {
      child = const Center(key: ValueKey('empty-detail'), child: Text('Pick a dish, a category or an option group.'));
    } else {
      final Widget editor = switch (s.kind) {
        'item' => ItemEditor(
          catalog: catalog,
          itemKey: s.key,
          onChanged: _changed,
          onDeleted: () => setState(() => _selected = null),
          stations: _stations,
        ),
        'category' => CategoryEditor(catalog: catalog, categoryKey: s.key, onChanged: _changed),
        _ => GroupEditor(catalog: catalog, groupKey: s.key, onChanged: _changed, stations: _stations),
      };
      child = SingleChildScrollView(
        key: ValueKey('${s.kind}/${s.key}/${catalog.revision}'),
        padding: const EdgeInsets.all(24),
        child: editor,
      );
    }
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      // a short page (the location's rule for Extra) starts at the top like a long one, not in the middle
      layoutBuilder: (current, previous) => Stack(alignment: Alignment.topLeft, children: [...previous, ?current]),
      child: child,
    );
  }
}

// --- the editors ----------------------------------------------------------------------------------------

/// One dish: its names, where it prints, its sizes and prices, where it sits on the menus, its option groups.
class ItemEditor extends StatelessWidget {
  const ItemEditor({
    super.key,
    required this.catalog,
    required this.itemKey,
    required this.onChanged,
    required this.onDeleted,
    this.stations,
  });

  final MenuCatalog catalog;
  final String itemKey;
  final VoidCallback onChanged;
  final VoidCallback onDeleted;

  /// The stations as the hub lists them, with the printer serving each; null when the hub did not say.
  final StationList? stations;

  @override
  Widget build(BuildContext context) {
    final item = catalog.get('item', itemKey)!;
    final category = catalog.get('category', item['category'] as String);
    final sizes = catalog.variantsOf(itemKey);
    final entries = catalog.entriesOf(itemKey);
    final own = catalog.attachmentsOf('item', itemKey);
    final inherited = catalog.attachmentsOf('category', item['category'] as String);
    final with_ = goesWith(catalog, item);
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text(nameOf(item), style: theme.textTheme.headlineSmall)),
            Text('On sale'),
            Switch(
              value: item['active'] != false,
              onChanged: (v) {
                item['active'] = v;
                onChanged();
              },
            ),
          ],
        ),
        _names(item, onChanged, kitchen: true),
        const SizedBox(height: 12),
        Wrap(
          spacing: 16,
          runSpacing: 12,
          children: [
            _dropdown<String>(
              label: 'Category',
              value: item['category'] as String,
              items: {for (final c in catalog.categories()) c['code'] as String: nameOf(c)},
              onChanged: (v) {
                item['category'] = v;
                onChanged();
              },
            ),
          ],
        ),
        _heading(context, 'Prints at'),
        _dropdown<String?>(
          label: 'Station',
          value: item['station'] as String?,
          items: {
            null: 'Category\'s station (${_stationName(catalog, category?['station'] as String?)})',
            for (final s in catalog.stations()) s['code'] as String: nameOf(s),
            _newStation: 'A new station…',
          },
          onChanged: (v) async {
            if (v == _newStation) {
              final code = await newStation(context, catalog);
              if (code == null) return;
              item['station'] = code;
            } else {
              item['station'] = v;
            }
            onChanged();
          },
        ),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            _printsAtLine(catalog, (item['station'] ?? category?['station']) as String?, stations),
            key: const ValueKey('prints-at'),
            style: theme.textTheme.bodySmall,
          ),
        ),
        _heading(context, 'Sizes and prices'),
        SwitchListTile(
          key: ValueKey('$itemKey/asks-price'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Its price is typed when it is rung'),
          subtitle: const Text(
            'For a market price. The order screen asks for the price each time, and the prices below are not used.',
          ),
          value: asksPrice(item),
          onChanged: (v) {
            setAsks(item, price: v, name: v && asksName(item));
            onChanged();
          },
        ),
        SwitchListTile(
          key: ValueKey('$itemKey/asks-name'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Its name is typed too'),
          subtitle: const Text(
            'An off-menu dish, like Open Food. Whoever rings it types what it is and its price: '
            'that is what the check, the bill and the kitchen ticket say.',
          ),
          value: asksName(item),
          onChanged: (v) {
            setAsks(item, price: v || asksPrice(item), name: v);
            onChanged();
          },
        ),
        const SizedBox(height: 10),
        for (final v in sizes)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                SizedBox(width: 200, child: _text('${v['id']}/name', 'Size', nameOf(v), (t) => _setName(v, 'en', t))),
                const SizedBox(width: 12),
                SizedBox(
                  width: 120,
                  child: _price('${v['id']}/price', v['base_price'] as String, (p) {
                    v['base_price'] = p;
                    onChanged();
                  }),
                ),
                const SizedBox(width: 12),
                const Text('On sale'),
                Switch(
                  value: v['active'] != false,
                  onChanged: (on) {
                    v['active'] = on;
                    onChanged();
                  },
                ),
                if (sizes.length > 1)
                  IconButton(
                    tooltip: 'Remove this size',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () {
                      removeVariant(catalog, v['id'] as String);
                      onChanged();
                    },
                  ),
              ],
            ),
          ),
        TextButton.icon(
          icon: const Icon(Icons.add),
          label: const Text('Add a size'),
          onPressed: () {
            final code = _uniqueCode(catalog, 'variant', 'size', prefix: '$itemKey:');
            final price = sizes.isEmpty ? '0.00' : sizes.last['base_price'] as String;
            catalog.put('variant', newVariant(itemKey, code, 'New size', price, sizes.length));
            onChanged();
          },
        ),
        _heading(context, 'On the menu'),
        for (final e in entries)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                SizedBox(
                  width: 100,
                  child: _text('${e['id']}/number', 'Number', e['number'] as String? ?? '', (t) {
                    e['number'] = t.trim().isEmpty ? null : t.trim();
                    onChanged();
                  }),
                ),
                const SizedBox(width: 12),
                _dropdown<String>(
                  label: 'Section',
                  value: e['section'] as String,
                  items: {
                    for (final s in catalog.sections())
                      if (s['menu'] == e['menu'])
                        s['id'] as String: '${nameOf(catalog.get('menu', s['menu'] as String))} › ${nameOf(s)}',
                  },
                  onChanged: (v) {
                    e['section'] = v;
                    onChanged();
                  },
                ),
                const SizedBox(width: 12),
                const Text('Shown'),
                Switch(
                  value: e['visible'] != false,
                  onChanged: (on) {
                    e['visible'] = on;
                    onChanged();
                  },
                ),
                IconButton(
                  tooltip: 'Take off this menu',
                  icon: const Icon(Icons.remove_circle_outline),
                  onPressed: () {
                    catalog.delete('entry', e['id'] as String);
                    onChanged();
                  },
                ),
              ],
            ),
          ),
        TextButton.icon(
          icon: const Icon(Icons.add),
          label: const Text('Put on a menu'),
          onPressed: () async {
            final section = await showDialog<String>(
              context: context,
              builder: (_) => _PickDialog(
                title: 'Which section?',
                options: {
                  for (final s in catalog.sections())
                    s['id'] as String: '${nameOf(catalog.get('menu', s['menu'] as String))} › ${nameOf(s)}',
                },
              ),
            );
            if (section == null) return;
            catalog.put('entry', newEntry(catalog, itemKey, catalog.get('section', section)!, ''));
            onChanged();
          },
        ),
        _heading(context, 'Option groups'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final a in own)
              InputChip(
                label: Text(nameOf(catalog.get('group', a['group'] as String))),
                onDeleted: () {
                  catalog.delete('attachment', keyOf('attachment', a));
                  onChanged();
                },
              ),
            for (final a in inherited)
              Chip(
                avatar: const Icon(Icons.subdirectory_arrow_right, size: 16),
                label: Text('${nameOf(catalog.get('group', a['group'] as String))} (from ${nameOf(category)})'),
              ),
            ActionChip(
              avatar: const Icon(Icons.add, size: 18),
              label: const Text('Add a group'),
              onPressed: () async {
                final taken = {...own, ...inherited}.map((a) => a['group']).toSet();
                var group = await showDialog<String>(
                  context: context,
                  builder: (_) => _PickDialog(
                    title: 'Ask for which options?',
                    options: {
                      for (final g in catalog.groups())
                        if (!taken.contains(g['code'])) g['code'] as String: nameOf(g),
                      _fromCategory: 'A new group offering the dishes of a category…',
                    },
                  ),
                );
                if (group == null) return;
                if (group == _fromCategory) {
                  // the maki combination offers the Roll category: every roll on sale, kept in step with it
                  if (!context.mounted) return;
                  final category = await showDialog<String>(
                    context: context,
                    builder: (_) => _PickDialog(
                      title: 'Offer the dishes of which category?',
                      options: {for (final c in catalog.categories()) c['code'] as String: nameOf(c)},
                    ),
                  );
                  if (category == null) return;
                  group = newSourcedGroup(catalog, category);
                }
                catalog.put('attachment', {
                  'owner_kind': 'item',
                  'owner': itemKey,
                  'group': group,
                  'overrides': <String, dynamic>{},
                  'excluded': false,
                  'sort': own.length,
                });
                onChanged();
              },
            ),
          ],
        ),
        _heading(context, 'Goes with'),
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Text(
            'Once this dish is rung, the order screen shows these under the dishes, one tap each. '
            'Nothing is added unless somebody taps it. Up to $goesWithMost, shown in this order.',
            style: theme.textTheme.bodySmall,
          ),
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final code in with_)
              InputChip(
                key: ValueKey('$itemKey/goes-with/$code'),
                label: Text(
                  catalog.get('item', code)?['active'] == false
                      ? '${nameOf(catalog.get('item', code))} (not on sale)'
                      : nameOf(catalog.get('item', code)),
                ),
                onDeleted: () {
                  setGoesWith(item, [...with_.where((c) => c != code)]);
                  onChanged();
                },
              ),
            if (with_.length < goesWithMost)
              ActionChip(
                key: ValueKey('$itemKey/goes-with/add'),
                avatar: const Icon(Icons.add, size: 18),
                label: const Text('Add a dish'),
                onPressed: () async {
                  final picked = await showDialog<String>(
                    context: context,
                    builder: (_) => _SearchPickDialog(
                      title: 'Goes with which dish?',
                      options: wholeDishes(catalog, except: {itemKey, ...with_}),
                    ),
                  );
                  if (picked == null) return;
                  setGoesWith(item, [...with_, picked]);
                  onChanged();
                },
              ),
          ],
        ),
        const SizedBox(height: 32),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(foregroundColor: theme.colorScheme.error),
          icon: const Icon(Icons.delete_forever),
          label: const Text('Delete this dish'),
          onPressed: () async {
            final sure = await showDialog<bool>(
              context: context,
              builder: (context) => AlertDialog(
                title: Text('Delete ${nameOf(item)}?'),
                content: const Text(
                  'It goes from every menu with its sizes. Old checks keep it. '
                  'To stop selling it for now, switch "On sale" off instead.',
                ),
                actions: [
                  TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
                  FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Delete')),
                ],
              ),
            );
            if (sure != true) return;
            removeItem(catalog, itemKey);
            onDeleted();
          },
        ),
      ],
    );
  }

  void _setName(Map<String, dynamic> row, String locale, String text) {
    final names = Map<String, dynamic>.from(row['names'] as Map? ?? const {});
    if (text.trim().isEmpty) {
      names.remove(locale);
    } else {
      names[locale] = text.trim();
    }
    row['names'] = names;
    onChanged();
  }
}

/// A category: its names and the station its dishes cook at unless a dish says otherwise.
class CategoryEditor extends StatelessWidget {
  const CategoryEditor({super.key, required this.catalog, required this.categoryKey, required this.onChanged});

  final MenuCatalog catalog;
  final String categoryKey;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final category = catalog.get('category', categoryKey)!;
    final attached = catalog.attachmentsOf('category', categoryKey);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Category: ${nameOf(category)}', style: Theme.of(context).textTheme.headlineSmall),
        _names(
          category,
          onChanged,
          renamed: (locale, was, now) => renameCategorySections(catalog, categoryKey, locale, was, now),
        ),
        const SizedBox(height: 12),
        _dropdown<String?>(
          label: 'Its dishes cook at',
          value: category['station'] as String?,
          items: {null: 'No station', for (final s in catalog.stations()) s['code'] as String: nameOf(s)},
          onChanged: (v) {
            category['station'] = v;
            onChanged();
          },
        ),
        _heading(context, 'On the menus'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final m in catalog.menus())
              FilterChip(
                key: ValueKey('on-menu-${m['code']}'),
                label: Text(nameOf(m)),
                selected: catalog.categoryOn(categoryKey, m['code'] as String),
                onSelected: (on) {
                  if (on) {
                    putCategoryOnMenu(catalog, categoryKey, m['code'] as String);
                  } else {
                    takeCategoryOffMenu(catalog, categoryKey, m['code'] as String);
                  }
                  onChanged();
                },
              ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            'Each menu is a tab on the order screen. A category on two menus (the soft drinks, with the food and '
            'at the bar) sells the same dishes from both. Where a dish prints is its station, whatever menu it '
            'was ordered from.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        _heading(context, 'Option groups every dish here asks for'),
        Wrap(
          spacing: 8,
          children: [
            for (final a in attached)
              InputChip(
                label: Text(nameOf(catalog.get('group', a['group'] as String))),
                onDeleted: () {
                  catalog.delete('attachment', keyOf('attachment', a));
                  onChanged();
                },
              ),
          ],
        ),
      ],
    );
  }
}

/// An option group (choice of rice, spice level): its rules, the stations whose tickets list what is picked
/// in it, and its options with their prices.
class GroupEditor extends StatelessWidget {
  const GroupEditor({super.key, required this.catalog, required this.groupKey, required this.onChanged, this.stations});

  final MenuCatalog catalog;
  final String groupKey;
  final VoidCallback onChanged;

  /// The stations as the hub lists them, with the printer serving each; null when the hub did not say.
  final StationList? stations;

  @override
  Widget build(BuildContext context) {
    final group = catalog.get('group', groupKey)!;
    final options = catalog.optionsOf(groupKey);
    final source = group['source_category'] as String?;
    final sourceCategory = source == null ? null : catalog.get('category', source);
    final usedBy = catalog
        .all('attachment')
        .where((a) => a['group'] == groupKey)
        .map((a) => nameOf(catalog.get(a['owner_kind'] == 'item' ? 'item' : 'category', a['owner'] as String)))
        .toList();
    int? whole(String t) => t.trim().isEmpty ? null : int.tryParse(t.trim());
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(nameOf(group), style: Theme.of(context).textTheme.headlineSmall),
        if (usedBy.isNotEmpty) Text('Asked for by ${usedBy.join(', ')}'),
        _names(group, onChanged),
        const SizedBox(height: 12),
        Wrap(
          spacing: 16,
          children: [
            SizedBox(
              width: 140,
              child: _text('$groupKey/min', 'Pick at least', '${group['min_select'] ?? 0}', (t) {
                group['min_select'] = whole(t) ?? 0;
                onChanged();
              }, number: true),
            ),
            SizedBox(
              width: 140,
              child: _text('$groupKey/max', 'Pick at most', '${group['max_select'] ?? ''}', (t) {
                group['max_select'] = whole(t);
                onChanged();
              }, number: true),
            ),
            SizedBox(
              width: 140,
              child: _text('$groupKey/free', 'Free picks', '${group['free_count'] ?? 0}', (t) {
                group['free_count'] = whole(t) ?? 0;
                onChanged();
              }, number: true),
            ),
          ],
        ),
        SwitchListTile(
          key: ValueKey('$groupKey/quantity'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Several of the same option'),
          subtitle: const Text(
            'An option can go on a dish more than once (2x Chicken fingers on a platter). '
            'Each one counts toward the picks and is charged.',
          ),
          value: group['allow_quantity'] == true,
          onChanged: (v) {
            group['allow_quantity'] = v;
            onChanged();
          },
        ),
        const SizedBox(height: 12),
        _dropdown<String?>(
          label: 'Options come from',
          value: source,
          items: {
            null: 'Options typed here',
            for (final c in catalog.categories()) c['code'] as String: 'The dishes of ${nameOf(c)}',
          },
          onChanged: (v) {
            group['source_category'] = v;
            syncSourcedOptions(catalog, groupKey);
            onChanged();
          },
        ),
        if (sourceCategory != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'Every dish on sale in ${nameOf(sourceCategory)} is an option here, kept in step with the category '
              'each time the menu is saved. Options added by hand stay beside them.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        if (hubHidesGroups(catalog)) ...[
          _heading(context, 'On the tickets at'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final s in catalog.stations())
                FilterChip(
                  key: ValueKey('$groupKey/ticket:${s['code']}'),
                  label: Text(nameOf(s)),
                  // a tick says it at a glance: this station's ticket lists the group
                  showCheckmark: true,
                  selected: !hiddenAt(group).contains(s['code']),
                  onSelected: (shown) {
                    showOnTickets(catalog, groupKey, s['code'] as String, shown);
                    onChanged();
                  },
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              ticketsLine(catalog, groupKey),
              key: ValueKey('$groupKey/tickets-line'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
        if (catalog.pricesWords) ...[
          _heading(context, pricedWords.values.join(', ')),
          for (final word in pricedWords.keys)
            _FactorChips(
              id: groupKey,
              word: word,
              value: catalog.groupFactor(groupKey, word),
              location: catalog.locationFactor(word),
              onPicked: (factor) {
                catalog.setGroupFactor(groupKey, word, factor);
                onChanged();
              },
            ),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'On a choice picked here: ${wordsLine(catalog, groupKey)} $_wordsSmallPrint',
              key: ValueKey('$groupKey/words-line'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
        _heading(context, 'Options'),
        for (final o in options)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                if (o['linked_variant'] != null)
                  // a choice that is a dish is called what the dish is called; a rename follows
                  SizedBox(
                    width: 352,
                    child: InputDecorator(
                      decoration: InputDecoration(
                        labelText: sourceCategory != null ? 'Dish of ${nameOf(sourceCategory)}' : 'Dish',
                        isDense: true,
                        border: const OutlineInputBorder(),
                      ),
                      child: Text(
                        optionName(catalog, o),
                        key: ValueKey('${o['id']}/dish'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  )
                else ...[
                  SizedBox(width: 200, child: _text('${o['id']}/en', 'Option', nameOf(o), (t) => _setName(o, 'en', t))),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 140,
                    child: _text('${o['id']}/zh', '中文', (o['names'] as Map?)?['zh'] as String? ?? '', (t) {
                      _setName(o, 'zh', t);
                    }),
                  ),
                ],
                const SizedBox(width: 12),
                SizedBox(
                  width: 110,
                  child: _price('${o['id']}/price', o['price'] as String? ?? '0.00', (p) {
                    o['price'] = p;
                    onChanged();
                  }, label: 'Adds'),
                ),
                const SizedBox(width: 8),
                const Text('Default'),
                Checkbox(
                  value: o['is_default'] == true,
                  onChanged: (v) {
                    o['is_default'] = v == true;
                    onChanged();
                  },
                ),
                const Text('On sale'),
                Switch(
                  value: o['active'] != false,
                  onChanged: (v) {
                    o['active'] = v;
                    onChanged();
                  },
                ),
                IconButton(
                  key: ValueKey('${o['id']}/routes'),
                  tooltip: o['routes_to'] == null
                      ? 'Also print the dish at another station (take out, say)'
                      : 'Also prints the dish at ${_stationName(catalog, o['routes_to'] as String?)}',
                  icon: Icon(
                    o['routes_to'] == null ? Icons.print_outlined : Icons.print,
                    color: o['routes_to'] == null ? null : Theme.of(context).colorScheme.primary,
                  ),
                  onPressed: () async {
                    final picked = await showDialog<String>(
                      context: context,
                      builder: (_) => _RouteDialog(
                        option: optionName(catalog, o),
                        current: o['routes_to'] as String?,
                        stations: catalog.stations(),
                        served: stations,
                      ),
                    );
                    if (picked == null) return;
                    o['routes_to'] = picked == _nowhere ? null : picked;
                    onChanged();
                  },
                ),
                if (o['linked_variant'] == null)
                  IconButton(
                    key: ValueKey('${o['id']}/link'),
                    tooltip: 'Make this option a dish from the menu',
                    icon: const Icon(Icons.link),
                    onPressed: () async {
                      final variant = await showDialog<String>(
                        context: context,
                        builder: (_) => _SearchPickDialog(title: 'Which dish?', options: dishChoices(catalog)),
                      );
                      if (variant == null) return;
                      o['linked_variant'] = variant;
                      o['names'] = <String, dynamic>{}; // called what the dish is called
                      o['kitchen_label'] = null;
                      onChanged();
                    },
                  )
                else if (sourceCategory == null || o['linked_variant'] == null)
                  IconButton(
                    key: ValueKey('${o['id']}/unlink'),
                    tooltip: 'Make this option a word again',
                    icon: const Icon(Icons.link_off),
                    onPressed: () {
                      o['names'] = {'en': optionName(catalog, o)};
                      o['linked_variant'] = null;
                      onChanged();
                    },
                  ),
                // a dish the category put here comes back on save: only its own options can go
                if (sourceCategory == null || o['linked_variant'] == null)
                  IconButton(
                    tooltip: 'Remove this option',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () {
                      catalog.delete('option', o['id'] as String);
                      onChanged();
                    },
                  ),
              ],
            ),
          ),
        TextButton.icon(
          icon: const Icon(Icons.add),
          label: const Text('Add an option'),
          onPressed: () {
            final code = _uniqueCode(catalog, 'option', 'opt', prefix: '$groupKey:');
            catalog.put('option', {
              'id': '$groupKey:$code',
              'group': groupKey,
              'code': code,
              'names': {'en': 'New option'},
              'kitchen_label': null,
              'price_mode': 'delta',
              'price': '0.00',
              'is_default': false,
              'max_qty': null,
              'effects': <dynamic>[],
              'linked_variant': null,
              'child_groups': <String>[],
              'station': null,
              'routes_to': null,
              'sort': options.length,
              'active': true,
            });
            onChanged();
          },
        ),
      ],
    );
  }

  void _setName(Map<String, dynamic> row, String locale, String text) {
    final names = Map<String, dynamic>.from(row['names'] as Map? ?? const {});
    if (text.trim().isEmpty) {
      names.remove(locale);
    } else {
      names[locale] = text.trim();
    }
    row['names'] = names;
    // the kitchen reads the option's label; keep it with the English name unless someone set it apart
    if (locale == 'en' && row.containsKey('kitchen_label')) row['kitchen_label'] = names['en'];
    onChanged();
  }
}

// --- what the one-tap words charge ----------------------------------------------------------------------

const _wordsSmallPrint =
    'A free option stays free, "No" always costs nothing, and a choice that is a dish is charged once whatever '
    'the word.';

/// What Extra, On the side and Light charge on a choice, for the whole location: each as times the option's
/// own price. An option group can charge otherwise, on its own page.
class WordsEditor extends StatelessWidget {
  const WordsEditor({super.key, required this.catalog, required this.onChanged});

  final MenuCatalog catalog;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final apart = [
      for (final g in catalog.groups())
        if (g['word_factors'] != null) nameOf(g),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(pricedWords.values.join(', '), style: theme.textTheme.headlineSmall),
        const Text(
          'What a choice costs with one of these words on it, as times the option\'s own price. '
          'It holds for every option group that does not say otherwise.',
        ),
        const SizedBox(height: 16),
        for (final word in pricedWords.keys)
          _FactorChips(
            id: 'words',
            word: word,
            value: catalog.locationFactor(word),
            onPicked: (factor) {
              catalog.setLocationFactor(word, factor!);
              onChanged();
            },
          ),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(wordsLine(catalog), key: const ValueKey('words/line'), style: theme.textTheme.bodyMedium),
        ),
        const SizedBox(height: 8),
        Text(_wordsSmallPrint, style: theme.textTheme.bodySmall),
        if (apart.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'Charging otherwise, set on the group: ${_listed(apart)}.',
              key: const ValueKey('words/apart'),
              style: theme.textTheme.bodySmall,
            ),
          ),
      ],
    );
  }
}

/// The buttons for what one word charges. With [location] (on a group) a first button puts the group back on
/// the location's rule and says what that is.
class _FactorChips extends StatelessWidget {
  const _FactorChips({
    required this.id,
    required this.word,
    required this.value,
    required this.onPicked,
    this.location,
  });

  final String id; // what the keys start with: the group's key, or "words" for the location
  final String word;
  final double? value; // null on a group that follows the location
  final double? location;
  final ValueChanged<double?> onPicked;

  @override
  Widget build(BuildContext context) {
    final offered = {...factorChoices.keys, ?value}.toList()..sort();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SizedBox(width: 96, child: Text(pricedWords[word]!, style: Theme.of(context).textTheme.titleSmall)),
          if (location != null)
            ChoiceChip(
              key: ValueKey('$id/word:$word:location'),
              label: Text('As the location (${factorName(location!)})'),
              selected: value == null,
              onSelected: (_) => onPicked(null),
            ),
          for (final factor in offered)
            ChoiceChip(
              key: ValueKey('$id/word:$word:${factorText(factor)}'),
              label: Text(factorName(factor)),
              selected: value == factor,
              onSelected: (_) => onPicked(factor),
            ),
        ],
      ),
    );
  }
}

/// What the words charge in a sentence or two, at the location or on the choices of one group: "Extra charges
/// the option twice. On the side and Light charge the option once."
String wordsLine(MenuCatalog catalog, [String? groupKey]) {
  final byFactor = <double, List<String>>{};
  for (final e in pricedWords.entries) {
    final factor = groupKey == null ? catalog.locationFactor(e.key) : catalog.factorIn(groupKey, e.key);
    byFactor.putIfAbsent(factor, () => []).add(e.value);
  }
  return [for (final e in byFactor.entries) '${_listed(e.value)} ${_charges(e.key, e.value.length > 1)}.'].join(' ');
}

String _charges(double factor, bool several) {
  final verb = several ? 'charge' : 'charges';
  if (factor == 0) return several ? 'cost nothing' : 'costs nothing';
  if (factor == 0.5) return "$verb half the option's price";
  if (factor == 1) return '$verb the option once';
  if (factor == 1.5) return '$verb the option one and a half times';
  if (factor == 2) return '$verb the option twice';
  return '$verb ${factorText(factor)} times the option';
}

// --- stations -------------------------------------------------------------------------------------------

/// The value of "A new station…" in a station list; no station code can be it.
const _newStation = '\u0000new';

/// What the route dialog returns for "nowhere else"; no station code can be it.
const _nowhere = '\u0000nowhere';

String _stationName(MenuCatalog catalog, String? code) => code == null ? 'none' : nameOf(catalog.get('station', code));

/// One line under the station: whether a printer serves it, as the hub says; nothing when it did not.
String _printsAtLine(MenuCatalog catalog, String? station, StationList? stations) {
  if (station == null) return 'No station: this dish prints no kitchen ticket.';
  final name = _stationName(catalog, station);
  final info = stations?.byCode(station);
  if (stations == null) return 'Prints at $name.';
  if (info?.printer != null) return 'Prints on the $name printer.';
  return 'No printer for $name yet: it prints on the first printer in the list. '
      'Add one under Location settings › Printers.';
}

/// Whether the hub keeps, per option group, the stations whose tickets leave the group off: every group it
/// sent then carries `hidden_at`. An older hub refuses the field, so the editor does not offer it there.
bool hubHidesGroups(MenuCatalog catalog) => catalog.all('group').any((g) => g.containsKey('hidden_at'));

/// The stations whose tickets leave a group's picks off (`hidden_at`; none while nobody has said).
Set<String> hiddenAt(Map<String, dynamic>? group) => {
  for (final code in group?['hidden_at'] as List? ?? const []) code as String,
};

/// Puts a group's picks on a station's tickets, or takes them off. The list is kept in the stations' own
/// order; an empty one is a manager saying every station reads the group, which the hub's menu import then
/// leaves alone.
void showOnTickets(MenuCatalog catalog, String groupKey, String station, bool shown) {
  final group = catalog.get('group', groupKey)!;
  final hidden = hiddenAt(group);
  shown ? hidden.remove(station) : hidden.add(station);
  group['hidden_at'] = [
    for (final s in catalog.stations())
      if (hidden.contains(s['code'])) s['code'] as String,
  ];
}

/// One line under the stations: which tickets list what is picked in the group, and what the others print.
String ticketsLine(MenuCatalog catalog, String groupKey) {
  final hidden = hiddenAt(catalog.get('group', groupKey));
  final stations = catalog.stations();
  final off = [
    for (final s in stations)
      if (hidden.contains(s['code'])) nameOf(s),
  ];
  final on = [
    for (final s in stations)
      if (!hidden.contains(s['code'])) nameOf(s),
  ];
  if (off.isEmpty) return 'Every station\'s ticket lists what is picked here, under the dish.';
  // a soup picked with a dish is a dish of its own: the soup station still gets it
  final dish = catalog.optionsOf(groupKey).any((o) => o['linked_variant'] != null)
      ? ' A pick that is a dish still prints at its own station.'
      : '';
  if (on.isEmpty) {
    return 'No station\'s ticket lists what is picked here: the dish prints without it. '
        'The check still shows it.$dish';
  }
  if (off.length <= on.length) {
    return 'Left off the tickets at ${_listed(off)}: the dish prints there without what is picked here. '
        'The check and the other stations still show it.$dish';
  }
  return 'Only the tickets at ${_listed(on)} list what is picked here: the dish prints at the other stations '
      'without it. The check still shows it.$dish';
}

/// "Wok 1", "Wok 1 and Wok 2", "Wok 1, Wok 2 and Fryer".
String _listed(List<String> names) =>
    names.length < 2 ? names.join() : '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';

/// Asks for a new station's name and adds it to the menu; its code, or null when nothing was typed.
Future<String?> newStation(BuildContext context, MenuCatalog catalog) async {
  final name = await showDialog<String>(
    context: context,
    builder: (_) => const _TextDialog(title: 'New station', label: 'Name, e.g. "Dessert"'),
  );
  if (name == null || name.trim().isEmpty) return null;
  final code = _uniqueCode(catalog, 'station', _slug(name.trim()));
  catalog.put('station', {
    'code': code,
    'names': {'en': name.trim()},
    'printers': <String>[],
    'cross_contact': <String>[],
  });
  return code;
}

/// Where a choice sends the dish as well: "nowhere else", or one of the stations, each saying whether a
/// printer serves it.
class _RouteDialog extends StatelessWidget {
  const _RouteDialog({required this.option, required this.current, required this.stations, this.served});

  final String option;
  final String? current;
  final List<Map<String, dynamic>> stations;
  final StationList? served;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SimpleDialog(
      title: Text('"$option" also prints the dish at'),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
          child: Text(
            'The dish, with its choices, prints at that station as well as its own: "Take out" sends it to the '
            'takeout counter to be bagged.',
            style: theme.textTheme.bodySmall,
          ),
        ),
        ListTile(
          key: const ValueKey('route:nowhere'),
          leading: Icon(current == null ? Icons.radio_button_checked : Icons.radio_button_off),
          title: const Text('Nowhere else'),
          onTap: () => Navigator.of(context).pop(_nowhere),
        ),
        for (final s in stations)
          ListTile(
            key: ValueKey('route:${s['code']}'),
            leading: Icon(current == s['code'] ? Icons.radio_button_checked : Icons.radio_button_off),
            title: Text(nameOf(s)),
            subtitle: switch (served?.byCode(s['code'] as String)) {
              null => null,
              final info => Text(info.printer == null ? 'no printer yet' : 'has a printer'),
            },
            onTap: () => Navigator.of(context).pop(s['code'] as String),
          ),
      ],
    );
  }
}

// --- building blocks ------------------------------------------------------------------------------------

/// English, Chinese and (for dishes) kitchen-ticket names. [renamed] hears each change: the language, the
/// name it had and the name it has now.
Widget _names(
  Map<String, dynamic> row,
  VoidCallback onChanged, {
  bool kitchen = false,
  void Function(String locale, String? was, String? now)? renamed,
}) {
  final id = row['id'] ?? row['code'];
  void set(String locale, String text) {
    final names = Map<String, dynamic>.from(row['names'] as Map? ?? const {});
    final was = names[locale] as String?;
    if (text.trim().isEmpty) {
      names.remove(locale);
    } else {
      names[locale] = text.trim();
    }
    row['names'] = names;
    renamed?.call(locale, was, names[locale] as String?);
    onChanged();
  }

  final names = (row['names'] as Map?)?.cast<String, dynamic>() ?? const {};
  return Padding(
    padding: const EdgeInsets.only(top: 12),
    child: Wrap(
      spacing: 16,
      runSpacing: 12,
      children: [
        SizedBox(width: 280, child: _text('$id/en', 'English name', names['en'] as String? ?? '', (t) => set('en', t))),
        SizedBox(width: 220, child: _text('$id/zh', '中文名', names['zh'] as String? ?? '', (t) => set('zh', t))),
        if (kitchen)
          SizedBox(
            width: 220,
            child: _text(
              '$id/kitchen',
              'On the kitchen ticket',
              names['kitchen'] as String? ?? '',
              (t) => set('kitchen', t),
              hint: 'same as the name',
            ),
          ),
      ],
    ),
  );
}

/// Whether a dish's price is typed when it is rung (`attrs.asks_price`; a dish that asks its name asks its
/// price as well), and whether its name is typed too (`attrs.asks_name`: an off-menu dish).
bool asksPrice(Map<String, dynamic> item) => _attrs(item)['asks_price'] == true || asksName(item);
bool asksName(Map<String, dynamic> item) => _attrs(item)['asks_name'] == true;

Map<String, dynamic> _attrs(Map<String, dynamic> item) => (item['attrs'] as Map?)?.cast<String, dynamic>() ?? const {};

/// Sets what a dish asks to be typed, leaving the rest of its `attrs` as they are. A dish that asks nothing
/// carries neither key, as before there was anything to ask.
void setAsks(Map<String, dynamic> item, {required bool price, required bool name}) {
  item['attrs'] = <String, dynamic>{
    for (final e in _attrs(item).entries)
      if (e.key != 'asks_price' && e.key != 'asks_name') e.key: e.value,
    if (price || name) 'asks_price': true,
    if (name) 'asks_name': true,
  };
}

/// How many dishes one dish can suggest (the hub's `GOES_WITH_MOST`): two rows of tiles on a phone.
const goesWithMost = 4;

/// The dishes a dish goes with (`attrs.goes_with`: item codes, in the order the order screen shows them once
/// the dish is rung; docs/goes-with.md). Only dishes the catalog still has, never the dish itself and none
/// twice, and no more than [goesWithMost]: what the hub would make of the list.
List<String> goesWith(MenuCatalog catalog, Map<String, dynamic> item) {
  final named = _attrs(item)['goes_with'];
  if (named is! List) return const [];
  final out = <String>[];
  for (final code in named) {
    if (code is! String || code == item['code'] || out.contains(code)) continue;
    if (catalog.get('item', code) != null) out.add(code);
  }
  return out.length > goesWithMost ? out.sublist(0, goesWithMost) : out;
}

/// Sets the dishes a dish goes with, leaving the rest of its `attrs` as they are. A dish that goes with
/// nothing carries no key, as before there was anything to go with.
void setGoesWith(Map<String, dynamic> item, List<String> codes) {
  item['attrs'] = <String, dynamic>{
    for (final e in _attrs(item).entries)
      if (e.key != 'goes_with') e.key: e.value,
    if (codes.isNotEmpty) 'goes_with': [...codes],
  };
}

/// Every dish by its code, for picking a whole dish and not one of its sizes: "Name · Category", in the
/// catalog's order, without [except].
Map<String, String> wholeDishes(MenuCatalog catalog, {Set<String> except = const {}}) => {
  for (final category in catalog.categories())
    for (final item in catalog.itemsIn(category['code'] as String))
      if (!except.contains(item['code'])) item['code'] as String: '${nameOf(item)} · ${nameOf(category)}',
};

Widget _heading(BuildContext context, String text) {
  final theme = Theme.of(context);
  return Padding(
    padding: const EdgeInsets.only(top: 28, bottom: 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(text, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        const Divider(height: 1),
      ],
    ),
  );
}

Widget _text(
  String key,
  String label,
  String value,
  ValueChanged<String> onChanged, {
  bool number = false,
  String? hint,
}) => TextFormField(
  key: ValueKey(key),
  initialValue: value,
  decoration: InputDecoration(labelText: label, hintText: hint, isDense: true, border: const OutlineInputBorder()),
  keyboardType: number ? TextInputType.number : TextInputType.text,
  onChanged: onChanged,
);

final _money = RegExp(r'^\d+(\.\d{0,2})?$');

/// A price box: a change is kept only while the text is a price, and is kept as dollars and cents.
Widget _price(String key, String value, ValueChanged<String> onChanged, {String label = 'Price'}) => TextFormField(
  key: ValueKey(key),
  initialValue: value,
  decoration: InputDecoration(labelText: label, prefixText: '\$', isDense: true, border: const OutlineInputBorder()),
  keyboardType: const TextInputType.numberWithOptions(decimal: true),
  autovalidateMode: AutovalidateMode.onUserInteraction,
  validator: (t) => _money.hasMatch((t ?? '').trim()) ? null : 'Not a price',
  onChanged: (t) {
    if (_money.hasMatch(t.trim())) onChanged(normalizePrice(t.trim()));
  },
);

/// "8.5" -> "8.50", "12" -> "12.00".
String normalizePrice(String text) {
  final parts = text.split('.');
  final cents = parts.length > 1 ? parts[1].padRight(2, '0') : '00';
  return '${int.parse(parts[0])}.$cents';
}

Widget _dropdown<T>({
  required String label,
  required T value,
  required Map<T, String> items,
  required ValueChanged<T> onChanged,
}) => SizedBox(
  width: 280,
  child: DropdownButtonFormField<T>(
    initialValue: items.containsKey(value) ? value : null,
    isExpanded: true,
    decoration: InputDecoration(labelText: label, isDense: true, border: const OutlineInputBorder()),
    items: [
      for (final e in items.entries)
        DropdownMenuItem<T>(
          value: e.key,
          child: Text(e.value, overflow: TextOverflow.ellipsis),
        ),
    ],
    onChanged: (v) => onChanged(v as T),
  ),
);

// --- what a change takes with it ------------------------------------------------------------------------

Map<String, dynamic> newVariant(String item, String code, String name, String price, int sort) => {
  'id': '$item:$code',
  'item': item,
  'code': code,
  'names': {'en': name},
  'base_price': price,
  'recipe_scale': '1',
  'component_overrides': <dynamic>[],
  'plu': null,
  'sort': sort,
  'active': true,
};

Map<String, dynamic> newEntry(MenuCatalog catalog, String item, Map<String, dynamic> section, String number) {
  final menu = section['menu'] as String;
  var id = '$menu:${number.isNotEmpty ? number : item}';
  for (var n = 2; catalog.get('entry', id) != null; n++) {
    id = '$menu:${number.isNotEmpty ? number : item}-$n';
  }
  return {
    'id': id,
    'menu': menu,
    'section': section['id'],
    'item': item,
    'number': number.isEmpty ? null : number,
    'variants': null,
    'price_overrides': <String, dynamic>{},
    'availability': <String, dynamic>{},
    'visible': true,
    'featured': false,
    'display': <String, dynamic>{},
    'sort': catalog.all('entry').where((e) => e['section'] == section['id']).length,
  };
}

/// A category's new name goes onto its section of every menu it is on, because the order screen names a
/// category's tile from the section (docs/dish-names.md). A section that was given a name of its own keeps it.
void renameCategorySections(MenuCatalog catalog, String categoryKey, String locale, String? was, String? now) {
  for (final section in catalog.all('section').where((s) => s['id'] == '${s['menu']}/$categoryKey')) {
    final names = Map<String, dynamic>.from(section['names'] as Map? ?? const {});
    final has = names[locale] as String?;
    if (has != null && has != was) continue;
    if (now == null) {
      names.remove(locale);
    } else {
      names[locale] = now;
    }
    section['names'] = names;
  }
}

/// Puts a category on a menu, as the import does: a section `menu/category` named like the category, under
/// the category's parent when that is on the menu too, and an entry for each of its dishes. A dish already on
/// another menu brings its number, the sizes it offers there and whether it shows, so the two menus agree.
void putCategoryOnMenu(MenuCatalog catalog, String categoryKey, String menu) {
  if (catalog.categoryOn(categoryKey, menu)) return;
  final category = catalog.get('category', categoryKey)!;
  final elsewhere = catalog.all('section').where((s) => s['id'] == '${s['menu']}/$categoryKey').firstOrNull;
  final parent = category['parent'] as String?;
  final sectionId = '$menu/$categoryKey';
  catalog.put('section', {
    'id': sectionId,
    'menu': menu,
    'names': copyRow((elsewhere?['names'] ?? category['names']) as Map<String, dynamic>),
    'parent': parent != null && catalog.categoryOn(parent, menu) ? '$menu/$parent' : null,
    'display': copyRow((elsewhere?['display'] as Map<String, dynamic>?) ?? const {}),
    'sort': (elsewhere?['sort'] ?? category['sort'] ?? 0) as int,
  });
  for (final item in catalog.itemsIn(categoryKey)) {
    final code = item['code'] as String;
    final others = catalog.entriesOf(code);
    final other =
        others.where((e) => (e['section'] as String).endsWith('/$categoryKey')).firstOrNull ?? others.firstOrNull;
    var id = '$menu:$code';
    for (var n = 2; catalog.get('entry', id) != null; n++) {
      id = '$menu:$code-$n';
    }
    catalog.put('entry', {
      'id': id,
      'menu': menu,
      'section': sectionId,
      'item': code,
      'number': other?['number'],
      'variants': other?['variants'] == null ? null : List<dynamic>.from(other!['variants'] as List),
      'price_overrides': <String, dynamic>{},
      'availability': <String, dynamic>{},
      'visible': other?['visible'] ?? true,
      'featured': false,
      'display': <String, dynamic>{},
      'sort': (other?['sort'] ?? item['sort'] ?? 0) as int,
    });
  }
}

/// Takes a category off a menu: its section there goes, with every entry in it. The dishes stay in the catalog
/// and on the other menus; a dish on no menu at all cannot be ordered until it is put back on one.
void takeCategoryOffMenu(MenuCatalog catalog, String categoryKey, String menu) {
  final sectionId = '$menu/$categoryKey';
  for (final e in catalog.all('entry').where((e) => e['section'] == sectionId).toList()) {
    catalog.delete('entry', e['id'] as String);
  }
  for (final s in catalog.all('section').where((s) => s['parent'] == sectionId).toList()) {
    takeCategoryOffMenu(catalog, (s['id'] as String).substring(menu.length + 1), menu);
  }
  catalog.delete('section', sectionId);
}

/// A size goes, and with it the menu entries' mentions of it.
void removeVariant(MenuCatalog catalog, String variantId) {
  catalog.delete('variant', variantId);
  for (final e in catalog.all('entry')) {
    final offered = e['variants'] as List?;
    if (offered != null && offered.contains(variantId)) e['variants'] = [...offered.where((v) => v != variantId)];
    final overrides = e['price_overrides'] as Map?;
    if (overrides != null && overrides.containsKey(variantId)) {
      e['price_overrides'] = Map<String, dynamic>.from(overrides)..remove(variantId);
    }
  }
}

/// A dish goes with its sizes, its places on the menus and its own option groups, and no other dish goes on
/// suggesting it ([goesWith]). The backend refuses the save if something else still needs it (a combo that
/// offers it), and says what.
void removeItem(MenuCatalog catalog, String itemKey) {
  for (final other in catalog.all('item')) {
    final named = _attrs(other)['goes_with'];
    if (named is List && named.contains(itemKey)) {
      setGoesWith(other, [
        for (final code in named)
          if (code is String && code != itemKey) code,
      ]);
    }
  }
  for (final v in catalog.variantsOf(itemKey)) {
    catalog.delete('variant', v['id'] as String);
  }
  for (final e in catalog.entriesOf(itemKey)) {
    catalog.delete('entry', e['id'] as String);
  }
  for (final a in catalog.attachmentsOf('item', itemKey)) {
    catalog.delete('attachment', keyOf('attachment', a));
  }
  catalog.delete('item', itemKey);
}

/// The pick that stands for "a new group from a category" in the add-a-group dialog.
const _fromCategory = '__from_category__';

/// A new group that offers the dishes of a category (the Roll category for the maki combination): named like
/// the category, one pick, its options from the category. The dish's editor sets how many picks after.
String newSourcedGroup(MenuCatalog catalog, String categoryKey) {
  final category = catalog.get('category', categoryKey)!;
  final code = _uniqueCode(catalog, 'group', _slug(nameOf(category)));
  catalog.put('group', {
    'code': code,
    'names': Map<String, dynamic>.from(category['names'] as Map? ?? {'en': categoryKey}),
    'min_select': 1,
    'max_select': 1,
    'free_count': 0,
    'allow_quantity': false,
    'allow_duplicates': false,
    'display': 'inline',
    'source_category': categoryKey,
    'sort': catalog.groups().length,
  });
  syncSourcedOptions(catalog, code);
  return code;
}

/// Gives a group whose options come from a category (`source_category`) the options the category's dishes
/// call for, as the hub does on every save (pos.menu.linked.sync): one option per dish on sale in the category
/// or the categories under it, one per size when a dish has several, each linked to the dish and named after
/// it. Options linked to a dish no longer there go; options typed by hand, and the prices and defaults set on
/// the ones kept, stay. Returns what changed, as text.
List<String> syncSourcedOptions(MenuCatalog catalog, String groupKey) {
  final group = catalog.get('group', groupKey);
  final category = group?['source_category'] as String?;
  if (group == null || category == null || catalog.get('category', category) == null) return const [];
  final wanted = <String, Map<String, dynamic>>{};
  for (final item in catalog.itemsUnder(category)) {
    if (item['active'] == false) continue;
    final itemCode = item['code'] as String;
    final sizes = catalog.variantsOf(itemCode).where((v) => v['active'] != false).toList();
    for (final (n, v) in sizes.indexed) {
      final code = sizes.length > 1 ? '$itemCode-${v['code']}' : itemCode;
      wanted['$groupKey:$code'] = {
        'id': '$groupKey:$code',
        'group': groupKey,
        'code': code,
        'names': <String, dynamic>{},
        'kitchen_label': null,
        'price_mode': 'delta',
        'price': '0.00',
        'is_default': false,
        'max_qty': null,
        'effects': <dynamic>[],
        'linked_variant': v['id'],
        'child_groups': <String>[],
        'station': null,
        'routes_to': null,
        'sort': ((item['sort'] as int?) ?? 0) * 10 + n,
        'active': true,
      };
    }
  }
  final changed = <String>[];
  for (final o in catalog.optionsOf(groupKey)) {
    final id = o['id'] as String;
    final fresh = wanted.remove(id);
    if (fresh != null) {
      o['linked_variant'] = fresh['linked_variant'];
      o['sort'] = fresh['sort'];
    } else if (o['linked_variant'] != null) {
      catalog.delete('option', id);
      changed.add('removed $id');
    }
  }
  for (final fresh in wanted.values) {
    catalog.put('option', fresh);
    changed.add('added ${fresh['id']}');
  }
  return changed;
}

/// What an option is called: its own name, or, for an option that is a dish, the dish's name, with the size
/// when the dish has several (as the hub shows it, pos.menu.defs.Definitions.option_names).
String optionName(MenuCatalog catalog, Map<String, dynamic> option, [String locale = 'en']) {
  final names = (option['names'] as Map?)?.cast<String, dynamic>() ?? const {};
  final linked = option['linked_variant'] as String?;
  final variant = linked == null ? null : catalog.get('variant', linked);
  if (variant == null || names.entries.any((e) => e.key != 'kitchen' && '${e.value}'.isNotEmpty)) {
    return nameOf(option, locale);
  }
  final dish = nameOf(catalog.get('item', variant['item'] as String), locale);
  return catalog.variantsOf(variant['item'] as String).length > 1 ? '$dish (${nameOf(variant, locale)})' : dish;
}

/// Every size of every dish, by variant id, for the dish picker: "Miso Soup", "Sweet & Sour Sauce (Medium)".
Map<String, String> dishChoices(MenuCatalog catalog) {
  final out = <String, String>{};
  for (final category in catalog.categories()) {
    for (final item in catalog.itemsIn(category['code'] as String)) {
      final sizes = catalog.variantsOf(item['code'] as String);
      for (final v in sizes) {
        final name = sizes.length > 1 ? '${nameOf(item)} (${nameOf(v)})' : nameOf(item);
        out[v['id'] as String] = '$name · ${nameOf(category)}';
      }
    }
  }
  return out;
}

String _uniqueCode(MenuCatalog catalog, String kind, String base, {String prefix = ''}) {
  final clean = base.isEmpty ? kind : base;
  if (catalog.get(kind, '$prefix$clean') == null) return clean;
  for (var n = 2; ; n++) {
    if (catalog.get(kind, '$prefix$clean$n') == null) return '$clean$n';
  }
}

String _slug(String name) => name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_').replaceAll(RegExp(r'^_|_$'), '');

// --- dialogs --------------------------------------------------------------------------------------------

/// A PIN for a session token (`/admin/session`): the menu editor, the quote times, Location. A manager's
/// or an owner's always; anyone else's when the location handed their role the [power] the session is for
/// (docs/roles.md). The hub decides; the box only says whose PIN it takes.
class ManagerPinDialog extends StatefulWidget {
  const ManagerPinDialog({
    super.key,
    required this.api,
    required this.device,
    this.action = 'Open the editor',
    this.what = 'edit the menu',
    this.power = 'menu',
    this.onPowers,
  });
  final PosApi api;
  final String device;
  final String action; // the button
  final String what; // "Only a manager can <what>"

  /// What the session is opened for: the hub refuses a PIN whose owner may not do it. Null for Location,
  /// which opens for anyone with something to do there.
  final String? power;

  /// Told what the PIN's owner may do, as the hub answered, before the box closes with the token; null from
  /// a hub older than the table, where only a manager gets a token.
  final ValueChanged<Set<String>?>? onPowers;

  @override
  State<ManagerPinDialog> createState() => _ManagerPinDialogState();
}

class _ManagerPinDialogState extends State<ManagerPinDialog> {
  final _pin = TextEditingController();
  String? _message;
  bool _busy = false;

  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy || _pin.text.isEmpty) return;
    setState(() => _busy = true);
    try {
      final json = await widget.api.adminSession(device: widget.device, pin: _pin.text, power: widget.power);
      final holds = json['powers'] as List?;
      widget.onPowers?.call(holds == null ? null : {...holds.cast<String>()});
      if (mounted) Navigator.of(context).pop(json['token'] as String);
    } on ApiException catch (err) {
      if (!mounted) return;
      final power = widget.power;
      final powers = widget.api.powers.value;
      setState(() {
        _busy = false;
        _pin.clear();
        _message = switch (err.status) {
          401 => 'Wrong PIN',
          403 when power == null && powers.pinTitle(null) == 'PIN' => 'Nothing under Location is open to this PIN',
          403 => 'Only ${power == null ? 'a manager' : powers.whose(power)} can ${widget.what}',
          423 => 'Too many tries. Wait a minute.',
          _ => err.message,
        };
      });
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.api.powers.value.pinTitle(widget.power)),
    content: SizedBox(
      width: 280,
      child: TextField(
        controller: _pin,
        autofocus: true,
        obscureText: true,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(labelText: 'PIN', errorText: _message, errorMaxLines: 3),
        onSubmitted: (_) => _submit(),
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
      FilledButton(onPressed: _busy ? null : _submit, child: Text(widget.action)),
    ],
  );
}

class _NewDish {
  const _NewDish(this.name, this.chinese, this.category, this.price, this.section, this.number);
  final String name;
  final String chinese;
  final String category;
  final String price;
  final String section;
  final String number;
}

class _NewDishDialog extends StatefulWidget {
  const _NewDishDialog({required this.catalog});
  final MenuCatalog catalog;

  @override
  State<_NewDishDialog> createState() => _NewDishDialogState();
}

class _NewDishDialogState extends State<_NewDishDialog> {
  final _name = TextEditingController();
  final _chinese = TextEditingController();
  final _price = TextEditingController();
  final _number = TextEditingController();
  late String? _category = widget.catalog.categories().firstOrNull?['code'] as String?;
  late String? _section = widget.catalog.sections().firstOrNull?['id'] as String?;

  @override
  void dispose() {
    for (final c in [_name, _chinese, _price, _number]) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _ok =>
      _name.text.trim().isNotEmpty && _money.hasMatch(_price.text.trim()) && _category != null && _section != null;

  @override
  Widget build(BuildContext context) {
    final catalog = widget.catalog;
    return AlertDialog(
      title: const Text('New dish'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'English name'),
              onChanged: (_) => setState(() {}),
            ),
            TextField(
              controller: _chinese,
              decoration: const InputDecoration(labelText: '中文名 (optional)'),
            ),
            TextField(
              controller: _price,
              decoration: const InputDecoration(labelText: 'Price', prefixText: '\$'),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              onChanged: (_) => setState(() {}),
            ),
            TextField(
              controller: _number,
              decoration: const InputDecoration(labelText: 'Menu number (optional)'),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _category,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Category'),
              items: [
                for (final c in catalog.categories())
                  DropdownMenuItem(value: c['code'] as String, child: Text(nameOf(c))),
              ],
              onChanged: (v) => setState(() => _category = v),
            ),
            DropdownButtonFormField<String>(
              initialValue: _section,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'On the menu at'),
              items: [
                for (final s in catalog.sections())
                  DropdownMenuItem(
                    value: s['id'] as String,
                    child: Text('${nameOf(catalog.get('menu', s['menu'] as String))} › ${nameOf(s)}'),
                  ),
              ],
              onChanged: (v) => setState(() => _section = v),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          onPressed: _ok
              ? () => Navigator.of(context).pop(
                  _NewDish(
                    _name.text.trim(),
                    _chinese.text.trim(),
                    _category!,
                    normalizePrice(_price.text.trim()),
                    _section!,
                    _number.text.trim(),
                  ),
                )
              : null,
          child: const Text('Add'),
        ),
      ],
    );
  }
}

class _TextDialog extends StatefulWidget {
  const _TextDialog({required this.title, required this.label});
  final String title;
  final String label;

  @override
  State<_TextDialog> createState() => _TextDialogState();
}

class _TextDialogState extends State<_TextDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: TextField(
      controller: _controller,
      autofocus: true,
      decoration: InputDecoration(labelText: widget.label),
      onSubmitted: (v) => Navigator.of(context).pop(v.trim()),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
      FilledButton(onPressed: () => Navigator.of(context).pop(_controller.text.trim()), child: const Text('Add')),
    ],
  );
}

class _PickDialog extends StatelessWidget {
  const _PickDialog({required this.title, required this.options});
  final String title;
  final Map<String, String> options;

  @override
  Widget build(BuildContext context) => SimpleDialog(
    title: Text(title),
    children: [
      for (final e in options.entries)
        SimpleDialogOption(onPressed: () => Navigator.of(context).pop(e.key), child: Text(e.value)),
    ],
  );
}

/// A pick from a long list (every dish on the menu), narrowed by typing.
class _SearchPickDialog extends StatefulWidget {
  const _SearchPickDialog({required this.title, required this.options});
  final String title;
  final Map<String, String> options;

  @override
  State<_SearchPickDialog> createState() => _SearchPickDialogState();
}

class _SearchPickDialogState extends State<_SearchPickDialog> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final q = _query.toLowerCase();
    final shown = [
      for (final e in widget.options.entries)
        if (q.isEmpty || e.value.toLowerCase().contains(q) || e.key.toLowerCase().contains(q)) e,
    ];
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 420,
        height: 440,
        child: Column(
          children: [
            TextField(
              key: const ValueKey('dish-search'),
              autofocus: true,
              decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search', isDense: true),
              onChanged: (v) => setState(() => _query = v),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                itemCount: shown.length,
                itemBuilder: (context, i) => ListTile(
                  dense: true,
                  title: Text(shown[i].value),
                  onTap: () => Navigator.of(context).pop(shown[i].key),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel'))],
    );
  }
}

class _AuditTile extends StatelessWidget {
  const _AuditTile({required this.change});
  final Map<String, dynamic> change;

  @override
  Widget build(BuildContext context) {
    final before = (change['before'] as Map?)?.cast<String, dynamic>();
    final after = (change['after'] as Map?)?.cast<String, dynamic>();
    final row = after ?? before ?? const {};
    final what = '${change['table_name']} ${row['code'] ?? row['names']?['en'] ?? ''}'.trim();
    final diffs = [
      if (before != null && after != null)
        for (final k in after.keys)
          if ('${before[k]}' != '${after[k]}' && k != 'id') '$k: ${before[k]} → ${after[k]}',
    ];
    return ListTile(
      dense: true,
      leading: Icon(switch (change['action']) {
        'insert' => Icons.add_circle_outline,
        'delete' => Icons.remove_circle_outline,
        _ => Icons.edit_outlined,
      }),
      title: Text('${change['actor'] ?? 'someone'} · ${change['action']} $what'),
      subtitle: Text([if (diffs.isNotEmpty) diffs.join('; '), '${change['at'] ?? ''}'].join('\n')),
    );
  }
}
