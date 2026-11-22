import 'package:flutter/material.dart';

import '../api.dart';
import '../roster.dart';
import 'theme.dart';

/// Tells the hub that [server] is in tonight's turn for a table ([on]) or out of it, and answers with the
/// turn as it stands: the staff ids of the people in it, whose turn it is first.
typedef SayTurn = Future<List<String>> Function(StaffMember server, bool on);

/// Tonight's turn for a table (docs/table-servers.md): who is in it and in what order, as buttons. A host
/// taps a name to put somebody in who is working the floor, or to take out whoever is cut for the night,
/// on a break or gone home. The hub keeps the turn; every tap is asked of it and shows what it answered.
class TurnDialog extends StatefulWidget {
  const TurnDialog({
    super.key,
    required this.servers,
    required this.turn,
    required this.onSay,
    required this.onChanged,
  });

  /// The people a table can be given to.
  final List<StaffMember> servers;

  /// The turn as the floor had it when the dialog was opened.
  final List<String> turn;
  final SayTurn onSay;

  /// The turn as the hub answered it after a tap: whoever opened the dialog shows it from then on.
  final ValueChanged<List<String>> onChanged;

  @override
  State<TurnDialog> createState() => _TurnDialogState();
}

class _TurnDialogState extends State<TurnDialog> {
  late List<String> _turn = widget.turn;
  String? _asking; // the one a word is on its way to the hub about
  String? _problem;

  Future<void> _tap(StaffMember server) async {
    if (_asking != null) return;
    final on = !_turn.contains(server.staffId);
    setState(() {
      _asking = server.staffId;
      _problem = null;
    });
    try {
      final turn = await widget.onSay(server, on);
      if (!mounted) return;
      setState(() => _turn = turn);
      widget.onChanged(turn);
    } on ApiException catch (err) {
      if (!mounted) return;
      setState(
        () => _problem = err.status == null
            ? 'The hub cannot be reached, and the turn is kept there. Try again in a moment.'
            : err.detail?['message'] as String? ?? err.message,
      );
    } finally {
      if (mounted) setState(() => _asking = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final ordered = inTurnFirst(widget.servers, _turn);
    final places = [
      for (final id in _turn)
        if (widget.servers.any((s) => s.staffId == id)) id,
    ];
    return AlertDialog(
      title: const Text("Tonight's turn"),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24), // a phone keeps its width
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final server in ordered)
                  _TurnTile(
                    key: ValueKey('turn:${server.staffId}'),
                    server: server,
                    place: places.indexOf(server.staffId) + 1,
                    asking: _asking == server.staffId,
                    onTap: _asking == null ? () => _tap(server) : null,
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              _problem ??
                  'Tap a name to put them in or take them out. Whoever has waited longest for a table is next. '
                      'With the time clock on, servers come in as they clock in.',
              key: ValueKey(_problem == null ? 'turn-help' : 'turn-problem'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: _problem == null ? scheme.onSurfaceVariant : scheme.error,
              ),
            ),
          ],
        ),
      ),
      actions: [
        FilledButton(
          key: const ValueKey('turn-done'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
    );
  }
}

class _TurnTile extends StatelessWidget {
  const _TurnTile({super.key, required this.server, required this.place, required this.asking, required this.onTap});

  final StaffMember server;

  /// Where they stand in the turn, from 1; 0 for somebody who is not in it.
  final int place;
  final bool asking;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isIn = place > 0;
    final ink = isIn ? scheme.onPrimaryContainer : scheme.onSurfaceVariant;
    return Material(
      color: isIn ? scheme.primaryContainer : scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: isIn ? scheme.primary : scheme.outlineVariant),
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
                Text(
                  server.name,
                  style: theme.textTheme.titleSmall?.copyWith(color: ink, fontWeight: FontWeight.w700),
                ),
                Text(
                  asking
                      ? 'Asking the hub'
                      : isIn
                      ? placeInTurn(place)
                      : 'Not in it',
                  style: theme.textTheme.bodySmall?.copyWith(color: ink, fontFeatures: PosTheme.tabular),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
