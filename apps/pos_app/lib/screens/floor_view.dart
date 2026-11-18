import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show PathMetric;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../api.dart';
import '../floor.dart';
import '../live.dart';
import '../local_order.dart';
import '../outbox.dart';
import '../roster.dart';
import 'booked_table_dialog.dart' show holdColors;
import 'ready_mark.dart';
import 'theme.dart';

/// The restaurant's floor as drawn on its plan: tables coloured by what is happening at them, a room picker,
/// and a tap that opens the table's check (or seats a new party). With an [outbox], the checks this device
/// opened that no backend knows yet are on their tables too (ADR 6).
///
/// Each busy table's edge is a countdown: a ring that starts whole and unwinds counter-clockwise to twelve
/// o'clock as the table waits on its stage (seated with no order, dishes not sent, a course held, everything
/// sent), amber when it is running out, whole again and flashing red once time is up, with a badge that says
/// what and how long. The hub says what each table waits on and since when, and what each stage is given
/// (`/settings/table_timers`); the map only runs the clock. The clock costs the map nothing it can avoid: the
/// rings are one painted layer, repainted only when one of them would look different, and the few words that
/// follow the clock (minutes, badges, the count of tables that need a look) are rebuilt one by one as theirs
/// change. The tables are rebuilt when the hub has news, as before.
///
/// "Mine" (a chip at the start of the bar, for whoever a table can be theirs) picks out that person's tables:
/// the other servers' fade but stay where they are and still open on a tap, a free table stays as it is, and
/// the count of tables that need a look is of their own. On a screen with the room for it, their tables are
/// also listed beside the map.
class FloorView extends StatefulWidget {
  const FloorView({
    super.key,
    required this.api,
    required this.onTable,
    this.onTableHeld,
    this.outbox,
    this.now,
    this.me,
    this.mine = false,
    this.onMine,
    this.moving,
  });

  final PosApi api;
  final void Function(FloorPlan plan, TableSpot table) onTable;

  /// A table was held down: where a host or manager hands a seated table to another server. Null on a map
  /// that offers none.
  final void Function(FloorPlan plan, TableSpot table)? onTableHeld;
  final Outbox? outbox;

  /// The time now in wall-clock ms: the hub's clock as [api] knows it, unless a test brings its own.
  final int Function()? now;

  /// Who is at this screen, when a table can be theirs: the map offers them "Mine". Null offers none.
  final StaffMember? me;

  /// "Mine" is on: the tables of [me] stand out and the other servers' fade.
  final bool mine;

  /// "Mine" was tapped: what it is to be now.
  final ValueChanged<bool>? onMine;

  /// The table being moved, by id: it stands out until the table it goes to is tapped. Null for none.
  final String? moving;

  @override
  State<FloorView> createState() => FloorViewState();
}

class FloorViewState extends State<FloorView> {
  FloorPlan? _plan;
  String? _room; // null = the whole floor
  Timer? _timer;
  Timer? _second;
  bool _inFront = true; // no check, screen or dialog is open over the map
  // The countdowns: the time as of the last second, for the parts that show it, and a number that moves only
  // when the rings would be painted differently, which is all that repaints them.
  late final _clock = ValueNotifier<int>(_nowMs());
  final _ringsLook = ValueNotifier<int>(0);
  _Rings? _rings;
  // The hub tells the map when a table's check changed; the timer only asks while it cannot, and now and then.
  late final _poll = SafetyPoll(widget.api.live);
  late final _reader = Paced(const Duration(seconds: 1), _read);
  StreamSubscription<LiveChange>? _live;

