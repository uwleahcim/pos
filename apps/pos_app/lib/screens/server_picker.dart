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
/// right now, so the next party goes where there is room for it.
class ServerPicker extends StatelessWidget {
  const ServerPicker({
    super.key,
    required this.servers,
    required this.plan,
    required this.picked,
    required this.onPicked,
  });

  final List<StaffMember> servers;
  final FloorPlan plan;
  final StaffMember? picked;
  final ValueChanged<StaffMember> onPicked;

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
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final server in servers)
          _ServerTile(
            key: ValueKey('server:${server.staffId}'),
            server: server,
            load: ServerLoad.of(plan, server),
            picked: server.staffId == picked?.staffId,
            onTap: () => onPicked(server),
          ),
      ],
    );
  }
}

class _ServerTile extends StatelessWidget {
  const _ServerTile({super.key, required this.server, required this.load, required this.picked, required this.onTap});

  final StaffMember server;
  final ServerLoad load;
  final bool picked;
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
                    Text(
                      server.name,
                      style: theme.textTheme.titleSmall?.copyWith(color: ink, fontWeight: FontWeight.w700),
                    ),
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
