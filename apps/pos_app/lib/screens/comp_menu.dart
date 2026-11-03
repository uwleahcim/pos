/// A comp on one dish, from a hold on its price (Mike, 2026-11-03): a menu pops up at the price with the
/// reasons the location's rules allow on one item, each saying what it gives and whether a manager must
/// put in a PIN. A fixed one (a comp, a staff meal) is complete at a tap; one with a range asks how much
/// first. A discount already on the item is listed with a way to take it off, and reasons that cannot go
/// on top of it are greyed out, as the hub would refuse them. The hub keeps the rules and checks again.
library;

import 'package:flutter/material.dart';

import '../menu.dart';
import '../pricing.dart';

/// A reason the menu offers for one item.
class CompChoice {
  const CompChoice({required this.rule, required this.gives, required this.enabled});

  final DiscountRule rule;

  /// What the reason gives, in a few words: "free", "50% off", "up to 20% or $20", "any amount".
  final String gives;

  /// Whether it may go on the item now: not on top of a discount that does not stack.
  final bool enabled;

  /// Whether the reason is complete at a tap (a comp, a fixed percentage), or how much has to be chosen.
  bool get asksHowMuch => !(_only('comp') || (_only('percent') && rule.fixedPercent != null));

  bool _only(String kind) => rule.kinds.length == 1 && rule.kinds.single == kind;
}

/// The reasons the rules allow on one item, in the rules' order, each enabled unless a discount already
/// on the item (or on the whole check) does not stack with it (the hub's own rule, made here first).
List<CompChoice> compChoices(PricingRules rules, List<CheckDiscount> existing, String lineId) {
  final byCode = {for (final r in rules.discounts) r.code: r};
  final overlapping = [
    for (final d in existing)
      if (d.lineId == null || d.lineId == lineId) d,
  ];
  final othersStack = overlapping.every((d) => byCode[d.reason]?.stacks ?? false);
  return [
    for (final rule in rules.discounts)
      if (rule.onLines)
        CompChoice(rule: rule, gives: givesOf(rule), enabled: overlapping.isEmpty || (rule.stacks && othersStack)),
  ];
}

/// What a reason gives, in a few words.
String givesOf(DiscountRule rule) {
  final comp = rule.kinds.contains('comp');
  final percent = rule.kinds.contains('percent');
  final amount = rule.kinds.contains('amount');
  if (comp && !percent && !amount) return 'free';
  final fixed = rule.fixedPercent;
  if (percent && !amount && !comp && fixed != null) return '$fixed% off';
  final maxPercent = rule.maxPercent == null ? null : double.parse(rule.maxPercent!);
  final anyPercent = percent && fixed == null && (maxPercent == null || maxPercent >= 100);
  final anyAmount = amount && rule.maxAmount == null;
  if (anyPercent || anyAmount) return 'any amount';
  final caps = [if (percent) fixed != null ? '$fixed%' : '${rule.maxPercent}%', if (amount) '\$${rule.maxAmount}'];
  final cap = 'up to ${caps.join(' or ')}';
  return comp ? 'free, or $cap' : cap;
}

/// "Comped · Manager comp", "50% off · Staff meal", "$5 off · Loyalty reward": a discount as its line shows it.
String compLabel(CheckDiscount d) => switch (d.kind) {
  'comp' => 'Comped · ${d.name}',
  'percent' => '${d.value}% off · ${d.name}',
  _ => '\$${d.value} off · ${d.name}',
};

