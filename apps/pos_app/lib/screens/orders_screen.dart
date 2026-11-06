import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../camera.dart';
import '../coursing.dart';
import '../desk_phone_watcher.dart';
import '../floor.dart';
import '../local_order.dart';
import '../outbox.dart';
import '../phone.dart';
import '../photos.dart';
import '../print_relay.dart';
import '../session.dart';
import '../settings.dart';
import '../takeout.dart';
import 'compact.dart';
import 'display_dialog.dart';
import 'floor_view.dart';
import 'location_settings_screen.dart';
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
    this.phone,
    this.deskPhones,
  });

  final PosApi api;
  final Outbox outbox;
  final Settings settings;
  final Session session;
  final EventCamera camera;
  final PhotoQueue photos;
  final PrintRelay? relay;

  /// The terminal's phone, when it is one: a caller on the line, or just off it, goes into a to-go order.
  final PhoneClient? phone;

  /// The desk phones linked to this device: a call taken on one opens the caller's order here, as if this
  /// terminal had picked up.
  final DeskPhoneWatcher? deskPhones;

  @override
  State<OrdersScreen> createState() => _OrdersScreenState();
}

class _OrdersScreenState extends State<OrdersScreen> {
  List<Order> _orders = const [];
  bool _showClosed = false;
  bool _floor = true;
  final _floorKey = GlobalKey<FloorViewState>();
  Timer? _timer;
  // The counts as they stood when this screen came up, so only what happens from now on opens anything (set
  // here, not lazily: the first notification may be the one that moves a count).
  int _orderRequests = 0;
  int _answers = 0;
  int _deskCalls = 0;
  bool _ordering = false; // the to-go form is open

