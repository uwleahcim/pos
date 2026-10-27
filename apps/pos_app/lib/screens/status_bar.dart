import 'package:flutter/material.dart';

import '../api.dart';
import '../outbox.dart';

/// Which backend answers and how many taps still wait to be sent. Always visible, never in the way.
class StatusBar extends StatelessWidget {
  const StatusBar({super.key, required this.api, required this.outbox});

  final PosApi api;
  final Outbox outbox;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: Listenable.merge([api.connection, outbox]),
      builder: (context, _) {
        final conn = api.connection.value;
        final online = conn.isOnline;
        final text = online ? 'connected to ${conn.endpoint}' : (conn.error ?? 'connecting');
        final pending = outbox.pending;
        final refusal = outbox.lastRefusal;
        if (refusal != null) {
          return Material(
            color: scheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
              child: Row(
                children: [
                  const Icon(Icons.block, size: 18),
                  const SizedBox(width: 8),
                  Expanded(child: Text('Not added: $refusal', maxLines: 2, overflow: TextOverflow.ellipsis)),
                  IconButton(
                    tooltip: 'Dismiss',
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: outbox.clearRefusal,
                  ),
                ],
              ),
            ),
          );
        }
        return Material(
          color: online ? scheme.surfaceContainerHighest : scheme.errorContainer,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Row(
              children: [
                Icon(online ? Icons.cloud_done : Icons.cloud_off, size: 18),
                const SizedBox(width: 8),
                Expanded(child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis)),
                if (pending > 0) Text('$pending waiting to send'),
              ],
            ),
          ),
        );
      },
    );
  }
}
