import 'package:flutter/material.dart';

import '../deliveries.dart';
import '../powers.dart';
import '../roster.dart';
import 'theme.dart';

/// Who takes it (docs/delivery.md): the people a delivery can be handed to, as buttons, each with how many
/// bags they have out right now, so the next one goes to whoever is free. The hub says who delivers
/// (Location › Who may do what); a tap on a name hands the bags over.
class DriverPicker extends StatelessWidget {
  const DriverPicker({super.key, required this.drivers, required this.deliveries, this.bags = 1});

  final List<StaffMember> drivers;
  final Deliveries deliveries;

  /// How many bags are being handed over in one go.
  final int bags;

  /// Asks, and answers who was tapped: null when nobody was.
  static Future<StaffMember?> ask(
    BuildContext context, {
    required List<StaffMember> drivers,
    required Deliveries deliveries,
    int bags = 1,
  }) => showDialog<StaffMember>(
    context: context,
    builder: (_) => DriverPicker(drivers: drivers, deliveries: deliveries, bags: bags),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // only the people who do everything are offered: nobody was named a driver here yet
    final managersOnly = drivers.every((d) => alwaysRoles.contains(d.role));
    return AlertDialog(
      key: const ValueKey('driver-picker'),
      title: Text(bags == 1 ? 'Who takes it?' : 'Who takes these $bags?'),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (drivers.isEmpty)
                Text(
                  'The hub lists nobody who takes deliveries out.',
                  style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                )
              else
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final driver in drivers)
                      _DriverTile(
                        key: ValueKey('driver:${driver.staffId}'),
                        driver: driver,
                        out: deliveries.has(driver.staffId),
                        onTap: () => Navigator.of(context).pop(driver),
                      ),
                  ],
                ),
              if (managersOnly) ...[
                const SizedBox(height: 12),
                Text(
                  'Who takes deliveries out is set under Location › Who may do what.',
                  key: const ValueKey('driver-picker-hint'),
                  style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel'))],
    );
  }
}

class _DriverTile extends StatelessWidget {
  const _DriverTile({super.key, required this.driver, required this.out, required this.onTap});

  final StaffMember driver;
  final int out;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: scheme.outlineVariant),
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
                Text(driver.name, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                Text(
                  out == 0 ? 'nothing out' : '$out out',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
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
