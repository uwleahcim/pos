import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/screens/reader_keys.dart';
import 'package:pos_app/screens/tap_focus.dart';
import 'package:pos_app/screens/text_arrows.dart';
import 'package:pos_app/tags.dart';

/// A touch or a click puts the keyboard's focus on what was touched (Mike, 2026-11-15), on any screen.

/// The rules of the focus as the app has them around every screen, over [home].
Widget app(Widget home, {WedgeTagReader? reader}) => MaterialApp(
  builder: (context, child) => TapTakesFocus(
    child: ReaderKeysPressNothing(
      typed: reader?.typed,
      child: ArrowsLeaveTextBoxes(child: child!),
    ),
  ),
  home: Scaffold(body: home),
);

/// Where the focus is: the label of the button it is on, 'box' for the text box, 'none' off every element.
String at() {
  final focus = FocusManager.instance.primaryFocus;
  final context = focus?.context;
  if (focus == null || context == null || focus is FocusScopeNode) return 'none';
  String? name;
  bool label(Element element) {
    final widget = element.widget;
    if (widget is Text) name = widget.data;
    if (widget is Icon) name = 'icon';
    if (name == null) element.visitChildren(label);
    return name == null;
  }

  if (context.findAncestorWidgetOfExactType<TextField>() != null) return 'box';
  (context as Element).visitChildren(label);
  return name ?? 'other';
}

Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pumpAndSettle();
}

