import 'package:flutter/material.dart';

import '../floor.dart';
import '../takeout.dart' show clockTime;
import 'theme.dart';

/// How far off a booked table's time is at [nowMs], in words: "in 25 min", "in 1 h 10 min", "now",
/// "20 min ago", and for a party that came in and waits, "here since 18:22".
String holdWhenWords(TableHold hold, int nowMs) {
  final here = hold.arrivedMs;
  if (here != null) return 'here since ${clockTime(here)}';
  String span(int minutes) =>
      minutes < 60 ? '$minutes min' : '${minutes ~/ 60} h${minutes % 60 == 0 ? '' : ' ${minutes % 60} min'}';
  final ahead = hold.atMs - nowMs;
  if (ahead > 0) return 'in ${span((ahead / 60000).ceil())}';
  final past = -ahead ~/ 60000;
  return past == 0 ? 'now' : '${span(past)} ago';
}

/// The colours of a booked table's time: plain while it is ahead, amber when it is near, red when it is past
/// with nobody seated, and a colour of its own for a party that is here and waits.
(Color fill, Color ink) holdColors(BuildContext context, {required bool here, required TimerLevel level}) {
  final scheme = Theme.of(context).colorScheme;
  final pos = PosColors.of(context);
  if (here) return (scheme.primaryContainer, scheme.onPrimaryContainer);
  return switch (level) {
    TimerLevel.ok => (scheme.surfaceContainerHighest, scheme.onSurface),
    TimerLevel.warn => (pos.timerWarn, pos.timerWarnText),
    TimerLevel.late => (pos.timerLate, pos.timerLateText),
  };
}

/// Asked before somebody sits down at a free table that is booked (docs/reservations.md): who the table is
/// kept for and for when. It warns and refuses nothing.
///
/// It pops `true` to go on with what was being done ([go] names it: "Seat a walk-in", "Seat Lee here"), a
/// [TableHold] to seat that reservation's party instead (offered with [seats]: a party walking in may be
/// the very one the table is kept for), and nothing to leave the table alone.
class BookedTableDialog extends StatelessWidget {
  const BookedTableDialog({
    super.key,
    required this.table,
    required this.holds,
    required this.nowMs,
    required this.go,
    this.seats = false,
  });

  final TableSpot table;

  /// The reservations the table is being kept for now, the earliest first. Never empty.
  final List<TableHold> holds;
  final int nowMs;

  /// What going on is called.
  final String go;

  /// Each reservation has a button that seats its party here.
  final bool seats;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final small = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    // On a narrow phone, or with large type, Seat goes under the party and not beside it. (A dialog sizes
    // itself to what is in it, so what is in it cannot ask how wide it got: the screen says.)
    final media = MediaQuery.of(context);
    final room = (media.size.width - 128).clamp(0.0, 360.0);
    final beside = room >= 250 * media.textScaler.scale(1);
    return AlertDialog(
      title: Text('${table.label} is booked'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final hold in holds)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Builder(
                    builder: (context) {
                      final (fill, ink) = holdColors(context, here: hold.isHere, level: hold.levelAt(nowMs));
                      final party = Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                            decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(8)),
                            child: Text(
                              hold.time,
                              style: theme.textTheme.labelLarge?.copyWith(
                                color: ink,
                                fontWeight: FontWeight.w700,
                                fontFeatures: PosTheme.tabular,
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  hold.label,
                                  key: ValueKey('booked-for:${hold.id}'),
                                  style: theme.textTheme.titleSmall,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                Text(holdWhenWords(hold, nowMs), key: ValueKey('booked-when:${hold.id}'), style: small),
                              ],
                            ),
                          ),
                        ],
                      );
                      if (!seats) return party;
                      final seat = FilledButton(
                        key: ValueKey('booked-seat:${hold.id}'),
                        onPressed: () => Navigator.of(context).pop(hold),
                        child: const Text('Seat'),
                      );
                      return beside
                          ? Row(
                              children: [
                                Expanded(child: party),
                                const SizedBox(width: 8),
                                seat,
                              ],
                            )
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [party, const SizedBox(height: 4), seat],
                            );
                    },
                  ),
                ),
              Text(
                seats
                    ? 'If somebody else sits here, the reservation stays in the book.'
                    : 'The reservation stays in the book.',
                style: small,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('booked-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        // seating the booked party is what a tap on its table mostly means: going on anyway stands back
        if (seats)
          OutlinedButton(
            key: const ValueKey('booked-anyway'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(go),
          )
        else
          FilledButton(
            key: const ValueKey('booked-anyway'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(go),
          ),
      ],
    );
  }
}
