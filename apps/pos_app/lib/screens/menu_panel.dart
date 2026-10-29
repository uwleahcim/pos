import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../menu.dart';
import 'drill_down.dart';

/// A line the operator configured: what to send in `add_line`.
class ChosenLine {
  const ChosenLine({
    required this.name,
    required this.request,
    this.qty = 1,
    this.note = '',
    this.unitPrice,
    this.modifiers = const [],
    this.itemId,
  });
  final String name;
  final LineRequest request;
  final int qty;
  final String note;

  /// The price of one as the menu showed it, so the check can show the line before the hub prices it.
  final String? unitPrice;
  final List<String> modifiers;
  final String? itemId;
}

/// How often a menu on screen asks whether it changed, and how long one read is kept at most: lunch ends
/// and dinner starts without anyone saving anything.
abstract final class MenuPanelCheck {
  static const every = Duration(seconds: 5);
  static const reload = Duration(minutes: 5);
}

/// The menu as buttons. It opens on its categories; a category opens its dishes and shrinks the categories
/// to a strip on top, and pulling down at the top of the dishes goes back (see [DrillDown]). A category with
/// subcategories opens the same way, one level at a time. A dish with nothing to ask is added with one tap;
/// anything else opens [ItemSheet]. The search box on the categories finds dishes in all of them.
class MenuPanel extends StatefulWidget {
  const MenuPanel({super.key, required this.api, required this.onChosen});

  final PosApi api;
  final ValueChanged<ChosenLine> onChosen;

  @override
  State<MenuPanel> createState() => _MenuPanelState();
}

