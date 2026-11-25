import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/screens/save_bar.dart';

/// The one way a settings page is saved ([SaveBarScaffold]): nothing is kept as it is changed, a bar with Save
/// comes up at the bottom of the screen with the first change and stays there however the page is
/// scrolled, it rests at the page's end, it goes once everything is put back, and leaving with a change
/// waiting asks first.

/// A settings page of [rows] switches, the first on a card of its own, which waits to be saved while any
/// switch is on.
class Page extends StatefulWidget {
  const Page({super.key, this.rows = 30, this.always = false, this.problems = const [], this.saving = false});

  final int rows;
  final bool always;
  final List<SaveProblem> problems;
  final bool saving;

  @override
  State<Page> createState() => PageState();
}

class PageState extends State<Page> {
  final Set<int> on = {};
  int saves = 0;

  @override
  Widget build(BuildContext context) => SaveBarScaffold(
    appBar: AppBar(title: const Text('A settings page')),
    changed: on.isNotEmpty,
    always: widget.always,
    onSave: widget.saving
        ? null
        : () => setState(() {
            saves++;
            on.clear();
          }),
    saveKey: const ValueKey('page-save'),
    waiting: '${on.length} not saved',
    problems: widget.problems,
    unsaved: 'The switches are not saved.',
    child: ListView(
      key: const ValueKey('page-list'),
      children: [
        for (var i = 0; i < widget.rows; i++)
          SwitchListTile(
            key: ValueKey('row:$i'),
            title: Text('Setting $i'),
            value: on.contains(i),
            onChanged: (to) => setState(() => to ? on.add(i) : on.remove(i)),
          ),
      ],
    ),
  );
}

Finder key(String name) => find.byKey(ValueKey(name));

Future<PageState> pumpPage(
  WidgetTester tester, {
  Size size = const Size(400, 800),
  double textScale = 1,
  Page page = const Page(),
  bool pushed = false,
}) async {
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: pushed
          ? Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: TextButton(
                    key: const ValueKey('open'),
                    onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page)),
                    child: const Text('Open'),
                  ),
                ),
              ),
            )
          : page,
    ),
  );
  await tester.pumpAndSettle();
  if (pushed) {
    await tester.tap(key('open'));
    await tester.pumpAndSettle();
  }
  return tester.state<PageState>(find.byType(Page));
}

Future<void> flip(WidgetTester tester, int row) async {
  await tester.tap(key('row:$row'));
  await tester.pumpAndSettle();
}

/// Whether the bar shows its line: there is more of the page under it.
bool lined(WidgetTester tester) {
  final context = tester.element(key('save-bar'));
  final bar = tester.widget<AnimatedContainer>(key('save-bar')).decoration! as BoxDecoration;
  return (bar.border! as Border).top.color == Theme.of(context).colorScheme.outlineVariant;
}

