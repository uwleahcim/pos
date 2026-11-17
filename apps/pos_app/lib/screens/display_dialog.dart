import 'package:flutter/material.dart';

import '../dish_names.dart';
import '../session.dart';

/// A staff member's own text size, contrast, and which name of a dish they read (English or Chinese:
/// docs/dish-names.md). Each tap applies on this screen at once and is kept by the backend, so the same
/// settings follow them to any device they sign in on.
class DisplayDialog extends StatelessWidget {
  const DisplayDialog({super.key, required this.session});

  final Session session;

  /// The offered size nearest to what is stored (another app may have saved a size in between).
  static double closest(double scale) {
    var best = DisplayPrefs.textScales.first.$1;
    for (final (offered, _) in DisplayPrefs.textScales) {
      if ((offered - scale).abs() < (best - scale).abs()) best = offered;
    }
    return best;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final theme = Theme.of(context);
        final prefs = session.prefs;
        Future<void> save(DisplayPrefs next) async {
          final problem = await session.savePrefs(next);
          if (problem != null && context.mounted) {
            ScaffoldMessenger.maybeOf(context)?.showSnackBar(
              SnackBar(content: Text('Applied on this screen, but not saved for your other devices: $problem')),
            );
          }
        }

        return AlertDialog(
          title: const Text('Display'),
          insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12), // a phone keeps its width and height
          // a small phone with large text scrolls to the last of them
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Text size', style: theme.textTheme.titleSmall),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    for (final (scale, name) in DisplayPrefs.textScales)
                      ChoiceChip(
                        key: ValueKey('text-scale:$scale'),
                        label: Text(name),
                        selected: closest(prefs.textScale) == scale,
                        onSelected: (_) => save(prefs.copyWith(textScale: scale)),
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                SwitchListTile(
                  key: const ValueKey('high-contrast'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('High contrast'),
                  subtitle: const Text('Black on white and stronger lines'),
                  value: prefs.highContrast,
                  onChanged: (on) => save(prefs.copyWith(highContrast: on)),
                ),
                Text('Dish names', style: theme.textTheme.titleSmall),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    for (final (code, name) in const [(englishNames, 'English'), (chineseNames, '中文')])
                      ChoiceChip(
                        key: ValueKey('dish-names:$code'),
                        label: Text(name),
                        selected: readsChinese(prefs.locale) == (code == chineseNames),
                        onSelected: (_) => save(prefs.copyWith(locale: code)),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'On the menu and on the check. Bills and kitchen tickets do not change.',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 8),
                Text(
                  'These follow you to any screen you sign in on.',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Done'))],
        );
      },
    );
  }
}
