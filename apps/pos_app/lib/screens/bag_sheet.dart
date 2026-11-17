import 'package:flutter/material.dart';

import '../bag.dart';
import 'menu_panel.dart';

/// Asks the to-go question (docs/to-go-question.md) and gives the answer: the things for the bag in the order
/// they were picked, none of them when the customer wants nothing, or null when the sheet was closed without
/// an answer (the order is then not sent).
Future<List<BagItem>?> askBag(
  BuildContext context, {
  required BagQuestion question,
  List<BagItem>? answer,
  String action = 'Send',
}) => showModalBottomSheet<List<BagItem>>(
  context: context,
  isScrollControlled: true, // as tall as its buttons, on a phone held sideways too
  constraints: const BoxConstraints(maxWidth: 560),
  builder: (_) => BagSheet(question: question, answer: answer, action: action),
);

/// The one question asked before a to-go order is sent: what goes in the bag besides the food. Its choices
/// are the menu's own buttons. A tap puts one in, another tap one more, the minus takes one out. "Nothing"
/// answers at once, since most orders want nothing or the usual and every question is a tap more.
class BagSheet extends StatefulWidget {
  const BagSheet({super.key, required this.question, this.answer, this.action = 'Send'});

  final BagQuestion question;

  /// The answer the order carries, when it is being changed.
  final List<BagItem>? answer;

  /// What the button that takes the answer says: "Send" before a send, "Next" before the payment, "Save"
  /// for a change.
  final String action;

  @override
  State<BagSheet> createState() => _BagSheetState();
}

class _BagSheetState extends State<BagSheet> {
  /// How many of each, by the choice's id, in the order they were first picked.
  late final _qty = <String, int>{for (final item in widget.answer ?? const <BagItem>[]) item.id: item.qty};

  /// The location's choices, then whatever the order carries that is no longer offered: it stays on the
  /// order unless it is taken out here.
  late final List<BagItem> _offered = [
    for (final choice in widget.question.choices)
      if (choice.id != null) BagItem(id: choice.id!, name: choice.name),
    for (final item in widget.answer ?? const <BagItem>[])
      if (!widget.question.choices.any((choice) => choice.id == item.id)) BagItem(id: item.id, name: item.name),
  ];

  void _more(String id) => setState(() {
    final now = (_qty[id] ?? 0) + 1;
    if (now <= bagQtyMax) _qty[id] = now;
  });

  void _fewer(String id) => setState(() {
    final now = (_qty[id] ?? 0) - 1;
    now > 0 ? _qty[id] = now : _qty.remove(id);
  });

  List<BagItem> get _picked => [
    for (final MapEntry(key: id, value: qty) in _qty.entries)
      BagItem(id: id, name: _offered.firstWhere((offered) => offered.id == id).name, qty: qty),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 12 + MediaQuery.viewInsetsOf(context).bottom),
        child: Column(
          key: const ValueKey('bag-sheet'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.question.question, style: theme.textTheme.titleLarge),
            const SizedBox(height: 2),
            Text('Tap again for one more.', style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
            const SizedBox(height: 12),
            Flexible(
              child: SingleChildScrollView(
                child: ChoiceGrid(
                  children: [
                    for (final offered in _offered)
                      ChoiceTile(
                        key: ValueKey('bag:${offered.id}'),
                        groupLabel: _qty.containsKey(offered.id) ? 'In the bag' : '',
                        name: BagItem(id: offered.id, name: offered.name, qty: _qty[offered.id] ?? 1).toString(),
                        available: true,
                        selected: _qty.containsKey(offered.id),
                        onTap: () => _more(offered.id),
                        onRemove: _qty.containsKey(offered.id) ? () => _fewer(offered.id) : null,
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    key: const ValueKey('bag-nothing'),
                    onPressed: () => Navigator.of(context).pop(const <BagItem>[]),
                    child: const Text('Nothing'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    key: const ValueKey('bag-done'),
                    onPressed: _qty.isEmpty ? null : () => Navigator.of(context).pop(_picked),
                    child: Text(widget.action),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
