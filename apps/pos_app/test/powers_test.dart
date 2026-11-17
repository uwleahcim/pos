import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/camera.dart';
import 'package:pos_app/outbox.dart';
import 'package:pos_app/photos.dart';
import 'package:pos_app/powers.dart';
import 'package:pos_app/queue_store.dart';
import 'package:pos_app/screens/discount_sheet.dart';
import 'package:pos_app/screens/location_settings_screen.dart';
import 'package:pos_app/screens/powers_screen.dart';
import 'package:pos_app/screens/rush.dart';
import 'package:pos_app/screens/shift_notes_screen.dart';
import 'package:pos_app/session.dart';
import 'package:pos_app/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'hub.dart';
import 'location_rows.dart';

/// Who may do what (docs/roles.md): the location hands powers to its roles; a manager and an owner hold
/// every one always; the menu, Location and the PIN boxes follow the table; and the hub decides every time.

/// Taps what has this key. On the table's own screen a row far down the list is first scrolled to: the list
/// builds only what is near the screen.
Future<void> tapKey(WidgetTester tester, String key) async {
  final target = find.byKey(ValueKey(key));
  final table = find.descendant(of: find.byType(PowersScreen), matching: find.byType(Scrollable));
  if (target.evaluate().isEmpty && table.evaluate().isNotEmpty) {
    await tester.scrollUntilVisible(target, 200, scrollable: table.first);
  }
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ValueKey(key)));
  await tester.pumpAndSettle();
}

/// Whether a role's button of a power is lit. Looked at on a screen tall enough to hold the whole table.
bool lit(WidgetTester tester, String power, String role) =>
    tester.widget<FilterChip>(find.byKey(ValueKey('power:$power:$role'))).selected;

/// A screen that holds the whole table with nothing to scroll.
const wholeTable = Size(700, 3200);

