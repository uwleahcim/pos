import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../api.dart';
import '../floor.dart';

/// The restaurant's floor as drawn on its plan: tables coloured by what is happening at them, a room picker,
/// and a tap that opens the table's check (or seats a new party).
class FloorView extends StatefulWidget {
  const FloorView({super.key, required this.api, required this.onTable});

  final PosApi api;
  final void Function(FloorPlan plan, TableSpot table) onTable;

  @override
  State<FloorView> createState() => FloorViewState();
}

class FloorViewState extends State<FloorView> {
  FloorPlan? _plan;
  String? _room; // null = the whole floor
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => refresh());
    refresh();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> refresh() async {
    try {
      final plan = await widget.api.floor();
      if (mounted) setState(() => _plan = plan);
    } on ApiException {
      // The status bar shows the outage; the map keeps its last picture.
    }
  }

  @override
  Widget build(BuildContext context) {
    final plan = _plan;
    if (plan == null) return const Center(child: CircularProgressIndicator());
    final rooms = plan.rooms;
    final room = rooms.where((r) => r.id == _room).firstOrNull;
    final shown = plan.tables.where((t) => room == null || t.room == room.id).toList();
    // The frame: the chosen room, or every room together.
    final left = room?.x ?? rooms.map((r) => r.x).fold<double>(plan.width, math.min);
    final top = room?.y ?? rooms.map((r) => r.y).fold<double>(plan.height, math.min);
    final right = room == null ? rooms.map((r) => r.x + r.w).fold<double>(0, math.max) : room.x + room.w;
    final bottom = room == null ? rooms.map((r) => r.y + r.h).fold<double>(0, math.max) : room.y + room.h;
    final busy = plan.status.length;
    return Column(
      children: [
        SizedBox(
          height: 48,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            children: [
              for (final r in [null, ...rooms])
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                  child: ChoiceChip(
                    label: Text(r?.name ?? 'Whole floor'),
                    selected: _room == r?.id,
                    onSelected: (_) => setState(() => _room = r?.id),
                  ),
                ),
              Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text('$busy of ${plan.tables.length} tables open'),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: InteractiveViewer(
            maxScale: 4,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: FittedBox(
                child: SizedBox(
                  width: right - left,
                  height: bottom - top,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      if (room == null)
                        for (final r in rooms)
                          Positioned(
                            left: r.x - left,
                            top: r.y - top,
                            width: r.w,
                            height: r.h,
                            child: _RoomOutline(name: r.name),
                          ),
                      for (final t in shown)
                        _TablePositioned(
                          table: t,
                          left: left,
                          top: top,
                          checks: plan.checksAt(t.id),
                          onTap: () => widget.onTable(plan, t),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        const _Legend(),
      ],
    );
  }
}

class _RoomOutline extends StatelessWidget {
  const _RoomOutline({required this.name});
  final String name;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant, width: 2),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Align(
        alignment: Alignment.bottomRight,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Text(name, style: TextStyle(fontSize: 22, color: scheme.outline)),
        ),
      ),
    );
  }
}

/// Table colours: free, seated (nothing sent yet), waiting (a course is held), fired (everything sent).
Color stageColor(ColorScheme scheme, String? stage) => switch (stage) {
  'seated' => Colors.blue.shade300,
  'waiting' => Colors.orange.shade300,
  'fired' => Colors.green.shade400,
  _ => scheme.surfaceContainerHighest,
};

class _TablePositioned extends StatelessWidget {
  const _TablePositioned({
    required this.table,
    required this.left,
    required this.top,
    required this.checks,
    required this.onTap,
  });

  final TableSpot table;
  final double left, top;
  final List<TableCheck> checks;
  final VoidCallback onTap;

  static const _minSide = 34.0; // keeps counter stools big enough to tap

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final w = math.max(table.w, _minSide), h = math.max(table.h, _minSide);
    final check = checks.firstOrNull;
    final minutes = check?.minutesOpen(DateTime.now());
    final color = stageColor(scheme, check?.stage);
    return Positioned(
      left: table.x - w / 2 - left,
      top: table.y - h / 2 - top,
      width: w,
      height: h,
      child: Transform.rotate(
        angle: table.rotation * math.pi / 180,
        child: Material(
          color: color,
          shape: table.round
              ? const CircleBorder()
              : RoundedRectangleBorder(borderRadius: BorderRadius.circular(table.kind == 'booth' ? 10 : 4)),
          elevation: check == null ? 0 : 2,
          child: InkWell(
            customBorder: table.round ? const CircleBorder() : null,
            onTap: onTap,
            child: Transform.rotate(
              angle: -table.rotation * math.pi / 180,
              child: Center(
                child: FittedBox(
                  child: Padding(
                    padding: const EdgeInsets.all(2),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(table.label, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                        if (check != null)
                          Text(
                            '${check.guests ?? '?'}p ${minutes}m${checks.length > 1 ? ' +${checks.length - 1}' : ''}',
                            style: const TextStyle(fontSize: 10),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget dot(String? stage, String label) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(color: stageColor(scheme, stage), shape: BoxShape.circle),
          ),
          const SizedBox(width: 4),
          Text(label),
        ],
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Wrap(
        alignment: WrapAlignment.center,
        children: [
          dot(null, 'Free'),
          dot('seated', 'Seated'),
          dot('waiting', 'Course held'),
          dot('fired', 'All fired'),
        ],
      ),
    );
  }
}
