import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/camera.dart';
import 'package:pos_app/screens/location_settings_screen.dart';
import 'package:pos_app/screens/signin_screen.dart';
import 'package:pos_app/screens/time_clock_card.dart';
import 'package:pos_app/screens/time_clock_screen.dart';
import 'package:pos_app/session.dart';
import 'package:pos_app/settings.dart';
import 'package:pos_app/timeclock.dart';

import 'hub.dart';
import 'location_rows.dart';
import 'idle_lock_test.dart' show Desk, amy, pumpApp;

/// The time clock (docs/time-clock.md): a person clocks in and out and takes breaks with their own PIN, from
/// the sign-in pad or from inside the POS; a manager reads the hours, corrects a shift with a reason, takes
/// one off or writes one in; and the location turns the clock on under Location settings.

/// Monday 16 November 2026, on the device's own clock.
DateTime at(int hour, [int minute = 0, int day = 16]) => DateTime(2026, 11, day, hour, minute);
int ms(int hour, [int minute = 0, int day = 16]) => at(hour, minute, day).millisecondsSinceEpoch;

Map<String, dynamic> clockOn({bool breaksPaid = false, String week = 'mon'}) => {
  'enabled': true,
  'breaks_paid': breaksPaid,
  'week_starts': week,
};

/// A shift as the pretend hub holds it.
Map<String, dynamic> shift(
  String id,
  String staffId,
  String name,
  String role,
  int inMs, {
  int? outMs,
  List<(int, int?)> breaks = const [],
  String? closedBy,
  bool edited = false,
  bool removed = false,
}) => {
  'shift_id': id,
  'staff_id': staffId,
  'name': name,
  'role': role,
  'in_ms': inMs,
  'out_ms': outMs,
  'breaks': [
    for (final (start, end) in breaks) <String, dynamic>{'start_ms': start, 'end_ms': end},
  ],
  'closed_by': closedBy ?? (outMs == null ? '' : 'self'),
  'edited': edited,
  'removed': removed,
  'log': [
    {'entry_id': 'in-$id', 'action': 'in', 'at_ms': inMs, 'by_id': staffId, 'by': name, 'device': 'mac1', 'reason': ''},
    if (closedBy == 'system')
      {'entry_id': 'auto-$id', 'action': 'auto_out', 'at_ms': outMs, 'by_id': '', 'by': '', 'device': '', 'reason': ''},
  ],
};

/// A device at the sign-in pad, with a hub that uses the time clock.
class Pad {
  Pad({bool on = true}) {
    hub.timeClock = on ? clockOn() : {'enabled': false, 'breaks_paid': false, 'week_starts': 'mon'};
  }

  final hub = Hub();
  final settings = Settings(device: 't1', endpoints: ['http://hub:8000']);
  late final api = PosApi(settings, client: MockClient(hub.handle));
  late final session = Session(api);

  List<String> get actions => [for (final p in hub.punches) p['action'] as String];
}

Future<void> pumpPad(WidgetTester tester, Pad pad, {Size size = const Size(900, 760)}) async {
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: SignInScreen(session: pad.session, settings: pad.settings, camera: NoCamera()),
    ),
  );
  await tester.pumpAndSettle();
}

