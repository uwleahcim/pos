import 'package:flutter/material.dart';

import '../waitlist.dart' show guestWords;
import 'theme.dart';

/// How many guests a party is: the numbers most parties are as buttons, and a step either way for the rest.
/// The form of a party for the waitlist has it, and the form of a reservation. Its keys start with
/// [prefix]: `party-size`, `party-fewer`, `party-more`, `party-size:4`.
class GuestsPicker extends StatelessWidget {
  const GuestsPicker({
    super.key,
    required this.prefix,
    required this.size,
    required this.most,
    required this.onChanged,
  });

  final String prefix;
  final int size;

  /// The largest party that is taken.
  final int most;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            IconButton.filledTonal(
              key: ValueKey('$prefix-fewer'),
              tooltip: 'One guest fewer',
              onPressed: size > 1 ? () => onChanged(size - 1) : null,
              icon: const Icon(Icons.remove),
            ),
            Expanded(
              child: Text(
                guestWords(size),
                key: ValueKey('$prefix-size'),
                textAlign: TextAlign.center,
                style: theme.textTheme.titleLarge?.copyWith(fontFeatures: PosTheme.tabular),
              ),
            ),
            IconButton.filledTonal(
              key: ValueKey('$prefix-more'),
              tooltip: 'One guest more',
              onPressed: size < most ? () => onChanged(size + 1) : null,
              icon: const Icon(Icons.add),
            ),
          ],
        ),
        const SizedBox(height: 6),
        // One row on the narrowest phone too: each number takes its share of the width.
        Row(
          children: [
            for (final (at, preset) in const [1, 2, 3, 4, 5, 6, 8].indexed) ...[
              if (at > 0) const SizedBox(width: 4),
              Expanded(
                child: ChoiceChip(
                  key: ValueKey('$prefix-size:$preset'),
                  label: SizedBox(
                    width: double.infinity,
                    child: Text('$preset', textAlign: TextAlign.center),
                  ),
                  labelPadding: EdgeInsets.zero,
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  visualDensity: VisualDensity.compact,
                  showCheckmark: false,
                  selected: size == preset,
                  onSelected: (_) => onChanged(preset),
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }
}

/// How many guests a party is, in a square: what a host looks for first when a table of four comes free.
class GuestsBadge extends StatelessWidget {
  const GuestsBadge({super.key, required this.size, this.muted = false});

  final int size;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 40,
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: muted ? scheme.surfaceContainerHighest : scheme.primaryContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        '$size',
        semanticsLabel: guestWords(size),
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w800,
          color: muted ? scheme.onSurfaceVariant : scheme.onPrimaryContainer,
          fontFeatures: PosTheme.tabular,
        ),
      ),
    );
  }
}
