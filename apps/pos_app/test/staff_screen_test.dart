import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/screens/location_settings_screen.dart';
import 'package:pos_app/screens/staff_screen.dart';
import 'package:pos_app/staff_list.dart';

import 'hub.dart';
import 'location_rows.dart';

/// Staff and PINs (docs/staff.md): everybody who signs in, kept by a manager in the app. The hub keeps the
/// list and checks every PIN; the page shows who is on it and who set each PIN, and never a PIN.

Future<void> tapKey(WidgetTester tester, String key) async {
  final target = find.byKey(ValueKey(key));
  if (target.evaluate().isEmpty) {
    // the page is a list that builds only what is near the screen: on a small phone the people are below it
    final page = find.descendant(of: find.byType(StaffScreen), matching: find.byType(Scrollable)).first;
    await tester.scrollUntilVisible(target, 120, scrollable: page);
  }
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Future<void> type(WidgetTester tester, String key, String text) async {
  await tester.enterText(find.byKey(ValueKey(key)), text);
  await tester.pumpAndSettle();
}

String textOf(WidgetTester tester, String key) => tester.widget<Text>(find.byKey(ValueKey(key))).data!;

/// The line under a person's name, as it reads.
String lineOf(WidgetTester tester, String staffId) {
  final tile = tester.widget<ListTile>(find.byKey(ValueKey('person:$staffId')));
  return (tile.subtitle! as Text).textSpan!.toPlainText();
}

ChoiceChip chip(WidgetTester tester, String role) =>
    tester.widget<ChoiceChip>(find.byKey(ValueKey('person-role:$role')));

/// The page as Location opens it for a manager, on the day the pretend hub stamps a PIN with. Whatever it
/// reports back comes to [told].
Future<Terminal> pumpStaff(
  WidgetTester tester, {
  void Function(Hub hub)? hub,
  Size size = const Size(700, 1600),
  double textScale = 1,
  String token = 'tok-admin',
  List<StaffList>? told,
}) async {
  final t = await terminal(tester);
  hub?.call(t.hub);
  tester.view.physicalSize = size;
  final staff = StaffList.fromJson(t.hub.staffSaid());
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: StaffScreen(
        api: t.api,
        token: token,
        staff: staff,
        onChanged: told?.add,
        now: () => DateTime.fromMillisecondsSinceEpoch(Hub.staffAtMs),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return t;
}

void main() {
  group('a person and the list, in words', () {
    final now = DateTime(2026, 11, 24, 15);
    StaffPerson person(Map<String, dynamic> pin) =>
        StaffPerson.fromJson({...Hub.onStaff('s1', 'Amy', 'server'), 'pin': pin});

    test('where a PIN is from, who set it and when, and never the PIN', () {
      final at = DateTime(2026, 11, 24, 9).millisecondsSinceEpoch;
      final before = DateTime(2026, 11, 20, 9).millisecondsSinceEpoch;
      expect(person({'from': 'app', 'by': 'Mike', 'at_ms': at}).pinLine(now), 'PIN set by Mike today');
      expect(person({'from': 'app', 'by': 'Mike', 'at_ms': before}).pinLine(now), 'PIN set by Mike on Nov 20');
      expect(
        person({'from': 'terminal', 'by': "the hub's terminal", 'at_ms': at}).pinLine(now),
        "PIN set in the hub's terminal today",
      );
      expect(person({'from': 'hub', 'by': '', 'at_ms': null}).pinLine(now), "PIN from the hub's terminal");
      final demo = person({'from': 'demo', 'by': '', 'at_ms': null});
      expect(demo.pinLine(now), 'PIN from the guide: change it');
      expect(demo.demoPin, isTrue);
    });

    test('a role is said as one person of it, and one this app does not know as the hub says it', () {
      expect(roleName('server'), 'Server');
      expect(roleName('owner'), 'Owner');
      expect(roleName('sommelier'), 'sommelier');
      expect(roleName(''), 'No role');
    });

    test('the row under Location says how many, and what needs doing', () {
      final hub = Hub();
      expect(StaffList.fromJson(hub.staffSaid()).summary, "4 people, from the hub's terminal");
      hub.staffSource = 'app';
      expect(StaffList.fromJson(hub.staffSaid()).summary, '4 people');
      hub.demoStaff();
      expect(
        StaffList.fromJson(hub.staffSaid()).summary,
        '4 people · all with PINs from the guide, which anybody can read',
      );
      hub.staffKept![0] = Hub.onStaff('s1', 'Amy', 'server', from: 'app', by: 'Mike', atMs: Hub.staffAtMs);
      expect(
        StaffList.fromJson(hub.staffSaid()).summary,
        '4 people · 3 still with a PIN from the guide, which anybody can read',
      );
      hub.staffKept = [Hub.onStaff('s3', 'Mike', 'manager', you: true, from: 'app')];
      hub.staffSource = 'app';
      expect(StaffList.fromJson(hub.staffSaid()).summary, '1 person');
    });

    test('a hub that says less is read all the same', () {
      final list = StaffList.fromJson({
        'staff': [
          {'staff_id': 's1', 'name': 'Amy', 'role': 'server'},
        ],
      });
      final amy = list.people.single;
      expect((amy.canChange, amy.canRole, amy.canRemove, amy.why, amy.you), (true, true, true, null, false));
      expect((list.source, list.demoPins, list.added), ('app', 0, null));
      expect(list.roles, isEmpty);
      expect(list.byId('s1'), same(amy));
      expect(list.byId('s9'), isNull);
    });
  });

  group('the page', () {
    testWidgets('lists everybody with their role and where their PIN is from', (tester) async {
      await pumpStaff(tester);
      expect(find.text('Staff and PINs'), findsOneWidget);
      expect(find.text('Amy'), findsOneWidget);
      expect(find.text('Mike (you)'), findsOneWidget);
      expect(lineOf(tester, 's1'), "Server · PIN from the hub's terminal");
      expect(lineOf(tester, 's2'), "Bartender · PIN from the hub's terminal");
      expect(lineOf(tester, 's3'), "Manager · PIN from the hub's terminal");
      expect(lineOf(tester, 's4'), "Host · PIN from the hub's terminal");
      expect(textOf(tester, 'staff-source'), contains("typed in the hub's terminal"));
      expect(find.byKey(const ValueKey('staff-demo')), findsNothing);
      expect(textOf(tester, 'staff-way-back'), contains('sudo hubctl staff pin'));
    });

    testWidgets('a list kept in the app says nothing of the terminal', (tester) async {
      await pumpStaff(
        tester,
        hub: (hub) {
          hub.staffSource = 'app';
          hub.staffKept![0] = Hub.onStaff('s1', 'Amy', 'server', from: 'app', by: 'Mike', atMs: Hub.staffAtMs);
        },
      );
      expect(find.byKey(const ValueKey('staff-source')), findsNothing);
      expect(lineOf(tester, 's1'), 'Server · PIN set by Mike today');
    });

    testWidgets('warns while anybody signs in with a PIN from the guide', (tester) async {
      final t = await pumpStaff(tester, hub: (hub) => hub.demoStaff());
      final warning = find.descendant(of: find.byKey(const ValueKey('staff-demo')), matching: find.byType(Text));
      expect(
        tester.widget<Text>(warning).data,
        '4 people still sign in with a PIN from the guide, which anybody can read. Give each a PIN of their own.',
      );
      expect(lineOf(tester, 's1'), 'Server · PIN from the guide: change it');
      expect(textOf(tester, 'staff-source'), 'The first change made here keeps the list in the app from then on.');
      // one of them gets a PIN of their own
      await tapKey(tester, 'person:s1');
      await type(tester, 'person-pin', '4827');
      await tapKey(tester, 'person-save');
      expect(t.hub.staffChanged.single.$1, 's1');
      expect(t.hub.staffChanged.single.$2, {'pin': '4827'});
      expect(tester.widget<Text>(warning).data, startsWith('3 people still sign in with a PIN from the guide'));
      expect(lineOf(tester, 's1'), 'Server · PIN set by Mike today');
      expect(find.byKey(const ValueKey('staff-source')), findsNothing);
    });

    testWidgets('the last one with a PIN from the guide is said as one', (tester) async {
      await pumpStaff(
        tester,
        hub: (hub) {
          hub.staffSource = 'app';
          hub.staffKept![1] = Hub.onStaff('s2', 'Ben', 'bartender', from: 'demo');
        },
      );
      final warning = find.descendant(of: find.byKey(const ValueKey('staff-demo')), matching: find.byType(Text));
      expect(
        tester.widget<Text>(warning).data,
        '1 person still signs in with a PIN from the guide, which anybody can read. Give them a PIN of their own.',
      );
    });
  });

  group('adding somebody', () {
    testWidgets('a name, a role and a PIN go to the hub, and the PIN is nowhere on the page after', (tester) async {
      final told = <StaffList>[];
      final t = await pumpStaff(tester, told: told);
      await tapKey(tester, 'staff-add');
      expect(find.text('Add a person'), findsNWidgets(2)); // the button behind, and the box's title
      expect(chip(tester, 'server').selected, isTrue, reason: 'most of the staff are servers');
      await type(tester, 'person-name', 'Kim');
      await tapKey(tester, 'person-role:driver');
      await type(tester, 'person-pin', '4827');
      await tapKey(tester, 'person-save');
      expect(t.hub.staffAuth, 'Bearer tok-admin');
      expect(t.hub.staffAdded.single, {'name': 'Kim', 'role': 'driver', 'pin': '4827'});
      expect(find.byType(StaffPersonDialog), findsNothing);
      expect(lineOf(tester, 's5'), 'Driver · PIN set by Mike today');
      expect(find.text('Kim is on the staff, and signs in with the PIN you typed'), findsOneWidget);
      expect(find.textContaining('4827'), findsNothing);
      expect((told.single.people.length, told.single.source, told.single.added), (5, 'app', 's5'));
      expect(find.byKey(const ValueKey('staff-source')), findsNothing, reason: 'the list is the app\'s now');
    });

    testWidgets('the PIN box takes four digits and nothing else, hidden until the eye is tapped', (tester) async {
      await pumpStaff(tester);
      await tapKey(tester, 'staff-add');
      await type(tester, 'person-pin', '48a2-7019');
      final box = tester.widget<TextField>(find.byKey(const ValueKey('person-pin')));
      expect(box.controller!.text, '4827');
      expect(box.obscureText, isTrue);
      expect(box.keyboardType, TextInputType.number);
      await tapKey(tester, 'person-pin-show');
      expect(tester.widget<TextField>(find.byKey(const ValueKey('person-pin'))).obscureText, isFalse);
    });

    testWidgets('nothing goes to the hub without a name, or with a PIN that is not four digits', (tester) async {
      final t = await pumpStaff(tester);
      await tapKey(tester, 'staff-add');
      await tapKey(tester, 'person-save');
      expect(textOf(tester, 'person-problem'), 'Everybody on the staff has a name.');
      await type(tester, 'person-name', 'Kim');
      await tapKey(tester, 'person-save');
      expect(textOf(tester, 'person-problem'), 'A PIN is four digits.');
      await type(tester, 'person-pin', '482');
      await tapKey(tester, 'person-save');
      expect(textOf(tester, 'person-problem'), 'A PIN is four digits.');
      expect(t.hub.staffAdded, isEmpty);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.byType(StaffPersonDialog), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('what the hub does not take is said in the box, with the boxes still filled', (tester) async {
      final t = await pumpStaff(
        tester,
        hub: (hub) => hub.refuseStaff = (409, 'pin_taken', 'Somebody else has that PIN. Pick another.'),
      );
      await tapKey(tester, 'staff-add');
      await type(tester, 'person-name', 'Kim');
      await type(tester, 'person-pin', '2222');
      await tapKey(tester, 'person-save');
      expect(textOf(tester, 'person-problem'), 'Somebody else has that PIN. Pick another.');
      expect(tester.widget<TextField>(find.byKey(const ValueKey('person-name'))).controller!.text, 'Kim');
      expect(tester.widget<TextField>(find.byKey(const ValueKey('person-pin'))).controller!.text, '2222');
      // another PIN, and the hub takes it
      t.hub.refuseStaff = null;
      await type(tester, 'person-pin', '4827');
      await tapKey(tester, 'person-save');
      expect(find.byType(StaffPersonDialog), findsNothing);
      expect(t.hub.staffAdded.map((typed) => typed['pin']), ['2222', '4827']);
      expect(find.text('Kim'), findsOneWidget);
    });

    testWidgets('a session that ran out, what only an owner does, and a hub that does not answer', (tester) async {
      final t = await pumpStaff(tester);
      await tapKey(tester, 'staff-add');
      await type(tester, 'person-name', 'Kim');
      await type(tester, 'person-pin', '4827');
      t.hub.refuseStaff = (401, 'sign_in', 'sign in with a manager PIN');
      await tapKey(tester, 'person-save');
      expect(textOf(tester, 'person-problem'), 'The PIN has run out. Go back and open Location again.');
      t.hub.refuseStaff = (403, 'owner_only', 'Only an owner makes somebody an owner.');
      await tapKey(tester, 'person-save');
      expect(textOf(tester, 'person-problem'), 'Only an owner makes somebody an owner.');
      t.hub
        ..refuseStaff = null
        ..down = true;
      await tapKey(tester, 'person-save');
      expect(textOf(tester, 'person-problem'), 'The hub did not answer. Look whether it changed before trying again.');
      expect(tester.widget<TextField>(find.byKey(const ValueKey('person-pin'))).controller!.text, '4827');
      expect(t.hub.staffKept!.length, 4);
    });

    testWidgets('a token that is not a manager\'s changes nothing', (tester) async {
      final t = await pumpStaff(tester, token: 'tok-s1');
      await tapKey(tester, 'staff-add');
      await type(tester, 'person-name', 'Kim');
      await type(tester, 'person-pin', '4827');
      await tapKey(tester, 'person-save');
      expect(textOf(tester, 'person-problem'), 'Only a manager or an owner changes the staff.');
      expect(t.hub.staffAdded, isEmpty);
    });
  });

  group('changing somebody', () {
    testWidgets('only what changed goes to the hub', (tester) async {
      final t = await pumpStaff(tester);
      await tapKey(tester, 'person:s1');
      expect(find.descendant(of: find.byType(AlertDialog), matching: find.text('Amy')), findsNWidgets(2)); // title, box
      expect(tester.widget<TextField>(find.byKey(const ValueKey('person-name'))).controller!.text, 'Amy');
      expect(chip(tester, 'server').selected, isTrue);
      await type(tester, 'person-name', 'Amy W');
      await tapKey(tester, 'person-save');
      expect(t.hub.staffChanged.last.$1, 's1');
      expect(t.hub.staffChanged.last.$2, {'name': 'Amy W'});
      expect(find.text('Amy W saved'), findsOneWidget);
      expect(lineOf(tester, 's1'), "Server · PIN from the hub's terminal", reason: 'the PIN was not touched');

      await tapKey(tester, 'person:s1');
      await tapKey(tester, 'person-role:host');
      await tapKey(tester, 'person-save');
      expect(t.hub.staffChanged.last.$2, {'role': 'host'});
      expect(lineOf(tester, 's1'), startsWith('Host · '));

      await tapKey(tester, 'person:s1');
      await type(tester, 'person-pin', '4827');
      await tapKey(tester, 'person-save');
      expect(t.hub.staffChanged.last.$2, {'pin': '4827'});
      expect(find.text('Amy W saved. The new PIN works now, and the old one does not'), findsOneWidget);
      expect(lineOf(tester, 's1'), 'Host · PIN set by Mike today');
      expect(find.textContaining('4827'), findsNothing);
    });

    testWidgets('Save with nothing changed asks the hub nothing', (tester) async {
      final t = await pumpStaff(tester);
      await tapKey(tester, 'person:s2');
      await tapKey(tester, 'person-save');
      expect(find.byType(StaffPersonDialog), findsNothing);
      expect(t.hub.staffChanged, isEmpty);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('a new PIN that is not four digits does not go to the hub', (tester) async {
      final t = await pumpStaff(tester);
      await tapKey(tester, 'person:s2');
      await type(tester, 'person-pin', '48');
      await tapKey(tester, 'person-save');
      expect(textOf(tester, 'person-problem'), 'A PIN is four digits.');
      expect(t.hub.staffChanged, isEmpty);
    });

    testWidgets('your own name and PIN are yours to change, your role and your place on the staff are not', (
      tester,
    ) async {
      final t = await pumpStaff(tester);
      await tapKey(tester, 'person:s3');
      expect(
        textOf(tester, 'person-why-not'),
        'Your own role is for another manager to change, and so is taking you off the staff.',
      );
      expect(chip(tester, 'manager').selected, isTrue);
      for (final role in t.hub.staffRoles) {
        expect(chip(tester, role).onSelected, isNull, reason: role);
      }
      expect(find.byKey(const ValueKey('person-remove')), findsNothing);
      await type(tester, 'person-pin', '4827');
      await tapKey(tester, 'person-save');
      expect(t.hub.staffChanged.single.$1, 's3');
      expect(t.hub.staffChanged.single.$2, {'pin': '4827'});
    });

    testWidgets('where nobody is an owner yet, a manager makes themselves the first, and nothing else', (tester) async {
      final t = await pumpStaff(
        tester,
        hub: (hub) => hub.staffKept![2] = Hub.onStaff('s3', 'Mike', 'manager', you: true, firstOwner: true),
      );
      await tapKey(tester, 'person:s3');
      expect(
        textOf(tester, 'person-why-not'),
        'Nobody is an owner here yet: you can make yourself the owner. Any other role for you, and taking you '
        'off the staff, is for another manager.',
      );
      for (final role in t.hub.staffRoles) {
        expect(chip(tester, role).onSelected, role == 'owner' || role == 'manager' ? isNotNull : isNull, reason: role);
      }
      expect(find.byKey(const ValueKey('person-remove')), findsNothing);
      await tapKey(tester, 'person-role:owner');
      expect(chip(tester, 'owner').selected, isTrue);
      await tapKey(tester, 'person-role:manager');
      expect(chip(tester, 'manager').selected, isTrue, reason: 'and back, before it is saved');
      await tapKey(tester, 'person-role:owner');
      await tapKey(tester, 'person-save');
      expect(t.hub.staffChanged.single.$1, 's3');
      expect(t.hub.staffChanged.single.$2, {'role': 'owner'});
      expect(lineOf(tester, 's3'), startsWith('Owner · '));
    });

    testWidgets('an owner is an owner\'s to change: a manager is shown them and can change nothing', (tester) async {
      final t = await pumpStaff(
        tester,
        hub: (hub) {
          hub.staffKept!.add(Hub.onStaff('s5', 'Olive', 'owner', ownerOnly: true));
          hub.staffRoles = [...hub.staffRoles]..remove('owner');
        },
      );
      expect(lineOf(tester, 's5'), startsWith('Owner · '));
      await tapKey(tester, 'person:s5');
      expect(textOf(tester, 'person-why-not'), 'Only an owner changes an owner or takes one off the staff.');
      expect(tester.widget<TextField>(find.byKey(const ValueKey('person-name'))).enabled, isFalse);
      expect(find.byKey(const ValueKey('person-pin')), findsNothing, reason: 'no PIN to type for them');
      expect(chip(tester, 'owner').selected, isTrue, reason: 'their own role shows, though a manager cannot give it');
      expect(chip(tester, 'owner').onSelected, isNull);
      expect(chip(tester, 'manager').onSelected, isNull);
      expect(find.byKey(const ValueKey('person-save')), findsNothing);
      expect(find.byKey(const ValueKey('person-remove')), findsNothing);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(t.hub.staffChanged, isEmpty);
      // and a manager is offered no owner to make of anybody else
      await tapKey(tester, 'person:s1');
      expect(find.byKey(const ValueKey('person-role:owner')), findsNothing);
      expect(find.byKey(const ValueKey('person-role:manager')), findsOneWidget);
    });

    testWidgets('a role this app does not know stays its owner\'s until another is picked', (tester) async {
      final t = await pumpStaff(tester, hub: (hub) => hub.staffKept![0] = Hub.onStaff('s1', 'Amy', 'sommelier'));
      expect(lineOf(tester, 's1'), startsWith('sommelier · '));
      await tapKey(tester, 'person:s1');
      expect(chip(tester, 'sommelier').selected, isTrue);
      expect(chip(tester, 'sommelier').onSelected, isNull, reason: 'nobody is given a role the hub does not offer');
      await tapKey(tester, 'person-role:server');
      await tapKey(tester, 'person-save');
      expect(t.hub.staffChanged.single.$2, {'role': 'server'});
    });
  });

  group('taking somebody off the staff', () {
    testWidgets('asks first, and Keep leaves them where they are', (tester) async {
      final t = await pumpStaff(tester);
      await tapKey(tester, 'person:s2');
      await tapKey(tester, 'person-remove');
      expect(find.text('Take Ben off the staff?'), findsOneWidget);
      expect(find.textContaining('signs in no more, by PIN, tag or face'), findsOneWidget);
      await tester.tap(find.text('Keep'));
      await tester.pumpAndSettle();
      expect(t.hub.staffRemoved, isEmpty);
      expect(find.byType(StaffPersonDialog), findsOneWidget);
    });

    testWidgets('once sure, they are gone from the list', (tester) async {
      final told = <StaffList>[];
      final t = await pumpStaff(tester, told: told);
      await tapKey(tester, 'person:s2');
      await tapKey(tester, 'person-remove');
      await tapKey(tester, 'person-remove-sure');
      expect(t.hub.staffRemoved, ['s2']);
      expect(find.byKey(const ValueKey('person:s2')), findsNothing);
      expect(find.text('Ben is off the staff'), findsOneWidget);
      expect(told.single.people.map((p) => p.name), ['Amy', 'Mike', 'Holly']);
    });

    testWidgets('what the hub refuses is said, and they stay', (tester) async {
      final t = await pumpStaff(
        tester,
        hub: (hub) =>
            hub.refuseStaff = (409, 'last_manager', 'Ben is the last manager here. Make somebody else one first.'),
      );
      await tapKey(tester, 'person:s2');
      await tapKey(tester, 'person-remove');
      await tapKey(tester, 'person-remove-sure');
      expect(textOf(tester, 'person-problem'), 'Ben is the last manager here. Make somebody else one first.');
      expect(t.hub.staffKept!.length, 4);
    });
  });

  group('a small phone', () {
    testWidgets('the page and the box fit a 320-wide phone with large text', (tester) async {
      final t = await pumpStaff(
        tester,
        size: const Size(320, 640),
        textScale: 1.3,
        hub: (hub) {
          hub.demoStaff();
          hub.staffKept!.add(Hub.onStaff('s5', 'Bartholomew Featherstonehaugh-Smythe', 'cashier', from: 'demo'));
        },
      );
      expect(tester.takeException(), isNull);
      await tapKey(tester, 'person:s5');
      expect(tester.takeException(), isNull);
      await type(tester, 'person-pin', '48');
      await tapKey(tester, 'person-save');
      expect(textOf(tester, 'person-problem'), 'A PIN is four digits.');
      expect(tester.takeException(), isNull);
      await tapKey(tester, 'person-remove');
      expect(tester.takeException(), isNull);
      expect(t.hub.staffRemoved, isEmpty);
    });
  });

  group('Location', () {
    Future<Terminal> pumpLocation(WidgetTester tester, {Set<String>? holds, void Function(Hub hub)? hub}) async {
      final t = await terminal(tester);
      hub?.call(t.hub);
      tester.view.physicalSize = wholeLocation;
      await tester.pumpWidget(
        MaterialApp(
          home: LocationSettingsScreen(api: t.api, token: 'tok-admin', holds: holds, staffId: 's3', device: 't1'),
        ),
      );
      await tester.pumpAndSettle();
      return t;
    }

    String rowLine(WidgetTester tester) =>
        (tester.widget<ListTile>(find.byKey(const ValueKey('staff-list'))).subtitle! as Text).data!;

    testWidgets('the row says how the staff stand, opens the page, and follows what is changed there', (tester) async {
      final t = await pumpLocation(tester, hub: (hub) => hub.demoStaff());
      await bringUp(tester, 'staff-list');
      expect(rowLine(tester), '4 people · all with PINs from the guide, which anybody can read');
      await tapKey(tester, 'staff-list');
      expect(find.byType(StaffScreen), findsOneWidget);
      await tapKey(tester, 'staff-add');
      await type(tester, 'person-name', 'Kim');
      await type(tester, 'person-pin', '4827');
      await tapKey(tester, 'person-save');
      // the hub lists Kim with the faces and tags from now on
      t.hub.staffList = [
        ...t.hub.staffList,
        {'staff_id': 's5', 'name': 'Kim', 'role': 'server'},
      ];
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(rowLine(tester), '5 people · 4 still with a PIN from the guide, which anybody can read');
      await bringUp(tester, 'staff:s5');
      expect(find.byKey(const ValueKey('staff:s5')), findsOneWidget, reason: 'the faces and tags read again');
    });

    testWidgets('a hub older than the staff kept in the app says so, and the row opens nothing', (tester) async {
      await pumpLocation(tester, hub: (hub) => hub.staffKept = null);
      await bringUp(tester, 'staff-list');
      expect(rowLine(tester), 'This hub is older than the staff kept in the app: update it (sudo hubctl update)');
      expect(tester.widget<ListTile>(find.byKey(const ValueKey('staff-list'))).onTap, isNull);
    });

    testWidgets('somebody who opened Location for the reports is shown no staff row, and the hub is not asked', (
      tester,
    ) async {
      final t = await pumpLocation(tester, holds: {'reports'});
      expect(find.byKey(const ValueKey('staff-list')), findsNothing);
      expect(t.hub.staffAsks, 0);
    });
  });
}
