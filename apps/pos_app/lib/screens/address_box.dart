import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../address_list.dart';
import '../takeout.dart';
import 'fee_lookup.dart';
import 'service_badge.dart';
import 'text_arrows.dart';

/// A box a street address is typed in, with a list under it of what the letters typed so far could become
/// (docs/delivery.md, "A list of addresses while typing"). The hub says what is listed ([source]): the
/// restaurant's own earlier deliveries first, and a map service's answers where a manager turned that on.
///
/// A tap on a line puts it in the box. Nothing else does: what was typed stands until somebody taps, and
/// Enter says the address is done as it is typed. The list is asked for once the typing pauses, never for
/// an address the form itself filled in, and it goes when the box is left. With a keyboard, the arrow down
/// goes into the list, Enter takes the line and Escape closes the list.
///
/// The list drops down over whatever stands under the box and moves nothing (Mike, 2026-11-26): it is
/// drawn on the screen's overlay, as wide as the box, and no taller than the room between the box and the
/// bottom of the screen or the keyboard. A list longer than that scrolls in itself. Where the form
/// scrolls, the box is brought up to make that room, and the list is put away while the box is scrolled
/// out of sight.
///
/// A list that holds a map service's answer carries its name ([MapCredit]), as its terms want, and before
/// it a tiny badge of that service with a ring for how much of its free amount is left this month
/// ([ServiceBadge]): at a glance who answered and how far the free amount goes. Both stand at the top of
/// the list, where nothing moves them.
class AddressBox extends StatefulWidget {
  const AddressBox({
    super.key,
    required this.controller,
    this.source,
    this.fieldKey,
    this.decoration = const InputDecoration(),
    this.maxLength,
    this.inputFormatters,
    this.onChanged,
    this.onDone,
    this.onLeft,
    this.onPicked,
    this.onNext,
    this.beside,
    this.wait = const Duration(milliseconds: 300),
  });

  final TextEditingController controller;

  /// How the hub is asked for the list; null where there is none to ask for, and the box is a box.
  final AddressSource? source;

  /// The key of the text box itself.
  final Key? fieldKey;
  final InputDecoration decoration;
  final int? maxLength;
  final List<TextInputFormatter>? inputFormatters;

  /// Something was typed, or a line was tapped.
  final VoidCallback? onChanged;

  /// The address is done: Enter, or a line was tapped.
  final VoidCallback? onDone;

  /// The box and its list were left for something else on the screen.
  final VoidCallback? onLeft;

  /// A line was tapped, on a form that has more boxes than this one for an address ([AddressFields]): the
  /// line is handed over, and nothing is put in this box by itself. [onChanged] and [onDone] are then the
  /// form's to call.
  final ValueChanged<AddressSuggestion>? onPicked;

  /// Enter goes on to the next box of the address, and does not say that the address is done.
  final VoidCallback? onNext;

  /// A box that stands beside this one, on the same line: the list opens under both.
  final Widget? beside;

  /// How long the typing pauses before the hub is asked.
  final Duration wait;

  /// Letters typed before a list is asked for.
  static const from = 2;

  @override
  State<AddressBox> createState() => _AddressBoxState();
}

class _AddressBoxState extends State<AddressBox> with WidgetsBindingObserver {
  final _focus = FocusNode(debugLabel: 'address box');
  final _floats = OverlayPortalController(debugLabel: 'address list');
  final _rolls = ScrollController(debugLabel: 'address list');

  /// The focus of each line of the list, as far as a list ever had lines.
  final _lines = <FocusNode>[];
  Timer? _pause;
  int _turn = 0;
  AddressSuggestions? _list;

  /// The form's own scrolling around the box, where it has one.
  ScrollableState? _form;

  /// The room under the box, down to the bottom of the screen or the keyboard, as the list was last laid out.
  double _room = double.infinity;

  /// The least the list is given, however little room there is: a line and a half, so there is a list.
  static const _least = 72.0;

  /// Kept clear between the list and the bottom of the screen.
  static const _edge = 8.0;

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

  /// The keyboard came or went, or the screen was turned: the room under the box is another.
  @override
  void didChangeMetrics() {
    if (mounted && _list != null) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pause?.cancel();
    _focus.dispose();
    _rolls.dispose();
    for (final line in _lines) {
      line.dispose();
    }
    super.dispose();
  }

  FocusNode _line(int index) {
    while (_lines.length <= index) {
      _lines.add(FocusNode(debugLabel: 'address line ${_lines.length}'));
    }
    return _lines[index];
  }

  /// Puts [list] under the box, or none.
  void _show(AddressSuggestions? list) {
    if (!mounted) return;
    setState(() => _list = list);
    if (list != null) {
      _floats.show();
    } else if (_floats.isShowing) {
      _floats.hide();
    }
  }

