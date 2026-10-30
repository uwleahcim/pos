import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../api.dart';
import '../floor.dart';
import 'theme.dart';

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
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final posColors = PosColors.of(context);
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
        Container(
          height: 54,
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLowest,
            border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
          ),
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              for (final r in [null, ...rooms])
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                  child: ChoiceChip(
                    label: Text(r?.name ?? 'Whole floor'),
                    selected: _room == r?.id,
                    onSelected: (_) => setState(() => _room = r?.id),
                  ),
                ),
              Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: scheme.outlineVariant),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: busy > 0 ? posColors.firedBorder : scheme.outline,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '$busy of ${plan.tables.length} tables open',
                          style: theme.textTheme.labelMedium?.copyWith(
                            fontFeatures: PosTheme.tabular,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ColoredBox(
            color: posColors.floorCanvas,
            child: CustomPaint(
              painter: _FloorGridPainter(color: posColors.floorGridDot),
              child: InteractiveViewer(
                maxScale: 4,
                child: Padding(
                  padding: const EdgeInsets.all(16),
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
                              key: ValueKey(t.id),
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
          ),
        ),
        const _Legend(),
      ],
    );
  }
}

class _FloorGridPainter extends CustomPainter {
  const _FloorGridPainter({required this.color});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    const step = 28.0;
    for (double x = step / 2; x < size.width; x += step) {
      for (double y = step / 2; y < size.height; y += step) {
        canvas.drawCircle(Offset(x, y), 1.1, paint);
      }
    }
  }

  @override
  bool shouldRepaint(_FloorGridPainter old) => old.color != color;
}

class _RoomOutline extends StatelessWidget {
  const _RoomOutline({required this.name});
  final String name;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final posColors = PosColors.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: posColors.roomFill,
        border: Border.all(color: posColors.roomBorder, width: 1.8),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Align(
        alignment: Alignment.bottomRight,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLow.withValues(alpha: 0.85),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: posColors.roomBorder.withValues(alpha: 0.6)),
            ),
            child: Text(
              name,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.2,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
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

(Color fill, Color border, Color text) _stageStyle(PosColors colors, String? stage) => switch (stage) {
  'seated' => (colors.seated, colors.seatedBorder, colors.seatedText),
  'waiting' => (colors.waiting, colors.waitingBorder, colors.waitingText),
  'fired' => (colors.fired, colors.firedBorder, colors.firedText),
  _ => (colors.freeTable, colors.freeTableBorder, colors.freeTableText),
};

class _TablePositioned extends StatelessWidget {
  const _TablePositioned({
    super.key,
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
    final posColors = PosColors.of(context);
    final w = math.max(table.w, _minSide), h = math.max(table.h, _minSide);
    final check = checks.firstOrNull;
    final minutes = check?.minutesOpen(DateTime.now());
    final (fill, border, textColor) = _stageStyle(posColors, check?.stage);
    final radius = BorderRadius.circular(table.kind == 'booth' ? 12 : 8);
    final shape = table.round
        ? CircleBorder(
            side: BorderSide(color: border, width: check == null ? 1.5 : 2.2),
          )
        : RoundedRectangleBorder(
            borderRadius: radius,
            side: BorderSide(color: border, width: check == null ? 1.5 : 2.2),
          );

    return Positioned(
      left: table.x - w / 2 - left,
      top: table.y - h / 2 - top,
      width: w,
      height: h,
      child: Transform.rotate(
        angle: table.rotation * math.pi / 180,
        child: PressableScale(
          pressedScale: 0.93,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
            decoration: ShapeDecoration(
              color: fill,
              shape: shape,
              shadows: [
                BoxShadow(
                  color: check == null ? Colors.black.withValues(alpha: 0.04) : border.withValues(alpha: 0.22),
                  blurRadius: check == null ? 4 : 10,
                  offset: Offset(0, check == null ? 2 : 3),
                ),
              ],
            ),
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                customBorder: table.round ? const CircleBorder() : RoundedRectangleBorder(borderRadius: radius),
                onTap: onTap,
                child: Transform.rotate(
                  angle: -table.rotation * math.pi / 180,
                  child: Center(
                    child: FittedBox(
                      child: Padding(
                        padding: const EdgeInsets.all(3),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              table.label,
                              style: TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 14,
                                color: textColor,
                                letterSpacing: -0.2,
                              ),
                            ),
                            if (check != null)
                              Container(
                                margin: const EdgeInsets.only(top: 1),
                                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0.5),
                                decoration: BoxDecoration(
                                  color: border.withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  '${check.guests ?? '?'}p ${minutes}m${checks.length > 1 ? ' +${checks.length - 1}' : ''}',
                                  style: TextStyle(
                                    fontSize: 9.5,
                                    fontWeight: FontWeight.w700,
                                    color: textColor,
                                    fontFeatures: PosTheme.tabular,
                                  ),
                                ),
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
        ),
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final posColors = PosColors.of(context);
    Widget dot(String? stage, String label) {
      final (fill, border, _) = _stageStyle(posColors, stage);
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 13,
              height: 13,
              decoration: BoxDecoration(
                color: fill,
                shape: BoxShape.circle,
                border: Border.all(color: border, width: 2),
              ),
            ),
            const SizedBox(width: 6),
            Text(label, style: theme.textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant)),
          ],
        ),
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
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
