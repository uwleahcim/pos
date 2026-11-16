import 'package:flutter/material.dart';

import '../to_go_stages.dart';

/// One row above the list of checks: Later, Cooking, Ready and Unpaid, each with how many to-go orders it
/// holds. Tapping one lists only those, due first; tapping it again brings every check back. They share the
/// width, so the row is the same on the narrowest phone and never scrolls.
///
/// With a bar tab open, **Tabs** stands first in the row, with how many are open: tapping it lists only the
/// tabs, by the name on each. With tabs and no to-go order ([toGo] false) it stands there alone.
class ToGoChips extends StatelessWidget {
  const ToGoChips({
    super.key,
    required this.counts,
    required this.picked,
    required this.onPicked,
    this.toGo = true,
    this.tabs,
    this.tabsPicked = false,
    this.onTabs,
  });

  final Map<ToGoChip, int> counts;

  /// The chip the list is narrowed to; null lists every check.
  final ToGoChip? picked;

  /// The chip tapped, or null when the picked one was tapped again.
  final ValueChanged<ToGoChip?> onPicked;

  /// Whether the four chips of the to-go orders show.
  final bool toGo;

  /// How many bar tabs are open; null leaves the Tabs chip out.
  final int? tabs;

  /// The list is narrowed to the tabs.
  final bool tabsPicked;

  /// Tabs was tapped: on, or off again.
  final ValueChanged<bool>? onTabs;

  static const _gap = 6.0;

  /// How wide Tabs is when it stands alone: a button, not a bar across the screen.
  static const _alone = 104.0;

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
            final many = (toGo ? ToGoChip.values.length : 0) + (tabs == null ? 0 : 1);
            if (many == 0) return const SizedBox.shrink();
            // All in one size of letters, whichever fits the longest of them on this screen.
            final each = many == 1 ? _alone : (box.maxWidth - _gap * (many - 1)) / many;
            final style = each >= 80
                ? theme.textTheme.labelLarge
                : each >= 62
                ? theme.textTheme.labelMedium
                : theme.textTheme.labelSmall;
            Widget chip(Key key, String label, int count, bool on, VoidCallback onTap) => _Chip(
              key: key,
              label: label,
              count: count,
              on: on,
              fill: on ? scheme.secondaryContainer : scheme.surfaceContainerHigh,
              ink: on ? scheme.onSecondaryContainer : scheme.onSurface,
              border: on ? scheme.secondary : scheme.outlineVariant,
              style: style,
              onTap: onTap,
            );
            final chips = [
              if (tabs != null)
                chip(const ValueKey('chip:tabs'), 'Tabs', tabs!, tabsPicked, () => onTabs?.call(!tabsPicked)),
              if (toGo)
                for (final one in ToGoChip.values)
                  chip(
                    ValueKey('chip:${one.name}'),
                    one.label,
                    counts[one] ?? 0,
                    one == picked,
                    () => onPicked(one == picked ? null : one),
                  ),
            ];
            if (chips.length == 1) return SizedBox(width: _alone, child: chips.single);
            return Row(
              children: [
                for (final (i, one) in chips.indexed) ...[if (i > 0) const SizedBox(width: _gap), Expanded(child: one)],
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
