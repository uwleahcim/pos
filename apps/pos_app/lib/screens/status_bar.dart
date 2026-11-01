import 'package:flutter/material.dart';

import '../api.dart';
import '../outbox.dart';
import 'theme.dart';

/// Which backend answers and how many taps still wait to be sent, as one small icon for the app bar: green
/// on the usual backend, amber on a backup, red when nothing answers. A tap opens the details and the card
/// for what still works in that state. A line the backend refused shows once as a message and keeps a red
/// mark here.
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
    final posColors = PosColors.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([widget.api.connection, widget.outbox]),
      builder: (context, _) {
        final conn = widget.api.connection.value;
        final level = conn.levelWith(widget.api.settings.endpoints);
        final pending = widget.outbox.pending;
        final refused = widget.outbox.lastRefusal != null;
        final (icon, color) = switch (level) {
          ConnectionLevel.capturing || ConnectionLevel.lost => (Icons.cloud_off, scheme.error),
          ConnectionLevel.backup => (Icons.cloud_sync_outlined, posColors.waitingText),
          ConnectionLevel.usual when pending > 0 => (Icons.cloud_upload_outlined, scheme.onSurfaceVariant),
          ConnectionLevel.usual => (Icons.cloud_done_outlined, scheme.primary),
        };
        return IconButton(
          key: const ValueKey('status'),
          tooltip: statusTitle(level),
          onPressed: () => showStatusDetails(context, api: widget.api, outbox: widget.outbox),
          icon: Badge(
            isLabelVisible: refused || pending > 0,
            backgroundColor: refused ? scheme.error : scheme.secondary,
            label: Text(refused ? '!' : '$pending'),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: Icon(icon, key: ValueKey(icon), color: color),
            ),
          ),
        );
      },
    );
  }
}

/// The one red line ADR 6 asks for while no backend answers: what this screen can and cannot do, with a tap
/// for the whole card. Takes no space in any other state.
class CaptureBanner extends StatelessWidget {
  const CaptureBanner({super.key, required this.api, required this.outbox});

  final PosApi api;
  final Outbox outbox;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ValueListenableBuilder(
      valueListenable: api.connection,
      builder: (context, conn, _) {
        if (!conn.capturing) return const SizedBox.shrink();
        return Material(
          key: const ValueKey('capture-banner'),
          color: scheme.error,
          child: InkWell(
            onTap: () => showStatusDetails(context, api: api, outbox: outbox),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                children: [
                  Icon(Icons.cloud_off, size: 16, color: scheme.onError),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Taking orders only: nothing prints, cash only, prices are estimates',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: scheme.onError, fontWeight: FontWeight.w600),
                    ),
                  ),
                  Icon(Icons.chevron_right, size: 18, color: scheme.onError),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

String statusTitle(ConnectionLevel level) => switch (level) {
  ConnectionLevel.usual => 'Connected',
  ConnectionLevel.backup => 'On a backup',
  ConnectionLevel.capturing => 'Capturing only',
  ConnectionLevel.lost => 'Not connected',
};

/// The connection, the queue, the saved menu's age and the runbook card for this state, as a bottom sheet.
Future<void> showStatusDetails(BuildContext context, {required PosApi api, required Outbox outbox}) =>
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => ListenableBuilder(
        listenable: Listenable.merge([api.connection, outbox]),
        builder: (context, _) {
          final theme = Theme.of(context);
          final scheme = theme.colorScheme;
          final posColors = PosColors.of(context);
          final conn = api.connection.value;
          final endpoints = api.settings.endpoints;
          final level = conn.levelWith(endpoints);
          final refusal = outbox.lastRefusal;
          final cache = api.cache;
          final now = DateTime.now();
          final (icon, color) = switch (level) {
            ConnectionLevel.usual => (Icons.cloud_done_outlined, scheme.primary),
            ConnectionLevel.backup => (Icons.cloud_sync_outlined, posColors.waitingText),
            _ => (Icons.cloud_off, scheme.error),
          };
          final since = conn.since == null ? '' : _forHowLong(now.difference(conn.since!));
          final subtitle = switch (level) {
            ConnectionLevel.usual => null,
            ConnectionLevel.backup => 'The usual backend (${endpoints.firstOrNull}) is not answering$since',
            ConnectionLevel.capturing => 'No backend answers$since; orders are kept on this screen',
            ConnectionLevel.lost => conn.error ?? 'connecting',
          };
          return SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Card(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ListTile(
                          leading: Icon(icon, color: color),
                          title: Text(
                            level == ConnectionLevel.usual || level == ConnectionLevel.backup
                                ? '${statusTitle(level)}: ${conn.endpoint}'
                                : statusTitle(level),
                          ),
                          subtitle: subtitle == null ? null : Text(subtitle),
                        ),
                        const Divider(height: 1),
                        ListTile(
                          leading: const Icon(Icons.outbox_outlined),
                          title: Text(outbox.pending == 0 ? 'Everything is sent' : '${outbox.pending} waiting to send'),
                          subtitle: outbox.pending == 0 ? null : const Text('They go as soon as a backend answers.'),
                        ),
                        if (cache != null && level != ConnectionLevel.usual) ...[
                          const Divider(height: 1),
                          ListTile(
                            leading: const Icon(Icons.save_outlined),
                            title: Text(
                              cache.hasMenu ? 'Menu saved ${ago(cache.menuAt!, now)}' : 'No menu saved on this screen',
                            ),
                            subtitle: Text(
                              cache.has('taxes')
                                  ? 'Tax rates from ${ago(cache.readAt('taxes')!, now)}'
                                  : 'Tax rates not saved yet: estimates show no tax',
                            ),
                          ),
                        ],
                        if (refusal != null) ...[
                          const Divider(height: 1),
                          ListTile(
                            leading: Icon(Icons.block, color: scheme.error),
                            title: Text('Not added: $refusal'),
                            trailing: TextButton(onPressed: outbox.clearRefusal, child: const Text('Dismiss')),
                          ),
                        ],
                        if (endpoints.length > 1) ...[
                          const Divider(height: 1),
                          ListTile(
                            leading: const Icon(Icons.swap_vert),
                            title: const Text('Backends, in failover order'),
                            subtitle: Text(endpoints.join('\n')),
                          ),
                        ],
                      ],
                    ),
                  ),
                  RunbookCard(level: level, endpoint: conn.endpoint),
                ],
              ),
            ),
          );
        },
      ),
    );

