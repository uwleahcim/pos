import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../delivery_fee.dart';
import 'fee_lookup.dart';
import 'menu_panel.dart';
import 'theme.dart';

/// What a delivery costs the customer, picked on its form (docs/delivery.md, "The delivery fee"): the
/// location's prices as the menu's own buttons, each headed by what it costs over "Up to 2.5 mi", and "No
/// fee". A fee the order carries that the list no longer offers at that price stays, as a button of its
/// own, until another is picked.
///
/// The price heads the button as its label, not as the badge a dish's price is: a form is narrow on a
/// phone, and a label gives way where a badge would not. Where a button is too narrow for "Up to 4.5 mi" on
/// one line (a small phone, or large type) it says "4.5 mi" and the heading says "up to", so the miles or
/// minutes are never the part that is cut off.
///
/// More than four prices are not a button each ([DeliveryFees.crowded]; the owner's words, 2026-11-27:
/// "delivery fees with lots of options (over 4) change it something that fit better on the screen than a
/// bunch of buttons"). They are one line that says the fee picked, and a tap on it opens the whole list
/// from the bottom of the screen: each price on a line of its own, how far it reaches on the left and what
/// it costs on the right, the one picked marked. A tap on a line picks it and puts the list away. A slider
/// was his first thought; a list was chosen over it because a slider has no place for "nobody picked yet",
/// "No fee" or the custom fee, shows one price at a time, and moves under a thumb that only meant to scroll
/// the form.
///
/// Where the location lets it ([DeliveryFees.offersCustom], "A custom fee for a delivery further away"),
/// the custom fee is one more of the choices, after the prices: "Custom fee, past 8 mi". Picked, a box
/// under the choices takes what this delivery costs. The form holds what is typed as it is typed
/// ([FeePick.typed]) and cannot be finished on a custom fee with no amount ([FeePick.unfinished]).
///
/// Where the hub looks the distance up, a line over the buttons says how far the address is; the form
/// picks the band for it (the custom fee for an address further than them all), and any other can still be
/// tapped.
class FeePicker extends StatefulWidget {
  const FeePicker({
    super.key,
    required this.fees,
    required this.pick,
    required this.onPick,
    this.taken,
    this.asker,
    this.address = '',
    this.onLookUp,
  });

  /// Whether a form shows the picker at all: the location charges a fee, or the order carries one.
  static bool shown(DeliveryFees? fees, OrderFee? taken) => (fees?.asks ?? false) || (taken != null && !taken.none);

  /// The location's prices; null from a hub that charges none.
  final DeliveryFees? fees;

  /// A band's reach, [FeePick.none], [FeePick.kept], a custom fee as far as it is typed ([FeePick.typed]),
  /// or null while nobody picked.
  final String? pick;
  final ValueChanged<String> onPick;

  /// The fee the order carries, when it is being changed.
  final OrderFee? taken;

  /// Where the hub looks the distance up ("Looking the distance up"): what it said of [address] stands
  /// over the prices, and [onLookUp] asks, or asks again.
  final DistanceAsker? asker;
  final String address;
  final LookUp? onLookUp;

  /// The narrowest a button may be, at type of the usual size, and still say "Up to 240 min" on one line.
  static const roomy = 120.0;

  @override
  State<FeePicker> createState() => _FeePickerState();
}

/// One of the choices: a price of the list, the fee the order carries, the custom fee, or no fee.
class _Choice {
  const _Choice({
    required this.mark,
    required this.pick,
    required this.heading,
    required this.name,
    required this.selected,
    this.price = '',
    this.under,
  });

  /// What its button, or its line of the list, is found by: "fee:4.5", "fee:custom", "fee:none".
  final String mark;

  /// What the form is told when it is tapped ([FeePick]).
  final String pick;

  /// What heads its button, and leads the one line of a long list: what it costs, "$5.00"; nothing for no
  /// fee.
  final String heading;

  /// How far it reaches, "Up to 4.5 mi", or what it is.
  final String name;
  final bool selected;

  /// What it costs, alone, for the right side of its line of the list; nothing where there is no amount.
  final String price;

  /// A second line for the list, where the name alone does not say it all.
  final String? under;

  bool get custom => FeePick.isCustom(pick);
}

class _FeePickerState extends State<FeePicker> {
  late final _amount = TextEditingController(text: FeePick.typedOf(_picked));
  final _amountFocus = FocusNode(debugLabel: 'custom delivery fee');
  final _listFocus = FocusNode(debugLabel: 'delivery fee list');

  bool get _listed => widget.taken == null || FeePick.listed(widget.taken!, widget.fees);

  /// What is picked. What the order carries reads as the list's own choice while the list still has it.
  String? get _picked {
    final taken = widget.taken;
    return widget.pick == FeePick.kept && taken != null && _listed ? taken.pick : widget.pick;
  }

