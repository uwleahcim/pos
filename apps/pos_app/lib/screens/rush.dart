import 'package:flutter/material.dart';

import '../takeout.dart';

/// The minutes a manager can add to every new quote while the kitchen is behind. 0 takes the rush off.
const rushChoices = [0, 10, 15, 20, 30, 45];

/// One slim line above the checks while a rush runs, so whoever takes the next to-go order knows the quote
/// is longer tonight and by how much. Tapping it changes the rush (a manager's PIN is asked for).
class RushStrip extends StatelessWidget {
  const RushStrip({super.key, required this.rush, this.onTap});

  final Rush rush;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: scheme.tertiaryContainer,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          // The minutes are what matters: on the narrowest phones the hour it ends gives way to them.
          child: LayoutBuilder(
            builder: (context, box) => Row(
              children: [
                Icon(Icons.local_fire_department_outlined, size: 16, color: scheme.onTertiaryContainer),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Kitchen is busy: new quotes +${rush.minutes} min',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onTertiaryContainer,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (box.maxWidth >= 330) ...[
                  const SizedBox(width: 8),
                  Text(
                    'until ${clockTime(rush.until)}',
                    style: theme.textTheme.bodySmall?.copyWith(color: scheme.onTertiaryContainer),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The rush as buttons: how many minutes to add to every new quote, or Off. Pops the minutes picked.
class RushSheet extends StatelessWidget {
  const RushSheet({super.key, required this.current});

  /// The minutes the rush adds now; 0 while there is none.
  final int current;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Kitchen is busy', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Add minutes to every new to-go quote, on every screen. Orders already promised keep their '
              'time. It goes off by itself overnight.',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            // A grid of buttons that fills the sheet: three across on a phone, all six on a wide screen.
            LayoutBuilder(
              builder: (context, box) {
                const gap = 8.0;
                final across = box.maxWidth >= 560 ? rushChoices.length : 3;
                final width = (box.maxWidth - gap * (across - 1)) / across;
                final style = FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 6));
                return Wrap(
                  spacing: gap,
                  runSpacing: gap,
                  children: [
                    for (final minutes in rushChoices)
                      SizedBox(
                        width: width.floorToDouble(),
                        height: 52,
                        child: minutes == current
                            ? FilledButton(
                                key: ValueKey('rush:$minutes'),
                                style: style,
                                onPressed: () => Navigator.of(context).pop(minutes),
                                child: Text(minutes == 0 ? 'Off' : '+$minutes min', maxLines: 1),
                              )
                            : FilledButton.tonal(
                                key: ValueKey('rush:$minutes'),
                                style: style,
                                onPressed: () => Navigator.of(context).pop(minutes),
                                child: Text(minutes == 0 ? 'Off' : '+$minutes min', maxLines: 1),
                              ),
                      ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// The mark on a to-go order for later in the list of checks: amber while it starts cooking soon (and, if
/// nobody sent it yet, by when to send it), red when its time to start has come and it was never sent.
/// Nothing while its start is far off, or once the kitchen has it.
class LaterMark extends StatelessWidget {
  const LaterMark({
    super.key,
    required this.stage,
    required this.sent,
    required this.starts,
    required this.warn,
    required this.late,
  });

  final LaterStage stage;

  /// Whether the order was sent: its ticket then prints by itself when it must start.
  final bool sent;

  /// When the order must start cooking.
  final DateTime starts;

  /// The colour pairs (fill, text) for "soon" and for "not sent": the floor map's timer colours.
  final (Color, Color) warn;
  final (Color, Color) late;

  @override
  Widget build(BuildContext context) {
    if (stage != LaterStage.soon && stage != LaterStage.unsent) return const SizedBox.shrink();
    final (fill, ink) = stage == LaterStage.soon ? warn : late;
    final at = clockTime(starts.millisecondsSinceEpoch);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(6)),
      child: Text(
        stage == LaterStage.unsent
            ? 'Not sent, due to start $at'
            : sent
            ? 'Starts $at'
            : 'Send by $at',
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: ink, fontWeight: FontWeight.w700),
      ),
    );
  }
}