/// The table's own screen, as Location opens it for a manager. Whatever it is left with comes to [left].
Future<Terminal> pumpPowers(
  WidgetTester tester, {
  void Function(Hub hub)? hub,
  Size? size,
  double textScale = 1,
  List<Powers?>? left,
}) async {
  final t = await terminal(tester);
  hub?.call(t.hub);
  if (size != null) tester.view.physicalSize = size;
  final table = (await t.api.powersTable())!;
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: FilledButton(
              key: const ValueKey('open'),
              onPressed: () async {
                final saved = await Navigator.of(context).push(
                  MaterialPageRoute<Powers>(
                    builder: (_) => PowersScreen(api: t.api, token: 'tok-admin', powers: table),
                  ),
                );
                left?.add(saved);
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tapKey(tester, 'open');
  return t;
}

/// Location as the PIN of someone who [holds] these powers opens it; null is a manager on an older hub.
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

const everything = {
  'void',
  'adjust',
  'exempt',
  'history',
  'take_tables',
  'assign_tables',
  'rush',
  'notes',
  'logbook',
  'waste',
  'reports',
  'guests',
  'time_clock',
  'menu',
  'settings',
};

/// The orders screen with [role] signed in, on a hub that knows of the rush.
Future<Terminal> pumpMenu(WidgetTester tester, String role, {void Function(Hub hub)? hub}) async {
  final t = await terminal(tester, role: role);
  t.hub.quotes = {...t.hub.quotes, 'rush': null};
  hub?.call(t.hub);
  await pumpOrdersOn(tester, t);
  return t;
}

Future<void> typePin(WidgetTester tester, String pin, String button) async {
  await tester.enterText(find.byType(TextField).last, pin);
  await tester.tap(find.widgetWithText(FilledButton, button));
  await tester.pumpAndSettle();
}

void main() {
  group('the table', () {
    test('starts as the hub always was: only the tables are handed out', () {
      const table = Powers.standard;
      for (final role in handedRoles) {
        for (final power in powersById.keys) {
          final usual =
              (power == 'take_tables' && (role == 'server' || role == 'bartender')) ||
              (power == 'assign_tables' && role == 'host');
          expect(table.holds(role, power), usual, reason: '$role, $power');
        }
        expect(table.opensLocation(role), isFalse);
      }
      expect(table.summary, 'As it started: managers and owners approve and open the back office');
      expect(powersById.length, 14);
    });

    test('a manager and an owner hold everything whatever it says, and nobody else the settings', () {
      final nothing = Powers({for (final power in powersById.keys) power: const []});
      final all = Powers({for (final power in powersById.keys) power: handedRoles, settingsPower: handedRoles});
      for (final table in [Powers.standard, nothing, all, const Powers({})]) {
        for (final role in alwaysRoles) {
          expect([...powersById.keys, settingsPower].every((power) => table.holds(role, power)), isTrue);
          expect(table.opensLocation(role), isTrue);
        }
        for (final role in handedRoles) {
          expect(table.holds(role, settingsPower), isFalse);
        }
        expect(table.holds(null, 'void'), isFalse); // nobody signed in
        expect(table.holds('dishwasher', 'void'), isFalse); // a role this app does not know holds nothing
      }
    });

    test('handing a power out and taking it back', () {
      final handed = Powers.standard.hand('void', 'kitchen', on: true).hand('void', 'bartender', on: true);
      expect(handed.handedTo('void'), ['bartender', 'kitchen']); // in the screen's order
      expect(handed.holds('bartender', 'void') && !handed.holds('server', 'void'), isTrue);
      expect(handed.hand('void', 'bartender', on: true), handed); // twice is once
      expect(handed.hand('void', 'kitchen', on: false).hand('void', 'bartender', on: false), Powers.standard);
      // a table that lists a power with nobody is the same as one that does not list it
      expect(Powers({...Powers.standard.roles, 'void': const []}), Powers.standard);
      expect(Powers({...Powers.standard.roles, 'void': const []}).hashCode, Powers.standard.hashCode);
    });

    test('whose PIN a step takes, in words', () {
      expect(Powers.standard.whose('void'), 'a manager');
      expect(Powers.standard.pinTitle('void'), 'Manager PIN');
      final one = Powers.standard.hand('void', 'bartender', on: true);
      expect(one.whose('void'), 'a manager or a bartender');
      expect((one.pinTitle('void'), one.pinTitle('adjust')), ('PIN', 'Manager PIN'));
      final three = one.hand('void', 'server', on: true).hand('void', 'kitchen', on: true);
      expect(three.whose('void'), 'a manager, a server, a bartender or the kitchen');
      // Location opens for anything under it: the box is a manager's until something there is handed out
      expect(one.pinTitle(null), 'Manager PIN');
      expect(one.hand('reports', 'host', on: true).pinTitle(null), 'PIN');
      expect(one.hand('reports', 'host', on: true).opensLocation('host'), isTrue);
      expect(one.opensLocation('bartender'), isFalse); // approving a void opens nothing there
    });

    test('the row says what is handed out beyond how it started, and what was taken from it', () {
      final table = Powers.standard
          .hand('void', 'bartender', on: true)
          .hand('reports', 'host', on: true)
          .hand('reports', 'cashier', on: true)
          .hand('take_tables', 'bartender', on: false)
          .hand('assign_tables', 'host', on: false);
      expect(
        table.summary,
        'Approve a void: Bartenders · Take tables: Servers · Give tables out: managers only · '
        'See the reports: Hosts, Cashiers',
      );
    });

    test('a power or a role this app does not know is kept as the hub sent it', () {
      final table = Powers.fromJson({
        'roles': {
          'void': ['bartender'],
          'fly': ['server'],
        },
        'handed': handedRoles,
      });
      expect(table.holds('bartender', 'void'), isTrue);
      expect((table.toJson()['roles'] as Map)['fly'], ['server']); // sent back as it came
      expect(table.hand('void', 'host', on: true).roles['fly'], ['server']);
    });

    testWidgets('the app follows the hub: the table as last read, the standard one from an older hub', (tester) async {
      final t = await terminal(tester);
      expect(t.api.powers.value, Powers.standard);
      t.hub.powers!['void'] = ['bartender'];
      expect((await t.api.readPowers()).holds('bartender', 'void'), isTrue);
      expect(t.api.powers.value.holds('bartender', 'void'), isTrue);
      t.hub.powers = null; // a hub from before the table
      expect(await t.api.powersTable(), isNull);
      expect(t.api.powers.value, Powers.standard);
    });
  });

  group('the screen', () {
    testWidgets('every power is a row with a button per role, lit as the table stands', (tester) async {
      await pumpPowers(tester, size: wholeTable);
      expect(find.text('Who may do what'), findsOneWidget);
      expect(find.byKey(const ValueKey('powers-intro')), findsOneWidget);
      for (final group in powerGroups) {
        expect(find.text(group.name), findsOneWidget);
        for (final power in group.powers) {
          expect(find.text(power.name), findsOneWidget);
          expect(find.text(power.about), findsOneWidget);
          for (final role in handedRoles) {
            expect(lit(tester, power.id, role), Powers.standard.holds(role, power.id), reason: '${power.id} $role');
          }
        }
      }
      // five roles to hand a power to, and no button for a manager or an owner: theirs is not the table's
      expect(find.widgetWithText(FilterChip, 'Bartenders'), findsNWidgets(14));
      expect(find.widgetWithText(FilterChip, 'Managers'), findsNothing);
      expect(find.widgetWithText(FilterChip, 'Owners'), findsNothing);
      // nothing to save, and nothing to put back
      expect(tester.widget<FilledButton>(find.byKey(const ValueKey('powers-save'))).onPressed, isNull);
      expect(tester.widget<TextButton>(find.byKey(const ValueKey('powers-reset'))).onPressed, isNull);
    });

    testWidgets('a tap hands a power out, Save counts the changes and the hub keeps them', (tester) async {
      final left = <Powers?>[];
      final t = await pumpPowers(tester, left: left, size: wholeTable);
      await tapKey(tester, 'power:void:bartender');
      expect(lit(tester, 'void', 'bartender'), isTrue);
      expect(find.text('Save 1 change'), findsOneWidget);
      await tapKey(tester, 'power:reports:host');
      await tapKey(tester, 'power:take_tables:bartender'); // and one taken back
      expect(find.text('Save 3 changes'), findsOneWidget);
      await tapKey(tester, 'power:reports:host'); // tapped back: no change after all
      expect(find.text('Save 2 changes'), findsOneWidget);
      expect(t.hub.powersAuth, isNull, reason: 'nothing is sent before Save');

      await tapKey(tester, 'powers-save');
      expect(find.byType(PowersScreen), findsNothing);
      expect(t.hub.powersAuth, 'Bearer tok-admin');
      expect(t.hub.powers!['void'], ['bartender']);
      expect(t.hub.powers!['take_tables'], ['server']);
      expect(t.hub.powers!['reports'], isEmpty);
      expect(t.hub.powers!['assign_tables'], ['host']);
      expect(left.single!.holds('bartender', 'void'), isTrue);
      expect(t.api.powers.value, left.single); // this screen's own menu follows at once
    });

    testWidgets('As it started puts every button back', (tester) async {
      final t = await pumpPowers(
        tester,
        size: wholeTable,
        hub: (hub) => hub.powers = {
          ...hub.powers!,
          'void': ['bartender', 'server'],
          'take_tables': <String>[],
        },
      );
      expect((lit(tester, 'void', 'server'), lit(tester, 'take_tables', 'server')), (true, false));
      expect(find.text('Save'), findsOneWidget);
      await tapKey(tester, 'powers-reset');
      expect((lit(tester, 'void', 'server'), lit(tester, 'void', 'bartender')), (false, false));
      expect((lit(tester, 'take_tables', 'server'), lit(tester, 'take_tables', 'bartender')), (true, true));
      expect(find.text('Save 4 changes'), findsOneWidget);
      expect(tester.widget<TextButton>(find.byKey(const ValueKey('powers-reset'))).onPressed, isNull);
      await tapKey(tester, 'powers-save');
      expect(Powers(t.hub.powers!), Powers.standard);
    });

    testWidgets('what the hub refuses is said, and the screen keeps the changes', (tester) async {
      final left = <Powers?>[];
      final t = await pumpPowers(
        tester,
        size: wholeTable,
        hub: (hub) => hub.refusePowers = 'void: unknown role: chef',
        left: left,
      );
      await tapKey(tester, 'power:void:kitchen');
      await tapKey(tester, 'powers-save');
      expect(find.byType(PowersScreen), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const ValueKey('powers-message'))).data, 'void: unknown role: chef');
      expect(lit(tester, 'void', 'kitchen'), isTrue);
      expect(t.hub.powers!['void'], isEmpty);
      expect(left, isEmpty);
      // and it can be tried again
      t.hub.refusePowers = null;
      await tapKey(tester, 'powers-save');
      expect(t.hub.powers!['void'], ['kitchen']);
    });

    testWidgets('a token that is no manager is told only a manager changes the table', (tester) async {
      final t = await terminal(tester);
      tester.view.physicalSize = wholeTable;
      final table = (await t.api.powersTable())!;
      await tester.pumpWidget(
        MaterialApp(
          home: PowersScreen(api: t.api, token: 'tok-s4', powers: table),
        ),
      );
      await tapKey(tester, 'power:void:host');
      await tapKey(tester, 'powers-save');
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('powers-message'))).data,
        'Only a manager or an owner changes who may do what.',
      );
      expect(t.hub.powers!['void'], isEmpty);
      expect(t.api.powers.value.holds('host', 'void'), isFalse);
    });

    testWidgets('leaving with changes not saved asks first', (tester) async {
      final left = <Powers?>[];
      final t = await pumpPowers(tester, left: left, size: wholeTable);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(PowersScreen), findsNothing, reason: 'nothing changed: nothing to ask');
      expect(left, [null]);

      await tapKey(tester, 'open');
      await tapKey(tester, 'power:guests:server');
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('Leave without saving?'), findsOneWidget);
      await tester.tap(find.text('Keep editing'));
      await tester.pumpAndSettle();
      expect(find.byType(PowersScreen), findsOneWidget);
      expect(lit(tester, 'guests', 'server'), isTrue);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tapKey(tester, 'powers-discard');
      expect(find.byType(PowersScreen), findsNothing);
      expect(t.hub.powers!['guests'], isEmpty);
      expect(t.hub.powersAuth, isNull);
    });

    testWidgets('it fits a 320-wide phone with large text', (tester) async {
      await pumpPowers(tester, size: const Size(320, 568), textScale: 1.3);
      expect(find.text('Approve a void'), findsOneWidget);
      // the last row comes up, and its buttons are whole
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('power:menu:kitchen')),
        300,
        scrollable: find.descendant(of: find.byType(PowersScreen), matching: find.byType(Scrollable)).first,
      );
      await tester.pumpAndSettle();
      final chip = tester.getRect(find.byKey(const ValueKey('power:menu:kitchen')));
      expect(chip.left >= 0 && chip.right <= 320, isTrue);
      await tapKey(tester, 'power:menu:kitchen');
      expect(find.text('Save 1 change'), findsOneWidget);
      final save = tester.getRect(find.byKey(const ValueKey('powers-save')));
      expect(save.right <= 320 && save.bottom <= 568, isTrue);
    });
  });

  group('Location', () {
    testWidgets('a manager finds the row, what it hands out, and the screen behind it', (tester) async {
      final t = await pumpLocation(tester, holds: everything);
      expect(find.text('Location settings'), findsOneWidget);
      String row() => tester
          .widget<Text>(find.descendant(of: find.byKey(const ValueKey('powers')), matching: find.byType(Text)).last)
          .data!;
      expect(row(), 'As it started: managers and owners approve and open the back office');
      await tapKey(tester, 'powers');
      expect(find.byType(PowersScreen), findsOneWidget);
      await tapKey(tester, 'power:void:bartender');
      await tapKey(tester, 'powers-save');
      expect(find.byType(PowersScreen), findsNothing);
      expect(find.text('Who may do what saved'), findsOneWidget);
      expect(row(), 'Approve a void: Bartenders');
      expect(t.hub.powers!['void'], ['bartender']);
    });

    testWidgets('an older hub has no table: the row says so and opens nothing', (tester) async {
      await pumpLocation(tester, hub: (hub) => hub.powers = null);
      expect(find.text('The hub has not answered about who may do what (an older hub: update it)'), findsOneWidget);
      await tapKey(tester, 'powers');
      expect(find.byType(PowersScreen), findsNothing);
      // and everything else is where it was: a token there is a manager's
      for (final key in ['board', 'day-report', 'guests-report', 'shift-notes', 'quote-times', 'voids']) {
        expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
      }
    });

    testWidgets('a host handed the reports finds the reports and none of the settings', (tester) async {
      await pumpLocation(tester, holds: {'assign_tables', 'reports'});
      expect(find.text('Location'), findsOneWidget);
      expect(find.text('Location settings'), findsNothing);
      for (final key in ['board', 'day-report', 'sales-report', 'dishes-report', 'adjustments-report']) {
        expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
      }
      for (final key in [
        'guests-report',
        'waste-report',
        'shift-notes',
        'logbook',
        'powers',
        'coursing-enabled',
        'quote-times',
        'to-go-question',
        'table-timers',
        'voids',
        'time-clock-enabled',
        'time-clock-hours',
        'desk-add',
      ]) {
        expect(find.byKey(ValueKey(key)), findsNothing, reason: key);
      }
      expect(find.text('Printers'), findsNothing);
      expect(find.text('Sign in by face'), findsNothing);
    });

    testWidgets('each power under Location shows its own rows', (tester) async {
      const rows = {
        'guests': ['guests-report'],
        'waste': ['waste-report'],
        'notes': ['shift-notes'],
        'logbook': ['logbook'],
        'time_clock': ['time-clock-hours'],
        'reports': ['day-report', 'sales-report', 'dishes-report', 'adjustments-report'],
      };
      for (final power in rows.keys) {
        await pumpLocation(tester, holds: {power});
        for (final entry in rows.entries) {
          for (final key in entry.value) {
            expect(
              find.byKey(ValueKey(key)),
              entry.key == power ? findsOneWidget : findsNothing,
              reason: '$key with $power',
            );
          }
        }
        expect(find.byKey(const ValueKey('board')), findsOneWidget);
        expect(find.byKey(const ValueKey('powers')), findsNothing);
        expect(find.byKey(const ValueKey('time-clock-enabled')), findsNothing);
        await tester.pumpWidget(const SizedBox());
      }
    });

    testWidgets('a manager finds every row where it always was', (tester) async {
      await pumpLocation(
        tester,
        holds: everything,
        hub: (hub) => hub.timeClock = {'enabled': false, 'breaks_paid': false, 'week_starts': 'mon'},
      );
      for (final key in [
        'board',
        'day-report',
        'sales-report',
        'dishes-report',
        'guests-report',
        'waste-report',
        'shift-notes',
        'logbook',
        'powers',
        'coursing-enabled',
        'quote-times',
        'voids',
        'adjustments-report',
        'time-clock-hours',
      ]) {
        expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
      }
      // the report of what came off stays in the voids' card for a manager, once
      final card = find.ancestor(of: find.byKey(const ValueKey('voids')), matching: find.byType(Card));
      expect(find.descendant(of: card, matching: find.byKey(const ValueKey('adjustments-report'))), findsOneWidget);
    });
  });

  group('the menu of the orders screen', () {
    testWidgets('a host sees what a host always saw, and what the location handed the hosts', (tester) async {
      final t = await pumpMenu(tester, 'host');
      for (final entry in ['Kitchen rush', 'Location', 'Menu editor']) {
        expect(find.byTooltip(entry), findsNothing, reason: entry);
      }
      await stop(tester);

      await pumpMenu(tester, 'host', hub: (hub) => hub.powers!['rush'] = ['host']);
      expect(find.byTooltip('Kitchen rush'), findsOneWidget);
      expect(find.byTooltip('Location'), findsNothing);
      expect(find.byTooltip('Menu editor'), findsNothing);
      await stop(tester);

      await pumpMenu(tester, 'host', hub: (hub) => hub.powers!['menu'] = ['host']);
      expect(find.byTooltip('Menu editor'), findsOneWidget);
      expect(find.byTooltip('Kitchen rush'), findsNothing);
      expect(find.byTooltip('Location'), findsNothing);
      await stop(tester);

      for (final power in ['reports', 'guests', 'waste', 'notes', 'logbook', 'time_clock']) {
        await pumpMenu(tester, 'host', hub: (hub) => hub.powers![power] = ['host']);
        expect(find.byTooltip('Location'), findsOneWidget, reason: power);
        expect(find.byTooltip('Menu editor'), findsNothing, reason: power);
        await stop(tester);
      }
      // approving on a check, or a table of one's own, opens nothing in the menu
      await pumpMenu(tester, 'host', hub: (hub) => hub.powers!['void'] = ['host']);
      expect(find.byTooltip('Location'), findsNothing);
      await stop(tester);
      expect(t.hub.sessionsFor, isEmpty);
    });

    testWidgets('a manager sees everything on a hub that has the table and on one that has none', (tester) async {
      await pumpMenu(tester, 'manager');
      for (final entry in ['Kitchen rush', 'Location', 'Menu editor']) {
        expect(find.byTooltip(entry), findsOneWidget, reason: entry);
      }
      await stop(tester);
      await pumpMenu(tester, 'owner', hub: (hub) => hub.powers = null);
      for (final entry in ['Kitchen rush', 'Location', 'Menu editor']) {
        expect(find.byTooltip(entry), findsOneWidget, reason: entry);
      }
      await stop(tester);
      await pumpMenu(tester, 'server', hub: (hub) => hub.powers = null);
      for (final entry in ['Kitchen rush', 'Location', 'Menu editor']) {
        expect(find.byTooltip(entry), findsNothing, reason: entry);
      }
      await stop(tester);
    });

    testWidgets('the rush takes the PIN of whoever was handed it, and says so to a PIN that was not', (tester) async {
      final t = await pumpMenu(tester, 'host', hub: (hub) => hub.powers!['rush'] = ['host']);
      await tester.tap(find.byTooltip('Kitchen rush'));
      await tester.pumpAndSettle();
      expect(find.text('PIN'), findsWidgets);
      expect(find.text('Manager PIN'), findsNothing);
      await typePin(tester, '1111', 'Set the rush'); // Amy, a server
      expect(find.text('Only a manager or a host can add minutes to the quotes'), findsOneWidget);
      await typePin(tester, '3333', 'Set the rush'); // Holly, a host
      expect(find.byType(RushSheet), findsOneWidget);
      expect(t.hub.sessionsFor, ['rush', 'rush']);
      expect(t.hub.pins, ['1111', '3333']);
      await stop(tester);
    });

    testWidgets('Location opens for a host handed the reports, with the reports and no settings', (tester) async {
      final t = await pumpMenu(tester, 'host', hub: (hub) => hub.powers!['reports'] = ['host']);
      await tester.tap(find.byTooltip('Location'));
      await tester.pumpAndSettle();
      expect(find.text('Manager PIN'), findsNothing);
      await typePin(tester, '1111', 'Open location settings'); // Amy has nothing there
      expect(find.text('Nothing under Location is open to this PIN'), findsOneWidget);
      await typePin(tester, '3333', 'Open location settings');
      expect(find.byType(LocationSettingsScreen), findsOneWidget);
      expect(tester.widget<LocationSettingsScreen>(find.byType(LocationSettingsScreen)).holds, {
        'assign_tables',
        'reports',
      });
      expect(tester.widget<LocationSettingsScreen>(find.byType(LocationSettingsScreen)).token, 'tok-s4');
      expect(find.byKey(const ValueKey('day-report')), findsOneWidget);
      expect(find.byKey(const ValueKey('powers')), findsNothing);
      expect(find.byKey(const ValueKey('quote-times')), findsNothing);
      expect(t.hub.sessionsFor, [null, null]); // Location asks for no one power
      await stop(tester);
    });

    testWidgets("a manager's PIN at a host's screen opens all of Location", (tester) async {
      await pumpMenu(tester, 'host', hub: (hub) => hub.powers!['reports'] = ['host']);
      await tester.tap(find.byTooltip('Location'));
      await tester.pumpAndSettle();
      await typePin(tester, '9999', 'Open location settings');
      expect(find.text('Location settings'), findsOneWidget);
      await bringUp(tester, 'powers'); // under the reports, of which Today is one more
      expect(find.byKey(const ValueKey('powers')), findsOneWidget);
      expect(tester.widget<LocationSettingsScreen>(find.byType(LocationSettingsScreen)).holds, everything);
      await stop(tester);
    });

    testWidgets('on a hub with no table Location is a manager\'s, worded as before', (tester) async {
      final t = await pumpMenu(tester, 'manager', hub: (hub) => hub.powers = null);
      await tester.tap(find.byTooltip('Location'));
      await tester.pumpAndSettle();
      expect(find.text('Manager PIN'), findsOneWidget);
      await typePin(tester, '1111', 'Open location settings');
      expect(find.text('Only a manager can change location settings'), findsOneWidget);
      await typePin(tester, '9999', 'Open location settings');
      expect(tester.widget<LocationSettingsScreen>(find.byType(LocationSettingsScreen)).holds, isNull);
      await bringUp(tester, 'quote-times');
      expect(find.byKey(const ValueKey('quote-times')), findsOneWidget);
      expect(t.hub.pins, ['1111', '9999']);
      await stop(tester);
    });

    testWidgets('a change to the table reaches a screen that is already up', (tester) async {
      // a terminal on a hub with the change feed, as the app runs: the hub says when a setting changed
      SharedPreferences.setMockInitialValues({});
      final settings = Settings(
        device: 't1',
        endpoints: ['http://hub:8000'],
        prefs: await SharedPreferences.getInstance(),
      );
      final hub = Hub()..quotes['rush'] = null;
      final live = LiveHub(hub);
      final api = PosApi(settings, client: live.client);
      final session = Session(api)..staff = const Staff(staffId: 's4', name: 'Holly', role: 'host', method: 'pin');
      final outbox = Outbox(api, settings, store: MemoryStore());
      final photos = PhotoQueue(api, settings, NoCamera(), session, store: MemoryStore());
      tester.view
        ..physicalSize = const Size(1100, 800)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      api.live.start();
      await pumpOrdersOn(tester, Terminal(hub, api, outbox, photos, session, settings));
      live.hello();
      live.beats();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(api.live.isLive, isTrue);
      expect(find.byTooltip('Kitchen rush'), findsNothing);

      hub.powers!['rush'] = ['host']; // a manager hands the hosts the rush at another screen
      live.changed(topics: ['settings']);
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(find.byTooltip('Kitchen rush'), findsOneWidget);

      hub.powers!['rush'] = []; // and takes it back
      live.changed(topics: ['settings']);
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(find.byTooltip('Kitchen rush'), findsNothing);

      await stop(tester);
      live.close();
      api.dispose();
      await tester.pump();
    });
  });

  group('a PIN on a check', () {
    Future<(Terminal, List<String?>)> pumpApproval(WidgetTester tester, {void Function(Hub hub)? hub}) async {
      final t = await terminal(tester);
      hub?.call(t.hub);
      await t.api.readPowers();
      final got = <String?>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: FilledButton(
                key: const ValueKey('ask'),
                onPressed: () async => got.add(
                  await showDialog<String>(
                    context: context,
                    builder: (_) => ApprovalDialog(
                      api: t.api,
                      device: 't1',
                      orderId: 'o1',
                      what: 'Voiding Duck (Kitchen error)',
                      purpose: 'void',
                    ),
                  ),
                ),
                child: const Text('Ask'),
              ),
            ),
          ),
        ),
      );
      await tapKey(tester, 'ask');
      return (t, got);
    }

    testWidgets("it is a manager's while nobody else holds the power, worded as before", (tester) async {
      final (t, got) = await pumpApproval(tester);
      expect(find.text('Manager PIN'), findsOneWidget);
      expect(find.text('Voiding Duck (Kitchen error) needs a manager.'), findsOneWidget);
      await typePin(tester, '2222', 'Approve');
      expect(find.text('Only a manager can approve this'), findsOneWidget);
      await typePin(tester, '9999', 'Approve');
      expect(got, ['tok-o1']);
      expect(t.hub.purposes, ['void', 'void']);
    });

    testWidgets('it says whose PIN it takes once the location handed the power out', (tester) async {
      final (t, got) = await pumpApproval(tester, hub: (hub) => hub.powers!['void'] = ['bartender']);
      expect(find.text('Manager PIN'), findsNothing);
      expect(find.text('Voiding Duck (Kitchen error) needs a manager or a bartender.'), findsOneWidget);
      await typePin(tester, '1111', 'Approve'); // Amy, a server
      expect(find.text('Only a manager or a bartender can approve this'), findsOneWidget);
      await typePin(tester, '2222', 'Approve'); // Ben, a bartender
      expect(got, ['tok-o1']);
      expect(t.hub.pins, ['1111', '2222']);
    });
  });

  group('the notes for the shift', () {
    testWidgets('whoever was handed the notes is offered to write them, behind their own PIN', (tester) async {
      final t = await terminal(tester, role: 'host');
      const holly = Staff(staffId: 's4', name: 'Holly', role: 'host', method: 'pin');
      Future<void> pump() async {
        await t.api.readPowers();
        await tester.pumpWidget(
          MaterialApp(
            home: ShiftNotesScreen(api: t.api, device: 't1', staff: holly),
          ),
        );
        await tester.pumpAndSettle();
      }

      await pump();
      expect(find.byKey(const ValueKey('notes-unlock')), findsNothing);
      await tester.pumpWidget(const SizedBox());

      t.hub.powers!['notes'] = ['host'];
      await pump();
      await tapKey(tester, 'notes-unlock');
      await typePin(tester, '1111', 'Change the notes'); // Amy was not handed them
      expect(find.text('Only a manager or a host can write or change the notes'), findsOneWidget);
      await typePin(tester, '3333', 'Change the notes');
      expect(find.byKey(const ValueKey('note-write')), findsOneWidget);
      expect(t.hub.sessionsFor, ['notes', 'notes']);
    });
  });
}
