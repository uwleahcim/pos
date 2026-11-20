import 'package:flutter/material.dart';

import '../delivery_fee.dart';
import 'fee_lookup.dart';
import 'menu_panel.dart';

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
/// Where the hub looks the distance up, a line over the buttons says how far the address is; the form
/// picks the band for it, and any other button can still be tapped.
class FeePicker extends StatelessWidget {
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

  /// A band's reach, [FeePick.none], [FeePick.kept], or null while nobody picked.
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
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fees = this.fees;
    final taken = this.taken;
    final listed = taken == null || FeePick.listed(taken, fees);
    // what the order carries reads as the list's own button while the list still has it
    final picked = pick == FeePick.kept && taken != null && listed ? taken.pick : pick;
    return LayoutBuilder(
      key: const ValueKey('fee-picker'),
      builder: (context, constraints) {
        final narrow = ChoiceTile.grid(constraints.maxWidth).width / MediaQuery.textScalerOf(context).scale(1) < roomy;
        final reach = narrow ? reachShort : reachWords;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(narrow ? 'Delivery fee, up to' : 'Delivery fee', style: theme.textTheme.titleSmall),
            if (asker case final asker? when asker.can && onLookUp != null) ...[
              const SizedBox(height: 2),
              FeeLookupLine(asker: asker, address: address, onLookUp: onLookUp!),
            ],
            const SizedBox(height: 6),
            ChoiceGrid(
              children: [
                if (taken != null && !listed)
                  ChoiceTile(
                    key: const ValueKey('fee:kept'),
                    // the website's own fee is no band: it stays until somebody picks one of the list's
                    groupLabel: taken.onWebsite ? feeWords(taken.amount) : '${feeWords(taken.amount)} · as taken',
                    name: taken.onWebsite ? (narrow ? 'Website' : 'On the website') : reach(taken.by!, taken.upTo!),
                    available: true,
                    selected: picked == FeePick.kept,
                    onTap: () => onPick(FeePick.kept),
                  ),
                if (fees != null && fees.asks)
                  for (final band in fees.bands)
                    ChoiceTile(
                      key: ValueKey('fee:${band.upTo}'),
                      groupLabel: feeWords(band.fee),
                      name: reach(fees.by, band.upTo),
                      available: true,
                      selected: picked == band.upTo,
                      onTap: () => onPick(band.upTo),
                    ),
                ChoiceTile(
                  key: const ValueKey('fee:none'),
                  groupLabel: '',
                  name: 'No fee',
                  available: true,
                  selected: picked == FeePick.none,
                  onTap: () => onPick(FeePick.none),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}