class _MenuPanelState extends State<MenuPanel> {
  List<Menu>? _menus;
  String? _error;
  var _path = <String>[]; // the open categories, outermost first, by section id
  final _origins = <String, Alignment>{}; // open path -> where the button that opened it sits
  int? _revision;
  DateTime _loadedAt = DateTime(0);
  Timer? _watch;
  final _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
    _watch = Timer.periodic(MenuPanelCheck.every, (_) => _check());
  }

  @override
  void dispose() {
    _watch?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final (revision, menus) = await widget.api.menus();
      if (mounted) {
        setState(() {
          _menus = menus;
          _revision = revision;
          _loadedAt = DateTime.now();
          _error = null;
        });
      }
    } on ApiException catch (err) {
      if (mounted) setState(() => _error = err.toString());
    }
  }

  /// A manager saved the menu (or the hour changed the menus open): read it again, keeping the open category.
  Future<void> _check() async {
    if (_menus == null) return _load();
    if (DateTime.now().difference(_loadedAt) >= MenuPanelCheck.reload) return _load();
    try {
      if (await widget.api.menuRevision() != _revision) await _load();
    } on ApiException {
      // offline: keep showing the menu already here; the status icon says why
    }
  }

  List<MenuSection> get _sections => [for (final m in _menus ?? const <Menu>[]) ...m.sections];

  /// The open categories, as far as the menu still has them: a category a manager removed closes.
  List<MenuSection> get _open {
    final open = <MenuSection>[];
    var level = _sections;
    for (final id in _path) {
      final s = level.where((s) => s.sectionId == id).firstOrNull;
      if (s == null) break;
      open.add(s);
      level = s.sections;
    }
    return open;
  }

  List<MenuEntry> get _found {
    final q = _search.text.trim().toLowerCase();
    return [
      for (final s in _sections)
        for (final e in s.allEntries)
          if (e.number?.toLowerCase() == q ||
              e.name.toLowerCase().contains(q) ||
              (e.secondName ?? '').toLowerCase().contains(q))
            e,
    ];
  }

  /// Opens `section` at `depth`; its dishes grow out of `tile`, the button that opened them.
  void _openAt(int depth, MenuSection section, BuildContext tile) => setState(() {
    _path = [..._path.take(depth), section.sectionId];
    _origins[_path.join('/')] = _originOf(tile);
    _search.clear();
  });

  /// Where `tile` sits in the panel, as the point a level grows out of and shrinks back into.
  Alignment _originOf(BuildContext tile) {
    final box = tile.findRenderObject() as RenderBox?;
    final panel = context.findRenderObject() as RenderBox?;
    if (box == null || panel == null || !box.hasSize || !panel.hasSize || panel.size.isEmpty) {
      return Alignment.topCenter;
    }
    final c = panel.globalToLocal(box.localToGlobal(box.size.center(Offset.zero)));
    return Alignment(c.dx / panel.size.width * 2 - 1, c.dy / panel.size.height * 2 - 1);
  }

  /// A level opening grows out of the button that opened it and fades in; closing, it shrinks back into
  /// it. The categories under it just fade.
  Widget _transition(Widget child, Animation<double> animation) {
    final level = (child.key as ValueKey<String>?)?.value ?? '';
    final faded = FadeTransition(opacity: animation, child: child);
    if (level.isEmpty) return faded;
    return ScaleTransition(
      scale: Tween(begin: 0.8, end: 1.0).animate(animation),
      alignment: _origins[level] ?? Alignment.topCenter,
      child: faded,
    );
  }

  void _close() => setState(() => _path = _path.take(_open.length - 1).toList());

  /// The 86 board from the order screen: long-press a dish to mark a size sold out or back.
  Future<void> _eightySix(MenuEntry entry) async {
    await showDialog<void>(
      context: context,
      builder: (context) => _EightySixDialog(api: widget.api, entry: entry),
    );
    await _load();
  }

  Future<void> _tap(MenuEntry entry) async {
    if (!entry.available) return;
    if (entry.quickAdd) {
      widget.onChosen(
        ChosenLine(
          name: entry.name,
          request: LineRequest(variantId: entry.variants.first.variantId, entryId: entry.entryId),
          unitPrice: entry.variants.first.price,
          itemId: entry.item,
        ),
      );
      return;
    }
    final chosen = await showDialog<ChosenLine>(
      context: context,
      builder: (_) => ItemSheet(api: widget.api, entry: entry),
    );
    if (chosen != null) widget.onChosen(chosen);
  }

  Widget _grid({required List<MenuSection> sections, required List<MenuEntry> entries, required int depth}) =>
      GridView.extent(
        maxCrossAxisExtent: 180,
        childAspectRatio: 1.35,
        padding: const EdgeInsets.all(8),
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        physics: DrillDown.physics,
        children: [
          for (final s in sections) _SectionButton(section: s, onTap: (tile) => _openAt(depth, s, tile)),
          for (final e in entries) _EntryButton(entry: e, onTap: () => _tap(e), onLongPress: () => _eightySix(e)),
        ],
      );

  @override
  Widget build(BuildContext context) {
    if (_menus == null) {
      return Center(
        child: _error == null
            ? const CircularProgressIndicator()
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Menu not loaded: $_error'),
                  TextButton(onPressed: _load, child: const Text('Retry')),
                ],
              ),
      );
    }
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: _transition,
      layoutBuilder: (current, previous) => Stack(fit: StackFit.expand, children: [...previous, ?current]),
      child: _level(),
    );
  }

  /// The categories, or the open one, keyed by its path so a change animates.
  Widget _level() {
    final open = _open;
    if (open.isEmpty) {
      final searching = _search.text.trim().isNotEmpty;
      return Column(
        key: const ValueKey(''),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: TextField(
              controller: _search,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                suffixIcon: searching
                    ? IconButton(
                        tooltip: 'Clear',
                        icon: const Icon(Icons.close),
                        onPressed: () => setState(_search.clear),
                      )
                    : null,
                hintText: 'Number or name',
                isDense: true,
                border: const OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
          Expanded(
            child: searching
                ? _grid(sections: const [], entries: _found, depth: 0)
                : _grid(sections: _sections, entries: const [], depth: 0),
          ),
        ],
      );
    }
    final depth = open.length - 1;
    final here = open.last;
    final siblings = depth == 0 ? _sections : open[depth - 1].sections;
    return DrillDown(
      key: ValueKey(_path.take(open.length).join('/')),
      onClose: _close,
      header: _Strip(
        sections: siblings,
        selected: here,
        onBack: _close,
        onTap: (s, chip) => s == here ? _close() : _openAt(depth, s, chip),
      ),
      child: _grid(sections: here.sections, entries: here.entries, depth: open.length),
    );
  }
}

/// The categories of one level, shrunk to a row above the open one.
class _Strip extends StatelessWidget {
  const _Strip({required this.sections, required this.selected, required this.onBack, required this.onTap});

