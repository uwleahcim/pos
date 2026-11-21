import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api.dart';
import '../dish_names.dart';
import '../kitchen_notes.dart';
import '../live.dart';
import '../local_order.dart' show localPrice;
import '../menu.dart';
import '../menu_search.dart';
import 'drill_down.dart';
import 'tap_focus.dart';
import 'text_arrows.dart';
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
    this.zhName,
    this.wentWith,
  });

  /// What the line is recorded as: the dish's English name, whoever rings it in.
  final String name;

  /// The dish's Chinese name, where the menu holds one: what the check calls the line for a person who
  /// reads the names in Chinese (docs/dish-names.md). Never what is recorded.
  final String? zhName;
  final LineRequest request;
  final int qty;
  final String note;

  /// The price of one as the menu showed it, so the check can show the line before the hub prices it.
  final String? unitPrice;

  /// The choices that differ from the menu's defaults, each with the price of one, as the check lists them.
  final List<CheckModifier> modifiers;
  final String? itemId;

  /// The dish (its item code) whose suggestion this one was added from, in the tray "Goes with ..."; null
  /// for a dish rung any other way. The hub keeps it on the line for the report of suggestions taken
  /// (docs/goes-with.md); nothing else about the line is different.
  final String? wentWith;

  /// The same line as one taken from what goes with [dish].
  ChosenLine suggestedWith(String dish) => ChosenLine(
    name: name,
    request: request,
    qty: qty,
    note: note,
    unitPrice: unitPrice,
    modifiers: modifiers,
    itemId: itemId,
    zhName: zhName,
    wentWith: dish,
  );
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
///
/// With a keyboard (Mike, 2026-11-14): Down from the search field goes to the first tile under it, once the
/// cursor is at the end of what was typed (an arrow leaves a text box only when it can move the cursor no
/// further, [ArrowsLeaveTextBoxes]), and the arrows move from tile to tile. Enter on a tile that opens something takes the focus into what opened: a
/// category's first dish, the first choice a dish asks for. Once the choices are made and the dish is on the
/// order, the focus is back on the dish. Escape backs out of the level the focus is on, to the tile that
/// opened it, and closes whatever is open under that level: from the choices to the dish, from the dishes to
/// their category (the choices close too), from the categories to the search field. Delete or Backspace on a
/// dish takes one of it off the order ([onRemove]); in the search field they edit the text.
///
/// A touch or a click puts the focus on what was touched ([TapTakesFocus], around the whole app), so the
/// keyboard goes on from there. Only Enter moves the focus into what a tile opens: a tile touched or clicked
/// keeps it.
class MenuPanel extends StatefulWidget {
  const MenuPanel({super.key, required this.api, required this.onChosen, this.qtyOf, this.onRemove, this.by});

  /// How long the trays take to open, close or change size.
  static const transition = Duration(milliseconds: 280);

  final PosApi api;
  final ValueChanged<ChosenLine> onChosen;
  final int Function(MenuEntry entry)? qtyOf;

  /// Delete or Backspace pressed on a dish's tile: one of that dish comes off the order, if it is on it.
  final ValueChanged<MenuEntry>? onRemove;

  /// Who is at the screen, by name: the 86 board says who marked a dish sold out or typed its number left.
  final String? by;

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
  static const _offerGrid = 'offer'; // the grid of the dishes that go with a dish: its tiles and their focus

  List<Menu>? _menus;
  String? _menuCode; // the menu whose categories show (Food, Drinks, Lunch); the first one until a tab is tapped
  String? _error;
  var _path = <String>[]; // the open categories, outermost first, by section id
  List<MenuSection> _lastOpen = const []; // kept while the items tray animates closed
  final _itemCache = <String, ItemDetail>{};
  final _localCounts = <String, int>{}; // fallback item counts when widget.qtyOf is not provided
  final _tiles = <String, _Tiles>{}; // each grid's tiles as they were last built: see [_tilesOf]
  var _counted = 0; // goes up whenever the count on a tile may have changed: see [_tilesOf]
  (String, List<Menu>?, List<MenuEntry>)? _lastFound; // what the search last found, for what words on what menus
  (List<Menu>?, MenuSearch<MenuEntry>)? _searchable; // the dishes prepared for the search, for what menus
  (List<Menu>?, Map<String, List<(String, MenuEntry)>>)? _placed; // where each dish is, for what menus: [_places]
  (List<Menu>, String, Widget)? _tabsBuilt; // the tabs as last built, for which menus with which one on screen
  (bool, Widget)? _searchBuilt; // the search field as last built, with or without its Clear button
  (_PendingItemSelection, int, int, double, Widget)? _trayBuilt; // the choices tray as last built: see [_trayFor]
  var _answered = 0; // goes up with every answer given in the choices tray
  _PendingItemSelection? _pending;
  _PendingItemSelection? _lastPending; // kept while the required-selections tray animates closed
  _Offer? _offer; // the dishes that go with the dish rung last, in the same tray once it asks nothing: [_rung]
  _Offer? _lastOffer; // kept while that tray animates closed
  var _trayOffered = false; // what the tray showed last: the dishes that go with one, not a dish's choices
  int? _revision;
  DateTime _loadedAt = DateTime(0);
  Timer? _watch;
  // The hub tells the panel when the menu was saved or a dish 86'd; the timer only asks for the revision
  // while it cannot, and once a minute.
  late final _poll = SafetyPoll(widget.api.live, every: 12);
  StreamSubscription<LiveChange>? _live;
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

  // The keyboard. Every tile has a focus node of its own, named by the grid it is in and its key, so that the
  // focus can be sent to a tile that is only just coming on screen (the first dish of a category that opens)
  // and the panel knows which dish a key was pressed on. The three levels (the top grid, an open category's
  // dishes, a dish's choices) each sit in a node that says whether the focus is somewhere inside it.
  final _focus = <String, FocusNode>{};
  final _dishOf = <FocusNode, MenuEntry>{}; // the dish on each dish tile's node
  final _searchFocus = FocusNode(debugLabel: 'menu search');
  final _topLevel = FocusNode(debugLabel: 'menu top', canRequestFocus: false, skipTraversal: true);
  final _dishLevel = FocusNode(debugLabel: 'menu dishes', canRequestFocus: false, skipTraversal: true);
  final _choiceLevel = FocusNode(debugLabel: 'menu choices', canRequestFocus: false, skipTraversal: true);
  final _trayScroll = ScrollController();
  final _offerScroll = ScrollController();
  _Wanted? _wanted; // the tile the focus goes to as soon as it is on screen
  FocusNode? _toShow; // the tile that took the focus while the trays moved: brought into view once they rest
  var _keying = false; // a key is being handled right now: what a tile does this moment, the keyboard did
  var _columns = 1; // the grids as last laid out: how many tiles across, how tall each
  var _tileHeight = 0.0;

  _CategoryScrollController _itemsScrollFor(String sectionId) =>
      _itemsScrolls.putIfAbsent(sectionId, _CategoryScrollController.new);

  FocusNode _focusOf(String grid, String tile) =>
      _focus.putIfAbsent('$grid|$tile', () => FocusNode(debugLabel: '$grid|$tile'));

  static String _sectionKey(MenuSection s) => 's:${s.sectionId}';
  static String _entryKey(MenuEntry e) => 'e:${e.entryId}:${e.item}';

  static bool _sameEntry(MenuEntry a, MenuEntry b) => a.entryId == b.entryId && a.item == b.item;

  @override
  void initState() {
    super.initState();
    _load();
    unawaited(_readKitchenNotes());
    _watch = Timer.periodic(MenuPanelCheck.every, (_) => _check());
    _live = widget.api.live.changes.listen(_onLive);
  }

  /// The location's one-tap notes to the kitchen, read ahead once so a dish's sheet has its buttons at once
  /// (each sheet reads them again as it opens, so a change of the list needs no word from the hub's feed).
  /// With nothing answering the last list read stands.
  Future<void> _readKitchenNotes() async {
    try {
      await widget.api.kitchenNotes();
    } on ApiException {
      // the note is typed, as before
    }
  }

  /// The hub says the menu changed: a save moves the revision, an 86 does not, so the menu is read either
  /// way (the hub answers "the one you have" when it is). A feed that just connected says nothing about
  /// the menu, so the revision is asked for once.
  void _onLive(LiveChange change) {
    if (change.menu) {
      unawaited(_load());
    } else if (change.everything) {
      unawaited(_check(told: true));
    }
  }

  /// The screen above drew again: the order may have changed, and with it the counts on the tiles.
  @override
  void didUpdateWidget(MenuPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    _counted++;
  }

