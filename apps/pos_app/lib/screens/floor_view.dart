import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show PathMetric;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../api.dart';
import '../floor.dart';
import '../floor_layout.dart';
import '../live.dart';
import '../local_order.dart';
import '../outbox.dart';
import '../roster.dart';
import '../seated.dart';
import 'booked_table_dialog.dart' show holdColors;
import 'guest_tag_mark.dart';
import 'ready_mark.dart';
import 'compact.dart';
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

class FloorViewState extends State<FloorView> with SingleTickerProviderStateMixin {
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
  // Where the tables stand: how far the ones shown can grow (worked out once for them) and where that puts
  // them on a map of the size it has now. Both are kept until the tables or the size change.
  List<TableSpot>? _grownOf;
  String? _grownRoom;
  FloorGrowth? _growth;
  FloorLayout? _layout;
  Rect? _layoutUnder;
  // Going from the whole floor to a room and back, the tables glide from where they were to where they now
  // stand: [_from] is where they were, until they have arrived.
  late final _glide = AnimationController(vsync: this, duration: glideTime, value: 1);
  late final Animation<double> _glided = CurvedAnimation(parent: _glide, curve: Curves.easeInOutCubic);
  FloorLayout? _from;
  final _zoom = TransformationController();
  final _roomChips = <String?, GlobalKey>{};

  /// How long the tables take from the whole floor to a room and back.
  static const glideTime = Duration(milliseconds: 360);