  void _typed(String _) {
    widget.onChanged?.call();
    _pause?.cancel();
    _turn++; // an answer still on its way is for other letters
    if (widget.source == null) return;
    if (oneLine(widget.controller.text).length < AddressBox.from) {
      if (_list != null) _show(null);
      return;
    }
    _pause = Timer(widget.wait, _ask);
  }

  Future<void> _ask() async {
    final source = widget.source, typed = widget.controller.text;
    if (source == null || !mounted) return;
    final turn = ++_turn;
    AddressSuggestions? answer;
    try {
      answer = await source(typed);
    } on Object {
      answer = null; // a list is a help: no list, and no word about it
    }
    if (!mounted || turn != _turn || widget.controller.text != typed) return;
    _show(answer == null || answer.suggestions.isEmpty ? null : answer);
    if (_list == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => _bringUp());
  }

  /// The list opened under the box, over what stands there. Where it has not the room for all its lines
  /// and the form scrolls, the box is brought up by as much as is missing, but never out of sight: on a
  /// screen too short for both, the box goes to the top and the list shows as far as there is room, so
  /// what is being typed can be read. The rest of the list is a scroll away, in the list itself.
  void _bringUp() {
    if (!mounted || _list == null || !_rolls.hasClients) return;
    final box = context.findRenderObject();
    final position = _form?.position;
    if (box == null || position == null) return;
    final viewport = RenderAbstractViewport.maybeOf(box);
    if (viewport == null) return;
    // what of the list does not show, and what of it would stand under the bottom of the screen
    final missing = _rolls.position.maxScrollExtent + math.max(0.0, _least - _room);
    if (missing <= 0) return;
    final toBox = viewport.getOffsetToReveal(box, 0).offset - _over;
    final to = math.min(position.pixels + missing, toBox).clamp(position.minScrollExtent, position.maxScrollExtent);
    if (to > position.pixels) {
      position.animateTo(to, duration: const Duration(milliseconds: 150), curve: Curves.easeOut);
    }
  }

  /// Room kept over the box when it goes to the top: its label stands on its upper edge.
  static const _over = 12.0;

  void _close() {
    _pause?.cancel();
    _turn++;
    if (_list != null) _show(null);
  }

  /// The arrows between the box and the lines of its list, and from line to line. The list lies over other
  /// boxes of the form, so which line is under which is said here and not left to where things stand on
  /// the screen: the arrow down from the box, once its cursor can go no further, is the first line; from a
  /// line it is the next one; the arrow up from the first line is the box again.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final list = _list;
    final direction = ArrowsLeaveTextBoxes.directionOf(event.logicalKey);
    if (list == null || (direction != TraversalDirection.down && direction != TraversalDirection.up)) {
      return KeyEventResult.ignored;
    }
    final down = direction == TraversalDirection.down;
    final at = _lines.indexWhere((line) => line.hasPrimaryFocus);
    if (at < 0) {
      if (!down || !_focus.hasPrimaryFocus || !ArrowsLeaveTextBoxes.isPlainPress(event)) return KeyEventResult.ignored;
      if (!ArrowsLeaveTextBoxes.cursorAtEdge(widget.controller.value, direction!)) return KeyEventResult.ignored;
      _to(0);
      return KeyEventResult.handled;
    }
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    if (down) {
      if (at + 1 < list.suggestions.length) _to(at + 1);
    } else if (at == 0) {
      _focus.requestFocus();
    } else {
      _to(at - 1);
    }
    return KeyEventResult.handled;
  }

  /// The keyboard goes to a line of the list, and the list scrolls it into sight.
  void _to(int index) {
    final line = _line(index);
    line.requestFocus();
    final drawn = line.context?.findRenderObject();
    if (drawn == null || !_rolls.hasClients) return;
    final rolls = _rolls.position;
    rolls.ensureVisible(drawn, alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd);
    rolls.ensureVisible(drawn, alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart);
  }

  /// The list, drawn over the screen under the box ([about] says where the box stands on it and how big
  /// both are): as wide as the box and what stands beside it, and as tall as its lines or as the room
  /// under the box, whichever is less.
  Widget _float(BuildContext context, OverlayChildLayoutInfo about) {
    final list = _list;
    if (list == null || about.childPaintTransform.determinant() == 0.0) return const SizedBox.shrink();
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
    return Transform(
      transform: about.childPaintTransform.clone()..translateByDouble(0, box.height, 0, 1),
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: box.width,
          height: math.max(_room, _least),
          child: Align(
            alignment: Alignment.topCenter,
            // a click on a line is not a click away from the box: the box keeps the keyboard. A touch on
            // anything else puts the list away, so what it lay over can be reached
            child: TextFieldTapRegion(
              onTapOutside: (_) => _close(),
              child: _AddressList(list: list, onPick: _pick, rolls: _rolls, line: _line),
            ),
          ),
        ),
      ),
    );
  }

  void _pick(AddressSuggestion picked) {
    _focus.requestFocus(); // before the line that was tapped is gone, so the box and its list are not left
    final onPicked = widget.onPicked;
    if (onPicked != null) {
      _close();
      onPicked(picked);
      return;
    }
    widget.controller.value = TextEditingValue(
      text: picked.address,
      selection: TextSelection.collapsed(offset: picked.address.length),
    );
    _close();
    widget.onChanged?.call();
    widget.onDone?.call();
  }

  @override
  Widget build(BuildContext context) {
    final list = _list;
    final onNext = widget.onNext, beside = widget.beside;
    final box = TextField(
      key: widget.fieldKey,
      focusNode: _focus,
      controller: widget.controller,
      maxLength: widget.maxLength,
      inputFormatters: widget.inputFormatters,
      textCapitalization: TextCapitalization.words,
      keyboardType: TextInputType.streetAddress,
      textInputAction: onNext == null ? null : TextInputAction.next,
      decoration: widget.decoration,
      onChanged: _typed,
      // the next box of the address, named by the form: the list's own lines are not it
      onEditingComplete: onNext == null
          ? null
          : () {
              _close();
              onNext();
            },
      onSubmitted: onNext != null
          ? null
          : (_) {
              _close();
              widget.onDone?.call();
            },
    );
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _onKey,
      onFocusChange: (has) {
        if (has) return;
        _close();
        widget.onLeft?.call();
      },
      child: CallbackShortcuts(
        bindings: list == null
            ? const <ShortcutActivator, VoidCallback>{}
            : {
                const SingleActivator(LogicalKeyboardKey.escape): () {
                  _focus.requestFocus();
                  _close();
                },
              },
        child: OverlayPortal.overlayChildLayoutBuilder(
          controller: _floats,
          overlayChildBuilder: _float,
          child: beside == null
              ? box
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: box),
                    const SizedBox(width: 8),
                    beside,
                  ],
                ),
        ),
      ),
    );
  }
}

