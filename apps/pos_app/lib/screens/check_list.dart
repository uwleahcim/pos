/// The rows of the check as a list that is rearranged by hand. Hold a line by its dish and it lifts into a
/// stack in hand; while it is held, tap other lines and they fold out of the list and stack behind it, each
/// showing from under the one before it but for its top edge, so that its dish can still be read, like a
/// fanned deck of cards. The rows open room for the stack where it would land
/// and move out of its way as it passes them, and once let go the stack comes down onto that room and
/// spreads into full rows, the rows around it moving apart to fit them; then the lines take their places in
/// the order stacked.
///
/// While dishes are in hand, the foot of the check offers places to drop them on instead of putting them
/// back down ([LotTarget]: Comp, Void): let go over one and the lines go nowhere, and the screen is told
/// which place took them.
library;

import 'dart:ui' show lerpDouble;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../api.dart' show Line;
import '../check_order.dart';

/// A hold on the check, as the rows see it: the line in hand, the lines picked up to go along with it in
/// the order they were tapped, and a way to pick a line up or put it down.
class CheckDrag {
  const CheckDrag({required this.held, required this.picked, required this.toggle});

  final String held;
  final List<String> picked;
  final void Function(String lineId) toggle;

  bool moves(String lineId) => lineId == held || picked.contains(lineId);
}

/// Builds a row: in the list, or in the stack in hand when the drag moves its line.
typedef CheckRowBuilder = Widget Function(BuildContext context, int index, CheckRow row, CheckDrag? drag);

/// A place at the foot of the check to drop the dishes in hand on, instead of putting them back down.
@immutable
class LotTarget {
  const LotTarget({required this.id, required this.label, required this.icon, this.danger = false, this.plain = false});

  final String id;

  /// What it does with them, in a word or two: "Comp 3", "Void 3".
  final String label;
  final IconData icon;

  /// It takes dishes off the check: drawn in the colour of a void.
  final bool danger;

  /// It gives nothing away and takes nothing off (the dishes go to another check): drawn in a quiet colour.
  final bool plain;
}

class CheckList extends StatefulWidget {
  const CheckList({
    super.key,
    required this.rows,
    required this.rowBuilder,
    required this.paper,
    required this.onDrop,
    this.targets,
    this.onTarget,
  });

  final List<CheckRow> rows;
  final CheckRowBuilder rowBuilder;

  /// The colour of the stack in hand: the check's paper.
  final Color paper;

  /// The stack has come down: the lines, as stacked, and where.
  final void Function(Drop drop) onDrop;

  /// The places the lines in hand (as stacked) can be dropped on, shown across the foot of the check while
  /// they are held. Null, or none: the check only rearranges.
  final List<LotTarget> Function(List<Line> inHand)? targets;

  /// The lines in hand were let go over the target with that id. They stay where they were on the check.
  final void Function(String target, List<Line> lines)? onTarget;

  /// How tall the places to drop on are, across the foot of the check.
  static const targetBar = 56.0;

  /// A row folding away or back, the rows making room, the stack growing.
  static const settle = Duration(milliseconds: 150);

  /// The stack coming down onto its room and spreading into rows once let go.
  static const land = Duration(milliseconds: 220);

  /// How much of each card behind the held one is hidden under the card in front of it: its top edge, so
  /// that the dish and its quantity can still be read.
  static const cover = 18.0;

  /// How far each card behind the held one steps in from the sides, to sit behind the one before it.
  static const step = 4.0;

  @override
  State<CheckList> createState() => CheckListState();
}

/// The part of a row that is held to lift it (the dish's name): hold it a moment and the row is in hand.
/// The list owns the hold's gesture, since this part of the row leaves the list once the row lifts.
class HoldToDrag extends StatelessWidget {
  const HoldToDrag({super.key, required this.index, required this.child});

  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (event) => context.findAncestorStateOfType<CheckListState>()?._watch(index, event, context),
      child: child,
    );
  }
}

class CheckListState extends State<CheckList> with TickerProviderStateMixin {
  final _viewport = GlobalKey();
  final _scroll = ScrollController();
  final _rowKeys = <String, GlobalKey>{};
  _Hold? _hold;