  @override
  void didUpdateWidget(FeePicker old) {
    super.didUpdateWidget(old);
    // the form holds what is typed: where it says something else (the map asked for a custom fee for
    // another address, the dialog was told another order), the box follows
    final picked = _picked;
    if (old.pick != widget.pick && FeePick.isCustom(picked) && FeePick.typedOf(picked) != _amount.text.trim()) {
      _amount.text = FeePick.typedOf(picked);
    }
  }

  @override
  void dispose() {
    _amount.dispose();
    _amountFocus.dispose();
    _listFocus.dispose();
    super.dispose();
  }

  /// A choice was tapped. The custom fee comes back with what was typed of it before, and the keyboard
  /// goes to its box: what it costs is the next thing to say.
  void _tap(_Choice choice) {
    if (!choice.custom) return widget.onPick(choice.pick);
    widget.onPick(FeePick.typed(_amount.text));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _amountFocus.requestFocus();
    });
  }

  /// The choices in the order they are offered: what the order carries and the list has no more, the
  /// prices nearest first, the custom fee, no fee. [reach] words how far a price goes.
  List<_Choice> _choices(String Function(String by, String upTo) reach, {required bool narrow}) {
    final fees = widget.fees, taken = widget.taken, picked = _picked;
    final typed = FeePick.amountOf(picked);
    final furthest = fees?.furthest;
    return [
      if (taken != null && !_listed)
        _Choice(
          mark: 'fee:kept',
          pick: FeePick.kept,
          // the website's own fee is no band: it stays until somebody picks one of the list's
          heading: taken.onWebsite ? feeWords(taken.amount) : '${feeWords(taken.amount)} · as taken',
          name: taken.onWebsite
              ? (narrow ? 'Website' : 'On the website')
              : taken.custom
              ? 'Custom fee'
              : reach(taken.by!, taken.upTo!),
          selected: picked == FeePick.kept,
          price: feeWords(taken.amount),
          under: taken.onWebsite ? null : 'As it was taken',
        ),
      if (fees != null && fees.asks)
        for (final band in fees.bands)
          _Choice(
            mark: 'fee:${band.upTo}',
            pick: band.upTo,
            heading: feeWords(band.fee),
            name: reach(fees.by, band.upTo),
            selected: picked == band.upTo,
            price: feeWords(band.fee),
          ),
      if (fees != null && fees.offersCustom && furthest != null)
        _Choice(
          mark: 'fee:custom',
          pick: FeePick.custom,
          // what was typed heads it once it is an amount, as a price heads its own
          heading: FeePick.isCustom(picked) && typed != null ? feeWords(typed) : 'Custom fee',
          name: pastWords(fees.by, furthest.upTo),
          selected: FeePick.isCustom(picked),
          price: FeePick.isCustom(picked) && typed != null ? feeWords(typed) : '',
          under: 'Type what this delivery costs',
        ),
      _Choice(mark: 'fee:none', pick: FeePick.none, heading: '', name: 'No fee', selected: picked == FeePick.none),
    ];
  }

  /// The whole list, up from the bottom of the screen: a line each, how far on the left and what it costs
  /// on the right, the one picked marked. A tap picks and puts it away.
  Future<void> _openList(List<_Choice> choices) async {
    // the keyboard leaves the address for the line that was tapped, and comes back to it afterwards: not to
    // a text box, which would bring the keys up again
    _listFocus.requestFocus();
    final found = widget.asker?.found;
    final tapped = await showModalBottomSheet<_Choice>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      // on a tablet the list stays a list: what a price costs is read beside how far it reaches
      constraints: const BoxConstraints(maxWidth: 440),
      builder: (context) {
        final theme = Theme.of(context);
        final scheme = theme.colorScheme;
        return SafeArea(
          child: SingleChildScrollView(
            key: const ValueKey('fee-list-sheet'),
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Delivery fee', style: theme.textTheme.titleMedium),
                      if (found != null)
                        Text(
                          '${found.measured.words} drive',
                          key: const ValueKey('fee-list-drive'),
                          style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                for (final choice in choices)
                  FeeListLine(
                    key: ValueKey(choice.mark),
                    title: choice.custom ? 'Custom fee · ${choice.name.toLowerCase()}' : choice.name,
                    under: choice.under,
                    price: choice.price,
                    selected: choice.selected,
                    onTap: () => Navigator.of(context).pop(choice),
                  ),
              ],
            ),
          ),
        );
      },
    );
    if (tapped != null && mounted) _tap(tapped);
  }

  /// The one line that stands for a long list: the fee picked, and that there is more to it.
  Widget _line(ThemeData theme, List<_Choice> choices) {
    final scheme = theme.colorScheme;
    final at = choices.where((choice) => choice.selected).firstOrNull;
    final on = at != null;
    final ink = on ? scheme.onPrimaryContainer : scheme.onSurface;
    return Semantics(
      button: true,
      child: Material(
        color: on ? scheme.primaryContainer : scheme.surfaceContainerLowest,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: on ? scheme.primary : scheme.outlineVariant, width: on ? 2 : 1),
        ),
        child: InkWell(
          key: const ValueKey('fee-list'),
          borderRadius: BorderRadius.circular(14),
          focusNode: _listFocus,
          onTap: () => _openList(choices),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 52),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
              child: Row(
                children: [
                  Expanded(
                    child: at == null
                        ? Text(
                            'Pick the fee',
                            key: const ValueKey('fee-list-picked'),
                            style: theme.textTheme.titleSmall?.copyWith(color: scheme.onSurfaceVariant),
                          )
                        : Text.rich(
                            key: const ValueKey('fee-list-picked'),
                            TextSpan(
                              children: [
                                if (at.heading.isNotEmpty) ...[
                                  TextSpan(
                                    text: at.heading,
                                    style: TextStyle(fontWeight: FontWeight.w800, fontFeatures: PosTheme.tabular),
                                  ),
                                  const TextSpan(text: ' · '),
                                ],
                                TextSpan(text: at.name),
                              ],
                            ),
                            style: theme.textTheme.titleSmall?.copyWith(color: ink, fontWeight: FontWeight.w600),
                          ),
                  ),
                  Icon(Icons.unfold_more, color: on ? ink : scheme.onSurfaceVariant),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The box a custom fee is typed in, under the choices. The choice over it says what it is for ("Past 8
  /// mi"), so the box says only what it takes: its label, a "$" and "0.00" until something is typed.
  Widget _amountBox() {
    final typed = _amount.text.trim();
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: TextField(
        key: const ValueKey('fee-custom-amount'),
        controller: _amount,
        focusNode: _amountFocus,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        textInputAction: TextInputAction.done,
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')), LengthLimitingTextInputFormatter(6)],
        decoration: InputDecoration(
          isDense: true,
          labelText: 'Custom fee',
          floatingLabelBehavior: FloatingLabelBehavior.always,
          prefixText: '\$',
          hintText: '0.00',
          errorText: typed.isNotEmpty && FeePick.money(typed) == null ? 'Dollars and cents, such as 12 or 12.50' : null,
        ),
        onChanged: (text) => widget.onPick(FeePick.typed(text)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fees = widget.fees;
    final crowded = fees != null && fees.asks && fees.crowded;
    return LayoutBuilder(
      key: const ValueKey('fee-picker'),
      builder: (context, constraints) {
        // a line of the list is as wide as the form, so it always has the room for "Up to"
        final narrow =
            !crowded &&
            ChoiceTile.grid(constraints.maxWidth).width / MediaQuery.textScalerOf(context).scale(1) < FeePicker.roomy;
        final choices = _choices(narrow ? reachShort : reachWords, narrow: narrow);
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(narrow ? 'Delivery fee, up to' : 'Delivery fee', style: theme.textTheme.titleSmall),
            if (widget.asker case final asker? when asker.can && widget.onLookUp != null) ...[
              const SizedBox(height: 2),
              FeeLookupLine(asker: asker, address: widget.address, onLookUp: widget.onLookUp!),
            ],
            const SizedBox(height: 6),
            if (crowded)
              _line(theme, choices)
            else
              ChoiceGrid(
                children: [
                  for (final choice in choices)
                    ChoiceTile(
                      key: ValueKey(choice.mark),
                      groupLabel: choice.heading,
                      name: choice.name,
                      available: true,
                      selected: choice.selected,
                      onTap: () => _tap(choice),
                    ),
                ],
              ),
            if (FeePick.isCustom(_picked)) _amountBox(),
          ],
        );
      },
    );
  }
}

/// One line of the list a long list of prices opens ([FeePicker]): how far it reaches on the left, what it
/// costs on the right, and a tick before the one that is picked. The words on the left give way and go
/// onto a second line where the two do not fit side by side (a small phone, large type); what it costs is
/// never cut.
class FeeListLine extends StatelessWidget {
  const FeeListLine({
    super.key,
    required this.title,
    required this.selected,
    required this.onTap,
    this.price = '',
    this.under,
  });

  /// "Up to 4.5 mi", "Custom fee · past 8 mi", "No fee".
  final String title;

  /// A second, smaller line under [title].
  final String? under;

  /// "$5.00"; nothing where there is no amount to say.
  final String price;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final ink = selected ? scheme.onPrimaryContainer : scheme.onSurface;
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected ? scheme.primaryContainer : Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 52),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Icon(Icons.check, size: 20, color: selected ? ink : Colors.transparent),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: ink,
                            fontWeight: selected ? FontWeight.w700 : null,
                          ),
                        ),
                        if (under case final under?)
                          Text(
                            under,
                            style: theme.textTheme.bodySmall?.copyWith(color: selected ? ink : scheme.onSurfaceVariant),
                          ),
                      ],
                    ),
                  ),
                  if (price.isNotEmpty) ...[
                    const SizedBox(width: 12),
                    Text(
                      price,
                      maxLines: 1,
                      softWrap: false,
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: ink,
                        fontWeight: FontWeight.w700,
                        fontFeatures: PosTheme.tabular,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