  @override
  void dispose() {
    _watch?.cancel();
    unawaited(_live?.cancel());
    _transition.dispose();
    _search.dispose();
    _categoriesScroll.dispose();
    _searchScroll.dispose();
    for (final c in _itemsScrolls.values) {
      c.dispose();
    }
    _trayScroll.dispose();
    _offerScroll.dispose();
    for (final node in [..._focus.values, _searchFocus, _topLevel, _dishLevel, _choiceLevel]) {
      node.dispose();
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
      _show();
    });
  }

  /// Sends the keyboard's focus to a tile. One that is not on screen yet takes it as soon as it is: a tray
  /// has no height in its first frame, and a grid only builds the tiles near what it shows, so a tile too far
  /// down ([index] is its place in the grid [scroll] moves) has its row scrolled to first.
  void _want(FocusNode node, {ScrollController? scroll, int index = 0}) {
    _wanted = _Wanted(node, scroll, index);
    _nextFrame();
  }

  void _nextFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _giveFocus());
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _giveFocus() {
    final wanted = _wanted;
    if (!mounted || wanted == null) return;
    // (a tile that was built and then scrolled away keeps its old context, so only a mounted one counts)
    if (wanted.node.context?.mounted ?? false) {
      _wanted = null;
      wanted.node.requestFocus();
      _toShow = wanted.node;
      if (!_transition.isAnimating) _show();
      return;
    }
    // Not built. While the trays move it may only need its tray to open; once they rest, its row is scrolled
    // to, and a tile that still is not there after a few frames is not coming (the menu changed under it).
    if (!_transition.isAnimating) {
      if (++wanted.tries > 4) {
        _wanted = null;
        return;
      }
      final scroll = _touched ? null : wanted.scroll;
      if (scroll != null && scroll.hasClients && scroll.position.haveDimensions) {
        final position = scroll.position;
        final row = wanted.index ~/ _columns;
        position.jumpTo((row * (_tileHeight + _gridSpacing)).clamp(position.minScrollExtent, position.maxScrollExtent));
      }
    }
    _nextFrame();
  }

  /// Whether the screen was touched last, not a key or the mouse: the focus shows no highlight then, and no
  /// grid scrolls to show where it went. A finger put it there; the screen stays as the finger left it.
  static bool get _touched => FocusManager.instance.highlightMode == FocusHighlightMode.touch;

  /// Whether what a tile does right now was done with the keyboard: Enter on [from], which has the focus,
  /// while that key is being handled ([_onKey]). A touch or a click on a tile that happens to have the focus
  /// is not.
  bool _byKey(FocusNode? from) => _keying && (from?.hasPrimaryFocus ?? false);

  /// Scrolls the tile that took the focus into view, if its grid shows only part of it.
  void _show() {
    final node = _toShow;
    _toShow = null;
    final context = node?.context;
    if (node == null || context == null || !context.mounted || !node.hasPrimaryFocus || _touched) return;
    for (final policy in const [
      ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
      ScrollPositionAlignmentPolicy.keepVisibleAtStart,
    ]) {
      unawaited(Scrollable.ensureVisible(context, alignmentPolicy: policy));
    }
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
        final shown = _offer;
        if (shown != null) {
          // the tray moves only if it now holds more or fewer dishes: a menu read again moves nothing else
          final now = _offerOn(shown);
          if (now?.entries.length != shown.entries.length) _startTransition(resetScroll: false);
          setState(() {
            _offer = now;
            if (now != null) _lastOffer = now;
          });
        }
      }
      unawaited(_prefetch(revision));
    } on ApiException catch (err) {
      if (mounted) setState(() => _error = err.toString());
    }
  }

  /// Saves every dish's sizes and choices with the menu, so the screen can still configure a dish when no
  /// backend answers (ADR 6). The device keeps them per menu revision, so this downloads nothing while the
  /// dishes of this revision are already saved: a panel opened for every order must not read ten megabytes
  /// and write 559 dishes each time (it did, and the screen froze for seconds). Quietly skipped when nothing
  /// answers or the hub is older than this call.
  Future<void> _prefetch(int revision) async {
    try {
      await widget.api.prefetchItems(revision: revision);
    } on ApiException {
      // next load tries again
    }
  }

  /// A manager saved the menu (or the hour changed the menus open): read it again, keeping the open category.
  Future<void> _check({bool told = false}) async {
    if (_menus == null) return _load();
    if (DateTime.now().difference(_loadedAt) >= MenuPanelCheck.reload) return _load();
    if (!told && !_poll.due()) return; // the hub would have said
    _poll.asked();
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
      _offer = null;
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
  /// found at the bar too. The best match comes first ([MenuSearch]: "beef broccoli" finds Beef with Broccoli,
  /// then the other beef dishes), so Down or Enter in the search field lands on it. A dish on two menus at
  /// the same sizes and prices (the soft drinks) is listed once, under its first menu; a dish the lunch menu
  /// sells as another size or price is listed from both.
  ///
  /// Looked up once for the words typed, not on every frame while a tray moves under the results.
  List<MenuEntry> get _found {
    final q = _search.text.trim().toLowerCase();
    final last = _lastFound;
    if (last != null && last.$1 == q && identical(last.$2, _menus)) return last.$3;
    final seen = <String>{};
    String offer(MenuEntry e) => '${e.item}|${e.variants.map((v) => '${v.variantId}=${v.price}').join(',')}';
    final found = [
      for (final e in _dishes.find(q))
        if (seen.add(offer(e))) e,
    ];
    _lastFound = (q, _menus, found);
    return found;
  }

  /// The dishes the search looks through, in the menus' order: prepared once for the menus as they were
  /// read, not on every key pressed.
  MenuSearch<MenuEntry> get _dishes {
    final last = _searchable;
    if (last != null && identical(last.$1, _menus)) return last.$2;
    final dishes = MenuSearch<MenuEntry>([
      for (final m in _openMenus)
        for (final s in m.sections) ...s.allEntries,
    ], (e) => SearchText(number: e.number, names: [e.name, e.secondName], labels: [e.kitchenName]));
    _searchable = (_menus, dishes);
    return dishes;
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
  ///
  /// [from] is the tile it was opened from. Opened with the keyboard (Enter on that tile), the focus goes to
  /// the first of what opened. Touched or clicked, the focus is the tile's ([TapTakesFocus]) and stays with
  /// it: a category inside a category shows among the categories above once it is open, and the focus goes
  /// there with it.
  void _openAt(int depth, MenuSection section, {FocusNode? from}) {
    final keyed = _byKey(from);
    final currentDepth = _open.isEmpty ? 0 : _open.length - 1;
    _startTransition(resetScroll: depth != currentDepth, resetItemsSectionId: section.sectionId);
    setState(() {
      _path = [..._path.take(depth), section.sectionId];
      _pending = null;
      _offer = null;
      _search.clear();
    });
    if (!keyed) {
      final shown = _focusOf('categories-$depth', _sectionKey(section));
      if (from != null && from != shown) _want(shown);
      return;
    }
    final first = section.sections.isNotEmpty
        ? _sectionKey(section.sections.first)
        : section.entries.isNotEmpty
        ? _entryKey(section.entries.first)
        : null;
    if (first != null) {
      _want(_focusOf('items-${section.sectionId}', first), scroll: _itemsScrollFor(section.sectionId));
    }
  }

  /// Closes the open category (the innermost one). Closed from its own tile ([from]: Enter on it, a touch or
  /// a click), the focus stays with that tile where it shows now.
  void _close({FocusNode? from}) => _closeTo(_open.length - 1, focus: from != null);

  /// Backs out to the first [keep] open categories: the ones under them close, and a dish's choices with
  /// them. With [focus], the keyboard's focus goes to the tile of the category that closed, where it shows now:
  /// among the top categories, or among the dishes of the category it is in.
  void _closeTo(int keep, {bool focus = false}) {
    final open = _open;
    if (keep < 0 || keep >= open.length) return;
    _startTransition(resetScroll: math.max(0, keep - 1) != open.length - 1);
    setState(() {
      _path = [for (final s in open.take(keep)) s.sectionId];
      _pending = null;
      _offer = null;
    });
    if (!focus) return;
    final closed = open[keep];
    if (keep == 0) {
      _want(_focusOf('categories-0', _sectionKey(closed)), scroll: _categoriesScroll, index: _top.indexOf(closed));
    } else {
      final parent = open[keep - 1];
      _want(
        _focusOf('items-${parent.sectionId}', _sectionKey(closed)),
        scroll: _itemsScrollFor(parent.sectionId),
        index: parent.sections.indexOf(closed),
      );
    }
  }

  void _openPending(_PendingItemSelection pending) {
    _startTransition(resetScroll: false);
    setState(() {
      _pending = pending;
      _lastPending = pending;
      // another dish from the menu: what went with the one before is over. A suggested dish asking its
      // size keeps the suggestions, which are back in the tray once it is answered.
      if (!pending.offered) _offer = null;
    });
  }

  void _closePending() {
    if (_pending == null) return;
    _startTransition(resetScroll: false);
    setState(() => _pending = null);
  }

  void _closeOffer() {
    if (_offer == null) return;
    _startTransition(resetScroll: false);
    setState(() => _offer = null);
  }

  /// Every place a dish has on the menus open now, by its item code: where the dishes that go with a dish are
  /// looked up. Prepared once for the menus as they were read.
  Map<String, List<(String, MenuEntry)>> get _places {
    final last = _placed;
    if (last != null && identical(last.$1, _menus)) return last.$2;
    final places = <String, List<(String, MenuEntry)>>{};
    for (final m in _openMenus) {
      for (final s in m.sections) {
        for (final e in s.allEntries) {
          places.putIfAbsent(e.item, () => []).add((m.menu, e));
        }
      }
    }
    _placed = (_menus, places);
    return places;
  }

  /// The dishes the menu says go with [rung], as they can be rung right now, in the order the manager put
  /// them: each where it is on the menu on screen, else on another menu that is open (a beer with the duck,
  /// from the Drinks tab). One that is on no open menu, or sold out, is not suggested.
  List<MenuEntry> _goingWith(MenuEntry rung) {
    if (rung.goesWith.isEmpty) return const [];
    final here = _menu?.menu;
    final places = _places;
    final out = <MenuEntry>[];
    for (final code in rung.goesWith) {
      final sold = [
        for (final place in places[code] ?? const <(String, MenuEntry)>[])
          if (place.$2.available) place,
      ];
      final entry = (sold.where((place) => place.$1 == here).firstOrNull ?? sold.firstOrNull)?.$2;
      if (entry != null && !out.any((e) => e.item == entry.item)) out.add(entry);
    }
    return out;
  }

  /// A dish from the menu just went on the order ([tile] is its tile): the dishes the menu says go with it
  /// open in the tray under the dishes, each as its own tile, one tap to add. Only a suggestion: nothing goes
  /// on the order by itself, and a dish that names none opens nothing. Another of the same dish leaves the
  /// tray as it is; another dish replaces it with its own, or closes it.
  ///
  /// A dish rung from that tray ([offered]) changes nothing here: what was suggested suggests nothing
  /// further, and the tray stays for the next of them.
  void _rung(MenuEntry entry, {FocusNode? tile, bool offered = false}) {
    if (offered || !mounted) return;
    final with_ = _goingWith(entry);
    final open = _offer;
    if (with_.isEmpty) {
      _closeOffer();
      return;
    }
    if (open != null && _sameEntry(open.of, entry) && listEquals(open.entries, with_)) return;
    final offer = _Offer(entry, with_, tile);
    _startTransition(resetScroll: false);
    setState(() {
      _offer = offer;
      _lastOffer = offer;
    });
  }

  /// The menu was read again while the tray showed what goes with a dish: the same dish as the menu has it
  /// now, with what goes with it now (a dish just 86'd is gone from the tray, one a manager added is in it).
  _Offer? _offerOn(_Offer? offer) {
    if (offer == null) return null;
    final of = (_places[offer.of.item] ?? const <(String, MenuEntry)>[])
        .map((place) => place.$2)
        .where((e) => _sameEntry(e, offer.of))
        .firstOrNull;
    if (of == null) return null;
    final with_ = _goingWith(of);
    return with_.isEmpty ? null : _Offer(of, with_, offer.tile);
  }

  void _choose(ChosenLine chosen) {
    final key = '${chosen.request.entryId ?? ''}:${chosen.itemId ?? ''}';
    setState(() {
      _localCounts[key] = (_localCounts[key] ?? 0) + chosen.qty;
      _counted++;
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
    _settlePending(pending);
  }

  void _togglePendingOption(_Ask ask, OptionDetail option) {
    final pending = _pending;
    if (pending == null || !option.available) return;
    pending.toggle(ask, option);
    _settlePending(pending, answered: ask.answered);
  }

  /// A hold on a choice that is a dish: that dish's own sheet, every choice on it and a note to the kitchen,
  /// as a hold on its menu tile would open it. Done chooses the dish with what was picked there.
  Future<void> _longPressPendingOption(_Ask ask, OptionDetail option) async {
    final pending = _pending;
    if (pending == null || !option.available || !option.isDish) return;
    final inside = await showDialog<Choices>(
      context: context,
      builder: (_) => DishChoicesSheet(
        option: option,
        initial: ask.choices.nested[option.optionId],
        kitchenNotes: widget.api.kitchenNotesKnown,
      ),
    );
    if (inside == null || !mounted || _pending != pending) return;
    pending.answered(ask, option, inside);
    _settlePending(pending);
  }

  /// The tray closes and the dish goes on the order once nothing is left to ask; otherwise it shows the rest.
  ///
  /// Once the dish is on the order the focus is on its tile, for one more of it or the next dish: the choice
  /// that was picked, with the keyboard, a finger or the mouse, is gone with the tray. While questions are
  /// left, a choice picked with the keyboard moves the focus on to the first of them as soon as the one just
  /// picked in has its answer ([answered]), and leaves it put while that one wants more; a choice touched or
  /// clicked keeps the focus ([TapTakesFocus]).
  void _settlePending(_PendingItemSelection pending, {bool answered = true}) {
    final keyed = _keying && _choiceLevel.hasFocus;
    if (pending.isComplete) {
      final chosen = pending.toChosenLine();
      _closePending();
      _choose(chosen);
      _rung(pending.entry, tile: pending.tile, offered: pending.offered);
      final tile = pending.tile;
      if (tile != null) _want(tile);
    } else {
      setState(() => _answered++);
      if (keyed && answered) _focusOpenChoice(pending);
    }
  }

  /// The focus goes to the first choice of the first question the tray still asks.
  void _focusOpenChoice(_PendingItemSelection pending) {
    final next = pending.firstOpen;
    if (next != null) _want(_focusOf('tray', next.$1), scroll: _trayScroll, index: next.$2);
  }

  /// The focus goes to the first tile under the search field: what it found, or the first category. False
  /// when there is none.
  bool _focusFirstOfTop() {
    final open = _open;
    if (open.isEmpty && _search.text.trim().isNotEmpty) {
      final found = _found;
      if (found.isNotEmpty) _want(_focusOf('search', _entryKey(found.first)), scroll: _searchScroll);
      return found.isNotEmpty;
    }
    final depth = open.isEmpty ? 0 : open.length - 1;
    final siblings = depth == 0 ? _top : open[depth - 1].sections;
    final first = siblings.isNotEmpty
        ? _sectionKey(siblings.first)
        : depth == 0 && _topEntries.isNotEmpty
        ? _entryKey(_topEntries.first)
        : null;
    if (first != null) _want(_focusOf('categories-$depth', first), scroll: _categoriesScroll);
    return first != null;
  }

  /// Enter (or the on-screen keyboard's Done) in the search field goes to what was found, like Down. With
  /// nothing found it only lets go of the field, as it always did.
  void _submitSearch() {
    if (!_focusFirstOfTop()) _searchFocus.unfocus();
  }

  void _clearSearch() => setState(() {
    _search.clear();
    _pending = null;
    _offer = null;
  });

  /// The field's Clear button: the button goes away with the text, so the focus (its own while it was being
  /// pressed, [TapTakesFocus]) goes to the field it cleared, ready for the next search.
  void _clearFromButton() {
    _clearSearch();
    _want(_searchFocus);
  }

  /// Keys pressed with the focus anywhere in the menu: see [MenuPanel]. What is not for the menu goes on to
  /// whoever has it next (the search field edits its text with Backspace and Delete as it always did).
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    final down = event is KeyDownEvent;
    if (event is! KeyUpEvent && !_keying) {
      _keying = true;
      scheduleMicrotask(() => _keying = false);
    }
    if (key == LogicalKeyboardKey.escape) {
      return down && _backOut() ? KeyEventResult.handled : KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.backspace || key == LogicalKeyboardKey.delete) {
      final dish = _dishOf[FocusManager.instance.primaryFocus];
      if (dish == null || widget.onRemove == null) return KeyEventResult.ignored;
      // one press, one dish: a key held down does not empty the order
      if (down) widget.onRemove!(dish);
      return KeyEventResult.handled;
    }
    // Down in the search field, once the cursor is at the end of what was typed and has nowhere left to go
    // (the rule of every text box, see [ArrowsLeaveTextBoxes]): to the first tile under the field, which may
    // have to be scrolled to. The other arrows leave the field by that rule, to whatever is that way.
    if (key == LogicalKeyboardKey.arrowDown &&
        _searchFocus.hasPrimaryFocus &&
        ArrowsLeaveTextBoxes.isPlainPress(event) &&
        ArrowsLeaveTextBoxes.cursorAtEdge(_search.value, TraversalDirection.down) &&
        _focusFirstOfTop()) {
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Escape: out of the level the focus is on, onto the tile that opened it, and whatever is open under that
  /// level closes too. From a dish's choices to the dish; from a category's dishes to the category (the
  /// choices close with them); from sub-categories to the category they are in; from the top of the menu to
  /// the search field, where it clears what was typed. False when there is nothing to back out of.
  bool _backOut() {
    final open = _open;
    if (_choiceLevel.hasFocus) {
      final offer = _offer;
      if (_pending == null && offer != null) {
        // from the dishes that go with a dish, back to that dish
        _closeOffer();
        if (offer.tile != null) _want(offer.tile!);
        return true;
      }
      final tile = (_pending ?? _lastPending)?.tile;
      _closePending();
      if (tile != null) _want(tile);
      return true;
    }
    if (_dishLevel.hasFocus && open.isNotEmpty) {
      _closeTo(open.length - 1, focus: true);
      return true;
    }
    if (_topLevel.hasFocus) {
      if (open.length > 1) {
        _closeTo(open.length - 2, focus: true);
        return true;
      }
      if (open.isNotEmpty) {
        _closeTo(0);
      } else {
        _closePending();
        _closeOffer();
      }
      _want(_searchFocus);
      return true;
    }
    if (_searchFocus.hasPrimaryFocus && !_search.value.composing.isValid) {
      if (open.isNotEmpty) {
        _closeTo(0);
        return true;
      }
      if (_pending == null && _offer == null && _search.text.isEmpty) return false;
      _clearSearch();
      return true;
    }
    return false;
  }

  /// The 86 board from the order screen: mark a size sold out or back, or type how many are left.
  Future<void> _eightySix(MenuEntry entry) async {
    await showDialog<void>(
      context: context,
      builder: (context) => EightySixDialog(api: widget.api, entry: entry, by: widget.by),
    );
    await _load();
  }

  /// Tapping an item auto-adds it immediately when all required selections already have defaults
  /// (or when it has only one size and no options). When required selections are still needed
  /// (such as choosing a size or a required modifier group with no defaults), it expands the
  /// inline required-selections section below. A dish whose price is typed when it is rung (a market
  /// price, an off-menu dish) opens its sheet, which asks for it.
  ///
  /// [from] is the tile tapped. When Enter was pressed on it, the focus goes into the choices that open; it
  /// is back on the tile once they are made ([_settlePending]). Touched or clicked, the tile keeps the focus.
  ///
  /// Once the dish is on the order, the dishes the menu says go with it open in the tray ([_rung]); a dish
  /// tapped there is [offered], and is rung the same way without suggesting anything itself.
  Future<void> _tap(MenuEntry entry, {FocusNode? from, bool offered = false}) async {
    if (!entry.available) return;
    final keyed = _byKey(from);
    final wentWith = _offeredWith(offered);
    if (_pending != null && _pending!.entry == entry) {
      _closePending();
      return;
    }
    final availableVariants = [
      for (final v in entry.variants)
        if (v.available) v,
    ];
    if (availableVariants.isEmpty) return;
    if (entry.asksPrice) {
      // its price, or what it is and its price, has to be typed: the dish's own sheet asks, a tap or a hold
      await _longPress(entry, from: from, offered: offered);
      return;
    }

    ItemDetail? detail;
    final choices = Choices();
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
      fillDefaults(detail.groups, choices);
      for (final g in detail.groups) {
        if (g.required && choices.units(g.groupId) < g.minSelect) requiredGroups.add(g);
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
      choices: choices,
      tile: from,
      offered: offered,
      wentWith: wentWith,
    );

    if (pending.isComplete) {
      if (_pending != null) _closePending();
      _choose(pending.toChosenLine());
      _rung(entry, tile: from, offered: offered);
      return;
    }

    _openPending(pending);
    if (keyed) _focusOpenChoice(pending);
  }

  /// Long-pressing an item opens the popup [ItemSheet] to customize modifiers, size, quantity, or note.
  Future<void> _longPress(MenuEntry entry, {FocusNode? from, bool offered = false}) async {
    if (!entry.available) {
      await _eightySix(entry);
      return;
    }
    if (_pending != null) _closePending();
    final wentWith = _offeredWith(offered);
    final chosen = await showDialog<ChosenLine>(
      context: context,
      builder: (_) => ItemSheet(api: widget.api, entry: entry, onEightySix: () => _eightySix(entry)),
    );
    if (chosen == null) return;
    _choose(wentWith == null ? chosen : chosen.suggestedWith(wentWith));
    _rung(entry, tile: from, offered: offered);
  }

  /// The dish whose suggestions the tray shows, by its item code, for a tile tapped there ([offered]): what
  /// the line says it went with. Read when the tile is tapped, not when it was built: the tiles are kept
  /// while the same dishes are suggested, and two dishes can suggest the same ones.
  String? _offeredWith(bool offered) => offered ? (_offer ?? _lastOffer)?.of.item : null;

  /// The tiles of one grid (`grid` names it: the categories, the open category's dishes, what the search
  /// found).
  ///
  /// While a tray opens or closes this panel is drawn again on every frame, to move the trays, and nothing
  /// on a tile changes in between. Handed the list it already has, a grid does not go through its tiles at
  /// all; handed new tiles, even ones that look the same, it builds every one of them again with everything
  /// inside: over 800 widgets a frame with a full category open, measured 2026-11-12, which is where the
  /// frames went on a slow tablet. So the tiles are kept, and a tile is built again only when what it shows
  /// changes: the dish itself (a new menu, an 86), whether it is the open one, its count from the check. A
  /// dish added to the check builds one tile, not the category.
  ///
  /// [focus] names the grid for the tiles' focus nodes: the same dish in the search and in its category is
  /// two tiles, each with its own.
  List<Widget> _tilesOf(
    String grid, {
    required String focus,
    required List<MenuSection> sections,
    required List<MenuEntry> entries,
    required int depth,
    MenuSection? selected,
  }) {
    final pending = _pending;
    final asking = pending == null ? -1 : entries.indexWhere((e) => _sameEntry(pending.entry, e));
    final last = _tiles[grid];
    final sameTiles =
        last != null &&
        last.focus == focus &&
        listEquals(last.sections, sections) &&
        listEquals(last.entries, entries) &&
        last.depth == depth;
    final sameState = sameTiles && last.selected == selected && last.asking == asking;
    if (sameState && last.counted == _counted) return last.widgets;
    // The counts are read from the check only when the check may have changed, not on every frame.
    final qty = [for (final e in entries) _qtyOf(e)];
    if (sameState && listEquals(last.qty, qty)) {
      last.counted = _counted;
      return last.widgets;
    }
    final widgets = <Widget>[
      for (final (i, s) in sections.indexed)
        if (sameTiles && (s == selected) == (s == last.selected))
          last.widgets[i]
        else
          _sectionTile(focus, depth, s, i, selected: s == selected),
      for (final (i, e) in entries.indexed)
        if (sameTiles && qty[i] == last.qty[i] && (i == asking) == (i == last.asking))
          last.widgets[sections.length + i]
        else
          _entryTile(focus, e, qty: qty[i], selected: i == asking),
    ];
    _tiles[grid] = _Tiles(
      focus: focus,
      sections: sections,
      entries: entries,
      depth: depth,
      selected: selected,
      asking: asking,
      qty: qty,
      counted: _counted,
      widgets: widgets,
    );
    return widgets;
  }

  Widget _sectionTile(String grid, int depth, MenuSection s, int index, {required bool selected}) {
    final node = _focusOf(grid, _sectionKey(s));
    return _SectionButton(
      key: ValueKey(_sectionKey(s)),
      section: s,
      index: index,
      selected: selected,
      focusNode: node,
      onTap: selected ? () => _close(from: node) : () => _openAt(depth, s, from: node),
    );
  }

  Widget _entryTile(String grid, MenuEntry e, {required int qty, required bool selected}) {
    final node = _focusOf(grid, _entryKey(e));
    _dishOf[node] = e;
    final offered = grid == _offerGrid; // a tile of the tray that says what goes with a dish
    return _EntryButton(
      key: ValueKey(_entryKey(e)),
      entry: e,
      qty: qty,
      selected: selected,
      focusNode: node,
      onTap: () => _tap(e, from: node, offered: offered),
      onLongPress: () => _longPress(e, from: node, offered: offered),
    );
  }

  Widget _searchField(bool searching) {
    final last = _searchBuilt;
    if (last != null && last.$1 == searching) return last.$2;
    final field = Center(
      child: TextField(
        controller: _search,
        focusNode: _searchFocus,
        decoration: InputDecoration(
          prefixIcon: const Icon(Icons.search),
          suffixIcon: searching
              ? IconButton(tooltip: 'Clear', icon: const Icon(Icons.close), onPressed: _clearFromButton)
              : null,
          hintText: 'Number or name',
          isDense: true,
        ),
        onEditingComplete: _submitSearch,
        onChanged: (_) => setState(() {
          _pending = null;
          _offer = null;
        }),
      ),
    );
    _searchBuilt = (searching, field);
    return field;
  }

  /// The tray that asks a dish's size and choices, the same widget until an answer changes what it shows:
  /// every roll of the maki combination is a button in it, and none of them changes while the tray opens.
  Widget _trayFor(_PendingItemSelection pending, int crossAxisCount, double tileHeight) {
    final last = _trayBuilt;
    if (last != null &&
        identical(last.$1, pending) &&
        last.$2 == _answered &&
        last.$3 == crossAxisCount &&
        last.$4 == tileHeight) {
      return last.$5;
    }
    final tray = _RequiredSelectionsSection(
      pending: pending,
      crossAxisCount: crossAxisCount,
      tileHeight: tileHeight,
      onSelectVariant: _selectPendingVariant,
      onToggleOption: _togglePendingOption,
      onLongPressOption: _longPressPendingOption,
      onClose: _closePending,
      scroll: _trayScroll,
      focusOf: (tile) => _focusOf('tray', tile),
    );
    _trayBuilt = (pending, _answered, crossAxisCount, tileHeight, tray);
    return tray;
  }

  Widget _tabsFor(List<Menu> menus, String selected) {
    final last = _tabsBuilt;
    if (last != null && identical(last.$1, menus) && last.$2 == selected) return last.$3;
    final tabs = _MenuTabs(menus: menus, selected: selected, onSelected: _showMenu);
    _tabsBuilt = (menus, selected, tabs);
    return tabs;
  }

  Widget _grid({
    required String tiles,
    required String focus,
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
    children: _tilesOf(tiles, focus: focus, sections: sections, entries: entries, depth: depth, selected: selected),
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
        _columns = crossAxisCount;
        _tileHeight = tileHeight;
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

        // The tray under the dishes: a dish's size and choices while one asks, else the dishes that go with
        // the dish rung last ([_rung]). One tray, so the two never stack on a phone.
        double targetRequiredHeight = 0.0;
        final pending = _pending;
        final offer = pending == null ? _offer : null;
        if (pending != null || offer != null) {
          final double neededRequiredHeight;
          if (pending != null) {
            final requiredCount =
                (pending.needsVariant ? pending.availableVariants.length : 0) +
                pending.asks.fold<int>(0, (sum, a) => sum + a.group.options.length);
            final requiredRows = requiredCount == 0 ? 1 : (requiredCount / crossAxisCount).ceil();
            neededRequiredHeight = _itemsDividerHeight + gridHeightForRows(requiredRows);
          } else {
            final rows = (offer!.entries.length / crossAxisCount).ceil();
            neededRequiredHeight = _GoesWithSection.heightOver(context) + gridHeightForRows(rows);
          }
          _trayOffered = pending == null;
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
        // while the tray closes it still shows what it showed last
        final displayPending = pending ?? (_trayOffered ? null : _lastPending);
        final displayOffer = offer ?? (pending == null && _trayOffered ? _lastOffer : null);
        // the dish the tray is about stays in view while the tray opens under it
        final subject = pending?.entry ?? offer?.of;

        final pendingTopIndex = subject != null && here == null
            ? topEntries.indexWhere((e) => _sameEntry(e, subject))
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
                selectedTileIndex: subject != null ? found.indexWhere((e) => _sameEntry(e, subject)) : -1,
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
          final entryIdx = subject != null ? displayHere.entries.indexWhere((e) => _sameEntry(e, subject)) : -1;
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

        // The field and the tabs are the same widgets from frame to frame, like the tiles ([_tilesOf]): only
        // the fade and the heights around them move.
        // Faded out (a category is open), the field takes no taps, and the arrows do not stop on it either.
        final searchField = Opacity(
          opacity: currentSearchFactor,
          child: ExcludeFocusTraversal(
            excluding: currentSearchFactor < 0.5,
            child: IgnorePointer(ignoring: currentSearchFactor < 0.5, child: _searchField(searching)),
          ),
        );

        // Each part has a key of its own: the top row and the trays come and go, and without keys the grids
        // after them would be taken for other widgets and built from nothing, every tile, in a single frame.
        final column = Column(
          children: [
            if (showTop)
              SizedBox(
                key: const ValueKey('menu-top'),
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
                                _tabsFor(tabs, _menu!.menu),
                                const SizedBox(width: 8),
                                Expanded(child: searchField),
                              ],
                            ),
                    ),
                  ),
                ),
              ),
            SizedBox(
              key: const ValueKey('menu-categories'),
              height: currentCategoriesHeight,
              child: _level(
                _topLevel,
                searching
                    ? _grid(
                        tiles: 'search',
                        focus: 'search',
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
                        tiles: 'categories',
                        focus: 'categories-$depth',
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
            ),
            if (currentItemsHeight > 0.5 && displayHere != null)
              SizedBox(
                key: const ValueKey('menu-dishes'),
                height: currentItemsHeight,
                child: ClipRect(
                  child: OverflowBox(
                    alignment: Alignment.topCenter,
                    minHeight: math.max(currentItemsHeight, _itemsDividerHeight + 1.0),
                    maxHeight: math.max(currentItemsHeight, _itemsDividerHeight + 1.0),
                    child: ColoredBox(
                      color: Theme.of(context).colorScheme.surfaceContainerLow,
                      child: _level(
                        _dishLevel,
                        DrillDown(
                          onClose: _close,
                          header: const Divider(height: _itemsDividerHeight, thickness: _itemsDividerHeight),
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 200),
                            switchInCurve: Curves.easeOutCubic,
                            switchOutCurve: Curves.easeInCubic,
                            child: _grid(
                              tiles: 'items',
                              focus: 'items-${displayHere.sectionId}',
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
                    child: _level(_choiceLevel, _trayFor(displayPending, crossAxisCount, tileHeight)),
                  ),
                ),
              )
            else if (currentRequiredHeight > 0.5 && displayOffer != null)
              SizedBox(
                key: const ValueKey('goes-with'),
                height: currentRequiredHeight,
                child: ClipRect(
                  child: OverflowBox(
                    alignment: Alignment.topCenter,
                    // never laid out shorter than its own top line: while the tray opens and closes that
                    // line is cut by the tray's edge, not squeezed
                    minHeight: math.max(currentRequiredHeight, _GoesWithSection.least(context)),
                    maxHeight: math.max(currentRequiredHeight, _GoesWithSection.least(context)),
                    child: _level(
                      _choiceLevel,
                      // While the trays move a tile here is not where it was a moment ago: a second tap meant
                      // for the dish above (two of it, quickly) must not ring a suggestion instead.
                      IgnorePointer(
                        ignoring: _transition.isAnimating,
                        child: _GoesWithSection(
                          of: displayOffer.of,
                          crossAxisCount: crossAxisCount,
                          tileHeight: tileHeight,
                          onClose: _closeOffer,
                          scroll: _offerScroll,
                          tiles: _tilesOf(
                            _offerGrid,
                            focus: _offerGrid,
                            sections: const [],
                            entries: displayOffer.entries,
                            depth: 0,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
        // every key pressed with the focus in the menu passes here on its way up: [_onKey]
        return Focus(
          canRequestFocus: false,
          skipTraversal: true,
          includeSemantics: false,
          onKeyEvent: _onKey,
          child: column,
        );
      },
    );
  }

  /// One level of the menu, in the node that says whether the keyboard's focus is somewhere in it.
  Widget _level(FocusNode node, Widget child) =>
      Focus(focusNode: node, canRequestFocus: false, skipTraversal: true, includeSemantics: false, child: child);
}

/// A tile the keyboard's focus is to go to ([_MenuPanelState._want]).
class _Wanted {
  _Wanted(this.node, this.scroll, this.index);

  final FocusNode node;
  final ScrollController? scroll; // the grid the tile is in, and its place there
  final int index;
  var tries = 0; // frames it was looked for since the trays came to rest
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

/// One grid's tiles as they were last built, and what they were built from ([_MenuPanelState._tilesOf]).
class _Tiles {
  _Tiles({
    required this.focus,
    required this.sections,
    required this.entries,
    required this.depth,
    required this.selected,
    required this.asking,
    required this.qty,
    required this.counted,
    required this.widgets,
  });

  final String focus; // the grid the tiles' focus nodes are named by
  final List<MenuSection> sections;
  final List<MenuEntry> entries;
  final int depth;
  final MenuSection? selected;
  final int asking; // which of the dishes has its size or choices asked in the tray below, or -1
  final List<int> qty; // the count on each dish's tile
  int counted; // [_MenuPanelState._counted] when the counts were last read
  final List<Widget> widgets;
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
    this.focusNode,
  });

  final MenuSection section;
  final int index;
  final bool selected;
  final VoidCallback onTap;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final count = section.allEntries.length;
    final (name, _) = namesShown(section.name, section.secondName, chineseFirst: DishLanguage.chineseOf(context));
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
            focusNode: focusNode,
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      name,
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

/// A dish tapped on the grid whose tap could not add it yet: the size or the required choices it still needs,
/// asked in the tray under the dishes. A choice that is a dish (a roll of the maki combination) brings that
/// dish's defaults and asks, under it, what they leave open ("Kappa Maki · Sauce"); the tray grows and shrinks
/// with the questions. Once everything is answered the line goes on the check.
class _PendingItemSelection {
  _PendingItemSelection({
    required this.entry,
    this.detail,
    required this.availableVariants,
    required this.needsVariant,
    this.selectedVariantId,
    required this.requiredGroups,
    required this.choices,
    this.tile,
    this.offered = false,
    this.wentWith,
  }) {
    _askPicked(detail?.groups ?? const [], choices, '');
  }

  /// The focus node of the tile that was tapped: the keyboard's focus goes back to it from the tray.
  final FocusNode? tile;

  /// It was tapped among the dishes that go with another dish: once it is on the order those are back in the
  /// tray, and it suggests nothing itself ([_MenuPanelState._rung]).
  final bool offered;

  /// That other dish, by its item code: what the line says it went with ([ChosenLine.wentWith]).
  final String? wentWith;

  static String variantKey(VariantOffer v) => 'req-variant:${v.variantId}';
  static String optionKey(_Ask ask, OptionDetail o) => 'req-option:${ask.path}${ask.group.groupId}:${o.optionId}';

  /// The first choice of the first question still open, by its button's key and its place among the tray's
  /// buttons (the sizes first, then each question's choices): where the keyboard's focus goes next.
  (String, int)? get firstOpen {
    var at = 0;
    if (needsVariant) {
      if (selectedVariantId == null) {
        for (final (i, v) in availableVariants.indexed) {
          if (v.available) return (variantKey(v), i);
        }
      }
      at = availableVariants.length;
    }
    for (final ask in asks) {
      if (!ask.answered) {
        for (final (i, o) in ask.group.options.indexed) {
          if (o.available) return (optionKey(ask, o), at + i);
        }
      }
      at += ask.group.options.length;
    }
    return null;
  }

  final MenuEntry entry;
  final ItemDetail? detail;
  final List<VariantOffer> availableVariants;
  final bool needsVariant;
  String? selectedVariantId;

  /// The dish's own required groups that its defaults do not answer.
  final List<GroupDetail> requiredGroups;
  final Choices choices;

  /// For each chosen choice that is a dish (by its path of option ids): that dish's required groups its
  /// defaults did not answer, asked under it for as long as it stays chosen.
  final Map<String, List<GroupDetail>> _nestedAsks = {};

  /// Every question the tray asks, the dish's own first, then those on each chosen dish in menu order.
  List<_Ask> get asks => [
    for (final g in requiredGroups) _Ask(g, choices, path: ''),
    ..._asksInside(detail?.groups ?? const [], choices, ''),
  ];

  List<_Ask> _asksInside(List<GroupDetail> groups, Choices choices, String path) => [
    for (final g in groups)
      for (final o in g.options)
        if (o.groups.isNotEmpty && choices.picked(g.groupId, o.optionId)) ...[
          for (final ng in _nestedAsks['$path${o.optionId}'] ?? const <GroupDetail>[])
            _Ask(ng, choices.inside(o.optionId), path: '$path${o.optionId}/', under: o.name),
          ..._asksInside(o.groups, choices.inside(o.optionId), '$path${o.optionId}/'),
        ],
  ];

  void _askPicked(List<GroupDetail> groups, Choices choices, String path) {
    for (final g in groups) {
      for (final o in g.options) {
        if (o.groups.isEmpty || !choices.picked(g.groupId, o.optionId)) continue;
        _askInside(o, choices, '$path${o.optionId}');
        _askPicked(o.groups, choices.inside(o.optionId), '$path${o.optionId}/');
      }
    }
  }

  /// A dish was chosen as a choice: it comes with its defaults, and what they leave open is asked under it.
  void _askInside(OptionDetail option, Choices choices, String key) {
    final inside = choices.inside(option.optionId);
    if (inside.selections.isEmpty) fillDefaults(option.groups, inside);
    _nestedAsks[key] = [
      for (final g in option.groups)
        if (g.required && inside.units(g.groupId) < g.minSelect) g,
    ];
  }

  /// A tap on a choice in the tray: a single-pick group takes it, a multi-pick group adds or removes it up to
  /// its limit. A choice that is a dish starts asking that dish's open questions; one taken off stops.
  void toggle(_Ask ask, OptionDetail option) {
    final group = ask.group;
    final choices = ask.choices;
    final current = choices.selections[group.groupId] ?? const <String>[];
    if (group.single) {
      choices.selections[group.groupId] = [option.optionId];
    } else if (current.contains(option.optionId)) {
      // where the group takes several of one choice, a tap on a chosen one adds another while there is room
      if (!choices.addOne(group, option)) {
        choices.selections[group.groupId] = [...current]..remove(option.optionId);
      }
    } else if (choices.room(group)) {
      choices.selections[group.groupId] = [...current, option.optionId];
    }
    choices.settle(group);
    _followPicks(ask, group);
  }

  /// The dish's own sheet answered for a choice that is a dish: its choices are taken as they are and the
  /// dish is chosen, so the tray asks about it only what the sheet left open, which is nothing.
  void answered(_Ask ask, OptionDetail option, Choices inside) {
    ask.choices.nested[option.optionId] = inside;
    ask.choices.take(ask.group, option.optionId);
    _nestedAsks.remove('${ask.path}${option.optionId}'); // asked again from what the sheet chose
    _followPicks(ask, ask.group);
  }

  /// After a pick in [group]: a dish now chosen starts asking its open questions, one taken off stops.
  void _followPicks(_Ask ask, GroupDetail group) {
    final choices = ask.choices;
    for (final o in group.options) {
      if (o.groups.isEmpty) continue;
      final key = '${ask.path}${o.optionId}';
      if (!choices.picked(group.groupId, o.optionId)) {
        _nestedAsks.remove(key);
      } else if (!_nestedAsks.containsKey(key)) {
        _askInside(o, choices, key);
      }
    }
  }

  bool get isComplete => selectedVariantId != null && asks.every((a) => a.answered);

  ChosenLine toChosenLine() {
    final variant = availableVariants.firstWhere(
      (v) => v.variantId == selectedVariantId,
      orElse: () => availableVariants.first,
    );
    final name = entry.variants.length > 1 ? '${entry.name} (${variant.name})' : entry.name;
    final zh = namesShown(entry.name, entry.secondName, chineseFirst: true).$2 == null ? null : entry.secondName;
    final request = LineRequest.withChoices(variant.variantId, entry.entryId, choices);
    final groups = detail?.groups ?? const <GroupDetail>[];
    return ChosenLine(
      name: name,
      zhName: zh == null ? null : (entry.variants.length > 1 ? '$zh (${variant.name})' : zh),
      request: request,
      // the menu's own prices until the hub answers, as the sheet does when no hub answers
      unitPrice: localPrice(name, availableVariants, detail, request).unitPrice,
      modifiers: pickedModifiers(groups, request),
      itemId: entry.item,
      wentWith: wentWith,
    );
  }
}

/// The dishes the menu says go with a dish that was just rung ([_MenuPanelState._rung]), as the tray under
/// the dishes shows them.
class _Offer {
  const _Offer(this.of, this.entries, this.tile);

  /// The dish that was rung.
  final MenuEntry of;

  /// What goes with it, each as it can be rung right now.
  final List<MenuEntry> entries;

  /// The focus node of the tile it was rung from: Escape in the tray takes the keyboard's focus back there.
  final FocusNode? tile;
}

/// The tray that says what goes with the dish just rung: a line naming that dish, then each suggestion as the
/// dish's own tile, in the menu's grid. A tap adds one, a hold opens its sheet, and it shows how many are on
/// the order, exactly as its tile in its own category does. Closed with its button, by pulling down, or by
/// going on to another dish or category.
class _GoesWithSection extends StatelessWidget {
  const _GoesWithSection({
    required this.of,
    required this.crossAxisCount,
    required this.tileHeight,
    required this.onClose,
    required this.scroll,
    required this.tiles,
  });

  final MenuEntry of;
  final int crossAxisCount;
  final double tileHeight;
  final VoidCallback onClose;
  final ScrollController scroll;
  final List<Widget> tiles;

  static const _lineHeight = 32.0;
  static const _topPadding = 2.0;

  /// The room the tray takes beyond a plain grid of its tiles: the rule on top and the line that names the
  /// dish, less the padding it does without over its first row. The line grows with large type.
  static double heightOver(BuildContext context) =>
      _MenuPanelState._itemsDividerHeight + _line(context) + _topPadding - _MenuPanelState._gridPadding;

  /// The least height it can be laid out in: its rule, the line that names the dish, and a sliver of tiles.
  static double least(BuildContext context) => _MenuPanelState._itemsDividerHeight + _line(context) + 1.0;

  static double _line(BuildContext context) =>
      math.max(_lineHeight, MediaQuery.textScalerOf(context).scale(12) * 1.5 + 8);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (name, _) = namesShown(of.name, of.secondName, chineseFirst: DishLanguage.chineseOf(context));
    return ColoredBox(
      color: scheme.surfaceContainer,
      child: DrillDown(
        onClose: onClose,
        header: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Divider(height: _MenuPanelState._itemsDividerHeight, thickness: _MenuPanelState._itemsDividerHeight),
            SizedBox(
              height: _line(context),
              child: Padding(
                padding: const EdgeInsets.only(left: 14, right: 2),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Goes with $name',
                        key: const ValueKey('goes-with-title'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    IconButton(
                      key: const ValueKey('goes-with-close'),
                      tooltip: 'Close',
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 40, minHeight: _lineHeight),
                      icon: Icon(Icons.close, size: 18, color: scheme.onSurfaceVariant),
                      onPressed: onClose,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        child: GridView(
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(
            _MenuPanelState._gridPadding,
            _topPadding,
            _MenuPanelState._gridPadding,
            _MenuPanelState._gridPadding,
          ),
          physics: DrillDown.physics,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            mainAxisSpacing: _MenuPanelState._gridSpacing,
            crossAxisSpacing: _MenuPanelState._gridSpacing,
            mainAxisExtent: tileHeight,
          ),
          children: tiles,
        ),
      ),
    );
  }
}

/// A question the tray asks: a group on the dish itself, or on a chosen choice that is a dish, with the
/// choices it is answered in.
class _Ask {
  const _Ask(this.group, this.choices, {required this.path, this.under});

  final GroupDetail group;
  final Choices choices;

  /// The option ids of the dishes this group sits under, slash-separated and slash-terminated; '' on the dish.
  final String path;

  /// The chosen dish this group is on, when it is on one.
  final String? under;

  String get label => under == null ? group.name : '$under · ${group.name}';
  int get count => choices.units(group.groupId);
  bool get answered => count >= group.minSelect;
}

class _RequiredSelectionsSection extends StatelessWidget {
  const _RequiredSelectionsSection({
    required this.pending,
    required this.crossAxisCount,
    required this.tileHeight,
    required this.onSelectVariant,
    required this.onToggleOption,
    required this.onLongPressOption,
    required this.onClose,
    required this.scroll,
    required this.focusOf,
  });

  final _PendingItemSelection pending;
  final int crossAxisCount;
  final double tileHeight;
  final ValueChanged<VariantOffer> onSelectVariant;
  final void Function(_Ask ask, OptionDetail option) onToggleOption;

  /// A hold on a choice that is a dish: the dish's own sheet.
  final void Function(_Ask ask, OptionDetail option) onLongPressOption;
  final VoidCallback onClose;
  final ScrollController scroll;

  /// The focus node of a button, by its key: the panel sends the keyboard's focus to the buttons.
  final FocusNode Function(String tile) focusOf;

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
          controller: scroll,
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
                ChoiceTile(
                  key: ValueKey(_PendingItemSelection.variantKey(v)),
                  focusNode: focusOf(_PendingItemSelection.variantKey(v)),
                  groupLabel: sizeLabel(v),
                  name: v.name,
                  priceLabel: v.price,
                  available: v.available,
                  selected: pending.selectedVariantId == v.variantId,
                  onTap: () => onSelectVariant(v),
                ),
            for (final ask in pending.asks)
              for (final o in ask.group.options)
                ChoiceTile(
                  key: ValueKey(_PendingItemSelection.optionKey(ask, o)),
                  focusNode: focusOf(_PendingItemSelection.optionKey(ask, o)),
                  groupLabel: ask.group.minSelect > 1
                      ? '${ask.label} (${ask.count}/${ask.group.minSelect})'
                      : ask.label,
                  name: ask.choices.picked(ask.group.groupId, o.optionId) && ask.choices.qty(o.optionId) > 1
                      ? '${ask.choices.qty(o.optionId)}x ${o.name}'
                      : o.name,
                  priceLabel: o.free ? null : '+${o.price}',
                  available: o.available,
                  selected: ask.choices.picked(ask.group.groupId, o.optionId),
                  dish: o.isDish,
                  onTap: () => onToggleOption(ask, o),
                  onLongPress: o.isDish ? () => onLongPressOption(ask, o) : null,
                ),
          ],
        ),
      ),
    );
  }
}

/// What heads a size's button: "Size", with how many are left where someone is counting that size.
String sizeLabel(VariantOffer v) => v.available && v.left != null ? 'Size · ${v.left} left' : 'Size';

/// A choice as a button of the menu's grid: the tray under the tiles and the item sheet show a dish's sizes
/// and choices with it, so a choice looks and taps like a category or a dish.
class ChoiceTile extends StatelessWidget {
  const ChoiceTile({
    super.key,
    required this.groupLabel,
    required this.name,
    this.priceLabel,
    required this.available,
    required this.selected,
    this.dish = false,
    this.changed = false,
    required this.onTap,
    this.onLongPress,
    this.onRemove,
    this.focusNode,
  });

  /// The menu's own tile grid for a width: how many tiles across, and how wide and how tall each is.
  static ({int columns, double width, double height}) grid(double width) {
    final columns = (width / (_MenuPanelState._maxCrossAxisExtent + _MenuPanelState._gridSpacing)).ceil().clamp(1, 99);
    final tileWidth = (width - _MenuPanelState._gridSpacing * (columns - 1)) / columns;
    return (columns: columns, width: tileWidth, height: tileWidth / _MenuPanelState._childAspectRatio);
  }

  final String groupLabel;
  final String name;
  final String? priceLabel;
  final bool available;
  final bool selected;

  /// The choice is a dish of the menu: marked, since a hold opens it.
  final bool dish;

  /// That dish differs from how it comes (a choice on it changed, or it carries a note).
  final bool changed;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  /// One fewer of it, where the group takes several of the same choice: a minus in the corner.
  final VoidCallback? onRemove;
  final FocusNode? focusNode;

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
          focusNode: focusNode,
          onTap: available ? onTap : null,
          onLongPress: available ? onLongPress : null,
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
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (dish)
                        Padding(
                          padding: const EdgeInsets.only(right: 4, top: 1),
                          child: Icon(
                            changed ? Icons.tune : Icons.restaurant_menu,
                            size: 14,
                            color: selected ? scheme.onPrimaryContainer : scheme.onSurfaceVariant,
                          ),
                        ),
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
                      if (onRemove != null)
                        Align(
                          alignment: Alignment.bottomRight,
                          child: IconButton(
                            tooltip: 'One fewer',
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                            icon: Icon(Icons.remove_circle_outline, size: 22, color: scheme.onPrimaryContainer),
                            onPressed: onRemove,
                          ),
                        ),
                    ],
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

/// Buttons laid out as the menu lays out its tiles: as many across as the width takes, each the tiles' shape.
/// It sizes itself, so it sits in a scrolling sheet.
class ChoiceGrid extends StatelessWidget {
  const ChoiceGrid({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final grid = ChoiceTile.grid(constraints.maxWidth);
      return GridView(
        shrinkWrap: true,
        padding: EdgeInsets.zero,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: grid.columns,
          mainAxisSpacing: _MenuPanelState._gridSpacing,
          crossAxisSpacing: _MenuPanelState._gridSpacing,
          mainAxisExtent: grid.height,
        ),
        children: children,
      );
    },
  );
}

class _EntryButton extends StatelessWidget {
  const _EntryButton({
    super.key,
    required this.entry,
    required this.onTap,
    required this.onLongPress,
    this.qty = 0,
    this.selected = false,
    this.focusNode,
  });

  final MenuEntry entry;
  final int qty;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final available = entry.available;
    // The name the person at the screen reads is the big one; the other goes small under it.
    final (name, second) = namesShown(entry.name, entry.secondName, chineseFirst: DishLanguage.chineseOf(context));
    // Someone typed a number left: it stands where the price does, as 86 does once none are left.
    final left = available ? entry.left : null;
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
          focusNode: focusNode,
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
                      key: left == null ? null : ValueKey('entry-left:${entry.entryId}:${entry.item}'),
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                      decoration: BoxDecoration(
                        color: !available
                            ? scheme.errorContainer
                            : (left != null ? scheme.tertiaryContainer : scheme.secondaryContainer),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        !available ? '86' : (left != null ? '$left left' : entry.priceLabel),
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: !available
                              ? scheme.onErrorContainer
                              : (left != null ? scheme.onTertiaryContainer : scheme.onSecondaryContainer),
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
                          name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(
                            decoration: available ? null : TextDecoration.lineThrough,
                            color: available ? scheme.onSurface : scheme.onSurfaceVariant,
                            height: 1.15,
                          ),
                        ),
                      ),
                      if (second != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 1),
                          child: Text(
                            second,
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

  /// The location's one-tap notes, as last read: the buttons over the note. Read again as the sheet opens.
  late List<String> _kitchenNotes = widget.api.kitchenNotesKnown;

  /// What is typed for a dish that asks: its price, and what it is for an off-menu dish. A line reopened
  /// comes with what was typed for it.
  late final _typedName = TextEditingController(text: _request.name ?? '');
  late final _typedPrice = TextEditingController(text: _request.price ?? '');
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
    unawaited(_readKitchenNotes());
  }

  Future<void> _readKitchenNotes() async {
    try {
      final read = await widget.api.kitchenNotes();
      final notes = read?.notes ?? const <String>[];
      if (mounted && !listEquals(notes, _kitchenNotes)) setState(() => _kitchenNotes = notes);
    } on ApiException {
      // nothing answers and nothing was saved: the note is typed, as before
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _note.dispose();
    _typedName.dispose();
    _typedPrice.dispose();
    super.dispose();
  }

  /// Everything the dish asks to be typed is there: nothing for a dish with a price of its own.
  bool get _typed =>
      !widget.entry.asksPrice || (_request.price != null && (!widget.entry.asksName || _request.name != null));

  /// Takes what the two boxes hold into the request: a price the hub would take, a name with something in it.
  void _readTyped() {
    final name = _typedName.text.trim().replaceAll(RegExp(r'\s+'), ' ');
    setState(() {
      _request.price = typedPrice(_typedPrice.text);
      _request.name = widget.entry.asksName && name.isNotEmpty ? name : null;
    });
    _reprice();
  }

  Future<void> _load() async {
    try {
      final entryId = widget.entry.entryId.isEmpty ? null : widget.entry.entryId;
      final detail = await widget.api.item(widget.entry.item, entryId: entryId);
      if (widget.initial == null) {
        fillDefaults(detail.groups, _request);
      } else {
        _fillInside(detail.groups, _request); // a line reopened: the dishes it chose come with their defaults
      }
      if (mounted) setState(() => _detail = detail);
      _reprice();
    } on ApiException catch (err) {
      if (mounted) setState(() => _error = err.toString());
    }
  }

  void _reprice() {
    _debounce?.cancel();
    if (!_typed) {
      // nothing to ask the hub yet: it would only say that the price is missing, which the empty box says
      if (_priced != null) setState(() => _priced = null);
      return;
    }
    final asked = _request.copy();
    _debounce = Timer(const Duration(milliseconds: 150), () async {
      try {
        final priced = await widget.api.price(_request);
        // an answer for a price typed over since is not this dish's price
        if (mounted && asked.price == _request.price && _typed) setState(() => _priced = priced);
      } on ApiException catch (err) {
        if (!mounted || !_typed) return;
        if (err.status == null) {
          // No backend answers (ADR 6): the menu's own prices, marked estimated, so the dish still goes on.
          setState(() => _priced = localPrice(_lineName, widget.entry.variants, _detail, _request));
        } else {
          setState(() => _error = err.toString());
        }
      }
    });
  }

  /// The defaults of every chosen dish that has no choices on it yet, down through the levels.
  void _fillInside(List<GroupDetail> groups, Choices choices) {
    for (final g in groups) {
      for (final o in g.options) {
        if (o.groups.isEmpty || !choices.picked(g.groupId, o.optionId)) continue;
        final inside = choices.inside(o.optionId);
        if (inside.selections.isEmpty) fillDefaults(o.groups, inside);
        _fillInside(o.groups, inside);
      }
    }
  }

  /// The choices that differ from the menu's defaults, as the check lists them, each with its price; a
  /// marked choice is listed with its word even when it is the default ("No white rice"), and a choice left
  /// off ("no") is free, as the backend makes it. The choices on a chosen dish follow it one level deeper.
  List<CheckModifier> get _picked => pickedModifiers(_detail?.groups ?? const <GroupDetail>[], _request);

  String get _lineName {
    final typed = _request.name;
    if (widget.entry.asksName && typed != null) return typed; // an off-menu dish is called what was typed
    final variant = widget.entry.variants.firstWhere((v) => v.variantId == _request.variantId);
    return widget.entry.variants.length > 1 ? '${widget.entry.name} (${variant.name})' : widget.entry.name;
  }

  /// The same in Chinese, for the check of a person who reads the names that way; null where the menu has
  /// no Chinese name for the dish, and for a dish whose name was typed.
  String? get _zhLineName {
    final entry = widget.entry;
    if (entry.asksName && _request.name != null) return null;
    if (namesShown(entry.name, entry.secondName, chineseFirst: true).$2 == null) return null;
    final variant = entry.variants.firstWhere((v) => v.variantId == _request.variantId);
    return entry.variants.length > 1 ? '${entry.secondName} (${variant.name})' : entry.secondName;
  }

  /// The line as it stands, handed back to whoever opened the sheet; nothing while it cannot be sold.
  void _done() {
    final priced = _priced;
    if (priced == null || !priced.ok || !_typed) return;
    Navigator.of(context).pop(
      ChosenLine(
        name: _lineName,
        zhName: _zhLineName,
        request: _request,
        qty: _qty,
        note: _note.text.trim(),
        unitPrice: priced.unitPrice,
        modifiers: _picked,
        itemId: widget.entry.item,
      ),
    );
  }

  /// The boxes of a dish that asks: what it is (an off-menu dish only) and its price. Side by side where
  /// the sheet is wide enough for a name to be read in its box; on a phone the name has the sheet's width
  /// and the price goes under it.
  Widget _typedBoxes() {
    final entry = widget.entry;
    final said = _typedPrice.text.trim();
    final name = TextField(
      key: const ValueKey('typed-name'),
      controller: _typedName,
      autofocus: widget.initial == null,
      maxLength: typedNameMax,
      textCapitalization: TextCapitalization.sentences,
      textInputAction: TextInputAction.next,
      decoration: const InputDecoration(labelText: 'What is it', isDense: true, counterText: ''),
      onChanged: (_) => _readTyped(),
    );
    final price = TextField(
      key: const ValueKey('typed-price'),
      controller: _typedPrice,
      autofocus: widget.initial == null && !entry.asksName,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
      textInputAction: TextInputAction.done,
      decoration: InputDecoration(
        labelText: 'Price',
        prefixText: '\$ ',
        isDense: true,
        // said only once something is typed that is no price: an empty box says it by itself
        errorText: said.isNotEmpty && _request.price == null ? 'Like 18.50' : null,
      ),
      onChanged: (_) => _readTyped(),
      onSubmitted: (_) => _done(),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: LayoutBuilder(
        builder: (context, box) {
          if (!entry.asksName) return SizedBox(width: 160, child: price);
          if (box.maxWidth < 340) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                name,
                const SizedBox(height: 10),
                SizedBox(width: 160, child: price),
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: name),
              const SizedBox(width: 10),
              SizedBox(width: 116, child: price),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final detail = _detail;
    final priced = _priced;
    final total = priced == null ? null : (double.parse(priced.unitPrice) * _qty).toStringAsFixed(2);
    final (name, second) = namesShown(
      widget.entry.name,
      widget.entry.secondName,
      chineseFirst: DishLanguage.chineseOf(context),
    );
    return AlertDialog(
      title: Row(
        children: [
          Expanded(child: Text(second == null ? name : '$name  $second')),
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
                    if (widget.entry.asksPrice) _typedBoxes(),
                    if (widget.entry.variants.length > 1) ...[
                      Text('Size', style: theme.textTheme.titleSmall),
                      const SizedBox(height: 6),
                      ChoiceGrid(
                        children: [
                          for (final v in widget.entry.variants)
                            ChoiceTile(
                              key: ValueKey('size:${v.variantId}'),
                              groupLabel: sizeLabel(v),
                              name: v.name,
                              priceLabel: widget.entry.asksPrice ? null : v.price,
                              available: v.available,
                              selected: _request.variantId == v.variantId,
                              onTap: () {
                                setState(() => _request.variantId = v.variantId);
                                _reprice();
                              },
                            ),
                        ],
                      ),
                      const SizedBox(height: 14),
                    ],
                    ChoicesEditor(
                      groups: detail.groups,
                      choices: _request,
                      kitchenNotes: _kitchenNotes,
                      onChanged: () {
                        setState(() {});
                        _reprice();
                      },
                    ),
                    KitchenNoteChips(notes: _kitchenNotes, controller: _note),
                    TextField(
                      key: const ValueKey('line-note'),
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
                          // the total takes what the row has left: a long one (a typed price can run to
                          // thousands) is drawn smaller on a narrow phone, never off the sheet's edge
                          Expanded(
                            child: total == null
                                ? const SizedBox()
                                : Align(
                                    alignment: Alignment.centerRight,
                                    child: FittedBox(
                                      fit: BoxFit.scaleDown,
                                      alignment: Alignment.centerRight,
                                      child: Padding(
                                        padding: const EdgeInsets.only(left: 4, right: 6),
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
          onPressed: priced != null && priced.ok && _typed ? _done : null,
          child: Text(widget.initial == null ? 'Add' : 'Update'),
        ),
      ],
    );
  }
}

/// The choices on a dish as chips, group by group: a tap picks one, the kitchen's words mark one ("No
/// peanuts"), and a chosen choice that is a dish shows the questions its defaults leave open in a block right
/// under it. A hold on a choice that is a dish opens that dish's own sheet, with every choice on it and a note
/// to the kitchen, as a hold on its menu tile would. The item sheet and a dish's own sheet share it, so a dish
/// inside a dish reads the same at every level.
class ChoicesEditor extends StatefulWidget {
  const ChoicesEditor({
    super.key,
    required this.groups,
    required this.choices,
    required this.onChanged,
    this.kitchenNotes = const [],
  });

  final List<GroupDetail> groups;

  /// The location's one-tap notes, for the sheet of a dish opened from here.
  final List<String> kitchenNotes;

  /// Edited in place; [onChanged] says when.
  final Choices choices;
  final VoidCallback onChanged;

  @override
  State<ChoicesEditor> createState() => _ChoicesEditorState();
}

class _ChoicesEditorState extends State<ChoicesEditor> {
  String? _armed; // No, Extra, On the side or Light, waiting for the choice it is about

  /// A tap on a choice, on the dish or on a chosen dish one level down ([choices] is that level's).
  void _toggle(Choices choices, GroupDetail group, OptionDetail option) {
    setState(() {
      final current = choices.selections[group.groupId] ?? [];
      final chosen = current.contains(option.optionId);
      final armed = _armed;
      _armed = null;
      if (armed != null) {
        // "No peanuts": the word goes on this choice, which has to be on the line for it to mean anything.
        // The same word again takes it off and leaves the plain choice.
        // a full group takes no new choice, and a "no" in it cannot turn back into one more
        final full = !group.single && !choices.room(group) && (!chosen || choices.prefixes[option.optionId] == 'no');
        if (!full) {
          if (choices.prefixes[option.optionId] == armed) {
            choices.prefixes.remove(option.optionId);
          } else {
            choices.prefixes[option.optionId] = armed;
          }
          if (!chosen) {
            choices.selections[group.groupId] = group.single ? [option.optionId] : [...current, option.optionId];
          }
        }
      } else if (group.single) {
        choices.selections[group.groupId] = chosen && !group.required ? [] : [option.optionId];
      } else if (chosen && group.allowQuantity) {
        // several of the same choice: a tap on a chosen one adds another; its minus takes one off
        choices.addOne(group, option);
      } else if (chosen) {
        choices.selections[group.groupId] = [...current]..remove(option.optionId);
      } else if (choices.room(group)) {
        choices.selections[group.groupId] = [...current, option.optionId];
      }
      // a word or a count only means something on a choice that is on the line
      choices.settle(group);
      final kept = choices.selections[group.groupId] ?? const <String>[];
      // a dish chosen as a choice comes with its own defaults; what they leave open is asked right under it
      if (option.groups.isNotEmpty && kept.contains(option.optionId) && !choices.nested.containsKey(option.optionId)) {
        fillDefaults(option.groups, choices.inside(option.optionId));
      }
    });
    widget.onChanged();
  }

  /// A hold on a choice that is a dish: its own sheet. Done takes the choices made there and chooses the dish.
  Future<void> _openDish(Choices choices, GroupDetail group, OptionDetail option) async {
    final inside = await showDialog<Choices>(
      context: context,
      builder: (_) =>
          DishChoicesSheet(option: option, initial: choices.nested[option.optionId], kitchenNotes: widget.kitchenNotes),
    );
    if (inside == null || !mounted) return;
    setState(() {
      choices.nested[option.optionId] = inside;
      choices.take(group, option.optionId);
    });
    widget.onChanged();
  }

  /// What a choice's button reads: how many of it and its word in front of its name. Its price is the
  /// button's badge ([_optionPrice]).
  String _optionLabel(Choices choices, OptionDetail o) {
    final mark = choices.prefixes[o.optionId];
    final n = choices.qty(o.optionId);
    final word = mark == null ? o.name : '${instructions[mark]} ${o.name}';
    return n > 1 ? '${n}x $word' : word;
  }

  /// The badge on a choice's button: what one of it adds with the word it carries, so "Extra" on the shrimp
  /// shows the shrimp charged again. None on a free choice and on one marked "no" (the backend charges
  /// nothing for a choice left off).
  String? _optionPrice(Choices choices, GroupDetail g, OptionDetail o) {
    final price = choiceCents(g, o, choices.prefixes[o.optionId]);
    return price == 0 ? null : '+${(price / 100).toStringAsFixed(2)}';
  }

  /// One fewer of a choice in a group that takes several: the minus on its chip.
  void _removeOne(Choices choices, GroupDetail group, OptionDetail option) {
    setState(() {
      choices.removeOne(group, option.optionId);
      choices.settle(group);
    });
    widget.onChanged();
  }

  /// The dish behind a choice was changed: a choice on it differs from its defaults, or it carries a note.
  bool _changed(Choices choices, OptionDetail o) {
    final inside = choices.nested[o.optionId];
    if (inside == null) return false;
    return (inside.notes?.isNotEmpty ?? false) || pickedModifiers(o.groups, inside).isNotEmpty;
  }

  /// A dish's groups as chips; under each chosen choice that is a dish, the questions its defaults leave
  /// open in a block one step in, so a roll's sauce is asked right under the roll. The rest of that dish is a
  /// hold away.
  List<Widget> _groupBlocks(
    ThemeData theme,
    ColorScheme scheme,
    List<GroupDetail> groups,
    Choices choices,
    int depth,
  ) => [
    for (final g in groups) ...[
      Text(
        // a group that needs several shows how many it has, as the tray does: "Platter (6/6)"
        g.minSelect > 1
            ? '${g.name} (${choices.taken(g.groupId)}/${g.minSelect})'
            : (g.required ? '${g.name} (required)' : g.name),
        style: theme.textTheme.titleSmall?.copyWith(color: g.required ? scheme.primary : scheme.onSurface),
      ),
      if (g.allowQuantity)
        Text(
          'Tap again for one more, the minus for one fewer.',
          style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
      const SizedBox(height: 6),
      ChoiceGrid(
        children: [
          for (final o in g.options)
            ChoiceTile(
              key: ValueKey('choice:${o.optionId}@$depth'),
              groupLabel: g.name,
              name: _optionLabel(choices, o),
              priceLabel: _optionPrice(choices, g, o),
              available: o.available,
              selected: choices.picked(g.groupId, o.optionId),
              dish: o.isDish,
              changed: o.isDish && _changed(choices, o),
              onTap: () => _toggle(choices, g, o),
              onLongPress: o.isDish ? () => _openDish(choices, g, o) : null,
              onRemove: g.allowQuantity && o.available && choices.picked(g.groupId, o.optionId)
                  ? () => _removeOne(choices, g, o)
                  : null,
            ),
        ],
      ),
      const SizedBox(height: 14),
      for (final o in g.options)
        if (choices.picked(g.groupId, o.optionId) && openGroups(o).isNotEmpty)
          Container(
            key: ValueKey('inside:${o.optionId}'),
            margin: const EdgeInsets.only(bottom: 14),
            padding: const EdgeInsets.only(left: 12),
            decoration: BoxDecoration(
              border: Border(left: BorderSide(color: scheme.outlineVariant, width: 2)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(o.name, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                ..._groupBlocks(theme, scheme, openGroups(o), choices.inside(o.optionId), depth + 1),
              ],
            ),
          ),
    ],
  ];

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
              ? 'To mark a choice, tap a word and then the choice. Hold a dish to open it.'
              : 'Now tap the choice to mark “${instructions[_armed]}”.',
          style: theme.textTheme.bodySmall?.copyWith(color: _armed == null ? scheme.onSurfaceVariant : scheme.primary),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.groups.isNotEmpty) _instructionRow(theme, scheme),
        ..._groupBlocks(theme, scheme, widget.groups, widget.choices, 0),
      ],
    );
  }
}

/// A dish chosen as a choice on another dish, opened on its own by a hold: every choice on it, as its own
/// sheet shows them, and a note to the kitchen that prints with it. Done hands the choices back, and the dish
/// is chosen with them; Cancel changes nothing.
class DishChoicesSheet extends StatefulWidget {
  const DishChoicesSheet({super.key, required this.option, this.initial, this.kitchenNotes = const []});

  final OptionDetail option;

  /// The choices already on the dish, when it was chosen before.
  final Choices? initial;

  /// The location's one-tap notes: the buttons over this dish's note.
  final List<String> kitchenNotes;

  @override
  State<DishChoicesSheet> createState() => _DishChoicesSheetState();
}

class _DishChoicesSheetState extends State<DishChoicesSheet> {
  late final Choices _choices = _start();
  late final _note = TextEditingController(text: widget.initial?.notes ?? '');

  /// The choices as they stand, or the dish's defaults when it has not been chosen yet.
  Choices _start() {
    final initial = widget.initial;
    if (initial != null && initial.selections.isNotEmpty) return initial.copyChoices();
    return defaultChoices(widget.option.groups)..notes = initial?.notes;
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final option = widget.option;
    return AlertDialog(
      title: Text(option.name),
      content: SizedBox(
        width: 490,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ChoicesEditor(
                groups: option.groups,
                choices: _choices,
                kitchenNotes: widget.kitchenNotes,
                onChanged: () => setState(() {}),
              ),
              KitchenNoteChips(notes: widget.kitchenNotes, controller: _note),
              TextField(
                key: const ValueKey('dish-note'),
                controller: _note,
                decoration: const InputDecoration(
                  labelText: 'Note to the kitchen',
                  prefixIcon: Icon(Icons.edit_note_outlined),
                  isDense: true,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          onPressed: choicesComplete(option.groups, _choices)
              ? () {
                  final note = _note.text.trim();
                  Navigator.of(context).pop(_choices..notes = note.isEmpty ? null : note);
                }
              : null,
          child: const Text('Done'),
        ),
      ],
    );
  }
}

/// The location's one-tap notes to the kitchen (docs/kitchen-notes.md), a button each, over the box a dish's
/// note is typed in. A tap puts the words in the note, after what is there; another tap takes them out. What
/// was typed around them stays, and the box shows the note as the kitchen will read it.
class KitchenNoteChips extends StatelessWidget {
  const KitchenNoteChips({super.key, required this.notes, required this.controller});

  final List<String> notes;
  final TextEditingController controller;

  void _tap(String note) {
    final text = toggleNote(controller.text, note);
    controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (notes.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: ListenableBuilder(
        listenable: controller,
        // Close together, so six notes are two rows on a phone and the note under them stays in view.
        builder: (context, _) => Wrap(
          spacing: 6,
          children: [
            for (final note in notes)
              FilterChip(
                key: ValueKey('kitchen-note:$note'),
                label: Text(note),
                labelPadding: const EdgeInsets.symmetric(horizontal: 2),
                visualDensity: VisualDensity.compact,
                showCheckmark: false, // the chips keep their places as they are tapped
                selected: hasNote(controller.text, note),
                onSelected: (_) => _tap(note),
              ),
          ],
        ),
      ),
    );
  }
}

/// The 86 sheet for one dish: mark a size sold out or bring it back, or, where the hub keeps numbers, type
/// how many are left. With a number the dish stays on sale, every one sold takes it down, one taken off a
/// check gives it back, the hub marks the dish sold out at zero, and the number clears overnight.
class EightySixDialog extends StatefulWidget {
  const EightySixDialog({super.key, required this.api, required this.entry, this.by});
  final PosApi api;
  final MenuEntry entry;

  /// Who is setting it, by name, for the board.
  final String? by;

  @override
  State<EightySixDialog> createState() => _EightySixDialogState();
}

class _EightySixDialogState extends State<EightySixDialog> {
  late final Map<String, bool> _out = {for (final v in widget.entry.variants) v.variantId: !v.available};
  late final Map<String, int?> _left = {for (final v in widget.entry.variants) v.variantId: v.left};
  late final Map<String, TextEditingController> _number = {
    for (final v in widget.entry.variants) v.variantId: TextEditingController(text: v.left == null ? '' : '${v.left}'),
  };
  String? _error;

  @override
  void dispose() {
    for (final number in _number.values) {
      number.dispose();
    }
    super.dispose();
  }

  Future<void> _set(String variantId, bool out) async {
    try {
      await widget.api.set86(variantId, soldOut: out, by: widget.by);
      setState(() {
        _out[variantId] = out;
        _left[variantId] = null; // sold out by hand, or back on sale: either way nobody is counting it now
        _number[variantId]!.clear();
        _error = null;
      });
    } on ApiException catch (err) {
      setState(() => _error = err.toString());
    }
  }

  /// Puts the typed number on the size, or with [off] takes the number off and leaves the dish on sale.
  Future<void> _count(String variantId, {bool off = false}) async {
    final n = off ? null : int.tryParse(_number[variantId]!.text.trim());
    if (!off && (n == null || n < 1 || n > 999)) {
      setState(() => _error = 'Type how many are left, from 1 to 999.');
      return;
    }
    try {
      await widget.api.set86(variantId, soldOut: false, left: n, by: widget.by);
      setState(() {
        _out[variantId] = false;
        _left[variantId] = n;
        if (off) _number[variantId]!.clear();
        _error = null;
      });
    } on ApiException catch (err) {
      setState(() => _error = err.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final sizes = widget.entry.variants.length > 1;
    return AlertDialog(
      title: Text('86 ${widget.entry.name}'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final v in widget.entry.variants) ...[
              SwitchListTile(
                key: ValueKey('out:${v.variantId}'),
                contentPadding: EdgeInsets.zero,
                title: Text(sizes ? v.name : 'Sold out'),
                subtitle: sizes ? const Text('Sold out') : null,
                value: _out[v.variantId] ?? false,
                onChanged: (out) => _set(v.variantId, out),
              ),
              if (v.counts)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  // on a phone the sheet is too narrow for all three: taking the number off goes underneath
                  child: Wrap(
                    spacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      SizedBox(
                        width: 132,
                        child: TextField(
                          key: ValueKey('left:${v.variantId}'),
                          controller: _number[v.variantId],
                          keyboardType: TextInputType.number,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                            LengthLimitingTextInputFormatter(3),
                          ],
                          decoration: const InputDecoration(labelText: 'Number left', isDense: true),
                          onSubmitted: (_) => _count(v.variantId),
                        ),
                      ),
                      FilledButton.tonal(
                        key: ValueKey('left-set:${v.variantId}'),
                        onPressed: () => _count(v.variantId),
                        child: const Text('Set'),
                      ),
                      if (_left[v.variantId] != null)
                        TextButton(
                          key: ValueKey('left-off:${v.variantId}'),
                          onPressed: () => _count(v.variantId, off: true),
                          child: const Text('No number'),
                        ),
                    ],
                  ),
                ),
            ],
            if (widget.entry.counts)
              Text(
                'With a number the dish stays on sale: every one sold takes it down, and at zero it is sold out. '
                'The number clears overnight.',
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_error!, style: TextStyle(color: scheme.error)),
              ),
          ],
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Done'))],
    );
  }
}