  /// Bumped when a hold begins or ends, so the rows take their new sizes at once rather than animate to
  /// them: the held row leaves its room behind the moment it lifts, and the stack's lines take their places
  /// the moment it has landed.
  int _generation = 0;

  late final Ticker _ticker = createTicker(_tick);

  /// The stack sliding to where it is held once the rows above its room close up or open (a line of theirs
  /// picked up or put back): [_shiftFrom] is how far from there it set off, [_shift] how far it still is.
  late final AnimationController _shifting = AnimationController(vsync: this, duration: CheckList.settle)
    ..addListener(() => setState(() {}));
  late final CurvedAnimation _shifted = CurvedAnimation(parent: _shifting, curve: Curves.easeOutCubic);
  double _shiftFrom = 0;

  double get _shift => _shiftFrom * (1 - _shifted.value);

  /// The stack, let go, coming down onto its room and spreading into full rows; at its end the lines take
  /// their places.
  late final AnimationController _landing = AnimationController(vsync: this, duration: CheckList.land)
    ..addListener(() => setState(() {}))
    ..addStatusListener((status) {
      if (status == AnimationStatus.completed && (_hold?.landing ?? false)) _commit();
    });
  late final CurvedAnimation _landed = CurvedAnimation(parent: _landing, curve: Curves.easeOutCubic);

  /// The gesture of the finger on a dish: a hold lifts the row, then the finger carries it.
  DelayedMultiDragGestureRecognizer? _finger;

  /// A finger has come down on a dish: should it stay a moment, the row lifts.
  void _watch(int index, PointerDownEvent event, BuildContext from) {
    if (_hold != null) return;
    _finger?.dispose();
    _finger = DelayedMultiDragGestureRecognizer()
      ..gestureSettings = MediaQuery.maybeGestureSettingsOf(from)
      ..onStart = ((position) => _lift(index, position))
      ..addPointer(event);
  }