  final List<MenuSection> sections;
  final MenuSection selected;
  final VoidCallback onBack;
  final void Function(MenuSection section, BuildContext chip) onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: Row(
        children: [
          IconButton(
            key: const ValueKey('menu-back'),
            tooltip: 'Back to the categories',
            icon: const Icon(Icons.expand_less),
            onPressed: onBack,
          ),
          Expanded(
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.only(right: 8),
              children: [
                for (final s in sections)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 4),
                    child: _StripChip(section: s, selected: s == selected, onTap: (chip) => onTap(s, chip)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Scrolls itself into view when it is the open one, so the strip shows where the operator is.
class _StripChip extends StatefulWidget {
  const _StripChip({required this.section, required this.selected, required this.onTap});

  final MenuSection section;
  final bool selected;
  final ValueChanged<BuildContext> onTap;

  @override
  State<_StripChip> createState() => _StripChipState();
}

class _StripChipState extends State<_StripChip> {
  @override
  void initState() {
    super.initState();
    if (widget.selected) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Scrollable.ensureVisible(context, alignment: 0.5);
      });
    }
  }

  @override
  Widget build(BuildContext context) => ChoiceChip(
    label: Text(widget.section.name),
    selected: widget.selected,
    onSelected: (_) => widget.onTap(context),
    visualDensity: VisualDensity.compact,
  );
}

class _SectionButton extends StatelessWidget {
  const _SectionButton({required this.section, required this.onTap});

  final MenuSection section;
  final ValueChanged<BuildContext> onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final count = section.allEntries.length;
    return Material(
      color: theme.colorScheme.tertiaryContainer,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => onTap(context),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  section.name,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.onTertiaryContainer),
                ),
              ),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      count == 1 ? '1 dish' : '$count dishes',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall,
                    ),
                  ),
                  Icon(Icons.chevron_right, size: 16, color: theme.colorScheme.onTertiaryContainer),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EntryButton extends StatelessWidget {
  const _EntryButton({required this.entry, required this.onTap, required this.onLongPress});

  final MenuEntry entry;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final available = entry.available;
    return Material(
      color: available ? theme.colorScheme.secondaryContainer : theme.colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: available ? onTap : null,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      entry.number ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.clip,
                      style: theme.textTheme.labelMedium,
                    ),
                  ),
                  Text(available ? entry.priceLabel : '86', style: theme.textTheme.labelLarge),
                ],
              ),
              const SizedBox(height: 4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Flexible(
                      child: Text(
                        entry.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                          decoration: available ? null : TextDecoration.lineThrough,
                        ),
                      ),
                    ),
                    if (entry.secondName != null)
                      Text(
                        entry.secondName!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                  ],
                ),
              ),
              if (!entry.quickAdd) Icon(Icons.tune, size: 14, color: theme.colorScheme.onSecondaryContainer),
            ],
          ),
        ),
      ),
    );
  }
}

/// Size, choices, quantity and a note for one dish, with the backend's price shown as they change.
/// With [initial] it reopens a line already on the order, to change it.
class ItemSheet extends StatefulWidget {
  const ItemSheet({super.key, required this.api, required this.entry, this.initial, this.warning});

  final PosApi api;
  final MenuEntry entry;
  final ChosenLine? initial;

  /// Shown above the buttons, e.g. that changing a fired dish voids it.
  final String? warning;

  @override
  State<ItemSheet> createState() => _ItemSheetState();
}