  @override
  void initState() {
    super.initState();
    _orderRequests = widget.phone?.orderRequests ?? 0;
    _answers = widget.phone?.answers ?? 0;
    _deskCalls = widget.deskPhones?.calls ?? 0;
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _refresh());
    widget.outbox.addListener(_onOutbox);
    widget.phone?.addListener(_onPhone);
    widget.deskPhones?.addListener(_onDeskPhone);
    // A desk phone picked up just before someone signed in: its call is still waiting, if it is fresh.
    WidgetsBinding.instance.addPostFrameCallback((_) => _takeDeskCall());
    _refresh();
  }

  @override
  void dispose() {
    _timer?.cancel();
    widget.outbox.removeListener(_onOutbox);
    widget.phone?.removeListener(_onPhone);
    widget.deskPhones?.removeListener(_onDeskPhone);
    super.dispose();
  }

  void _onOutbox() {
    if (mounted) setState(() {});
  }

  /// The caller changed, a call was picked up, or To go was tapped on the call strip: the caller's order
  /// opens, or the form opens for the caller, once.
  void _onPhone() {
    if (!mounted) return;
    final phone = widget.phone!;
    if (phone.answers != _answers) {
      _answers = phone.answers;
      unawaited(_callAnswered(phone.caller));
    }
    if (phone.orderRequests != _orderRequests) {
      _orderRequests = phone.orderRequests;
      if (!_ordering) unawaited(_newOrder());
    }
    setState(() {});
  }

  /// A call taken on a desk phone linked to this device: the same as picking up here. A call this terminal's
  /// own phone took is left to it, so one call opens one thing.
  void _onDeskPhone() {
    if (!mounted) return;
    final desk = widget.deskPhones!;
    if (desk.calls == _deskCalls) return;
    _deskCalls = desk.calls;
    _takeDeskCall();
  }

  void _takeDeskCall() {
    if (!mounted) return;
    final call = widget.deskPhones?.take();
    if (call == null) return;
    final own = widget.settings.phone;
    if (own.active && own.extension == call.extension) return;
    unawaited(_callAnswered(call.caller));
  }

  /// A call picked up on this terminal, or on a desk phone linked to it: the last order the number opened
  /// today comes up, so a customer calling back lands on their order; with none (or no number, or no hub
  /// answering) the to-go form opens for the caller instead. Whatever screen was open stays underneath for
  /// afterwards.
  Future<void> _callAnswered(Caller? caller) async {
    final number = caller?.number?.trim() ?? '';
    Order? order;
    if (number.isNotEmpty) {
      try {
        order = await widget.api.lastOrder(phone: number);
      } on ApiException {
        order = null; // nothing answers, or the hub refused: a new order is the next best thing
      }
    }
    if (!mounted) return;
    if (order != null) return _open(order.orderId);
    if (!_ordering) await _newOrder(caller: caller);
  }

  Future<void> _refresh() async {
    try {
      final orders = await widget.api.listOrders(status: _showClosed ? null : 'open');
      if (mounted) setState(() => _orders = orders);
    } on ApiException {
      // The status bar already shows the outage; the list keeps its last picture.
    }
  }

  /// The checks to list: the backend's, and before them the ones opened on this screen that no backend has
  /// heard of yet (their create is still queued), so a check taken offline can be reopened.
  List<(Order, bool)> get _listed {
    final queued = queuedOrders(widget.outbox).where((q) => !_orders.any((o) => o.orderId == q.orderId));
    return [for (final q in queued) (q, true), for (final o in _orders) (o, false)];
  }

  /// Counter mode (architecture section 12): name and phone first, the channel, when it is for. The hub
  /// numbers the order when the create arrives; the quote comes from the hub's settings per channel. With a
  /// caller on the phone, or just off it, or [caller] from a desk phone, the form starts with the number,
  /// the channel and the caller-ID name.
  Future<void> _newOrder({Caller? caller}) async {
    if (_ordering) return;
    _ordering = true;
    try {
      Quotes quotes;
      try {
        quotes = await widget.api.quotes();
      } on ApiException {
        quotes = const Quotes(); // the hub's own defaults, until it answers
      }
      if (!mounted) return;
      final who = caller ?? widget.phone?.callerForOrder;
      final request = await showDialog<TakeoutRequest>(
        context: context,
        builder: (context) => _TakeoutDialog(quotes: quotes, caller: who),
      );
      if (request == null || !mounted) return;
      await _startOrder(request, quotes);
    } finally {
      _ordering = false;
    }
  }

  Future<void> _startOrder(TakeoutRequest request, Quotes quotes) async {
    final minutes = quotes.minutesFor(request.channel);
    final promised = request.promisedAt ?? DateTime.now().add(Duration(minutes: minutes));
    await _create({
      'order_type': 'takeout',
      'channel': request.channel,
      'customer_name': request.name,
      if (request.phone.isNotEmpty) 'phone': request.phone,
      'locale': request.locale,
      'quoted_minutes': minutes,
      'promised_at': promised.millisecondsSinceEpoch,
      'stage': 'new',
    });
  }

  /// Ready sends the customer their text (the hub does, once); picked up closes the check.
  Future<void> _setStage(Order order, String stage) async {
    await widget.outbox.addAll(order.orderId, [
      ('set_field', {'stage': stage}),
      if (stage == 'picked_up') ('close', {}),
    ]);
  }

  /// What a manager sets for the whole location (coursing, quote times), behind the manager PIN.
  Future<void> _location() async {
    final token = await showDialog<String>(
      context: context,
      builder: (_) => ManagerPinDialog(
        api: widget.api,
        device: widget.settings.device,
        action: 'Open location settings',
        what: 'change location settings',
      ),
    );
    if (token == null || !mounted) return;
    await Navigator.of(context).push(
      PosPageRoute(
        builder: (_) => LocationSettingsScreen(
          api: widget.api,
          token: token,
          device: widget.settings.device,
          camera: widget.camera,
        ),
      ),
    );
  }

  /// Opens a new check with these fields, stamped with the signed-in server, and shows it.
  Future<void> _create(Map<String, dynamic> fields) async {
    final staff = widget.session.staff;
    final orderId = widget.outbox.newId();
    final opId = await widget.outbox.add(orderId, 'create', {
      ...fields,
      if (staff != null) 'server': staff.name,
      if (staff != null) 'server_id': staff.staffId,
    });
    unawaited(widget.photos.capture('create', opId: opId));
    if (!mounted) return;
    await _open(orderId);
  }

  Future<void> _open(String orderId) async {
    // The location's coursing as the hub has it now, or as last read: a manager's change reaches every
    // terminal on the next order it opens. With nothing read yet, the standard courses.
    Coursing coursing;
    try {
      coursing = await widget.api.coursing();
    } on ApiException {
      coursing = Coursing.defaults;
    }
    if (!mounted) return;
    await Navigator.of(context).push(
      PosPageRoute(
        builder: (_) => OrderScreen(
          api: widget.api,
          outbox: widget.outbox,
          photos: widget.photos,
          orderId: orderId,
          coursing: coursing,
          staffName: widget.session.staff?.name,
          phone: widget.phone,
        ),
      ),
    );
    _refresh();
    _floorKey.currentState?.refresh();
  }

  /// A free table seats a party; a busy one opens its check, or asks which one when it has several.
  Future<void> _onTable(FloorPlan plan, TableSpot table) async {
    final checks = plan.checksAt(table.id);
    if (checks.length == 1) return _open(checks.single.orderId);
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
      if (picked.isNotEmpty) return _open(picked);
    }
    if (!mounted) return;
    final guests = await showDialog<int>(
      context: context,
      builder: (_) => _GuestsDialog(table: table),
    );
    if (guests == null || !mounted) return;
    await _create({'table': table.id, 'guests': guests, 'order_type': 'dine_in'});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final posColors = PosColors.of(context);
    final small = compact(context);
    final listed = _listed;
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
        ('Location', Icons.storefront_outlined, _location),
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
        'Display',
        Icons.text_fields,
        () => showDialog<void>(
          context: context,
          builder: (_) => DisplayDialog(session: widget.session),
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
          StatusIcon(api: widget.api, outbox: widget.outbox, phone: widget.phone),
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
              child: Icon(_floor ? Icons.list_alt_rounded : Icons.table_restaurant_rounded, key: ValueKey(_floor)),
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
          CaptureBanner(api: widget.api, outbox: widget.outbox),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              child: _floor
                  ? FloorView(key: _floorKey, api: widget.api, outbox: widget.outbox, onTable: _onTable)
                  : listed.isEmpty
                  ? Center(
                      key: const ValueKey('empty-orders'),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            padding: const EdgeInsets.all(18),
                            decoration: BoxDecoration(color: scheme.surfaceContainerLow, shape: BoxShape.circle),
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
                      itemCount: listed.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, i) {
                        final (order, queued) = listed[i];
                        final lines = order.activeLines;
                        final items = lines.fold<int>(0, (n, l) => n + l.qty);
                        final isTakeout = order.isTakeout;
                        final stage = order.stage;
                        // Counter mode: the number the hub gave it, the name, the channel, when it is for,
                        // whether it is paid, and the next step (Ready texts the customer; Picked up closes).
                        final Widget? step = !isTakeout || !order.isOpen || !order.isFired
                            ? null
                            : stage == 'new'
                            ? FilledButton.tonal(
                                key: ValueKey('ready-${order.orderId}'),
                                onPressed: () => _setStage(order, 'ready'),
                                child: const Text('Ready'),
                              )
                            : stage == 'ready'
                            ? FilledButton.tonal(
                                key: ValueKey('picked-up-${order.orderId}'),
                                onPressed: () => _setStage(order, 'picked_up'),
                                child: const Text('Picked up'),
                              )
                            : null;
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
                                  isTakeout ? '${order.orderNo ?? '…'}' : order.table,
                                  style: const TextStyle(fontWeight: FontWeight.w700),
                                ),
                              ),
                              title: Text(
                                isTakeout
                                    ? [
                                        order.customerName.isEmpty ? 'To go' : order.customerName,
                                        if (order.channel.isNotEmpty) channelLabel(order.channel).toLowerCase(),
                                      ].join(' · ')
                                    : 'Table ${order.table}',
                                style: theme.textTheme.titleMedium,
                              ),
                              subtitle: Text(
                                [
                                  '$items items',
                                  order.status,
                                  if (order.isFired) 'fired',
                                  if (isTakeout && order.promisedAt != null) 'ready ${clockTime(order.promisedAt!)}',
                                  if (isTakeout) order.hasPaid ? 'paid' : 'pay at pickup',
                                  if (isTakeout && stageLabel(stage).isNotEmpty) stageLabel(stage).toUpperCase(),
                                  if (queued) 'waiting to send',
                                ].join(' · '),
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: queued ? scheme.error : scheme.onSurfaceVariant,
                                ),
                              ),
                              trailing: step ?? const Icon(Icons.chevron_right),
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
      // With a caller on the phone, or just off it, the button names the caller: the order starts with the number.
      floatingActionButton: FloatingActionButton.extended(
        key: const ValueKey('to-go'),
        onPressed: () => _newOrder(),
        icon: const Icon(Icons.shopping_bag_outlined),
        label: Text(switch (widget.phone?.callerForOrder) {
          null => 'To go',
          final caller => caller.formatted.isEmpty ? 'To go' : 'To go · ${caller.formatted}',
        }),
      ),
    );
  }
}