  @override
  void didUpdateWidget(CheckList oldWidget) {
    super.didUpdateWidget(oldWidget);
    final hold = _hold;
    if (hold == null) return;
    final ids = {
      for (final row in widget.rows)
        if (row is LineRow) row.line.lineId,
    };
    if (!ids.contains(hold.held) || !hold.picked.every(ids.contains)) {
      // a line in hand is gone (another terminal's change): nothing to put down
      _letGo();
      _hold = null;
      _generation++;
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _hold != hold) return;
      _measure(hold);
      if (!hold.landing) _settle(hold); // coming down, the stack has its room
      setState(() {});
    });
  }

  @override
  void dispose() {
    _finger?.dispose();
    _ticker.dispose();
    _shifted.dispose();
    _shifting.dispose();
    _landed.dispose();
    _landing.dispose();
    _scroll.dispose();
    super.dispose();
  }

  double get _offset => _scroll.hasClients ? _scroll.offset : 0;

  /// A point on the screen, as a height down the check's rows (the list as if it were not scrolled).
  double _contentY(Offset global) {
    final box = _viewport.currentContext!.findRenderObject() as RenderBox;
    return box.globalToLocal(global).dy + _offset;
  }

  /// A point on the screen, as a place in the check's own frame (the part of the list that shows).
  Offset _local(Offset global) => (_viewport.currentContext!.findRenderObject() as RenderBox).globalToLocal(global);

  /// The places the lines in hand can be dropped on: none when the screen offers none.
  List<LotTarget> _targets(_Hold hold) =>
      widget.onTarget == null ? const [] : widget.targets?.call([for (final row in _stack(hold)) row.line]) ?? const [];

  /// How much of the foot of the check the places to drop on take.
  double _barHeight(_Hold hold) => _targets(hold).isEmpty ? 0 : CheckList.targetBar;

  /// The target the finger is over, if it is over one: they share the foot of the check evenly.
  LotTarget? _over(_Hold hold) {
    final targets = _targets(hold);
    final box = _viewport.currentContext?.findRenderObject() as RenderBox?;
    if (targets.isEmpty || box == null || hold.landing) return null;
    final at = hold.finger;
    if (at.dy < box.size.height - CheckList.targetBar || at.dy > box.size.height) return null;
    if (at.dx < 0 || at.dx >= box.size.width) return null;
    return targets[(at.dx / box.size.width * targets.length).floor().clamp(0, targets.length - 1)];
  }

  double _measuredHeight(String rowId) =>
      (_rowKeys[rowId]?.currentContext?.findRenderObject() as RenderBox?)?.size.height ?? 0;

  /// Notes how tall the rows that stay are; the ones in hand keep the height they had when they lifted.
  void _measure(_Hold hold) {
    for (final row in widget.rows) {
      if (!hold.moves(row)) hold.heights[row.rowId] = _measuredHeight(row.rowId);
    }
  }

  List<CheckRow> _remaining(_Hold hold) => [
    for (final row in widget.rows)
      if (!hold.moves(row)) row,
  ];

  /// The rows in hand, in the order they are stacked.
  List<LineRow> _stack(_Hold hold) {
    final byId = {
      for (final row in widget.rows)
        if (row is LineRow) row.line.lineId: row,
    };
    return [
      for (final id in [hold.held, ...hold.picked]) ?byId[id],
    ];
  }

  /// How tall the lines in hand are laid out as rows: what they take once landed.
  double _stackHeight(_Hold hold) => _stack(hold).fold(0.0, (sum, row) => sum + (hold.heights[row.rowId] ?? 0));

  /// How tall the stack in hand is: the held dish's card, and each card behind it but for its covered top.
  double _deckHeight(_Hold hold) {
    final stacked = _stack(hold);
    var height = 0.0;
    for (var i = 0; i < stacked.length; i++) {
      height += (hold.heights[stacked[i].rowId] ?? 0) - (i == 0 ? 0 : CheckList.cover);
    }
    return height;
  }

  int _slotOf(_Hold hold, List<CheckRow> remaining) {
    if (hold.roomBefore == null) return remaining.length;
    final slot = remaining.indexWhere((row) => row.rowId == hold.roomBefore);
    return slot < 0 ? remaining.length : slot;
  }

  Drag? _lift(int index, Offset global) {
    if (_hold != null || index >= widget.rows.length) return null;
    final rows = widget.rows;
    final row = rows[index];
    if (row is! LineRow) return null;
    final heights = {for (final r in rows) r.rowId: _measuredHeight(r.rowId)};
    var top = 0.0;
    for (var i = 0; i < index; i++) {
      top += heights[rows[i].rowId] ?? 0;
    }
    final hold = _Hold(
      held: row.line.lineId,
      heights: heights,
      grab: _contentY(global) - top,
      roomBefore: index + 1 < rows.length ? rows[index + 1].rowId : null,
      top: top,
    )..finger = _local(global);
    setState(() {
      _hold = hold;
      _generation++;
    });
    return _StackDrag(this);
  }

  void _update(Offset global) {
    final hold = _hold;
    if (hold == null || hold.landing) return;
    hold.top = _contentY(global) - hold.grab;
    hold.finger = _local(global);
    if (_over(hold) == null) {
      _settle(hold);
      _scrollIfAtEdge(hold);
    } else {
      _ticker.stop(); // over a place to drop on: the rows keep still, the room stays where it was
    }
    setState(() {});
  }

  /// Moves the room to where the stack is: going down, the row just under the room comes up over the
  /// stack once the stack's foot passes the row's middle; going up, the row just above it goes down under
  /// the stack once the stack's head passes its middle.
  void _settle(_Hold hold) {
    final remaining = _remaining(hold);
    final h = [for (final row in remaining) hold.heights[row.rowId] ?? 0];
    final height = _deckHeight(hold);
    final head = hold.top;
    final foot = head + height;
    var slot = _slotOf(hold, remaining);
    var base = 0.0; // how far down the row at `slot` starts, before the room
    for (var i = 0; i < slot; i++) {
      base += h[i];
    }
    while (slot < remaining.length && base + height + h[slot] / 2 < foot) {
      base += h[slot];
      slot++;
    }
    while (slot > 0 && base - h[slot - 1] / 2 >= head) {
      slot--;
      base -= h[slot];
    }
    hold.roomBefore = slot < remaining.length ? remaining[slot].rowId : null;
  }

  /// A tap on a line while one is in hand: it goes along, or goes back if it was already in the stack.
  /// The room keeps its place among the rows that stay: a row above it folding away or back moves the room
  /// up or down by that much, and the stack with it.
  void _toggle(String lineId) {
    final hold = _hold;
    if (hold == null || hold.landing || lineId == hold.held) return;
    final rowId = 'line:$lineId';
    final rows = widget.rows;
    final index = rows.indexWhere((row) => row.rowId == rowId);
    if (index < 0) return;
    final room = hold.roomBefore == null ? rows.length : rows.indexWhere((row) => row.rowId == hold.roomBefore);
    final height = hold.heights[rowId] ?? 0;
    setState(() {
      if (hold.picked.remove(lineId)) {
        if (index < room) _shiftBy(hold, height); // its row opens above the room again
      } else {
        if (hold.roomBefore == rowId) {
          // the room was just above it: it stays put, now above the next row that stays
          final remaining = _remaining(hold);
          final i = remaining.indexWhere((row) => row.rowId == rowId);
          hold.roomBefore = i + 1 < remaining.length ? remaining[i + 1].rowId : null;
        } else if (index < room) {
          _shiftBy(hold, -height); // its row folds away above the room
        }
        hold.picked.add(lineId);
      }
      _settle(hold);
    });
  }

  /// The room has moved [by] with the rows above it: the stack goes with it, the finger keeping its place
  /// on the screen, and the stack slides there rather than jumps.
  void _shiftBy(_Hold hold, double by) {
    hold.top += by;
    hold.grab -= by;
    _shiftFrom = _shift - by;
    _shifting.forward(from: 0);
  }

  /// Let go: the stack comes down onto its room and spreads into full rows, the room growing to fit them;
  /// then the lines take their places.
  void _end() {
    final hold = _hold;
    if (hold == null || hold.landing) return;
    final target = _over(hold);
    if (target != null) {
      // let go over Comp or Void: the lines go back to their rows and the screen does the rest
      final lines = [for (final row in _stack(hold)) row.line];
      _putDown();
      widget.onTarget?.call(target.id, lines);
      return;
    }
    _ticker.stop();
    _shifting.stop();
    final remaining = _remaining(hold);
    final slot = _slotOf(hold, remaining);
    var roomTop = 0.0;
    for (var i = 0; i < slot; i++) {
      roomTop += hold.heights[remaining[i].rowId] ?? 0;
    }
    final from = hold.top + _shift;
    if (hold.picked.isEmpty && (roomTop - from).abs() < 0.5) {
      _commit(); // one dish, in its place already: nothing to come down or spread out
      return;
    }
    setState(() {
      hold.landing = true;
      hold.landFrom = from;
      hold.landTo = roomTop;
    });
    _landing.forward(from: 0);
  }

  void _commit() {
    final hold = _hold;
    if (hold == null) return;
    final drop = dropOf(widget.rows, held: hold.held, picked: hold.picked, at: _slotOf(hold, _remaining(hold)));
    _putDown();
    widget.onDrop(drop);
  }

  /// The hold is over without a landing: every line back in its row at once.
  void _cancel() => _putDown();

  void _putDown() {
    _letGo();
    _finger?.dispose();
    _finger = null;
    setState(() {
      _hold = null;
      _generation++;
    });
  }

  /// Nothing in hand moves any more.
  void _letGo() {
    _ticker.stop();
    _shifting.stop();
    _landing.stop();
    _shiftFrom = 0;
  }

  static const _edge = 56.0;

  /// Near the top or bottom of the list, the list scrolls to bring more rows under the stack.
  void _scrollIfAtEdge(_Hold hold) {
    final box = _viewport.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !_scroll.hasClients) return;
    final finger = hold.top + hold.grab - _offset;
    // the foot of the list is above the places to drop on
    final atEdge = finger < _edge || finger > box.size.height - _barHeight(hold) - _edge;
    if (atEdge && !_ticker.isActive) _ticker.start();
    if (!atEdge && _ticker.isActive) _ticker.stop();
  }

  void _tick(Duration _) {
    final hold = _hold;
    final box = _viewport.currentContext?.findRenderObject() as RenderBox?;
    if (hold == null || hold.landing || box == null || !_scroll.hasClients) {
      _ticker.stop();
      return;
    }
    final finger = hold.top + hold.grab - _offset;
    final height = box.size.height - _barHeight(hold);
    final double delta;
    if (finger < _edge) {
      delta = -(_edge - finger) / _edge * 10;
    } else if (finger > height - _edge) {
      delta = (finger - (height - _edge)) / _edge * 10;
    } else {
      _ticker.stop();
      return;
    }
    final target = (_offset + delta.clamp(-14.0, 14.0)).clamp(0.0, _scroll.position.maxScrollExtent);
    if (target == _offset) {
      _ticker.stop();
      return;
    }
    hold.top += target - _offset;
    _scroll.jumpTo(target);
    _settle(hold);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final hold = _hold;
    final rows = widget.rows;
    final drag = hold == null
        ? null
        : CheckDrag(held: hold.held, picked: List.unmodifiable(hold.picked), toggle: _toggle);
    final children = <Widget>[];
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      final moving = hold != null && hold.moves(row);
      if (hold != null) children.add(_room(hold, row.rowId));
      children.add(
        KeyedSubtree(
          key: ValueKey('check-row:${row.rowId}'),
          child: KeyedSubtree(
            key: _rowKeys.putIfAbsent(row.rowId, GlobalKey.new),
            child: AnimatedSize(
              key: ValueKey(('row', row.rowId, _generation)),
              duration: CheckList.settle,
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: moving
                  ? const SizedBox(width: double.infinity, height: 0)
                  : widget.rowBuilder(context, i, row, drag),
            ),
          ),
        ),
      );
    }
    final targets = hold == null ? const <LotTarget>[] : _targets(hold);
    if (hold != null) {
      children.add(_room(hold, null));
      // the end of the check can still be reached above the places to drop on
      if (targets.isNotEmpty) children.add(const SizedBox(height: CheckList.targetBar));
    }
    return Stack(
      key: _viewport,
      children: [
        SingleChildScrollView(
          key: const ValueKey('check-list'),
          controller: _scroll,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
        ),
        if (hold != null) _stackInHand(context, hold, drag!),
        // over the stack, so the stack goes in under them and the place the finger is on can be read
        if (hold != null && targets.isNotEmpty && !hold.landing)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: CheckList.targetBar,
            child: _TargetBar(targets: targets, over: _over(hold)?.id),
          ),
      ],
    );
  }

  /// The room above a row (or at the end of the check, for null): the stack's height where the stack
  /// would land, nothing elsewhere. Every row has one, so the room slides from row to row. Once the stack
  /// is let go the room grows to fit its lines as rows, moving the rows around it apart.
  Widget _room(_Hold hold, String? rowId) => AnimatedContainer(
    key: ValueKey('room:${rowId ?? ''}'),
    duration: hold.landing ? CheckList.land : CheckList.settle,
    curve: Curves.easeOutCubic,
    height: hold.roomBefore != rowId
        ? 0
        : hold.landing
        ? _stackHeight(hold)
        : _deckHeight(hold),
  );

  /// The stack in hand: the held dish's card in front, the ones picked up behind it, each a step in from
  /// the sides and showing but for its top edge ([CheckList.cover]) under the one before it, like a fanned
  /// deck of cards. Coming down onto its room, the cards spread into full rows, so that the lines can take
  /// their places under them without a jump.
  Widget _stackInHand(BuildContext context, _Hold hold, CheckDrag drag) {
    final rows = widget.rows;
    final stacked = _stack(hold);
    final t = hold.landing ? _landed.value : 0.0;
    final top = (hold.landing ? lerpDouble(hold.landFrom, hold.landTo, t)! : hold.top + _shift) - _offset;
    // a card moves to its place in the stack on its own; coming down, it moves with the landing instead
    final onItsOwn = hold.landing ? Duration.zero : CheckList.settle;
    final cards = <Widget>[];
    var deckTop = 0.0; // where the card sits in the deck
    var flatTop = 0.0; // where it sits once the deck has spread into rows
    for (var i = 0; i < stacked.length; i++) {
      final row = stacked[i];
      cards.add(
        AnimatedPositioned(
          key: ValueKey('stacked:${row.rowId}'),
          duration: onItsOwn,
          curve: Curves.easeOutCubic,
          top: lerpDouble(deckTop, flatTop, t),
          left: lerpDouble(i * CheckList.step, 0, t),
          right: lerpDouble(i * CheckList.step, 0, t),
          child: _Joined(
            fresh: row.line.lineId != hold.held,
            child: Material(
              color: widget.paper,
              elevation: 6,
              child: widget.rowBuilder(context, rows.indexOf(row), row, drag),
            ),
          ),
        ),
      );
      deckTop += (hold.heights[row.rowId] ?? 0) - CheckList.cover;
      flatTop += hold.heights[row.rowId] ?? 0;
    }
    return Positioned(
      key: const ValueKey('check-stack'),
      left: 0,
      right: 0,
      top: top,
      child: AnimatedContainer(
        duration: onItsOwn,
        curve: Curves.easeOutCubic,
        height: lerpDouble(_deckHeight(hold), flatTop, t),
        // the held card in front: painted last
        child: Stack(clipBehavior: Clip.none, children: cards.reversed.toList()),
      ),
    );
  }
}