/// The offline runbook: for the state the screen is in, what still works, what to tell the guest, what not
/// to do, and who to call (architecture section 15; the capture-only card from ADR 6). The printed card at
/// every station says the same.
class RunbookCard extends StatelessWidget {
  const RunbookCard({super.key, required this.level, this.endpoint});

  final ConnectionLevel level;
  final String? endpoint;

  /// The cards, by state: a title and its lines. Plain data so the printed version can be made from it.
  static const cards = <ConnectionLevel, (String, List<String>)>{
    ConnectionLevel.usual: (
      'Everything works',
      [
        'This screen is on its usual backend.',
        'If the icon turns amber or red, tap it: this card then says what still works.',
      ],
    ),
    ConnectionLevel.backup: (
      'Both hubs are down: working through a backup',
      [
        'Orders, checks and the menu work as usual through the backup.',
        'Kitchen tickets print through a screen set as print relay (Settings); printing may lag a little.',
        'Tell the manager so the hubs get looked at.',
      ],
    ),
    ConnectionLevel.capturing: (
      'Hubs and internet down: taking orders only',
      [
        'Take the order as usual: it is kept on this screen and sent the moment a backend answers.',
        'Prices and tax are estimates from the saved menu; the real check comes when the backend is back.',
        'Nothing prints: tell the kitchen by hand. Their tickets print, headed LATE, when the backend returns.',
        'Cash only: write the amount on the check. No cards, no receipts.',
        'Nothing is shared between screens: keep each table on the screen that took it.',
        'If it stays red for more than ten minutes, call the manager on duty.',
      ],
    ),
    ConnectionLevel.lost: (
      'Not connected, and no menu saved on this screen',
      [
        'This screen has never read the menu, so it cannot take orders until a backend answers.',
        'Use another screen, or check the addresses in Settings.',
      ],
    ),
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (title, lines) = cards[level]!;
    final red = level == ConnectionLevel.capturing || level == ConnectionLevel.lost;
    return Card(
      key: ValueKey('runbook:${level.name}'),
      color: red ? scheme.errorContainer : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.menu_book_outlined, size: 18, color: red ? scheme.onErrorContainer : scheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: theme.textTheme.titleSmall?.copyWith(color: red ? scheme.onErrorContainer : null),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            for (final line in lines)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('•  ', style: TextStyle(color: red ? scheme.onErrorContainer : scheme.onSurfaceVariant)),
                    Expanded(
                      child: Text(
                        line,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: red ? scheme.onErrorContainer : scheme.onSurface,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// "just now", "4 min ago", "2 h ago", "3 d ago".
String ago(DateTime at, DateTime now) {
  final d = now.difference(at);
  if (d.inMinutes < 1) return 'just now';
  if (d.inHours < 1) return '${d.inMinutes} min ago';
  if (d.inDays < 1) return '${d.inHours} h ago';
  return '${d.inDays} d ago';
}

String _forHowLong(Duration d) {
  if (d.inMinutes < 1) return '';
  if (d.inHours < 1) return ' for ${d.inMinutes} min';
  return ' for ${d.inHours} h ${d.inMinutes % 60} min';
}