void main() {
  test('names in a sentence', () {
    expect(inSentence(const []), '');
    expect(inSentence(const ['Courses']), 'Courses');
    expect(inSentence(const ['Courses', 'desk phones']), 'Courses and desk phones');
    expect(inSentence(const ['Courses', 'desk phones', 'tickets']), 'Courses, desk phones and tickets');
  });

  testWidgets('nothing changed: no bar, and the list has the whole screen', (tester) async {
    await pumpPage(tester);
    expect(key('save-bar'), findsNothing);
    expect(key('page-save'), findsNothing);
    expect(tester.getRect(key('page-list')).bottom, 800);
  });

  testWidgets('the first change brings Save up at the bottom of the screen; put back, it goes', (tester) async {
    final page = await pumpPage(tester);
    await tester.tap(key('row:1'));
    await tester.pump();
    expect(key('page-save'), findsOneWidget, reason: 'the bar is on its way up with the change itself');
    await tester.pumpAndSettle();
    final bar = tester.getRect(key('save-bar'));
    expect((bar.left, bar.right, bar.bottom), (0, 400, 800));
    expect(tester.getRect(key('page-list')).bottom, bar.top, reason: 'the list ends where the bar starts');
    final save = tester.getRect(key('page-save'));
    expect(save.right <= 400 - 16 && save.bottom <= 800, isTrue);
    expect(tester.widget<Text>(key('save-waiting')).data, '1 not saved');
    await flip(tester, 4);
    expect(tester.widget<Text>(key('save-waiting')).data, '2 not saved');

    // everything put back as it was: nothing to save, no bar
    await flip(tester, 1);
    await tester.tap(key('row:4'));
    await tester.pump();
    expect(tester.widget<FilledButton>(key('page-save')).onPressed, isNull, reason: 'going down, it saves nothing');
    expect(tester.widget<Text>(key('save-waiting')).data, '1 not saved', reason: 'and keeps its words as it goes');
    await tester.pumpAndSettle();
    expect(key('save-bar'), findsNothing);
    expect(tester.getRect(key('page-list')).bottom, 800);
    expect(page.saves, 0);

    // and Save itself takes it away
    await flip(tester, 2);
    await tester.tap(key('page-save'));
    await tester.pumpAndSettle();
    expect(page.saves, 1);
    expect(key('save-bar'), findsNothing);
  });

  testWidgets('it follows as the page is scrolled, and rests at the page\'s end', (tester) async {
    await pumpPage(tester);
    await flip(tester, 0);
    final at = tester.getRect(key('page-save'));
    expect(lined(tester), isTrue, reason: 'there is more of the page under the bar');

    await tester.drag(key('page-list'), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(tester.getRect(key('page-save')), at, reason: 'the page moved under it');
    expect(key('row:0'), findsNothing, reason: 'the switch that was flipped is scrolled away');
    expect(lined(tester), isTrue);

    // all the way down: the last row stands whole above the bar, and the line goes
    await tester.drag(key('page-list'), const Offset(0, -5000));
    await tester.pumpAndSettle();
    expect(tester.getRect(key('page-save')), at);
    expect(tester.getRect(key('row:29')).bottom, tester.getRect(key('save-bar')).top);
    expect(lined(tester), isFalse, reason: 'at the page\'s end it is part of the page');

    // and back up: it follows, with its line again
    await tester.drag(key('page-list'), const Offset(0, 200));
    await tester.pumpAndSettle();
    expect(tester.getRect(key('page-save')), at);
    expect(lined(tester), isTrue);
  });

  testWidgets('a page too short to scroll: the bar is at the bottom of the screen, at rest', (tester) async {
    await pumpPage(tester, page: const Page(rows: 3));
    await flip(tester, 2);
    expect(tester.getRect(key('save-bar')).bottom, 800);
    expect(lined(tester), isFalse);
  });

  testWidgets('a change made at the page\'s end stays in view when the bar comes up', (tester) async {
    await pumpPage(tester);
    await tester.drag(key('page-list'), const Offset(0, -5000));
    await tester.pumpAndSettle();
    expect(tester.getRect(key('row:29')).bottom, 800);
    await flip(tester, 29);
    final bar = tester.getRect(key('save-bar'));
    expect(tester.getRect(key('row:29')).bottom, bar.top, reason: 'the bar did not come up over the last row');
    expect(lined(tester), isFalse);

    // saved: the bar goes and the page has its room again
    await tester.tap(key('page-save'));
    await tester.pumpAndSettle();
    expect(tester.getRect(key('row:29')).bottom, 800);
  });

  testWidgets('a change made in the middle of the page leaves the page where it is', (tester) async {
    await pumpPage(tester);
    await tester.drag(key('page-list'), const Offset(0, -300));
    await tester.pumpAndSettle();
    final was = tester.getRect(key('row:8'));
    await flip(tester, 8);
    expect(tester.getRect(key('row:8')), was);
  });

  testWidgets('what a save did not get through is said above the button; a save on its way greys it', (tester) async {
    final page = await pumpPage(
      tester,
      page: const Page(
        problems: [
          (about: 'Courses', text: 'Every course needs a name.'),
          (about: null, text: 'The hub did not answer.'),
        ],
        saving: true,
      ),
    );
    await flip(tester, 0);
    final problems = tester.widgetList<Text>(key('save-problem')).map((t) => t.textSpan!.toPlainText()).toList();
    expect(problems, ['Courses: Every course needs a name.', 'The hub did not answer.']);
    final first = tester.getRect(key('save-problem').first);
    expect(first.bottom <= tester.getRect(key('page-save')).top, isTrue);
    expect(tester.widget<FilledButton>(key('page-save')).onPressed, isNull);
    await tester.tap(key('page-save'), warnIfMissed: false);
    expect(page.saves, 0);
  });

  testWidgets('what the page says in passing comes up above the bar, never over Save', (tester) async {
    await pumpPage(tester);
    await flip(tester, 0);
    ScaffoldMessenger.of(tester.element(key('page-list'))).showSnackBar(const SnackBar(content: Text('Test sent')));
    await tester.pumpAndSettle();
    final said = tester.getRect(find.byType(SnackBar));
    expect(said.bottom <= tester.getRect(key('save-bar')).top, isTrue);
    await tester.tap(key('page-save'));
    await tester.pumpAndSettle();
    expect(tester.state<PageState>(find.byType(Page)).saves, 1);
  });

  testWidgets('leaving with a change waiting asks first; with none it just leaves', (tester) async {
    await pumpPage(tester, pushed: true);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(Page), findsNothing, reason: 'nothing changed: nothing to ask');

    await tester.tap(key('open'));
    await tester.pumpAndSettle();
    await flip(tester, 3);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Leave without saving?'), findsOneWidget);
    expect(find.text('The switches are not saved.'), findsOneWidget);
    await tester.tap(find.text('Keep editing'));
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(key('row:3')).value, isTrue, reason: 'the change is still there');

    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(key('leave-discard'));
    await tester.pumpAndSettle();
    expect(find.byType(Page), findsNothing);
  });

  testWidgets('a page not saved yet at all has the bar from the start, and leaving it never asks', (tester) async {
    final page = await pumpPage(tester, page: const Page(always: true), pushed: true);
    expect(key('save-bar'), findsOneWidget);
    await tester.tap(key('page-save'));
    await tester.pumpAndSettle();
    expect(page.saves, 1);
    expect(key('save-bar'), findsOneWidget, reason: 'it stays');
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Leave without saving?'), findsNothing);
    expect(find.byType(Page), findsNothing);
  });

  testWidgets('with the keyboard up the bar stands on it', (tester) async {
    await pumpPage(tester);
    await flip(tester, 0);
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();
    expect(tester.getRect(key('save-bar')).bottom, 500);
    expect(tester.getRect(key('page-save')).bottom <= 500, isTrue);
  });

  testWidgets('on a wide screen the words and the button keep to the page\'s column', (tester) async {
    await pumpPage(tester, size: const Size(1200, 800));
    await flip(tester, 0);
    final bar = tester.getRect(key('save-bar'));
    expect((bar.left, bar.right), (0, 1200), reason: 'the bar itself goes from edge to edge');
    expect(tester.getRect(key('save-waiting')).left, (1200 - 640) / 2 + 16);
    expect(tester.getRect(key('page-save')).right, (1200 + 640) / 2 - 16);
  });

  testWidgets('it fits a 320-wide phone with large text', (tester) async {
    await pumpPage(
      tester,
      size: const Size(320, 568),
      textScale: 1.3,
      page: const Page(
        problems: [(about: 'Desk phones', text: 'Every phone needs its extension and the name of its screen.')],
      ),
    );
    await flip(tester, 0);
    final save = tester.getRect(key('page-save'));
    expect(save.right <= 320 && save.bottom <= 568, isTrue);
    expect(tester.getRect(key('save-problem')).right <= 320, isTrue);
    expect(tester.takeException(), isNull);
  });
}
