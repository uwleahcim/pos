import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../address_parts.dart';
import 'drop_list.dart';

/// The State box of an address: a list of the fifty states by their two letters, which typing narrows
/// down (Mike, 2026-11-26; docs/delivery.md, "The address in its parts").
///
/// - A tap on the box opens the list of all fifty, under the box and over what stands there
///   ([DropsList]), with the state the box holds marked and in the middle of what shows. A tap on a line
///   takes that state. The list shows six states and scrolls in itself for the rest.
/// - Typing shows the states that begin with what was typed, and the box takes no letter that no state
///   begins with: what stands in it is always on its way to one of the fifty ([fits]). Two letters are a
///   state. One letter is not yet: Enter takes the first state shown, and a box that is left with one
///   letter takes the state if only one begins with it and otherwise goes back to what it held.
/// - It is a text box all the same, so anything that fills an address in fills this one too: the list of
///   addresses under the street puts its state here as it does in every other box, and a state said by its
///   whole name ("Massachusetts", from a keyboard's own suggestion or a paste) is taken as its two
///   letters. What an address already says is kept as it is, also where it is none of the fifty ("DC").
/// - Two letters have nothing to select: the box shows no handles under its cursor and no menu over it,
///   which would lie over the first line of the list.
class StateBox extends StatefulWidget {
  const StateBox({
    super.key,
    required this.controller,
    required this.focusNode,
    this.fieldKey,
    this.decoration = const InputDecoration(),
    this.inputFormatters,
    this.onChanged,
    this.onNext,
  });

  final TextEditingController controller;
  final FocusNode focusNode;

  /// The key of the text box itself.
  final Key? fieldKey;
  final InputDecoration decoration;

  /// What else the form asks of what is typed, after the box's own rule.
  final List<TextInputFormatter>? inputFormatters;

  /// The box holds something else: a letter was typed or taken away, or a state was taken off the list.
  final VoidCallback? onChanged;

  /// Enter: on to the next box of the address.
  final VoidCallback? onNext;

  /// What the box holds as a state: its two letters. One letter alone is a state still being typed, and
  /// none yet.
  static String stateIn(String text) {
    final said = text.trim().toUpperCase();
    return said.length == 1 ? '' : said;
  }

  /// The box's own rule for what is typed: only what one of the fifty states begins with.
  ///
  /// - A state's whole name is its two letters, typed, pasted or put in by the keyboard's own suggestion.
  /// - One letter that a state begins with is taken, and a second one that makes a state with it. A second
  ///   letter that makes none is not taken: the box stays on its way to a state.
  /// - A letter typed where a state already stands starts another, wherever the cursor is ("MA" and then N
  ///   is "N", not "MAN").
  /// - Letters can always be taken away.
  static final fits = TextInputFormatter.withFunction((was, to) {
    if (to.text == was.text) return to;
    TextEditingValue put(String text) {
      if (text == to.text) return to;
      if (text == to.text.toUpperCase()) return to.copyWith(text: text);
      return TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
    }

    if (_takenAway(was.text.toUpperCase(), to.text.toUpperCase())) return put(to.text.toUpperCase());
    final typed = _typedIn(was.text, to.text);
    final whole = AddressParts.listedState(to.text) ?? AddressParts.listedState(typed);
    if (whole != null) return put(whole);
    final all = _letters(to.text);
    if (all.length <= 2 && AddressParts.statesFrom(all).isNotEmpty) return put(all);
    if (_letters(was.text).length == 1) return was; // on its way to a state, and this is not the way
    final letters = _letters(typed);
    for (final first in const [2, 1]) {
      if (letters.length < first) continue;
      final begin = letters.substring(0, first);
      if (AddressParts.statesFrom(begin).isNotEmpty) return put(begin);
    }
    return was;
  });

  static String _letters(String text) => text.toUpperCase().replaceAll(RegExp('[^A-Z]'), '');

  /// What was put into [to] that [was] did not have: what stands between what the two begin with and what
  /// they end on alike.
  static String _typedIn(String was, String to) {
    var head = 0;
    while (head < was.length && head < to.length && was[head] == to[head]) {
      head++;
    }
    var tail = 0;
    while (tail < was.length - head &&
        tail < to.length - head &&
        was[was.length - 1 - tail] == to[to.length - 1 - tail]) {
      tail++;
    }
    return to.substring(head, to.length - tail);
  }

  /// Whether [to] is [was] with letters taken away and none typed.
  static bool _takenAway(String was, String to) {
    if (to.length >= was.length) return false;
    var at = 0;
    for (final letter in to.split('')) {
      at = was.indexOf(letter, at) + 1;
      if (at == 0) return false;
    }
    return true;
  }

  @override
  State<StateBox> createState() => _StateBoxState();
}

class _StateBoxState extends State<StateBox> with WidgetsBindingObserver, DropsList<StateBox> {
  /// The states the list shows; null while there is no list.
  List<UsState>? _shown;

  /// Letters were typed since the keyboard came to the box: the list shows the states that begin with them.
  bool _narrowed = false;

  /// What the box held when the keyboard came to it: a letter left unfinished goes back to it.
  String _before = '';

  /// How large the type is, for the least width of the list and how much of it is enough.
  double _scale = 1;

  @override
  FocusNode get boxFocus => widget.focusNode;

  @override
  TextEditingController get boxText => widget.controller;

  @override
  int get listLines => _shown?.length ?? 0;

  /// A state's letters and its name on a line: wider than the box where the box is narrow.
  @override
  double get listMinWidth => 184 * _scale;

