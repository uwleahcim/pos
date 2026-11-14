import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Arrows in a text box (Mike, 2026-11-14): an arrow moves the cursor for as long as it can, and leaves the
/// text box once it cannot. With the cursor at the end of the text, Right or Down go to what is beside or
/// under the box; with it at the start, Left or Up do. Every text box of the app follows this, the menu's
/// search field among them: this sits once around the whole app (see `main.dart`), over every screen and
/// dialog.
///
/// A widget nearer the text box that has its own use for an arrow gets the key first and keeps it.
class ArrowsLeaveTextBoxes extends StatelessWidget {
  const ArrowsLeaveTextBoxes({super.key, required this.child});

  final Widget child;

  /// The way an arrow key points, null for any other key.
  static TraversalDirection? directionOf(LogicalKeyboardKey key) {
    if (key == LogicalKeyboardKey.arrowUp) return TraversalDirection.up;
    if (key == LogicalKeyboardKey.arrowDown) return TraversalDirection.down;
    if (key == LogicalKeyboardKey.arrowLeft) return TraversalDirection.left;
    if (key == LogicalKeyboardKey.arrowRight) return TraversalDirection.right;
    return null;
  }

  /// Whether the cursor of [value] has nowhere left to go towards [direction]: it stands at the end of the
  /// text for Right and Down (Down in a box of several lines runs to the end of the last line first), at
  /// the start for Left and Up. Selected text is not an edge, the arrow puts the cursor at one end of it;
  /// nor is text an input method is still composing, where the arrows pick among its candidates.
  static bool cursorAtEdge(TextEditingValue value, TraversalDirection direction) {
    if (value.composing.isValid) return false;
    final selection = value.selection;
    if (!selection.isValid) return true; // no cursor to move
    if (!selection.isCollapsed) return false;
    return switch (direction) {
      TraversalDirection.left || TraversalDirection.up => selection.extentOffset <= 0,
      TraversalDirection.right || TraversalDirection.down => selection.extentOffset >= value.text.length,
    };
  }

  /// Whether [event] is a plain, fresh press of an arrow: not one held down (a held arrow runs the cursor to
  /// the end of the text and stops there, it does not fly out of the box), and not one with Shift, Alt,
  /// Control or Command, which select or jump inside the text.
  static bool isPlainPress(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    final keyboard = HardwareKeyboard.instance;
    return !(keyboard.isShiftPressed || keyboard.isAltPressed || keyboard.isControlPressed || keyboard.isMetaPressed);
  }

  /// The text box the keyboard's focus is in, if it is in one.
  static EditableTextState? focusedTextBox() {
    final focus = FocusManager.instance.primaryFocus;
    final context = focus?.context;
    if (focus == null || context == null || !context.mounted) return null;
    final box = context.findAncestorStateOfType<EditableTextState>();
    return box != null && box.widget.focusNode == focus ? box : null;
  }

  static KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final direction = directionOf(event.logicalKey);
    if (direction == null || !isPlainPress(event)) return KeyEventResult.ignored;
    final box = focusedTextBox();
    if (box == null || !cursorAtEdge(box.textEditingValue, direction)) return KeyEventResult.ignored;
    // nothing that way: the key stays the text box's, which does nothing with it
    return box.widget.focusNode.focusInDirection(direction) ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      includeSemantics: false,
      onKeyEvent: _onKey,
      child: child,
    );
  }
}
