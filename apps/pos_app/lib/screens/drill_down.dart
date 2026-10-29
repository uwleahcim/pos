import 'package:flutter/material.dart';

/// One level opened from the level above it, for small screens: the level above shrinks to a strip on top,
/// this level fills the rest, and pulling down while it is scrolled to the top closes it again.
///
/// Used for the menu's categories now, and meant for any level that opens from another (nested categories,
/// a dish's options). The child's scrollable should use [DrillDown.physics] so a short list can still be
/// pulled.
class DrillDown extends StatefulWidget {
  const DrillDown({super.key, required this.header, required this.child, required this.onClose});

  /// The level above, shrunk.
  final Widget header;
  final Widget child;
  final VoidCallback onClose;

  /// Clamped and always scrollable: a pull at the top is reported as overscroll on every platform.
  static const physics = AlwaysScrollableScrollPhysics(parent: ClampingScrollPhysics());

  /// How far to pull, or how fast to swipe, to close.
  static const distance = 56.0;
  static const speed = 400.0;

  @override
  State<DrillDown> createState() => _DrillDownState();
}

class _DrillDownState extends State<DrillDown> {
  double _pulled = 0;

  bool _onScroll(ScrollNotification n) {
    if (n.depth != 0 || n.metrics.axis != Axis.vertical) return false;
    if (n is OverscrollNotification && n.dragDetails != null && n.overscroll < 0) {
      setState(() => _pulled -= n.overscroll);
    } else if (n is ScrollUpdateNotification && n.dragDetails != null && n.metrics.pixels < n.metrics.minScrollExtent) {
      setState(() => _pulled = n.metrics.minScrollExtent - n.metrics.pixels); // bouncing physics
    } else if (n is ScrollUpdateNotification && n.dragDetails != null && _pulled > 0 && (n.scrollDelta ?? 0) > 0) {
      setState(() => _pulled = 0); // pushed back up: scrolling the list, not closing it
    } else if (n is ScrollEndNotification) {
      final fling = n.dragDetails?.primaryVelocity ?? 0;
      final close = _pulled >= DrillDown.distance || (_pulled > 0 && fling >= DrillDown.speed);
      if (_pulled != 0) setState(() => _pulled = 0);
      if (close) widget.onClose();
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final ready = (_pulled / DrillDown.distance).clamp(0.0, 1.0);
    return Column(
      children: [
        widget.header,
        if (_pulled > 0)
          SizedBox(
            height: 24 * ready,
            child: Opacity(opacity: ready, child: const Icon(Icons.keyboard_double_arrow_up, size: 18)),
          ),
        Expanded(
          child: NotificationListener<ScrollNotification>(onNotification: _onScroll, child: widget.child),
        ),
      ],
    );
  }
}