  /// Five states showing are enough: the list scrolls in itself, and the form does not jump for it.
  @override
  double? get listEnough => 200 * _scale;

  /// Six states and half of the next, which says there are more: fifty lines do not fill the screen.
  @override
  double? get listMost => 6 + 6.5 * math.max(40.0, 12 + 20 * _scale);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 1.6);
  }

  String get _text => widget.controller.text.trim().toUpperCase();

  /// The line the list marks: the state Enter takes while one letter is typed (the first shown), otherwise
  /// the state the box holds. None where the box holds none of the list.
  int get _marked {
    final shown = _shown;
    if (shown == null || shown.isEmpty) return -1;
    final text = _text;
    if (text.length == 1) return 0;
    return shown.indexWhere((state) => state.code == text);
  }

  @override
  int get firstLine => _marked < 0 ? 0 : _marked;

  @override
  bool get arrowDownIsTheLists => true;

  @override
  bool openListByArrow() {
    _open();
    return _shown != null;
  }

  void _put(String text) {
    if (widget.controller.text == text) return;
    widget.controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    widget.onChanged?.call();
  }

  /// Opens the list, or shows other states in it: all fifty, or the ones that begin with what was typed.
  void _open() {
    if (!mounted) return;
    final shown = _narrowed ? AddressParts.statesFrom(_text) : usStates;
    if (shown.isEmpty) return closeList(); // the box holds what an address said and no state begins with
    setState(() => _shown = shown);
    showList();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _shown == null) return;
      final marked = _marked;
      if (rolls.hasClients) marked < 0 ? rolls.jumpTo(0) : seeLine(marked, middle: true);
      bringUp();
    });
  }

  @override
  void closeList() {
    if (_shown == null || !mounted) return;
    setState(() => _shown = null);
    hideList();
  }

  /// The keyboard came to the box: what it holds now is what a letter left unfinished goes back to.
  @override
  void boxEntered() {
    if (!mounted) return;
    _before = StateBox.stateIn(widget.controller.text);
    _narrowed = false;
  }

  @override
  void boxLeft() {
    if (!mounted) return;
    _settle(takeFirst: false);
    _narrowed = false;
  }

  /// One letter is no state. Where only one state begins with it, or [takeFirst] says to take the first
  /// that does, the box takes that state; otherwise it goes back to what it held.
  void _settle({required bool takeFirst}) {
    final text = _text;
    if (text.length != 1) return;
    final begin = AddressParts.statesFrom(text);
    _put(begin.length == 1 || (takeFirst && begin.isNotEmpty) ? begin.first.code : _before);
  }

  void _typed(String _) {
    _narrowed = true;
    _open();
    widget.onChanged?.call();
  }

  /// A line of the list was tapped, or Enter pressed on it.
  void _take(UsState state) {
    widget.focusNode.requestFocus(); // before the line is gone, so the box and its list are not left
    _narrowed = false;
    closeList();
    _put(state.code);
  }

  void _entered() {
    _settle(takeFirst: true);
    _narrowed = false;
    closeList();
    widget.onNext?.call();
  }

  @override
  Widget buildList(BuildContext context) =>
      _StateList(states: _shown!, marked: _marked, onPick: _take, rolls: rolls, line: lineFocus);

  @override
  Widget build(BuildContext context) {
    return dropUnder(
      TextField(
        key: widget.fieldKey,
        controller: widget.controller,
        focusNode: widget.focusNode,
        textCapitalization: TextCapitalization.characters,
        textInputAction: TextInputAction.next,
        autocorrect: false,
        enableSuggestions: false,
        enableInteractiveSelection: false,
        inputFormatters: [StateBox.fits, ...?widget.inputFormatters],
        decoration: widget.decoration.copyWith(
          // it is a list: the arrow says so
          suffixIcon: const Icon(Icons.arrow_drop_down, size: 20),
          suffixIconConstraints: const BoxConstraints(minWidth: 26, minHeight: 24),
        ),
        onTap: _open,
        onChanged: _typed,
        onEditingComplete: _entered,
      ),
    );
  }
}

/// The states under the box, each a button: its two letters, and its name beside them. The one the box
/// holds, or that Enter would take, is marked.
class _StateList extends StatelessWidget {
  const _StateList({
    required this.states,
    required this.marked,
    required this.onPick,
    required this.rolls,
    required this.line,
  });

  final List<UsState> states;
  final int marked;
  final ValueChanged<UsState> onPick;
  final ScrollController rolls;

  /// The keyboard's focus of each line, by its place in the list.
  final FocusNode Function(int index) line;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final quiet = theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant);
    return DropCard(
      mark: const ValueKey('state-list'),
      child: SingleChildScrollView(
        controller: rolls,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (index, state) in states.indexed)
              Semantics(
                button: true,
                selected: index == marked,
                label: state.name,
                child: Material(
                  type: index == marked ? MaterialType.canvas : MaterialType.transparency,
                  color: index == marked ? scheme.secondaryContainer : null,
                  child: InkWell(
                    key: ValueKey('state-option:${state.code}'),
                    focusNode: line(index),
                    onTap: () => onPick(state),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 40),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        child: Row(
                          children: [
                            Text(state.code, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                            const SizedBox(width: 10),
                            Expanded(
                              child: ExcludeSemantics(
                                child: Text(state.name, style: quiet, maxLines: 1, overflow: TextOverflow.ellipsis),
                              ),
                            ),
                            if (index == marked) const SizedBox.shrink(key: ValueKey('state-marked')),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
