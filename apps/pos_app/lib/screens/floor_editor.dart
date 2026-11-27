import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api.dart';
import '../floor.dart';
import '../floor_edit.dart';
import 'save_bar.dart';
import 'theme.dart';

/// The floor editor (docs/floor-editor.md): a manager draws the floor the map shows. Tables are picked,
/// dragged, sized and turned on the plan itself; a panel beside it (under it on a phone) has the rest: a
/// table's name, seats, shape, kind and room, lining tables up, copies, new tables ready-made, and the
/// rooms. Nothing takes effect until Save (the one Save bar); every change can be undone.
///
/// The plan is drawn by one painter and moved by one gesture: a drag that starts on a picked table moves
/// what is picked, any other drag moves the plan, two fingers (or the wheel) make it larger. What is
/// written on a table keeps a size that reads however far out the plan is.
class FloorEditorScreen extends StatefulWidget {
  const FloorEditorScreen({super.key, required this.api, required this.token});

  final PosApi api;

  /// A manager's token: only a manager changes the floor.
  final String token;

  @override
  State<FloorEditorScreen> createState() => FloorEditorScreenState();
}

class FloorEditorScreenState extends State<FloorEditorScreen> {
  /// The plan being drawn; null until the hub has said how it stands.
  FloorEditor? editor;
  FloorPlanEdit? _saved;
  String? _unread;
  bool _saving = false;
  List<SaveProblem> _refused = const [];

  // Where the plan is on the screen: a point of the plan is at [_origin] + point * [_scale].
  double _scale = 1;
  Offset _origin = Offset.zero;
  Size _canvas = Size.zero;
  bool _placed = false;

  /// The whole plan is shown to fit, and nobody has moved it since: it is fitted again when the room for it
  /// changes (the Save bar comes up, the list is put away, the device is turned).
  bool _fitted = false;

  // What the finger that is down is doing, and where things were when it came down.
  bool _moving = false, _handling = false;
  Offset _downAt = Offset.zero, _originThen = Offset.zero, _pressedAt = Offset.zero;
  double _scaleThen = 1;
  PointerDeviceKind _kind = PointerDeviceKind.touch;

  /// A tap adds to what is picked instead of picking one table: for a screen with no Shift key.
  bool _several = false;

  /// On a narrow screen the list under the plan is put away, and the plan has the whole screen.
  bool _shut = false;
  final _focus = FocusNode(debugLabel: 'floor plan');
  final _canvasKey = GlobalKey();
  final _name = TextEditingController();
  String? _nameOf;

  static const _least = 0.08, _most = 6.0;

  /// Where a point of the plan is on the canvas.
  Offset toScreen(Offset plan) => _origin + plan * _scale;

  /// The point of the plan that is at [screen] on the canvas.
  Offset toPlan(Offset screen) => (screen - _origin) / _scale;

  @override
  void initState() {
    super.initState();
    _read();
  }

