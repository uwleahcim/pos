import 'package:flutter/material.dart';

import 'text_arrows.dart';

/// A badge reader types like a keyboard: a tag's id, then Enter (`WedgeTagReader`). Enter presses the button
/// that has the keyboard's focus, and since a touch or a click leaves the focus on what was touched
/// (`TapTakesFocus`), a badge tapped at the reader would press the last button touched once more: one more
/// of the dish just added, for one. This sits once around the whole app (see `main.dart`) and keeps the
/// reader's keys from the buttons.
///
/// A text box with the focus still gets them, as before: a tag read while someone types lands in the text
/// (rare, and no button is pressed by it).
class ReaderKeysPressNothing extends StatelessWidget {
  const ReaderKeysPressNothing({super.key, required this.typed, required this.child});

  /// Whether a key came from the reader and would press a button (`WedgeTagReader.typed`); null with no
  /// reader, where every key is somebody's finger.
  final bool Function(KeyEvent event)? typed;

  final Widget child;

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final typed = this.typed;
    if (typed == null || !typed(event) || ArrowsLeaveTextBoxes.focusedTextBox() != null) {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
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
