import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/api.dart' show ApiException;
import 'package:pos_app/customers.dart';
import 'package:pos_app/guests_report.dart';
import 'package:pos_app/points.dart';
import 'package:pos_app/screens/guests_screen.dart';
import 'package:pos_app/screens/location_settings_screen.dart';
import 'package:pos_app/screens/points_dialog.dart';
import 'package:pos_app/seated.dart';

import 'customers_test.dart' as customers show linda, lindaDigits, openForm, typeNumber;
import 'guests_report_test.dart' show linda, lindaClosely, listed, omar, priya, pumpGuests, row, sam, tess, year;
import 'guests_report_test.dart' as guests show tapKey;
import 'hub.dart';
import 'location_rows.dart';
import 'table_tags_test.dart' show lindaAtA7, pumpCheck, seatedBooking, seatedParty, seven;

/// Points (docs/points.md; the owner's pick of 2026-11-25 from the Toast comparison): the guest who pays a
/// check earns points on it, where the owner set a rate. The hub does every sum; these tests are about the
/// rules a manager sets under Location › Points, and about the screens saying what the hub said: in the
/// guest list, beside a party seated at a table, and on the to-go form. Until a rate is set nobody earns,
/// and no screen says a word about points.

Finder key(String name) => find.byKey(ValueKey(name));

String said(WidgetTester tester, String name) {
  final text = tester.widget<Text>(key(name));
  return text.data ?? text.textSpan!.toPlainText();
}

Future<void> tapKey(WidgetTester tester, String name) async {
  await tester.ensureVisible(key(name));
  await tester.pumpAndSettle();
  await tester.tap(key(name));
  await tester.pumpAndSettle();
}

Future<void> stop(WidgetTester tester) => tester.pumpWidget(const SizedBox()); // stops the refresh timers

/// What the guest list is told of the rules: the first part of the setting.
Map<String, dynamic> rules({bool on = true, String rate = '1', int days = 365, bool alcohol = false}) => {
  'on': on,
  'ever': true,
  'per_dollar': on ? rate : '0',
  'alcohol': alcohol,
  'dine_in': true,
  'takeout': true,
  'delivery': true,
  'catering': true,
  'days': days,
};

const _has = {omar: 0, linda: 99, sam: 34, priya: 26, tess: 3};

/// The year of five guests on a hub where a point a dollar was set: Omar came last in August and has none
/// left to count (the rate was set after), Linda has the most.
Map<String, dynamic> yearOfPoints({Map<String, dynamic>? by}) {
  final report = year();
  return {
    ...report,
    'guests': [
      for (final guest in (report['guests'] as List).cast<Map<String, dynamic>>())
        {...guest, 'points': _has[guest['phone']]},
    ],
    'totals': {...report['totals'] as Map, 'points': 162},
    'points': by ?? rules(),
  };
}

/// Linda read closely on that hub: her pickup earned, her delivery was a kind of order that did not that
/// day, and two beers at a table earn nothing where drinks do not.
Map<String, dynamic> lindaWithPoints() {
  final closely = lindaClosely();
  const earned = {'l5': (31, ''), 'l4': (0, 'kind'), 'l3': (0, 'nothing')};
  return {
    ...closely,
    'guest': {...closely['guest'] as Map, 'points': 99},
    'latest': [
      for (final visit in (closely['latest'] as List).cast<Map<String, dynamic>>())
        {...visit, 'points': earned[visit['order_id']]!.$1, 'points_why': earned[visit['order_id']]!.$2},
    ],
    'points_next': {'points': 31, 'until': '2027-11-13'},
  };
}

