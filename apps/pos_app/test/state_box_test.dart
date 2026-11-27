import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/address_list.dart';
import 'package:pos_app/address_parts.dart';
import 'package:pos_app/screens/state_box.dart';
import 'package:pos_app/screens/tap_focus.dart';
import 'package:pos_app/screens/text_arrows.dart';

import 'address_fields_test.dart' show city, enter, pressEnter, pumpFields, state, street, zip;
import 'address_list_test.dart' show inBox, press, type;
import 'catering_test.dart' show dataOf, tapKey;
import 'delivery_fee_test.dart' show carried, delivery, pumpForm, pumpOrder;
import 'delivery_test.dart' show addressOn, addressParts, created, key, typed;
import 'hub.dart';

/// The State box of an address (docs/delivery.md, "The address in its parts"): a list of the fifty states
/// by their two letters, which typing narrows down, and which the list of addresses under the street
/// still fills (Mike, 2026-11-26). The first groups are the fifty and the box's rule for what is typed;
/// then the box by itself with its list; then the box among the others of an address, on the forms.

const m = 'MA MD ME MI MN MO MS MT';
const n = 'NC ND NE NH NJ NM NV NY';

/// The fifty by their letters, as [shown] says them.
String get fifty => [for (final state in usStates) state.code].join(' ');

/// The states the list shows by their letters, the top one first. Empty when there is no list.
String shown(WidgetTester tester) => [
  for (final line in tester.widgetList<InkWell>(find.descendant(of: key('state-list'), matching: find.byType(InkWell))))
    (line.key! as ValueKey<String>).value.split(':').last,
].join(' ');

/// The state the list marks: the one the box holds, or the one Enter takes. Null where it marks none.
String? marked(WidgetTester tester) {
  final mark = key('state-marked');
  if (mark.evaluate().isEmpty) return null;
  final line = tester.widget<InkWell>(find.ancestor(of: mark, matching: find.byType(InkWell)));
  return (line.key! as ValueKey<String>).value.split(':').last;
}

/// Whether the keyboard is on the list's line of [code].
bool onLine(WidgetTester tester, String code) =>
    tester.widget<InkWell>(key('state-option:$code')).focusNode!.hasPrimaryFocus;

/// What the box's own rule makes of [to] typed where [was] stood.
String fits(String was, String to) => StateBox.fits
    .formatEditUpdate(
      TextEditingValue(
        text: was,
        selection: TextSelection.collapsed(offset: was.length),
      ),
      TextEditingValue(
        text: to,
        selection: TextSelection.collapsed(offset: to.length),
      ),
    )
    .text;

/// A State box by itself, and what it told the form around it.
class Box {
  final text = TextEditingController();
  final focus = FocusNode();
  int changed = 0;
  int next = 0;
}

