import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../address_list.dart';
import '../takeout.dart';
import 'drop_list.dart';
import 'fee_lookup.dart';
import 'service_badge.dart';

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
/// out of sight. All of that is [DropsList], which the state's box shares.
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

class _AddressBoxState extends State<AddressBox> with WidgetsBindingObserver, DropsList<AddressBox> {
  final _focus = FocusNode(debugLabel: 'address box');
  Timer? _pause;
  int _turn = 0;
  AddressSuggestions? _list;

  @override
  FocusNode get boxFocus => _focus;

  @override
  TextEditingController get boxText => widget.controller;

  @override
  int get listLines => _list?.suggestions.length ?? 0;

  @override
  void closeList() => _close();

  @override
  void boxLeft() => widget.onLeft?.call();

  @override
  Widget buildList(BuildContext context) => _AddressList(list: _list!, onPick: _pick, rolls: rolls, line: lineFocus);

  @override
  void dispose() {
    _pause?.cancel();
    _focus.dispose();
    super.dispose();
  }

  /// Puts [list] under the box, or none.
  void _show(AddressSuggestions? list) {
    if (!mounted) return;
    setState(() => _list = list);
    if (list != null) {
      showList();
    } else {
      hideList();
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
    WidgetsBinding.instance.addPostFrameCallback((_) => bringUp());
  }

  void _close() {
    _pause?.cancel();
    _turn++;
    if (_list != null) _show(null);
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
    return dropUnder(
      beside == null
          ? box
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: box),
                const SizedBox(width: 8),
                beside,
              ],
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
    return DropCard(
      mark: const ValueKey('address-list'),
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
    );
  }
}
