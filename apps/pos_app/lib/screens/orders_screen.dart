import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../camera.dart';
import '../floor.dart';
import '../outbox.dart';
import '../photos.dart';
import '../print_relay.dart';
import '../session.dart';
import '../settings.dart';
import 'compact.dart';
import 'floor_view.dart';
import 'menu_editor.dart';
import 'order_screen.dart';
import 'settings_screen.dart';
import 'status_bar.dart';
import 'theme.dart';

/// The home screen: the floor map (tap a table to seat it or open its check), or the list of open checks.
/// Both refresh every two seconds; a later slice replaces polling with a push.
class OrdersScreen extends StatefulWidget {
  const OrdersScreen({
    super.key,
    required this.api,
    required this.outbox,
    required this.settings,
    required this.session,
    required this.camera,
    required this.photos,
    this.relay,
  });

  final PosApi api;
  final Outbox outbox;
  final Settings settings;
  final Session session;
  final EventCamera camera;
  final PhotoQueue photos;
  final PrintRelay? relay;

  @override
  State<OrdersScreen> createState() => _OrdersScreenState();
}

class _OrdersScreenState extends State<OrdersScreen> {
  List<Order> _orders = const [];
  bool _showClosed = false;
  bool _floor = true;
  final _floorKey = GlobalKey<FloorViewState>();
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
    final name = await showDialog<String>(context: context, builder: (context) => const _TableDialog());
    if (name == null || !mounted) return;
    await _create({'order_type': 'takeout', if (name.isNotEmpty) 'note': name});
  }

  /// Opens a new check with these fields, stamped with the signed-in server, and shows it.
  Future<void> _create(Map<String, dynamic> fields, {List<Course> courses = Course.defaults}) async {
    final staff = widget.session.staff;
    final orderId = widget.outbox.newId();
    final opId = await widget.outbox.add(orderId, 'create', {
      ...fields,
      if (staff != null) 'server': staff.name,
      if (staff != null) 'server_id': staff.staffId,
    });
    unawaited(widget.photos.capture('create', opId: opId));
    if (!mounted) return;
    await _open(orderId, courses: courses);
  }

  Future<void> _open(String orderId, {List<Course> courses = Course.defaults}) async {
    await Navigator.of(context).push(
      PosPageRoute(
        builder: (_) => OrderScreen(
          api: widget.api,
          outbox: widget.outbox,
          photos: widget.photos,
          orderId: orderId,
          courses: courses,
        ),
      ),
    );
    _refresh();
    _floorKey.currentState?.refresh();
  }

  /// A free table seats a party; a busy one opens its check, or asks which one when it has several.
  Future<void> _onTable(FloorPlan plan, TableSpot table) async {
    final checks = plan.checksAt(table.id);
    if (checks.length == 1) return _open(checks.single.orderId, courses: plan.courses);
    if (checks.length > 1) {
      final picked = await showModalBottomSheet<String>(
        context: context,
        showDragHandle: true,
        builder: (context) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final c in checks)
                  ListTile(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    leading: CircleAvatar(child: Text(table.label)),
                    title: Text('${table.label} · ${c.guests ?? '?'} guests · ${c.server ?? ''}'),
                    subtitle: Text('${c.items} items · ${c.total ?? ''}'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).pop(c.orderId),
                  ),
                const Divider(height: 12),
                ListTile(
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  leading: const Icon(Icons.add_circle_outline),
                  title: const Text('New check at this table'),
                  onTap: () => Navigator.of(context).pop(''),
                ),
              ],
            ),
          ),
        ),
      );
      if (picked == null || !mounted) return;
      if (picked.isNotEmpty) return _open(picked, courses: plan.courses);
    }
    if (!mounted) return;
    final guests = await showDialog<int>(
      context: context,
      builder: (_) => _GuestsDialog(table: table),
    );
    if (guests == null || !mounted) return;
    await _create({'table': table.id, 'guests': guests, 'order_type': 'dine_in'}, courses: plan.courses);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final posColors = PosColors.of(context);
    final small = compact(context);
    final more = <(String, IconData, VoidCallback)>[
      ('Sign out', Icons.logout, widget.session.signOut),
      (
        _showClosed ? 'Hide closed' : 'Show closed',
        _showClosed ? Icons.visibility_off : Icons.visibility,
        () => setState(() {
          _showClosed = !_showClosed;
          _refresh();
        }),
      ),
      if (const {'manager', 'owner'}.contains(widget.session.staff?.role))
        (
          'Menu editor',
          Icons.edit_note,
          () => Navigator.of(context).push(
            PosPageRoute(
              builder: (_) => MenuEditorScreen(api: widget.api, settings: widget.settings),
            ),
          ),
        ),
      (
        'Settings',
        Icons.settings,
        () => Navigator.of(context).push(
          PosPageRoute(
            builder: (_) => SettingsScreen(settings: widget.settings, api: widget.api, relay: widget.relay),
          ),
        ),
      ),
    ];
    return Scaffold(
      appBar: AppBar(
        title: Text(
          small
              ? widget.session.staff?.name ?? 'Orders'
              : 'Orders · ${widget.session.staff?.name ?? ''} · ${widget.settings.device}',
        ),
        actions: [
          StatusIcon(api: widget.api, outbox: widget.outbox),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
            child: Container(
              width: small ? 40 : 60,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: scheme.outlineVariant),
              ),
              child: ClipRRect(borderRadius: BorderRadius.circular(7), child: widget.camera.preview()),
            ),
          ),
          IconButton(
            tooltip: _floor ? 'List of checks' : 'Floor map',
            icon: AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              child: Icon(
                _floor ? Icons.list_alt_rounded : Icons.table_restaurant_rounded,
                key: ValueKey(_floor),
              ),
            ),
            onPressed: () => setState(() => _floor = !_floor),
          ),
          if (small)
            // a phone: the rest go in one menu, so the title still fits
            PopupMenuButton<VoidCallback>(
              tooltip: 'More',
              onSelected: (action) => action(),
              itemBuilder: (_) => [
                for (final (label, icon, action) in more)
                  PopupMenuItem(
                    value: action,
                    child: ListTile(leading: Icon(icon), title: Text(label), contentPadding: EdgeInsets.zero),
                  ),
              ],
            )
          else
            for (final (label, icon, action) in more) IconButton(tooltip: label, icon: Icon(icon), onPressed: action),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              child: _floor
                  ? FloorView(key: _floorKey, api: widget.api, onTable: _onTable)
                  : _orders.isEmpty
                  ? Center(
                      key: const ValueKey('empty-orders'),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            padding: const EdgeInsets.all(18),
                            decoration: BoxDecoration(
                              color: scheme.surfaceContainerLow,
                              shape: BoxShape.circle,
                            ),
                            child: Icon(Icons.receipt_long_outlined, size: 36, color: scheme.outline),
                          ),
                          const SizedBox(height: 14),
                          const Text('No open orders. Tap + to start one.'),
                        ],
                      ),
                    )
                  : ListView.separated(
                      key: const ValueKey('orders-list'),
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 88),
                      itemCount: _orders.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, i) {
                        final order = _orders[i];
                        final lines = order.activeLines;
                        final items = lines.fold<int>(0, (n, l) => n + l.qty);
                        final isTakeout = order.table.isEmpty;
                        return PressableScale(
                          pressedScale: 0.985,
                          child: Card(
                            child: ListTile(
                              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                              leading: CircleAvatar(
                                backgroundColor: order.isFired ? posColors.fired : scheme.primaryContainer,
                                foregroundColor: order.isFired ? posColors.firedText : scheme.onPrimaryContainer,
                                child: Text(
                                  isTakeout ? '?' : order.table,
                                  style: const TextStyle(fontWeight: FontWeight.w700),
                                ),
                              ),
                              title: Text(
                                isTakeout ? 'To go ${order.fields['note'] ?? ''}' : 'Table ${order.table}',
                                style: theme.textTheme.titleMedium,
                              ),
                              subtitle: Text(
                                '$items items · ${order.status}${order.isFired ? ' · fired' : ''}',
                                style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                              ),
                              trailing: const Icon(Icons.chevron_right),
                              onTap: () => _open(order.orderId),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _newOrder,
        icon: const Icon(Icons.shopping_bag_outlined),
        label: const Text('To go'),
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
      title: const Text('To-go order'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(
          labelText: 'Name for the order (optional)',
          prefixIcon: Icon(Icons.person_outline),
        ),
        onSubmitted: (v) => Navigator.of(context).pop(v.trim()),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.of(context).pop(_controller.text.trim()), child: const Text('Start')),
      ],
    );
  }
}

class _GuestsDialog extends StatefulWidget {
  const _GuestsDialog({required this.table});
  final TableSpot table;

  @override
  State<_GuestsDialog> createState() => _GuestsDialogState();
}

class _GuestsDialogState extends State<_GuestsDialog> {
  late int _guests = widget.table.kind == 'counter' ? 1 : widget.table.seats;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return AlertDialog(
      title: Text('Seat ${widget.table.label}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: scheme.outlineVariant),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  onPressed: _guests > 1 ? () => setState(() => _guests--) : null,
                  icon: const Icon(Icons.remove),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text(
                    '$_guests guests',
                    style: theme.textTheme.titleLarge?.copyWith(fontFeatures: PosTheme.tabular),
                  ),
                ),
                IconButton(onPressed: () => setState(() => _guests++), icon: const Icon(Icons.add)),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 6,
            children: [
              for (final preset in const [1, 2, 4, 6, 8])
                ActionChip(
                  label: Text('$preset'),
                  visualDensity: VisualDensity.compact,
                  backgroundColor: _guests == preset ? scheme.primaryContainer : null,
                  onPressed: () => setState(() => _guests = preset),
                ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.of(context).pop(_guests), child: const Text('Seat')),
      ],
    );
  }
}
