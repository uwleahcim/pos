import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Moves elements to their new places when a layout changes, instead of swapping the screen at once: a
/// category tile travels into the strip when it opens and back into the grid when it closes, changing
/// shape on the way. Elements that were not on screen before fade in.
///
/// Wrap each element in a [Reflow] with an id that stays the same across layouts, and call [snapshot]
/// just before the change. The moving copy is drawn above everything, so a clipping list on the way does
/// not hide it.
class ReflowGroup {
  final _live = <Object, _ReflowState>{};
  Map<Object, (Rect, Widget)> _from = const {};
  DateTime _at = DateTime(0);

  /// Remembers where every element is now and what it looks like.
  void snapshot() {
    _from = {
      for (final MapEntry(:key, :value) in _live.entries)
        if (value._rect() case final rect?) key: (rect, value.widget.child),
    };
    _at = DateTime.now();
  }

  bool get _changing => DateTime.now().difference(_at) < const Duration(milliseconds: 500);

  (Rect, Widget)? _take(Object id) => _changing ? _from.remove(id) : null;
}

class Reflow extends StatefulWidget {
  const Reflow({super.key, required this.id, required this.group, required this.child});

  final Object id;
  final ReflowGroup group;
  final Widget child;

  static const duration = Duration(milliseconds: 280);

  @override
  State<Reflow> createState() => _ReflowState();
}

class _ReflowState extends State<Reflow> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(vsync: this, duration: Reflow.duration);
  late final _t = CurvedAnimation(parent: _controller, curve: Curves.easeInOutCubic);
  OverlayEntry? _flight;
  _Mode _mode = _Mode.still;

  @override
  void initState() {
    super.initState();
    widget.group._live[widget.id] = this;
    _arrive();
  }

  @override
  void didUpdateWidget(Reflow old) {
    super.didUpdateWidget(old);
    if (old.id != widget.id || old.group != widget.group) {
      if (old.group._live[old.id] == this) old.group._live.remove(old.id);
      widget.group._live[widget.id] = this;
    }
    if (widget.group._changing) {
      _land();
      _controller.reset();
      _arrive();
    }
  }

  @override
  void dispose() {
    if (widget.group._live[widget.id] == this) widget.group._live.remove(widget.id);
    _flight?.remove();
    _controller.dispose();
    super.dispose();
  }

  Rect? _rect() {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.attached || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  void _arrive() {
    final from = widget.group._take(widget.id);
    if (from == null) {
      if (widget.group._changing) {
        _mode = _Mode.fading;
        _controller.forward().whenComplete(_land);
      }
      return;
    }
    _mode = _Mode.moving; // the element itself stays hidden while its copy travels to it
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final overlay = Overlay.maybeOf(context);
      if (!mounted || overlay == null) return _land();
      _flight = OverlayEntry(
        builder: (_) => _Flight(from: from, to: this, overlay: overlay),
      );
      overlay.insert(_flight!);
      _controller.forward().whenComplete(_land);
    });
  }

  void _land() {
    _flight?.remove();
    _flight = null;
    if (mounted && _mode != _Mode.still) setState(() => _mode = _Mode.still);
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _t,
    child: widget.child,
    builder: (context, child) {
      final v = _t.value;
      return Opacity(
        opacity: switch (_mode) {
          _Mode.still => 1,
          _Mode.moving => 0,
          _Mode.fading => v,
        },
        child: _mode == _Mode.fading
            ? Transform.scale(scale: 0.94 + 0.06 * v, child: child)
            : child,
      );
    },
  );
}

enum _Mode { still, moving, fading }

/// The travelling copy: the old look fading out and the new one fading in, both stretched over a box
/// that goes from the old place to the new one. The new place is read every frame, so a list that scrolls
/// to show the element meanwhile is followed.
class _Flight extends StatelessWidget {
  const _Flight({required this.from, required this.to, required this.overlay});

  final (Rect, Widget) from;
  final _ReflowState to;
  final OverlayState overlay;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: to._t,
    builder: (context, _) {
      final (start, before) = from;
      final end = to._rect() ?? start;
      final t = to._t.value;
      final lift = math.sin(t * math.pi);
      final box = overlay.context.findRenderObject() as RenderBox?;
      final origin = box == null ? Offset.zero : box.localToGlobal(Offset.zero);
      Widget look(Widget child, Size size, double opacity) => Opacity(
        opacity: opacity,
        child: FittedBox(
          fit: BoxFit.fill,
          child: SizedBox.fromSize(size: size, child: child),
        ),
      );
      return Positioned.fromRect(
        rect: Rect.lerp(start, end, t)!.shift(-origin),
        child: IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.12 * lift),
                  blurRadius: 12 * lift,
                  offset: Offset(0, 4 * lift),
                ),
              ],
            ),
            child: Material(
              type: MaterialType.transparency,
              child: Stack(
                fit: StackFit.expand,
                children: [look(before, start.size, 1 - t), look(to.widget.child, end.size, t)],
              ),
            ),
          ),
        ),
      );
    },
  );
}