  @override
  void dispose() {
    editor?.removeListener(_changed);
    editor?.dispose();
    _focus.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _read() async {
    setState(() => _unread = null);
    try {
      final plan = await widget.api.floorPlan();
      if (mounted) _open(plan);
    } on ApiException catch (err) {
      if (!mounted) return;
      setState(
        () => _unread = err.status == 404
            ? 'This hub is older than the floor editor. Update it first (sudo hubctl update).'
            : 'The floor plan could not be read: ${err.message}',
      );
    }
  }

  /// Starts over from [plan], the hub's own: after it was read, saved or put back. After a save the plan
  /// stays where the manager had it on the screen ([keepView]).
  void _open(FloorPlanEdit plan, {bool keepView = false}) {
    editor?.removeListener(_changed);
    editor?.dispose();
    setState(() {
      _saved = plan;
      editor = FloorEditor(plan.plan, busy: plan.busy, booked: plan.booked)..addListener(_changed);
      _refused = const [];
      if (!keepView) _placed = false;
      _nameOf = null;
    });
  }

  void _changed() {
    if (!mounted) return;
    // the hub's last word is about the plan as it was sent: any change since makes it stale
    setState(() => _refused = const []);
  }

  Future<void> _save() async {
    final editor = this.editor;
    if (editor == null) return;
    setState(() => _saving = true);
    try {
      final plan = await widget.api.saveFloorPlan(widget.token, editor.toJson());
      if (!mounted) return;
      _open(plan, keepView: true);
      _say('Floor plan saved');
    } on ApiException catch (err) {
      if (mounted) setState(() => _refused = [(about: null, text: _said(err))]);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Says [text] in passing, in place of whatever was being said.
  void _say(String text) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));

  static String _said(ApiException err) => switch (err.detail?['message']) {
    final String message when message.isNotEmpty => message,
    _ => err.message,
  };

  /// Back to the plan the hub came with, once the manager said so.
  Future<void> _putBack() async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Put back the original plan?'),
        content: const Text(
          'The floor goes back to the plan the hub came with, on every screen. The plan drawn here is lost.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(
            key: const ValueKey('floor-put-back-yes'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Put it back'),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    setState(() => _saving = true);
    try {
      final plan = await widget.api.resetFloorPlan(widget.token);
      if (!mounted) return;
      _open(plan);
      _say('The original plan is back');
    } on ApiException catch (err) {
      if (mounted) _say(_said(err));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ---- where the plan is on the screen

  /// Shows the whole plan, as large as the canvas has the room for.
  void fit() {
    if (_canvas.isEmpty) return;
    setState(_fit);
  }

  void _fit() {
    final frame = (editor?.frame ?? const Rect.fromLTWH(0, 0, 600, 400)).inflate(40);
    // The Save bar takes the foot of the plan as soon as something is changed: the room for it is kept
    // from the start, so that nothing moves and nothing is hidden when it comes up.
    // (More is kept free at the top than at the sides: the knob that turns a table of the first row stands
    // above it.)
    final foot = (editor?.changed ?? false) ? 0 : _barRoom;
    final high = math.max(_canvas.height - foot - _headRoom - 12, 80.0);
    _scale = math.min((_canvas.width - 24) / frame.width, high / frame.height).clamp(_least, 2.0);
    _origin = Offset(_canvas.width / 2, _headRoom + high / 2) - frame.center * _scale;
    _fitted = true;
  }

  static const _barRoom = 66.0, _headRoom = 44.0;

  /// Makes the plan [by] times as large about [about], a point of the canvas (its middle when null).
  void _zoom(double by, [Offset? about]) {
    final at = about ?? _canvas.center(Offset.zero);
    final scale = (_scale * by).clamp(_least, _most);
    setState(() {
      _origin = at - (at - _origin) / _scale * scale;
      _scale = scale;
      _fitted = false;
    });
  }

  static bool get _shift => HardwareKeyboard.instance.isShiftPressed;
  static bool get _command => HardwareKeyboard.instance.isMetaPressed || HardwareKeyboard.instance.isControlPressed;

  // ---- one finger, two fingers, a mouse

  void _down(ScaleStartDetails details) {
    final editor = this.editor;
    if (editor == null) return;
    _focus.requestFocus();
    _downAt = details.localFocalPoint;
    _originThen = _origin;
    _scaleThen = _scale;
    _moving = false;
    if (details.pointerCount != 1) return;
    // A finger is wider than a small table: one that comes down just beside a table has that table. (What
    // it has is what was under it when it came down, not where it had got to when the drag was known.)
    final reach = _kind == PointerDeviceKind.mouse ? 0.0 : 10 / _scale;
    final under = editor.tableAt(toPlan(_pressedAt), within: reach);
    if (under == null) return;
    // A drag on a picked table moves what is picked. With a mouse a drag on any table picks and moves it;
    // a finger moves the plan there, so that looking round a full floor moves no table by accident.
    if (!editor.picked.contains(under.key)) {
      if (_kind != PointerDeviceKind.mouse) return;
      editor.pick(under.key, more: _several || _shift);
    }
    editor.hold();
    _moving = true;
    // The table goes as far as the finger has: a drag is known only once the finger has moved some way, and
    // measured from there the table would trail behind it by that much.
    _downAt = _pressedAt;
  }

  void _dragged(ScaleUpdateDetails details) {
    final editor = this.editor;
    if (editor == null) return;
    if (_moving && details.pointerCount == 1) {
      // (holding Command or Control lets a table stand anywhere, off every line)
      editor.moveBy((details.localFocalPoint - _downAt) / _scale, within: _command ? 0 : 7 / _scale);
      return;
    }
    if (_moving) {
      // a second finger came down: the table stays where it got to, and the fingers have the plan
      editor.release();
      _moving = false;
      _downAt = details.localFocalPoint;
      _originThen = _origin;
      _scaleThen = _scale;
    }
    final scale = (_scaleThen * details.scale).clamp(_least, _most);
    setState(() {
      // the point of the plan that was under the fingers stays under them
      _origin = details.localFocalPoint - (_downAt - _originThen) / _scaleThen * scale;
      _scale = scale;
      _fitted = false;
    });
  }

  void _up(ScaleEndDetails details) {
    if (_moving) editor?.release();
    _moving = false;
  }

  void _tapped(TapUpDetails details) {
    final editor = this.editor;
    if (editor == null) return;
    _focus.requestFocus();
    final reach = details.kind == PointerDeviceKind.mouse ? 0.0 : 10 / _scale;
    final under = editor.tableAt(toPlan(details.localPosition), within: reach);
    if (under != null) {
      editor.pick(under.key, more: _several || _shift);
    } else if (!_several) {
      editor.pickNone();
    }
  }

  void _wheel(PointerSignalEvent event) {
    if (event is PointerScrollEvent) {
      _zoom(math.exp(-event.scrollDelta.dy / 320), event.localPosition);
    }
  }

  Offset _onCanvas(Offset global) =>
      (_canvasKey.currentContext!.findRenderObject()! as RenderBox).globalToLocal(global);

  // Where the finger took a handle: how far from the table's corner it came down, and how far round from
  // where the table faced. The table follows the finger from there, with no jump as it starts.
  Offset _grab = Offset.zero;
  double _grabTurn = 0;

  /// The table's corner was dragged to [corner], a point of the canvas: the table is as wide and deep as
  /// that makes it, about its middle.
  void _sizeTo(EditTable table, Offset corner) {
    final from = toPlan(corner) - table.center;
    final turn = -table.rotation * math.pi / 180;
    final across = (from.dx * math.cos(turn) - from.dy * math.sin(turn)).abs();
    final down = (from.dx * math.sin(turn) + from.dy * math.cos(turn)).abs();
    table.round
        ? editor!.sizeTo(table.key, from.distance * 2, from.distance * 2)
        : editor!.sizeTo(table.key, across * 2, down * 2);
  }

  /// How far round [global] is from straight above the table's middle, in degrees.
  double _roundTo(EditTable table, Offset global) =>
      (toPlan(_onCanvas(global)) - table.center).direction * 180 / math.pi + 90;

  /// The handle above the table was dragged to [global]: the table has turned as far as the finger went
  /// round its middle.
  void _turnTo(EditTable table, Offset global) {
    if ((toPlan(_onCanvas(global)) - table.center).distance < 1) return;
    editor!.turnTo(table.key, _roundTo(table, global) - _grabTurn, within: _command ? 0 : 4);
  }

  // ---- the keys of a Mac

  Map<ShortcutActivator, VoidCallback> _keys(FloorEditor editor) {
    void move(double dx, double dy) => editor.nudge(Offset(dx, dy));
    return {
      for (final (key, dx, dy) in const [
        (LogicalKeyboardKey.arrowLeft, -1.0, 0.0),
        (LogicalKeyboardKey.arrowRight, 1.0, 0.0),
        (LogicalKeyboardKey.arrowUp, 0.0, -1.0),
        (LogicalKeyboardKey.arrowDown, 0.0, 1.0),
      ]) ...{SingleActivator(key): () => move(dx, dy), SingleActivator(key, shift: true): () => move(dx * 10, dy * 10)},
      const SingleActivator(LogicalKeyboardKey.delete): _remove,
      const SingleActivator(LogicalKeyboardKey.backspace): _remove,
      const SingleActivator(LogicalKeyboardKey.escape): editor.pickNone,
      for (final command in const [true, false]) ...{
        SingleActivator(LogicalKeyboardKey.keyZ, meta: command, control: !command): editor.undo,
        SingleActivator(LogicalKeyboardKey.keyZ, meta: command, control: !command, shift: true): editor.redo,
        SingleActivator(LogicalKeyboardKey.keyD, meta: command, control: !command): editor.duplicate,
        SingleActivator(LogicalKeyboardKey.keyA, meta: command, control: !command): editor.pickAll,
      },
    };
  }

  void _remove() {
    final kept = editor?.remove() ?? const [];
    if (kept.isEmpty || !mounted) return;
    _say('${kept.join('. ')}. It stays on the plan until that is done with.');
  }

  // ---- the screen

  @override
  Widget build(BuildContext context) {
    final editor = this.editor;
    final theme = Theme.of(context);
    final problems = editor?.problems ?? const <String>[];
    return SaveBarScaffold(
      changed: editor?.changed ?? false,
      onSave: _saving || problems.isNotEmpty ? null : _save,
      saveKey: const ValueKey('floor-save'),
      waiting: problems.isEmpty ? 'Floor plan not saved' : 'Not saved yet',
      problems: [for (final problem in problems) (about: null, text: problem), ..._refused],
      unsaved: 'The floor plan you drew is not saved.',
      maxWidth: double.infinity,
      appBar: AppBar(
        title: const Text('Floor plan'),
        actions: [
          IconButton(
            key: const ValueKey('floor-undo'),
            tooltip: 'Undo',
            onPressed: editor?.canUndo ?? false ? editor!.undo : null,
            icon: const Icon(Icons.undo_rounded),
          ),
          IconButton(
            key: const ValueKey('floor-redo'),
            tooltip: 'Redo',
            onPressed: editor?.canRedo ?? false ? editor!.redo : null,
            icon: const Icon(Icons.redo_rounded),
          ),
          IconButton(
            key: const ValueKey('floor-several'),
            tooltip: _several ? 'Pick one table at a time' : 'Pick several tables',
            isSelected: _several,
            onPressed: editor == null ? null : () => setState(() => _several = !_several),
            icon: const Icon(Icons.library_add_check_outlined),
            selectedIcon: const Icon(Icons.library_add_check_rounded),
          ),
          PopupMenuButton<String>(
            key: const ValueKey('floor-more'),
            tooltip: 'More',
            enabled: editor != null && !_saving,
            onSelected: (picked) => switch (picked) {
              'all' => editor?.pickAll(),
              'fit' => fit(),
              _ => _putBack(),
            },
            itemBuilder: (context) => [
              const PopupMenuItem(value: 'all', child: Text('Pick every table')),
              const PopupMenuItem(value: 'fit', child: Text('Show the whole plan')),
              PopupMenuItem(
                key: const ValueKey('floor-put-back'),
                value: 'back',
                enabled: _saved?.edited ?? false,
                child: const Text('Put back the original plan'),
              ),
            ],
          ),
        ],
      ),
      child: editor == null
          ? Center(
              child: _unread == null
                  ? const CircularProgressIndicator()
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(_unread!, textAlign: TextAlign.center, style: theme.textTheme.bodyLarge),
                        ),
                        FilledButton(onPressed: _read, child: const Text('Try again')),
                      ],
                    ),
            )
          : LayoutBuilder(
              builder: (context, box) {
                // Beside the plan where there is the width (a tablet on its side, a Mac); under it otherwise.
                final beside = box.maxWidth >= 760;
                final panel = _Panel(
                  editor: editor,
                  name: _nameField(editor),
                  onRemove: _remove,
                  onAdd: _add,
                  wide: beside,
                );
                return beside
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(child: _plan(context, editor)),
                          VerticalDivider(width: 1, color: theme.colorScheme.outlineVariant),
                          SizedBox(width: 340, child: panel),
                        ],
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(child: _plan(context, editor)),
                          Divider(height: 1, color: theme.colorScheme.outlineVariant),
                          _PanelBar(
                            shut: _shut,
                            says: switch (editor.pickedTables) {
                              [] => 'Add a table, rooms',
                              [final table] => 'Table ${table.label}',
                              final tables => '${tables.length} tables',
                            },
                            onTap: () => setState(() => _shut = !_shut),
                          ),
                          if (!_shut)
                            ConstrainedBox(
                              constraints: BoxConstraints(maxHeight: math.min(330, box.maxHeight * 0.46)),
                              child: panel,
                            ),
                        ],
                      );
              },
            ),
    );
  }

  /// A new table of [preset], put down in the middle of what the screen shows of the plan.
  void _add(TablePreset preset) {
    final editor = this.editor;
    if (editor == null) return;
    final foot = editor.changed ? 0 : _barRoom;
    final key = editor.add(
      preset,
      at: _canvas.isEmpty ? null : toPlan(Offset(_canvas.width / 2, (_canvas.height - foot) / 2)),
    );
    if (key != null) _showAdded(key);
  }

  /// A table was put down: the plan moves so that it can be seen.
  void _showAdded(String key) {
    final table = editor?.table(key);
    if (table == null || _canvas.isEmpty) return;
    final at = toScreen(table.center);
    if ((Offset.zero & _canvas).deflate(40).contains(at)) return;
    setState(() {
      _origin = _canvas.center(Offset.zero) - table.center * _scale;
      _fitted = false;
    });
  }

  /// The field a table's name is typed in: it follows the table that is picked.
  Widget _nameField(FloorEditor editor) {
    final table = editor.only;
    if (table == null) {
      _nameOf = null;
      return const SizedBox.shrink();
    }
    if (_nameOf != table.key || (!_focusOnName && _name.text != table.label)) {
      _nameOf = table.key;
      _name.value = TextEditingValue(
        text: table.label,
        selection: TextSelection.collapsed(offset: table.label.length),
      );
    }
    final inUse = editor.inUse(table);
    return Focus(
      onFocusChange: (has) => _focusOnName = has,
      child: TextField(
        key: const ValueKey('table-name'),
        controller: _name,
        enabled: inUse == null,
        textCapitalization: TextCapitalization.characters,
        autocorrect: false,
        inputFormatters: [
          FilteringTextInputFormatter.allow(RegExp('[A-Za-z0-9_-]')),
          LengthLimitingTextInputFormatter(FloorEditor.labelMax),
        ],
        decoration: InputDecoration(
          labelText: 'Name',
          helperText: inUse == null ? 'Up to ${FloorEditor.labelMax} letters and figures' : '$inUse: it keeps its name',
          isDense: true,
        ),
        onChanged: (text) => editor.rename(table.key, text),
      ),
    );
  }

  bool _focusOnName = false;

  Widget _plan(BuildContext context, FloorEditor editor) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = PosColors.of(context);
    return LayoutBuilder(
      builder: (context, box) {
        final resized = box.biggest != _canvas;
        _canvas = box.biggest;
        // The whole plan, to fit: the first time it is drawn, and whenever the room for it changes while
        // nobody has moved it (never under a finger that has a table).
        if (!_canvas.isEmpty && (!_placed || (resized && _fitted && !_moving && !_handling))) {
          _placed = true;
          _fit();
        }
        final only = editor.only;
        return ClipRect(
          child: CallbackShortcuts(
            bindings: _keys(editor),
            child: Focus(
              focusNode: _focus,
              autofocus: true,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: Listener(
                      onPointerDown: (event) {
                        _kind = event.kind;
                        _pressedAt = event.localPosition;
                      },
                      onPointerSignal: _wheel,
                      child: GestureDetector(
                        key: const ValueKey('floor-canvas'),
                        behavior: HitTestBehavior.opaque,
                        onScaleStart: _down,
                        onScaleUpdate: _dragged,
                        onScaleEnd: _up,
                        onTapUp: _tapped,
                        child: CustomPaint(
                          key: _canvasKey,
                          painter: _PlanPainter(
                            editor: editor,
                            scale: _scale,
                            origin: _origin,
                            canvasColor: colors.floorCanvas,
                            dot: colors.floorGridDot,
                            roomFill: colors.roomFill,
                            roomLine: colors.roomBorder,
                            fill: colors.freeTable,
                            booth: Color.alphaBlend(scheme.primary.withValues(alpha: 0.07), colors.freeTable),
                            line: colors.freeTableBorder,
                            ink: colors.freeTableText,
                            faint: scheme.onSurfaceVariant,
                            pick: scheme.primary,
                            wrong: scheme.error,
                            crowded: editor.crowded,
                            font: theme.textTheme.bodyMedium?.fontFamily,
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (only != null) ..._handles(context, editor, only),
                  Positioned(left: 10, bottom: 10, child: _zoomButtons(context)),
                  if (editor.tables.isEmpty)
                    Center(
                      child: Text(
                        'No table yet. Add one from the list.',
                        style: theme.textTheme.bodyLarge?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// The two handles of the one table that is picked: its corner, to size it, and a knob above it, to turn
  /// it. They are as large on the screen however far out the plan is.
  List<Widget> _handles(BuildContext context, FloorEditor editor, EditTable table) {
    final scheme = Theme.of(context).colorScheme;
    final turn = table.rotation * math.pi / 180;
    Offset turned(Offset from) => Offset(
      from.dx * math.cos(turn) - from.dy * math.sin(turn),
      from.dx * math.sin(turn) + from.dy * math.cos(turn),
    );
    // (the corner's handle stands a little off the corner, so that it does not hide a small table)
    final out = table.round ? const Offset(1, 1) : turned(Offset(table.w, table.h));
    final itsCorner = table.round
        ? toScreen(table.center + Offset.fromDirection(math.pi / 4, table.w / 2))
        : toScreen(table.center + turned(Offset(table.w / 2, table.h / 2)));
    final corner = itsCorner + out / out.distance * 11;
    // The knob stands above the table, as the table is turned; under it where above is off the plan's edge.
    final reach = turned(Offset(0, -(table.h / 2 * _scale + 34)));
    final above = toScreen(table.center) + reach, under = toScreen(table.center) - reach;
    final room = (Offset.zero & _canvas).deflate(18);
    final knob = room.contains(above) || !room.contains(under) ? above : under;
    Widget handle(
      String key,
      Offset at,
      IconData icon,
      String tip,
      void Function(Offset global) taken,
      void Function(Offset global) to,
    ) => Positioned(
      left: at.dx - 22,
      top: at.dy - 22,
      child: GestureDetector(
        key: ValueKey(key),
        behavior: HitTestBehavior.opaque,
        // (from where the finger came down, not from where the drag was known: nothing trails behind)
        dragStartBehavior: DragStartBehavior.down,
        onPanStart: (details) {
          _handling = true;
          editor.hold();
          taken(details.globalPosition);
        },
        onPanUpdate: (details) => to(details.globalPosition),
        onPanEnd: (details) {
          _handling = false;
          editor.release();
        },
        onPanCancel: () {
          _handling = false;
          editor.release();
        },
        child: Tooltip(
          message: tip,
          // (a finger's worth of room round a knob that is drawn smaller)
          child: SizedBox.square(
            dimension: 44,
            child: Center(
              child: Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  color: scheme.primary,
                  shape: BoxShape.circle,
                  border: Border.all(color: scheme.surface, width: 2),
                  boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 4, offset: Offset(0, 1))],
                ),
                child: Icon(icon, size: 15, color: scheme.onPrimary),
              ),
            ),
          ),
        ),
      ),
    );

    return [
      handle(
        'handle-size',
        corner,
        Icons.open_in_full_rounded,
        'Drag to size',
        (at) => _grab = _onCanvas(at) - itsCorner,
        (to) => _sizeTo(table, _onCanvas(to) - _grab),
      ),
      if (!table.round)
        handle(
          'handle-turn',
          knob,
          Icons.rotate_right_rounded,
          'Drag to turn',
          (at) => _grabTurn = _roundTo(table, at) - table.rotation,
          (to) => _turnTo(table, to),
        ),
    ];
  }

  Widget _zoomButtons(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget button(String key, IconData icon, String tip, VoidCallback onTap) => IconButton(
      key: ValueKey(key),
      tooltip: tip,
      visualDensity: VisualDensity.compact,
      onPressed: onTap,
      icon: Icon(icon, size: 20),
    );
    return Material(
      color: scheme.surface,
      elevation: 2,
      borderRadius: BorderRadius.circular(22),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          button('zoom-out', Icons.remove_rounded, 'Smaller', () => _zoom(1 / 1.3)),
          button('zoom-fit', Icons.fit_screen_rounded, 'Show the whole plan', fit),
          button('zoom-in', Icons.add_rounded, 'Larger', () => _zoom(1.3)),
        ],
      ),
    );
  }
}

/// The plan as it is drawn: the rooms' frames, the tables, and the lines a table being moved has settled
/// on. Everything is worked out from the plan's own units at the scale the screen has it.
class _PlanPainter extends CustomPainter {
  _PlanPainter({
    required this.editor,
    required this.scale,
    required this.origin,
    required this.canvasColor,
    required this.dot,
    required this.roomFill,
    required this.roomLine,
    required this.fill,
    required this.booth,
    required this.line,
    required this.ink,
    required this.faint,
    required this.pick,
    required this.wrong,
    required this.crowded,
    required this.font,
  }) : super(repaint: editor);

  final FloorEditor editor;
  final double scale;
  final Offset origin;
  final Color canvasColor, dot, roomFill, roomLine, fill, booth, line, ink, faint, pick, wrong;
  final Set<String> crowded;

  /// The app's own typeface, for what is written on the plan.
  final String? font;

  Offset at(Offset plan) => origin + plan * scale;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = canvasColor);
    _grid(canvas, size);
    for (final room in editor.rooms) {
      final frame = editor.frameOf(room.key);
      if (frame == null) continue;
      final on = Rect.fromPoints(at(frame.topLeft), at(frame.bottomRight));
      final shape = RRect.fromRectAndRadius(on, const Radius.circular(14));
      canvas.drawRRect(shape, Paint()..color = roomFill);
      canvas.drawRRect(
        shape,
        Paint()
          ..color = roomLine
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
      final name = _words(room.name.toUpperCase(), 10.5, faint, FontWeight.w700, spacing: 1.1, wide: on.width - 16);
      if (on.width > 60) name.paint(canvas, on.topLeft + Offset(10, -name.height - 3));
    }
    final picked = editor.picked;
    // what is picked is drawn last, over its neighbours
    for (final pass in [false, true]) {
      for (final table in editor.tables) {
        if (picked.contains(table.key) == pass) _table(canvas, table, picked: pass);
      }
    }
    final guide = Paint()
      ..color = pick
      ..strokeWidth = 1;
    for (final g in editor.guides) {
      g.upright
          ? canvas.drawLine(at(Offset(g.at, g.from - 12)), at(Offset(g.at, g.to + 12)), guide)
          : canvas.drawLine(at(Offset(g.from - 12, g.at)), at(Offset(g.to + 12, g.at)), guide);
    }
  }

  /// Dots a regular way apart on the plan, as far apart on the screen as reads as a grid.
  void _grid(Canvas canvas, Size size) {
    var step = 25.0;
    while (step * scale < 18) {
      step *= 2;
    }
    final paint = Paint()..color = dot;
    final from = (Offset.zero - origin) / scale, to = (size.bottomRight(Offset.zero) - origin) / scale;
    for (var x = (from.dx / step).floor() * step; x <= to.dx; x += step) {
      for (var y = (from.dy / step).floor() * step; y <= to.dy; y += step) {
        canvas.drawCircle(at(Offset(x, y)), 1.1, paint);
      }
    }
  }

  void _table(Canvas canvas, EditTable table, {required bool picked}) {
    final middle = at(table.center);
    final w = table.w * scale, h = table.h * scale, side = math.min(w, h);
    final edge = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = picked ? (side * 0.1).clamp(1.8, 2.6) : 1.4
      ..color = picked
          ? pick
          : crowded.contains(table.key)
          ? wrong
          : line;
    final inside = Paint()
      ..color = picked ? Color.alphaBlend(pick.withValues(alpha: 0.14), fill) : (table.kind == 'booth' ? booth : fill);
    canvas.save();
    canvas.translate(middle.dx, middle.dy);
    canvas.rotate(table.rotation * math.pi / 180);
    if (table.round) {
      canvas.drawCircle(Offset.zero, w / 2, inside);
      canvas.drawCircle(Offset.zero, w / 2, edge);
    } else {
      final shape = RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset.zero, width: w, height: h),
        Radius.circular((side * (table.kind == 'booth' ? 0.24 : 0.16)).clamp(2.0, 22.0)),
      );
      canvas.drawRRect(shape, inside);
      canvas.drawRRect(shape, edge);
    }
    canvas.restore();
    // Its name, upright, at a size that reads however far out the plan is; its seats under it where the
    // table has the room.
    // (With the whole plan on a phone a stool at the bar is a few points across: its name is drawn as small
    // as keeps it off its neighbour's, and reads again as soon as the plan is made larger.)
    TextPainter named(double size) =>
        _words(table.label.isEmpty ? '?' : table.label, size, table.label.isEmpty ? wrong : ink, FontWeight.w800);
    final most = (side * 0.3).clamp(10.0, 18.0);
    var name = named(most);
    if (name.width > side) name = named((most * side / name.width).clamp(6.5, most));
    final seats = side >= 40
        ? _words('${table.seats} ${table.seats == 1 ? 'seat' : 'seats'}', 10, faint, FontWeight.w600)
        : null;
    final high = name.height + (seats?.height ?? 0);
    name.paint(canvas, middle - Offset(name.width / 2, high / 2));
    seats?.paint(canvas, middle + Offset(-seats.width / 2, high / 2 - seats.height));
    if (editor.inUse(table) != null) {
      // a table in use wears a small lock: it can be moved, not renamed or taken off
      final lock = TextPainter(
        text: TextSpan(
          text: String.fromCharCode(Icons.lock_rounded.codePoint),
          style: TextStyle(fontFamily: Icons.lock_rounded.fontFamily, fontSize: 11, color: faint),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final (across, down) = table.reach;
      lock.paint(canvas, middle + Offset(across * scale - 9, -down * scale - 3));
    }
  }

  TextPainter _words(
    String text,
    double size,
    Color color,
    FontWeight weight, {
    double spacing = 0,
    double wide = double.infinity,
  }) => TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(
        fontFamily: font,
        fontSize: size,
        height: 1.15,
        color: color,
        fontWeight: weight,
        letterSpacing: spacing,
      ),
    ),
    textDirection: TextDirection.ltr,
    maxLines: 1,
    ellipsis: '…',
  )..layout(maxWidth: math.max(wide, 20));

  @override
  bool shouldRepaint(_PlanPainter old) =>
      old.editor != editor ||
      old.scale != scale ||
      old.origin != origin ||
      old.fill != fill ||
      old.ink != ink ||
      old.pick != pick ||
      old.canvasColor != canvasColor ||
      old.font != font ||
      !setEquals(old.crowded, crowded);
}

/// The bar between the plan and the list under it on a narrow screen: a tap puts the list away, so that the
/// plan has the whole screen, and brings it back. Put away, it says what the list is about.
class _PanelBar extends StatelessWidget {
  const _PanelBar({required this.shut, required this.says, required this.onTap});

  final bool shut;
  final String says;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Semantics(
      button: true,
      label: shut ? 'Show the list: $says' : 'Hide the list',
      child: InkWell(
        key: const ValueKey('panel-toggle'),
        onTap: onTap,
        child: SizedBox(
          height: shut ? 44 : 26,
          child: Stack(
            alignment: Alignment.center,
            children: [
              if (shut)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          says,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall,
                        ),
                      ),
                      Icon(Icons.keyboard_arrow_up_rounded, color: scheme.onSurfaceVariant),
                    ],
                  ),
                )
              else
                Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(color: scheme.outlineVariant, borderRadius: BorderRadius.circular(2)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Everything about the plan that is not done on the plan itself. With one table picked: its name, seats,
/// shape, kind, room, size and turn. With several: lining them up and spreading them out. With none: new
/// tables ready-made, and the rooms.
class _Panel extends StatelessWidget {
  const _Panel({
    required this.editor,
    required this.name,
    required this.onRemove,
    required this.onAdd,
    required this.wide,
  });

  final FloorEditor editor;

  /// The field the picked table's name is typed in, which the screen keeps.
  final Widget name;
  final VoidCallback onRemove;
  final void Function(TablePreset preset) onAdd;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final picked = editor.pickedTables;
    final only = editor.only;

    Widget head(String text, {Widget? trailing}) => Padding(
      padding: const EdgeInsets.only(top: 14, bottom: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text.toUpperCase(),
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.w700,
                letterSpacing: 1,
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );

    Widget stepper(String key, String label, String value, VoidCallback? less, VoidCallback? more) => Row(
      children: [
        Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
        IconButton.filledTonal(
          key: ValueKey('$key-less'),
          tooltip: 'Less',
          visualDensity: VisualDensity.compact,
          onPressed: less,
          icon: const Icon(Icons.remove_rounded, size: 18),
        ),
        SizedBox(
          width: 56,
          child: Text(
            value,
            key: ValueKey('$key-value'),
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium?.copyWith(fontFeatures: PosTheme.tabular),
          ),
        ),
        IconButton.filledTonal(
          key: ValueKey('$key-more'),
          tooltip: 'More',
          visualDensity: VisualDensity.compact,
          onPressed: more,
          icon: const Icon(Icons.add_rounded, size: 18),
        ),
      ],
    );

    Widget rooms(String? of) => Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final room in editor.rooms)
          ChoiceChip(
            key: ValueKey('table-room:${room.key}'),
            label: Text(room.name.isEmpty ? '(no name)' : room.name),
            selected: room.key == of,
            onSelected: (_) => editor.toRoom(room.key),
          ),
      ],
    );

    Widget turning() => Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        ActionChip(
          key: const ValueKey('turn-left'),
          avatar: const Icon(Icons.rotate_left_rounded, size: 18),
          label: const Text('15°'),
          onPressed: () => editor.turnBy(-15),
        ),
        ActionChip(
          key: const ValueKey('turn-right'),
          avatar: const Icon(Icons.rotate_right_rounded, size: 18),
          label: const Text('15°'),
          onPressed: () => editor.turnBy(15),
        ),
        ActionChip(
          key: const ValueKey('turn-straight'),
          label: const Text('Straight'),
          onPressed: () => editor.turn(0),
        ),
        ActionChip(
          key: const ValueKey('turn-corner'),
          label: const Text('On its corner'),
          onPressed: () => editor.turn(45),
        ),
      ],
    );

    Widget doing() => Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Row(
        children: [
          Expanded(
            child: FilledButton.tonalIcon(
              key: const ValueKey('table-duplicate'),
              onPressed: editor.duplicate,
              icon: const Icon(Icons.copy_rounded, size: 18),
              label: const Text('Copy'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: OutlinedButton.icon(
              key: const ValueKey('table-delete'),
              onPressed: onRemove,
              style: OutlinedButton.styleFrom(foregroundColor: scheme.error),
              icon: const Icon(Icons.delete_outline_rounded, size: 18),
              label: const Text('Take off'),
            ),
          ),
        ],
      ),
    );

    final List<Widget> children;
    if (only != null) {
      children = [
        head(
          'Table ${only.label}',
          trailing: TextButton(key: const ValueKey('pick-none'), onPressed: editor.pickNone, child: const Text('Done')),
        ),
        name,
        const SizedBox(height: 10),
        stepper(
          'seats',
          'Seats',
          '${only.seats}',
          only.seats > 1 ? () => editor.seats(only.seats - 1) : null,
          only.seats < FloorEditor.seatsMax ? () => editor.seats(only.seats + 1) : null,
        ),
        head('Shape'),
        SegmentedButton<bool>(
          key: const ValueKey('table-shape'),
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: false, label: Text('Straight sides'), icon: Icon(Icons.crop_square_rounded, size: 18)),
            ButtonSegment(value: true, label: Text('Round'), icon: Icon(Icons.circle_outlined, size: 18)),
          ],
          selected: {only.round},
          onSelectionChanged: (to) => editor.shape(round: to.single),
        ),
        head('Kind'),
        SegmentedButton<String>(
          key: const ValueKey('table-kind'),
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: 'table', label: Text('Table')),
            ButtonSegment(value: 'booth', label: Text('Booth')),
            ButtonSegment(value: 'counter', label: Text('Bar seat')),
          ],
          selected: {only.kind},
          onSelectionChanged: (to) => editor.kind(to.single),
        ),
        head('Room'),
        rooms(only.room),
        head('Size'),
        stepper(
          'width',
          only.round ? 'Across' : 'Width',
          only.w.round().toString(),
          () => editor.size(w: only.w - 1, h: only.round ? only.w - 1 : null),
          () => editor.size(w: only.w + 1, h: only.round ? only.w + 1 : null),
        ),
        if (!only.round) ...[
          const SizedBox(height: 4),
          stepper(
            'depth',
            'Depth',
            only.h.round().toString(),
            () => editor.size(h: only.h - 1),
            () => editor.size(h: only.h + 1),
          ),
        ],
        if (!only.round) ...[head('Turn (${only.rotation.round()}°)'), turning()],
        doing(),
      ];
    } else if (picked.isNotEmpty) {
      Widget line(String key, IconData icon, String tip, VoidCallback onTap) =>
          IconButton.filledTonal(key: ValueKey(key), tooltip: tip, onPressed: onTap, icon: Icon(icon, size: 20));
      children = [
        head(
          '${picked.length} tables',
          trailing: TextButton(key: const ValueKey('pick-none'), onPressed: editor.pickNone, child: const Text('Done')),
        ),
        Text('Drag one of them to move them together.', style: theme.textTheme.bodySmall),
        head('Line up'),
        Wrap(
          spacing: 4,
          runSpacing: 4,
          children: [
            line('line-left', Icons.align_horizontal_left_rounded, 'Left edges', () => editor.lineUp(LineUp.left)),
            line('line-center', Icons.align_horizontal_center_rounded, 'Middles', () => editor.lineUp(LineUp.center)),
            line('line-right', Icons.align_horizontal_right_rounded, 'Right edges', () => editor.lineUp(LineUp.right)),
            line('line-top', Icons.align_vertical_top_rounded, 'Top edges', () => editor.lineUp(LineUp.top)),
            line('line-middle', Icons.align_vertical_center_rounded, 'Middles', () => editor.lineUp(LineUp.middle)),
            line(
              'line-bottom',
              Icons.align_vertical_bottom_rounded,
              'Bottom edges',
              () => editor.lineUp(LineUp.bottom),
            ),
          ],
        ),
        head('Space evenly'),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            ActionChip(
              key: const ValueKey('spread-across'),
              avatar: const Icon(Icons.horizontal_distribute_rounded, size: 18),
              label: const Text('Across'),
              onPressed: picked.length < 3 ? null : () => editor.spread(across: true),
            ),
            ActionChip(
              key: const ValueKey('spread-down'),
              avatar: const Icon(Icons.vertical_distribute_rounded, size: 18),
              label: const Text('Down'),
              onPressed: picked.length < 3 ? null : () => editor.spread(across: false),
            ),
            ActionChip(
              key: const ValueKey('same-size'),
              label: const Text('Same size as the first'),
              onPressed: editor.sameSize,
            ),
          ],
        ),
        head('Room'),
        rooms(picked.map((table) => table.room).toSet().length == 1 ? picked.first.room : null),
        head('Turn'),
        turning(),
        doing(),
      ];
    } else {
      children = [
        head('Add a table'),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final preset in tablePresets)
              ActionChip(
                key: ValueKey('preset:${preset.name}'),
                avatar: Icon(
                  preset.round
                      ? Icons.circle_outlined
                      : preset.rotation != 0
                      ? Icons.diamond_outlined
                      : Icons.crop_square_rounded,
                  size: 18,
                ),
                label: Text(preset.name),
                onPressed: () => onAdd(preset),
              ),
          ],
        ),
        head(
          'Rooms',
          trailing: TextButton.icon(
            key: const ValueKey('add-room'),
            onPressed: () => _askRoom(context, null),
            icon: const Icon(Icons.add_rounded, size: 18),
            label: const Text('Add a room'),
          ),
        ),
        for (final (at, room) in editor.rooms.indexed) _roomRow(context, at, room),
        Padding(
          padding: const EdgeInsets.only(top: 14),
          child: Text(
            'Tap a table to pick it, then drag it. Drag its corner to size it and the knob above it to turn it. '
            'Two fingers, or the wheel, make the plan larger.',
            style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
      ];
    }
    // (a column, not a list that builds what is in sight: there is little of it, and a key of the keyboard
    // finds every button)
    return SingleChildScrollView(
      key: const ValueKey('floor-panel'),
      padding: EdgeInsets.fromLTRB(14, wide ? 4 : 0, 14, 18),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
    );
  }

  Widget _roomRow(BuildContext context, int at, EditRoom room) {
    final theme = Theme.of(context);
    final count = editor.tables.where((table) => table.room == room.key).length;
    return Padding(
      key: ValueKey('room-row:${room.key}'),
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              key: ValueKey('room-name:${room.key}'),
              borderRadius: BorderRadius.circular(8),
              onTap: () => _askRoom(context, room),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(room.name.isEmpty ? '(no name)' : room.name, style: theme.textTheme.titleSmall),
                    Text(
                      count == 0 ? 'No tables' : '$count ${count == 1 ? 'table' : 'tables'}',
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ),
          ),
          IconButton(
            key: ValueKey('room-pick:${room.key}'),
            tooltip: 'Pick its tables',
            visualDensity: VisualDensity.compact,
            onPressed: count == 0 ? null : () => editor.pickRoom(room.key),
            icon: const Icon(Icons.select_all_rounded, size: 20),
          ),
          IconButton(
            key: ValueKey('room-up:${room.key}'),
            tooltip: 'Earlier in the list',
            visualDensity: VisualDensity.compact,
            onPressed: at == 0 ? null : () => editor.moveRoom(room.key, -1),
            icon: const Icon(Icons.arrow_upward_rounded, size: 20),
          ),
          IconButton(
            key: ValueKey('room-down:${room.key}'),
            tooltip: 'Later in the list',
            visualDensity: VisualDensity.compact,
            onPressed: at == editor.rooms.length - 1 ? null : () => editor.moveRoom(room.key, 1),
            icon: const Icon(Icons.arrow_downward_rounded, size: 20),
          ),
          IconButton(
            key: ValueKey('room-remove:${room.key}'),
            tooltip: count > 0
                ? 'Move its tables to another room first'
                : editor.rooms.length < 2
                ? 'The plan keeps one room'
                : 'Take the room off',
            visualDensity: VisualDensity.compact,
            onPressed: count > 0 || editor.rooms.length < 2 ? null : () => editor.removeRoom(room.key),
            icon: const Icon(Icons.delete_outline_rounded, size: 20),
          ),
        ],
      ),
    );
  }

  /// Asks for a room's name: of a new room for null, of [room] otherwise.
  Future<void> _askRoom(BuildContext context, EditRoom? room) async {
    final field = TextEditingController(text: room?.name ?? '');
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(room == null ? 'New room' : 'Name of the room'),
        content: TextField(
          key: const ValueKey('room-name-field'),
          controller: field,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          inputFormatters: [LengthLimitingTextInputFormatter(FloorEditor.roomNameMax)],
          decoration: const InputDecoration(labelText: 'Name', hintText: 'Patio'),
          onSubmitted: (text) => Navigator.of(context).pop(text),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
          FilledButton(
            key: const ValueKey('room-name-ok'),
            onPressed: () => Navigator.of(context).pop(field.text),
            child: Text(room == null ? 'Add' : 'Rename'),
          ),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty) return;
    room == null ? editor.addRoom(name) : editor.renameRoom(room.key, name);
  }
}