void main() {
  final pressed = <String>[];
  setUp(pressed.clear);
  Widget button(String name) => TextButton(onPressed: () => pressed.add(name), child: Text(name));

  /// Two rows of buttons, a label and a text box.
  Widget page() => Column(
    children: [
      Row(children: [button('one'), button('two'), button('three')]),
      Row(children: [button('four'), button('five'), button('six')]),
      const Padding(padding: EdgeInsets.all(24), child: Text('a label')),
      const SizedBox(width: 300, child: TextField()),
    ],
  );

  testWidgets('a touch puts the focus on the button touched, and the arrows go on from there', (tester) async {
    await tester.pumpWidget(app(page()));
    expect(at(), 'none');
    await tester.tap(find.text('five'));
    await tester.pumpAndSettle();
    expect(pressed, ['five'], reason: 'the touch still presses the button');
    expect(at(), 'five');

    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(at(), 'six');
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(at(), 'three');
    await press(tester, LogicalKeyboardKey.enter);
    expect(pressed, ['five', 'three']);

    await tester.tap(find.text('one'));
    await tester.pumpAndSettle();
    expect(at(), 'one');
  });

  testWidgets('a click with the mouse does the same; a right click does not', (tester) async {
    await tester.pumpWidget(app(page()));
    await tester.tap(find.text('two'), kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(pressed, ['two']);
    expect(at(), 'two');

    await tester.tap(find.text('six'), kind: PointerDeviceKind.mouse, buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(at(), 'two');
  });

  testWidgets('a touch on nothing, and a finger that slides away, leave the focus where it was', (tester) async {
    await tester.pumpWidget(app(page()));
    await tester.tap(find.text('four'));
    await tester.pumpAndSettle();
    expect(at(), 'four');

    await tester.tap(find.text('a label'));
    await tester.pumpAndSettle();
    expect(at(), 'four');

    await tester.drag(find.text('two'), const Offset(0, 80));
    await tester.pumpAndSettle();
    expect(at(), 'four');
    expect(pressed, ['four']);
  });

  testWidgets('a text box keeps its own way with a tap, and gives the focus up to a button touched', (tester) async {
    await tester.pumpWidget(app(page()));
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    expect(at(), 'box');
    await tester.enterText(find.byType(TextField), 'abc');
    await tester.tap(find.text('six'));
    await tester.pumpAndSettle();
    expect(at(), 'six');
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    expect(at(), 'box');
  });

  testWidgets('the innermost element touched gets it: a button on a row, or the row', (tester) async {
    await tester.pumpWidget(
      app(
        ListView(
          children: [
            for (final name in ['first', 'second'])
              ListTile(
                title: Text(name),
                onTap: () => pressed.add(name),
                trailing: IconButton(icon: const Icon(Icons.delete), onPressed: () => pressed.add('bin $name')),
              ),
          ],
        ),
      ),
    );
    await tester.tap(find.text('second'));
    await tester.pumpAndSettle();
    expect(pressed, ['second']);
    final row = FocusManager.instance.primaryFocus;
    expect(row!.context!.findAncestorWidgetOfExactType<ListTile>(), isNotNull);
    expect(row.context!.findAncestorWidgetOfExactType<IconButton>(), isNull);

    await tester.tap(find.byIcon(Icons.delete).first);
    await tester.pumpAndSettle();
    expect(pressed, ['second', 'bin first']);
    final bin = FocusManager.instance.primaryFocus;
    expect(bin!.context!.findAncestorWidgetOfExactType<IconButton>(), isNotNull);
    expect(tester.widget<ListTile>(find.widgetWithText(ListTile, 'first')).title, isNotNull);
  });

  testWidgets('what a touch opens takes the focus, and gives it back to the element once closed', (tester) async {
    await tester.pumpWidget(
      app(
        Builder(
          builder: (context) => Column(
            children: [
              button('other'),
              TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (context) => AlertDialog(
                    content: const Text('Sure?'),
                    actions: [
                      TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('No')),
                      TextButton(
                        autofocus: true,
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('Yes'),
                      ),
                    ],
                  ),
                ),
                child: const Text('ask'),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.tap(find.text('ask'));
    await tester.pumpAndSettle();
    expect(at(), 'Yes', reason: 'the dialog opens on its own button');
    await tester.tap(find.text('No'));
    await tester.pumpAndSettle();
    expect(find.text('Sure?'), findsNothing);
    expect(at(), 'ask');
  });

  testWidgets('a hold that opens a sheet over the element does not pull the focus back under it', (tester) async {
    await tester.pumpWidget(
      app(
        Builder(
          builder: (context) => Center(
            child: InkWell(
              onLongPress: () => showDialog<void>(
                context: context,
                builder: (context) => AlertDialog(
                  content: const Text('Sheet'),
                  actions: [
                    TextButton(
                      autofocus: true,
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Done'),
                    ),
                  ],
                ),
              ),
              child: const Padding(padding: EdgeInsets.all(40), child: Text('dish')),
            ),
          ),
        ),
      ),
    );
    await tester.longPress(find.text('dish'));
    await tester.pumpAndSettle();
    expect(find.text('Sheet'), findsOneWidget);
    expect(at(), 'Done');
  });

  group('a badge reader on the keyboard', () {
    late DateTime now;
    late WedgeTagReader reader;
    final tags = <String>[];
    setUp(() {
      now = DateTime(2026, 11, 15, 12);
      tags.clear();
      reader = WedgeTagReader(onTag: tags.add, clock: () => now)..install();
    });
    tearDown(() => reader.uninstall());

    /// The reader types [text] and Enter, a key every five milliseconds.
    Future<void> badge(WidgetTester tester, String text) async {
      now = now.add(const Duration(seconds: 2));
      for (final ch in text.split('')) {
        final key = ch == ' '
            ? LogicalKeyboardKey.space
            : LogicalKeyboardKey(ch.toLowerCase().codeUnitAt(0)); // a letter's or a digit's own key
        await tester.sendKeyEvent(key, character: ch);
        now = now.add(const Duration(milliseconds: 5));
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      now = now.add(const Duration(seconds: 2));
    }

    testWidgets('its Enter signs the badge in and does not press the button touched last', (tester) async {
      await tester.pumpWidget(app(page(), reader: reader));
      await tester.tap(find.text('five'));
      await tester.pumpAndSettle();
      expect(pressed, ['five']);
      expect(at(), 'five');

      await badge(tester, '04a2b3c4');
      expect(tags, ['04A2B3C4']);
      expect(pressed, ['five'], reason: 'the badge pressed nothing');

      await badge(tester, '04 a2 b3 c4');
      expect(tags, ['04A2B3C4', '04A2B3C4']);
      expect(pressed, ['five'], reason: 'nor do the spaces a reader types inside an id');

      // a person's Enter, and a person's Space, still press it
      await press(tester, LogicalKeyboardKey.enter);
      expect(pressed, ['five', 'five']);
      now = now.add(const Duration(seconds: 2));
      await press(tester, LogicalKeyboardKey.space);
      expect(pressed, ['five', 'five', 'five']);
    });

    testWidgets('a badge read while a text box has the focus is typed into it, as before', (tester) async {
      await tester.pumpWidget(app(page(), reader: reader));
      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      await badge(tester, '04a2b3c4');
      expect(tags, ['04A2B3C4']);
      expect(
        reader.typed(
          const KeyDownEvent(
            physicalKey: PhysicalKeyboardKey.enter,
            logicalKey: LogicalKeyboardKey.enter,
            timeStamp: Duration.zero,
          ),
        ),
        isFalse,
        reason: 'only the reader’s own key, while it is being handled',
      );
    });
  });
}
