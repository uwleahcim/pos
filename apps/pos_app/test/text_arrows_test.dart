import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/screens/text_arrows.dart';

/// Arrows in a text box (Mike, 2026-11-14): an arrow leaves the box only when it can no longer move the
/// cursor, in any text box of the app.

/// A text box with a button on each side of it, as any screen of the app has them: inside the rule that
/// sits around the whole app.
Future<TextEditingController> pumpBox(WidgetTester tester, {String text = '', int? maxLines = 1}) async {
  final controller = TextEditingController(text: text);
  addTearDown(controller.dispose);
  Widget button(String name) => TextButton(onPressed: () {}, child: Text(name));
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => ArrowsLeaveTextBoxes(child: child!),
      home: Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              button('above'),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  button('left'),
                  SizedBox(
                    width: 200,
                    child: TextField(controller: controller, maxLines: maxLines),
                  ),
                  button('right'),
                ],
              ),
              button('below'),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byType(TextField));
  await tester.pump();
  return controller;
}

/// Where the focus is: 'box', or the name of the button.
String at(WidgetTester tester) {
  final context = FocusManager.instance.primaryFocus?.context;
  if (context == null) return 'none';
  if (context.findAncestorWidgetOfExactType<TextField>() != null) return 'box';
  final button = context.findAncestorWidgetOfExactType<TextButton>();
  return button == null ? 'other' : (button.child! as Text).data!;
}

Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('an empty text box: every arrow leaves it, the way it points', (tester) async {
    for (final (key, name) in [
      (LogicalKeyboardKey.arrowUp, 'above'),
      (LogicalKeyboardKey.arrowDown, 'below'),
      (LogicalKeyboardKey.arrowLeft, 'left'),
      (LogicalKeyboardKey.arrowRight, 'right'),
    ]) {
      await pumpBox(tester);
      expect(at(tester), 'box');
      await press(tester, key);
      expect(at(tester), name);
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('with text in it, Right and Down leave from the end, Left and Up from the start', (tester) async {
    final box = await pumpBox(tester, text: 'abc');
    box.selection = const TextSelection.collapsed(offset: 3);
    await tester.pump();

    // at the end: Left and Up are still the cursor's
    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect((at(tester), box.selection.extentOffset), ('box', 2));
    // in the middle: no arrow leaves; Right steps on to the end, and only the next Right leaves
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect((at(tester), box.selection.extentOffset), ('box', 3));
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(at(tester), 'right');

    FocusManager.instance.primaryFocus!.focusInDirection(TraversalDirection.left);
    await tester.pumpAndSettle();
    expect(at(tester), 'box');
    box.selection = const TextSelection.collapsed(offset: 1);
    await tester.pump();
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect((at(tester), box.selection.extentOffset), ('box', 3), reason: 'Down runs to the end first');
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(at(tester), 'below');

    FocusManager.instance.primaryFocus!.focusInDirection(TraversalDirection.up);
    await tester.pumpAndSettle();
    box.selection = const TextSelection.collapsed(offset: 1);
    await tester.pump();
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect((at(tester), box.selection.extentOffset), ('box', 0), reason: 'Up runs to the start first');
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(at(tester), 'above');

    FocusManager.instance.primaryFocus!.focusInDirection(TraversalDirection.down);
    await tester.pumpAndSettle();
    box.selection = const TextSelection.collapsed(offset: 1);
    await tester.pump();
    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect((at(tester), box.selection.extentOffset), ('box', 0));
    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(at(tester), 'left');
  });

  testWidgets('selected text, a held arrow and Shift with an arrow all stay in the box', (tester) async {
    final box = await pumpBox(tester, text: 'abc');

    // all of it selected: the arrow puts the cursor at that end of it, the next one leaves
    box.selection = const TextSelection(baseOffset: 0, extentOffset: 3);
    await tester.pump();
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect((at(tester), box.selection), ('box', const TextSelection.collapsed(offset: 3)));

    // Shift and an arrow selects: at the end there is nothing more to select, and the focus stays
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await press(tester, LogicalKeyboardKey.arrowRight);
    await press(tester, LogicalKeyboardKey.arrowDown);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(at(tester), 'box');

    // an arrow held down runs the cursor to the end and stops there
    box.selection = const TextSelection.collapsed(offset: 0);
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
    for (var i = 0; i < 6; i++) {
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
    }
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect((at(tester), box.selection.extentOffset), ('box', 3));
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(at(tester), 'right', reason: 'a fresh press leaves');
  });

  testWidgets('a box of several lines: Down and Up move between its lines before they leave', (tester) async {
    final box = await pumpBox(tester, text: 'one\ntwo', maxLines: 3);
    box.selection = const TextSelection.collapsed(offset: 1);
    await tester.pump();
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect((at(tester), box.selection.extentOffset), ('box', 5), reason: 'to the second line');
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect((at(tester), box.selection.extentOffset), ('box', 7), reason: 'to the end of the last line');
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(at(tester), 'below');

    FocusManager.instance.primaryFocus!.focusInDirection(TraversalDirection.up);
    await tester.pumpAndSettle();
    box.selection = const TextSelection.collapsed(offset: 5);
    await tester.pump();
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect((at(tester), box.selection.extentOffset), ('box', 1));
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect((at(tester), box.selection.extentOffset), ('box', 0));
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(at(tester), 'above');
  });

  testWidgets(
    'on a Mac a box entered with an arrow has its text selected: the first arrow drops the selection, the next leaves',
    (tester) async {
      final box = await pumpBox(tester, text: 'abc');
      box.selection = const TextSelection.collapsed(offset: 0);
      await tester.pump();
      await press(tester, LogicalKeyboardKey.arrowLeft);
      expect(at(tester), 'left');

      await press(tester, LogicalKeyboardKey.arrowRight);
      expect((at(tester), box.selection), ('box', const TextSelection(baseOffset: 0, extentOffset: 3)));
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect((at(tester), box.selection), ('box', const TextSelection.collapsed(offset: 3)));
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(at(tester), 'right');
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets('nothing that way: the focus stays in the box', (tester) async {
    final controller = TextEditingController(text: 'abc');
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => ArrowsLeaveTextBoxes(child: child!),
        home: Scaffold(body: TextField(controller: controller)),
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.pump();
    controller.selection = const TextSelection.collapsed(offset: 3);
    await tester.pump();
    await press(tester, LogicalKeyboardKey.arrowRight);
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(at(tester), 'box');
    expect(controller.selection.extentOffset, 3);
  });
}
