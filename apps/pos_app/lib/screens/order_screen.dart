import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../outbox.dart';
import '../photos.dart';
import 'status_bar.dart';

/// One order: its lines as the backend replays them, and the taps that append to it.
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
      if (mounted) setState(() => _order = order);
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

  Future<void> _addLine() async {
    final result = await showDialog<(String, int)>(context: context, builder: (_) => const _LineDialog());
    if (result == null) return;
    final (item, qty) = result;
    await _append('add_line', {'line_id': widget.outbox.newId(), 'item': item, 'qty': qty});
  }

  @override
  Widget build(BuildContext context) {
    final order = _order;
    final open = order?.isOpen ?? true;
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
            child: order == null
                ? const Center(child: CircularProgressIndicator())
                : order.lines.isEmpty
                ? const Center(child: Text('Nothing ordered yet.'))
                : ListView(
                    children: [
                      for (final line in order.lines)
                        ListTile(
                          leading: Text('${line.qty}×', style: Theme.of(context).textTheme.titleMedium),
                          title: Text(
                            line.item,
                            style: line.isVoid ? const TextStyle(decoration: TextDecoration.lineThrough) : null,
                          ),
                          subtitle: Text(
                            [
                              if (line.isVoid) 'void',
                              if (line.modifiedAfterFire) 'changed after fire',
                              if (line.note.isNotEmpty) line.note,
                            ].join(' · '),
                          ),
                          trailing: open && !line.isVoid
                              ? IconButton(
                                  tooltip: 'Void line',
                                  icon: const Icon(Icons.delete_outline),
                                  onPressed: () => _append('void_line', {'line_id': line.lineId}),
                                )
                              : null,
                        ),
                    ],
                  ),
          ),
        ],
      ),
      floatingActionButton: open
          ? FloatingActionButton.extended(
              onPressed: _addLine,
              icon: const Icon(Icons.add),
              label: const Text('Add item'),
            )
          : null,
    );
  }
}

class _LineDialog extends StatefulWidget {
  const _LineDialog();

  @override
  State<_LineDialog> createState() => _LineDialogState();
}

class _LineDialogState extends State<_LineDialog> {
  final _item = TextEditingController();
  int _qty = 1;

  @override
  void dispose() {
    _item.dispose();
    super.dispose();
  }

  void _submit() {
    final item = _item.text.trim();
    if (item.isEmpty) return;
    Navigator.of(context).pop((item, _qty));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add item'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _item,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Item (phase 0: typed; phase 1: from the menu)'),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(onPressed: _qty > 1 ? () => setState(() => _qty--) : null, icon: const Icon(Icons.remove)),
              Text('$_qty', style: Theme.of(context).textTheme.titleLarge),
              IconButton(onPressed: () => setState(() => _qty++), icon: const Icon(Icons.add)),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(onPressed: _submit, child: const Text('Add')),
      ],
    );
  }
}