/// The first tap of a to-go order: name and phone, the channel, the language for texts, and whether it is
/// for now (the channel's quote) or a later time today or tomorrow. For a [caller] the number, the phone
/// channel and the caller-ID name are filled in; all of it stays editable.
class _TakeoutDialog extends StatefulWidget {
  const _TakeoutDialog({required this.quotes, this.caller});
  final Quotes quotes;
  final Caller? caller;

  @override
  State<_TakeoutDialog> createState() => _TakeoutDialogState();
}

class _TakeoutDialogState extends State<_TakeoutDialog> {
  late final _name = TextEditingController(text: widget.caller?.displayName ?? '');
  late final _phone = TextEditingController(text: widget.caller?.formatted ?? '');
  late String _channel = widget.caller == null ? 'counter' : 'phone';
  String _locale = 'en';
  bool _later = false;
  int _dayOffset = 0; // 0 today, 1 tomorrow
  TimeOfDay? _time;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  DateTime? get _promised {
    final time = _time;
    if (!_later || time == null) return null;
    final day = DateTime.now().add(Duration(days: _dayOffset));
    return DateTime(day.year, day.month, day.day, time.hour, time.minute);
  }

  bool get _ready => _name.text.trim().isNotEmpty && (!_later || _time != null);

  void _start() => Navigator.of(context).pop(
    TakeoutRequest(
      name: _name.text.trim(),
      phone: _phone.text.trim(),
      channel: _channel,
      locale: _locale,
      promisedAt: _promised,
    ),
  );