  @override
  void initState() {
    super.initState();
    // Under an open check nobody sees the map: it stops asking, and reads again the moment it is back.
    _timer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (_inFront && _poll.due()) unawaited(_reader.now(must: false));
    });
    _live = widget.api.live.changes.listen((change) {
      // a table booked, a reservation changed or ended, somebody put in tonight's turn or taken out: the
      // tables kept for today and the turn come with the floor. So does who sits at each table: a party
      // seated from the book or the waitlist, and a tag put on a guest (which tells both)
      if (_inFront && (change.anyOrder || change.reservations || change.waitlist || change.floor)) _reader();
    });
    _second = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_inFront) _tick();
    });
    _glide.addStatusListener((status) {
      // The tables have arrived: the ones that left the screen on the way are let go.
      if (status == AnimationStatus.completed && _from != null && mounted) setState(() => _from = null);
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
    _glide.dispose();
    _zoom.dispose();
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

  /// Shows [room], or the whole floor for null: the tables glide to their new places, and the map is back
  /// at its own size if it was pinched larger.
  void _show(String? room) {
    if (room == _room) return;
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    setState(() {
      _from = still ? null : _layout;
      _room = room;
    });
    _zoom.value = Matrix4.identity();
    if (!still && _from != null) unawaited(_glide.forward(from: 0));
    // The room's own button comes into sight, for a room opened by a tap on the map.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final chip = _roomChips[room]?.currentContext;
      if (mounted && chip != null) {
        unawaited(
          Scrollable.ensureVisible(
            chip,
            alignment: 0.5,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
          ),
        );
      }
    });
  }

  /// How far the tables of [room] (of the whole floor for null) can grow: worked out when the plan's
  /// tables or the room shown change, and kept in between.
  FloorGrowth _growthFor(List<TableSpot> tables, String? room) {
    if (_growth == null || !identical(tables, _grownOf) || room != _grownRoom) {
      _growth = FloorGrowth.of(
        room == null
            ? tables
            : [
                for (final table in tables)
                  if (table.room == room) table,
              ],
      );
      _grownOf = tables;
      _grownRoom = room;
    }
    return _growth!;
  }

  /// Where [growth]'s tables stand on a map of [size]: worked out when either changes. No table stands
  /// [under] the buttons the screen floats over the map's corner: where one would, the map ends above them.
  FloorLayout _layoutFor(FloorGrowth growth, Size size, Rect? under) {
    final last = _layout;
    if (last != null && identical(last.growth, growth) && last.view == size && _layoutUnder == under) return last;
    // The whole floor keeps a line above each room for the room's name.
    final top = _room == null ? _RoomOutline.nameHigh + 10 : 16.0;
    var layout = FloorLayout.of(growth, size, top: top);
    if (under != null && layout.places.any((place) => place.bounds.overlaps(under))) {
      layout = FloorLayout.of(growth, size, top: top, bottom: under.height + 8);
    }
    _layoutUnder = under;
    return _layout = layout;
  }

  /// The corner of a map of [size] that the screen's floating buttons cover (Tab and To go on the orders
  /// screen, which stand higher on a phone, above the words under the map); null on a screen with none.
  Rect? _floated(BuildContext context, Size size) {
    if (!(Scaffold.maybeOf(context)?.hasFloatingActionButton ?? false)) return null;
    final high = compact(context) ? 82.0 : 38.0;
    if (size.height < high * 3) return null;
    return Rect.fromLTRB(math.max(0, size.width - 232), size.height - high, size.width, size.height);
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
    final growth = _growthFor(plan.tables, room?.id);
    final busy = plan.status.length;
    // "Mine": the tables with a check of the person at this screen. While it is on the other servers' busy
    // tables fade; a free table never does, since anyone may seat it.
    final me = widget.me;
    final mine = me == null ? const <String>{} : tablesOf(plan, me);
    final mineOn = widget.mine && me != null;
    bool faded(String tableId) => mineOn && !mine.contains(tableId) && plan.checksAt(tableId).isNotEmpty;
    final looked = mineOn ? mine : null; // whose tables the count of those needing a look is of
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
                // Every room's name is there, the ones off the side of the screen too: a room opened by a
                // tap on the map has its name brought into sight.
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      for (final r in [null, ...rooms])
                        Padding(
                          key: _roomChips.putIfAbsent(r?.id, GlobalKey.new),
                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                          child: ChoiceChip(
                            label: Text(r?.name ?? 'Whole floor'),
                            selected: _room == r?.id,
                            onSelected: (_) => _show(r?.id),
                          ),
                        ),
                      Padding(
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
                    ],
                  ),
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
                        transformationController: _zoom,
                        // The tables are laid out for the room the map has, in points of the screen: what is
                        // written on them is the size it says it is, on a phone as on a Mac.
                        child: LayoutBuilder(
                          // (with the list of my tables beside it, the screen's buttons float over the list)
                          builder: (context, map) => _map(
                            context,
                            plan,
                            growth,
                            map.biggest,
                            faded,
                            listed: mineOn && box.maxWidth >= _MyTables.fitsFrom,
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

  /// The map itself, on [size] points of screen: the rooms' frames (on the whole floor), the tables, their
  /// countdown rings and the badges on their edges.
  Widget _map(
    BuildContext context,
    FloorPlan plan,
    FloorGrowth growth,
    Size size,
    bool Function(String) faded, {
    bool listed = false,
  }) {
    final posColors = PosColors.of(context);
    final layout = _layoutFor(growth, size, listed ? null : _floated(context, size));
    // While the tables glide: where each was, and the ones that are on their way off the screen.
    final from = _from;
    Rect? cameFrom(TableSpot table) => from == null ? null : (from[table.id] ?? from.project(table)).box;
    final leaving = [
      if (from != null)
        for (final place in from.places)
          if (layout[place.table.id] == null) place,
    ];
    final rings = _rings = _Rings.of(plan, layout, colors: posColors, faded: faded, cameFrom: cameFrom);
    final frames = _room == null ? layout.rooms(above: _RoomOutline.nameHigh + 4) : const <String, Rect>{};
    Widget tile(TablePlace place, {bool leaves = false}) => _TableTile(
      place: place,
      checks: plan.checksAt(place.table.id),
      holds: plan.holds[place.table.id] ?? const [],
      guests: plan.guestsAt(place.table.id),
      clock: _clock,
      ringed: !leaves && rings.has(place.table.id),
      faded: faded(place.table.id),
      moving: place.table.id == widget.moving,
      onTap: () => widget.onTable(plan, place.table),
      onHeld: widget.onTableHeld == null ? null : () => widget.onTableHeld!(plan, place.table),
    );
    Rect markAt(TablePlace place, bool star) => _EdgeMark.frame(
      place,
      star: star,
      ringed: rings.has(place.table.id),
      ready: plan.checksAt(place.table.id).any((check) => check.ready > 0),
    );
    return SizedBox.fromSize(
      size: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (final r in plan.rooms)
            if (frames[r.id] case final frame?)
              Positioned.fromRect(
                key: ValueKey('room:${r.id}'),
                rect: frame,
                child: _RoomOutline(name: r.name, fadeIn: from == null ? null : _glided, onTap: () => _show(r.id)),
              ),
          // A table on its way off the screen keeps its look until it is gone, and takes no tap.
          for (final place in leaving)
            _Placed(
              key: ValueKey(place.table.id),
              glide: _glided,
              from: place.box,
              to: layout.project(place.table).box,
              size: place.box.size,
              child: IgnorePointer(child: tile(place, leaves: true)),
            ),
          for (final place in layout.places)
            _Placed(
              key: ValueKey(place.table.id),
              glide: _glided,
              from: cameFrom(place.table),
              to: place.box,
              size: place.box.size,
              child: tile(place),
            ),
          // Every table's countdown ring, in one layer of its own: a second going by repaints this and
          // nothing else, and only when a ring moved.
          if (rings.all.isNotEmpty)
            Positioned.fill(
              child: IgnorePointer(
                child: RepaintBoundary(
                  child: CustomPaint(
                    key: const ValueKey('timer-rings'),
                    painter: _RingsPainter(rings: rings, clock: _clock, look: _ringsLook, glide: _glided),
                  ),
                ),
              ),
            ),
          for (final ring in rings.all)
            _Placed(
              key: ValueKey('timer-badge-at:${ring.tableId}'),
              glide: _glided,
              from: ring.follow(_TimerBadge.frame(ring.place)),
              to: _TimerBadge.frame(ring.place),
              size: _TimerBadge.frame(ring.place).size,
              child: IgnorePointer(
                child: _Ticking<(TimerLevel, String, String)?>(
                  clock: _clock,
                  read: (now) {
                    final at = plan.countdownAt(ring.tableId, now);
                    return at == null || at.level == TimerLevel.ok ? null : (at.level, at.stage, at.short);
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
                            side: ring.place.side,
                          ),
                        ),
                ),
              ),
            ),
          // Dishes the kitchen marked made that wait to be carried: a badge on the table's lower edge (the
          // countdown's is on the upper), until they went out or have waited too long to still be there.
          for (final place in layout.places)
            if (plan.checksAt(place.table.id).any((check) => check.ready > 0))
              _Placed(
                key: ValueKey('ready-badge-at:${place.table.id}'),
                glide: _glided,
                from: _following(_ReadyBadge.frame(place), place.box, cameFrom(place.table)),
                to: _ReadyBadge.frame(place),
                size: _ReadyBadge.frame(place).size,
                child: IgnorePointer(
                  child: _Ticking<int>(
                    clock: _clock,
                    read: (now) => plan.readyAt(place.table.id, now),
                    builder: (context, count) => count == 0
                        ? const SizedBox.shrink()
                        : _Faded(
                            faded: faded(place.table.id),
                            child: _ReadyBadge(
                              key: ValueKey('ready-badge:${place.table.id}'),
                              count: count,
                              side: place.side,
                            ),
                          ),
                  ),
                ),
              ),
          // What a table too small to say it still shows on its edge: that it is wanted for a booking, and
          // that a guest at it carries a tag.
          for (final place in layout.places)
            for (final star in [false, true])
              if (star
                  ? plan.checksAt(place.table.id).isNotEmpty &&
                        plan.guestsAt(place.table.id).any((party) => party.tags.isNotEmpty)
                  : plan.holds[place.table.id]?.isNotEmpty ?? false)
                _Placed(
                  key: ValueKey('${star ? 'tagged' : 'booked'}-mark-at:${place.table.id}'),
                  glide: _glided,
                  from: _following(markAt(place, star), place.box, cameFrom(place.table)),
                  to: markAt(place, star),
                  size: markAt(place, star).size,
                  child: IgnorePointer(
                    child: _Faded(
                      faded: faded(place.table.id),
                      child: _EdgeMark(
                        place: place,
                        checks: plan.checksAt(place.table.id),
                        holds: plan.holds[place.table.id] ?? const [],
                        guests: plan.guestsAt(place.table.id),
                        clock: _clock,
                        ringed: rings.has(place.table.id),
                        star: star,
                      ),
                    ),
                  ),
                ),
        ],
      ),
    );
  }
}

