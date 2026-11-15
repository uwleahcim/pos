/// A comp on several dishes at once (the Toast comparison, 2026-11-15): the dishes picked up on the check and
/// let go over Comp get one reason, picked here from the reasons the location's rules allow on an item, laid
/// out as buttons like a dish's choices. A reason that needs a manager asks for the PIN once, after this,
/// for all of them. A dish that already carries a discount nothing goes on top of is left as it is, and the
/// reason's button says how many of the dishes it goes on.
library;

import 'package:flutter/material.dart';

import '../menu.dart';
import '../pricing.dart';
import 'comp_menu.dart';
import 'menu_panel.dart' show ChoiceGrid, ChoiceTile;

/// A dish of the lot, as the dialog names it.
typedef LotDish = ({String lineId, int qty, String name, String total});

/// A reason offered for the lot, with the dishes it may go on.
class LotChoice {
  const LotChoice({required this.rule, required this.gives, required this.lineIds});

  final DiscountRule rule;

  /// What the reason gives each dish, in a few words: "free", "50% off", "up to 20% or $20".
  final String gives;

  /// The dishes of the lot it may go on, in the lot's order: not one that already carries a discount it
  /// does not stack with.
  final List<String> lineIds;

  /// Whether the reason is complete at a tap (a comp, a fixed percentage), or how much has to be chosen.
  bool get asksHowMuch => CompChoice(rule: rule, gives: gives, enabled: true).asksHowMuch;
}

/// The reasons the rules allow on an item that can go on at least one dish of the lot, in the rules' order.
List<LotChoice> lotChoices(PricingRules rules, List<CheckDiscount> existing, List<String> lineIds) {
  final allowed = {
    for (final id in lineIds)
      id: {
        for (final choice in compChoices(rules, existing, id))
          if (choice.enabled) choice.rule.code,
      },
  };
  return [
    for (final rule in rules.discounts)
      if (rule.onLines && lineIds.any((id) => allowed[id]!.contains(rule.code)))
        LotChoice(
          rule: rule,
          gives: givesOf(rule),
          lineIds: [
            for (final id in lineIds)
              if (allowed[id]!.contains(rule.code)) id,
          ],
        ),
  ];
}

/// What was chosen for the lot: the reason, what it takes off each dish, and the dishes it goes on.
class LotComp {
  const LotComp({required this.rule, required this.kind, this.value, required this.lineIds});

  final DiscountRule rule;
  final String kind; // comp | percent | amount
  final String? value;
  final List<String> lineIds;

  /// One `discount` for each dish, as the hub takes them.
  List<Map<String, dynamic>> get discounts => [
    for (final id in lineIds) {'reason': rule.code, 'kind': kind, if (kind != 'comp') 'value': value, 'line_id': id},
  ];
}

/// "1 dish", "3 dishes".
String dishes(int n) => n == 1 ? '1 dish' : '$n dishes';

/// The dishes of the lot and the reasons for them. Pops the [LotComp] to send, or null when the operator
/// walks away.
class LotCompDialog extends StatelessWidget {
  const LotCompDialog({super.key, required this.lot, required this.choices});

  final List<LotDish> lot;
  final List<LotChoice> choices;

  Future<void> _pick(BuildContext context, LotChoice choice) async {
    final rule = choice.rule;
    if (!choice.asksHowMuch) {
      final kind = rule.kinds.single;
      Navigator.of(
        context,
      ).pop(LotComp(rule: rule, kind: kind, value: kind == 'comp' ? null : rule.fixedPercent, lineIds: choice.lineIds));
      return;
    }
    final howMuch = await showDialog<(String, String?)>(
      context: context,
      builder: (_) => HowMuchDialog(rule: rule, dish: 'each of ${dishes(choice.lineIds.length)}'),
    );
    if (howMuch == null || !context.mounted) return;
    Navigator.of(context).pop(LotComp(rule: rule, kind: howMuch.$1, value: howMuch.$2, lineIds: choice.lineIds));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return AlertDialog(
      title: Text('Comp ${dishes(lot.length)}'),
      contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final dish in lot)
                Padding(
                  key: ValueKey('lot-dish:${dish.lineId}'),
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Row(
                    children: [
                      Expanded(child: Text('${dish.qty} × ${dish.name}', maxLines: 1, overflow: TextOverflow.ellipsis)),
                      if (dish.total.isNotEmpty) Text('\$${dish.total}', style: theme.textTheme.bodyMedium),
                    ],
                  ),
                ),
              const SizedBox(height: 10),
              if (choices.isEmpty)
                Text(
                  'Each of these already has a discount that nothing goes on top of.',
                  key: const ValueKey('lot-comp-none'),
                  style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                )
              else ...[
                Text('One reason for all of them', style: theme.textTheme.titleSmall),
                const SizedBox(height: 8),
                ChoiceGrid(
                  children: [
                    for (final choice in choices)
                      ChoiceTile(
                        key: ValueKey('lot-comp:${choice.rule.code}'),
                        // what it gives, and on how many when a dish of the lot cannot take it
                        groupLabel: choice.lineIds.length == lot.length
                            ? _capital(choice.gives)
                            : '${_capital(choice.gives)} · ${choice.lineIds.length} of ${lot.length}',
                        name: choice.rule.name,
                        priceLabel: choice.rule.needsManager ? 'PIN' : null,
                        available: true,
                        selected: false,
                        onTap: () => _pick(context, choice),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [TextButton(autofocus: true, onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel'))],
    );
  }
}

String _capital(String words) => words.isEmpty ? words : words[0].toUpperCase() + words.substring(1);
