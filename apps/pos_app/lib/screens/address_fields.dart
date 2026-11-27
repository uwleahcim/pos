import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../address_list.dart';
import '../address_parts.dart';
import '../takeout.dart';
import 'address_box.dart';
import 'state_box.dart';

/// A delivery's address in its parts, each in a box of its own (docs/delivery.md, "The address in its
/// parts"): the number and the street, the apartment or unit, the town, the state and the ZIP.
///
/// The order still carries one line, and so does the form around these boxes: [address] holds it, written
/// from the boxes at every letter ([AddressParts.line]) and read into them whenever the form itself puts
/// another address there (the customer's last delivery, an order that is opened to be changed). A line
/// from before there were boxes is read as far as it can be told apart, and stays as it was written until
/// somebody changes a box: opening an order and saving it never rewrites its address.
///
/// The street's box has the list of addresses under it while it is typed in ([AddressBox]). A tap on a
/// line fills every box: with the parts the map service said, and with what the line reads as where it
/// said none. Where the service's list leaves the ZIP out (Google's), the hub is asked for it once, for
/// that line ([whole]), and the address is done when it has answered.
///
/// The state's box is a list of the fifty states ([StateBox]): a tap opens it, typing narrows it down, and
/// whatever fills an address in fills it like the other boxes.
///
/// Space is short on a phone: the unit and the town share a line there, and the state and the ZIP the
/// next. On anything wider the unit stands beside the street, and the town, the state and the ZIP share
/// the second line.
class AddressFields extends StatefulWidget {
  const AddressFields({
    super.key,
    required this.address,
    this.source,
    this.whole,
    this.homeState = '',
    this.onChanged,
    this.onDone,
    this.onChosen,
    this.onLeft,
    this.wait = const Duration(milliseconds: 300),
  });

  /// The address on one line, as the order carries it: the form's own box, which these boxes keep.
  final TextEditingController address;

  /// How the hub is asked for the list under the street; null where there is none to ask for.
  final AddressSource? source;

  /// How the hub is asked for the parts a tapped line left out; null where it is not asked.
  final AddressWhole? whole;

  /// The restaurant's own state, by its two letters: a form with no address yet starts with it in the
  /// state's box, since nearly every delivery stays in it. Empty where it is not known.
  final String homeState;

  /// A box was typed in, or a line was tapped.
  final VoidCallback? onChanged;

  /// The address is done, as far as it is typed: a line was tapped, or Enter in a box once the street has
  /// its town or its ZIP, or Enter in the last box.
  final VoidCallback? onDone;

  /// A line of the list was tapped and its address is whole: said in place of [onDone] where a form does
  /// more for an address somebody chose than for one that was typed (it picks the delivery fee for it
  /// whatever was picked before). Null: [onDone] is told, as of any address that is done.
  final VoidCallback? onChosen;

  /// All of the boxes were left for something else on the screen.
  final VoidCallback? onLeft;

  /// How long the typing in the street pauses before the hub is asked for its list.
  final Duration wait;

  /// The room, at the usual size of type, from which the boxes stand on two lines and not on three.
  static const wideFrom = 330.0;

  @override
  State<AddressFields> createState() => _AddressFieldsState();
}

class _AddressFieldsState extends State<AddressFields> {
  final _street = TextEditingController();
  final _unit = TextEditingController();
  final _city = TextEditingController();
  final _state = TextEditingController();
  final _zip = TextEditingController();
  final _unitFocus = FocusNode(debugLabel: 'address unit');
  final _cityFocus = FocusNode(debugLabel: 'address city');
  final _stateFocus = FocusNode(debugLabel: 'address state');
  final _zipFocus = FocusNode(debugLabel: 'address zip');

  /// The line as these boxes last read it off the form or wrote it there.
  String _held = '';

  /// The line the boxes were last filled from, and what it was read as: while the boxes say just that, the
  /// line stays as it was written.
  String _readLine = '';
  AddressParts _read = const AddressParts();

  /// Counts what was typed and tapped: an answer about a tapped line is for the boxes as they stood then.
  int _turn = 0;

  @override
  void initState() {
    super.initState();
    _take();
    widget.address.addListener(_outside);
  }

  @override
  void didUpdateWidget(AddressFields old) {
    super.didUpdateWidget(old);
    if (old.address != widget.address) {
      old.address.removeListener(_outside);
      widget.address.addListener(_outside);
      _take();
    } else if (old.homeState != widget.homeState) {
      _home(was: old.homeState);
    }
  }

  @override
  void dispose() {
    widget.address.removeListener(_outside);
    for (final box in [_street, _unit, _city, _state, _zip]) {
      box.dispose();
    }
    for (final focus in [_unitFocus, _cityFocus, _stateFocus, _zipFocus]) {
      focus.dispose();
    }
    super.dispose();
  }

