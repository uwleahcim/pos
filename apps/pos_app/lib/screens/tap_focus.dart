import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// A touch or a click takes the keyboard's focus with it (Mike, 2026-11-15): whatever was touched on the
/// screen, or clicked with the mouse, is where the keyboard goes on from. Flutter's buttons do not do this by
/// themselves (only text boxes take the focus when tapped), so this sits once around the whole app (see
/// `main.dart`), over every screen and dialog.
///
/// The focus goes to the element under the finger: the innermost thing there that the arrows could also have
/// reached. A tap on nothing (the page, a label) leaves the focus where it was; so does a finger that moves
/// off (a scroll, a drag) or that comes up over something else (a hold that opened a sheet). Text boxes are
/// left to themselves: they take the focus on a tap as they always did, and put the cursor where it landed.
///
/// The tap still does whatever the element does. The focus is asked for before that happens and moves only
/// after it, so what the tap opens (a dialog, a sheet) or asks for itself wins; closed again, the focus is
/// back on the element.
class TapTakesFocus extends StatefulWidget {
  const TapTakesFocus({super.key, required this.child});

  final Widget child;

  /// The element at [position] that can hold the keyboard's focus, if there is one: the first of what is
  /// drawn there, front to back, that is a place the arrows stop at. Not a text box (see the class).
  static FocusNode? elementAt(Offset position, int viewId) {
    final hit = HitTestResult();
    WidgetsBinding.instance.hitTestInView(hit, position, viewId);
    if (hit.path.isEmpty) return null;
    // Each place the arrows stop at, by what draws it. `descendants` lists the innermost first, so of two
    // focus nodes around the same drawing the inner one is kept.
    final places = <RenderObject, FocusNode>{};
    for (final node in FocusManager.instance.rootScope.descendants) {
      if (node is FocusScopeNode || node.skipTraversal || !node.canRequestFocus) continue;
      final context = node.context;
      if (context == null || !context.mounted) continue;
      final drawn = context.findRenderObject();
      if (drawn != null) places.putIfAbsent(drawn, () => node);
    }
    for (final entry in hit.path) {
      final node = places[entry.target];
      if (node == null) continue;
      final box = node.context!.findAncestorStateOfType<EditableTextState>();
      return box != null && box.widget.focusNode == node ? null : node;
    }
    return null;
  }

  @override
  State<TapTakesFocus> createState() => _TapTakesFocusState();
}

class _TapTakesFocusState extends State<TapTakesFocus> {
  final _down = <int, (Offset, FocusNode)>{}; // each finger down on an element: where, and on what

  void _onDown(PointerDownEvent event) {
    // the mouse's main button only: a right click is not a tap
    if (event.kind == PointerDeviceKind.mouse && event.buttons != kPrimaryButton) return;
    final node = TapTakesFocus.elementAt(event.position, event.viewId);
    if (node != null) _down[event.pointer] = (event.position, node);
  }

  void _onUp(PointerUpEvent event) {
    final down = _down.remove(event.pointer);
    if (down == null) return;
    final (at, node) = down;
    if ((event.position - at).distance > kTouchSlop) return; // it moved: a scroll or a drag
    if (TapTakesFocus.elementAt(event.position, event.viewId) != node) return; // no longer what is there
    node.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onDown,
      onPointerUp: _onUp,
      onPointerCancel: (event) => _down.remove(event.pointer),
      child: widget.child,
    );
  }
}
