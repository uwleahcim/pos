import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../api.dart';
import '../local_order.dart' show localPrice;
import '../menu.dart';
import 'drill_down.dart';
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

  /// The choices that differ from the menu's defaults, each with the price of one, as the check lists them.
  final List<CheckModifier> modifiers;
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
/// same size), and pulling down at the top of the dishes goes back (see [DrillDown]). Switching between
/// categories with different item counts smoothly expands or shrinks the items section and the categories
/// section in lockstep. Tapping an item whose required choices already have defaults adds it immediately;
/// tapping an item that needs required selections (such as size or a required modifier group without
/// defaults) expands an inline section below until those selections are made. Long-pressing an item opens
/// [ItemSheet] as a popup to customize any modifiers, quantity, or kitchen note.
///
/// The same on every screen: a Mac or a tablet only fits more tiles per row. The categories never collapse to
/// a strip of chips (Mike, 2026-11-01).
class MenuPanel extends StatefulWidget {
  const MenuPanel({super.key, required this.api, required this.onChosen, this.qtyOf});

  /// How long the trays take to open, close or change size.
  static const transition = Duration(milliseconds: 280);

  final PosApi api;
  final ValueChanged<ChosenLine> onChosen;
  final int Function(MenuEntry entry)? qtyOf;

  @override
  State<MenuPanel> createState() => _MenuPanelState();
}

class _MenuPanelState extends State<MenuPanel> with SingleTickerProviderStateMixin {
  static const _gridPadding = 10.0;
  static const _gridSpacing = 10.0;
  static const _maxCrossAxisExtent = 185.0;
  static const _childAspectRatio = 1.55;
  static const _searchBarHeight = 56.0;
  static const _itemsDividerHeight = 1.0;

  List<Menu>? _menus;
  String? _menuCode; // the menu whose categories show (Food, Drinks, Lunch); the first one until a tab is tapped
  String? _error;
  var _path = <String>[]; // the open categories, outermost first, by section id
  List<MenuSection> _lastOpen = const []; // kept while the items tray animates closed
  final _itemCache = <String, ItemDetail>{};
  final _localCounts = <String, int>{}; // fallback item counts when widget.qtyOf is not provided
  _PendingItemSelection? _pending;
  _PendingItemSelection? _lastPending; // kept while the required-selections tray animates closed
  int? _revision;
  DateTime _loadedAt = DateTime(0);
  Timer? _watch;
  final _search = TextEditingController();
  final _categoriesScroll = _CategoryScrollController();
  final _searchScroll = _CategoryScrollController();
  final _itemsScrolls = <String, _CategoryScrollController>{};
  late final _transition = AnimationController(vsync: this, duration: MenuPanel.transition, value: 1.0)
    ..addListener(_onTransitionTick)
    ..addStatusListener(_onTransitionStatus);

  double _fromSearchFactor = 1.0;
  double _currentSearchFactor = 1.0;
  double _fromCategoriesHeight = 0.0;
  double _currentCategoriesHeight = 0.0;
  double _fromItemsHeight = 0.0;
  double _currentItemsHeight = 0.0;
  double _fromRequiredHeight = 0.0;
  double _currentRequiredHeight = 0.0;

  _CategoryScrollController _itemsScrollFor(String sectionId) =>
      _itemsScrolls.putIfAbsent(sectionId, _CategoryScrollController.new);

  static bool _sameEntry(MenuEntry a, MenuEntry b) => a.entryId == b.entryId && a.item == b.item;

  @override
  void initState() {
    super.initState();
    _load();
    _watch = Timer.periodic(MenuPanelCheck.every, (_) => _check());
  }