  /// The form put another address in its box: the customer's last delivery, or none any more.
  void _outside() {
    if (oneLine(widget.address.text) == _held) return;
    _turn++;
    _take();
  }

  /// Reads the form's line into the boxes.
  void _take() {
    final line = oneLine(widget.address.text);
    final parts = AddressParts.parse(line);
    _held = line;
    _readLine = line;
    _read = parts;
    _fill(parts);
    _home();
  }

  /// With no address yet, the state's box starts on the restaurant's own; one that was typed stays.
  void _home({String was = ''}) {
    final empty = _street.text.isEmpty && _unit.text.isEmpty && _city.text.isEmpty && _zip.text.isEmpty;
    if (_held.isEmpty && empty && (_state.text.isEmpty || _state.text == was)) _put(_state, widget.homeState);
  }

  static void _put(TextEditingController box, String text) {
    if (box.text == text) return;
    box.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  void _fill(AddressParts parts) {
    _put(_street, parts.street);
    _put(_unit, parts.unit);
    _put(_city, parts.city);
    _put(_state, parts.state);
    _put(_zip, parts.zip);
  }

  /// What the boxes hold.
  AddressParts get _now => AddressParts(
    street: oneLine(_street.text),
    unit: oneLine(_unit.text),
    city: oneLine(_city.text),
    state: StateBox.stateIn(_state.text), // one letter is a state still being typed, and none yet
    zip: _zip.text.trim(),
  );

  /// Writes the boxes on the form's line: as it was written, while they say what it was read as. A whole
  /// address in the first box ([_apart]) is written as its parts say it, at every letter: the order
  /// carries the same line whether or not the box was left before the form was saved.
  void _write() {
    final now = _now;
    final line = now == _read ? _readLine : (_apart(now) ?? now).line;
    if (line == _held) return;
    _held = line;
    widget.address.text = line;
  }

  void _typed() {
    _turn++;
    _write();
    widget.onChanged?.call();
  }

  /// A line of the list was tapped: every box takes its part, and none keeps what it held. Where the line
  /// names something more to ask ([AddressSuggestion.ref]) and has no ZIP, the hub is asked for it, and
  /// the address is done once it has answered: so whoever is told that it is done hears of the whole
  /// address, once.
  Future<void> _picked(AddressSuggestion picked) async {
    final turn = ++_turn;
    final parts = picked.boxes;
    _read = parts;
    _readLine = picked.parts == null ? oneLine(picked.address) : parts.line;
    _fill(parts);
    _write();
    widget.onChanged?.call();
    final whole = widget.whole;
    if (whole != null && picked.ref != null && parts.zip.isEmpty) {
      AddressParts? more;
      try {
        more = await whole(picked);
      } on Object {
        more = null; // a help, like the list: the boxes keep what the line said
      }
      if (!mounted || turn != _turn) return; // typed in meanwhile: nobody is done with it
      if (more != null) {
        final filled = parts.copyWith(
          city: parts.city.isEmpty ? more.city : null,
          state: parts.state.isEmpty ? more.state : null,
          zip: more.zip,
        );
        if (filled != parts) {
          _fill(filled);
          _write();
          widget.onChanged?.call();
        }
      }
    }
    (widget.onChosen ?? widget.onDone)?.call();
  }

  /// Somebody typed the whole address in the first box, commas and all, as it used to be typed: what its
  /// parts are, each for its own box. Null where the first box holds no more than a street. While the
  /// other boxes are empty, the state keeps what its box held where the address names none. Over boxes
  /// that hold something, only an address typed as far as its state or its ZIP is taken for a whole one
  /// and replaces them: "12 Elm St, side door" is no new town.
  AddressParts? _apart(AddressParts now) {
    if (!now.street.contains(',')) return null;
    final read = AddressParts.parse(now.street);
    if (read.street == now.street) return null;
    final alone = now.unit.isEmpty && now.city.isEmpty && now.zip.isEmpty;
    if (alone) return read.copyWith(state: read.state.isEmpty ? now.state : null);
    return read.state.isNotEmpty || read.zip.isNotEmpty ? read : null;
  }

  /// The first box is left with a whole address in it ([_apart]): each part goes to its own box. The line
  /// the order carries is the same before and after.
  void _tidy() {
    if (!mounted) return;
    final apart = _apart(_now);
    if (apart == null) return;
    _fill(apart);
    _write();
    widget.onChanged?.call();
  }

  /// Enter in a box goes on to the next one ([next]; none after the last). It also says that so much of
  /// the address is done, once that is enough to find it by: a street with its town or its ZIP. The last
  /// box says it of whatever is typed, as the one box did before there were several.
  void _entered(FocusNode? next) {
    _tidy();
    final now = _now;
    next?.requestFocus();
    if (next == null || (now.street.isNotEmpty && (now.city.isNotEmpty || now.zip.isNotEmpty))) {
      widget.onDone?.call();
    }
  }

  /// A box takes no more letters than the whole line has room for ([eventTextMax]): what is pasted is cut
  /// to fit, and what is there can always be taken away.
  TextInputFormatter _room(AddressParts Function(AddressParts now, String text) put) =>
      TextInputFormatter.withFunction((was, to) {
        if (to.text.length <= was.text.length) return to;
        final over = put(_now, oneLine(to.text)).line.length - eventTextMax;
        if (over <= 0) return to;
        final keep = to.text.length - over;
        if (keep <= was.text.length) return was;
        return TextEditingValue(
          text: to.text.substring(0, keep),
          selection: TextSelection.collapsed(offset: keep),
        );
      });

  InputDecoration _small(String label) => InputDecoration(
    labelText: label,
    counterText: '',
    contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
  );

  @override
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (has) {
        if (has) return;
        _tidy();
        widget.onLeft?.call();
      },
      child: LayoutBuilder(
        builder: (context, room) {
          // large type needs the room that many times over
          final scale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 1.6);
          final wide = room.maxWidth >= AddressFields.wideFrom * scale;
          const gap = SizedBox(width: 8);
          final unitRoom = wide ? 112 * scale : (room.maxWidth - 8) * 2 / 5;
          final unit = TextField(
            key: const ValueKey('event-address:unit'),
            controller: _unit,
            focusNode: _unitFocus,
            textCapitalization: TextCapitalization.words,
            textInputAction: TextInputAction.next,
            inputFormatters: [
              LengthLimitingTextInputFormatter(20),
              _room((now, text) => now.copyWith(unit: text)),
            ],
            // its whole name where the box has the room for it
            decoration: _small(unitRoom >= 100 * scale ? 'Apt / unit' : 'Apt'),
            onChanged: (_) => _typed(),
            onEditingComplete: () => _entered(_cityFocus),
          );
          final city = TextField(
            key: const ValueKey('event-address:city'),
            controller: _city,
            focusNode: _cityFocus,
            textCapitalization: TextCapitalization.words,
            textInputAction: TextInputAction.next,
            inputFormatters: [
              LengthLimitingTextInputFormatter(60),
              _room((now, text) => now.copyWith(city: text)),
            ],
            decoration: _small('City'),
            onChanged: (_) => _typed(),
            onEditingComplete: () => _entered(_stateFocus),
          );
          // a list of the fifty states, which typing narrows down; a tap on the list of addresses fills it
          // like any other box
          final state = StateBox(
            fieldKey: const ValueKey('event-address:state'),
            controller: _state,
            focusNode: _stateFocus,
            inputFormatters: [_room((now, text) => now.copyWith(state: StateBox.stateIn(text)))],
            decoration: _small('State'),
            onChanged: _typed,
            onNext: () => _entered(_zipFocus),
          );
          final zip = TextField(
            key: const ValueKey('event-address:zip'),
            controller: _zip,
            focusNode: _zipFocus,
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.done,
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp('[0-9-]')),
              LengthLimitingTextInputFormatter(10),
              _room((now, text) => now.copyWith(zip: text)),
            ],
            decoration: _small('ZIP'),
            onChanged: (_) => _typed(),
            onSubmitted: (_) => _entered(null),
          );
          final street = AddressBox(
            fieldKey: const ValueKey('event-address'),
            controller: _street,
            source: widget.source,
            wait: widget.wait,
            inputFormatters: [_room((now, text) => now.copyWith(street: text))],
            decoration: const InputDecoration(
              labelText: 'Deliver to',
              hintText: 'Number and street',
              prefixIcon: Icon(Icons.place_outlined),
              counterText: '',
            ),
            onChanged: _typed,
            onLeft: _tidy,
            onPicked: _picked,
            onNext: () => _entered(_unitFocus),
            beside: wide ? SizedBox(width: unitRoom, child: unit) : null,
          );
          return Column(
            key: const ValueKey('address-fields'),
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              street,
              const SizedBox(height: 8),
              if (wide)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: city),
                    gap,
                    SizedBox(width: 84 * scale, child: state),
                    gap,
                    SizedBox(width: 104 * scale, child: zip),
                  ],
                )
              else ...[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 2, child: unit),
                    gap,
                    Expanded(flex: 3, child: city),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 2, child: state),
                    gap,
                    Expanded(flex: 3, child: zip),
                  ],
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}