void main() {
  group('the rules and their words', () {
    test('until somebody sets a rate nobody earns, and the hub says what a rate would earn on', () {
      final off = PointsRules.fromJson(Hub.pointsOff);
      expect((off.on, off.ever, off.earning.perDollar, off.earning.earns, off.days), (false, false, '0', false, 365));
      expect((off.from, off.by, off.since), (null, '', null));
      expect(off.earlier, isEmpty);
      final earning = off.earning;
      expect(
        (earning.dineIn, earning.takeout, earning.delivery, earning.catering, earning.alcohol),
        (true, true, true, true, false),
      );
      expect((off.perDollarMost, off.daysLeast, off.daysMost), ('100', 30, 365));
      expect(off.summary, 'Off: nobody earns points until you set how many a dollar earns');
    });

    test('a rate set: since when, by whom, and one line that says it', () {
      final on = PointsRules.fromJson(Hub.pointsOn);
      expect((on.on, on.ever, on.earning.perDollar, on.by), (true, true, '1', 'Mike'));
      expect((on.from, on.since), (DateTime(2026, 11, 1), DateTime(2026, 11, 1)));
      expect(
        on.summary,
        'The guest who pays earns 1 point a dollar · no points on alcoholic drinks · points last a year',
      );
      final narrow = PointsRules.fromJson({
        ...Hub.pointsOn,
        'per_dollar': '1.5',
        'takeout': false,
        'catering': false,
        'days': 90,
      });
      expect(
        narrow.summary,
        'The guest who pays earns 1.5 points a dollar · no points on to-go orders, catering or alcoholic drinks · '
        'points last 90 days',
      );
      final everything = PointsRules.fromJson({...Hub.pointsOn, 'alcohol': true, 'per_dollar': '2'});
      expect(everything.summary, 'The guest who pays earns 2 points a dollar · points last a year');
      expect(everything.earning.exceptWords, '');
    });

    test('turned off after it was on: what was earned still counts, and the versions before are read', () {
      final off = PointsRules.fromJson({
        ...Hub.pointsOn,
        'on': false,
        'per_dollar': '0',
        'from': '2026-11-16',
        'days': 120,
        'earlier': [
          {'from': '2026-11-01', 'until': '2026-11-15', 'per_dollar': '1', 'by': 'Mike', 'alcohol': false},
          {'from': 'never', 'until': '2026-10-31', 'per_dollar': '5'},
          'junk',
        ],
      });
      expect((off.on, off.ever), (false, true));
      expect(off.summary, 'Off: nobody earns now. Points earned before still count for 120 days from their day');
      final was = off.earlier.single; // a row with no day in it is no version
      expect(
        (was.from, was.until, was.earning.perDollar, was.by),
        (DateTime(2026, 11, 1), DateTime(2026, 11, 15), '1', 'Mike'),
      );
    });

    test('an answer with nothing in it is off', () {
      final none = PointsRules.fromJson(const {});
      expect((none.on, none.ever, none.earning.perDollar, none.days), (false, false, '0', 365));
    });

    test('counts, rates and days as people read them', () {
      expect((pointsWords(0), pointsWords(1), pointsWords(1240)), ('0 points', '1 point', '1,240 points'));
      expect((pointsShort(1), pointsShort(99), pointsShort(1234567)), ('1 pt', '99 pts', '1,234,567 pts'));
      expect(
        (rateWords('1'), rateWords('1.5'), rateWords('0.25')),
        ('1 point a dollar', '1.5 points a dollar', '0.25 points a dollar'),
      );
      expect((lastWords(365), lastWords(90)), ('a year', '90 days'));
      expect(manyWords(-1200), '-1,200');
    });

    test('a rate as it is typed, in the hub\'s own words', () {
      expect(
        [
          for (final typed in ['1', '1.50', '2.', '.5', '0', '100', ' 3 ', '0.25']) rateTyped(typed),
        ],
        ['1', '1.5', '2', '0.5', '0', '100', '3', '0.25'],
      );
      expect([
        for (final typed in ['', 'a lot', '-1', '100.01', '1.005', '1.2.3', '.']) rateTyped(typed),
      ], everyElement(isNull));
      expect(rateTyped('7', most: '5'), isNull);
    });

    test('why a visit earned nothing, in a few words', () {
      expect(whyNoPoints('off'), 'no points were given that day');
      expect(whyNoPoints('open'), 'no points until the check is closed');
      expect(whyNoPoints('kind'), 'this kind of order earns no points');
      expect(whyNoPoints('catering'), 'catering earns no points');
      expect(whyNoPoints('nothing'), 'nothing on it earns points');
      expect(whyNoPoints('gone'), 'its points ran out');
      // where another guest paid, or nobody said who, the line says that already
      expect([
        whyNoPoints('other'),
        whyNoPoints('waits'),
        whyNoPoints(''),
        whyNoPoints('new word'),
      ], everyElement(isNull));
    });

    test('a manager\'s save says the rate, what earns and the days', () {
      const change = PointsChange(
        perDollar: '1.5',
        dineIn: true,
        takeout: false,
        delivery: true,
        catering: false,
        alcohol: true,
        days: 180,
      );
      expect(change.toJson(), {
        'per_dollar': '1.5',
        'dine_in': true,
        'takeout': false,
        'delivery': true,
        'catering': false,
        'alcohol': true,
        'days': 180,
      });
    });
  });

  group('what the screens read', () {
    test('the guest list: each guest\'s points, their sum, and the rules they were earned by', () {
      final report = GuestsReport.fromJson(yearOfPoints());
      expect(report.hasPoints, isTrue);
      expect((report.points!.on, report.points!.earning.perDollar, report.points!.days), (true, '1', 365));
      expect({for (final guest in report.guests) guest.phone: guest.points}, _has);
      expect(report.totals.points, 162);
      // by points, and equals by what they spent
      expect(
        [for (final guest in sortedGuests(report.guests, GuestSort.points)) guest.called],
        ['Linda Chen', '781 555 0104', 'Priya Patel', 'Tess Moreau', 'Omar Haddad'],
      );
      // what a manager writes about a guest moves no point
      const kept = GuestKept(phone: linda, note: 'Window seat', tags: ['VIP']);
      final after = report.withKept(kept);
      expect((after.hasPoints, after.guests[1].points, after.guests[1].note), (true, 99, 'Window seat'));
    });

    test('a hub older than points, or one where no rate was ever set, says none', () {
      final older = GuestsReport.fromJson(year());
      expect((older.points, older.hasPoints, older.totals.points), (null, false, 0));
      expect(older.guests.map((guest) => guest.points), everyElement(0));
      final never = GuestsReport.fromJson(yearOfPoints(by: {...rules(on: false), 'ever': false}));
      expect((never.points!.ever, never.hasPoints), (false, false));
    });

    test('one guest read closely: what each visit earned or why not, and which points run out first', () {
      final detail = GuestDetail.fromJson(lindaWithPoints());
      expect(detail.guest.points, 99);
      expect(
        [for (final visit in detail.latest) (visit.orderId, visit.points, visit.pointsWhy, visit.pointsSaid)],
        [
          ('l5', 31, '', '31 points'),
          ('l4', 0, 'kind', 'this kind of order earns no points'),
          ('l3', 0, 'nothing', 'nothing on it earns points'),
        ],
      );
      expect((detail.pointsNext!.points, detail.pointsNext!.until), (31, DateTime(2027, 11, 13)));
      // kept through a note written meanwhile
      expect(detail.withKept(const GuestKept(phone: linda)).pointsNext!.points, 31);
      final older = GuestDetail.fromJson(lindaClosely());
      expect((older.pointsNext, older.latest.first.points, older.latest.first.pointsSaid), (null, 0, null));
      expect(PointsNext.of({'points': 0, 'until': '2027-01-01'}), isNull);
      expect(PointsNext.of({'points': 5, 'until': 'some day'}), isNull);
    });

    test('a party at a table and a customer at a number: a count, or nothing where the hub says none', () {
      final party = SeatedParty.fromJson({'name': 'Linda P.', 'points': 99});
      expect(party.points, 99);
      expect(SeatedParty.fromJson({'name': 'Wu', 'points': null}).points, isNull);
      expect(SeatedParty.fromJson({'name': 'Wu'}).points, isNull);
      // a party whose points moved is another party to the screen: it is drawn again
      expect(party == SeatedParty.fromJson({'name': 'Linda P.', 'points': 116}), isFalse);
      expect(party == SeatedParty.fromJson({'name': 'Linda P.', 'points': 99}), isTrue);
      expect(CustomerCard.fromJson({'phone': linda, 'known': true, 'points': 99}).points, 99);
      expect(CustomerCard.fromJson({'phone': linda, 'known': true, 'points': 0}).points, 0);
      expect(CustomerCard.fromJson({'phone': linda, 'known': true}).points, isNull);
    });
  });

  group('the calls', () {
    testWidgets('the rules are read without a token, and a save carries the manager\'s', (tester) async {
      final t = await terminal(tester);
      expect(await t.api.pointsRules(), isNull); // a hub older than points
      t.hub.points = Hub.pointsOff;
      expect((await t.api.pointsRules())!.on, isFalse);
      final saved = await t.api.savePoints(
        'tok-admin',
        const PointsChange(
          perDollar: '2',
          dineIn: true,
          takeout: true,
          delivery: true,
          catering: false,
          alcohol: false,
          days: 200,
        ),
      );
      expect(t.hub.pointsAuth, 'Bearer tok-admin');
      expect(t.hub.pointsSaves.single, {
        'per_dollar': '2',
        'dine_in': true,
        'takeout': true,
        'delivery': true,
        'catering': false,
        'alcohol': false,
        'days': 200,
      });
      expect((saved.on, saved.earning.perDollar, saved.earning.catering, saved.days), (true, '2', false, 200));
      expect((saved.from, saved.by), (DateTime(2026, 11, 16), 'Mike'));
      t.hub.refusePoints = 'points last a whole number of days, from 30 to 365';
      await expectLater(
        t.api.savePoints(
          'tok-admin',
          const PointsChange(
            perDollar: '2',
            dineIn: true,
            takeout: true,
            delivery: true,
            catering: true,
            alcohol: false,
            days: 1,
          ),
        ),
        throwsA(
          isA<ApiException>()
              .having((err) => err.status, 'status', 422)
              .having((err) => err.detail?['message'], 'message', contains('from 30 to 365')),
        ),
      );
    });
  });

  group('under Location', () {
    Future<Terminal> pumpLocation(WidgetTester tester, {Map<String, dynamic>? points, Size? size, double? type}) async {
      final t = await terminal(tester);
      t.hub.points = points;
      if (size != null) tester.view.physicalSize = size;
      if (type != null) {
        tester.platformDispatcher.textScaleFactorTestValue = type;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      }
      await tester.pumpWidget(
        MaterialApp(
          home: LocationSettingsScreen(api: t.api, token: 'tok-admin', device: 't1'),
        ),
      );
      await tester.pumpAndSettle();
      await bringUp(tester, 'points');
      return t;
    }

    String rowWords(WidgetTester tester) => ((tester.widget<ListTile>(key('points')).subtitle!) as Text).data!;
    TextField box(WidgetTester tester, String name) => tester.widget<TextField>(key(name));
    bool canSave(WidgetTester tester) => tester.widget<FilledButton>(key('points-save')).onPressed != null;

    testWidgets('nobody earns until a manager sets a rate; the dialog says what a point is earned on', (tester) async {
      final t = await pumpLocation(tester, points: Hub.pointsOff);
      expect(rowWords(tester), 'Off: nobody earns points until you set how many a dollar earns');
      await tapKey(tester, 'points');
      expect(find.byType(PointsDialog), findsOneWidget);
      expect(said(tester, 'points-says'), contains('The guest who pays a check earns points on it'));
      expect(said(tester, 'points-says'), contains('before tax, charges and tips, less comps and discounts'));
      expect(said(tester, 'points-says'), contains('they cannot be spent yet'));
      // off: the box is empty, and says what to type
      expect(box(tester, 'points-rate').controller!.text, '');
      expect(box(tester, 'points-rate').decoration!.helperText, 'Off: nobody earns. Set 1 for one point a dollar');
      expect(box(tester, 'points-days').controller!.text, '365');
      // everything earns but alcoholic drinks
      for (final name in ['dine-in', 'takeout', 'delivery', 'catering']) {
        expect(tester.widget<SwitchListTile>(key('points-$name')).value, isTrue, reason: name);
      }
      expect(tester.widget<SwitchListTile>(key('points-alcohol')).value, isFalse);
      expect(find.text('Off: the drinks on a check earn nothing, the food on it does'), findsOneWidget);
      expect(said(tester, 'points-since'), startsWith('What you change about earning counts from today'));

      await tester.enterText(key('points-rate'), '1.5');
      await tester.pump();
      expect(box(tester, 'points-rate').decoration!.helperText, 'A \$20.00 check earns 30 points');
      await tapKey(tester, 'points-alcohol');
      expect(find.text('Drinks earn like food'), findsOneWidget);
      await tapKey(tester, 'points-catering');
      await tester.enterText(key('points-days'), '180');
      expect(t.hub.pointsSaves, isEmpty); // nothing is saved before Save
      await tapKey(tester, 'points-save');
      expect(find.byType(PointsDialog), findsNothing);
      expect(t.hub.pointsAuth, 'Bearer tok-admin');
      expect(t.hub.pointsSaves.single, {
        'per_dollar': '1.5',
        'dine_in': true,
        'takeout': true,
        'delivery': true,
        'catering': false,
        'alcohol': true,
        'days': 180,
      });
      expect(find.text('Points saved: they are earned from today'), findsOneWidget);
      expect(
        rowWords(tester),
        'The guest who pays earns 1.5 points a dollar · no points on catering · points last 180 days',
      );
      await stop(tester);
    });

    testWidgets('a rate is changed from today, and turned off by a rate of nothing', (tester) async {
      final t = await pumpLocation(tester, points: Hub.pointsOn);
      expect(rowWords(tester), startsWith('The guest who pays earns 1 point a dollar'));
      await tapKey(tester, 'points');
      expect(box(tester, 'points-rate').controller!.text, '1');
      expect(said(tester, 'points-since'), startsWith('These rules have counted since Nov 1, 2026 (Mike).'));
      expect(said(tester, 'points-since'), contains('a check of an earlier day keeps what it earned'));
      await tester.enterText(key('points-rate'), '2');
      await tapKey(tester, 'points-save');
      expect(t.hub.points!['per_dollar'], '2');
      // the rule of before stands in the dialog with its days
      await tapKey(tester, 'points');
      expect(said(tester, 'points-earlier:2026-11-01'), 'Nov 1, 2026 to Nov 15, 2026: 1 point a dollar');
      // an empty box is a rate of nothing: off
      await tester.enterText(key('points-rate'), '');
      await tester.pump();
      expect(canSave(tester), isTrue);
      await tapKey(tester, 'points-save');
      expect(t.hub.pointsSaves.last['per_dollar'], '0');
      expect(find.text('Points saved: nobody earns'), findsOneWidget);
      expect(rowWords(tester), 'Off: nobody earns now. Points earned before still count for a year from their day');
      await stop(tester);
    });

    testWidgets('what is no rate and no number of days cannot be saved, and says why', (tester) async {
      final t = await pumpLocation(tester, points: Hub.pointsOn);
      await tapKey(tester, 'points');
      await tester.enterText(key('points-rate'), '250');
      await tester.pump();
      expect(box(tester, 'points-rate').decoration!.errorText, 'A number from 0 to 100, like 1 or 1.5');
      expect(canSave(tester), isFalse);
      await tester.enterText(key('points-rate'), '1.005');
      await tester.pump();
      expect(canSave(tester), isFalse);
      await tester.enterText(key('points-rate'), '1');
      await tester.enterText(key('points-days'), '7');
      await tester.pump();
      expect(box(tester, 'points-days').decoration!.errorText, 'From 30 to 365 days');
      expect(canSave(tester), isFalse);
      await tester.enterText(key('points-days'), '400');
      await tester.pump();
      expect(canSave(tester), isFalse);
      await tester.enterText(key('points-days'), '90');
      await tester.pump();
      expect(canSave(tester), isTrue);
      // a rate with no kind of order to earn it is no rule
      for (final name in ['dine-in', 'takeout', 'delivery']) {
        await tapKey(tester, 'points-$name');
      }
      expect(said(tester, 'points-nothing-earns'), startsWith('Pick at least one kind of order that earns'));
      expect(canSave(tester), isFalse);
      await tapKey(tester, 'points-delivery');
      expect(key('points-nothing-earns'), findsNothing);
      expect(canSave(tester), isTrue);
      expect(t.hub.pointsSaves, isEmpty);
      await stop(tester);
    });

    testWidgets('the hub refuses, or does not answer: the dialog says so and nothing is changed', (tester) async {
      final t = await pumpLocation(tester, points: Hub.pointsOn);
      await tapKey(tester, 'points');
      await tester.enterText(key('points-rate'), '3');
      t.hub.refusePoints = 'points a dollar is a number from 0 to 100, to two decimals; 0 is off';
      await tapKey(tester, 'points-save');
      expect(find.byType(PointsDialog), findsOneWidget);
      expect(said(tester, 'points-problem'), 'points a dollar is a number from 0 to 100, to two decimals; 0 is off');
      t.hub
        ..refusePoints = null
        ..pointsDown = true;
      await tapKey(tester, 'points-save');
      expect(said(tester, 'points-problem'), 'The hub is not answering: nothing was saved.');
      expect(t.hub.points!['per_dollar'], '1');
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(rowWords(tester), startsWith('The guest who pays earns 1 point a dollar'));
      await stop(tester);
    });

    testWidgets('a hub older than points says so, and the row opens nothing', (tester) async {
      await pumpLocation(tester);
      expect(rowWords(tester), 'The hub has not answered about points (an older hub: update it)');
      expect(tester.widget<ListTile>(key('points')).onTap, isNull);
      await stop(tester);
    });

    testWidgets('on a small phone with large type the dialog is whole', (tester) async {
      final t = await pumpLocation(tester, points: Hub.pointsOn, size: const Size(320, 640), type: 1.3);
      await tapKey(tester, 'points');
      expect(tester.takeException(), isNull);
      await tester.enterText(key('points-rate'), '0.5');
      await tester.pumpAndSettle(); // the box that was typed in is brought up before anything else is
      await tapKey(tester, 'points-alcohol');
      await tapKey(tester, 'points-takeout');
      expect(tester.takeException(), isNull);
      await tapKey(tester, 'points-save');
      expect(find.byType(PointsDialog), findsNothing);
      expect((t.hub.points!['per_dollar'], t.hub.points!['alcohol'], t.hub.points!['takeout']), ('0.5', true, false));
      expect(tester.takeException(), isNull);
      await stop(tester);
    });
  });

  group('in the guest list', () {
    Future<Terminal> pumpPoints(WidgetTester tester, {Map<String, dynamic>? by, Size? size}) => pumpGuests(
      tester,
      guests: yearOfPoints(by: by),
      size: size ?? const Size(1100, 3600),
      before: (hub) => hub.guestDetails = {linda: lindaWithPoints()},
    );

    testWidgets('the list says each guest\'s points, their sum, and the rule they are earned by', (tester) async {
      await pumpPoints(tester);
      expect(row(tester, 'guests-points'), ['Their points', '162', '1 point a dollar · they last a year']);
      expect(row(tester, 'guest-row:$linda').join(' | '), contains('last Nov 14 · 99 points'));
      expect(row(tester, 'guest-row:$sam').join(' | '), contains('new · 34 points'));
      // a guest with none has no word about them in their row
      expect(row(tester, 'guest-row:$omar').join(' | '), isNot(contains('point')));
      expect(said(tester, 'guests-note'), contains('Points are earned by the guest who pays a check'));
      expect(said(tester, 'guests-note'), contains("a check's points count for a year from its day"));
    });

    testWidgets('by points: the guest with the most first', (tester) async {
      await pumpPoints(tester);
      expect(listed(tester).first, 'Omar Haddad'); // by what they spent, as the list opens
      await guests.tapKey(tester, 'guests-by:points');
      expect(listed(tester), ['Linda Chen', '781 555 0104', 'Priya Patel', 'Tess Moreau', 'Omar Haddad']);
      await guests.tapKey(tester, 'guests-by:spent');
      expect(listed(tester).first, 'Omar Haddad');
    });

    testWidgets('an open guest: how many, which run out first, and what each visit earned or why not', (tester) async {
      await pumpPoints(tester);
      await guests.tapKey(tester, 'guest-row:$linda');
      expect(said(tester, 'guest-points:$linda'), '99 points · 31 of them count until Nov 13, 2027');
      expect(
        row(tester, 'guest-visit:$linda:l5').join(' | '),
        contains("2 Egg roll, General Tso's Chicken · 31 points"),
      );
      expect(row(tester, 'guest-visit:$linda:l4').join(' | '), contains('this kind of order earns no points'));
      expect(row(tester, 'guest-visit:$linda:l3').join(' | '), contains('2 Tsingtao · nothing on it earns points'));
      // a guest with none says so, once they are open
      await guests.tapKey(tester, 'guest-row:$omar');
      expect(said(tester, 'guest-points:$omar'), 'No points now');
    });

    testWidgets('all of a guest\'s points run out the same day: said in fewer words', (tester) async {
      final t = await pumpPoints(tester);
      t.hub.guestDetails[priya] = {
        ...lindaWithPoints(),
        'guest': {...(yearOfPoints()['guests'] as List)[3] as Map},
        'points_next': {'points': 26, 'until': '2027-10-29'},
      };
      await guests.tapKey(tester, 'guest-row:$priya');
      expect(said(tester, 'guest-points:$priya'), '26 points · they count until Oct 29, 2027');
    });

    testWidgets('the rate was turned off: the list still says what was earned, and that nobody earns now', (
      tester,
    ) async {
      await pumpPoints(tester, by: rules(on: false, days: 120));
      expect(row(tester, 'guests-points'), ['Their points', '162', 'nobody earns now · they last 120 days']);
      expect(key('guests-by:points'), findsOneWidget);
      expect(row(tester, 'guest-row:$linda').join(' | '), contains('99 points'));
    });

    testWidgets('no rate was ever set: not a word about points anywhere on the list', (tester) async {
      for (final guestsOf in [
        year(),
        yearOfPoints(by: {...rules(on: false), 'ever': false}),
      ]) {
        await pumpGuests(tester, guests: guestsOf);
        expect(key('guests-points'), findsNothing);
        expect(key('guests-by:points'), findsNothing);
        expect(find.byType(GuestsScreen), findsOneWidget);
        expect(find.textContaining('point', findRichText: true), findsNothing);
        await guests.tapKey(tester, 'guest-row:$linda');
        expect(key('guest-points:$linda'), findsNothing);
        expect(find.textContaining('point', findRichText: true), findsNothing);
        await stop(tester);
      }
    });

    testWidgets('on a small phone the four orders fit, and the points stand under the guest', (tester) async {
      await pumpPoints(tester, size: const Size(320, 640));
      expect(tester.takeException(), isNull);
      for (final sort in GuestSort.values) {
        final label = tester.getRect(key('guests-by:${sort.name}'));
        expect(label.left >= 0 && label.right <= 320, isTrue, reason: sort.name);
      }
      await guests.tapKey(tester, 'guests-by:points');
      // the guest with the most points is the first under the head of the list
      await guests.tapKey(tester, 'guest-row:$linda');
      expect(row(tester, 'guest-row:$linda').first, '1');
      expect(row(tester, 'guest-row:$linda').join(' | '), contains('99 points'));
      expect(said(tester, 'guest-points:$linda'), startsWith('99 points'));
      expect(tester.takeException(), isNull);
    });
  });

  group('at the table', () {
    /// Linda (from her reservation) and Omar (from the waitlist) at A7, and Wu who left no number.
    void threeAtA7(Hub hub) {
      lindaAtA7(hub);
      hub
        ..parties = [seatedParty('p1', 'Omar', omar, 'o1', seatedMs: seven + 60000)]
        ..bookings!.add(seatedBooking('b2', 'Wu', '', 'o1', seatedMs: seven + 120000));
    }

    testWidgets('each seated guest who left a number says their points beside their name', (tester) async {
      await pumpCheck(
        tester,
        hub: (hub) {
          threeAtA7(hub);
          hub.guestPoints = {linda: 1240};
        },
      );
      expect(said(tester, 'seated-name:0'), 'Linda P.');
      expect(find.descendant(of: key('seated-points:0'), matching: find.text('1,240 pts')), findsOneWidget);
      // Omar has none yet: it says so, for he can earn
      expect(find.descendant(of: key('seated-points:1'), matching: find.text('0 pts')), findsOneWidget);
      // Wu left no number: no guest of the list, no points to say
      expect(said(tester, 'seated-name:2'), 'Wu');
      expect(key('seated-points:2'), findsNothing);
      // the points stand between the name and the party's tags, on its own line of the strip
      final name = tester.getRect(key('seated-name:0')), points = tester.getRect(key('seated-points:0'));
      expect(points.left > name.right, isTrue);
      expect((points.center.dy - name.center.dy).abs() < 6, isTrue);
      await stop(tester);
    });

    testWidgets('no rate was ever set, or an older hub: the strip is the strip it was', (tester) async {
      await pumpCheck(tester, hub: threeAtA7);
      expect(said(tester, 'seated-name:0'), 'Linda P.');
      for (final at in [0, 1, 2]) {
        expect(key('seated-points:$at'), findsNothing);
      }
      expect(find.textContaining('pts'), findsNothing);
      await stop(tester);
    });

    testWidgets('on a small phone with large type the strip holds the points too', (tester) async {
      await pumpCheck(
        tester,
        size: const Size(320, 640),
        textScale: 1.3,
        hub: (hub) {
          threeAtA7(hub);
          hub.guestPoints = {linda: 1240, omar: 17};
        },
      );
      expect(tester.takeException(), isNull);
      expect(key('seated-points:0'), findsOneWidget);
      expect(tester.getRect(key('seated-points:0')).right <= 320, isTrue);
      await stop(tester);
    });
  });

  group('on the to-go form', () {
    Future<Terminal> pumpForm(WidgetTester tester, Object? points) async {
      final t = await terminal(tester);
      t.hub.customers[customers.lindaDigits] = {...customers.linda(), if (points != #none) 'points': points};
      await pumpOrdersOn(tester, t);
      await customers.openForm(tester);
      await customers.typeNumber(tester, '781 555 1234');
      expect(key('customer-card'), findsOneWidget);
      return t;
    }

    testWidgets('the customer at the number says their points under how often they ordered', (tester) async {
      await pumpForm(tester, 99);
      expect(said(tester, 'customer-points'), 'They have 99 points');
      final summary = tester.getRect(key('customer-summary')), points = tester.getRect(key('customer-points'));
      expect(points.top >= summary.bottom, isTrue);
      await stop(tester);
    });

    testWidgets('a customer with none yet says so, where a rate is set', (tester) async {
      await pumpForm(tester, 0);
      expect(said(tester, 'customer-points'), 'No points yet');
      await stop(tester);
    });

    testWidgets('no rate was ever set, or an older hub: the card is the card it was', (tester) async {
      await pumpForm(tester, null);
      expect(key('customer-points'), findsNothing);
      await stop(tester);
      await pumpForm(tester, #none);
      expect(key('customer-points'), findsNothing);
      await stop(tester);
    });
  });
}