/// Where a [part] of a table (a badge on its edge, its ring) is while the table is at [from] on its way to
/// [to]: as far from the table's middle and as large as the table is then, in proportion. Null with no
/// [from]: the part is where it belongs.
Rect? _following(Rect part, Rect to, Rect? from) {
  if (from == null || to.width <= 0) return null;
  final by = from.width / to.width;
  return Rect.fromCenter(
    center: from.center + (part.center - to.center) * by,
    width: part.width * by,
    height: part.height * by,
  );
}

/// A part of the map in its place: at [to], and on the way there from [from] while the tables glide. It is
/// built once, at the [size] it has when it has arrived, and only drawn smaller or larger on the way: a
/// glide lays out and repaints, and builds nothing.
class _Placed extends AnimatedWidget {
  const _Placed({
    super.key,
    required Animation<double> glide,
    required this.from,
    required this.to,
    required this.size,
    required this.child,
  }) : super(listenable: glide);

  final Rect? from;
  final Rect to;
  final Size size;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final at = (listenable as Animation<double>).value;
    final from = this.from;
    return Positioned.fromRect(
      rect: from == null || at >= 1 ? to : Rect.lerp(from, to, at)!,
      child: FittedBox(
        fit: BoxFit.fill,
        child: SizedBox.fromSize(size: size, child: child),
      ),
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
  _Ring({required this.place, required Path path, required this.calm, this.faded = false, this.cameFrom})
    : metric = path.computeMetrics().first {
    twelve = _twelve();
  }

  /// How wide the line is on a table whose shorter side is [side] points: a little wider as the countdown
  /// runs out and when it is over, and in proportion to the table within bounds, so that it reads on a
  /// seat at the bar and is not a band on a large round.
  static double width(TimerLevel level, double side) => _widths[level]! * (side / 64).clamp(0.62, 1.3);
  static const _widths = {TimerLevel.ok: 3.4, TimerLevel.warn: 4.2, TimerLevel.late: 4.6};

  /// How far inside the table's edge the middle of the line runs, and how far in the line reaches at its
  /// widest: what is written on the table keeps clear of that. On a table of some size the line runs just
  /// inside the edge; the smaller the table the further out, until on the smallest it runs on the edge
  /// itself and leaves the table's name the room it needs.
  static double inset(double side) => (width(TimerLevel.late, side) / 2 + 0.6) * ((side - 28) / 16).clamp(0.0, 1.0);
  static double reach(double side) => inset(side) + width(TimerLevel.late, side) / 2;

  /// The table it runs round, where the map has it.
  final TablePlace place;

  String get tableId => place.table.id;
  Offset get center => place.center;
  final PathMetric metric;

  /// How far along the line twelve o'clock is: the point straight above the table's middle on the screen,
  /// however the table is turned. Every countdown is read from there.
  late final double twelve;

  /// The ring's colour while nothing is pressing: the table's own border colour.
  final Color calm;

  /// Another server's table while "Mine" is on: its ring and badge are as faint as the table.
  final bool faded;

  /// Where the table was, while the tables glide to new places: the ring and the badge go with it.
  final Rect? cameFrom;

  /// Where a [part] on the table's edge is while the table is still where it [cameFrom].
  Rect? follow(Rect part) => _following(part, place.box, cameFrom);

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

  static _Ring of(TablePlace place, Color calm, {bool faded = false, Rect? cameFrom}) {
    final inset = _Ring.inset(place.side);
    final box = Rect.fromCenter(center: Offset.zero, width: place.w, height: place.h).deflate(inset);
    final path = Path();
    if (place.table.round) {
      // Two halves, so the line starts at the top whatever a full turn in one piece would start at.
      final circle = Rect.fromCircle(center: Offset.zero, radius: box.shortestSide / 2);
      path
        ..arcTo(circle, -math.pi / 2, math.pi, true)
        ..arcTo(circle, math.pi / 2, math.pi, false);
    } else {
      final r = Radius.circular(math.max(place.corner - inset, 0));
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
    final placed = Matrix4.translationValues(place.center.dx, place.center.dy, 0)..rotateZ(place.turn);
    return _Ring(place: place, path: path.transform(placed.storage), calm: calm, faded: faded, cameFrom: cameFrom);
  }
}

/// The rings of the tables on the map, with the plan their countdowns are read from.
class _Rings {
  const _Rings(this.plan, this.all, this.colors);

  /// A ring for each table of [layout] that has a check waiting on a stage the location times.
  factory _Rings.of(
    FloorPlan plan,
    FloorLayout layout, {
    required PosColors colors,
    bool Function(String tableId)? faded,
    Rect? Function(TableSpot table)? cameFrom,
  }) => _Rings(plan, [
    for (final place in layout.places)
      // Whether a table has a countdown does not depend on the time, only where it stands does.
      if (plan.countdownAt(place.table.id, 0) != null)
        _Ring.of(
          place,
          _stageStyle(colors, plan.checksAt(place.table.id).firstOrNull?.stage).$2,
          faded: faded?.call(place.table.id) ?? false,
          cameFrom: cameFrom?.call(place.table),
        ),
  ], colors);

  final FloorPlan plan;
  final List<_Ring> all;
  final PosColors colors;

  bool has(String tableId) => all.any((ring) => ring.tableId == tableId);

  /// A number that is the same for as long as the rings would be painted the same: each ring's level, how
  /// much of it is left to the nearest point of its length, and for one that is out of time which half of
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
  _RingsPainter({required this.rings, required this.clock, required Listenable look, required this.glide})
    : super(repaint: Listenable.merge([look, glide]));

  final _Rings rings;
  final ValueListenable<int> clock;

  /// How far the tables are on their way to new places: each ring is drawn where its table is.
  final Animation<double> glide;

  @override
  void paint(Canvas canvas, Size size) {
    final now = clock.value;
    final colors = rings.colors;
    final paint = Paint()..style = PaintingStyle.stroke;
    final onTheWay = glide.value < 1;
    for (final ring in rings.all) {
      final at = rings.plan.countdownAt(ring.tableId, now);
      if (at == null) continue;
      final from = onTheWay ? ring.cameFrom : null;
      if (from != null) {
        final to = ring.place.box, here = Rect.lerp(from, to, glide.value)!;
        canvas
          ..save()
          ..translate(here.center.dx, here.center.dy)
          ..scale(to.width <= 0 ? 1 : here.width / to.width)
          ..translate(-to.center.dx, -to.center.dy);
      }
      paint.strokeWidth = _Ring.width(at.level, ring.place.side);
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
      if (from != null) canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_RingsPainter old) => old.rings != rings || old.clock != clock;
}

/// The badge on a table whose countdown is running out or over: what it waits on, and the minutes left
/// ("3m") or over ("+2m"). On a table too small for both it is the minutes alone.
class _TimerBadge extends StatelessWidget {
  const _TimerBadge({super.key, required this.level, required this.stage, required this.text, required this.side});

  final TimerLevel level;
  final String stage;
  final String text;

  /// The shorter side of the table it is on, in points: what its own size goes by.
  final double side;

  static double _type(double side) => (side * 0.17).clamp(9.5, 12.0);
  static bool _brief(double side) => side < 40;

  /// The room a badge is given on the map: on the table's edge straight above its middle. A table turned
  /// on its corner wears it a little inside its point, clear of the table above.
  static Rect frame(TablePlace place) {
    final type = _type(place.side), high = type * 1.8;
    return Rect.fromCenter(
      center: place.center.translate(
        0,
        (place.turned ? high * (_brief(place.side) ? 0.12 : 0.3) : -high * 0.14) - place.above,
      ),
      width: type * (_brief(place.side) ? 3.8 : 5.6),
      height: high,
    );
  }

  /// How far down from the table's uppermost point the badge reaches: what is written on the table
  /// starts below that.
  static double covers(TablePlace place) =>
      frame(place).center.dy + _type(place.side) * 0.72 - (place.center.dy - place.above);

  @override
  Widget build(BuildContext context) {
    final colors = PosColors.of(context);
    final late = level == TimerLevel.late;
    final ink = late ? colors.timerLateText : colors.timerWarnText;
    final type = _type(side);
    return Center(
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: type * 0.45, vertical: type * 0.12),
          decoration: BoxDecoration(
            color: late ? colors.timerLate : colors.timerWarn,
            borderRadius: BorderRadius.circular(type),
            boxShadow: [
              BoxShadow(color: Colors.black.withValues(alpha: 0.2), blurRadius: 3, offset: const Offset(0, 1)),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!_brief(side)) ...[Icon(stageIcon(stage), size: type, color: ink), SizedBox(width: type * 0.2)],
              Text(
                text,
                textScaler: TextScaler.noScaling,
                style: TextStyle(
                  fontSize: type,
                  height: 1.15,
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

/// The badge on a table with dishes the kitchen marked made that have not gone out: "2 ready". It stands on
/// the table's lower edge, so a table can wear it and its countdown's badge at once. On a table too small
/// for the word it is the mark and the count.
class _ReadyBadge extends StatelessWidget {
  const _ReadyBadge({super.key, required this.count, required this.side});

  final int count;

  /// The shorter side of the table it is on, in points: what its own size goes by.
  final double side;

  static double _type(double side) => (side * 0.17).clamp(9.5, 12.0);
  static bool _brief(double side) => side < 48;

  /// The room a badge is given on the map: on the table's edge straight below its middle.
  static Rect frame(TablePlace place) {
    final type = _type(place.side), high = type * 1.8;
    return Rect.fromCenter(
      center: place.center.translate(0, place.above - (place.turned ? high * 0.3 : -high * 0.14)),
      width: type * (_brief(place.side) ? 3.6 : 6.4),
      height: high,
    );
  }

  /// How far up from the table's lowest point the badge reaches: what is written on the table ends
  /// above that.
  static double covers(TablePlace place) =>
      place.center.dy + place.above - (frame(place).center.dy - _type(place.side) * 0.72);

  @override
  Widget build(BuildContext context) {
    final (fill, ink) = readyColors(context);
    final type = _type(side);
    return Center(
      // (a count of two figures, or a wider typeface, is drawn smaller sooner than cut off)
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: type * 0.45, vertical: type * 0.12),
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(type),
            boxShadow: [
              BoxShadow(color: Colors.black.withValues(alpha: 0.2), blurRadius: 3, offset: const Offset(0, 1)),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(readyIcon, size: type, color: ink),
              SizedBox(width: type * 0.2),
              Text(
                _brief(side) ? '$count' : '$count ready',
                semanticsLabel: readyInWords(count),
                textScaler: TextScaler.noScaling,
                style: TextStyle(
                  fontSize: type,
                  height: 1.15,
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

/// What a table too small to say it still shows: that it is wanted for a booking (the mark of one, in the
/// colour its time would have) and that a guest at it carries a tag (a star). A small mark on the table's
/// edge, in the layer of the badges: at the upper corners of a table with no countdown; under a countdown,
/// whose badge stands between those, at the lower corners, and beside the table's middle when dishes wait
/// there as well. Nothing on a table that says the same in words or beside its name.
class _EdgeMark extends StatelessWidget {
  const _EdgeMark({
    required this.place,
    required this.checks,
    required this.holds,
    required this.guests,
    required this.clock,
    required this.ringed,
    required this.star,
  });

  final TablePlace place;
  final List<TableCheck> checks;
  final List<TableHold> holds;
  final List<SeatedParty> guests;
  final ValueListenable<int> clock;
  final bool ringed;

  /// The star of a tagged guest, on the table's right; otherwise the mark of a booking, on its left.
  final bool star;

  static double _type(double side) => (side * 0.31).clamp(8.0, 10.0);

  /// The room the mark is given on the map: at the corner of an upright table, a little inside it; on the
  /// edge of a round table and of one turned on its corner a little outside, in the corner of the table's
  /// frame that the table leaves empty, clear of its name.
  static Rect frame(TablePlace place, {required bool star, required bool ringed, required bool ready}) {
    final type = _type(place.side);
    final (across, down) = place.reach;
    final left = !ringed
        ? Offset(-across, -down)
        : !ready
        ? Offset(-across, down)
        : const Offset(-1, 0);
    final way = star ? Offset(-left.dx, left.dy) : left;
    final inside = place.table.round
        ? -type * 0.15
        : place.turned
        ? -type * 0.3
        : type * 0.3 + place.corner * 0.29;
    return Rect.fromCenter(
      center: place.center + place.edgeToward(way) - way / way.distance * inside,
      width: type * 2,
      height: type * 1.6,
    );
  }

  @override
  Widget build(BuildContext context) {
    final check = checks.firstOrNull;
    return _Ticking<_HoldLook?>(
      // (as the words on the table: it follows the clock only where a booking's colour turns)
      clock: clock,
      read: (now) => holds.isEmpty ? null : _holdLook(holds, now, seated: check != null),
      builder: (context, look) {
        final colors = PosColors.of(context);
        final (holdLeft, starLeft) = _TableWords(
          place: place,
          checks: checks,
          holds: look == null ? const [] : holds,
          guests: guests,
          clock: clock,
          ringed: ringed,
        ).left(colors, _TableWords.larger(context));
        if (!(star ? starLeft : holdLeft)) return const SizedBox.shrink();
        final (fill, border, ink) = _stageStyle(colors, check?.stage);
        final type = _type(place.side);
        return Center(
          child: star
              ? Container(
                  width: type * 1.36,
                  height: type * 1.36,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: border,
                    shape: BoxShape.circle,
                    border: Border.all(color: fill, width: 1),
                  ),
                  child: Icon(
                    taggedIcon,
                    key: ValueKey('table-guest-tagged:${place.table.id}'),
                    size: type,
                    color: fill,
                    semanticLabel: 'seated here: ${guestsInWords(guests)}',
                  ),
                )
              : _HoldMark(
                  key: ValueKey('table-hold:${place.table.id}'),
                  look: look!,
                  named: false,
                  brief: true,
                  ink: ink,
                  line: border,
                  size: type,
                  backing: fill,
                ),
        );
      },
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

/// A room on the whole floor: a frame round its tables with its name in the corner. A tap on it, anywhere
/// that is not a table, shows the room by itself.
class _RoomOutline extends StatelessWidget {
  const _RoomOutline({required this.name, required this.onTap, this.fadeIn});

  final String name;
  final VoidCallback onTap;

  /// While the tables glide to their places on the whole floor, the frames come up with them.
  final Animation<double>? fadeIn;

  /// The room a frame keeps above its tables for the room's name.
  static const nameHigh = 22.0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final posColors = PosColors.of(context);
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(16),
      side: BorderSide(color: posColors.roomBorder, width: 1.4),
    );
    final frame = Semantics(
      button: true,
      label: 'Show $name by itself',
      child: Material(
        color: posColors.roomFill,
        shape: shape,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Align(
            alignment: Alignment.topLeft,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(11, 6, 11, 0),
              child: ExcludeSemantics(
                child: Text(
                  name.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.fade,
                  softWrap: false,
                  textScaler: TextScaler.noScaling,
                  style: TextStyle(
                    fontSize: 10.5,
                    height: 1.2,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.9,
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.82),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final fadeIn = this.fadeIn;
    return fadeIn == null ? frame : FadeTransition(opacity: fadeIn, child: frame);
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

/// A table on the map, at the size the layout gave it: its shape in the colour of its stage, and on it as
/// much of what there is to say as can be written at a size that reads ([_TableWords]).
class _TableTile extends StatelessWidget {
  const _TableTile({
    required this.place,
    required this.checks,
    required this.clock,
    required this.ringed,
    required this.onTap,
    this.holds = const [],
    this.guests = const [],
    this.faded = false,
    this.moving = false,
    this.onHeld,
  });

  /// Where the map has the table, and how large.
  final TablePlace place;
  final List<TableCheck> checks;

  /// The parties the host seated at this table, from a reservation or the waitlist, the first to sit first
  /// (docs/guest-list.md, "On the floor map"). None at a walk-in's table.
  final List<SeatedParty> guests;

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

  /// How wide a table's own edge is drawn: wider on a busy table, and in proportion to it within bounds.
  static double edge(double side, {required bool busy}) => (busy ? 2.2 : 1.4) * (side / 64).clamp(0.8, 1.25);

  @override
  Widget build(BuildContext context) {
    final posColors = PosColors.of(context);
    final table = place.table;
    final check = checks.firstOrNull;
    final (fill, border, textColor) = _stageStyle(posColors, check?.stage);
    final radius = BorderRadius.circular(place.corner);
    final side = moving
        ? BorderSide(color: Theme.of(context).colorScheme.primary, width: 4)
        : BorderSide(
            color: ringed ? border.withValues(alpha: 0.28) : border,
            width: edge(place.side, busy: check != null),
          );
    final shape = table.round ? CircleBorder(side: side) : RoundedRectangleBorder(borderRadius: radius, side: side);
    return _Faded(
      key: ValueKey('table-look:${table.id}'),
      faded: faded,
      child: Transform.rotate(
        angle: place.turn,
        child: PressableScale(
          pressedScale: 0.94,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
            decoration: ShapeDecoration(
              color: fill,
              shape: shape,
              shadows: [
                BoxShadow(
                  color: check == null ? Colors.black.withValues(alpha: 0.05) : border.withValues(alpha: 0.24),
                  blurRadius: check == null ? 5 : 12,
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
                // The words stand upright however the table is turned, and may be wider than the frame of
                // a table turned on its corner, which is widest across its middle.
                child: Transform.rotate(
                  angle: -place.turn,
                  child: OverflowBox(
                    minWidth: 0,
                    minHeight: 0,
                    maxWidth: double.infinity,
                    maxHeight: double.infinity,
                    // a booked table says so only once it is wanted, which the clock decides
                    child: holds.isEmpty
                        ? _words(false)
                        : _Ticking<bool>(
                            clock: clock,
                            read: (now) => _holdLook(holds, now, seated: check != null) != null,
                            builder: (context, booked) => _words(booked),
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

  Widget _words(bool booked) => _TableWords(
    place: place,
    checks: checks,
    holds: booked ? holds : const [],
    guests: guests,
    clock: clock,
    ringed: ringed,
  );
}

/// One thing a table says of itself: a line of words, or two for a booking with its party's name.
class _Part {
  const _Part(this.rank, this.high, this.wide, this.child, {this.lesser});

  /// How soon it is left out when the table has not the room for everything: the highest first. The
  /// table's own name is never left out.
  final int rank;

  /// The room it takes: its height, and the width it is written at when nothing presses.
  final double high, wide;
  final Widget child;

  /// What takes its place before it is left out altogether: the minutes without the party's size, a
  /// booking's time without its name.
  final _Part? lesser;
}

/// What a table says ([_TableWords]): each line with the room it has where it stands, how far down from the
/// table's middle the lines stand together, and what found no room on the table at all.
typedef _Wording = ({List<(_Part, double)> said, double down, bool holdLeft, bool starLeft});

/// What is written on a table, upright and centred on it: its name, and of a busy table whose it is, who
/// sits there, how many and for how long, what it has run up, and the booking it is wanted for next.
///
/// Every line is written at a size that reads, in points of the screen, a little larger on a larger table
/// and never smaller than the smallest type the map uses. A table that has not the room for every line says
/// less, not the same in smaller letters: what matters least at a glance is left out first (the total, then
/// the guest's name, the booking, the server, and last the party and its minutes), and a tap on the table
/// tells the rest. The table's shape decides the room: a round table and one turned on its corner are
/// widest across the middle, so their lines are fitted to where each one stands.
class _TableWords extends StatelessWidget {
  const _TableWords({
    required this.place,
    required this.checks,
    required this.holds,
    required this.guests,
    required this.clock,
    this.ringed = false,
  });

  final TablePlace place;
  final List<TableCheck> checks;

  /// The table has a countdown ring, and with it a badge on its upper edge when the time runs out: the
  /// words keep clear of where that stands.
  final bool ringed;

  /// Dishes wait to be carried to the table, which a badge on its lower edge says.
  bool get ready => checks.any((check) => check.ready > 0);

  /// The table's reservations when one of them is to be shown now; none otherwise.
  final List<TableHold> holds;
  final List<SeatedParty> guests;
  final ValueListenable<int> clock;

  /// The size of the table's name and of its other words on a table whose shorter side is [side] points.
  static double nameSize(double side) => (side * 0.25).clamp(12.0, 22.0);
  static double wordSize(double side) => (side * 0.158).clamp(10.5, 13.5);

  /// How wide [text] is written at [size], near enough to tell what fits: by the letter, so the answer is
  /// the same on every device and takes no measuring.
  static double _wide(String text, double size, [double perLetter = 0.58]) => text.characters.length * size * perLetter;

  /// How much smaller than written a line may be drawn to fit before it is left out instead.
  static const _squeezed = 0.92;

  /// The room across the table for a line that stands from [top] down [high] points, measured from the
  /// table's middle: the width of the table where the letters are, which leave some of a line's height
  /// empty above and below them.
  double _room(double top, double high, double inset) =>
      place.roomAt(top + high * 0.16, top + high * 0.9, inset: inset);

  /// How much larger than written the reader has type set: it counts, as far as a table can give it.
  static double larger(BuildContext context) => (MediaQuery.textScalerOf(context).scale(100) / 100).clamp(1.0, 1.3);

  @override
  Widget build(BuildContext context) {
    final wording = _wording(PosColors.of(context), larger(context));
    return MediaQuery.withNoTextScaling(
      child: Transform.translate(
        offset: Offset(0, wording.down),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (part, room) in wording.said)
              SizedBox(
                // (a table too small even for its name has it drawn as small as it takes)
                width: math.max(room, 6),
                height: part.high,
                child: FittedBox(fit: BoxFit.scaleDown, child: part.child),
              ),
          ],
        ),
      ),
    );
  }

  /// Whether the table is wanted for a booking, and whether a guest at it carries a tag, with no room to
  /// say so: not in a line of its own and not beside the table's name. The map then puts a small mark on
  /// the table's edge ([_EdgeMark]), so that neither is ever missing from it.
  (bool, bool) left(PosColors colors, double larger) {
    final wording = _wording(colors, larger);
    return (wording.holdLeft, wording.starLeft);
  }

  /// What the table says in the type of a reader who has it [larger]: each line with the room it has where
  /// it stands, how far down from the table's middle they stand together, and what found no room.
  _Wording _wording(PosColors colors, double larger) {
    final table = place.table;
    final check = checks.firstOrNull;
    final (fill, border, ink) = _stageStyle(colors, check?.stage);
    final name = nameSize(place.side) * larger, word = wordSize(place.side) * larger;
    final inset = check == null ? _TableTile.edge(place.side, busy: false) + 2 : _Ring.reach(place.side) + 1.5;
    final server = shortName(check?.server);
    final tagged = guests.any((party) => party.tags.isNotEmpty);
    final more = checks.length > 1 ? ' +${checks.length - 1}' : '';
    final look = holds.isEmpty ? null : _holdLook(holds, clock.value, seated: check != null);

    TextStyle words(FontWeight weight, {Color? color, double? size}) => TextStyle(
      fontSize: size ?? word,
      height: 1.2,
      fontWeight: weight,
      color: color ?? ink,
      fontFeatures: PosTheme.tabular,
    );

    // A booking, as much of it as there is room for: the time with whose it is, the time, the mark alone.
    Widget holdMark({required bool named, bool brief = false, double? size}) => _Ticking<_HoldLook?>(
      // It follows the clock only where its colour turns and where its time is long past.
      clock: clock,
      read: (now) => _holdLook(holds, now, seated: check != null),
      builder: (context, look) => look == null
          ? const SizedBox.shrink()
          : _HoldMark(
              key: ValueKey('table-hold:${table.id}'),
              look: look,
              named: named,
              brief: brief,
              ink: ink,
              line: border,
              size: size ?? word * 0.92,
            ),
    );
    _Part booking({required bool named, bool brief = false}) => _Part(
      3,
      word * (named ? 2.62 : 1.5),
      brief
          ? word * 1.7
          : math.max(
              _wide(
                    '${look!.hold.isHere ? 'here' : look.hold.time}${look.more > 0 ? ' +${look.more}' : ''}',
                    word * 0.92,
                  ) +
                  word * 1.9,
              named ? _wide('${_HoldMark.short(look.hold.name)} ${look.hold.size}p', word * 0.95, 0.6) : 0,
            ),
      holdMark(named: named, brief: brief),
      lesser: named
          ? booking(named: false)
          : brief
          ? null
          : booking(named: false, brief: true),
    );
    // Who sits here, by as many letters of the name as there is room for.
    _Part guest(int letters) => _Part(
      4,
      word * 1.3,
      _wide(_GuestMark.words(guests, letters), word * 0.95, 0.6) + (tagged ? word * 1.25 : 0),
      _GuestMark(
        key: ValueKey('table-guest:${table.id}'),
        tableId: table.id,
        guests: guests,
        letters: letters,
        ink: ink,
        size: word * 0.95,
      ),
      lesser: letters > 5 ? guest(letters - 2) : null,
    );

    // Everything the table could say under its name, from the top down.
    final parts = <_Part>[
      // whose table it is: the server who opened it, or the one it was given to
      if (server.isNotEmpty)
        _Part(
          2,
          word * 1.42,
          _wide(server, word * 0.95) + word * 0.9,
          Container(
            key: ValueKey('table-server:${table.id}'),
            padding: EdgeInsets.symmetric(horizontal: word * 0.45, vertical: word * 0.04),
            decoration: BoxDecoration(color: border, borderRadius: BorderRadius.circular(word * 0.5)),
            child: Text(
              server,
              style: words(FontWeight.w800, color: fill, size: word * 0.95).copyWith(letterSpacing: 0.1),
            ),
          ),
        ),
      // who sits here: the party the host seated, by its name, with a star when a guest of it carries a
      // tag. It stands in the middle of the table, where a round table and one turned on its corner are
      // widest.
      if (check != null && guests.isNotEmpty) guest(_GuestMark.most),
      // how many, and the minutes since the table was sat: the one word here that follows the clock
      if (check != null)
        _Part(
          1,
          word * 1.3,
          _wide('${check.guests ?? '?'}p 88m$more', word),
          _Ticking<int>(
            clock: clock,
            read: check.minutesOpen,
            builder: (context, minutes) =>
                Text('${check.guests ?? '?'}p ${minutes}m$more', style: words(FontWeight.w700)),
          ),
          lesser: _Part(
            1,
            word * 1.3,
            _wide('88m', word),
            _Ticking<int>(
              clock: clock,
              read: check.minutesOpen,
              builder: (context, minutes) => Text(
                '${minutes}m',
                semanticsLabel: '${check.guests ?? '?'}p ${minutes}m$more',
                style: words(FontWeight.w700),
              ),
            ),
          ),
        ),
      // what the table has run up, as a manager reads the room
      if (check?.total case final total?)
        _Part(
          5,
          word * 1.26,
          _wide('\$$total', word * 0.95),
          Text(
            '\$$total',
            style: words(FontWeight.w600, color: ink.withValues(alpha: 0.86), size: word * 0.95),
          ),
        ),
      // booked for today: the time, and on a free table whose it is
      if (look != null) booking(named: check == null),
    ];

    final nameHigh = name * 1.14, nameWide = _wide(table.label, name, 0.64);
    var (shown, down) = _fitted(parts, nameHigh, nameWide, inset);
    final high = shown.fold(nameHigh, (high, part) => high + part.high);
    // What had to go keeps its mark beside the table's name, where the table is wide enough for it: the
    // mark of a booking the table is wanted for, and the star of a guest who carries a tag.
    final holdGone = look != null && !shown.any((part) => part.rank == 3);
    final starGone = tagged && check != null && !shown.any((part) => part.rank == 4);
    final holdWide = name * 0.95, starWide = name * 0.9;
    var holdOnName = false, starOnName = false;
    for (final (hold, star) in [(holdGone, starGone), (holdGone, false), (false, starGone)]) {
      if (!hold && !star) continue;
      final wide = nameWide + (hold ? holdWide : 0) + (star ? starWide : 0);
      if (_stands(shown, nameHigh, wide, inset) case final at?) {
        (holdOnName, starOnName, down) = (hold, star, at);
        break;
      }
    }
    final said = <(_Part, double)>[]; // each part with the width it has where it stands
    final stack = [
      _Part(
        0,
        nameHigh,
        nameWide + (starOnName ? starWide : 0) + (holdOnName ? holdWide : 0),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (starOnName) ...[
              Icon(
                taggedIcon,
                key: ValueKey('table-guest-tagged:${table.id}'),
                size: name * 0.82,
                color: ink,
                semanticLabel: 'seated here: ${guestsInWords(guests)}',
              ),
              SizedBox(width: name * 0.08),
            ],
            Text(
              table.label,
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: name,
                color: ink,
                letterSpacing: -0.2,
                height: 1.14,
              ),
            ),
            if (holdOnName) ...[SizedBox(width: name * 0.14), holdMark(named: false, brief: true, size: name * 0.62)],
          ],
        ),
      ),
      ...shown,
    ];
    var y = down - high / 2;
    for (final part in stack) {
      said.add((part, _room(y, part.high, inset)));
      y += part.high;
    }
    return (said: said, down: down, holdLeft: holdGone && !holdOnName, starLeft: starGone && !starOnName);
  }

  /// The most of [parts] that fits on the table under its name ([nameHigh] high, [nameWide] wide), in
  /// their order, and how far down from the table's middle they stand to fit. A line too wide for the
  /// table even with nothing else under the name is said in fewer words, or not at all. Then, while a
  /// line would stand outside the table or be squeezed past reading, the part that matters least gives
  /// way to its lesser form, and is left out when it has none.
  (List<_Part>, double) _fitted(List<_Part> parts, double nameHigh, double nameWide, double inset) {
    var shown = <_Part>[];
    for (final part in parts) {
      _Part? said = part;
      while (said != null && (said.high <= 0 || _stands([said], nameHigh, nameWide, inset) == null)) {
        said = said.lesser;
      }
      if (said != null) shown.add(said);
    }
    while (shown.isNotEmpty) {
      if (_stands(shown, nameHigh, nameWide, inset) case final down?) return (shown, down);
      // the last of the least important
      var least = 0;
      for (var i = 1; i < shown.length; i++) {
        if (shown[i].rank >= shown[least].rank) least = i;
      }
      final lesser = shown[least].lesser;
      shown = [
        for (var i = 0; i < shown.length; i++)
          if (i != least) shown[i] else ?lesser,
      ];
    }
    return (shown, 0);
  }

  /// Where the name and [shown] under it stand so that every line has the room it needs: how far down
  /// from the table's middle, and null when nowhere on the table. In the middle where that will do. A
  /// round table and one turned on its corner are widest across the middle, so on those the lines move
  /// up or down until the widest of them stands where the table is wide enough. No line stands under a
  /// badge on the table's edge.
  double? _stands(List<_Part> shown, double nameHigh, double nameWide, double inset) {
    final high = shown.fold(nameHigh, (high, part) => high + part.high);
    final last = shown.isEmpty ? nameHigh : shown.last.high;
    final from = ringed ? _TimerBadge.covers(place) - place.above : double.negativeInfinity;
    final to = ready ? place.above - _ReadyBadge.covers(place) : double.infinity;
    bool at(double down) {
      var y = down - high / 2;
      if (y + nameHigh * 0.16 < from || y + high - last * 0.1 > to) return false;
      if (_room(y, nameHigh, inset) < nameWide * _squeezed) return false;
      y += nameHigh;
      for (final part in shown) {
        if (_room(y, part.high, inset) < part.wide * _squeezed) return false;
        y += part.high;
      }
      return true;
    }

    if (at(0)) return 0;
    final most = math.min(place.side * 0.24, place.reach.$2 - high / 2);
    for (var by = 0.75; by <= most; by += 0.75) {
      if (at(-by)) return -by;
      if (at(by)) return by;
    }
    return null;
  }
}

/// On a table booked for today: the time it is booked for, plain while that is ahead, amber when it is near
/// and red when it is past with nobody seated; "here" once the party came in and waits. With [named], whose
/// it is and how many ("Chen 4p"), which a free table has the room for. "+1" says the table is booked once
/// more after this.
class _HoldMark extends StatelessWidget {
  const _HoldMark({
    super.key,
    required this.look,
    required this.named,
    required this.ink,
    required this.line,
    required this.size,
    this.brief = false,
    this.backing,
  });

  final _HoldLook look;
  final bool named;

  /// What is behind a mark that has no colour of its own, where it stands on a table's edge and not on
  /// the table.
  final Color? backing;

  /// On a table with no room for the time: the mark alone, in the colour the time would have.
  final bool brief;

  /// The colour the table writes in, and the colour of its edge: what a time still ahead is drawn in.
  final Color ink, line;

  /// The size of its words, in points.
  final double size;

  /// The most letters of a name a table has the room for.
  static const _letters = 9;

  /// A party's name as a table has the room for it.
  static String short(String name) =>
      name.characters.length > _letters ? '${name.characters.take(_letters - 1)}…' : name;

  @override
  Widget build(BuildContext context) {
    final (:hold, :level, :more) = look;
    final plain = !hold.isHere && level == TimerLevel.ok;
    final (fill, text) = plain ? (null, ink) : holdColors(context, here: hold.isHere, level: level);
    final inWords =
        'booked for ${hold.time}, ${hold.label}'
        '${hold.isHere
            ? ', the party is here'
            : level == TimerLevel.late
            ? ', past its time'
            : level == TimerLevel.warn
            ? ', nearly its time'
            : ''}'
        '${more > 0 ? ', and booked $more more ${more == 1 ? 'time' : 'times'} today' : ''}';
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: EdgeInsets.symmetric(
            horizontal: size * (brief ? 0.3 : 0.42),
            vertical: size * (brief ? 0.14 : 0.06),
          ),
          decoration: BoxDecoration(
            color: fill ?? backing,
            borderRadius: BorderRadius.circular(size * 0.6),
            border: plain ? Border.all(color: line, width: 0.9) : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(bookedIcon, size: size * 0.98, color: text, semanticLabel: brief ? inWords : null),
              if (!brief) ...[
                SizedBox(width: size * 0.18),
                Text(
                  '${hold.isHere ? 'here' : hold.time}${more > 0 ? ' +$more' : ''}',
                  semanticsLabel: inWords,
                  style: TextStyle(
                    fontSize: size,
                    height: 1.15,
                    fontWeight: FontWeight.w800,
                    color: text,
                    fontFeatures: PosTheme.tabular,
                  ),
                ),
              ],
            ],
          ),
        ),
        if (named)
          Text(
            '${short(hold.name)} ${hold.size}p',
            key: ValueKey('table-hold-name:${hold.id}'),
            style: TextStyle(fontSize: size * 1.03, height: 1.22, fontWeight: FontWeight.w600, color: ink),
          ),
      ],
    );
  }
}

/// The mark of a table that is booked, on the map and under it.
const bookedIcon = Icons.event_rounded;

/// The mark of a table where a guest sits who carries a tag in the guest list ("VIP").
const taggedIcon = Icons.star_rounded;

/// Who sits at a table, in words: "Linda P., tagged Catering client, VIP; Omar".
String guestsInWords(List<SeatedParty> guests) => [
  for (final party in guests)
    [if (party.name.isNotEmpty) party.name, if (party.tags.isNotEmpty) 'tagged ${party.tags.join(', ')}'].join(', '),
].join('; ');

/// On a table the host seated a party at, from its reservation or the waitlist: whose table it is, by the
/// party's name ("Chen"), with a star before it when a guest seated there carries a tag in the guest list.
/// "+1" says another party sits there too. The check itself says the rest: the tags by name and the note.
class _GuestMark extends StatelessWidget {
  const _GuestMark({
    super.key,
    required this.tableId,
    required this.guests,
    required this.ink,
    required this.size,
    this.letters = _GuestMark.most,
  });

  final String tableId;
  final List<SeatedParty> guests;

  /// How many letters of the party's name it writes at most: fewer on a table with less room.
  final int letters;

  /// The colour the table writes in.
  final Color ink;

  /// The size of its words, in points.
  final double size;

  /// The most letters of a name a table has the room for.
  static const most = 9;

  /// What it writes: the first party's name in [letters] letters at most, and how many more sit there.
  static String words(List<SeatedParty> guests, [int letters = most]) {
    final first = guests.firstWhere((party) => party.name.isNotEmpty, orElse: () => guests.first).name;
    final name = first.characters.length > letters ? '${first.characters.take(letters - 1)}…' : first;
    final more = guests.length - 1;
    return [if (name.isNotEmpty) name, if (more > 0) '+$more'].join(' ');
  }

  @override
  Widget build(BuildContext context) {
    final said = words(guests, letters);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (guests.any((party) => party.tags.isNotEmpty)) ...[
          Icon(taggedIcon, key: ValueKey('table-guest-tagged:$tableId'), size: size * 1.18, color: ink),
          if (said.isNotEmpty) SizedBox(width: size * 0.12),
        ],
        Text(
          said,
          semanticsLabel: 'seated here: ${guestsInWords(guests)}',
          style: TextStyle(fontSize: size, height: 1.22, fontWeight: FontWeight.w700, color: ink),
        ),
      ],
    );
  }
}

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
    final seated = plan.guestsOf(checks); // whose table it is, when the host seated them from the book or the list
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
                      // whose table it is, with the tags they carry: the list has the room the map has not
                      if (seated.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 2),
                          child: Wrap(
                            key: ValueKey('my-table-guests:${table.id}'),
                            spacing: 6,
                            runSpacing: 2,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              for (final guest in seated) ...[
                                if (guest.name.isNotEmpty)
                                  Text(
                                    guest.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: scheme.onSurface,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                for (final tag in guest.tags) GuestTagMark(tag),
                              ],
                            ],
                          ),
                        ),
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
