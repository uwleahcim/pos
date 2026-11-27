import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'text_arrows.dart';

/// A text box with a list that drops down from it: over whatever stands under the box, moving nothing
/// (Mike, 2026-11-26). The list of addresses under a street's box ([AddressBox]) and the list of states
/// under the state's ([StateBox]) are both this.
///
/// The list is drawn on the screen's overlay, as wide as the box or as [listMinWidth], and no taller than
/// the room between the box and the bottom of the screen or the keyboard. A list longer than that scrolls
/// in itself ([rolls]). Where the form scrolls, the box is brought up to make that room ([bringUp]), and
/// the list is not shown while the box is scrolled out of sight. A touch on anything but the box and the
/// list, and Escape, ask for the list to go ([closeList]).
///
/// With a keyboard, the arrow down goes from the box into the list and on from line to line, and the arrow
/// up back and from the first line into the box: each line of the list takes [lineFocus] of its place.
///
/// The state that uses it says what its box and its list are, shows and hides the list as it comes and goes
/// ([showList], [hideList]: never while the screen is being built), and builds its box inside [dropUnder].
mixin DropsList<T extends StatefulWidget> on State<T>, WidgetsBindingObserver {
  /// The focus of the text box itself.
  FocusNode get boxFocus;

  /// What is typed in the box: the arrow down leaves it for the list once its cursor can go no further.
  TextEditingController get boxText;

  /// How many lines the list has. None is no list.
  int get listLines;

  /// The list: a [DropCard] with its lines, each a button with [lineFocus] of its place, scrolling in
  /// [rolls].
  Widget buildList(BuildContext context);

  /// The list is to go: Escape was pressed, something else was touched, or the box was left.
  void closeList();

  /// The keyboard came to the box from somewhere else on the screen.
  void boxEntered() {}

  /// The box and its list were left for something else on the screen.
  void boxLeft() {}

  /// The list is at least this wide, where its box is narrower.
  double get listMinWidth => 0;

  /// How tall the lines of the list need to show for the form to leave the box where it is; null is all of
  /// them. A long list that scrolls in itself anyway says a few lines.
  double? get listEnough => null;

  /// The list is never taller than this, however much room there is under the box; null is as tall as its
  /// lines. A long list says a few lines and scrolls in itself for the rest.
  double? get listMost => null;

  final _floats = OverlayPortalController(debugLabel: 'drop list');

  /// The scrolling of the list's lines.
  final rolls = ScrollController(debugLabel: 'drop list');

  /// The focus of each line of the list, as far as a list ever had lines.
  final _lines = <FocusNode>[];

  /// The form's own scrolling around the box, where it has one.
  ScrollableState? _form;

  /// The room under the box, down to the bottom of the screen or the keyboard, as the list was last laid out.
  double _room = double.infinity;

  /// Runs out once the keyboard stands where it was going: see [didChangeMetrics].
  Timer? _stands;

  /// The least the list is given, however little room there is: a line and a half, so there is a list.
  static const _least = 72.0;

  /// Kept clear between the list and the edges of the screen.
  static const _edge = 8.0;

  /// Room kept over the box when it goes to the top: its label stands on its upper edge.
  static const _over = 12.0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _form = Scrollable.maybeOf(context);
  }

  /// The keyboard came or went, or the screen was turned: the room under the box is another. A list that
  /// opened before the keyboard came (a tap on the box opens both) had the room the keyboard then takes,
  /// so once the keyboard stands the box is brought up for it, as when the list opened. Not before: the
  /// keyboard comes over many frames, and the text box moves itself into sight at each of them.
  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    if (!mounted || listLines == 0) return;
    setState(() {});
    _stands?.cancel();
    _stands = Timer(const Duration(milliseconds: 200), () {
      if (!mounted || listLines == 0) return;
      setState(() {}); // a frame first: the list is drawn where the box now stands, and its room is known
      WidgetsBinding.instance.addPostFrameCallback((_) => bringUp());
    });
  }

  @override
  void dispose() {
    _stands?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    rolls.dispose();
    for (final line in _lines) {
      line.dispose();
    }
    super.dispose();
  }

  /// The keyboard's focus of the line at [index] of the list.
  FocusNode lineFocus(int index) {
    while (_lines.length <= index) {
      _lines.add(FocusNode(debugLabel: 'drop list line ${_lines.length}'));
    }
    return _lines[index];
  }

  /// Whether the keyboard's focus is on a line of the list.
  bool get onLine => _lines.any((line) => line.hasPrimaryFocus);

  /// The list is there to be drawn.
  void showList() {
    if (mounted && !_floats.isShowing) _floats.show();
  }

  /// There is no list any more.
  void hideList() {
    if (mounted && _floats.isShowing) _floats.hide();
  }

  /// The list opened under the box, over what stands there. Where it has not the room for its lines (for
  /// [listEnough] of them) and the form scrolls, the box is brought up by as much as is missing, but never
  /// out of sight: on a screen too short for both, the box goes to the top and the list shows as far as
  /// there is room, so what is being typed can be read. The rest of the list is a scroll away, in the list
  /// itself. Call it once the list is drawn.
  void bringUp() {
    if (!mounted || listLines == 0 || !rolls.hasClients) return;
    final box = context.findRenderObject();
    final position = _form?.position;
    if (box == null || position == null) return;
    final viewport = RenderAbstractViewport.maybeOf(box);
    if (viewport == null) return;
    // what of the list does not show, and what of it would stand under the bottom of the screen
    var hidden = rolls.position.maxScrollExtent;
    final enough = listEnough;
    if (enough != null) hidden = math.min(hidden, math.max(0.0, enough - rolls.position.viewportDimension));
    final missing = hidden + math.max(0.0, _least - _room);
    if (missing <= 0) return;
    final toBox = viewport.getOffsetToReveal(box, 0).offset - _over;
    final to = math.min(position.pixels + missing, toBox).clamp(position.minScrollExtent, position.maxScrollExtent);
    if (to > position.pixels) {
      position.animateTo(to, duration: const Duration(milliseconds: 150), curve: Curves.easeOut);
    }
  }

  /// The arrows between the box and the lines of its list, and from line to line. The list lies over other
  /// boxes of the form, so which line is under which is said here and not left to where things stand on
  /// the screen: the arrow down from the box, once its cursor can go no further, is the first line; from a
  /// line it is the next one; the arrow up from the first line is the box again.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final lines = listLines;
    final direction = ArrowsLeaveTextBoxes.directionOf(event.logicalKey);
    if (direction != TraversalDirection.down && direction != TraversalDirection.up) return KeyEventResult.ignored;
    final down = direction == TraversalDirection.down;
    final at = lines == 0 ? -1 : _lines.indexWhere((line) => line.hasPrimaryFocus);
    if (at < 0) {
      if (!down || !boxFocus.hasPrimaryFocus || !ArrowsLeaveTextBoxes.isPlainPress(event)) {
        return KeyEventResult.ignored;
      }
      if (!arrowDownIsTheLists && !ArrowsLeaveTextBoxes.cursorAtEdge(boxText.value, direction!)) {
        return KeyEventResult.ignored;
      }
      // no list yet: a box that opens its list with the arrow does, and any other leaves the arrow alone
      if (lines == 0) return openListByArrow() ? KeyEventResult.handled : KeyEventResult.ignored;
      toLine(firstLine);
      return KeyEventResult.handled;
    }
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    if (down) {
      if (at + 1 < lines) toLine(at + 1);
    } else if (at == 0) {
      boxFocus.requestFocus();
    } else {
      toLine(at - 1);
    }
    return KeyEventResult.handled;
  }

  /// The line the arrow down goes to from the box: the first one, unless the list marks another.
  int get firstLine => 0;

  /// Whether the arrow down in the box is the list's wherever the cursor stands: a box of two letters has
  /// no other use for it. Otherwise the arrow moves the cursor for as long as it can, as in every text box.
  bool get arrowDownIsTheLists => false;

  /// The arrow down was pressed in the box while it has no list: a box that opens its list then does so
  /// and says true.
  bool openListByArrow() => false;

  /// The keyboard goes to a line of the list, and the list scrolls it into sight.
  void toLine(int index) {
    final line = lineFocus(index);
    line.requestFocus();
    seeLine(index);
  }

  /// The list scrolls as far as it takes for the line at [index] to show whole. With [middle], it scrolls
  /// the line to the middle of what shows, as far as the list goes: a list that opens on a line shows what
  /// is over it and under it.
  void seeLine(int index, {bool middle = false}) {
    final drawn = lineFocus(index).context?.findRenderObject();
    if (drawn == null || !rolls.hasClients) return;
    final position = rolls.position;
    if (middle) {
      position.ensureVisible(drawn, alignment: 0.5);
      return;
    }
    position.ensureVisible(drawn, alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd);
    position.ensureVisible(drawn, alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart);
  }

  /// The list, drawn over the screen under the box ([about] says where the box stands on it and how big
  /// both are): as wide as the box and what stands beside it, and as tall as its lines or as the room
  /// under the box, whichever is less.
  Widget _float(BuildContext context, OverlayChildLayoutInfo about) {
    if (listLines == 0 || about.childPaintTransform.determinant() == 0.0) return const SizedBox.shrink();
    final box = about.childSize;
    final stands = MatrixUtils.transformRect(about.childPaintTransform, Offset.zero & box);
    // the box scrolled out of the form's sight: its list does not hang in the air
    final form = _form?.context.findRenderObject(), over = Overlay.maybeOf(this.context)?.context.findRenderObject();
    if (form is RenderBox && over is RenderBox && form.attached && form.hasSize) {
      final sight = MatrixUtils.transformRect(form.getTransformTo(over), Offset.zero & form.size);
      if (stands.bottom < sight.top + 1 || stands.bottom > sight.bottom + 1) return const SizedBox.shrink();
    }
    // the screen without the keyboard: a dialog takes the keyboard out of what its children are told, so
    // the screen itself is asked
    final view = MediaQueryData.fromView(View.of(context));
    final screen = view.padding.deflateRect(view.viewInsets.deflateRect(Offset.zero & about.overlaySize));
    _room = screen.bottom - stands.bottom - _edge;
    // a list wider than its box stays on the screen: it goes left by what would stand off the right edge
    final wide = math.max(box.width, listMinWidth);
    final off = wide > box.width ? math.min(0.0, screen.right - _edge - (stands.left + wide)) : 0.0;
    final most = listMost;
    return Transform(
      transform: about.childPaintTransform.clone()..translateByDouble(off, box.height, 0, 1),
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: wide,
          height: math.max(most == null ? _room : math.min(_room, most), _least),
          child: Align(
            alignment: Alignment.topCenter,
            // a click on a line is not a click away from the box: the box keeps the keyboard. A touch on
            // anything else puts the list away, so what it lay over can be reached
            child: TextFieldTapRegion(onTapOutside: (_) => closeList(), child: buildList(context)),
          ),
        ),
      ),
    );
  }

  /// The box ([child]: the text box, and what stands beside it on its line) with its list under it. The
  /// focus going into the list is not the box being left.
  Widget dropUnder(Widget child) {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _onKey,
      onFocusChange: (has) {
        if (has) return boxEntered();
        closeList();
        boxLeft();
      },
      child: CallbackShortcuts(
        bindings: listLines == 0
            ? const <ShortcutActivator, VoidCallback>{}
            : {
                const SingleActivator(LogicalKeyboardKey.escape): () {
                  boxFocus.requestFocus();
                  closeList();
                },
              },
        child: OverlayPortal.overlayChildLayoutBuilder(controller: _floats, overlayChildBuilder: _float, child: child),
      ),
    );
  }
}

/// The card a list that drops down is drawn on: it lies over the boxes under it, and its shadow says so.
/// [mark] is the key of the card itself.
class DropCard extends StatelessWidget {
  const DropCard({super.key, required this.mark, required this.child});

  final Key mark;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Material(
        key: mark,
        color: scheme.surfaceContainerLow,
        elevation: 6,
        shadowColor: scheme.shadow,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          side: BorderSide(color: scheme.outlineVariant),
          borderRadius: BorderRadius.circular(8),
        ),
        clipBehavior: Clip.antiAlias,
        child: child,
      ),
    );
  }
}
