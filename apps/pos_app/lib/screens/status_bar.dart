import 'package:flutter/material.dart';

import '../api.dart';
import '../outbox.dart';

/// Which backend answers and how many taps still wait to be sent, as one small icon for the app bar: a
/// tap opens the details. A line the backend refused shows once as a message and keeps a red mark here.
class StatusIcon extends StatefulWidget {
  const StatusIcon({super.key, required this.api, required this.outbox});

  final PosApi api;
  final Outbox outbox;

  @override
  State<StatusIcon> createState() => _StatusIconState();
}

class _StatusIconState extends State<StatusIcon> {
  String? _told; // the refusal already shown as a message

  @override
  void initState() {
    super.initState();
    widget.outbox.addListener(_onOutbox);
  }

  @override
  void dispose() {
    widget.outbox.removeListener(_onOutbox);
    super.dispose();
  }

  void _onOutbox() {
    final refusal = widget.outbox.lastRefusal;
    if (refusal == null || refusal == _told || !mounted) return;
    _told = refusal;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text('Not added: $refusal'),
        action: SnackBarAction(label: 'Dismiss', onPressed: widget.outbox.clearRefusal),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: Listenable.merge([widget.api.connection, widget.outbox]),
      builder: (context, _) {
        final conn = widget.api.connection.value;
        final pending = widget.outbox.pending;
        final refused = widget.outbox.lastRefusal != null;
        final IconData icon;
        final Color color;
        if (!conn.isOnline) {
          (icon, color) = (Icons.cloud_off, scheme.error);
        } else if (pending > 0) {
          (icon, color) = (Icons.cloud_upload_outlined, scheme.onSurfaceVariant);
        } else {
          (icon, color) = (Icons.cloud_done_outlined, scheme.primary);
        }
        return IconButton(
          key: const ValueKey('status'),
          tooltip: conn.isOnline ? 'Connected' : 'Not connected',
          onPressed: () => _details(context),
          icon: Badge(
            isLabelVisible: refused || pending > 0,
            backgroundColor: refused ? scheme.error : scheme.secondary,
            label: Text(refused ? '!' : '$pending'),
            child: Icon(icon, color: color),
          ),
        );
      },
    );
  }

  Future<void> _details(BuildContext context) => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) => ListenableBuilder(
      listenable: Listenable.merge([widget.api.connection, widget.outbox]),
      builder: (context, _) {
        final conn = widget.api.connection.value;
        final outbox = widget.outbox;
        final refusal = outbox.lastRefusal;
        final endpoints = widget.api.settings.endpoints;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: Icon(conn.isOnline ? Icons.cloud_done_outlined : Icons.cloud_off),
                  title: Text(conn.isOnline ? 'Connected to ${conn.endpoint}' : 'Not connected'),
                  subtitle: conn.isOnline ? null : Text(conn.error ?? 'connecting'),
                ),
                ListTile(
                  leading: const Icon(Icons.outbox_outlined),
                  title: Text(outbox.pending == 0 ? 'Everything is sent' : '${outbox.pending} waiting to send'),
                  subtitle: outbox.pending == 0 ? null : const Text('They go as soon as a backend answers.'),
                ),
                if (refusal != null)
                  ListTile(
                    leading: Icon(Icons.block, color: Theme.of(context).colorScheme.error),
                    title: Text('Not added: $refusal'),
                    trailing: TextButton(onPressed: outbox.clearRefusal, child: const Text('Dismiss')),
                  ),
                if (endpoints.length > 1)
                  ListTile(
                    leading: const Icon(Icons.swap_vert),
                    title: const Text('Backends, in failover order'),
                    subtitle: Text(endpoints.join('\n')),
                  ),
              ],
            ),
          ),
        );
      },
    ),
  );
}
