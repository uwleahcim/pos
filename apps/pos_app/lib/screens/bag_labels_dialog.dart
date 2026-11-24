import 'package:flutter/material.dart';

import '../api.dart';
import 'theme.dart';

/// "How many bags?" (docs/bag-labels.md): asked when somebody taps Labels on a to-go order. The answer is a
/// grid of numbers and one tap gives it: a label prints for each bag. The numbers most orders go into stand
/// there at once, and More shows the rest, up to the most the hub prints at one asking. It pops with the
/// number, or with nothing when nobody picks one.
class BagLabelsDialog extends StatefulWidget {
  const BagLabelsDialog({super.key, required this.whose, this.most = PosApi.bagsMost});

  /// Whose bags they are, as the labels say it: "#12 Chen". Empty for an order with no number and no name.
  final String whose;

  /// The most bags one asking prints labels for.
  final int most;

  /// The numbers that stand there before More is tapped.
  static const first = 12;
  static const _across = 4;
  static const _gap = 6.0;

  /// "1 label" or "3 labels".
  static String labelWords(int bags) => bags == 1 ? '1 label' : '$bags labels';

  @override
  State<BagLabelsDialog> createState() => _BagLabelsDialogState();
}

class _BagLabelsDialogState extends State<BagLabelsDialog> {
  late int _shown = widget.most < BagLabelsDialog.first ? widget.most : BagLabelsDialog.first;

  Widget _number(BuildContext context, int bags) {
    return FilledButton.tonal(
      key: ValueKey('bags:$bags'),
      onPressed: () => Navigator.of(context).pop(bags),
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 52),
        padding: EdgeInsets.zero,
        textStyle: Theme.of(context).textTheme.titleMedium
            ?.copyWith(fontWeight: FontWeight.w700, fontFeatures: PosTheme.tabular),
      ),
      child: Text('$bags', semanticsLabel: bags == 1 ? '1 bag' : '$bags bags'),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const across = BagLabelsDialog._across;
    return AlertDialog(
      key: const ValueKey('bag-labels-dialog'),
      // a narrow phone keeps four numbers across, each wide enough for a finger
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      scrollable: true,
      title: const Text('How many bags?'),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // whose bags, on a line of its own: a name may end in a full stop ("Linda P.")
            if (widget.whose.isNotEmpty)
              Text(
                widget.whose,
                key: const ValueKey('bag-labels-whose'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
            Text(
              'A label prints for each bag.',
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            for (var from = 1; from <= _shown; from += across)
              Padding(
                padding: EdgeInsets.only(top: from == 1 ? 0 : BagLabelsDialog._gap),
                child: Row(
                  children: [
                    for (var bags = from; bags < from + across; bags++) ...[
                      if (bags > from) const SizedBox(width: BagLabelsDialog._gap),
                      Expanded(child: bags <= _shown ? _number(context, bags) : const SizedBox()),
                    ],
                  ],
                ),
              ),
          ],
        ),
      ),
      actions: [
        if (_shown < widget.most)
          TextButton(
            key: const ValueKey('bags-more'),
            onPressed: () => setState(() => _shown = widget.most),
            child: const Text('More'),
          ),
        TextButton(
          key: const ValueKey('bags-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
