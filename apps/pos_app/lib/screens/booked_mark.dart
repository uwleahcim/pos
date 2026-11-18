import 'package:flutter/material.dart';

import '../reservations.dart';
import '../table_timers.dart' show TimerLevel;
import 'booked_table_dialog.dart' show holdColors;
import 'theme.dart';

/// The count of today's booked tables still to sit down, as the small mark under the waitlist's button
/// (docs/reservations.md): a square page of a calendar where the parties waiting are a round badge. Plain
/// while every reservation is ahead, amber when one is near its time and red when one is past it with
/// nobody seated.
class BookedMark extends StatelessWidget {
  const BookedMark({super.key, required this.count, required this.level});

  final int count;
  final TimerLevel level;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final pos = PosColors.of(context);
    final (fill, ink) = switch (level) {
      TimerLevel.ok => (scheme.secondaryContainer, scheme.onSecondaryContainer),
      TimerLevel.warn => (pos.timerWarn, pos.timerWarnText),
      TimerLevel.late => (pos.timerLate, pos.timerLateText),
    };
    return Container(
      constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
      padding: const EdgeInsets.symmetric(horizontal: 3),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(4),
        // a hair around it, so it reads apart from the icon it sits on: the bar's own colour, and a line
        // where the plain mark is pale
        border: Border.all(color: level == TimerLevel.ok ? scheme.outline : scheme.surface),
      ),
      child: Center(
        widthFactor: 1,
        heightFactor: 1,
        child: Text(
          count > 99 ? '99+' : '$count',
          style: theme.textTheme.labelSmall?.copyWith(
            color: ink,
            fontWeight: FontWeight.w700,
            height: 1.1,
            fontFeatures: PosTheme.tabular,
          ),
        ),
      ),
    );
  }
}

/// Today's booked tables still to sit down, as the row at the top of the waitlist: how many, and the next
/// one with its time first ([nextBookedWords]). Whoever tells a walk-in how long the wait is sees what is
/// booked beside who waits. A tap is [onTap]: the way to the reservation book.
class BookedToCome extends StatelessWidget {
  const BookedToCome({super.key, required this.toCome, required this.nowMs, required this.onTap});

  /// The standing reservations of today, the earliest first; never empty.
  final List<Booking> toCome;
  final int nowMs;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final next = toCome.first;
    // the earliest is the one furthest along: near its time, past it, or here and waiting
    final (fill, ink) = holdColors(context, here: next.isHere, level: next.levelAt(nowMs));
    return Material(
      color: scheme.secondaryContainer,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
          child: Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(8)),
                child: Icon(Icons.event_rounded, size: 20, color: ink),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      bookedToComeWords(toCome.length),
                      key: const ValueKey('waitlist-booked-count'),
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: scheme.onSecondaryContainer,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      nextBookedWords(next, nowMs),
                      key: const ValueKey('waitlist-booked-next'),
                      // a narrow phone with large type takes a second line before it cuts the guests off
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSecondaryContainer,
                        fontFeatures: PosTheme.tabular,
                      ),
                    ),
                  ],
                ),
              ),
              Tooltip(
                message: 'Open the reservation book',
                child: Icon(Icons.chevron_right, color: scheme.onSecondaryContainer),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