/// The box in a form that scrolls, [above] under its top: a box over it to leave it for, one under it for
/// its list to lie on, and more form under that. [atRight] stands it at the right edge of the screen.
Future<Box> pumpState(
  WidgetTester tester, {
  String text = '',
  Size? size,
  double above = 0,
  double type = 1,
  bool atRight = false,
  bool keys = false,
}) async {
  if (size != null) {
    tester.view
      ..physicalSize = size
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }
  final box = Box()..text.text = text;
  await tester.pumpWidget(
    MaterialApp(
      // the rules of the keyboard's focus that sit around the whole app (main.dart)
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(type)),
        child: keys ? TapTakesFocus(child: ArrowsLeaveTextBoxes(child: child!)) : child!,
      ),
      home: Scaffold(
        body: SingleChildScrollView(
          key: const ValueKey('form'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(height: above),
              const TextField(key: ValueKey('over')),
              Row(
                mainAxisAlignment: atRight ? MainAxisAlignment.end : MainAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 96 * type,
                    child: StateBox(
                      fieldKey: const ValueKey('state'),
                      controller: box.text,
                      focusNode: box.focus,
                      decoration: const InputDecoration(labelText: 'State'),
                      onChanged: () => box.changed++,
                      onNext: () => box.next++,
                    ),
                  ),
                ],
              ),
              const TextField(key: ValueKey('under')),
              const SizedBox(height: 900),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return box;
}

/// A tap on the box by itself: its list opens.
Future<void> tapState(WidgetTester tester) async {
  await tester.tap(key('state'));
  await tester.pumpAndSettle();
}

/// Letters typed in the box by itself: [text] is all the box would hold if it took them.
Future<void> typeState(WidgetTester tester, String text) async {
  await tester.enterText(key('state'), text);
  await tester.pumpAndSettle();
}

/// How far the form is scrolled.
double scrolled(WidgetTester tester) => tester
    .state<ScrollableState>(find.descendant(of: key('form'), matching: find.byType(Scrollable)).first)
    .position
    .pixels;

void main() {
  group('the fifty states', () {
    test('are fifty, in the order of their letters, each with its name', () {
      final codes = [for (final state in usStates) state.code];
      expect(codes, hasLength(50));
      expect(codes, [...codes]..sort());
      expect(codes.toSet(), hasLength(50));
      expect(codes, isNot(contains('DC'))); // read off an address and kept, but not one of the fifty
      String name(String code) => usStates.firstWhere((state) => state.code == code).name;
      expect(
        [name('MA'), name('NH'), name('NC'), name('WV'), name('RI')],
        ['Massachusetts', 'New Hampshire', 'North Carolina', 'West Virginia', 'Rhode Island'],
      );
      expect((usStates.first.code, usStates.last.code), ('AK', 'WY'));
    });

    test('the ones that begin with what is typed', () {
      String from(String typed) => [for (final state in AddressParts.statesFrom(typed)) state.code].join(' ');
      expect(from(''), fifty);
      expect(from('m'), m);
      expect(from(' N '), n);
      expect(from('mi'), 'MI');
      expect(from('d'), 'DE');
      expect((from('x'), from('mx'), from('mas'), from('dc')), ('', '', '', ''));
    });

    test('one of the fifty for what somebody says of it', () {
      expect(AddressParts.listedState('ma'), 'MA');
      expect(AddressParts.listedState(' Massachusetts '), 'MA');
      expect(AddressParts.listedState('new hampshire'), 'NH');
      expect(AddressParts.listedState('US-NH'), 'NH');
      for (final none in ['', 'M', 'XX', 'Mass', 'DC', 'District of Columbia', 'Winchester']) {
        expect(AddressParts.listedState(none), isNull, reason: none);
      }
    });

    test('what a map service says of a state is its two letters in the box, whichever way it says it', () {
      String of(String state, {String line = '4 Oak Rd, Nashua'}) => AddressSuggestion.of(
        Hub.addressLine(
          line,
          from: 'mapbox',
          parts: {'street': '4 Oak Rd', 'unit': '', 'city': 'Nashua', 'state': state, 'zip': '03060'},
        ),
      )!.boxes.state;
      expect(of('NH'), 'NH');
      expect(of('nh'), 'NH');
      expect(of('New Hampshire'), 'NH');
      expect(of('US-NH'), 'NH');
      expect(of('DC'), 'DC'); // what an address says is kept, also where the list does not offer it
      // a service that left the state out of its parts, or said what is none: the line itself names it
      expect(of('', line: '4 Oak Rd, Nashua, NH 03060'), 'NH');
      expect(of('', line: '4 Oak Rd, Nashua, New Hampshire 03060, United States'), 'NH');
      expect(of('Hillsborough County', line: '4 Oak Rd, Nashua, NH 03060'), 'NH');
      expect(of('', line: '4 Oak Rd, Nashua'), '');
      // and a line with no parts at all is read as it is written
      expect(AddressSuggestion.of(Hub.addressLine('4 Oak Rd, Nashua, NH 03060'))!.boxes.state, 'NH');
    });
  });

  group('what the box takes', () {
    test('a letter a state begins with, and a second one that makes a state with it', () {
      expect(fits('', 'm'), 'M');
      expect(fits('M', 'Ma'), 'MA');
      expect(fits('', 'nh'), 'NH');
      expect(fits('N', 'Nh'), 'NH');
      // no state begins with these: the box stays as it was
      expect(fits('', 'x'), '');
      expect(fits('', '7'), '');
      expect(fits('M', 'Mx'), 'M');
      expect(fits('M', 'Mk'), 'M'); // K begins a state, but MK is none: M is still on its way
      expect(fits('M', 'M '), 'M');
    });

    test('a letter typed where a state stands starts another, wherever the cursor is', () {
      expect(fits('MA', 'MAn'), 'N');
      expect(fits('MA', 'nMA'), 'N');
      expect(fits('MA', 'MnA'), 'N');
      expect(fits('MA', 'MAl'), 'L'); // not AL: the letters before it are not part of the new one
      expect(fits('MA', 'MAx'), 'MA');
      expect(fits('MA', 'n'), 'N'); // typed over all of it
      expect(fits('DC', 'DCv'), 'V'); // also where an address said what is none of the fifty
      final put = StateBox.fits.formatEditUpdate(
        const TextEditingValue(text: 'MA', selection: TextSelection.collapsed(offset: 0)),
        const TextEditingValue(text: 'nMA', selection: TextSelection.collapsed(offset: 1)),
      );
      expect((put.text, put.selection), ('N', const TextSelection.collapsed(offset: 1)));
    });

    test('letters can always be taken away', () {
      expect(fits('MA', 'M'), 'M');
      expect(fits('MA', 'A'), 'A');
      expect(fits('MA', ''), '');
      expect(fits('DC', 'C'), 'C'); // on its way to CA, CO or CT
      expect(fits('M', ''), '');
    });

    test("a state's whole name is its two letters", () {
      expect(fits('', 'Massachusetts'), 'MA');
      expect(fits('MA', 'New Hampshire'), 'NH');
      expect(fits('MA', 'MANew Hampshire'), 'NH'); // pasted behind what stood there
      expect(fits('M', 'Maine'), 'ME');
      expect(fits('', 'm4a ss'), 'MA'); // and of anything else, the letters it begins with
      expect(fits('', 'District of Columbia'), 'D');
    });
  });

  group('the list', () {
    testWidgets('a tap opens the fifty over what stands under the box, the state it holds marked', (tester) async {
      final box = await pumpState(tester, text: 'MA');
      final was = tester.getRect(key('state')), under = tester.getRect(key('under'));
      expect(shown(tester), '');
      await tapState(tester);
      expect(shown(tester), fifty);
      expect(marked(tester), 'MA');
      // under the box and over the one below, and nothing moved for it
      final list = tester.getRect(key('state-list'));
      expect(list.top, inInclusiveRange(was.bottom, was.bottom + 8));
      expect(list.left, was.left);
      expect(list.width, 184); // the letters and the name: wider than a box of two letters
      expect(list.bottom, greaterThan(under.bottom));
      expect((tester.getRect(key('state')), tester.getRect(key('under'))), (was, under));
      expect(scrolled(tester), 0);
      // six states and a half show, not fifty down to the bottom of the screen
      expect(list.height, inInclusiveRange(240, 270));
      // the marked one whole, with the states before it and after it: the rest is a scroll away
      final line = tester.getRect(key('state-option:MA'));
      expect(line.top, greaterThan(list.top + 40));
      expect(line.bottom, lessThan(list.bottom - 40));
      for (final near in ['LA', 'MA', 'MD']) {
        expect(key('state-option:$near').hitTestable(), findsOneWidget, reason: near);
      }
      expect(key('state-option:AK').hitTestable(), findsNothing);
      expect(key('state-option:WY').hitTestable(), findsNothing);
      // each line says the state's name beside its letters
      expect(find.descendant(of: key('state-option:MA'), matching: find.text('Massachusetts')), findsOneWidget);
      expect((box.text.text, box.changed), ('MA', 0));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a box that holds no state opens the fifty from the top, and marks none', (tester) async {
      await pumpState(tester);
      await tapState(tester);
      expect((shown(tester), marked(tester)), (fifty, null));
      expect(key('state-option:AK').hitTestable(), findsOneWidget);
      // the same for what an address said that is none of the fifty: it is kept until another is taken
      final box = await pumpState(tester, text: 'DC');
      await tapState(tester);
      expect((shown(tester), marked(tester), box.text.text), (fifty, null, 'DC'));
    });

    testWidgets('a tap on a line takes the state, and the box keeps the keyboard', (tester) async {
      final box = await pumpState(tester, text: 'MA', keys: true);
      await tapState(tester);
      await tester.tap(key('state-option:MD'));
      await tester.pumpAndSettle();
      expect((box.text.text, shown(tester), box.focus.hasPrimaryFocus), ('MD', '', true));
      expect((box.changed, box.next), (1, 0));
      expect(key('under').hitTestable(), findsOneWidget); // what the list lay over is there again
      // a state further down is a scroll away, in the list itself: a finger on the list is not a touch
      // elsewhere
      await tapState(tester);
      expect(marked(tester), 'MD');
      await tester.drag(key('state-option:MD'), const Offset(0, -120));
      await tester.pumpAndSettle();
      expect(shown(tester), fifty);
      await tapKey(tester, 'state-option:TX');
      expect((box.text.text, shown(tester), box.focus.hasPrimaryFocus), ('TX', '', true));
      // the state the box already holds, tapped again, changes nothing
      await tapState(tester);
      await tester.tap(key('state-option:TX'));
      await tester.pumpAndSettle();
      expect((box.text.text, box.changed), ('TX', 2));
    });

    testWidgets('typing shows the states that begin with what is typed', (tester) async {
      final box = await pumpState(tester);
      await typeState(tester, 'm');
      expect((box.text.text, shown(tester), marked(tester)), ('M', m, 'MA'));
      await typeState(tester, 'Mi');
      expect((box.text.text, shown(tester), marked(tester)), ('MI', 'MI', 'MI'));
      expect(box.changed, 2);
      // a letter typed after a state starts another
      await typeState(tester, 'MIn');
      expect((box.text.text, shown(tester), marked(tester)), ('N', n, 'NC'));
      // a letter no state begins with is not taken: the box and its list stay as they were
      await typeState(tester, 'Nx');
      expect((box.text.text, shown(tester), box.changed), ('N', n, 3));
      await typeState(tester, 'Nq');
      expect((box.text.text, shown(tester), box.changed), ('N', n, 3));
      await typeState(tester, 'Nh');
      expect((box.text.text, shown(tester)), ('NH', 'NH'));
      // the letters taken away again: all fifty, none marked
      await typeState(tester, 'N');
      expect((box.text.text, shown(tester)), ('N', n));
      await typeState(tester, '');
      expect((box.text.text, shown(tester), marked(tester)), ('', fifty, null));
      // a state said by its whole name, as a keyboard's own suggestion puts it in
      await typeState(tester, 'New Hampshire');
      expect((box.text.text, shown(tester)), ('NH', 'NH'));
      expect(tester.takeException(), isNull);
    });

    testWidgets('Enter with one letter takes the first state shown, and goes on', (tester) async {
      final box = await pumpState(tester);
      await typeState(tester, 'n');
      await tester.testTextInput.receiveAction(TextInputAction.next);
      await tester.pumpAndSettle();
      expect((box.text.text, shown(tester), box.next), ('NC', '', 1));
      // with a state, or with nothing, Enter only goes on
      await tester.testTextInput.receiveAction(TextInputAction.next);
      await tester.pumpAndSettle();
      expect((box.text.text, box.next), ('NC', 2));
      await typeState(tester, '');
      await tester.testTextInput.receiveAction(TextInputAction.next);
      await tester.pumpAndSettle();
      expect((box.text.text, shown(tester), box.next), ('', '', 3));
    });

    testWidgets('a box left with one letter takes the only state that begins with it, or what it held', (tester) async {
      final box = await pumpState(tester, text: 'MA');
      await typeState(tester, 'MAn');
      expect(box.text.text, 'N');
      await tester.tap(key('over'));
      await tester.pumpAndSettle();
      expect((box.text.text, shown(tester)), ('MA', '')); // eight states begin with N: none was said
      await typeState(tester, 'MAd');
      await tester.tap(key('over'));
      await tester.pumpAndSettle();
      expect(box.text.text, 'DE'); // only Delaware begins with D
      // and a box that held nothing is empty again
      await typeState(tester, '');
      await tester.tap(key('over'));
      await tester.pumpAndSettle();
      await typeState(tester, 't');
      expect(shown(tester), 'TN TX');
      await tester.tap(key('over'));
      await tester.pumpAndSettle();
      expect((box.text.text, shown(tester)), ('', ''));
      // one letter alone is no state for the form around the box
      expect(
        (StateBox.stateIn('m'), StateBox.stateIn('ma'), StateBox.stateIn(' dc '), StateBox.stateIn('')),
        ('', 'MA', 'DC', ''),
      );
    });

    testWidgets('a touch on anything else puts the list away', (tester) async {
      final box = await pumpState(tester, text: 'MA');
      await tapState(tester);
      expect(shown(tester), fifty);
      await tester.tapAt(const Offset(600, 500)); // nothing there
      await tester.pumpAndSettle();
      expect((shown(tester), box.text.text, box.changed), ('', 'MA', 0));
      // and another tap on the box opens it again
      await tapState(tester);
      expect((shown(tester), marked(tester)), (fifty, 'MA'));
    });

    testWidgets('with a keyboard: the arrow down opens the list and goes into it, Enter takes, Escape closes', (
      tester,
    ) async {
      final box = await pumpState(tester, text: 'MA', keys: true);
      await tapState(tester);
      await press(tester, LogicalKeyboardKey.escape);
      expect((shown(tester), box.text.text, box.focus.hasPrimaryFocus), ('', 'MA', true));
      // the arrow down opens the list, and from there goes to the state the box holds and on
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect((shown(tester), marked(tester), box.focus.hasPrimaryFocus), (fifty, 'MA', true));
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(onLine(tester, 'MA'), isTrue);
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(onLine(tester, 'MD'), isTrue);
      expect(key('state-option:MD').hitTestable(), findsOneWidget);
      await press(tester, LogicalKeyboardKey.enter);
      expect((box.text.text, shown(tester), box.focus.hasPrimaryFocus), ('MD', '', true));
      // after a letter the arrow goes to the first state that begins with it; the arrow up from the first
      // line is the box again, the list still open
      await typeState(tester, 'MDn');
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(onLine(tester, 'NC'), isTrue);
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(onLine(tester, 'ND'), isTrue);
      await press(tester, LogicalKeyboardKey.arrowUp);
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect((box.focus.hasPrimaryFocus, shown(tester)), (true, n));
      // the arrows go down a list longer than its room line by line, each scrolled into sight
      await typeState(tester, '');
      for (final code in fifty.split(' ').take(12)) {
        await press(tester, LogicalKeyboardKey.arrowDown);
        expect(onLine(tester, code), isTrue, reason: code);
        expect(key('state-option:$code').hitTestable(), findsOneWidget, reason: code);
      }
      await press(tester, LogicalKeyboardKey.escape);
      expect((shown(tester), box.text.text, box.focus.hasPrimaryFocus), ('', '', true));
    });

    testWidgets('at the right edge of a small phone with large type the list stays on the screen', (tester) async {
      await pumpState(tester, text: 'MA', size: const Size(320, 568), type: 1.3, atRight: true);
      await tapState(tester);
      final list = tester.getRect(key('state-list')), box = tester.getRect(key('state'));
      expect(box.right, 320);
      expect(list.width, moreOrLessEquals(184 * 1.3));
      expect(list.right, lessThanOrEqualTo(320 - 8)); // it goes left by what would stand off the screen
      expect(list.left, greaterThanOrEqualTo(8));
      expect(list.bottom, lessThanOrEqualTo(568 - 8));
      expect(marked(tester), 'MA');
      expect(key('state-option:MA').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(key('state-option:MD'));
      await tester.pumpAndSettle();
      expect(typed(tester, 'state'), 'MD');
    });

    for (final above in [300.0, 520.0]) {
      testWidgets('the keyboard that comes after the tap takes the room: the box goes up, the list ends over it '
          '(the box $above down the form)', (tester) async {
        await pumpState(tester, text: 'MA', size: const Size(390, 844), above: above);
        expect(scrolled(tester), 0);
        await tester.tap(key('state'));
        await tester.pump();
        expect(shown(tester), fifty);
        // the keyboard comes up over a few frames, and stands
        addTearDown(tester.view.resetViewInsets);
        for (final up in [84.0, 168.0, 252.0, 336.0]) {
          tester.view.viewInsets = FakeViewPadding(bottom: up);
          await tester.pump(const Duration(milliseconds: 60));
        }
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();
        final list = tester.getRect(key('state-list')), box = tester.getRect(key('state'));
        expect(list.bottom, lessThanOrEqualTo(844 - 336 - 8 + 0.5)); // nothing of it under the keyboard
        expect(list.height, greaterThanOrEqualTo(190)); // five states: the form made the room for them
        expect(scrolled(tester), greaterThan(0));
        expect(box.top, greaterThanOrEqualTo(0)); // and what is typed can still be read
        expect(list.top, inInclusiveRange(box.bottom, box.bottom + 8));
        expect((shown(tester), marked(tester)), (fifty, 'MA'));
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('in an address', () {
    testWidgets('the state taken off the list is on the line the order carries, and one letter is not', (tester) async {
      final fields = await pumpFields(tester, home: 'MA');
      await enter(tester, street, '4 Oak Rd');
      await enter(tester, city, 'Nashua');
      expect(fields.address.text, '4 Oak Rd, Nashua, MA');
      await tapKey(tester, state);
      expect((shown(tester), marked(tester)), (fifty, 'MA'));
      await tapKey(tester, 'state-option:NH');
      expect((typed(tester, state), fields.address.text), ('NH', '4 Oak Rd, Nashua, NH'));
      expect(inBox(tester, state), isTrue);
      // one letter is a state still being typed: the line names none until it is one
      await enter(tester, state, 'NHv');
      expect((typed(tester, state), fields.address.text), ('V', '4 Oak Rd, Nashua'));
      await enter(tester, state, 'Vt');
      expect((typed(tester, state), fields.address.text), ('VT', '4 Oak Rd, Nashua, VT'));
      expect(AddressParts.parse(fields.address.text).state, 'VT');
    });

    testWidgets('Enter with one letter takes the first state shown and goes on to the ZIP', (tester) async {
      final fields = await pumpFields(tester, home: 'MA');
      await enter(tester, street, '4 Oak Rd');
      await enter(tester, city, 'Nashua');
      await enter(tester, state, 'MAn');
      expect(shown(tester), n);
      await pressEnter(tester, state);
      expect((typed(tester, state), shown(tester), inBox(tester, zip)), ('NC', '', true));
      expect(fields.address.text, '4 Oak Rd, Nashua, NC');
    });

    testWidgets('a tap on a line of the list of addresses fills the state, whichever way it is said', (tester) async {
      final fields = await pumpFields(tester, home: 'MA');
      Map<String, String> parts(String city, String state, String zip) => {
        'street': '4 Oak Rd',
        'unit': '',
        'city': city,
        'state': state,
        'zip': zip,
      };
      fields.t.hub.addressLists = {
        '4 oa': [
          // by its letters, spelled out, with the country before it, left out of the parts, and with no
          // parts at all
          Hub.addressLine('4 Oak Rd, Kittery, ME 03904', from: 'mapbox', parts: parts('Kittery', 'ME', '03904')),
          Hub.addressLine(
            '4 Oak Rd, Nashua, New Hampshire 03060, United States',
            from: 'mapbox',
            parts: parts('Nashua', 'New Hampshire', '03060'),
          ),
          Hub.addressLine('4 Oak Rd, Barre, VT 05641', from: 'azure', parts: parts('Barre', 'US-VT', '05641')),
          Hub.addressLine('4 Oak Rd, Salem, NH 03079', from: 'azure', parts: parts('Salem', '', '03079')),
          Hub.addressLine('4 Oak Rd, Woburn, MA 01801', from: 'customer'),
          // and what is none of the fifty is kept as the address says it
          Hub.addressLine('4 Oak Rd, Washington, DC 20001', from: 'mapbox', parts: parts('Washington', 'DC', '20001')),
        ],
      };
      for (final (line, city, said, zip) in [
        (0, 'Kittery', 'ME', '03904'),
        (1, 'Nashua', 'NH', '03060'),
        (2, 'Barre', 'VT', '05641'),
        (3, 'Salem', 'NH', '03079'),
        (4, 'Woburn', 'MA', '01801'),
        (5, 'Washington', 'DC', '20001'),
      ]) {
        // whatever state was put in by hand before, off its list
        await tapKey(tester, state);
        await tapKey(tester, 'state-option:CA');
        expect(typed(tester, state), 'CA');
        await type(tester, '4 oa');
        await tapKey(tester, 'address-suggestion:$line');
        expect(addressParts(tester), ['4 Oak Rd', '', city, said, zip], reason: 'line $line');
        expect(fields.address.text, endsWith('$city, $said $zip'), reason: 'line $line');
        // and the list of states opens on the one the address filled in
        await tapKey(tester, state);
        expect((shown(tester), marked(tester)), (fifty, said == 'DC' ? null : said), reason: 'line $line');
        await press(tester, LogicalKeyboardKey.escape);
        expect((shown(tester), typed(tester, state)), ('', said), reason: 'line $line');
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('on the to-go form on a phone: the list of states, and the order starts with the one taken', (
      tester,
    ) async {
      final t = await pumpForm(
        tester,
        fees: {...Hub.mapFees, 'origin': '1 Restaurant Row, Winchester, MA 01890'},
        size: const Size(390, 844),
      );
      t.hub.distances['4 Oak Rd, Nashua, NH'] = const {'miles': '1.6', 'minutes': 5};
      await tester.enterText(key('takeout-name'), 'Linda');
      await tapKey(tester, 'channel:phone');
      await tapKey(tester, 'handover:delivery');
      expect(addressParts(tester), ['', '', '', 'MA', '']);
      await enter(tester, street, '4 Oak Rd');
      await enter(tester, city, 'Nashua');
      await tapKey(tester, state);
      expect((shown(tester), marked(tester)), (fifty, 'MA'));
      final list = tester.getRect(key('state-list'));
      expect(list.right, lessThanOrEqualTo(390 - 8));
      expect(list.bottom, lessThanOrEqualTo(844 - 8));
      await tapKey(tester, 'state-option:NH');
      expect(addressOn(tester), '4 Oak Rd, Nashua, NH');
      expect(tester.takeException(), isNull);
      // Enter from the state's box on: the address is done, and how far it is gets asked with its state
      await pressEnter(tester, state);
      await pressEnter(tester, zip);
      expect([for (final ask in t.hub.distanceAsks) ask['address']], ['4 Oak Rd, Nashua, NH']);
      await tapKey(tester, 'takeout-start');
      expect(created(t.hub)['address'], '4 Oak Rd, Nashua, NH');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets("on the order's own dialog: a state typed is saved on the order's line", (tester) async {
      final t = await pumpOrder(tester, delivery(fee: carried('2', '3.00')), fees: Hub.mapFees);
      await tapKey(tester, 'when-strip');
      expect(addressParts(tester), ['12 Elm St', '', 'Winchester', '', '']);
      await tapKey(tester, state);
      expect((shown(tester), marked(tester)), (fifty, null));
      await enter(tester, state, 'm');
      expect(shown(tester), m);
      await tapKey(tester, 'state-option:MA');
      expect(addressOn(tester), '12 Elm St, Winchester, MA');
      await tapKey(tester, 'when-save');
      expect(dataOf(t.hub, 'set_field', 'o1')['address'], '12 Elm St, Winchester, MA');
      await tester.pumpWidget(const SizedBox());
    });
  });
}
