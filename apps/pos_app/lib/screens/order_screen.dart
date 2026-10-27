import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../menu.dart';
import '../outbox.dart';
import '../photos.dart';
import 'menu_panel.dart';
import 'status_bar.dart';

/// One order: its check as the backend prices it, and the menu whose taps append to it.
class OrderScreen extends StatefulWidget {
  const OrderScreen({super.key, required this.api, required this.outbox, required this.photos, required this.orderId});

  final PosApi api;
  final Outbox outbox;
  final PhotoQueue photos;
  final String orderId;

  @override
  State<OrderScreen> createState() => _OrderScreenState();
}

class _OrderScreenState extends State<OrderScreen> {
  Order? _order;
  Check? _check;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _refresh());
    _refresh();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final order = await widget.api.order(widget.orderId);
      final check = await widget.api.check(widget.orderId);
      if (mounted) {
        setState(() {
          _order = order;
          _check = check;
        });
      }
    } on ApiException {
      // 404 until the create op lands; the status bar shows outages.
    }
  }

  static const _photographed = {'fire', 'close', 'reopen', 'void_line', 'void_order'};

  Future<void> _append(String kind, [Map<String, dynamic> data = const {}]) async {
    final opId = await widget.outbox.add(widget.orderId, kind, data);
    if (_photographed.contains(kind)) unawaited(widget.photos.capture(kind, opId: opId));
    _refresh();
  }

  Future<void> _add(ChosenLine line) => _append('add_line', {
    'line_id': widget.outbox.newId(),
    'item': line.name,
    'qty': line.qty,
    if (line.note.isNotEmpty) 'note': line.note,
    'request': line.request.toJson(),
  });

  @override
  Widget build(BuildContext context) {
    final order = _order;
    final open = order?.isOpen ?? true;
    final ticket = _TicketPanel(
      order: order,
      check: _check,
      open: open,
      onVoid: (line) => _append('void_line', {'line_id': line.lineId}),
    );
    final menu = open
        ? MenuPanel(api: widget.api, onChosen: _add)
        : const Center(child: Text('This check is closed. Reopen it to add items.'));
    return Scaffold(
      appBar: AppBar(
        title: Text(order == null ? 'Order' : 'Table ${order.table} · ${order.status}'),
        actions: [
          if (order != null && open)
            TextButton.icon(
              onPressed: () => _append('fire', {'course': '*'}),
              icon: const Icon(Icons.local_fire_department),
              label: Text(order.isFired ? 'Fire again' : 'Fire'),
            ),
          if (order != null && open)
            TextButton.icon(
              onPressed: () => _append('close'),
              icon: const Icon(Icons.check),
              label: const Text('Close'),
            ),
          if (order != null && order.status == 'closed')
            TextButton.icon(
              onPressed: () => _append('reopen'),
              icon: const Icon(Icons.undo),
              label: const Text('Reopen'),
            ),
        ],
      ),
      body: Column(
        children: [
          StatusBar(api: widget.api, outbox: widget.outbox),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                if (constraints.maxWidth >= 720) {
                  // Mac and iPad: the check on the left, the menu on the right.
                  return Row(
                    children: [
                      SizedBox(width: constraints.maxWidth * 0.38, child: ticket),
                      const VerticalDivider(width: 1),
                      Expanded(child: menu),
                    ],
                  );
                }
                // iPhone: the check and the menu as two tabs.
                return DefaultTabController(
                  length: 2,
                  initialIndex: 1,
                  child: Column(
                    children: [
                      TabBar(
                        tabs: [
                          Tab(text: 'Check ${_check == null ? '' : '\$${_check!.total}'}'),
                          const Tab(text: 'Menu'),
                        ],
                      ),
                      Expanded(child: TabBarView(children: [ticket, menu])),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// The lines on the check with their prices, and the totals the backend computed.
class _TicketPanel extends StatelessWidget {
  const _TicketPanel({required this.order, required this.check, required this.open, required this.onVoid});

  final Order? order;
  final Check? check;
  final bool open;
  final ValueChanged<Line> onVoid;

  @override
  Widget build(BuildContext context) {
    final order = this.order;
    final theme = Theme.of(context);
    if (order == null) return const Center(child: CircularProgressIndicator());
    if (order.lines.isEmpty) return const Center(child: Text('Nothing ordered yet.'));
    final check = this.check;
    return Column(
      children: [
        Expanded(
          child: ListView(
            children: [
              for (final line in order.lines)
                Builder(
                  builder: (context) {
                    final priced = check?.line(line.lineId);
                    return ListTile(
                      dense: true,
                      leading: Text('${line.qty}×', style: theme.textTheme.titleMedium),
                      title: Text(
                        priced?.name ?? line.item,
                        style: line.isVoid ? const TextStyle(decoration: TextDecoration.lineThrough) : null,
                      ),
                      subtitle: Text(
                        [
                          ...?priced?.modifiers,
                          if (line.isVoid) 'void',
                          if (line.modifiedAfterFire) 'changed after fire',
                          if (line.note.isNotEmpty) line.note,
                        ].join(' · '),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (priced != null) Text(priced.total),
                          if (open && !line.isVoid)
                            IconButton(
                              tooltip: 'Void line',
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () => onVoid(line),
                            ),
                        ],
                      ),
                    );
                  },
                ),
            ],
          ),
        ),
        if (check != null)
          Material(
            color: theme.colorScheme.surfaceContainerHigh,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Column(
                children: [
                  _TotalRow('Subtotal', check.subtotal),
                  for (final t in check.taxLines) _TotalRow('${t.name} ${t.ratePct}%', t.amount),
                  _TotalRow('Total', check.total, strong: true),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _TotalRow extends StatelessWidget {
  const _TotalRow(this.label, this.amount, {this.strong = false});

  final String label;
  final String amount;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    final style = strong ? Theme.of(context).textTheme.titleMedium : Theme.of(context).textTheme.bodyMedium;
    return Row(
      children: [
        Text(label, style: style),
        const Spacer(),
        Text(amount, style: style),
      ],
    );
  }
}
