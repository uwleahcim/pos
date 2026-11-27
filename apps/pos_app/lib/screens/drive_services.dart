import 'package:flutter/material.dart';

import '../drive_lookups.dart';
import 'service_badge.dart';

/// The map services that are asked one thing about a delivery's drive, as rows a manager puts in order
/// and turns on or off (docs/delivery.md, "Which service is asked first"): how far it goes, in the Delivery
/// fee's dialog, and how long the drive is right now, in Live traffic's.
///
/// Each row has a handle that moves it earlier or later, the service's badge with a ring for how many of
/// its day's lookups are left, its name, a line on how it stands, and its switch. Where a row stands says
/// when it is asked, so no number is put before its name. The order and the switches are the dialog's to
/// hold: this shows them and says what somebody did.
class DriveServicesList extends StatelessWidget {
  const DriveServicesList({
    super.key,
    required this.mark,
    required this.services,
    required this.onMoved,
    required this.onTurned,
    this.enabled = true,
  });

  /// What the keys of its parts begin with: `fee-services`, `live-services`.
  final String mark;

  /// The services in the order they stand now, each turned on or off as it stands now.
  final List<DriveService> services;

  /// Somebody dragged the service at one place of the list to another.
  final void Function(int from, int to) onMoved;

  /// Somebody turned a service on or off.
  final void Function(String name, bool on) onTurned;

  /// False while the dialog saves.
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    Widget row(int index) {
      final service = services[index];
      final words = service.words;
      return Column(
        key: ValueKey('$mark-row:${service.name}'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // flush with the words above and below it; the room to its right and above and below is its too
              ReorderableDragStartListener(
                index: index,
                enabled: enabled && services.length > 1,
                child: MouseRegion(
                  cursor: SystemMouseCursors.grab,
                  child: Padding(
                    key: ValueKey('$mark-handle:${service.name}'),
                    padding: const EdgeInsets.fromLTRB(0, 10, 10, 10),
                    child: Icon(Icons.drag_handle, color: scheme.onSurfaceVariant),
                  ),
                ),
              ),
              Expanded(
                child: SwitchListTile(
                  key: ValueKey('$mark:${service.name}'),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  controlAffinity: ListTileControlAffinity.trailing,
                  // the badge a delivery's form shows beside a figure of this service, with the same ring
                  secondary: ServiceBadge(
                    key: ValueKey('$mark-badge:${service.name}'),
                    service: service.name,
                    title: service.title,
                    share: service.key ? service.share : null,
                    words: service.key ? service.leftWords : null,
                  ),
                  value: service.on,
                  onChanged: enabled ? (to) => onTurned(service.name, to) : null,
                  title: Text(
                    service.title,
                    key: ValueKey('$mark-name:${service.name}'),
                    style: theme.textTheme.bodyLarge,
                  ),
                  subtitle: words.isEmpty
                      ? null
                      : Text(
                          words,
                          key: ValueKey('$mark-state:${service.name}'),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: service.troubled ? scheme.error : scheme.onSurfaceVariant,
                          ),
                        ),
                ),
              ),
            ],
          ),
          const Divider(height: 4),
        ],
      );
    }

    return ReorderableListView.builder(
      key: ValueKey(mark),
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      buildDefaultDragHandles: false,
      // a row that is being dragged: lifted off the dialog, on the dialog's own ground
      proxyDecorator: (child, index, animation) => AnimatedBuilder(
        animation: animation,
        builder: (context, child) => Material(
          elevation: 6 * Curves.easeInOut.transform(animation.value),
          color: theme.dialogTheme.backgroundColor ?? scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(8),
          child: child,
        ),
        child: child,
      ),
      itemCount: services.length,
      onReorderItem: onMoved,
      itemBuilder: (context, index) => row(index),
    );
  }
}