  @override
  void initState() {
    super.initState();
    // Under an open check nobody sees the map: it stops asking, and reads again the moment it is back.
    _timer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (_inFront && _poll.due()) unawaited(_reader.now(must: false));
    });
    _live = widget.api.live.changes.listen((change) {
      // a table booked, a reservation changed or ended: the tables kept for today come with the floor
      if (_inFront && (change.anyOrder || change.reservations)) _reader();
    });
    _second = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_inFront) _tick();
    });
    widget.outbox?.addListener(_onOutbox);
    refresh();
  }

  int _nowMs() => (widget.now ?? widget.api.nowMs)();

  /// The clock moved on: the words that show it hear of it, and the rings are repainted if they changed.
  void _tick() {
    _clock.value = _nowMs();
    _ringsLook.value = _rings?.look(_clock.value) ?? 0;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final inFront = ModalRoute.isCurrentOf(context) ?? true;
    if (inFront && !_inFront) {
      refresh();
      // After the frame: the clock's listeners rebuild, which they cannot be told to do during a build.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _inFront) _tick();
      });
    }
    _inFront = inFront;
  }

  @override
  void dispose() {
    _timer?.cancel();
    _second?.cancel();
    unawaited(_live?.cancel());
    _reader.cancel();
    widget.outbox?.removeListener(_onOutbox);
    _clock.dispose();
    _ringsLook.dispose();
    super.dispose();
  }

  void _onOutbox() {
    if (mounted) setState(() {});
  }

  Future<void> refresh() => _reader.now();

  Future<void> _read() async {
    _poll.asked();
    try {
      final plan = await widget.api.floor();
      // A backend with nothing new hands back the plan it gave last time: nothing to redraw then.
      if (mounted && !identical(plan, _plan)) {
        _clock.value = _nowMs(); // a table that just changed counts from now, not from the last second
        setState(() => _plan = plan);
      }
    } on ApiException {
      // The status bar shows the outage; the map keeps its last picture.
    }
  }

  /// The tables that need a look, the most pressing first, each with what it waits on in words; a tap opens
  /// the table. With [only], just those tables: a person's own while "Mine" is on.
  Future<void> _showAttention(FloorPlan plan, {Set<String>? only}) async {
    final now = _nowMs();
    final rows = [
      for (final table in plan.tables)
        if (only == null || only.contains(table.id))
          if (plan.countdownAt(table.id, now) case final at? when at.level != TimerLevel.ok) (table, at),
    ]..sort((a, b) => b.$2.moreUrgentThan(a.$2) ? 1 : (a.$2.moreUrgentThan(b.$2) ? -1 : 0));
    final picked = await showModalBottomSheet<TableSpot>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        final posColors = PosColors.of(context);
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              if (rows.isEmpty)
                ListTile(
                  title: Text(
                    only == null ? 'No table needs a look right now' : 'None of your tables needs a look right now',
                  ),
                ),
              for (final (table, at) in rows)
                ListTile(
                  key: ValueKey('attention:${table.id}'),
                  leading: CircleAvatar(
                    backgroundColor: at.level == TimerLevel.late ? posColors.timerLate : posColors.timerWarn,
                    foregroundColor: at.level == TimerLevel.late ? posColors.timerLateText : posColors.timerWarnText,
                    child: Icon(stageIcon(at.stage), size: 20),
                  ),
                  title: Text('${table.label} · ${timerStageLabel(at.stage)}'),
                  subtitle: Text(countdownInWords(at)),
                  trailing: Text(plan.checksAt(table.id).firstOrNull?.server ?? ''),
                  onTap: () => Navigator.of(context).pop(table),
                ),
            ],
          ),
        );
      },
    );
    if (picked != null && mounted) widget.onTable(plan, picked);
  }

  @override
  Widget build(BuildContext context) {
    final outbox = widget.outbox;
    final (movedTo, merged) = outbox == null ? (const <String, String>{}, const <String>{}) : queuedTables(outbox);
    final plan = outbox == null
        ? _plan
        : _plan?.withChecks(queuedChecks(outbox)).withServers(queuedServers(outbox)).withTables(movedTo, merged);
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
    // "Mine": the tables with a check of the person at this screen. While it is on the other servers' busy
    // tables fade; a free table never does, since anyone may seat it.
    final me = widget.me;
    final mine = me == null ? const <String>{} : tablesOf(plan, me);
    final mineOn = widget.mine && me != null;
    bool faded(String tableId) => mineOn && !mine.contains(tableId) && plan.checksAt(tableId).isNotEmpty;
    final looked = mineOn ? mine : null; // whose tables the count of those needing a look is of
    final rings = _rings = _Rings.of(plan, shown, left: left, top: top, colors: posColors, faded: faded);
    return Column(
      children: [
        Container(
          height: 54,
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLowest,
            border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
          ),
          child: Row(
            children: [
              // Pinned at the start, so it is there whichever room is shown and however far the rooms are
              // scrolled.
              if (me != null) ...[
                Padding(
                  padding: const EdgeInsets.only(left: 12),
                  child: FilterChip(
                    key: const ValueKey('mine-chip'),
                    label: Text('Mine ${mine.length}'),
                    showCheckmark: false,
                    selected: mineOn,
                    tooltip: mineOn ? 'Show every table the same' : 'Pick out my tables',
                    onSelected: widget.onMine,
                  ),
                ),
                Container(width: 1, height: 26, margin: const EdgeInsets.only(left: 10), color: scheme.outlineVariant),
              ],
              Expanded(
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
              // How many tables need a look, pinned at the end of the bar: seen whichever room is shown and
              // however far the rooms are scrolled; it takes no room while every table is fine.
              if (plan.timers.enabled)
                _Ticking<(int, int)>(
                  clock: _clock,
                  read: (now) => _needingALook(plan, now, only: looked),
                  builder: (context, counts) => _AttentionPill(
                    late: counts.$1,
                    soon: counts.$2,
                    onTap: () => _showAttention(plan, only: looked),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          // The map, and beside it on a screen with the room (a tablet on its side, a Mac) the person's
          // tables as a list while "Mine" is on. Narrower, the map keeps the whole width.
          child: LayoutBuilder(
            builder: (context, box) => Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
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
                                      holds: plan.holds[t.id] ?? const [],
                                      clock: _clock,
                                      ringed: rings.has(t.id),
                                      faded: faded(t.id),
                                      moving: t.id == widget.moving,
                                      onTap: () => widget.onTable(plan, t),
                                      onHeld: widget.onTableHeld == null ? null : () => widget.onTableHeld!(plan, t),
                                    ),
                                  // Every table's countdown ring, in one layer of its own: a second going by repaints
                                  // this and nothing else, and only when a ring moved.
                                  if (rings.all.isNotEmpty)
                                    Positioned.fill(
                                      child: IgnorePointer(
                                        child: RepaintBoundary(
                                          child: CustomPaint(
                                            key: const ValueKey('timer-rings'),
                                            painter: _RingsPainter(rings: rings, clock: _clock, look: _ringsLook),
                                          ),
                                        ),
                                      ),
                                    ),
                                  for (final ring in rings.all)
                                    Positioned(
                                      left: ring.center.dx - _TimerBadge.width / 2,
                                      top: ring.top - _TimerBadge.height / 2,
                                      width: _TimerBadge.width,
                                      height: _TimerBadge.height,
                                      child: IgnorePointer(
                                        child: _Ticking<(TimerLevel, String, String)?>(
                                          clock: _clock,
                                          read: (now) {
                                            final at = plan.countdownAt(ring.tableId, now);
                                            return at == null || at.level == TimerLevel.ok
                                                ? null
                                                : (at.level, at.stage, at.short);
                                          },
                                          builder: (context, shown) => shown == null
                                              ? const SizedBox.shrink()
                                              : _Faded(
                                                  faded: ring.faded,
                                                  child: _TimerBadge(
                                                    key: ValueKey('timer-badge:${ring.tableId}'),
                                                    level: shown.$1,
                                                    stage: shown.$2,
                                                    text: shown.$3,
                                                  ),
                                                ),
                                        ),
                                      ),
                                    ),
                                  // Dishes the kitchen marked made that wait to be carried: a badge on the
                                  // table's lower edge (the countdown's is on the upper), until they went out
                                  // or have waited too long to still be there.
                                  for (final t in shown)
                                    if (plan.checksAt(t.id).any((check) => check.ready > 0))
                                      Positioned(
                                        left: t.x - left - _ReadyBadge.width / 2,
                                        top:
                                            t.y -
                                            top +
                                            math.max(t.h, _TablePositioned._minSide) / 2 -
                                            _ReadyBadge.height / 2,
                                        width: _ReadyBadge.width,
                                        height: _ReadyBadge.height,
                                        child: IgnorePointer(
                                          child: _Ticking<int>(
                                            clock: _clock,
                                            read: (now) => plan.readyAt(t.id, now),
                                            builder: (context, count) => count == 0
                                                ? const SizedBox.shrink()
                                                : _Faded(
                                                    faded: faded(t.id),
                                                    child: _ReadyBadge(
                                                      key: ValueKey('ready-badge:${t.id}'),
                                                      count: count,
                                                    ),
                                                  ),
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
                if (mineOn && box.maxWidth >= _MyTables.fitsFrom)
                  _MyTables(
                    plan: plan,
                    me: me,
                    tables: [
                      for (final table in plan.tables)
                        if (mine.contains(table.id)) table,
                    ],
                    clock: _clock,
                    onTable: (table) => widget.onTable(plan, table),
                    onHeld: widget.onTableHeld == null ? null : (table) => widget.onTableHeld!(plan, table),
                  ),
              ],
            ),
          ),
        ),
        _Legend(booked: plan.holds.isNotEmpty),
      ],
    );
  }
}

/// What a booked table says of its reservations at one moment: the one that comes next, how its time
/// stands, and how many more of today are still to come after it.
typedef _HoldLook = ({TableHold hold, TimerLevel level, int more});

/// The look of [holds] (one table's, the earliest first) at [nowMs]; null once none is still to come. A
/// table that is [seated] says nothing of a reservation hours away, whose party finds it free again: only
/// of one the table is being kept for by now.
_HoldLook? _holdLook(List<TableHold> holds, int nowMs, {bool seated = false}) {
  TableHold? next;
  var more = 0;
  for (final hold in holds) {
    if (nowMs >= hold.untilMs) continue;
    if (next == null) {
      next = hold;
    } else {
      more++;
    }
  }
  if (next == null || (seated && !next.keptAt(nowMs))) return null;
  return (hold: next, level: next.levelAt(nowMs), more: more);
}

/// The tables with a check that is [server]'s.
Set<String> tablesOf(FloorPlan plan, StaffMember server) => {
  for (final MapEntry(key: table, value: checks) in plan.status.entries)
    if (checks.any((check) => check.isServedBy(server))) table,
};

/// How many tables are out of time and how many are running out: on the whole floor, or among [only].
(int, int) _needingALook(FloorPlan plan, int nowMs, {Set<String>? only}) {
  var late = 0, soon = 0;
  for (final table in plan.status.keys) {
    if (only != null && !only.contains(table)) continue;
    switch (plan.countdownAt(table, nowMs)?.level) {
      case TimerLevel.late:
        late++;
      case TimerLevel.warn:
        soon++;
      case TimerLevel.ok || null:
    }
  }
  return (late, soon);
}

/// A countdown as a sentence: "Held 18 min · 7 min left", "Seated 12 min with no order · 2 min over".
String countdownInWords(Countdown at) {
  final waited = switch (at.stage) {
    'sat' => 'Seated ${at.elapsedMinutes} min with no order',
    'unsent' => 'Dishes waiting ${at.elapsedMinutes} min to be sent',
    'held' => 'Held ${at.elapsedMinutes} min',
    'fired' => '${at.elapsedMinutes} min since the last dish was sent',
    _ => '${at.elapsedMinutes} min',
  };
  final left = !at.isUp
      ? '${at.minutes} min left'
      : at.minutes == 0
      ? 'time is up'
      : '${at.minutes} min over';
  return '$waited · $left';
}

/// The mark for what a table waits on: a seat (nothing ordered), an arrow (not sent), a pause (held), a
/// service bell (everything sent: look in on the table).
IconData stageIcon(String stage) => switch (stage) {
  'sat' => Icons.event_seat_rounded,
  'unsent' => Icons.send_rounded,
  'held' => Icons.pause_rounded,
  'fired' => Icons.room_service_rounded,
  _ => Icons.timer_outlined,
};

/// A part of the map that shows the clock. It hears every second and is rebuilt only when what it reads off
/// the clock ([read]) is something else than last time: a minute, a badge, a count.
class _Ticking<T> extends StatefulWidget {
  const _Ticking({super.key, required this.clock, required this.read, required this.builder});

  final ValueListenable<int> clock;
  final T Function(int nowMs) read;
  final Widget Function(BuildContext context, T value) builder;

  @override
  State<_Ticking<T>> createState() => _TickingState<T>();
}

class _TickingState<T> extends State<_Ticking<T>> {
  late T _value = widget.read(widget.clock.value);

  @override
  void initState() {
    super.initState();
    widget.clock.addListener(_tick);
  }

  @override
  void didUpdateWidget(_Ticking<T> old) {
    super.didUpdateWidget(old);
    if (old.clock != widget.clock) {
      old.clock.removeListener(_tick);
      widget.clock.addListener(_tick);
    }
    _value = widget.read(widget.clock.value); // the table it reads for may have changed
  }

  @override
  void dispose() {
    widget.clock.removeListener(_tick);
    super.dispose();
  }

  void _tick() {
    final next = widget.read(widget.clock.value);
    if (next != _value) setState(() => _value = next);
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _value);
}

/// One table's ring: the line round its edge, clockwise.
class _Ring {
  _Ring({
    required this.tableId,
    required this.center,
    required this.top,
    required Path path,
    required this.calm,
    this.faded = false,
  }) : metric = path.computeMetrics().first {
    twelve = _twelve();
  }

  /// How far inside the table's edge the middle of the ring's line runs, and how wide the line is while the
  /// countdown runs, is running out, and is over (plan units, like the table's own size).
  static const inset = 2.5;
  static const widths = {TimerLevel.ok: 4.0, TimerLevel.warn: 5.0, TimerLevel.late: 5.5};

  final String tableId;
  final Offset center;

  /// The top of the table as it stands unturned: where the badge sits.
  final double top;
  final PathMetric metric;

  /// How far along the line twelve o'clock is: the point straight above the table's middle on the screen,
  /// however the table is turned. Every countdown is read from there.
  late final double twelve;

  /// The ring's colour while nothing is pressing: the table's own border colour.
  final Color calm;

  /// Another server's table while "Mine" is on: its ring and badge are as faint as the table.
  final bool faded;

  /// The whole line.
  Path get whole => metric.extractPath(0, metric.length);

  /// What is left of a countdown: from twelve o'clock, clockwise, [left] of the way round. As the time goes
  /// its far end draws back counter-clockwise to twelve, like the hand of a kitchen timer going to zero.
  Path remaining(double left) {
    final length = metric.length, end = twelve + length * left;
    if (left >= 1) return whole;
    if (end <= length) return metric.extractPath(twelve, end);
    return metric.extractPath(twelve, length)..extendWithPath(metric.extractPath(0, end - length), Offset.zero);
  }

  double _twelve() {
    // How far round from straight up the point [at] along the line is, clockwise: 0 up to a full turn.
    double turn(double at) {
      final to = metric.getTangentForOffset(at)!.position - center;
      final angle = math.atan2(to.dx, -to.dy);
      return angle < 0 ? angle + 2 * math.pi : angle;
    }

    final first = turn(0);
    if (first < 1e-6) return 0; // a table that is not turned: its line starts at twelve
    // The line goes clockwise round the middle, so the turn grows along it until it passes twelve and starts
    // over below where it began: halve the stretch that holds that point.
    var before = 0.0, after = metric.length;
    for (var i = 0; i < 24; i++) {
      final mid = (before + after) / 2;
      if (turn(mid) >= first) {
        before = mid;
      } else {
        after = mid;
      }
    }
    return after;
  }

  static _Ring of(TableSpot table, Offset center, double w, double h, Color calm, {bool faded = false}) {
    final box = Rect.fromCenter(center: Offset.zero, width: w, height: h).deflate(inset);
    final path = Path();
    if (table.round) {
      // Two halves, so the line starts at the top whatever a full turn in one piece would start at.
      final circle = Rect.fromCircle(center: Offset.zero, radius: box.shortestSide / 2);
      path
        ..arcTo(circle, -math.pi / 2, math.pi, true)
        ..arcTo(circle, math.pi / 2, math.pi, false);
    } else {
      final r = Radius.circular(math.max((table.kind == 'booth' ? 12.0 : 8.0) - inset, 0));
      path
        ..moveTo(0, box.top)
        ..lineTo(box.right - r.x, box.top)
        ..arcToPoint(Offset(box.right, box.top + r.y), radius: r)
        ..lineTo(box.right, box.bottom - r.y)
        ..arcToPoint(Offset(box.right - r.x, box.bottom), radius: r)
        ..lineTo(box.left + r.x, box.bottom)
        ..arcToPoint(Offset(box.left, box.bottom - r.y), radius: r)
        ..lineTo(box.left, box.top + r.y)
        ..arcToPoint(Offset(box.left + r.x, box.top), radius: r)
        ..close();
    }
    final placed = Matrix4.translationValues(center.dx, center.dy, 0)..rotateZ(table.rotation * math.pi / 180);
    return _Ring(
      tableId: table.id,
      center: center,
      top: center.dy - h / 2,
      path: path.transform(placed.storage),
      calm: calm,
      faded: faded,
    );
  }
}

/// The rings of the tables on the map, with the plan their countdowns are read from.
class _Rings {
  const _Rings(this.plan, this.all, this.colors);

  /// A ring for each shown table that has a check waiting on a stage the location times.
  factory _Rings.of(
    FloorPlan plan,
    List<TableSpot> shown, {
    required double left,
    required double top,
    required PosColors colors,
    bool Function(String tableId)? faded,
  }) => _Rings(plan, [
    for (final table in shown)
      // Whether a table has a countdown does not depend on the time, only where it stands does.
      if (plan.countdownAt(table.id, 0) != null)
        _Ring.of(
          table,
          Offset(table.x - left, table.y - top),
          math.max(table.w, _TablePositioned._minSide),
          math.max(table.h, _TablePositioned._minSide),
          _stageStyle(colors, plan.checksAt(table.id).firstOrNull?.stage).$2,
          faded: faded?.call(table.id) ?? false,
        ),
  ], colors);

  final FloorPlan plan;
  final List<_Ring> all;
  final PosColors colors;

  bool has(String tableId) => all.any((ring) => ring.tableId == tableId);

  /// A number that is the same for as long as the rings would be painted the same: each ring's level, how
  /// much of it is left to the nearest unit of its length, and for one that is out of time which half of
  /// the flash it is in. The layer is repainted when this moves, so a floor of calm tables with long
  /// countdowns repaints every few seconds, and one with a table out of time once a second.
  int look(int nowMs) {
    var look = 17;
    for (final ring in all) {
      final at = plan.countdownAt(ring.tableId, nowMs);
      if (at == null) continue;
      final step = at.isUp ? -1 : (at.left * ring.metric.length).round();
      look = Object.hash(look, at.level, step, at.level == TimerLevel.late && flashOn(nowMs));
    }
    return look;
  }

  /// A ring out of time flashes: bright one second, dim the next.
  static bool flashOn(int nowMs) => (nowMs ~/ 1000).isEven;
}

class _RingsPainter extends CustomPainter {
  _RingsPainter({required this.rings, required this.clock, required Listenable look}) : super(repaint: look);

  final _Rings rings;
  final ValueListenable<int> clock;

  @override
  void paint(Canvas canvas, Size size) {
    final now = clock.value;
    final colors = rings.colors;
    final paint = Paint()..style = PaintingStyle.stroke;
    for (final ring in rings.all) {
      final at = rings.plan.countdownAt(ring.tableId, now);
      if (at == null) continue;
      paint.strokeWidth = _Ring.widths[at.level]!;
      final seen = ring.faded ? _Faded.to : 1.0;
      switch (at.level) {
        case TimerLevel.late:
          // Time is up: the whole ring again, in red, flashing.
          paint.color = colors.timerLate.withValues(alpha: (_Rings.flashOn(now) ? 1 : 0.35) * seen);
          canvas.drawPath(ring.whole, paint);
        case TimerLevel.warn || TimerLevel.ok:
          final colour = at.level == TimerLevel.warn ? colors.timerWarn : ring.calm;
          paint.color = colour.withValues(alpha: colour.a * seen);
          // What is left of the ring, unwinding counter-clockwise to twelve o'clock; a stage that only
          // nudges stands whole in amber once its time is up.
          canvas.drawPath(at.isUp ? ring.whole : ring.remaining(at.left), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_RingsPainter old) => old.rings != rings || old.clock != clock;
}

/// The badge on a table whose countdown is running out or over: what it waits on, and the minutes left
/// ("3m") or over ("+2m").
class _TimerBadge extends StatelessWidget {
  const _TimerBadge({super.key, required this.level, required this.stage, required this.text});

  final TimerLevel level;
  final String stage;
  final String text;

  /// The room a badge is given on the plan, centred on the top of its table (plan units).
  static const width = 44.0, height = 14.0;

  @override
  Widget build(BuildContext context) {
    final colors = PosColors.of(context);
    final late = level == TimerLevel.late;
    final ink = late ? colors.timerLateText : colors.timerWarnText;
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 3.5, vertical: 1),
        decoration: BoxDecoration(
          color: late ? colors.timerLate : colors.timerWarn,
          borderRadius: BorderRadius.circular(7),
          boxShadow: [
            BoxShadow(color: Colors.black.withValues(alpha: 0.18), blurRadius: 2, offset: const Offset(0, 1)),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(stageIcon(stage), size: 8.5, color: ink),
            const SizedBox(width: 1.5),
            Text(
              text,
              style: TextStyle(
                fontSize: 8.5,
                height: 1.1,
                fontWeight: FontWeight.w800,
                color: ink,
                fontFeatures: PosTheme.tabular,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The badge on a table with dishes the kitchen marked made that have not gone out: "2 ready". It stands on
/// the table's lower edge, so a table can wear it and its countdown's badge at once.
class _ReadyBadge extends StatelessWidget {
  const _ReadyBadge({super.key, required this.count});

  final int count;

  /// The room a badge is given on the plan, centred on the bottom of its table (plan units).
  static const width = 52.0, height = 14.0;

  @override
  Widget build(BuildContext context) {
    final (fill, ink) = readyColors(context);
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 3.5, vertical: 1),
        decoration: BoxDecoration(
          color: fill,
          borderRadius: BorderRadius.circular(7),
          boxShadow: [
            BoxShadow(color: Colors.black.withValues(alpha: 0.18), blurRadius: 2, offset: const Offset(0, 1)),
          ],
        ),
        // (a count of two figures, or a wider typeface, is drawn smaller sooner than cut off)
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(readyIcon, size: 8.5, color: ink),
              const SizedBox(width: 1.5),
              Text(
                '$count ready',
                style: TextStyle(
                  fontSize: 8.5,
                  height: 1.1,
                  fontWeight: FontWeight.w800,
                  color: ink,
                  fontFeatures: PosTheme.tabular,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// How many tables need a look, beside the count of open tables: red for tables out of time, amber for
/// ones running out. Nothing while every table is fine. A tap lists them.
class _AttentionPill extends StatelessWidget {
  const _AttentionPill({required this.late, required this.soon, required this.onTap});

  final int late, soon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    if (late + soon == 0) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final colors = PosColors.of(context);
    Widget count(int n, Color fill, Color ink) => Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
      decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(10)),
      child: Text(
        '$n',
        style: theme.textTheme.labelMedium?.copyWith(
          color: ink,
          fontWeight: FontWeight.w800,
          fontFeatures: PosTheme.tabular,
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(left: 4, right: 12),
      child: Tooltip(
        message: 'Tables that need a look',
        child: Material(
          color: theme.colorScheme.surfaceContainerLow,
          shape: StadiumBorder(side: BorderSide(color: late > 0 ? colors.timerLate : colors.timerWarn)),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: const ValueKey('attention'),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.timer_outlined, size: 16, color: theme.colorScheme.onSurfaceVariant),
                  if (late > 0) count(late, colors.timerLate, colors.timerLateText),
                  if (soon > 0) count(soon, colors.timerWarn, colors.timerWarnText),
                ],
              ),
            ),
          ),
        ),
      ),
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
    required this.clock,
    required this.ringed,
    required this.onTap,
    this.holds = const [],
    this.faded = false,
    this.moving = false,
    this.onHeld,
  });

  final TableSpot table;
  final double left, top;
  final List<TableCheck> checks;

  /// The reservations of today that hold this table, the earliest first (docs/reservations.md).
  final List<TableHold> holds;

  /// The table is being moved: it is outlined until the table it goes to is tapped.
  final bool moving;

  /// Another server's table while "Mine" is on: it stays where it is and opens on a tap, only fainter.
  final bool faded;

  /// The time as of the last second, which the minutes on the table follow.
  final ValueListenable<int> clock;

  /// The table has a countdown ring: its own border steps back to a faint track for the ring to drain over.
  final bool ringed;
  final VoidCallback onTap;

  /// The table was held down; null where holding does nothing.
  final VoidCallback? onHeld;

  static const _minSide = 34.0; // keeps counter stools big enough to tap
  static const _busyLine = 1.12; // the height of a line of text on a busy table, in font sizes

  @override
  Widget build(BuildContext context) {
    final posColors = PosColors.of(context);
    final w = math.max(table.w, _minSide), h = math.max(table.h, _minSide);
    final check = checks.firstOrNull;
    final server = shortName(check?.server);
    final (fill, border, textColor) = _stageStyle(posColors, check?.stage);
    final radius = BorderRadius.circular(table.kind == 'booth' ? 12 : 8);
    final side = moving
        ? BorderSide(color: Theme.of(context).colorScheme.primary, width: 4)
        : BorderSide(color: ringed ? border.withValues(alpha: 0.28) : border, width: check == null ? 1.5 : 2.2);
    final shape = table.round ? CircleBorder(side: side) : RoundedRectangleBorder(borderRadius: radius, side: side);

    return Positioned(
      left: table.x - w / 2 - left,
      top: table.y - h / 2 - top,
      width: w,
      height: h,
      child: _Faded(
        key: ValueKey('table-look:${table.id}'),
        faded: faded,
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
                  onLongPress: onHeld,
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
                                  // a busy table holds four lines: they stand closer so they stay as large
                                  height: check == null ? null : _busyLine,
                                ),
                              ),
                              // whose table it is: the server who opened it, or the one it was given to
                              if (server.isNotEmpty)
                                Container(
                                  key: ValueKey('table-server:${table.id}'),
                                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0.5),
                                  decoration: BoxDecoration(color: border, borderRadius: BorderRadius.circular(4)),
                                  child: Text(
                                    server,
                                    style: TextStyle(
                                      fontSize: 9.5,
                                      fontWeight: FontWeight.w800,
                                      color: fill,
                                      letterSpacing: 0.1,
                                      height: _busyLine,
                                    ),
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
                                  child: Column(
                                    children: [
                                      // minutes since the table was sat: the one word here that follows the clock
                                      _Ticking<int>(
                                        clock: clock,
                                        read: check.minutesOpen,
                                        builder: (context, minutes) => Text(
                                          '${check.guests ?? '?'}p ${minutes}m${checks.length > 1 ? ' +${checks.length - 1}' : ''}',
                                          style: TextStyle(
                                            fontSize: 9.5,
                                            fontWeight: FontWeight.w700,
                                            color: textColor,
                                            fontFeatures: PosTheme.tabular,
                                            height: _busyLine,
                                          ),
                                        ),
                                      ),
                                      // what the table has run up, as a manager reads the room
                                      if (check.total != null)
                                        Text(
                                          '\$${check.total}',
                                          style: TextStyle(
                                            fontSize: 8.5,
                                            fontWeight: FontWeight.w600,
                                            color: textColor,
                                            fontFeatures: PosTheme.tabular,
                                            height: _busyLine,
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              // booked for today: the time, and on a free table whose it is. It follows the
                              // clock only where its colour turns and where its time is long past. It is
                              // drawn smaller sooner than it makes the table's own name smaller.
                              if (holds.isNotEmpty)
                                _Ticking<_HoldLook?>(
                                  clock: clock,
                                  read: (now) => _holdLook(holds, now, seated: check != null),
                                  builder: (context, look) => look == null
                                      ? const SizedBox.shrink()
                                      : ConstrainedBox(
                                          // (a round table is narrower where the booking is written)
                                          constraints: BoxConstraints(maxWidth: (table.round ? 0.78 : 1) * w - 8),
                                          child: FittedBox(
                                            fit: BoxFit.scaleDown,
                                            child: _HoldMark(
                                              key: ValueKey('table-hold:${table.id}'),
                                              look: look,
                                              named: check == null,
                                              ink: textColor,
                                              line: border,
                                            ),
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
      ),
    );
  }
}

/// On a table booked for today: the time it is booked for, plain while that is ahead, amber when it is near
/// and red when it is past with nobody seated; "here" once the party came in and waits. With [named], whose
/// it is and how many ("Chen 4p"), which a free table has the room for. "+1" says the table is booked once
/// more after this.
class _HoldMark extends StatelessWidget {
  const _HoldMark({super.key, required this.look, required this.named, required this.ink, required this.line});

  final _HoldLook look;
  final bool named;

  /// The colour the table writes in, and the colour of its edge: what a time still ahead is drawn in.
  final Color ink, line;

  /// The most letters of a name a table has the room for.
  static const _letters = 9;

  @override
  Widget build(BuildContext context) {
    final (:hold, :level, :more) = look;
    final plain = !hold.isHere && level == TimerLevel.ok;
    final (fill, text) = plain ? (null, ink) : holdColors(context, here: hold.isHere, level: level);
    final name = hold.name.characters.length > _letters ? '${hold.name.characters.take(_letters - 1)}…' : hold.name;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          margin: const EdgeInsets.only(top: 1.5),
          padding: const EdgeInsets.symmetric(horizontal: 3.5, vertical: 0.5),
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(5),
            border: plain ? Border.all(color: line, width: 0.8) : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(bookedIcon, size: 8, color: text),
              const SizedBox(width: 1.5),
              Text(
                '${hold.isHere ? 'here' : hold.time}${more > 0 ? ' +$more' : ''}',
                semanticsLabel:
                    'booked for ${hold.time}, ${hold.label}'
                    '${hold.isHere
                        ? ', the party is here'
                        : level == TimerLevel.late
                        ? ', past its time'
                        : level == TimerLevel.warn
                        ? ', nearly its time'
                        : ''}'
                    '${more > 0 ? ', and booked $more more ${more == 1 ? 'time' : 'times'} today' : ''}',
                style: TextStyle(
                  fontSize: 8.5,
                  height: 1.1,
                  fontWeight: FontWeight.w800,
                  color: text,
                  fontFeatures: PosTheme.tabular,
                ),
              ),
            ],
          ),
        ),
        if (named)
          Text(
            '$name ${hold.size}p',
            key: ValueKey('table-hold-name:${hold.id}'),
            style: TextStyle(fontSize: 8.5, height: 1.25, fontWeight: FontWeight.w600, color: ink),
          ),
      ],
    );
  }
}

/// The mark of a table that is booked, on the map and under it.
const bookedIcon = Icons.event_rounded;

/// Another server's table, or the badge on it, while "Mine" is on: fainter, and nothing else about it changes.
/// What is not faded is drawn as it always was, with no layer of its own.
class _Faded extends StatelessWidget {
  const _Faded({super.key, required this.faded, required this.child});

  /// How much of a faded table, its ring and its badge is left to see.
  static const to = 0.45;

  final bool faded;
  final Widget child;

  @override
  Widget build(BuildContext context) => faded ? Opacity(opacity: to, child: child) : child;
}

/// Beside the map while "Mine" is on, on a screen with the room for it: the person's tables as a list, the
/// one that most needs a look first, each with its party, how long it has sat, what it waits on and what it
/// has run up. A tap opens the table and a hold hands it over, as on the map.
class _MyTables extends StatelessWidget {
  const _MyTables({
    required this.plan,
    required this.me,
    required this.tables,
    required this.clock,
    required this.onTable,
    this.onHeld,
  });

  /// The narrowest screen the list is shown on (a tablet on its side, a Mac), and the room it takes there.
  /// On anything narrower the map keeps the whole width.
  static const fitsFrom = 840.0;
  static const width = 300.0;

  final FloorPlan plan;
  final StaffMember me;
  final List<TableSpot> tables;
  final ValueListenable<int> clock;
  final void Function(TableSpot table) onTable;
  final void Function(TableSpot table)? onHeld;

  List<TableCheck> _mineAt(TableSpot table) => [
    for (final check in plan.checksAt(table.id))
      if (check.isServedBy(me)) check,
  ];

  /// The tables as they are listed at [nowMs]: out of time first, then running out, then the rest, and the
  /// one sat longest first among equals.
  List<TableSpot> _listed(int nowMs) {
    int press(TableSpot table) => switch (plan.countdownAt(table.id, nowMs)?.level) {
      TimerLevel.late => 0,
      TimerLevel.warn => 1,
      TimerLevel.ok || null => 2,
    };
    int sat(TableSpot table) => _mineAt(table).map((check) => check.openedMs ?? nowMs).fold(nowMs, math.min);
    return [...tables]..sort((a, b) {
      final byPress = press(a).compareTo(press(b));
      if (byPress != 0) return byPress;
      final bySat = sat(a).compareTo(sat(b));
      return bySat != 0 ? bySat : a.label.compareTo(b.label);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      key: const ValueKey('my-tables'),
      width: width,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        border: Border(left: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text('My tables', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                ),
                Text(
                  ServerLoad.of(plan, me).inWords,
                  style: theme.textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: scheme.outlineVariant),
          Expanded(
            child: tables.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      'No table is yours right now. Tap a free table to seat a party.',
                      style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  )
                // Listed again only when the clock moves a table up or down the list.
                : _Ticking<String>(
                    clock: clock,
                    read: (now) => _listed(now).map((table) => table.id).join(' '),
                    builder: (context, _) => ListView(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      children: [
                        for (final table in _listed(clock.value))
                          _MyTableRow(
                            key: ValueKey('my-table:${table.id}'),
                            plan: plan,
                            table: table,
                            checks: _mineAt(table),
                            clock: clock,
                            onTap: () => onTable(table),
                            onHeld: onHeld == null ? null : () => onHeld!(table),
                          ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

/// One of the person's tables in the list beside the map.
class _MyTableRow extends StatelessWidget {
  const _MyTableRow({
    super.key,
    required this.plan,
    required this.table,
    required this.checks,
    required this.clock,
    required this.onTap,
    this.onHeld,
  });

  final FloorPlan plan;
  final TableSpot table;

  /// The person's checks on the table: one, but for a table split between parties.
  final List<TableCheck> checks;
  final ValueListenable<int> clock;
  final VoidCallback onTap;
  final VoidCallback? onHeld;

  /// What the table waits on when the location times no stage: the words of the legend.
  static String _stageInWords(String stage) => switch (stage) {
    'seated' => 'Nothing sent yet',
    'waiting' => 'A course is held',
    _ => 'Everything sent',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = PosColors.of(context);
    final check = checks.first;
    final (fill, border, ink) = _stageStyle(colors, check.stage);
    final guests = checks.every((c) => c.guests == null) ? null : checks.fold<int>(0, (n, c) => n + (c.guests ?? 0));
    final party = guests == null ? '' : '$guests ${guests == 1 ? 'guest' : 'guests'} · ';
    final more = checks.length > 1 ? ' · ${checks.length} checks' : '';
    return InkWell(
      onTap: onTap,
      onLongPress: onHeld,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 44,
              height: 44,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: fill,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: border, width: 2),
              ),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                  child: Text(
                    table.label,
                    style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15, color: ink),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              // The minutes, what the table waits on and whether its food is ready follow the clock; nothing
              // else here does.
              child: _Ticking<(int, TimerLevel?, String, int)>(
                clock: clock,
                read: (now) {
                  final at = plan.countdownAt(table.id, now);
                  return (
                    checks.map((c) => c.minutesOpen(now)).fold(0, math.max),
                    at?.level,
                    at == null ? _stageInWords(check.stage) : countdownInWords(at),
                    checks.fold(0, (n, c) => n + c.readyAt(now)),
                  );
                },
                builder: (context, shown) {
                  final (minutes, level, waits, ready) = shown;
                  final (readyFill, readyInk) = readyColors(context);
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              '$party$minutes min$more',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleSmall?.copyWith(fontFeatures: PosTheme.tabular),
                            ),
                          ),
                          if (checks.length == 1 && check.total != null)
                            Text(
                              '\$${check.total}',
                              style: theme.textTheme.titleSmall?.copyWith(fontFeatures: PosTheme.tabular),
                            ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      // Food the kitchen has made for the table comes first: it is getting cold
                      if (ready > 0)
                        Container(
                          key: ValueKey('my-table-ready:${table.id}'),
                          margin: const EdgeInsets.only(top: 1, bottom: 3),
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(color: readyFill, borderRadius: BorderRadius.circular(6)),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(readyIcon, size: 14, color: readyInk),
                              const SizedBox(width: 4),
                              Text(
                                readyInWords(ready),
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: readyInk,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                      // Running out or out of time: the words wear the map's badge colours, which read on
                      // a light screen and a dark one alike.
                      if (level == TimerLevel.warn || level == TimerLevel.late)
                        Container(
                          margin: const EdgeInsets.only(top: 1),
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: level == TimerLevel.late ? colors.timerLate : colors.timerWarn,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            waits,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: level == TimerLevel.late ? colors.timerLateText : colors.timerWarnText,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        )
                      else
                        Text(
                          waits,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({this.booked = false});

  /// A table is booked for today: the legend says what the time on a table means. On a day with no
  /// reservation it keeps the room.
  final bool booked;

  /// The narrowest screen whose legend has the room for "Booked" beside the rest, in one row.
  static const _bookedFrom = 480.0;

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
          // on a phone the row is full: the calendar on a table says it by itself there
          if (booked && MediaQuery.sizeOf(context).width >= _bookedFrom)
            Padding(
              key: const ValueKey('legend-booked'),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(bookedIcon, size: 15, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 5),
                  Text('Booked', style: theme.textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