  Future<void> _pickTime() async {
    final picked = await showTimePicker(context: context, initialTime: _time ?? TimeOfDay.now());
    if (picked != null && mounted) setState(() => _time = picked);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final minutes = widget.quotes.minutesFor(_channel);
    return AlertDialog(
      title: const Text('To-go order'),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                key: const ValueKey('takeout-name'),
                controller: _name,
                autofocus: true,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Name', prefixIcon: Icon(Icons.person_outline)),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 8),
              TextField(
                key: const ValueKey('takeout-phone'),
                controller: _phone,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                  labelText: 'Phone (for the ready text)',
                  prefixIcon: Icon(Icons.phone_outlined),
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: [
                  for (final c in handChannels)
                    ChoiceChip(
                      key: ValueKey('channel:$c'),
                      label: Text(channelLabel(c)),
                      selected: _channel == c,
                      onSelected: (_) => setState(() => _channel = c),
                    ),
                  const SizedBox(width: 8),
                  for (final (code, label) in const [('en', 'English'), ('zh', '中文')])
                    ChoiceChip(
                      key: ValueKey('locale:$code'),
                      label: Text(label),
                      selected: _locale == code,
                      onSelected: (_) => setState(() => _locale = code),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                key: const ValueKey('takeout-later'),
                contentPadding: EdgeInsets.zero,
                title: const Text('For later'),
                subtitle: Text(_later ? 'Prints ahead of its time by the quote' : 'Ready in about $minutes min'),
                value: _later,
                onChanged: (on) => setState(() => _later = on),
              ),
              if (_later)
                Wrap(
                  spacing: 10,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    SegmentedButton<int>(
                      segments: const [
                        ButtonSegment(value: 0, label: Text('Today')),
                        ButtonSegment(value: 1, label: Text('Tomorrow')),
                      ],
                      selected: {_dayOffset},
                      showSelectedIcon: false,
                      onSelectionChanged: (s) => setState(() => _dayOffset = s.first),
                    ),
                    OutlinedButton.icon(
                      key: const ValueKey('takeout-time'),
                      onPressed: _pickTime,
                      icon: const Icon(Icons.schedule),
                      label: Text(_time == null ? 'Time' : _time!.format(context)),
                    ),
                  ],
                ),
              if (_later && _time == null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text('Pick the time it is for.', style: theme.textTheme.bodySmall),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('takeout-start'),
          onPressed: _ready ? _start : null,
          child: const Text('Start'),
        ),
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
