import 'package:flutter/material.dart';

import '../to_go_stages.dart';

/// One row above the list of checks: Later, Cooking, Ready and Unpaid, each with how many to-go orders it
/// holds. Tapping one lists only those, due first; tapping it again brings every check back. The four
/// share the width, so the row is the same on the narrowest phone and never scrolls.
class ToGoChips extends StatelessWidget {
  const ToGoChips({super.key, required this.counts, required this.picked, required this.onPicked});

  final Map<ToGoChip, int> counts;

  /// The chip the list is narrowed to; null lists every check.
  final ToGoChip? picked;

  /// The chip tapped, or null when the picked one was tapped again.
  final ValueChanged<ToGoChip?> onPicked;

  static const _gap = 6.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520), // a tablet does not stretch them across the room
        child: LayoutBuilder(
          builder: (context, box) {
            // All four in one size of letters, whichever fits the longest of them on this screen.
            final each = (box.maxWidth - _gap * (ToGoChip.values.length - 1)) / ToGoChip.values.length;
            final style = each >= 80
                ? theme.textTheme.labelLarge
                : each >= 62
                ? theme.textTheme.labelMedium
                : theme.textTheme.labelSmall;
            return Row(
              children: [
                for (final chip in ToGoChip.values) ...[
                  if (chip != ToGoChip.values.first) const SizedBox(width: _gap),
                  Expanded(
                    child: _Chip(
                      key: ValueKey('chip:${chip.name}'),
                      label: chip.label,
                      count: counts[chip] ?? 0,
                      on: chip == picked,
                      fill: chip == picked ? scheme.secondaryContainer : scheme.surfaceContainerHigh,
                      ink: chip == picked ? scheme.onSecondaryContainer : scheme.onSurface,
                      border: chip == picked ? scheme.secondary : scheme.outlineVariant,
                      style: style,
                      onTap: () => onPicked(chip == picked ? null : chip),
                    ),
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    super.key,
    required this.label,
    required this.count,
    required this.on,
    required this.fill,
    required this.ink,
    required this.border,
    required this.style,
    required this.onTap,
  });

  final String label;
  final int count;
  final bool on;
  final Color fill;
  final Color ink;
  final Color border;
  final TextStyle? style;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // A chip holding nothing is quieter, and still tappable: "Ready 0" is an answer too.
    final quiet = count == 0 && !on;
    return Semantics(
      button: true,
      selected: on,
      label: '$label, $count',
      excludeSemantics: true,
      child: Material(
        color: fill,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: border, width: on ? 1.5 : 1),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            height: 36,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text.rich(
                  TextSpan(
                    text: '$label ',
                    children: [
                      TextSpan(
                        text: '$count',
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                    ],
                  ),
                  maxLines: 1,
                  style: style?.copyWith(
                    color: quiet ? ink.withValues(alpha: 0.55) : ink,
                    fontWeight: on ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
