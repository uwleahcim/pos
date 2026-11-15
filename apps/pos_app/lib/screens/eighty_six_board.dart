import 'package:flutter/material.dart';

import '../api.dart';
import '../menu.dart';

/// The 86 board for the manager: what is sold out, then every dish with a number left, the fewest first, so
/// what is about to run out is at the top. A row can be brought back here (a number taken off leaves the
/// dish on sale). Putting a dish on the board is done where the dish is: hold it on the order screen.
class EightySixBoard extends StatefulWidget {
  const EightySixBoard({super.key, required this.api, this.rows, this.by});

  final PosApi api;

  /// The board as the caller already read it; read here when null.
  final List<BoardRow>? rows;

  /// Who is at the screen, by name.
  final String? by;

  /// One line on a board for a card: "2 sold out · 3 with a number left".
  static String summary(List<BoardRow> rows) {
    final out = rows.where((r) => r.soldOut).length;
    final counted = rows.length - out;
    if (rows.isEmpty) return 'Nothing is sold out, and no dish has a number left';
    return [if (out > 0) '$out sold out', if (counted > 0) '$counted with a number left'].join(' · ');
  }

  @override
  State<EightySixBoard> createState() => _EightySixBoardState();
}

class _EightySixBoardState extends State<EightySixBoard> {
  late List<BoardRow>? _rows = widget.rows;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (_rows == null) _load();
  }

  Future<void> _load() async {
    try {
      final rows = await widget.api.board();
      if (mounted) {
        setState(() {
          _rows = rows;
          _error = null;
        });
      }
    } on ApiException catch (err) {
      if (mounted) setState(() => _error = err.message);
    }
  }

  /// Back on sale with no number: a sold-out dish comes back, a counted one is no longer counted.
  Future<void> _back(BoardRow row) async {
    setState(() => _busy = true);
    try {
      await widget.api.set86(row.targetId, soldOut: false, by: widget.by);
      await _load();
    } on ApiException catch (err) {
      if (mounted) setState(() => _error = err.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final rows = _rows;
    return AlertDialog(
      title: const Text('Sold out and running low'),
      content: SizedBox(
        width: 440,
        child: rows == null
            ? Center(heightFactor: 2, child: _error == null ? const CircularProgressIndicator() : Text(_error!))
            : SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (rows.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8),
                        child: Text('Nothing is sold out, and no dish has a number left.'),
                      ),
                    for (final row in rows)
                      ListTile(
                        key: ValueKey('board:${row.targetId}'),
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(row.name, style: theme.textTheme.titleSmall),
                        subtitle: Text(
                          row.by == null || row.by!.isEmpty ? row.said : '${row.said} · ${row.by}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: row.soldOut ? scheme.error : scheme.onSurfaceVariant,
                          ),
                        ),
                        trailing: TextButton(
                          key: ValueKey('board-back:${row.targetId}'),
                          onPressed: _busy ? null : () => _back(row),
                          child: Text(row.soldOut ? 'Bring back' : 'No number'),
                        ),
                      ),
                    const SizedBox(height: 8),
                    Text(
                      'To mark a dish sold out or type how many are left, hold the dish on the order screen. '
                      'Numbers clear overnight.',
                      style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(_error!, style: TextStyle(color: scheme.error)),
                      ),
                  ],
                ),
              ),
      ),
      actions: [TextButton(onPressed: () => Navigator.of(context).pop(_rows), child: const Text('Done'))],
    );
  }
}
