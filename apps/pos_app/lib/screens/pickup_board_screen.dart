import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../live.dart';
import '../pickup_board.dart';
import 'theme.dart';

/// The pickup board (docs/pickup-board.md): a screen facing the pickup shelf. It lists the to-go orders the
/// kitchen is making and the ones that are ready, each by its number and a first name, and nothing else of
/// them. Nobody is signed in on it and nothing on it can be changed: the only button is the staff's way to
/// the sign-in pad.
///
/// It reads the open orders when the hub says one changed, and now and then while the hub cannot say. With
/// the hub away it keeps its last picture and says it may be behind.
class PickupBoardScreen extends StatefulWidget {
  const PickupBoardScreen({super.key, required this.api, this.onStaff, this.now = DateTime.now});

  final PosApi api;

  /// One of the staff wants the sign-in pad.
  final VoidCallback? onStaff;
  final DateTime Function() now;

  @override
  State<PickupBoardScreen> createState() => _PickupBoardScreenState();
}

class _PickupBoardScreenState extends State<PickupBoardScreen> {
  List<Order> _orders = const [];
  ({List<BoardOrder> made, List<BoardOrder> ready}) _board = (made: const [], ready: const []);
  String _drawn = ''; // what the board says now, to tell whether it has to be drawn again
  bool _away = false; // the last read got no answer: the board may be behind
  late final _poll = SafetyPoll(widget.api.live);
  late final _reader = Paced(const Duration(seconds: 1), _read);
  StreamSubscription<LiveChange>? _live;
  Timer? _timer;
  Timer? _clock; // the next moment the clock alone changes the board

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (_poll.due()) unawaited(_reader.now(must: false));
    });
    _live = widget.api.live.changes.listen((change) {
      if (change.anyOrder) _reader();
    });
    unawaited(_reader.now());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _clock?.cancel();
    _live?.cancel();
    _reader.cancel();
    super.dispose();
  }

  Future<void> _read() async {
    _poll.asked();
    try {
      final orders = await widget.api.listOrders(status: 'open');
      if (!mounted) return;
      _orders = orders;
      if (_away) setState(() => _away = false);
      _draw();
    } on ApiException {
      if (mounted && !_away) setState(() => _away = true);
    }
  }

  static String _said(List<BoardOrder> orders) =>
      [for (final order in orders) '${order.orderId}\x1f${order.number}\x1f${order.name}'].join('\x1e');

  /// Works out what the board lists now, and draws it again only when that reads differently: a table's
  /// check changing, or a to-go order's dishes, is nothing to the board.
  void _draw() {
    final now = widget.now();
    final board = boardOf(_orders, now);
    final says = '${_said(board.made)}\x1d${_said(board.ready)}';
    if (says != _drawn) {
      setState(() {
        _board = board;
        _drawn = says;
      });
    }
    // An order sent ahead for a later time starts cooking when its ticket prints, with no change for the
    // hub to tell: the board looks again at that moment, not by the second.
    _clock?.cancel();
    final at = boardChanges(_orders, now);
    if (at == null) return;
    _clock = Timer(at.difference(now) + const Duration(seconds: 1), () {
      if (mounted) _draw();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final board = _board;
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, box) {
            // side by side where there is the width for two lists of tiles; one under the other on a phone
            final wide = box.maxWidth >= 640;
            // the size of everything follows the screen: a television across the room, a tablet on the shelf
            final unit = ((wide ? box.maxWidth / 2 : box.maxWidth) / 16).clamp(18.0, 44.0);
            final made = _BoardList(
              key: const ValueKey('board-made'),
              title: 'Being made',
              none: 'Nothing is being made right now.',
              orders: board.made,
              unit: unit,
              ready: false,
            );
            final ready = _BoardList(
              key: const ValueKey('board-ready'),
              title: 'Ready',
              none: 'Nothing is ready yet.',
              orders: board.ready,
              unit: unit,
              ready: true,
            );
            return Column(
              children: [
                Expanded(
                  child: wide
                      ? Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(child: SingleChildScrollView(child: made)),
                            VerticalDivider(width: 1, color: scheme.outlineVariant),
                            Expanded(child: SingleChildScrollView(child: ready)),
                          ],
                        )
                      // what a customer looks for first is whether theirs is ready
                      : SingleChildScrollView(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              ready,
                              Divider(height: 1, color: scheme.outlineVariant),
                              made,
                            ],
                          ),
                        ),
                ),
                Divider(height: 1, color: scheme.outlineVariant),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 2, 4, 2),
                  child: Row(
                    children: [
                      Expanded(
                        child: _away
                            ? Text(
                                'This board may be behind: the hub is not answering.',
                                key: const ValueKey('board-away'),
                                style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
                              )
                            : const SizedBox.shrink(),
                      ),
                      if (widget.onStaff != null)
                        TextButton(
                          key: const ValueKey('board-staff'),
                          style: TextButton.styleFrom(foregroundColor: scheme.onSurfaceVariant),
                          onPressed: widget.onStaff,
                          child: const Text('Staff'),
                        ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// One of the board's two lists: its title with how many, and a tile for each order.
class _BoardList extends StatelessWidget {
  const _BoardList({
    super.key,
    required this.title,
    required this.none,
    required this.orders,
    required this.unit,
    required this.ready,
  });

  final String title;
  final String none;
  final List<BoardOrder> orders;
  final double unit;
  final bool ready;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = PosColors.of(context);
    final gap = unit * 0.5;
    return Padding(
      padding: EdgeInsets.all(gap),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: unit * 1.1,
              fontWeight: FontWeight.w700,
              color: ready ? (theme.brightness == Brightness.dark ? colors.firedBorder : colors.firedText) : null,
            ),
          ),
          SizedBox(height: gap * 0.6),
          if (orders.isEmpty)
            Text(
              none,
              style: TextStyle(fontSize: unit * 0.6, color: scheme.onSurfaceVariant),
            )
          else
            Wrap(
              spacing: gap * 0.6,
              runSpacing: gap * 0.6,
              children: [for (final order in orders) _BoardTile(order: order, unit: unit, ready: ready)],
            ),
        ],
      ),
    );
  }
}

/// One order on the board: its number large, the first name under it.
class _BoardTile extends StatelessWidget {
  const _BoardTile({required this.order, required this.unit, required this.ready});

  final BoardOrder order;
  final double unit;
  final bool ready;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final colors = PosColors.of(context);
    final text = ready ? colors.firedText : scheme.onSurface;
    final number = order.number;
    return Container(
      key: ValueKey('board-order:${order.orderId}'),
      // every tile as wide as the next, so the numbers stand in columns a customer can run an eye down
      width: unit * 4.6,
      padding: EdgeInsets.symmetric(horizontal: unit * 0.3, vertical: unit * 0.25),
      decoration: BoxDecoration(
        color: ready ? colors.fired : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(unit * 0.4),
        border: Border.all(color: ready ? colors.firedBorder : scheme.outlineVariant, width: ready ? 2 : 1),
      ),
      child: Column(
        children: [
          // the large line is the number; an order with no number is called by its name there
          Text(
            number != null ? '$number' : order.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: number != null ? unit * 1.5 : unit * 1.1,
              height: number != null ? 1.1 : 1.5, // as tall a line either way
              fontWeight: number != null ? FontWeight.w800 : FontWeight.w700,
              color: text,
              fontFeatures: PosTheme.tabular,
            ),
          ),
          // (the line stays when there is no name to say, so every tile is as tall as the next)
          Text(
            number != null ? order.name : '',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: unit * 0.7, fontWeight: FontWeight.w500, color: text),
          ),
        ],
      ),
    );
  }
}