  @override
  void dispose() {
    _watch?.cancel();
    _transition.dispose();
    _search.dispose();
    _categoriesScroll.dispose();
    _searchScroll.dispose();
    for (final c in _itemsScrolls.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _onTransitionTick() {
    if (!mounted) return;
    setState(() {});
  }

  /// The grids are steered to computed offsets only while the trays animate. Once the last frame has landed,
  /// they are the operator's again: a later rebuild, a mouse wheel or a resize must not snap them back.
  void _onTransitionStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _transition.isAnimating) return;
      for (final scroll in [_categoriesScroll, _searchScroll, ..._itemsScrolls.values]) {
        scroll.endSync();
      }
    });
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
          _itemCache.clear();
        });
      }
      if (_prefetched != revision) unawaited(_prefetch(revision));
    } on ApiException catch (err) {
      if (mounted) setState(() => _error = err.toString());
    }
  }

  int? _prefetched; // the revision whose dishes are saved on this device

  /// Saves every dish's sizes and choices with the menu, so the screen can still configure a dish when no
  /// backend answers (ADR 6). Quietly skipped when nothing answers or the hub is older than this call.
  Future<void> _prefetch(int revision) async {
    try {
      await widget.api.prefetchItems();
      _prefetched = revision;
    } on ApiException {
      // next load tries again
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

  /// The menus open now (Food and Drinks all day, Lunch at lunch), in the hub's order: the tabs.
  List<Menu> get _openMenus => _menus ?? const <Menu>[];

  /// The menu on screen: the one whose tab was tapped, else the first. A menu that closed (lunch is over)
  /// gives way to the first without anyone doing anything.
  Menu? get _menu {
    final menus = _openMenus;
    if (menus.isEmpty) return null;
    return menus.where((m) => m.menu == _menuCode).firstOrNull ?? menus.first;
  }

  List<MenuSection> get _sections => _menu?.sections ?? const <MenuSection>[];

  /// A menu with a single category has no tile worth tapping: that category is the menu's root, and what it
  /// holds shows where the categories would. The Lunch tab opens on the specials themselves.
  MenuSection? get _root => _sections.length == 1 ? _sections.single : null;

  /// The categories tiled at the top: the menu's, or a single category's own sub-categories.
  List<MenuSection> get _top => _root?.sections ?? _sections;

  /// The dishes tiled with the top categories: a single category's own, else none.
  List<MenuEntry> get _topEntries => _root?.entries ?? const <MenuEntry>[];

  /// Shows another menu's categories: whatever was open on this one closes.
  void _showMenu(String code) {
    if (code == _menu?.menu || !_openMenus.any((m) => m.menu == code)) return;
    _startTransition(resetScroll: true);
    setState(() {
      _menuCode = code;
      _path = <String>[];
      _pending = null;
      _search.clear();
    });
  }

  /// The open categories, as far as the menu still has them: a category a manager removed closes.
  List<MenuSection> get _open {
    final open = <MenuSection>[];
    var level = _top;
    for (final id in _path) {
      final s = level.where((s) => s.sectionId == id).firstOrNull;
      if (s == null) break;
      open.add(s);
      level = s.sections;
    }
    return open;
  }

  /// What the search finds, on every menu open, whichever tab is showing: a soda typed on the Food tab is
  /// found at the bar too. A dish on two menus at the same sizes and prices (the soft drinks) is listed once,
  /// under its first menu; a dish the lunch menu sells as another size or price is listed from both.
  List<MenuEntry> get _found {
    final q = _search.text.trim().toLowerCase();
    final seen = <String>{};
    String offer(MenuEntry e) => '${e.item}|${e.variants.map((v) => '${v.variantId}=${v.price}').join(',')}';
    return [
      for (final m in _openMenus)
        for (final s in m.sections)
          for (final e in s.allEntries)
            if ((e.number?.toLowerCase() == q ||
                    e.name.toLowerCase().contains(q) ||
                    (e.secondName ?? '').toLowerCase().contains(q)) &&
                seen.add(offer(e)))
              e,
    ];
  }

  void _startTransition({required bool resetScroll, String? resetItemsSectionId}) {
    _fromSearchFactor = _currentSearchFactor;
    _fromCategoriesHeight = _currentCategoriesHeight;
    _fromItemsHeight = _currentItemsHeight;
    _fromRequiredHeight = _currentRequiredHeight;
    _categoriesScroll.captureStart(resetScroll: resetScroll);
    _searchScroll.captureStart(resetScroll: false);
    final here = _open.lastOrNull;
    if (here != null) {
      _itemsScrollFor(here.sectionId).captureStart(resetScroll: false);
    }
    if (resetItemsSectionId != null) {
      _itemsScrollFor(resetItemsSectionId).captureStart(resetScroll: true);
    }
    _transition.forward(from: 0.0);
  }

  /// Opens `section` at `depth`. The categories stay the same size in their grid above, smoothly
  /// collapsing or expanding to match the rows needed by `section`'s items.
  void _openAt(int depth, MenuSection section) {
    final currentDepth = _open.isEmpty ? 0 : _open.length - 1;
    _startTransition(resetScroll: depth != currentDepth, resetItemsSectionId: section.sectionId);
    setState(() {
      _path = [..._path.take(depth), section.sectionId];
      _pending = null;
      _search.clear();
    });
  }

  void _close() {
    final closingSubcategory = _open.length > 1;
    _startTransition(resetScroll: closingSubcategory);
    setState(() {
      _path = _path.take(_open.length - 1).toList();
      _pending = null;
    });
  }

  void _openPending(_PendingItemSelection pending) {
    _startTransition(resetScroll: false);
    setState(() {
      _pending = pending;
      _lastPending = pending;
    });
  }

  void _closePending() {
    if (_pending == null) return;
    _startTransition(resetScroll: false);
    setState(() => _pending = null);
  }

  void _choose(ChosenLine chosen) {
    final key = '${chosen.request.entryId ?? ''}:${chosen.itemId ?? ''}';
    setState(() {
      _localCounts[key] = (_localCounts[key] ?? 0) + chosen.qty;
    });
    widget.onChosen(chosen);
  }

  int _qtyOf(MenuEntry entry) {
    if (widget.qtyOf != null) return widget.qtyOf!(entry);
    return _localCounts['${entry.entryId}:${entry.item}'] ?? 0;
  }

  void _selectPendingVariant(VariantOffer variant) {
    final pending = _pending;
    if (pending == null || !variant.available) return;
    pending.selectedVariantId = variant.variantId;
    if (pending.isComplete) {
      final chosen = pending.toChosenLine();
      _closePending();
      _choose(chosen);
    } else {
      setState(() {});
    }
  }

  void _togglePendingOption(GroupDetail group, OptionDetail option) {
    final pending = _pending;
    if (pending == null || !option.available) return;
    final current = pending.selections[group.groupId] ?? const [];
    if (group.single) {
      pending.selections[group.groupId] = [option.optionId];
    } else if (current.contains(option.optionId)) {
      pending.selections[group.groupId] = [...current]..remove(option.optionId);
    } else if (group.maxSelect == null || current.length < group.maxSelect!) {
      pending.selections[group.groupId] = [...current, option.optionId];
    }
    if (pending.isComplete) {
      final chosen = pending.toChosenLine();
      _closePending();
      _choose(chosen);
    } else {
      setState(() {});
    }
  }

  /// The 86 board from the order screen: mark a size sold out or back.
  Future<void> _eightySix(MenuEntry entry) async {
    await showDialog<void>(
      context: context,
      builder: (context) => _EightySixDialog(api: widget.api, entry: entry),
    );
    await _load();
  }

  /// Tapping an item auto-adds it immediately when all required selections already have defaults
  /// (or when it has only one size and no options). When required selections are still needed
  /// (such as choosing a size or a required modifier group with no defaults), it expands the
  /// inline required-selections section below.
  Future<void> _tap(MenuEntry entry) async {
    if (!entry.available) return;
    if (_pending != null && _pending!.entry == entry) {
      _closePending();
      return;
    }
    final availableVariants = [
      for (final v in entry.variants)
        if (v.available) v,
    ];
    if (availableVariants.isEmpty) return;

    ItemDetail? detail;
    final selections = <String, List<String>>{};
    final requiredGroups = <GroupDetail>[];

    if (entry.hasOptions) {
      final cacheKey = '${entry.entryId}:${entry.item}';
      detail = _itemCache[cacheKey];
      if (detail == null) {
        try {
          final entryId = entry.entryId.isEmpty ? null : entry.entryId;
          detail = await widget.api.item(entry.item, entryId: entryId);
          _itemCache[cacheKey] = detail;
        } on ApiException catch (err) {
          // Added blind, the dish would reach the hub without its required choices and be refused there, and
          // the operator would only find out when the line vanished from the check. Say so now instead.
          if (!mounted) return;
          ScaffoldMessenger.maybeOf(context)
              ?.showSnackBar(SnackBar(content: Text("Can't load the choices for ${entry.name}: $err")));
          return;
        }
      }
      if (!mounted) return;
      for (final g in detail.groups) {
        final defaults = [
          for (final o in g.options)
            if (o.isDefault && o.available) o.optionId,
        ];
        if (defaults.isNotEmpty) {
          selections[g.groupId] = defaults;
        }
        if (g.required && defaults.length < g.minSelect) {
          requiredGroups.add(g);
        }
      }
    }

    final needsVariant = availableVariants.length > 1;
    final pending = _PendingItemSelection(
      entry: entry,
      detail: detail,
      availableVariants: availableVariants,
      needsVariant: needsVariant,
      selectedVariantId: needsVariant ? null : availableVariants.first.variantId,
      requiredGroups: requiredGroups,
      selections: selections,
    );

    if (pending.isComplete) {
      if (_pending != null) _closePending();
      _choose(pending.toChosenLine());
      return;
    }

    _openPending(pending);
  }

  /// Long-pressing an item opens the popup [ItemSheet] to customize modifiers, size, quantity, or note.
  Future<void> _longPress(MenuEntry entry) async {
    if (!entry.available) {
      await _eightySix(entry);
      return;
    }
    if (_pending != null) _closePending();
    final chosen = await showDialog<ChosenLine>(
      context: context,
      builder: (_) => ItemSheet(api: widget.api, entry: entry, onEightySix: () => _eightySix(entry)),
    );
    if (chosen != null) _choose(chosen);
  }

  Widget _grid({
    Key? key,
    ScrollController? controller,
    double extraBottomPadding = 0.0,
    required List<MenuSection> sections,
    required List<MenuEntry> entries,
    required int depth,
    required int crossAxisCount,
    required double tileHeight,
    MenuSection? selected,
  }) => GridView(
    key: key,
    controller: controller,
    padding: EdgeInsets.fromLTRB(_gridPadding, _gridPadding, _gridPadding, _gridPadding + extraBottomPadding),
    physics: DrillDown.physics,
    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: crossAxisCount,
      mainAxisSpacing: _gridSpacing,
      crossAxisSpacing: _gridSpacing,
      mainAxisExtent: tileHeight,
    ),
    children: [
      for (final (i, s) in sections.indexed)
        _SectionButton(
          key: ValueKey('s:${s.sectionId}'),
          section: s,
          index: i,
          selected: s == selected,
          onTap: () => s == selected ? _close() : _openAt(depth, s),
        ),
      for (final e in entries)
        _EntryButton(
          key: ValueKey('e:${e.entryId}:${e.item}'),
          entry: e,
          qty: _qtyOf(e),
          selected: _pending != null && _sameEntry(_pending!.entry, e),
          onTap: () => _tap(e),
          onLongPress: () => _longPress(e),
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
        if (open.isNotEmpty) {
          _lastOpen = open;
        }
        final searching = open.isEmpty && _search.text.trim().isNotEmpty;
        final depth = open.isEmpty ? 0 : open.length - 1;
        final here = open.lastOrNull;
        final siblings = depth == 0 ? _top : open[depth - 1].sections;
        final topEntries = depth == 0 ? _topEntries : const <MenuEntry>[]; // a single category's own dishes

        final found = searching ? _found : const <MenuEntry>[];
        final totalCategoryRows = ((siblings.length + topEntries.length) / crossAxisCount).ceil();
        final totalCategoriesContentHeight = gridHeightForRows(math.max(1, totalCategoryRows));
        final totalSearchRows = (found.length / crossAxisCount).ceil();
        final totalSearchContentHeight = gridHeightForRows(math.max(1, totalSearchRows));
        final topContentHeight = searching ? totalSearchContentHeight : totalCategoriesContentHeight;
        final minCategoriesHeight = math.min(topContentHeight, gridHeightForRows(1));

        double targetRequiredHeight = 0.0;
        final pending = _pending;
        if (pending != null) {
          final requiredCount =
              (pending.needsVariant ? pending.availableVariants.length : 0) +
              pending.requiredGroups.fold<int>(0, (sum, g) => sum + g.options.length);
          final requiredRows = requiredCount == 0 ? 1 : (requiredCount / crossAxisCount).ceil();
          final neededRequiredHeight = _itemsDividerHeight + gridHeightForRows(requiredRows);
          final minTopReserve = searching ? (_searchBarHeight + gridHeightForRows(1)) : minCategoriesHeight;
          final minItemsReserve = here != null ? (_itemsDividerHeight + gridHeightForRows(1)) : 0.0;
          final maxRequiredHeight = math.max(0.0, constraints.maxHeight - minTopReserve - minItemsReserve);
          targetRequiredHeight = neededRequiredHeight.clamp(0.0, maxRequiredHeight);
        }

        double targetItemsHeight = 0.0;
        if (here != null) {
          final itemCount = here.sections.length + here.entries.length;
          final itemRows = itemCount == 0 ? 1 : (itemCount / crossAxisCount).ceil();
          final neededItemsHeight = _itemsDividerHeight + gridHeightForRows(itemRows);
          final maxItemsHeight = math.max(0.0, constraints.maxHeight - minCategoriesHeight - targetRequiredHeight);
          targetItemsHeight = neededItemsHeight.clamp(0.0, maxItemsHeight);
        }

        // The top row holds the menu tabs (Food, Drinks; Lunch at lunch) and the search field. With tabs it
        // stays while a category is open, so the other menu is always one tap away, and only the search field
        // fades; with one menu there are no tabs and the row folds away to give the dishes its room.
        final tabs = _openMenus.length > 1 ? _openMenus : const <Menu>[];
        double topHeight(double searchFactor) => tabs.isEmpty ? _searchBarHeight * searchFactor : _searchBarHeight;
        final targetSearchFactor = open.isEmpty ? 1.0 : 0.0;
        final availableForCategories = math.max(
          minCategoriesHeight,
          constraints.maxHeight - topHeight(targetSearchFactor) - targetItemsHeight - targetRequiredHeight,
        );
        final targetCategoriesHeight = math.min(topContentHeight, availableForCategories);

        final t = Curves.easeInOutCubic.transform(_transition.value);
        final currentSearchFactor = ui.lerpDouble(_fromSearchFactor, targetSearchFactor, t)!.clamp(0.0, 1.0);
        final showSearch = !(currentSearchFactor <= 0.005 && open.isNotEmpty);
        final showTop = tabs.isNotEmpty || showSearch;
        final currentSearchHeight = showTop ? topHeight(currentSearchFactor) : 0.0;

        final rawCategoriesHeight = math.max(0.0, ui.lerpDouble(_fromCategoriesHeight, targetCategoriesHeight, t)!);
        final double currentCategoriesHeight = rawCategoriesHeight.clamp(
          0.0,
          math.max(0.0, constraints.maxHeight - currentSearchHeight),
        );
        final rawItemsHeight = math.max(0.0, ui.lerpDouble(_fromItemsHeight, targetItemsHeight, t)!);
        final double currentItemsHeight = rawItemsHeight.clamp(
          0.0,
          math.max(0.0, constraints.maxHeight - currentSearchHeight - currentCategoriesHeight),
        );
        final rawRequiredHeight = math.max(0.0, ui.lerpDouble(_fromRequiredHeight, targetRequiredHeight, t)!);
        final double currentRequiredHeight = rawRequiredHeight.clamp(
          0.0,
          math.max(0.0, constraints.maxHeight - currentSearchHeight - currentCategoriesHeight - currentItemsHeight),
        );

        _currentSearchFactor = currentSearchFactor;
        _currentCategoriesHeight = currentCategoriesHeight;
        _currentItemsHeight = currentItemsHeight;
        _currentRequiredHeight = currentRequiredHeight;

        final displayOpen = open.isNotEmpty ? open : _lastOpen;
        final displayHere = displayOpen.lastOrNull;
        final displayPending = pending ?? _lastPending;

        final pendingTopIndex = pending != null && here == null
            ? topEntries.indexWhere((e) => _sameEntry(e, pending.entry))
            : -1;
        final extraBottomSpace = _categoriesScroll.syncViewport(
          totalTileCount: siblings.length + topEntries.length,
          selectedTileIndex: here != null
              ? siblings.indexOf(here)
              : pendingTopIndex >= 0
              ? siblings.length + pendingTopIndex
              : -1,
          crossAxisCount: crossAxisCount,
          tileHeight: tileHeight,
          gridPadding: _gridPadding,
          gridSpacing: _gridSpacing,
          currentViewportHeight: currentCategoriesHeight,
          targetViewportHeight: targetCategoriesHeight,
          progress: t,
        );

        final searchExtraBottomSpace = searching
            ? _searchScroll.syncViewport(
                totalTileCount: found.length,
                selectedTileIndex: pending != null ? found.indexWhere((e) => _sameEntry(e, pending.entry)) : -1,
                crossAxisCount: crossAxisCount,
                tileHeight: tileHeight,
                gridPadding: _gridPadding,
                gridSpacing: _gridSpacing,
                currentViewportHeight: currentCategoriesHeight,
                targetViewportHeight: targetCategoriesHeight,
                progress: t,
              )
            : 0.0;

        _CategoryScrollController? itemsScroll;
        double itemsExtraBottomSpace = 0.0;
        if (displayHere != null) {
          itemsScroll = _itemsScrollFor(displayHere.sectionId);
          final entryIdx = pending != null ? displayHere.entries.indexWhere((e) => _sameEntry(e, pending.entry)) : -1;
          final selectedItemTileIndex = entryIdx >= 0 ? displayHere.sections.length + entryIdx : -1;
          itemsExtraBottomSpace = itemsScroll.syncViewport(
            totalTileCount: displayHere.sections.length + displayHere.entries.length,
            selectedTileIndex: selectedItemTileIndex,
            crossAxisCount: crossAxisCount,
            tileHeight: tileHeight,
            gridPadding: _gridPadding,
            gridSpacing: _gridSpacing,
            currentViewportHeight: math.max(0.0, currentItemsHeight - _itemsDividerHeight),
            targetViewportHeight: math.max(0.0, targetItemsHeight - _itemsDividerHeight),
            progress: t,
          );
        }

        if (_categoriesScroll.syncActive ||
            _searchScroll.syncActive ||
            (itemsScroll != null && itemsScroll.syncActive)) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            _categoriesScroll.syncToDesired();
            _searchScroll.syncToDesired();
            itemsScroll?.syncToDesired();
          });
        }

        final searchField = Opacity(
          opacity: currentSearchFactor,
          child: IgnorePointer(
            ignoring: currentSearchFactor < 0.5,
            child: Center(
              child: TextField(
                controller: _search,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: searching
                      ? IconButton(
                          tooltip: 'Clear',
                          icon: const Icon(Icons.close),
                          onPressed: () => setState(() {
                            _search.clear();
                            _pending = null;
                          }),
                        )
                      : null,
                  hintText: 'Number or name',
                  isDense: true,
                ),
                onChanged: (_) => setState(() => _pending = null),
              ),
            ),
          ),
        );

        return Column(
          children: [
            if (showTop)
              SizedBox(
                height: currentSearchHeight,
                child: ClipRect(
                  child: OverflowBox(
                    alignment: Alignment.topCenter,
                    minHeight: _searchBarHeight,
                    maxHeight: _searchBarHeight,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                      child: tabs.isEmpty
                          ? searchField
                          : Row(
                              children: [
                                _MenuTabs(menus: tabs, selected: _menu!.menu, onSelected: _showMenu),
                                const SizedBox(width: 8),
                                Expanded(child: searchField),
                              ],
                            ),
                    ),
                  ),
                ),
              ),
            SizedBox(
              height: currentCategoriesHeight,
              child: searching
                  ? _grid(
                      key: const ValueKey('search-grid'),
                      controller: _searchScroll,
                      extraBottomPadding: searchExtraBottomSpace,
                      sections: const [],
                      entries: found,
                      depth: 0,
                      crossAxisCount: crossAxisCount,
                      tileHeight: tileHeight,
                    )
                  : _grid(
                      key: ValueKey('categories-$depth'),
                      controller: _categoriesScroll,
                      extraBottomPadding: extraBottomSpace,
                      sections: siblings,
                      entries: topEntries,
                      depth: depth,
                      selected: here,
                      crossAxisCount: crossAxisCount,
                      tileHeight: tileHeight,
                    ),
            ),
            if (currentItemsHeight > 0.5 && displayHere != null)
              SizedBox(
                height: currentItemsHeight,
                child: ClipRect(
                  child: OverflowBox(
                    alignment: Alignment.topCenter,
                    minHeight: math.max(currentItemsHeight, _itemsDividerHeight + 1.0),
                    maxHeight: math.max(currentItemsHeight, _itemsDividerHeight + 1.0),
                    child: ColoredBox(
                      color: Theme.of(context).colorScheme.surfaceContainerLow,
                      child: DrillDown(
                        onClose: _close,
                        header: const Divider(height: _itemsDividerHeight, thickness: _itemsDividerHeight),
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 200),
                          switchInCurve: Curves.easeOutCubic,
                          switchOutCurve: Curves.easeInCubic,
                          child: _grid(
                            key: ValueKey('items-${displayHere.sectionId}'),
                            controller: itemsScroll,
                            extraBottomPadding: itemsExtraBottomSpace,
                            sections: displayHere.sections,
                            entries: displayHere.entries,
                            depth: displayOpen.length,
                            crossAxisCount: crossAxisCount,
                            tileHeight: tileHeight,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            if (currentRequiredHeight > 0.5 && displayPending != null)
              SizedBox(
                key: const ValueKey('required-selections'),
                height: currentRequiredHeight,
                child: ClipRect(
                  child: OverflowBox(
                    alignment: Alignment.topCenter,
                    minHeight: math.max(currentRequiredHeight, _itemsDividerHeight + 1.0),
                    maxHeight: math.max(currentRequiredHeight, _itemsDividerHeight + 1.0),
                    child: _RequiredSelectionsSection(
                      pending: displayPending,
                      crossAxisCount: crossAxisCount,
                      tileHeight: tileHeight,
                      onSelectVariant: _selectPendingVariant,
                      onToggleOption: _togglePendingOption,
                      onClose: _closePending,
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _CategoryScrollController extends ScrollController {
  double Function(double viewportHeight)? desiredScrollForViewport;
  bool syncActive = false;
  double fromScrollOffset = 0.0;
  double fromViewportHeight = 0.0;

  void captureStart({required bool resetScroll}) {
    if (resetScroll) {
      fromScrollOffset = 0.0;
      fromViewportHeight = 0.0;
    } else {
      fromScrollOffset = hasClients ? offset : 0.0;
      fromViewportHeight = hasClients && position.haveDimensions ? position.viewportDimension : 0.0;
    }
    syncActive = true;
  }

  double syncViewport({
    required int totalTileCount,
    required int selectedTileIndex,
    required int crossAxisCount,
    required double tileHeight,
    required double gridPadding,
    required double gridSpacing,
    required double currentViewportHeight,
    required double targetViewportHeight,
    required double progress,
  }) {
    if (!syncActive) {
      desiredScrollForViewport = null;
      return 0.0;
    }
    final totalRows = (totalTileCount / crossAxisCount).ceil();
    final totalContentHeight = totalRows <= 0
        ? 0.0
        : gridPadding * 2 + totalRows * tileHeight + (totalRows - 1) * gridSpacing;
    final targetMaxScroll = math.max(0.0, totalContentHeight - targetViewportHeight);
    var targetScroll = fromScrollOffset.clamp(0.0, targetMaxScroll);
    double? rowTop;
    double? rowBottom;
    if (selectedTileIndex >= 0 && selectedTileIndex < totalTileCount) {
      final row = selectedTileIndex ~/ crossAxisCount;
      rowTop = row * (tileHeight + gridSpacing);
      rowBottom = rowTop + tileHeight + gridPadding * 2;
      if (rowBottom > targetScroll + targetViewportHeight) {
        targetScroll = rowBottom - targetViewportHeight;
      }
      if (rowTop < targetScroll) {
        targetScroll = rowTop;
      }
      targetScroll = targetScroll.clamp(0.0, targetMaxScroll);
    }
    final startBottomVisible =
        fromViewportHeight <= 0 || (rowBottom != null && rowBottom <= fromScrollOffset + fromViewportHeight + 1.0);
    final startTopVisible = rowTop != null && rowTop >= fromScrollOffset - 1.0;

    double desiredForViewport(double viewportHeight) {
      var desired = ui.lerpDouble(fromScrollOffset, targetScroll, progress)!;
      if (rowBottom != null && (startBottomVisible || progress >= 1.0) && rowBottom > desired + viewportHeight) {
        desired = rowBottom - viewportHeight;
      }
      if (rowTop != null && (startTopVisible || progress >= 1.0) && rowTop < desired) {
        desired = rowTop;
      }
      return math.max(0.0, desired);
    }

    desiredScrollForViewport = desiredForViewport;
    final currentDesired = desiredForViewport(currentViewportHeight);
    if (currentDesired > 0) {
      return math.max(0.0, currentViewportHeight + currentDesired - totalContentHeight);
    }
    return 0.0;
  }

  @override
  ScrollPosition createScrollPosition(ScrollPhysics physics, ScrollContext context, ScrollPosition? oldPosition) {
    return _CategoryScrollPosition(controller: this, physics: physics, context: context, oldPosition: oldPosition);
  }

  void syncToDesired() {
    if (!hasClients) return;
    final pos = position;
    if (pos is _CategoryScrollPosition) {
      pos.syncToDesired();
    }
  }

  /// Lands the final offset, then stops steering: later rebuilds and dimension changes leave the scroll alone.
  void endSync() {
    syncToDesired();
    syncActive = false;
    desiredScrollForViewport = null;
  }
}

class _CategoryScrollPosition extends ScrollPositionWithSingleContext {
  _CategoryScrollPosition({
    required this.controller,
    required super.physics,
    required super.context,
    super.oldPosition,
  });

  final _CategoryScrollController controller;

  @override
  void applyUserOffset(double delta) {
    controller.syncActive = false;
    controller.desiredScrollForViewport = null;
    super.applyUserOffset(delta);
  }

  @override
  bool correctForNewDimensions(ScrollMetrics oldPosition, ScrollMetrics newPosition) {
    final desiredForViewport = controller.desiredScrollForViewport;
    if (desiredForViewport != null) {
      final desired = desiredForViewport(newPosition.viewportDimension)
          .clamp(newPosition.minScrollExtent, newPosition.maxScrollExtent);
      if ((desired - pixels).abs() > 0.01) {
        correctPixels(desired);
        return false;
      }
      return true;
    }
    return super.correctForNewDimensions(oldPosition, newPosition);
  }

  void syncToDesired() {
    if (!hasPixels || !haveDimensions) return;
    final desiredForViewport = controller.desiredScrollForViewport;
    if (desiredForViewport == null) return;
    final desired = desiredForViewport(viewportDimension).clamp(minScrollExtent, maxScrollExtent);
    if ((desired - pixels).abs() > 0.5) {
      jumpTo(desired);
    }
  }
}

/// The menus open now as tabs (Food, Drinks; Lunch at lunch), the one on screen filled in. One row shared
/// with the search field: a tap switches the categories below, whatever was open on the other menu closes.
class _MenuTabs extends StatelessWidget {
  const _MenuTabs({required this.menus, required this.selected, required this.onSelected});

  final List<Menu> menus;
  final String selected;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) => SegmentedButton<String>(
    key: const ValueKey('menu-tabs'),
    segments: [
      for (final m in menus)
        ButtonSegment(
          value: m.menu,
          label: Text(m.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
    ],
    selected: {selected},
    showSelectedIcon: false,
    style: const ButtonStyle(
      visualDensity: VisualDensity.compact,
      padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 14)),
    ),
    onSelectionChanged: (chosen) => onSelected(chosen.first),
  );
}

/// A category tile, in the colour the menu gives the category or one from the palette by its place among its
/// siblings, so a glance tells the sections apart.
class _SectionButton extends StatelessWidget {
  const _SectionButton({
    super.key,
    required this.section,
    required this.index,
    required this.onTap,
    this.selected = false,
  });

  final MenuSection section;
  final int index;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final count = section.allEntries.length;
    final tint = categoryTint(scheme, hex: section.color, index: index);
    final bg = tint.fill;
    final fg = tint.text;
    final border = selected ? scheme.primary : tint.border.withValues(alpha: 0.6);
    return PressableScale(
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: border, width: selected ? 2 : 1),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      section.name,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(color: fg, fontWeight: FontWeight.w700),
                    ),
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          count == 1 ? '1 dish' : '$count dishes',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(color: fg.withValues(alpha: 0.8)),
                        ),
                      ),
                      Container(
                        key: selected ? const ValueKey('menu-back') : null,
                        padding: const EdgeInsets.all(2),
                        decoration: BoxDecoration(color: fg.withValues(alpha: 0.12), shape: BoxShape.circle),
                        child: Icon(selected ? Icons.expand_less : Icons.chevron_right, size: 15, color: fg),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PendingItemSelection {
  _PendingItemSelection({
    required this.entry,
    this.detail,
    required this.availableVariants,
    required this.needsVariant,
    this.selectedVariantId,
    required this.requiredGroups,
    required this.selections,
  });

  final MenuEntry entry;
  final ItemDetail? detail;
  final List<VariantOffer> availableVariants;
  final bool needsVariant;
  String? selectedVariantId;
  final List<GroupDetail> requiredGroups;
  final Map<String, List<String>> selections;

  bool get isComplete {
    if (selectedVariantId == null) return false;
    for (final g in requiredGroups) {
      final count = selections[g.groupId]?.length ?? 0;
      if (count < g.minSelect) return false;
    }
    return true;
  }

  ChosenLine toChosenLine() {
    final variant = availableVariants.firstWhere(
      (v) => v.variantId == selectedVariantId,
      orElse: () => availableVariants.first,
    );
    final name = entry.variants.length > 1 ? '${entry.name} (${variant.name})' : entry.name;
    var priceCents = _parseCents(variant.price);
    final modifiers = <CheckModifier>[];
    for (final g in detail?.groups ?? const <GroupDetail>[]) {
      final pickedIds = selections[g.groupId] ?? const [];
      for (final o in g.options) {
        if (pickedIds.contains(o.optionId)) {
          if (!o.isDefault) modifiers.add(CheckModifier(o.name, price: o.free ? '0.00' : o.price));
          if (!o.free && priceCents != null) {
            final extra = _parseCents(o.price);
            if (extra != null) priceCents += extra;
          }
        }
      }
    }
    final unitPrice = priceCents != null ? (priceCents / 100.0).toStringAsFixed(2) : variant.price;
    return ChosenLine(
      name: name,
      request: LineRequest(
        variantId: variant.variantId,
        entryId: entry.entryId,
        selections: {
          for (final MapEntry(:key, :value) in selections.entries)
            if (value.isNotEmpty) key: [...value],
        },
      ),
      unitPrice: unitPrice,
      modifiers: modifiers,
      itemId: entry.item,
    );
  }
}

int? _parseCents(String price) {
  final d = double.tryParse(price);
  return d == null ? null : (d * 100).round();
}

class _RequiredSelectionsSection extends StatelessWidget {
  const _RequiredSelectionsSection({
    required this.pending,
    required this.crossAxisCount,
    required this.tileHeight,
    required this.onSelectVariant,
    required this.onToggleOption,
    required this.onClose,
  });

  final _PendingItemSelection pending;
  final int crossAxisCount;
  final double tileHeight;
  final ValueChanged<VariantOffer> onSelectVariant;
  final void Function(GroupDetail group, OptionDetail option) onToggleOption;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: scheme.surfaceContainer,
      child: DrillDown(
        onClose: onClose,
        header: const Divider(
          height: _MenuPanelState._itemsDividerHeight,
          thickness: _MenuPanelState._itemsDividerHeight,
        ),
        child: GridView(
          padding: const EdgeInsets.all(_MenuPanelState._gridPadding),
          physics: DrillDown.physics,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            mainAxisSpacing: _MenuPanelState._gridSpacing,
            crossAxisSpacing: _MenuPanelState._gridSpacing,
            mainAxisExtent: tileHeight,
          ),
          children: [
            if (pending.needsVariant)
              for (final v in pending.availableVariants)
                _ModifierButton(
                  key: ValueKey('req-variant:${v.variantId}'),
                  groupLabel: 'Size',
                  name: v.name,
                  priceLabel: v.price,
                  available: v.available,
                  selected: pending.selectedVariantId == v.variantId,
                  onTap: () => onSelectVariant(v),
                ),
            for (final g in pending.requiredGroups)
              for (final o in g.options)
                _ModifierButton(
                  key: ValueKey('req-option:${g.groupId}:${o.optionId}'),
                  groupLabel: g.minSelect > 1
                      ? '${g.name} (${(pending.selections[g.groupId] ?? const []).length}/${g.minSelect})'
                      : g.name,
                  name: o.name,
                  priceLabel: o.free ? null : '+${o.price}',
                  available: o.available,
                  selected: (pending.selections[g.groupId] ?? const []).contains(o.optionId),
                  onTap: () => onToggleOption(g, o),
                ),
          ],
        ),
      ),
    );
  }
}

class _ModifierButton extends StatelessWidget {
  const _ModifierButton({
    super.key,
    required this.groupLabel,
    required this.name,
    this.priceLabel,
    required this.available,
    required this.selected,
    required this.onTap,
  });

  final String groupLabel;
  final String name;
  final String? priceLabel;
  final bool available;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final bg = !available
        ? scheme.surfaceContainerHighest
        : (selected ? scheme.primaryContainer : scheme.surfaceContainerLowest);
    final borderColor = !available
        ? scheme.outlineVariant.withValues(alpha: 0.5)
        : (selected ? scheme.primary : scheme.outlineVariant);
    return PressableScale(
      enabled: available,
      child: Material(
        color: bg,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: borderColor, width: selected ? 2 : 1),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: available ? onTap : null,
          child: Padding(
            padding: const EdgeInsets.all(9),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        groupLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: selected ? scheme.onPrimaryContainer : scheme.primary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    if (!available || priceLabel != null)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                        decoration: BoxDecoration(
                          color: available ? scheme.secondaryContainer : scheme.errorContainer,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          available ? priceLabel! : '86',
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
                  child: Text(
                    name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      decoration: available ? null : TextDecoration.lineThrough,
                      color: !available
                          ? scheme.onSurfaceVariant
                          : (selected ? scheme.onPrimaryContainer : scheme.onSurface),
                      fontWeight: selected ? FontWeight.w700 : null,
                      height: 1.15,
                    ),
                  ),
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
  const _EntryButton({
    super.key,
    required this.entry,
    required this.onTap,
    required this.onLongPress,
    this.qty = 0,
    this.selected = false,
  });

  final MenuEntry entry;
  final int qty;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final available = entry.available;
    final bg = !available
        ? scheme.surfaceContainerHighest
        : (selected ? scheme.primaryContainer : scheme.surfaceContainerLowest);
    final borderColor = !available
        ? scheme.outlineVariant.withValues(alpha: 0.5)
        : (selected ? scheme.primary : (qty > 0 ? scheme.primary.withValues(alpha: 0.55) : scheme.outlineVariant));
    return PressableScale(
      enabled: available,
      child: Material(
        color: bg,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: borderColor, width: selected ? 2 : (qty > 0 ? 1.5 : 1)),
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
                    if (qty > 0) ...[
                      Container(
                        key: ValueKey('entry-qty:${entry.entryId}:${entry.item}'),
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                        decoration: BoxDecoration(color: scheme.primary, borderRadius: BorderRadius.circular(6)),
                        child: Text(
                          '$qty×',
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: scheme.onPrimary,
                            fontWeight: FontWeight.w700,
                            fontFeatures: PosTheme.tabular,
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                    ],
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
                            style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant, fontSize: 11.5),
                          ),
                        ),
                    ],
                  ),
                ),
                // only where a tap will ask something; on every dish with a rice group it would say nothing
                if (entry.needsChoice)
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
  const ItemSheet({super.key, required this.api, required this.entry, this.initial, this.warning, this.onEightySix});

  final PosApi api;
  final MenuEntry entry;
  final ChosenLine? initial;

  /// Shown above the buttons, e.g. that changing a fired dish voids it.
  final String? warning;
  final VoidCallback? onEightySix;

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
  String? _armed; // No, Extra, On the side or Light, waiting for the choice it is about

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
        if (!mounted) return;
        if (err.status == null) {
          // No backend answers (ADR 6): the menu's own prices, marked estimated, so the dish still goes on.
          setState(() => _priced = localPrice(_lineName, widget.entry.variants, _detail, _request));
        } else {
          setState(() => _error = err.toString());
        }
      }
    });
  }

  void _toggle(GroupDetail group, OptionDetail option) {
    setState(() {
      final current = _request.selections[group.groupId] ?? [];
      final chosen = current.contains(option.optionId);
      final armed = _armed;
      _armed = null;
      if (armed != null) {
        // "No peanuts": the word goes on this choice, which has to be on the line for it to mean anything.
        // The same word again takes it off and leaves the plain choice.
        final full = !chosen && !group.single && group.maxSelect != null && current.length >= group.maxSelect!;
        if (!full) {
          if (_request.prefixes[option.optionId] == armed) {
            _request.prefixes.remove(option.optionId);
          } else {
            _request.prefixes[option.optionId] = armed;
          }
          if (!chosen) {
            _request.selections[group.groupId] = group.single ? [option.optionId] : [...current, option.optionId];
          }
        }
      } else if (group.single) {
        _request.selections[group.groupId] = chosen && !group.required ? [] : [option.optionId];
      } else if (chosen) {
        _request.selections[group.groupId] = [...current]..remove(option.optionId);
      } else if (group.maxSelect == null || current.length < group.maxSelect!) {
        _request.selections[group.groupId] = [...current, option.optionId];
      }
      // a word only means something on a choice that is on the line
      final kept = _request.selections[group.groupId] ?? const <String>[];
      for (final o in group.options) {
        if (!kept.contains(o.optionId)) _request.prefixes.remove(o.optionId);
      }
    });
    _reprice();
  }

  /// The choices that differ from the menu's defaults, as the check lists them, each with its price; a
  /// marked choice is listed with its word even when it is the default ("No white rice"), and a choice left
  /// off ("no") is free, as the backend makes it.
  List<CheckModifier> get _picked => [
    for (final g in _detail?.groups ?? const <GroupDetail>[])
      for (final o in g.options)
        if ((_request.selections[g.groupId] ?? const []).contains(o.optionId) &&
            (_request.prefixes[o.optionId] != null || !o.isDefault))
          CheckModifier(
            _request.prefixes[o.optionId] == null ? o.name : '${instructions[_request.prefixes[o.optionId]]} ${o.name}',
            price: o.free || _request.prefixes[o.optionId] == 'no' ? '0.00' : o.price,
          ),
  ];

  /// A choice's chip: its word when it has one, and its price unless the word is "no" (the backend charges
  /// nothing for a choice left off).
  String _optionLabel(OptionDetail o) {
    final mark = _request.prefixes[o.optionId];
    final name = mark == null ? o.name : '${instructions[mark]} ${o.name}';
    return o.free || mark == 'no' ? name : '$name +${o.price}';
  }

  /// One tap for the kitchen's usual words. A word waits for the next choice tapped, then goes on it.
  Widget _instructionRow(ThemeData theme, ColorScheme scheme) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            for (final MapEntry(key: code, value: word) in instructions.entries)
              ChoiceChip(
                key: ValueKey('instruction:$code'),
                label: Text(word),
                selected: _armed == code,
                onSelected: (on) => setState(() => _armed = on ? code : null),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          _armed == null
              ? 'To mark a choice, tap a word and then the choice.'
              : 'Now tap the choice to mark “${instructions[_armed]}”.',
          style: theme.textTheme.bodySmall?.copyWith(color: _armed == null ? scheme.onSurfaceVariant : scheme.primary),
        ),
      ],
    ),
  );

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
      title: Row(
        children: [
          Expanded(
            child: Text(
              widget.entry.secondName == null ? widget.entry.name : '${widget.entry.name}  ${widget.entry.secondName}',
            ),
          ),
          if (widget.onEightySix != null)
            IconButton(
              tooltip: '86 ${widget.entry.name}',
              icon: const Icon(Icons.block, size: 18),
              onPressed: () {
                Navigator.of(context).pop();
                widget.onEightySix!();
              },
            ),
        ],
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
                    if (detail.groups.isNotEmpty) _instructionRow(theme, scheme),
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
                              label: Text(_optionLabel(o)),
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
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Text(
                                    '\$$total',
                                    style: theme.textTheme.titleLarge?.copyWith(
                                      fontWeight: FontWeight.w800,
                                      color: scheme.primary,
                                      fontFeatures: PosTheme.tabular,
                                    ),
                                  ),
                                  if (priced!.estimated)
                                    Text(
                                      'estimated',
                                      key: const ValueKey('price-estimated'),
                                      style: theme.textTheme.labelSmall?.copyWith(color: scheme.error),
                                    ),
                                ],
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
