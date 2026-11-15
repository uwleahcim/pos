import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../customers.dart';

/// The way into the search of the list of checks: a square with a magnifier beside the chips, or, with no
/// chips to sit beside, a pill that says what it does.
class FindCheckButton extends StatelessWidget {
  const FindCheckButton({super.key, required this.wide, required this.onTap});

  /// Whether it has the row to itself, and so room for words.
  final bool wide;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Tooltip(
      message: 'Find a check',
      child: Material(
        color: scheme.surfaceContainerHigh,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: scheme.outlineVariant),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            height: 36,
            width: wide ? null : 36,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: wide ? 12 : 0),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.search, size: 20, color: scheme.onSurface),
                  if (wide) ...[
                    const SizedBox(width: 8),
                    Text('Find a check', style: theme.textTheme.labelLarge?.copyWith(color: scheme.onSurface)),
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

/// The search box of the list of checks, in the row the chips have: what is typed narrows the list as it
/// is typed. A manager also gets a calendar, to look through the checks of another day; the day picked
/// shows beside the box, with a cross to come back to now. Escape, or the cross at the end, closes it.
class CheckSearchBar extends StatelessWidget {
  const CheckSearchBar({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    required this.onClose,
    required this.day,
    this.onPickDay,
    this.onClearDay,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;
  final VoidCallback onClose;

  /// The day whose checks are listed; null lists the open checks and the last day's.
  final DateTime? day;

  /// Opens the calendar; null for someone who is not a manager, who gets no calendar.
  final VoidCallback? onPickDay;
  final VoidCallback? onClearDay;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final day = this.day;
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): onClose},
      child: Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620), // a tablet does not stretch the box across the room
          child: _row(context, theme, scheme, day),
        ),
      ),
    );
  }

  Widget _row(BuildContext context, ThemeData theme, ColorScheme scheme, DateTime? day) {
    return Row(
      children: [
        Expanded(
          child: SizedBox(
            height: 40,
            child: TextField(
              key: const ValueKey('find-check'),
              controller: controller,
              focusNode: focusNode,
              autofocus: true,
              onChanged: onChanged,
              textInputAction: TextInputAction.search,
              style: theme.textTheme.bodyMedium,
              decoration: InputDecoration(
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                prefixIcon: const Icon(Icons.search, size: 20),
                prefixIconConstraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                hintText: 'Name, phone, table, number, server',
                hintMaxLines: 1,
              ),
            ),
          ),
        ),
        if (onPickDay != null) ...[
          const SizedBox(width: 6),
          if (day == null)
            IconButton(
              key: const ValueKey('find-day'),
              tooltip: 'Another day',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.calendar_today_outlined, size: 20),
              onPressed: onPickDay,
            )
          else
            InputChip(
              key: const ValueKey('find-day'),
              label: Text(_capital(dayLabel(day.millisecondsSinceEpoch, DateTime.now()))),
              labelStyle: theme.textTheme.labelLarge?.copyWith(color: scheme.onSecondaryContainer),
              backgroundColor: scheme.secondaryContainer,
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              deleteButtonTooltipMessage: 'Back to now',
              onPressed: onPickDay,
              onDeleted: onClearDay,
            ),
        ],
        IconButton(
          key: const ValueKey('find-close'),
          tooltip: 'Close search',
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.close, size: 20),
          onPressed: onClose,
        ),
      ],
    );
  }
}

String _capital(String words) => words.isEmpty ? words : words[0].toUpperCase() + words.substring(1);