/// The places to drop the dishes in hand on, side by side across the foot of the check; the one the finger
/// is over is filled in.
class _TargetBar extends StatelessWidget {
  const _TargetBar({required this.targets, required this.over});

  final List<LotTarget> targets;
  final String? over;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Listener(
      behavior: HitTestBehavior.opaque, // a second finger here picks up nothing from the rows underneath
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: CheckList.settle,
        curve: Curves.easeOut,
        builder: (context, t, child) => Opacity(opacity: t, child: child),
        child: Material(
          key: const ValueKey('lot-targets'),
          color: scheme.surface,
          elevation: 8,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (i, target) in targets.indexed) ...[
                  if (i > 0) const SizedBox(width: 8),
                  Expanded(child: _target(theme, scheme, target)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _target(ThemeData theme, ColorScheme scheme, LotTarget target) {
    final on = target.id == over;
    // a place that takes dishes off is the red of a void; the other is the theme's green, so the two are
    // told apart at a glance and by more than their words
    final (fill, ink) = switch ((target.danger, on)) {
      _ when target.plain && on => (scheme.secondary, scheme.onSecondary),
      _ when target.plain => (scheme.secondaryContainer, scheme.onSecondaryContainer),
      (true, true) => (scheme.error, scheme.onError),
      (true, false) => (scheme.errorContainer, scheme.onErrorContainer),
      (false, true) => (scheme.tertiary, scheme.onTertiary),
      (false, false) => (Color.alphaBlend(scheme.tertiary.withValues(alpha: 0.16), scheme.surface), scheme.tertiary),
    };
    return AnimatedContainer(
      key: ValueKey('lot-target:${target.id}'),
      duration: const Duration(milliseconds: 90),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: on ? fill : ink.withValues(alpha: 0.35), width: on ? 2 : 1),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(target.icon, size: 20, color: ink),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              target.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall?.copyWith(color: ink, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}

/// A line that has joined the stack fades in under the others.
class _Joined extends StatelessWidget {
  const _Joined({required this.fresh, required this.child});

  final bool fresh;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!fresh) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: CheckList.settle,
      curve: Curves.easeOut,
      builder: (context, t, child) => Opacity(opacity: t, child: child),
      child: child,
    );
  }
}

/// A hold on the check.
class _Hold {
  _Hold({required this.held, required this.heights, required this.grab, required this.roomBefore, required this.top});

  /// The line in hand.
  final String held;

  /// The lines picked up to go along, in the order tapped.
  final picked = <String>[];

  /// How tall each row is, by row id: as measured when the hold began for the rows in hand.
  final Map<String, double> heights;

  /// How far below the top of the stack the finger holds it.
  double grab;

  /// The row the room is above (one that stays), or null for the end of the check.
  String? roomBefore;

  /// The top of the stack, as a height down the check's rows.
  double top;

  /// Where the finger is, in the check's own frame: over a place to drop on, or not.
  Offset finger = Offset.zero;

  /// Let go: the stack is coming down onto its room, from [landFrom] to [landTo] down the check's rows.
  bool landing = false;
  double landFrom = 0;
  double landTo = 0;

  bool moves(CheckRow row) => row is LineRow && (row.line.lineId == held || picked.contains(row.line.lineId));
}

/// The finger's drag, as the gesture system reports it, carried to the list.
class _StackDrag extends Drag {
  _StackDrag(this.list);

  final CheckListState list;

  @override
  void update(DragUpdateDetails details) => list._update(details.globalPosition);

  @override
  void end(DragEndDetails details) => list._end();

  @override
  void cancel() => list._cancel();
}