/// Taps the digits of a PIN on the pad; the fourth sends it.
Future<void> tapPin(WidgetTester tester, String pin) async {
  for (final digit in pin.split('')) {
    await tester.tap(find.widgetWithText(FilledButton, digit));
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

Future<void> tapKey(WidgetTester tester, String key) async {
  if (find.byKey(ValueKey(key)).evaluate().isEmpty) {
    // further down a list that builds its rows as they come into view
    await tester.scrollUntilVisible(find.byKey(ValueKey(key)), 150, scrollable: find.byType(Scrollable).first);
  }
  await tester.ensureVisible(find.byKey(ValueKey(key)));
  await tester.tap(find.byKey(ValueKey(key)));
  await tester.pumpAndSettle();
}

/// A manager's change of a shift as the hub got it: the method, the path and what it carried.
List<Object?> change((String, String, Map<String, dynamic>) got) => [got.$1, got.$2, got.$3];

String said(WidgetTester tester) => tester.widget<Text>(find.byKey(const ValueKey('clock-said'))).data!;
String? under(WidgetTester tester) {
  final found = find.byKey(const ValueKey('clock-under'));
  return found.evaluate().isEmpty ? null : tester.widget<Text>(found).data;
}

/// The manager's hours screen at eight in the evening of the 16th, with pickers that answer what the test
/// says next.
class Hours {
  Hours(this.t);
  final Terminal t;
  final days = <DateTime>[];
  final times = <TimeOfDay>[];
  final helps = <String?>[];

  Future<DateTime?> pickDay(BuildContext context, DateTime from) async => days.isEmpty ? null : days.removeAt(0);
  Future<TimeOfDay?> pickTime(BuildContext context, TimeOfDay from, {String? help}) async {
    helps.add(help);
    return times.isEmpty ? null : times.removeAt(0);
  }
}

Future<Hours> pumpHours(WidgetTester tester, {Size size = const Size(1100, 800)}) async {
  final t = await terminal(tester);
  t.hub
    ..timeClock = clockOn()
    ..clockNow = ms(20);
  tester.view.physicalSize = size;
  return Hours(t);
}

Future<void> showHours(WidgetTester tester, Hours h, {DateTime? now}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: TimeClockScreen(
        api: h.t.api,
        token: 'tok-admin',
        device: 't1',
        now: () => now ?? at(20),
        pickDay: h.pickDay,
        pickTime: h.pickTime,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('what the clock counts', () {
    test('a length of time is said in hours and minutes, and in the decimal hours payroll takes', () {
      expect(hoursMinutes(0), '0 min');
      expect(hoursMinutes(59 * 60000 + 59999), '59 min');
      expect(hoursMinutes(2 * 3600000), '2 h');
      expect(hoursMinutes(7 * 3600000 + 32 * 60000), '7 h 32 min');
      expect(hoursMinutes(-5), '0 min');
      expect(decimalHours(7 * 3600000 + 32 * 60000), '7.53');
      expect(decimalHours(38 * 3600000 + 15 * 60000), '38.25');
      expect(decimalHours(-1), '0.00');
    });

    test('a day of the clock runs from 4 AM, and the pay week from its first day at 4 AM', () {
      expect(clockDay(at(20)), at(4));
      expect(clockDay(at(1, 30)), at(4, 0, 15)); // the small hours are still last night
      expect(clockDay(at(4)), at(4));
      // the 16th is a Monday
      expect(clockWeek(at(20), 'mon'), at(4, 0, 16));
      expect(clockWeek(at(20), 'sun'), at(4, 0, 15));
      expect(clockWeek(at(20, 0, 19), 'mon'), at(4, 0, 16));
      expect(clockWeek(at(2, 0, 16), 'mon'), at(4, 0, 9)); // Monday before 4 AM is last week's Sunday night
      expect(clockWeek(at(20, 0, 15), 'sun'), at(4, 0, 15));
    });

    test('a time picked for a clock-out is the first one after the clock-in, past midnight too', () {
      expect(firstAfter(at(16, 2), 22, 30), at(22, 30));
      expect(firstAfter(at(16, 2), 1, 10), at(1, 10, 17));
      expect(firstAfter(at(16, 2), 16, 2), at(16, 2));
    });

    test('the setting, a person\'s answer and the report are read as the hub writes them', () {
      final setting = ClockSetting.fromJson({'enabled': true, 'breaks_paid': true, 'week_starts': 'sun'});
      expect((setting.enabled, setting.breaksPaid, setting.weekStarts), (true, true, 'sun'));
      expect(setting.copyWith(enabled: false).toJson(), {'enabled': false, 'breaks_paid': true, 'week_starts': 'sun'});
      expect(ClockSetting.fromJson({'revision': 0}).enabled, isFalse); // an answer that is not a setting: off

      final stand = ClockStand.fromJson({
        'staff': {'staff_id': 's1', 'name': 'Amy', 'role': 'server', 'method': 'pin', 'preferences': {}},
        'breaks_paid': false,
        'state': 'break',
        'since_ms': ms(19, 15),
        'now_ms': ms(19, 27),
        'shift': {
          'shift_id': 'sh1',
          'staff_id': 's1',
          'name': 'Amy',
          'role': 'server',
          'in_ms': ms(16, 2),
          'out_ms': null,
          'breaks': [
            {'start_ms': ms(19, 15), 'end_ms': null},
          ],
          'state': 'break',
          'worked_ms': 193 * 60000,
          'break_ms': 12 * 60000,
          'span_ms': 205 * 60000,
        },
        'unended': null,
        'punched': 'break_start',
      });
      expect((stand.name, stand.role, stand.state, stand.punched), ('Amy', 'server', 'break', 'break_start'));
      expect((stand.shift!.open, stand.shift!.breaks.single.endMs, stand.unended), (true, null, null));

      final report = ClockReport.fromJson({
        'now_ms': ms(20),
        'breaks_paid': false,
        'on_now': [],
        'people': [
          {'staff_id': 's1', 'name': 'Amy', 'role': 'server', 'worked_ms': 60000, 'break_ms': 0, 'shifts': 2},
        ],
        'worked_ms': 60000,
        'unended': 1,
        'shifts': [
          {'shift_id': 'a', 'in_ms': 1000, 'log': []},
          {
            'shift_id': 'b',
            'in_ms': 2000,
            'log': [
              {'action': 'edit', 'at_ms': 3000, 'by': 'Mike', 'reason': 'left at ten'},
            ],
          },
        ],
        'week_starts': 'sun',
      });
      expect([for (final s in report.newestFirst) s.shiftId], ['b', 'a']);
      expect((report.people.single.shifts, report.unended, report.weekStarts, report.enabled), (2, 1, 'sun', true));
      final entry = report.newestFirst.first.log.single;
      expect((entry.what, entry.byManager, entry.reason), ('Corrected', true, 'left at ten'));
      expect(const ClockEntry(action: 'auto_out', atMs: 1).what, contains('nobody clocked out'));
    });
  });

  group('the calls', () {
    testWidgets('carry the PIN, the punch and its name, and for a manager the token', (tester) async {
      final t = await terminal(tester);
      expect(await t.api.clockSetting(), isNull); // a hub older than the clock
      t.hub.timeClock = clockOn();
      expect((await t.api.clockSetting())!.enabled, isTrue);

      final saved = await t.api.saveClockSetting('tok-admin', const ClockSetting(enabled: true, breaksPaid: true));
      expect((saved.breaksPaid, t.hub.timeClockAuth), (true, 'Bearer tok-admin'));

      final stand = await t.api.clockPunch(device: 't1', pin: '1111', action: 'in', punchId: 'p1');
      expect(t.hub.punches.single, {'device': 't1', 'pin': '1111', 'action': 'in', 'punch_id': 'p1'});
      expect((stand.state, stand.punched, stand.shift!.inMs), ('in', 'in', t.hub.clockNow));
      await t.api.clockPunch(device: 't1', pin: '1111', action: 'in', punchId: 'p1'); // sent again: one shift
      expect(t.hub.shifts, hasLength(1));

      final report = await t.api.clockReport('tok-admin', sinceMs: ms(4), untilMs: ms(4, 0, 17));
      expect(t.hub.clockAsks.single, {'since': '${ms(4)}', 'until': '${ms(4, 0, 17)}'});
      expect((t.hub.clockAuth, report.onNow.single.name), ('Bearer tok-admin', 'Amy'));

      final added = await t.api.addShift(
        'tok-admin',
        staffId: 's2',
        inMs: ms(11),
        outMs: ms(15),
        breaks: [ClockBreak(startMs: ms(13), endMs: ms(13, 30))],
        reason: 'forgot to clock in',
        device: 't1',
      );
      expect(change(t.hub.shiftChanges.last), [
        'POST',
        '/timeclock/shifts',
        {
          'staff_id': 's2',
          'in_ms': ms(11),
          'out_ms': ms(15),
          'breaks': [
            {'start_ms': ms(13), 'end_ms': ms(13, 30)},
          ],
          'reason': 'forgot to clock in',
          'device': 't1',
        },
      ]);
      // (breaks were set to count, above: the half hour stays in the four hours)
      expect((added.name, added.workedMs, added.breakMs), ('Ben', 240 * 60000, 30 * 60000));

      await t.api.editShift('tok-admin', added.shiftId, inMs: ms(11), outMs: ms(16), reason: 'stayed', device: 't1');
      expect((t.hub.shiftChanges.last.$1, t.hub.shiftChanges.last.$2), ('PUT', '/timeclock/shifts/${added.shiftId}'));
      expect(t.hub.shiftChanges.last.$3['breaks'], isEmpty);

      final gone = await t.api.removeShift('tok-admin', added.shiftId, reason: 'a test punch', device: 't1');
      expect(change(t.hub.shiftChanges.last), [
        'DELETE',
        '/timeclock/shifts/${added.shiftId}',
        {'reason': 'a test punch', 'device': 't1'},
      ]);
      expect((gone.removed, t.hub.clockAuth), (true, 'Bearer tok-admin'));
    });
  });

  group('at the sign-in pad', () {
    testWidgets('a location that does not use the clock shows none of it', (tester) async {
      final pad = Pad(on: false);
      await pumpPad(tester, pad);
      expect(find.byKey(const ValueKey('time-clock')), findsNothing);
      await tapPin(tester, '1111');
      expect(pad.session.staff?.name, 'Amy');
      expect(pad.hub.punches, isEmpty);
    });

    testWidgets('a hub older than the clock shows none of it either', (tester) async {
      final pad = Pad()..hub.timeClock = null;
      await pumpPad(tester, pad);
      expect(find.byKey(const ValueKey('time-clock')), findsNothing);
    });

    testWidgets('Time clock, a PIN, Clock in: the card says the time and nobody is signed in', (tester) async {
      final pad = Pad();
      await pumpPad(tester, pad);
      expect(find.text('Time clock'), findsOneWidget); // the button in the bar
      expect(find.byKey(const ValueKey('clock-note')), findsNothing);

      await tapKey(tester, 'time-clock');
      expect(find.byKey(const ValueKey('clock-note')), findsOneWidget);
      expect(find.text('Time clock · t1'), findsOneWidget);
      expect(find.text('Back to sign in'), findsOneWidget);

      await tapPin(tester, '1111');
      expect(find.byKey(const ValueKey('clock-card')), findsOneWidget);
      expect(find.text('Amy'), findsOneWidget);
      expect(find.text('Server · Time clock'), findsOneWidget);
      expect((said(tester), under(tester)), ('Not on the clock', null));
      expect(find.byKey(const ValueKey('clock-in')), findsOneWidget);
      expect(find.byKey(const ValueKey('clock-out')), findsNothing);
      expect(find.text('Enter your PIN'), findsNothing); // the card took the pad's place

      await tapKey(tester, 'clock-in');
      expect(said(tester), 'Clocked in at 4:02 PM');
      expect(pad.actions, ['state', 'in']);
      expect(pad.hub.punches.last['punch_id'], isNotEmpty);
      expect(find.byKey(const ValueKey('clock-in')), findsNothing); // one punch, then it is done
      expect(find.byKey(const ValueKey('clock-orders')), findsOneWidget);

      await tapKey(tester, 'clock-done');
      expect(find.byKey(const ValueKey('clock-card')), findsNothing);
      expect(find.text('Sign in · t1'), findsOneWidget); // back to signing in
      expect(find.byKey(const ValueKey('clock-note')), findsNothing);
      expect(pad.session.signedIn, isFalse);
      expect(pad.hub.shifts.single['in_ms'], pad.hub.clockNow); // the hub's time, not this screen's
    });

    testWidgets('on the clock: a break, back from it, and out, each with what the shift has come to', (tester) async {
      final pad = Pad();
      pad.hub.shifts.add(shift('sh1', 's1', 'Amy', 'server', ms(16, 2)));
      pad.hub.clockNow = ms(19, 15);
      await pumpPad(tester, pad);

      await tapKey(tester, 'time-clock');
      await tapPin(tester, '1111');
      expect((said(tester), under(tester)), ('On the clock since 4:02 PM', '3 h 13 min worked so far'));
      expect(find.byKey(const ValueKey('clock-in')), findsNothing);
      await tapKey(tester, 'clock-break_start');
      expect(said(tester), 'Break started at 7:15 PM');
      expect(find.byKey(const ValueKey('clock-orders')), findsNothing); // on a break: nothing to go on to
      await tapKey(tester, 'clock-done');

      pad.hub.clockNow = ms(19, 45);
      await tapKey(tester, 'time-clock');
      await tapPin(tester, '1111');
      expect((said(tester), under(tester)), ('On a break since 7:15 PM', '30 min so far'));
      expect(find.byKey(const ValueKey('clock-break_start')), findsNothing);
      await tapKey(tester, 'clock-break_end');
      expect(said(tester), 'Back from the break at 7:45 PM');
      await tapKey(tester, 'clock-done');

      pad.hub.clockNow = ms(22, 31);
      await tapKey(tester, 'time-clock');
      await tapPin(tester, '1111');
      expect(under(tester), '5 h 59 min worked, 30 min on breaks so far');
      await tapKey(tester, 'clock-out');
      expect(said(tester), 'Clocked out at 10:31 PM');
      expect(under(tester), 'This shift: 5 h 59 min worked, 30 min on breaks');
      expect(pad.actions, ['state', 'break_start', 'state', 'break_end', 'state', 'out']);
      expect(pad.session.signedIn, isFalse);
    });

    testWidgets('where breaks count, the card says so', (tester) async {
      final pad = Pad()..hub.timeClock = clockOn(breaksPaid: true);
      pad.hub.shifts.add(shift('sh1', 's1', 'Amy', 'server', ms(16), breaks: [(ms(18), ms(18, 30))]));
      pad.hub.clockNow = ms(20);
      await pumpPad(tester, pad);
      await tapKey(tester, 'time-clock');
      await tapPin(tester, '1111');
      expect(under(tester), '4 h worked, 30 min on breaks (counted as worked) so far');
    });

    testWidgets('Go to orders signs the person in with the PIN they clocked in with', (tester) async {
      final pad = Pad();
      await pumpPad(tester, pad);
      await tapKey(tester, 'time-clock');
      await tapPin(tester, '2222');
      expect(find.text('Bartender · Time clock'), findsOneWidget);
      await tapKey(tester, 'clock-in');
      await tapKey(tester, 'clock-orders');
      expect(
        (pad.session.staff?.name, pad.session.staff?.role, pad.session.staff?.method),
        ('Ben', 'bartender', 'pin'),
      );
    });

    testWidgets('a wrong PIN stays at the clock; Back to sign in leaves it', (tester) async {
      final pad = Pad();
      await pumpPad(tester, pad);
      await tapKey(tester, 'time-clock');
      await tapPin(tester, '4321');
      expect(find.text('Wrong PIN'), findsOneWidget);
      expect(find.byKey(const ValueKey('clock-card')), findsNothing);
      expect(find.byKey(const ValueKey('clock-note')), findsOneWidget);
      expect(pad.session.signedIn, isFalse);

      await tapKey(tester, 'time-clock'); // Back to sign in
      expect(find.byKey(const ValueKey('clock-note')), findsNothing);
      await tapPin(tester, '1111');
      expect(pad.session.staff?.name, 'Amy');
      expect(pad.actions, ['state']); // the wrong PIN's look alone: the sign-in was a sign-in
    });

    testWidgets('a punch nothing answered is the same punch when tapped again, and counts once', (tester) async {
      final pad = Pad();
      await pumpPad(tester, pad);
      await tapKey(tester, 'time-clock');
      await tapPin(tester, '1111');
      pad.hub.deaf = true; // the punch gets there; its answer does not
      await tapKey(tester, 'clock-in');
      expect(find.text('The hub did not answer. Tap again to make sure it is recorded.'), findsOneWidget);
      expect(find.byKey(const ValueKey('clock-in')), findsOneWidget);
      expect(pad.hub.shifts, hasLength(1));

      pad.hub.deaf = false;
      await tapKey(tester, 'clock-in');
      expect(said(tester), 'Clocked in at 4:02 PM');
      expect(find.byKey(const ValueKey('clock-error')), findsNothing);
      final ins = [
        for (final p in pad.hub.punches)
          if (p['action'] == 'in') p['punch_id'],
      ];
      expect(ins, hasLength(2));
      expect(ins.first, ins.last); // the same punch, sent twice
      expect(pad.hub.shifts, hasLength(1)); // and one shift
    });

    testWidgets('with the hub away the pad says so, and the card too', (tester) async {
      final pad = Pad();
      await pumpPad(tester, pad);
      await tapKey(tester, 'time-clock');
      pad.hub.down = true;
      await tapPin(tester, '1111');
      expect(find.text('The hub is not answering'), findsOneWidget);
      pad.hub.down = false;
      await tapPin(tester, '1111');
      pad.hub.down = true;
      await tapKey(tester, 'clock-in');
      expect(find.byKey(const ValueKey('clock-error')), findsOneWidget);
      expect(pad.hub.shifts, isEmpty);
      pad.hub.down = false;
    });

    testWidgets('a punch that no longer fits says why and shows where the person stands now', (tester) async {
      final pad = Pad();
      await pumpPad(tester, pad);
      await tapKey(tester, 'time-clock');
      await tapPin(tester, '1111');
      // clocked in at another screen while this card was up
      await pad.api.clockPunch(device: 't2', pin: '1111', action: 'in', punchId: 'other');
      await tapKey(tester, 'clock-in');
      expect(find.text('Amy is already on the clock'), findsOneWidget);
      expect(said(tester), 'On the clock since 4:02 PM');
      expect(find.byKey(const ValueKey('clock-out')), findsOneWidget);
      expect(find.byKey(const ValueKey('clock-in')), findsNothing);
    });

    testWidgets('a shift nobody clocked out of is told to the person', (tester) async {
      final pad = Pad();
      pad.hub.unended['s1'] = shift(
        'old',
        's1',
        'Amy',
        'server',
        ms(17, 0, 13),
        outMs: ms(4, 0, 14),
        closedBy: 'system',
      );
      await pumpPad(tester, pad);
      await tapKey(tester, 'time-clock');
      await tapPin(tester, '1111');
      final note = tester.widget<Text>(
        find.descendant(of: find.byKey(const ValueKey('clock-unended')), matching: find.byType(Text)),
      );
      expect(note.data, contains('Nobody clocked you out on Fri, Nov 13.'));
      expect(note.data, contains('counted to 4:00 AM'));
      expect(find.byKey(const ValueKey('clock-in')), findsOneWidget); // and they can still clock in
    });

    testWidgets('a card left alone closes itself', (tester) async {
      final pad = Pad();
      await pumpPad(tester, pad);
      await tapKey(tester, 'time-clock');
      await tapPin(tester, '1111');
      expect(find.byKey(const ValueKey('clock-card')), findsOneWidget);
      await tester.pump(const Duration(seconds: 29));
      expect(find.byKey(const ValueKey('clock-card')), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('clock-card')), findsNothing);
      expect(find.text('Sign in · t1'), findsOneWidget);
      expect(pad.actions, ['state']); // nothing was punched
    });

    testWidgets('the clock turned off while a PIN is typed: the pad says so and signs in again', (tester) async {
      final pad = Pad();
      await pumpPad(tester, pad);
      await tapKey(tester, 'time-clock');
      pad.hub.timeClock = {...clockOn(), 'enabled': false};
      await tapPin(tester, '1111');
      expect(find.text('The time clock is off'), findsOneWidget);
      expect(find.byKey(const ValueKey('time-clock')), findsNothing);
      expect(find.byKey(const ValueKey('clock-note')), findsNothing);
    });

    testWidgets('on a locked screen the clock works and the screen stays locked', (tester) async {
      final desk = Desk(minutes: 5);
      desk.hub.timeClock = clockOn();
      desk.hub.shifts.add(shift('sh1', 's2', 'Ben', 'bartender', ms(11)));
      tester.view
        ..physicalSize = const Size(900, 800)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      desk.session.applySignIn(amy);
      await pumpApp(tester, desk, realPad: true);
      desk.session.lock();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('locked-note')), findsOneWidget);

      await tapKey(tester, 'time-clock');
      await tapPin(tester, '2222');
      expect(find.text('Ben'), findsOneWidget);
      await tapKey(tester, 'clock-out');
      expect(said(tester), startsWith('Clocked out at'));
      expect(find.byKey(const ValueKey('clock-orders')), findsNothing); // off the clock: Done is all
      await tapKey(tester, 'clock-done');
      expect(find.byKey(const ValueKey('locked-note')), findsOneWidget);
      expect((desk.session.locked, desk.session.lockedFrom?.name), (true, 'Amy')); // Amy's screen waits as it was
    });

    testWidgets('on a small phone the pad and the card fit', (tester) async {
      final pad = Pad();
      pad.hub.unended['s1'] = shift(
        'old',
        's1',
        'Amy',
        'server',
        ms(17, 0, 13),
        outMs: ms(4, 0, 14),
        closedBy: 'system',
      );
      pad.hub.shifts.add(shift('sh1', 's1', 'Amy', 'server', ms(9), breaks: [(ms(12), ms(12, 30))]));
      await pumpPad(tester, pad, size: const Size(375, 667));
      expect(tester.takeException(), isNull);
      expect(find.widgetWithIcon(IconButton, Icons.punch_clock_outlined), findsOneWidget); // the icon alone
      expect(find.text('Time clock'), findsNothing);
      await tapKey(tester, 'time-clock');
      expect(tester.takeException(), isNull);
      await tapPin(tester, '1111');
      expect(find.byKey(const ValueKey('clock-card')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tapKey(tester, 'clock-out');
      expect(said(tester), startsWith('Clocked out at'));
      expect(tester.takeException(), isNull);
    });
  });

  group('inside the POS', () {
    testWidgets('the menu has Time clock where the location uses it, and it asks for the PIN', (tester) async {
      final t = await terminal(tester, role: 'server');
      t.hub.timeClock = clockOn();
      await pumpOrdersOn(tester, t);
      await tester.tap(find.byTooltip('Time clock'));
      await tester.pumpAndSettle();
      expect(find.text('Your PIN'), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('clock-pin')), '0000');
      await tapKey(tester, 'clock-open');
      expect(find.text('Wrong PIN'), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('clock-pin')), '2222');
      await tapKey(tester, 'clock-open');
      expect(find.text('Ben'), findsOneWidget); // whoever typed the PIN, not whoever is signed in
      await tapKey(tester, 'clock-in');
      expect(said(tester), 'Clocked in at 4:02 PM');
      expect(find.byKey(const ValueKey('clock-orders')), findsNothing); // they are in the POS already
      await tapKey(tester, 'clock-done');
      expect(find.byType(TimeClockDialog), findsNothing);
      expect(t.session.staff?.name, 'Mike'); // the screen is still whose it was
      await stop(tester);
    });

    testWidgets('no Time clock in the menu while the clock is off', (tester) async {
      final t = await terminal(tester, role: 'server');
      t.hub.timeClock = {...clockOn(), 'enabled': false};
      await pumpOrdersOn(tester, t);
      expect(find.byTooltip('Time clock'), findsNothing);
      await stop(tester);
    });
  });

  group('Location settings', () {
    Future<Terminal> pumpLocation(WidgetTester tester, Map<String, dynamic>? setting) async {
      final t = await terminal(tester);
      t.hub.timeClock = setting;
      tester.view.physicalSize = wholeLocation; // the cards build as they come into view
      await tester.pumpWidget(
        MaterialApp(
          home: LocationSettingsScreen(api: t.api, token: 'tok-admin', device: 't1'),
        ),
      );
      await tester.pumpAndSettle();
      return t;
    }

    testWidgets('the clock is off to start; a manager turns it on and sets how it counts', (tester) async {
      final t = await pumpLocation(tester, {'enabled': false, 'breaks_paid': false, 'week_starts': 'mon'});
      expect(find.text('Off: nobody is asked to clock in'), findsOneWidget);
      expect(find.byKey(const ValueKey('time-clock-breaks-paid')), findsNothing);

      await tapKey(tester, 'time-clock-enabled');
      expect((t.hub.timeClock!['enabled'], t.hub.timeClockAuth), (true, 'Bearer tok-admin'));
      expect(find.text('Off: a break is taken out of the hours'), findsOneWidget);

      await tapKey(tester, 'time-clock-breaks-paid');
      expect(t.hub.timeClock!['breaks_paid'], isTrue);
      expect(find.text('A break stays in the hours'), findsOneWidget);

      await tester.tap(find.text('Sunday'));
      await tester.pumpAndSettle();
      expect(t.hub.timeClock, {'enabled': true, 'breaks_paid': true, 'week_starts': 'sun'});
    });

    testWidgets('Hours opens the hours with the manager\'s token', (tester) async {
      final t = await pumpLocation(tester, clockOn());
      await tapKey(tester, 'time-clock-hours');
      expect(find.byType(TimeClockScreen), findsOneWidget);
      expect(t.hub.clockAuth, 'Bearer tok-admin');
      expect(find.text('Nobody is on the clock.'), findsOneWidget);
    });

    testWidgets('a hub older than the clock: the card says so', (tester) async {
      await pumpLocation(tester, null);
      expect(find.byKey(const ValueKey('time-clock-none')), findsOneWidget);
      expect(find.byKey(const ValueKey('time-clock-enabled')), findsNothing);
    });
  });

  group('the hours', () {
    /// Amy worked a lunch and is on now; Ben closed last night and was never clocked out; a punch of
    /// Holly's was taken off.
    void night(Hub hub) => hub.shifts.addAll([
      shift('a1', 's1', 'Amy', 'server', ms(11), outMs: ms(15, 30), breaks: [(ms(13), ms(13, 30))]),
      shift('a2', 's1', 'Amy', 'server', ms(17)),
      shift('b1', 's2', 'Ben', 'bartender', ms(17, 0, 15), outMs: ms(4), closedBy: 'system'),
      shift('h1', 's4', 'Holly', 'host', ms(16), outMs: ms(16, 1), removed: true, edited: true),
    ]);

    testWidgets('today: who is on now, what each person worked, and each shift', (tester) async {
      final h = await pumpHours(tester);
      night(h.t.hub);
      await showHours(tester, h);
      expect(h.t.hub.clockAsks.single, {'since': '${ms(4)}', 'until': '${ms(4, 0, 17)}'});

      // on now
      expect(find.byKey(const ValueKey('on-now:s1')), findsOneWidget);
      expect(find.text('In at 5:00 PM'), findsOneWidget);
      // hours: Amy's 4 h lunch and 3 h so far
      final amyRow = find.byKey(const ValueKey('person:s1'));
      expect(find.descendant(of: amyRow, matching: find.text('Amy · server')), findsOneWidget);
      expect(find.descendant(of: amyRow, matching: find.text('7 h')), findsOneWidget);
      expect(find.descendant(of: amyRow, matching: find.text('7.00 hours')), findsOneWidget);
      expect(
        find.descendant(of: amyRow, matching: find.text('2 shifts · 30 min on breaks · on the clock now')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('person:s4')), findsNothing); // a shift taken off counts for nobody
      expect(find.byKey(const ValueKey('person:s2')), findsNothing); // Ben's began yesterday
      expect(find.byKey(const ValueKey('unended-note')), findsNothing);
      // each shift, the latest first
      final rows = [
        for (final row in tester.widgetList<ListTile>(find.byType(ListTile)))
          if (row.key case ValueKey<String>(:final value) when value.startsWith('shift:')) value,
      ];
      expect(rows, ['shift:a2', 'shift:h1', 'shift:a1']);
      expect(find.text('5:00 PM, still on the clock'), findsOneWidget);
      expect(find.text('11:00 AM – 3:30 PM · 30 min on breaks'), findsOneWidget);
      expect(find.text('4:00 PM – 4:01 PM · taken off'), findsOneWidget);
    });

    testWidgets('this week and last week start on the location\'s first day, at 4 AM', (tester) async {
      final h = await pumpHours(tester);
      night(h.t.hub);
      await showHours(tester, h, now: at(20, 0, 18)); // a Wednesday
      await tapKey(tester, 'clock-span:week');
      expect(h.t.hub.clockAsks.last, {'since': '${ms(4, 0, 16)}', 'until': '${ms(4, 0, 23)}'});
      await tapKey(tester, 'clock-span:lastWeek');
      expect(h.t.hub.clockAsks.last, {'since': '${ms(4, 0, 9)}', 'until': '${ms(4, 0, 16)}'});
      // last week had Ben's Sunday night, never clocked out
      expect(find.byKey(const ValueKey('unended-note')), findsOneWidget);
      final benRow = find.byKey(const ValueKey('person:s2'));
      expect(find.descendant(of: benRow, matching: find.text('1 shift · 1 not clocked out')), findsOneWidget);
      expect(find.descendant(of: benRow, matching: find.text('11 h')), findsOneWidget);
      expect(find.text('5:00 PM – 4:00 AM · not clocked out'), findsOneWidget);

      // a location whose week starts on Sunday: the hub says so with the hours
      h.t.hub.timeClock = clockOn(week: 'sun');
      await tapKey(tester, 'clock-span:today');
      await tapKey(tester, 'clock-span:week');
      expect(h.t.hub.clockAsks.last, {'since': '${ms(4, 0, 15)}', 'until': '${ms(4, 0, 22)}'});
    });

    testWidgets('a shift opens with its log; a correction wants a reason and keeps untouched times', (tester) async {
      final h = await pumpHours(tester);
      night(h.t.hub);
      // Ben's clock-in was punched at 5:00:37
      h.t.hub.shifts[2]['in_ms'] = ms(17, 0, 15) + 37000;
      await showHours(tester, h, now: at(20, 0, 18));
      await tapKey(tester, 'clock-span:lastWeek');
      await tapKey(tester, 'shift:b1');
      expect(find.descendant(of: find.byType(AlertDialog), matching: find.text('Ben · bartender')), findsOneWidget);
      expect(find.text('Sunday, November 15, 2026'), findsOneWidget);
      expect(find.byKey(const ValueKey('shift-unended')), findsOneWidget);
      expect(find.textContaining('Clocked in · at mac1'), findsOneWidget);
      expect(find.textContaining('Closed when the night ended: nobody clocked out'), findsOneWidget);

      await tapKey(tester, 'shift-correct');
      expect(find.text("Correct Ben's shift"), findsOneWidget);
      expect(find.text('4:00 AM (the next day)'), findsOneWidget);
      final save = find.byKey(const ValueKey('shift-save'));
      expect(tester.widget<FilledButton>(save).onPressed, isNull); // no reason yet

      h.times.add(const TimeOfDay(hour: 23, minute: 30));
      await tapKey(tester, 'shift-out');
      expect(h.helps.last, 'Clocked out at');
      expect(find.text('11:30 PM'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('shift-reason')), 'Left at half past eleven');
      await tester.pumpAndSettle();
      await tapKey(tester, 'shift-save');

      final (method, path, body) = h.t.hub.shiftChanges.single;
      expect((method, path), ('PUT', '/timeclock/shifts/b1'));
      expect(body, {
        'in_ms': ms(17, 0, 15) + 37000, // to the second it was punched at
        'out_ms': ms(23, 30, 15),
        'breaks': <Object>[],
        'reason': 'Left at half past eleven',
        'device': 't1',
      });
      expect(h.t.hub.clockAuth, 'Bearer tok-admin');
      // back on the list, read again
      expect(find.byType(ShiftEditDialog), findsNothing);
      expect(find.text('5:00 PM – 11:30 PM · corrected'), findsOneWidget);
      expect(find.byKey(const ValueKey('unended-note')), findsNothing);

      await tapKey(tester, 'shift:b1');
      expect(find.textContaining('Corrected by Mike · "Left at half past eleven"'), findsOneWidget);
      expect(find.textContaining('was 5:00 PM – 4:00 AM, now 5:00 PM – 11:30 PM'), findsOneWidget);
    });

    testWidgets('what the hub refuses is said, and nothing is lost', (tester) async {
      final h = await pumpHours(tester);
      night(h.t.hub);
      await showHours(tester, h);
      await tapKey(tester, 'shift:a1');
      await tapKey(tester, 'shift-correct');
      h.times.add(const TimeOfDay(hour: 18, minute: 0));
      await tapKey(tester, 'shift-out');
      await tester.enterText(find.byKey(const ValueKey('shift-reason')), 'stayed late');
      await tester.pumpAndSettle();
      h.t.hub.refuseShift = ('overlaps', 'Amy already has a shift over that time');
      await tapKey(tester, 'shift-save');
      expect(find.text('Amy already has a shift over that time'), findsOneWidget);
      expect(find.byType(ShiftEditDialog), findsOneWidget);
      expect(find.text('6:00 PM'), findsOneWidget);

      h.t.hub.down = true;
      await tapKey(tester, 'shift-save');
      expect(find.text('The hub is not answering. Nothing was changed.'), findsOneWidget);
      h.t.hub.down = false;
    });

    testWidgets('the day, the clock-in and the breaks of a shift are corrected too', (tester) async {
      final h = await pumpHours(tester);
      night(h.t.hub);
      await showHours(tester, h);
      await tapKey(tester, 'shift:a1');
      await tapKey(tester, 'shift-correct');
      expect(find.text('1:00 PM – 1:30 PM'), findsOneWidget);

      // the whole shift was really on Sunday
      h.days.add(DateTime(2026, 11, 15));
      await tapKey(tester, 'shift-day');
      expect(find.text('Sun, Nov 15'), findsOneWidget);
      // and began at half past ten
      h.times.add(const TimeOfDay(hour: 10, minute: 30));
      await tapKey(tester, 'shift-in');
      // the break was 20 minutes, and there was a second one
      h.times.addAll(const [TimeOfDay(hour: 13, minute: 0), TimeOfDay(hour: 13, minute: 20)]);
      await tapKey(tester, 'shift-break:0');
      h.times.addAll(const [TimeOfDay(hour: 12, minute: 0), TimeOfDay(hour: 12, minute: 10)]);
      await tapKey(tester, 'shift-break-add');
      expect(h.helps.sublist(h.helps.length - 2), ['The break started at', 'The break ended at']);
      expect(find.text('12:00 PM – 12:10 PM'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('shift-reason')), 'wrong day');
      await tester.pumpAndSettle();
      await tapKey(tester, 'shift-save');
      expect(h.t.hub.shiftChanges.single.$3, {
        'in_ms': ms(10, 30, 15),
        'out_ms': ms(15, 30, 15),
        'breaks': [
          {'start_ms': ms(12, 0, 15), 'end_ms': ms(12, 10, 15)},
          {'start_ms': ms(13, 0, 15), 'end_ms': ms(13, 20, 15)},
        ],
        'reason': 'wrong day',
        'device': 't1',
      });
    });

    testWidgets('a break is struck out, and a clock-out taken away puts the person back on the clock', (tester) async {
      final h = await pumpHours(tester);
      night(h.t.hub);
      h.t.hub.shifts.removeAt(1); // Amy is not on the clock now
      await showHours(tester, h);
      await tapKey(tester, 'shift:a1');
      await tapKey(tester, 'shift-correct');
      await tapKey(tester, 'shift-break-delete:0');
      await tapKey(tester, 'shift-out-clear');
      expect(find.text('Still on the clock'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('shift-reason')), 'clocked out by mistake');
      await tester.pumpAndSettle();
      await tapKey(tester, 'shift-save');
      expect(h.t.hub.shiftChanges.single.$3, {
        'in_ms': ms(11),
        'out_ms': null,
        'breaks': <Object>[],
        'reason': 'clocked out by mistake',
        'device': 't1',
      });
      expect(find.byKey(const ValueKey('on-now:s1')), findsOneWidget);
    });

    testWidgets('a shift is taken off with a reason: it stays listed and counts for nothing', (tester) async {
      final h = await pumpHours(tester);
      night(h.t.hub);
      await showHours(tester, h);
      await tapKey(tester, 'shift:a1');
      await tapKey(tester, 'shift-take-off');
      expect(find.text("Take off Amy's shift"), findsOneWidget);
      expect(tester.widget<FilledButton>(find.byKey(const ValueKey('take-off-save'))).onPressed, isNull);
      await tester.enterText(find.byKey(const ValueKey('take-off-reason')), 'punched in for a tasting');
      await tester.pumpAndSettle();
      await tapKey(tester, 'take-off-save');
      expect(change(h.t.hub.shiftChanges.single), [
        'DELETE',
        '/timeclock/shifts/a1',
        {'reason': 'punched in for a tasting', 'device': 't1'},
      ]);
      expect(find.text('11:00 AM – 3:30 PM · 30 min on breaks · taken off'), findsOneWidget);
      final amyRow = find.byKey(const ValueKey('person:s1'));
      expect(find.descendant(of: amyRow, matching: find.text('3 h')), findsOneWidget); // only tonight's now

      // a shift taken off can be read, with its log, and not changed again
      await tapKey(tester, 'shift:a1');
      expect(find.text('Taken off: it counts for nothing.'), findsOneWidget);
      expect(find.textContaining('Taken off by Mike · "punched in for a tasting"'), findsOneWidget);
      expect(find.byKey(const ValueKey('shift-correct')), findsNothing);
      expect(find.byKey(const ValueKey('shift-take-off')), findsNothing);
    });

    testWidgets('a shift is written in for somebody who never clocked in', (tester) async {
      final h = await pumpHours(tester);
      await showHours(tester, h);
      expect(find.text('No shift began in this time.'), findsNWidgets(2));
      await tapKey(tester, 'shift-add');
      expect(find.text('Add a shift'), findsNWidgets(2)); // the button under it, and the dialog
      expect(find.text('Mon, Nov 16'), findsOneWidget);
      expect(find.text('12:00 PM'), findsOneWidget); // noon to start from; 9 PM is still to come

      await tester.tap(find.byKey(const ValueKey('shift-who')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Holly · host').last);
      await tester.pumpAndSettle();
      h.times.add(const TimeOfDay(hour: 15, minute: 45));
      await tapKey(tester, 'shift-in');
      await tester.enterText(find.byKey(const ValueKey('shift-reason')), 'the clock was not on yet');
      await tester.pumpAndSettle();
      await tapKey(tester, 'shift-save');
      expect(change(h.t.hub.shiftChanges.single), [
        'POST',
        '/timeclock/shifts',
        {
          'staff_id': 's4',
          'in_ms': ms(15, 45),
          'out_ms': null,
          'breaks': <Object>[],
          'reason': 'the clock was not on yet',
          'device': 't1',
        },
      ]);
      expect(find.byKey(const ValueKey('on-now:s4')), findsOneWidget);
      expect(find.text('3:45 PM, still on the clock · written in'), findsOneWidget);
    });

    testWidgets('the device\'s own pickers change nothing when they are only looked at', (tester) async {
      final t = await terminal(tester);
      t.hub
        ..timeClock = clockOn()
        ..clockNow = ms(20)
        ..shifts.add(shift('a1', 's1', 'Amy', 'server', ms(11) + 12000, outMs: ms(15, 30) + 5000));
      await tester.pumpWidget(
        MaterialApp(
          home: TimeClockScreen(api: t.api, token: 'tok-admin', device: 't1', now: () => at(20)),
        ),
      );
      await tester.pumpAndSettle();
      await tapKey(tester, 'shift:a1');
      await tapKey(tester, 'shift-correct');
      await tapKey(tester, 'shift-in');
      expect(find.text('Clocked in at'), findsOneWidget); // the time picker, saying what it is for
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      await tapKey(tester, 'shift-out');
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      await tapKey(tester, 'shift-day');
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('shift-reason')), 'looked, changed nothing');
      await tester.pumpAndSettle();
      await tapKey(tester, 'shift-save');
      final body = t.hub.shiftChanges.single.$3;
      expect((body['in_ms'], body['out_ms']), (ms(11) + 12000, ms(15, 30) + 5000));
    });

    testWidgets('the manager\'s hour is over, or the hub is older: the screen says which', (tester) async {
      final t = await terminal(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: TimeClockScreen(api: t.api, token: 'tok-admin', now: () => at(20)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('This hub is older than the time clock'), findsOneWidget);
    });

    testWidgets('the clock is off: the hours are still read, and the screen says nobody can clock in', (tester) async {
      final h = await pumpHours(tester);
      h.t.hub.timeClock = {...clockOn(), 'enabled': false};
      await showHours(tester, h);
      expect(find.byKey(const ValueKey('clock-off')), findsOneWidget);
    });

    testWidgets('on a small phone the hours and a correction fit', (tester) async {
      final h = await pumpHours(tester, size: const Size(320, 568));
      night(h.t.hub);
      await showHours(tester, h);
      expect(tester.takeException(), isNull);
      await tapKey(tester, 'shift:a1');
      expect(tester.takeException(), isNull);
      await tapKey(tester, 'shift-correct');
      expect(tester.takeException(), isNull);
      expect(find.text('1:00 PM – 1:30 PM'), findsOneWidget);
    });
  });
}
