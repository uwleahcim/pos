import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../outbox.dart';
import '../settings.dart';
import 'order_screen.dart';
import 'settings_screen.dart';
import 'status_bar.dart';

/// Open orders from the backend, refreshed every two seconds. Phase 1 replaces polling with a push.
class OrdersScreen extends StatefulWidget {
  const OrdersScreen({super.key, required this.api, required this.outbox, required this.settings});

  final PosApi api;
  final Outbox outbox;
  final Settings settings;

  @override
  State<OrdersScreen> createState() => _OrdersScreenState();
}

class _OrdersScreenState extends State<OrdersScreen> {
  List<Order> _orders = const [];
  bool _showClosed = false;
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
      final orders = await widget.api.listOrders(status: _showClosed ? null : 'open');
      if (mounted) setState(() => _orders = orders);
    } on ApiException {
      // The status bar already shows the outage; the list keeps its last picture.
    }
  }

  Future<void> _newOrder() async {
    final table = await showDialog<String>(context: context, builder: (context) => const _TableDialog());
    if (table == null || !mounted) return;
    final orderId = widget.outbox.newId();
    await widget.outbox.add(orderId, 'create', {'table': int.tryParse(table) ?? table});
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => OrderScreen(api: widget.api, outbox: widget.outbox, orderId: orderId),
      ),
    );
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Orders · ${widget.settings.device}'),
        actions: [
          IconButton(
            tooltip: _showClosed ? 'Hide closed' : 'Show closed',
            icon: Icon(_showClosed ? Icons.visibility_off : Icons.visibility),
            onPressed: () => setState(() {
              _showClosed = !_showClosed;
              _refresh();
            }),
          ),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings),
            onPressed: () =>
                Navigator.of(context)
                    .push(MaterialPageRoute(builder: (_) => SettingsScreen(settings: widget.settings))),
          ),
        ],
      ),
      body: Column(
        children: [
          StatusBar(api: widget.api, outbox: widget.outbox),
          Expanded(
            child: _orders.isEmpty
                ? const Center(child: Text('No open orders. Tap + to start one.'))
                : ListView.separated(
                    itemCount: _orders.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final order = _orders[i];
                      final lines = order.activeLines;
                      final items = lines.fold<int>(0, (n, l) => n + l.qty);
                      return ListTile(
                        leading: CircleAvatar(child: Text(order.table.isEmpty ? '?' : order.table)),
                        title: Text('Table ${order.table}'),
                        subtitle: Text('$items items · ${order.status}${order.isFired ? ' · fired' : ''}'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () async {
                          await Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) =>
                                  OrderScreen(api: widget.api, outbox: widget.outbox, orderId: order.orderId),
                            ),
                          );
                          _refresh();
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _newOrder,
        icon: const Icon(Icons.add),
        label: const Text('New order'),
      ),
    );
  }
}

class _TableDialog extends StatefulWidget {
  const _TableDialog();

  @override
  State<_TableDialog> createState() => _TableDialogState();
}

class _TableDialogState extends State<_TableDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New order'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'Table'),
        keyboardType: TextInputType.number,
        onSubmitted: (v) => Navigator.of(context).pop(v.trim()),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.of(context).pop(_controller.text.trim()), child: const Text('Start')),
      ],
    );
  }
}
