import 'package:flutter/material.dart';

import '../api.dart';
import '../online_orders.dart';
import '../to_go_stages.dart';

/// An order from the website says so in a slim strip under the order's bar, with how it is paid and what
/// the customer wrote for the whole order: "From the website · paid online" over "Customer wrote: no onions
/// in anything" (docs/online-orders.md, "On the screens"). The note is the one that heads the kitchen's
/// tickets. An order rung in on a screen has no such strip, unless it carries a note for the whole order.
/// A tap shows the whole of it ([showOnlineAbout]): a phone has room for two lines of a note, not for ten.
class OnlineStrip extends StatelessWidget {
  const OnlineStrip({super.key, required this.order});

  final Order order;

  /// Whether [order] has anything for the strip to say.
  static bool shows(Order order) => order.online != null || order.note.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final online = order.online;
    final note = order.note;
    final style = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurface, fontWeight: FontWeight.w600);
    return Material(
      key: const ValueKey('online-strip'),
      color: scheme.surfaceContainerHighest, // plain, like the customer's line: red is the allergy strip's
      child: InkWell(
        onTap: () => showOnlineAbout(context, order),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                online != null ? Icons.language : Icons.sticky_note_2_outlined,
                size: 16,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (online != null)
                      Text(
                        '$fromTheWebsite · ${moneyWords(order)}',
                        key: const ValueKey('online-words'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: style,
                      ),
                    if (note.isNotEmpty)
                      Text(
                        'Customer wrote: $note',
                        key: const ValueKey('order-note'),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: style,
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The whole of what an order from the website says of itself, to read and nothing else: the website's own
/// number for it (what to find it by in GloriaFood's app), what the customer was charged there, how it is
/// paid, and every word the customer wrote.
Future<void> showOnlineAbout(BuildContext context, Order order) {
  final online = order.online;
  final note = order.note;
  final money = moneyWords(order);
  return showDialog<void>(
    context: context,
    builder: (context) {
      final theme = Theme.of(context);
      return AlertDialog(
        key: const ValueKey('online-about'),
        title: Text(online != null ? fromTheWebsite : 'Customer\'s note'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (online != null) ...[
                for (final fact in onlineFacts(online)) Text(fact),
                Text('${money[0].toUpperCase()}${money.substring(1)}'),
              ],
              if (online != null && note.isNotEmpty) const SizedBox(height: 12),
              if (note.isNotEmpty) ...[
                if (online != null) Text('Customer wrote', style: theme.textTheme.labelLarge),
                Text(note, key: const ValueKey('order-note-whole')),
              ],
            ],
          ),
        ),
        actions: [
          FilledButton(autofocus: true, onPressed: () => Navigator.of(context).pop(), child: const Text('Close')),
        ],
      );
    },
  );
}