/// The lines under the box, each a button, and over them the map service's badge and name when one of them
/// is its answer. It lies over the form like a card: where it has less room than its lines need, the lines
/// scroll ([rolls]) under the service's name, which stays.
class _AddressList extends StatelessWidget {
  const _AddressList({required this.list, required this.onPick, required this.rolls, required this.line});

  final AddressSuggestions list;
  final ValueChanged<AddressSuggestion> onPick;
  final ScrollController rolls;

  /// The keyboard's focus of each line, by its place in the list.
  final FocusNode Function(int index) line;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final quiet = theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant);
    final credit = list.credit;
    final service = list.service;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Material(
        key: const ValueKey('address-list'),
        color: scheme.surfaceContainerLow,
        // it lies over the boxes under it, and its shadow says so
        elevation: 6,
        shadowColor: scheme.shadow,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          side: BorderSide(color: scheme.outlineVariant),
          borderRadius: BorderRadius.circular(8),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // who answered and what it has left, at the top: under the box, where the list's length and the
            // addresses' lengths never move it
            if (credit != null)
              Padding(
                padding: const EdgeInsetsDirectional.only(start: 11, end: 12, top: 6, bottom: 2),
                child: Row(
                  children: [
                    if (service != null) ...[
                      ServiceBadge(
                        key: const ValueKey('address-badge'),
                        service: service,
                        title: list.title ?? credit,
                        share: list.share,
                        words: list.leftWords,
                      ),
                      const SizedBox(width: 7),
                    ],
                    // a long name on a narrow screen with large type is made smaller, never cut or broken:
                    // its terms want it whole
                    Flexible(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: AlignmentDirectional.centerStart,
                        child: MapCredit(credit, mark: const ValueKey('address-credit')),
                      ),
                    ),
                  ],
                ),
              ),
            Flexible(
              child: SingleChildScrollView(
                controller: rolls,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final (index, one) in list.suggestions.indexed)
                      Semantics(
                        button: true,
                        label: one.theirs
                            ? 'Their earlier delivery'
                            : one.own
                            ? 'An earlier delivery'
                            : null,
                        child: InkWell(
                          key: ValueKey('address-suggestion:$index'),
                          focusNode: line(index),
                          onTap: () => onPick(one),
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(minHeight: 40),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                              child: Row(
                                children: [
                                  Icon(
                                    one.theirs
                                        ? Icons.person_pin_circle_outlined
                                        : one.own
                                        ? Icons.history
                                        : Icons.place_outlined,
                                    size: 18,
                                    color: scheme.onSurfaceVariant,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text.rich(
                                      TextSpan(
                                        children: [
                                          TextSpan(
                                            text: one.main,
                                            style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                                          ),
                                          if (one.rest.isNotEmpty) TextSpan(text: '  ${one.rest}', style: quiet),
                                        ],
                                      ),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
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
            ),
          ],
        ),
      ),
    );
  }
}