class _ItemSheetState extends State<ItemSheet> {
  ItemDetail? _detail;
  late final LineRequest _request;
  Priced? _priced;
  late int _qty = widget.initial?.qty ?? 1;
  late final _note = TextEditingController(text: widget.initial?.note ?? '');
  Timer? _debounce;
  String? _error;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    if (initial != null) {
      _request = initial.request.copy();
    } else {
      final first = widget.entry.variants.firstWhere((v) => v.available, orElse: () => widget.entry.variants.first);
      _request = LineRequest(variantId: first.variantId, entryId: widget.entry.entryId);
    }
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _note.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final entryId = widget.entry.entryId.isEmpty ? null : widget.entry.entryId;
      final detail = await widget.api.item(widget.entry.item, entryId: entryId);
      for (final g in widget.initial == null ? detail.groups : const <GroupDetail>[]) {
        final defaults = [
          for (final o in g.options)
            if (o.isDefault && o.available) o.optionId,
        ];
        if (defaults.isNotEmpty) _request.selections[g.groupId] = defaults;
      }
      if (mounted) setState(() => _detail = detail);
      _reprice();
    } on ApiException catch (err) {
      if (mounted) setState(() => _error = err.toString());
    }
  }

  void _reprice() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 150), () async {
      try {
        final priced = await widget.api.price(_request);
        if (mounted) setState(() => _priced = priced);
      } on ApiException catch (err) {
        if (mounted) setState(() => _error = err.toString());
      }
    });
  }

  void _toggle(GroupDetail group, OptionDetail option) {
    setState(() {
      final current = _request.selections[group.groupId] ?? [];
      if (group.single) {
        _request.selections[group.groupId] = current.contains(option.optionId) && !group.required
            ? []
            : [option.optionId];
      } else if (current.contains(option.optionId)) {
        _request.selections[group.groupId] = [...current]..remove(option.optionId);
      } else if (group.maxSelect == null || current.length < group.maxSelect!) {
        _request.selections[group.groupId] = [...current, option.optionId];
      }
    });
    _reprice();
  }

  /// The choices that differ from the menu's defaults, as the check lists them.
  List<String> get _picked => [
    for (final g in _detail?.groups ?? const <GroupDetail>[])
      for (final o in g.options)
        if (!o.isDefault && (_request.selections[g.groupId] ?? const []).contains(o.optionId)) o.name,
  ];

  String get _lineName {
    final variant = widget.entry.variants.firstWhere((v) => v.variantId == _request.variantId);
    return widget.entry.variants.length > 1 ? '${widget.entry.name} (${variant.name})' : widget.entry.name;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final detail = _detail;
    final priced = _priced;
    final total = priced == null ? null : (double.parse(priced.unitPrice) * _qty).toStringAsFixed(2);
    return AlertDialog(
      title: Text(
        widget.entry.secondName == null ? widget.entry.name : '${widget.entry.name}  ${widget.entry.secondName}',
      ),
      content: SizedBox(
        width: 480,
        child: detail == null
            ? Center(heightFactor: 2, child: _error == null ? const CircularProgressIndicator() : Text(_error!))
            : SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (widget.entry.variants.length > 1) ...[
                      Text('Size', style: theme.textTheme.titleSmall),
                      Wrap(
                        spacing: 8,
                        children: [
                          for (final v in widget.entry.variants)
                            ChoiceChip(
                              label: Text('${v.name} ${v.price}'),
                              selected: _request.variantId == v.variantId,
                              onSelected: v.available
                                  ? (_) {
                                      setState(() => _request.variantId = v.variantId);
                                      _reprice();
                                    }
                                  : null,
                            ),
                        ],
                      ),
                      const SizedBox(height: 12),
                    ],
                    for (final g in detail.groups) ...[
                      Text(g.required ? '${g.name} (required)' : g.name, style: theme.textTheme.titleSmall),
                      Wrap(
                        spacing: 8,
                        children: [
                          for (final o in g.options)
                            FilterChip(
                              label: Text(o.free ? o.name : '${o.name} +${o.price}'),
                              selected: (_request.selections[g.groupId] ?? const []).contains(o.optionId),
                              onSelected: o.available ? (_) => _toggle(g, o) : null,
                            ),
                        ],
                      ),
                      const SizedBox(height: 12),
                    ],
                    TextField(
                      controller: _note,
                      decoration: const InputDecoration(labelText: 'Note to the kitchen', isDense: true),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        IconButton(
                          onPressed: _qty > 1 ? () => setState(() => _qty--) : null,
                          icon: const Icon(Icons.remove),
                        ),
                        Text('$_qty', style: theme.textTheme.titleLarge),
                        IconButton(onPressed: () => setState(() => _qty++), icon: const Icon(Icons.add)),
                        const Spacer(),
                        if (total != null) Text('\$$total', style: theme.textTheme.titleLarge),
                      ],
                    ),
                    if (priced != null && !priced.ok)
                      for (final p in priced.problems) Text(p, style: TextStyle(color: theme.colorScheme.error)),
                    if (widget.warning != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(widget.warning!, style: TextStyle(color: theme.colorScheme.error)),
                      ),
                  ],
                ),
              ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          onPressed: priced != null && priced.ok
              ? () => Navigator.of(context).pop(
                  ChosenLine(
                    name: _lineName,
                    request: _request,
                    qty: _qty,
                    note: _note.text.trim(),
                    unitPrice: priced.unitPrice,
                    modifiers: _picked,
                    itemId: widget.entry.item,
                  ),
                )
              : null,
          child: Text(widget.initial == null ? 'Add' : 'Update'),
        ),
      ],
    );
  }
}

class _EightySixDialog extends StatefulWidget {
  const _EightySixDialog({required this.api, required this.entry});
  final PosApi api;
  final MenuEntry entry;

  @override
  State<_EightySixDialog> createState() => _EightySixDialogState();
}

class _EightySixDialogState extends State<_EightySixDialog> {
  late final Map<String, bool> _out = {for (final v in widget.entry.variants) v.variantId: !v.available};
  String? _error;

  Future<void> _set(String variantId, bool out) async {
    try {
      await widget.api.set86(variantId, soldOut: out);
      setState(() => _out[variantId] = out);
    } on ApiException catch (err) {
      setState(() => _error = err.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('86 ${widget.entry.name}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final v in widget.entry.variants)
            SwitchListTile(
              title: Text(widget.entry.variants.length > 1 ? v.name : 'Sold out'),
              value: _out[v.variantId] ?? false,
              onChanged: (out) => _set(v.variantId, out),
            ),
          if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ],
      ),
      actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Done'))],
    );
  }
}
