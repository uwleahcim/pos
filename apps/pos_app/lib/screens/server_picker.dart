import 'package:flutter/material.dart';

import '../floor.dart';
import '../roster.dart';
import 'theme.dart';

/// A party being sat: how many, and whose table it is when a host or manager said so (null when whoever
/// seats it takes it themselves).
class Seating {
  const Seating(this.guests, [this.server]);

  final int guests;
  final StaffMember? server;
}

/// The servers a table can be given to, as buttons: each with the tables and guests they have on the floor
/// right now, so the next party goes where there is room for it. With a [turn], the people in tonight's
/// turn come first, in the order they take their tables, and the one whose turn it is says so.
class ServerPicker extends StatelessWidget {
  const ServerPicker({
    super.key,
    required this.servers,
    required this.plan,
    required this.picked,
    required this.onPicked,
    this.turn = const [],
  });

  final List<StaffMember> servers;
  final FloorPlan plan;
  final StaffMember? picked;
  final ValueChanged<StaffMember> onPicked;

  /// Tonight's turn for a table, by staff id, whose turn it is first ([FloorPlan.turn]). Empty where a
  /// table is handed over and not sat, and while nobody was said to be on: the buttons stand as the hub
  /// lists the staff.
  final List<String> turn;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    if (servers.isEmpty) {
      return Text(
        'The hub lists nobody who takes tables.',
        style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
      );
    }
    final ordered = inTurnFirst(servers, turn);
    final next = turn.where((id) => servers.any((s) => s.staffId == id)).firstOrNull;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final server in ordered)
          _ServerTile(
            key: ValueKey('server:${server.staffId}'),
            server: server,
            load: ServerLoad.of(plan, server),
            picked: server.staffId == picked?.staffId,
            next: server.staffId == next,
            onTap: () => onPicked(server),
          ),
      ],
    );
  }
}

/// The small word on the one whose turn it is.
class NextMark extends StatelessWidget {
  const NextMark({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(color: scheme.primary, borderRadius: BorderRadius.circular(8)),
      child: Text(
        'Next',
        style: theme.textTheme.labelSmall?.copyWith(color: scheme.onPrimary, fontWeight: FontWeight.w700),
      ),
    );
  }
}

class _ServerTile extends StatelessWidget {
  const _ServerTile({
    super.key,
    required this.server,
    required this.load,
    required this.picked,
    required this.next,
    required this.onTap,
  });

  final StaffMember server;
  final ServerLoad load;
  final bool picked;

  /// It is this one's turn for a table.
  final bool next;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final ink = picked ? scheme.onPrimaryContainer : scheme.onSurface;
    return Material(
      color: picked ? scheme.primaryContainer : scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: picked ? scheme.primary : scheme.outlineVariant, width: picked ? 2 : 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 104, minHeight: 52),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        server.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(color: ink, fontWeight: FontWeight.w700),
                      ),
                    ),
                    if (next) ...[const SizedBox(width: 6), NextMark(key: ValueKey('turn-next:${server.staffId}'))],
                    if (picked) ...[
                      const SizedBox(width: 6),
                      Icon(Icons.check_circle, size: 16, color: scheme.primary),
                    ],
                  ],
                ),
                Text(
                  load.inWords,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: picked ? ink : scheme.onSurfaceVariant,
                    fontFeatures: PosTheme.tabular,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
