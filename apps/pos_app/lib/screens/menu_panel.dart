import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../api.dart';
import '../menu.dart';
import 'drill_down.dart';
import 'reflow.dart';
import 'theme.dart';

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

/// The menu as buttons. It opens on its categories; a category opens its dishes below and collapses the
/// categories section only by the number of rows needed to show the dishes (keeping category buttons the
/// same size), and pulling down at the top of the dishes goes back (see [DrillDown]). A category with
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
  static const _gridPadding = 10.0;
  static const _gridSpacing = 10.0;
  static const _maxCrossAxisExtent = 185.0;
  static const _childAspectRatio = 1.55;
  static const _itemsHeaderHeight = 40.0;

  List<Menu>? _menus;
  String? _error;
  var _path = <String>[]; // the open categories, outermost first, by section id
  final _reflow = ReflowGroup();
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

  /// Opens `section` at `depth`. The categories stay the same size in their grid above, collapsing only
  /// enough to show the opened section's items below (see [Reflow]).
  void _openAt(int depth, MenuSection section) {
    _reflow.snapshot();
    setState(() {
      _path = [..._path.take(depth), section.sectionId];
      _search.clear();
    });
  }

  void _close() {
    _reflow.snapshot();
    setState(() => _path = _path.take(_open.length - 1).toList());
  }

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

  Widget _grid({
    Key? key,
    required List<MenuSection> sections,
    required List<MenuEntry> entries,
    required int depth,
    required int crossAxisCount,
    required double tileHeight,
    MenuSection? selected,
  }) => GridView(
    key: key,
    padding: const EdgeInsets.all(_gridPadding),
    physics: DrillDown.physics,
    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: crossAxisCount,
      mainAxisSpacing: _gridSpacing,
      crossAxisSpacing: _gridSpacing,
      mainAxisExtent: tileHeight,
    ),
    children: [
      for (final s in sections)
        Reflow(
          id: 's:${s.sectionId}',
          group: _reflow,
          child: _SectionButton(
            section: s,
            selected: s == selected,
            onTap: () => s == selected ? _close() : _openAt(depth, s),
          ),
        ),
      for (final e in entries)
        Reflow(
          id: 'e:${e.entryId}:${e.item}',
          group: _reflow,
          child: _EntryButton(entry: e, onTap: () => _tap(e), onLongPress: () => _eightySix(e)),
        ),
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
                  const SizedBox(height: 8),
                  FilledButton.tonal(onPressed: _load, child: const Text('Retry')),
                ],
              ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final usableWidth = math.max(1.0, constraints.maxWidth - _gridPadding * 2);
        final crossAxisCount = (usableWidth / (_maxCrossAxisExtent + _gridSpacing)).ceil().clamp(1, 99);
        final tileWidth = (usableWidth - _gridSpacing * (crossAxisCount - 1)) / crossAxisCount;
        final tileHeight = tileWidth / _childAspectRatio;
        double gridHeightForRows(int rows) =>
            rows <= 0 ? 0.0 : _gridPadding * 2 + rows * tileHeight + (rows - 1) * _gridSpacing;

        final open = _open;
        final searching = open.isEmpty && _search.text.trim().isNotEmpty;
        final depth = open.isEmpty ? 0 : open.length - 1;
        final here = open.lastOrNull;
        final siblings = depth == 0 ? _sections : open[depth - 1].sections;

        double itemsHeight = 0;
        if (here != null) {
          final itemCount = here.sections.length + here.entries.length;
          final itemRows = itemCount == 0 ? 1 : (itemCount / crossAxisCount).ceil();
          final minCategoriesHeight = gridHeightForRows(1);
          final neededItemsHeight = _itemsHeaderHeight + gridHeightForRows(itemRows);
          final maxItemsHeight = math.max(0.0, constraints.maxHeight - minCategoriesHeight);
          itemsHeight = neededItemsHeight.clamp(0.0, maxItemsHeight);
        }

        return Column(
          children: [
            if (open.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 2),
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
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
            Expanded(
              child: searching
                  ? _grid(
                      key: const ValueKey('search-grid'),
                      sections: const [],
                      entries: _found,
                      depth: 0,
                      crossAxisCount: crossAxisCount,
                      tileHeight: tileHeight,
                    )
                  : _grid(
                      key: ValueKey('categories-$depth'),
                      sections: siblings,
                      entries: const [],
                      depth: depth,
                      selected: here,
                      crossAxisCount: crossAxisCount,
                      tileHeight: tileHeight,
                    ),
            ),
            if (here != null)
              SizedBox(
                height: itemsHeight,
                child: DrillDown(
                  key: ValueKey(_path.take(open.length).join('/')),
                  onClose: _close,
                  header: _ItemsHeader(path: open, onBack: _close),
                  child: _grid(
                    key: ValueKey('items-${here.sectionId}'),
                    sections: here.sections,
                    entries: here.entries,
                    depth: open.length,
                    crossAxisCount: crossAxisCount,
                    tileHeight: tileHeight,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Compact divider header between the collapsed category grid and the open category's items below.
class _ItemsHeader extends StatelessWidget {
  const _ItemsHeader({required this.path, required this.onBack});

  final List<MenuSection> path;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final here = path.last;
    final count = here.sections.length + here.entries.length;
    return Container(
      height: _MenuPanelState._itemsHeaderHeight,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border.symmetric(horizontal: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Row(
        children: [
          IconButton(
            key: const ValueKey('menu-back'),
            tooltip: 'Back to the categories',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.expand_more, size: 20),
            onPressed: onBack,
          ),
          Expanded(
            child: Text(
              path.map((s) => s.name).join(' › '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Text(
              count == 1 ? '1 item' : '$count items',
              style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionButton extends StatefulWidget {
  const _SectionButton({required this.section, required this.onTap, this.selected = false});

  final MenuSection section;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_SectionButton> createState() => _SectionButtonState();
}

class _SectionButtonState extends State<_SectionButton> {
  @override
  void initState() {
    super.initState();
    _ensureVisibleIfSelected();
  }

  @override
  void didUpdateWidget(_SectionButton old) {
    super.didUpdateWidget(old);
    if (widget.selected && !old.selected) _ensureVisibleIfSelected();
  }

  void _ensureVisibleIfSelected() {
    if (!widget.selected) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        Scrollable.ensureVisible(
          context,
          alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final selected = widget.selected;
    final count = widget.section.allEntries.length;
    final bg = selected ? scheme.primaryContainer : scheme.tertiaryContainer;
    final fg = selected ? scheme.onPrimaryContainer : scheme.onTertiaryContainer;
    final border = selected ? scheme.primary : scheme.tertiary.withValues(alpha: 0.28);
    return PressableScale(
      child: Material(
        color: bg,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: border, width: selected ? 2 : 1),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: widget.onTap,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    widget.section.name,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: fg,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        count == 1 ? '1 dish' : '$count dishes',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: fg.withValues(alpha: 0.8),
                        ),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.all(2),
                      decoration: BoxDecoration(
                        color: fg.withValues(alpha: 0.12),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        selected ? Icons.expand_less : Icons.chevron_right,
                        size: 15,
                        color: fg,
                      ),
                    ),
                  ],
                ),
              ],
            ),
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
    final scheme = theme.colorScheme;
    final available = entry.available;
    return PressableScale(
      enabled: available,
      child: Material(
        color: available ? scheme.surfaceContainerLowest : scheme.surfaceContainerHighest,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(
            color: available ? scheme.outlineVariant : scheme.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: available ? onTap : null,
          onLongPress: onLongPress,
          child: Padding(
            padding: const EdgeInsets.all(9),
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
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: scheme.primary,
                          fontWeight: FontWeight.w700,
                          fontFeatures: PosTheme.tabular,
                        ),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                      decoration: BoxDecoration(
                        color: available ? scheme.secondaryContainer : scheme.errorContainer,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        available ? entry.priceLabel : '86',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: available ? scheme.onSecondaryContainer : scheme.onErrorContainer,
                          fontWeight: FontWeight.w700,
                          fontFeatures: PosTheme.tabular,
                        ),
                      ),
                    ),
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
                            color: available ? scheme.onSurface : scheme.onSurfaceVariant,
                            height: 1.15,
                          ),
                        ),
                      ),
                      if (entry.secondName != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 1),
                          child: Text(
                            entry.secondName!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                              fontSize: 11.5,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                if (!entry.quickAdd)
                  Align(
                    alignment: Alignment.bottomRight,
                    child: Icon(Icons.tune, size: 13, color: scheme.onSurfaceVariant),
                  ),
              ],
            ),
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
    final scheme = theme.colorScheme;
    final detail = _detail;
    final priced = _priced;
    final total = priced == null ? null : (double.parse(priced.unitPrice) * _qty).toStringAsFixed(2);
    return AlertDialog(
      title: Text(
        widget.entry.secondName == null ? widget.entry.name : '${widget.entry.name}  ${widget.entry.secondName}',
      ),
      content: SizedBox(
        width: 490,
        child: detail == null
            ? Center(heightFactor: 2, child: _error == null ? const CircularProgressIndicator() : Text(_error!))
            : SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (widget.entry.variants.length > 1) ...[
                      Text('Size', style: theme.textTheme.titleSmall),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
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
                      const SizedBox(height: 14),
                    ],
                    for (final g in detail.groups) ...[
                      Text(
                        g.required ? '${g.name} (required)' : g.name,
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: g.required ? scheme.primary : scheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        children: [
                          for (final o in g.options)
                            FilterChip(
                              label: Text(o.free ? o.name : '${o.name} +${o.price}'),
                              selected: (_request.selections[g.groupId] ?? const []).contains(o.optionId),
                              onSelected: o.available ? (_) => _toggle(g, o) : null,
                            ),
                        ],
                      ),
                      const SizedBox(height: 14),
                    ],
                    TextField(
                      controller: _note,
                      decoration: const InputDecoration(
                        labelText: 'Note to the kitchen',
                        prefixIcon: Icon(Icons.edit_note_outlined),
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 14),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: scheme.outlineVariant),
                      ),
                      child: Row(
                        children: [
                          IconButton(
                            onPressed: _qty > 1 ? () => setState(() => _qty--) : null,
                            icon: const Icon(Icons.remove),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            child: Text(
                              '$_qty',
                              style: theme.textTheme.titleLarge?.copyWith(fontFeatures: PosTheme.tabular),
                            ),
                          ),
                          IconButton(onPressed: () => setState(() => _qty++), icon: const Icon(Icons.add)),
                          const Spacer(),
                          if (total != null)
                            Padding(
                              padding: const EdgeInsets.only(right: 6),
                              child: Text(
                                '\$$total',
                                style: theme.textTheme.titleLarge?.copyWith(
                                  fontWeight: FontWeight.w800,
                                  color: scheme.primary,
                                  fontFeatures: PosTheme.tabular,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (priced != null && !priced.ok)
                      for (final p in priced.problems)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(p, style: TextStyle(color: scheme.error)),
                        ),
                    if (widget.warning != null)
                      Container(
                        margin: const EdgeInsets.only(top: 10),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: scheme.errorContainer.withValues(alpha: 0.6),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.warning_amber_rounded, size: 18, color: scheme.error),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(widget.warning!, style: TextStyle(color: scheme.error)),
                            ),
                          ],
                        ),
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