/// The menu at a dish's price: pops the [Adjustment] to send (a `discount` on the line, or a
/// `remove_discount` for one already on it), or null when the operator walks away. [anchor] is the
/// price's own context, so the menu opens there.
Future<Adjustment?> showCompMenu(
  BuildContext anchor, {
  required String dish,
  required String price,
  required String lineId,
  required PricingRules rules,
  required List<CheckDiscount> existing,
}) async {
  final theme = Theme.of(anchor);
  final scheme = theme.colorScheme;
  final box = anchor.findRenderObject()! as RenderBox;
  final overlay = Navigator.of(anchor).overlay!.context.findRenderObject()! as RenderBox;
  final position = RelativeRect.fromRect(
    Rect.fromPoints(
      box.localToGlobal(Offset.zero, ancestor: overlay),
      box.localToGlobal(box.size.bottomRight(Offset.zero), ancestor: overlay),
    ),
    Offset.zero & overlay.size,
  );
  final onItem = [
    for (final d in existing)
      if (d.lineId == lineId) d,
  ];
  final choices = compChoices(rules, existing, lineId);
  final picked = await showMenu<Object>(
    context: anchor,
    position: position,
    items: [
      PopupMenuItem<Object>(
        enabled: false,
        height: 36,
        child: Text(
          price.isEmpty ? dish : '$dish · $price',
          style: theme.textTheme.labelLarge,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      for (final d in onItem)
        PopupMenuItem<Object>(
          key: ValueKey('uncomp:${d.discountId}'),
          value: d,
          child: Row(
            children: [
              Icon(Icons.undo, size: 18, color: scheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Flexible(child: Text('Take off ${d.name}', maxLines: 1, overflow: TextOverflow.ellipsis)),
            ],
          ),
        ),
      if (onItem.isNotEmpty) const PopupMenuDivider(),
      for (final c in choices)
        PopupMenuItem<Object>(
          key: ValueKey('comp:${c.rule.code}'),
          value: c,
          enabled: c.enabled,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(child: Text(c.rule.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
                  if (c.rule.needsManager) ...[
                    const SizedBox(width: 6),
                    Icon(Icons.lock_outline, size: 14, color: scheme.onSurfaceVariant),
                  ],
                ],
              ),
              Text(
                c.gives,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
    ],
  );
  if (picked == null) return null;
  if (picked is CheckDiscount) {
    return Adjustment(
      op: 'remove_discount',
      data: {'discount_id': picked.discountId},
      needsManager: false,
      label: 'Taking off ${picked.name}',
    );
  }
  final choice = picked as CompChoice;
  final rule = choice.rule;
  if (!choice.asksHowMuch) {
    final kind = rule.kinds.single;
    return _adjustment(rule, lineId, kind, kind == 'comp' ? null : rule.fixedPercent);
  }
  if (!anchor.mounted) return null;
  final howMuch = await showDialog<(String, String?)>(
    context: anchor,
    builder: (_) => HowMuchDialog(rule: rule, dish: dish),
  );
  if (howMuch == null) return null;
  return _adjustment(rule, lineId, howMuch.$1, howMuch.$2);
}

Adjustment _adjustment(DiscountRule rule, String lineId, String kind, String? value) => Adjustment(
  op: 'discount',
  data: {'reason': rule.code, 'kind': kind, if (kind != 'comp') 'value': value, 'line_id': lineId},
  needsManager: rule.needsManager,
  label: rule.name,
);

/// How much a reason with a range takes off one dish: a percentage (presets within the cap, or typed),
/// an amount, or the whole item, as the reason allows. Pops `(kind, value)`; the value is null for a comp.
class HowMuchDialog extends StatefulWidget {
  const HowMuchDialog({super.key, required this.rule, required this.dish});

  final DiscountRule rule;
  final String dish;

  @override
  State<HowMuchDialog> createState() => _HowMuchDialogState();
}

class _HowMuchDialogState extends State<HowMuchDialog> {
  static const _presets = [10, 15, 20, 25, 50];

  late String _kind = [
    'percent',
    'amount',
    'comp',
  ].firstWhere(widget.rule.kinds.contains, orElse: () => widget.rule.kinds.first);
  late final _value = TextEditingController(text: _kind == 'percent' ? widget.rule.fixedPercent ?? '' : '');

  @override
  void dispose() {
    _value.dispose();
    super.dispose();
  }

  String? get _problem => widget.rule.problem(_kind, _value.text.trim());

  void _apply() => Navigator.of(context).pop((_kind, _kind == 'comp' ? null : _value.text.trim()));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final rule = widget.rule;
    final problem = _problem;
    final maxPercent = rule.maxPercent == null ? null : double.parse(rule.maxPercent!);
    return AlertDialog(
      title: Text('${rule.name} on ${widget.dish}', maxLines: 2, overflow: TextOverflow.ellipsis),
      content: SizedBox(
        width: 300,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (rule.kinds.length > 1)
              SegmentedButton<String>(
                segments: [
                  for (final kind in rule.kinds)
                    ButtonSegment(
                      value: kind,
                      label: Text(switch (kind) {
                        'percent' => '%',
                        'amount' => '\$',
                        _ => 'Free',
                      }, key: ValueKey('kind:$kind')),
                    ),
                ],
                selected: {_kind},
                showSelectedIcon: false,
                onSelectionChanged: (s) => setState(() {
                  _kind = s.first;
                  _value.text = _kind == 'percent' ? rule.fixedPercent ?? '' : '';
                }),
              ),
            if (_kind == 'comp')
              const Padding(padding: EdgeInsets.only(top: 10), child: Text('The item comes to nothing.')),
            if (_kind == 'percent' && rule.fixedPercent == null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Wrap(
                  spacing: 8,
                  children: [
                    for (final p in _presets)
                      if (maxPercent == null || p <= maxPercent)
                        ChoiceChip(
                          key: ValueKey('preset:$p'),
                          label: Text('$p%'),
                          selected: _value.text == '$p',
                          onSelected: (_) => setState(() => _value.text = '$p'),
                        ),
                  ],
                ),
              ),
            if (_kind != 'comp')
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: TextField(
                  key: const ValueKey('how-much-value'),
                  controller: _value,
                  autofocus: rule.fixedPercent == null,
                  readOnly: rule.fixedPercent != null && _kind == 'percent',
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(
                    labelText: _kind == 'percent' ? 'Percent off' : 'Amount off',
                    prefixText: _kind == 'amount' ? '\$ ' : null,
                    suffixText: _kind == 'percent' ? '%' : null,
                    errorText: _value.text.trim().isEmpty ? null : problem,
                    helperText: _kind == 'percent'
                        ? (rule.fixedPercent != null
                              ? 'Always ${rule.fixedPercent}%'
                              : rule.maxPercent != null
                              ? 'Up to ${rule.maxPercent}%'
                              : null)
                        : (rule.maxAmount != null ? 'Up to \$${rule.maxAmount}' : null),
                  ),
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) => problem == null ? _apply() : null,
                ),
              ),
            if (rule.needsManager)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  'A manager puts in their PIN next.',
                  style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('how-much-apply'),
          onPressed: problem == null ? _apply : null,
          child: Text(rule.needsManager ? 'Manager PIN' : 'Apply'),
        ),
      ],
    );
  }
}
