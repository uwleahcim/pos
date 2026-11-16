import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/api.dart' show ApiException;
import 'package:pos_app/guests_report.dart';
import 'package:pos_app/screens/check_history_screen.dart';
import 'package:pos_app/screens/guests_screen.dart';
import 'package:pos_app/screens/location_settings_screen.dart';

import 'hub.dart';
import 'location_rows.dart';

/// The guest list (docs/guest-list.md): what a manager reads to see who the restaurant's guests are. The
/// hub does every sum; these tests are about the screen saying what the hub said, picking the lists out of
/// it, putting them in the order asked for and finding a guest by name or number.

/// Monday 16 November 2026, on the device's own clock.
int ms(int year, int month, int day, [int hour = 18]) => DateTime(year, month, day, hour).millisecondsSinceEpoch;

const linda = '7815550101', omar = '7815550102', priya = '7815550103', sam = '7815550104', tess = '7815550105';

Map<String, dynamic> favourite(String? item, String name, int count) => {'item': item, 'name': name, 'count': count};

Map<String, dynamic> guest(
  String phone,
  String name,
  int visits,
  String spent,
  String perVisit,
  String last,
  String first, {
  required int sinceMs,
  int? ordersEver,
  int lately = 0,
  bool regular = false,
  bool lapsed = false,
  bool isNew = false,
  String note = '',
  List<Map<String, dynamic>> favourites = const [],
}) => {
  'phone': phone,
  'name': name,
  'note': note,
  'visits': visits,
  'spent': spent,
  'per_visit': perVisit,
  'last': last,
  'first': first,
  'since_ms': sinceMs,
  'orders_ever': ordersEver ?? visits,
  'lately': lately,
  'regular': regular,
  'lapsed': lapsed,
  'new': isNew,
  'favourites': favourites,
};

Map<String, dynamic> about() => {
  'first': '2025-11-17',
  'last': '2026-11-16',
  'days': 365,
  'regular_visits': 3,
  'regular_days': 90,
  'lapsed_days': 60,
  'new_days': 30,
  'now_ms': ms(2026, 11, 16, 21),
};

Map<String, dynamic> lindaRow({int favourites = 3}) => guest(
  linda,
  'Linda Chen',
  5,
  '109.65',
  '21.93',
  '2026-11-14',
  '2026-03-02',
  sinceMs: ms(2025, 3, 2),
  ordersEver: 12,
  lately: 4,
  regular: true,
  note: 'Allergic to peanuts',
  favourites: [
    favourite('EGGROLL', 'Egg roll', 6),
    favourite('GTC', "General Tso's Chicken", 4),
    favourite('TSINGTAO', 'Tsingtao', 2),
    favourite(null, 'Lobster ginger scallion', 1),
    favourite('WINGS', 'Chicken wings', 1),
  ].take(favourites).toList(),
);

/// A year of five guests, the one who spent most first as the hub lists them: Omar stopped coming, Linda
/// and Priya are regulars, the number with no name is new, and Tess came once last year.
Map<String, dynamic> year() => {
  ...about(),
  'guests': [
    guest(
      omar,
      'Omar Haddad',
      4,
      '131.60',
      '32.90',
      '2026-08-20',
      '2026-02-10',
      sinceMs: ms(2026, 2, 10),
      lapsed: true,
      favourites: [favourite('DRAGON', 'Dragon roll', 5), favourite('TSINGTAO', 'Tsingtao', 4)],
    ),
    lindaRow(),
    guest(
      sam,
      '',
      2,
      '34.85',
      '17.43',
      '2026-11-10',
      '2026-11-01',
      sinceMs: ms(2026, 11, 1),
      lately: 2,
      isNew: true,
      favourites: [favourite('WINGS', 'Chicken wings', 2)],
    ),
    guest(
      priya,
      'Priya Patel',
      3,
      '26.85',
      '8.95',
      '2026-10-30',
      '2026-09-05',
      sinceMs: ms(2026, 9, 5),
      lately: 3,
      regular: true,
      favourites: [favourite('WINGS', 'Chicken wings', 3)],
    ),
    guest(tess, 'Tess Moreau', 1, '3.50', '3.50', '2025-12-20', '2025-12-20', sinceMs: ms(2025, 9, 22), ordersEver: 2),
  ],
  'totals': {'guests': 5, 'visits': 15, 'spent': '306.45', 'per_visit': '20.43', 'regulars': 2, 'lapsed': 1, 'new': 1},
};

Map<String, dynamic> visit(String id, int no, String day, String kind, String net, List<Map<String, dynamic>> dishes) =>
    {
      'order_id': id,
      'order_no': no,
      'day': day,
      'opened_ms': DateTime.parse('${day}T18:00:00').millisecondsSinceEpoch,
      'kind': kind,
      'net': net,
      'dishes': dishes,
    };

/// Linda read closely.
Map<String, dynamic> lindaClosely() => {
  ...about(),
  'guest': lindaRow(favourites: 5),
  'note_by': 'Amy',
  'note_ms': ms(2026, 11, 3),
  'latest': [
    visit('l5', 41, '2026-11-14', 'takeout', '31.90', [
      favourite('EGGROLL', 'Egg roll', 2),
      favourite('GTC', "General Tso's Chicken", 1),
    ]),
    visit('l4', 17, '2026-11-02', 'delivery', '24.90', [favourite('GTC', "General Tso's Chicken", 2)]),
    visit('l3', 8, '2026-10-10', 'dine_in', '13.00', [favourite('TSINGTAO', 'Tsingtao', 2)]),
  ],
};

Future<Terminal> pumpGuests(
  WidgetTester tester, {
  Map<String, dynamic>? guests,
  bool older = false,
  Size size = const Size(1100, 3600),
  void Function(Hub hub)? before,
}) async {
  final t = await terminal(tester);
  t.hub.guests = older ? null : (guests ?? year());
  t.hub.guestDetails = {linda: lindaClosely()};
  before?.call(t.hub);
  tester.view.physicalSize = size;
  await tester.pumpWidget(const SizedBox()); // a screen from earlier in the test is gone before this one opens
  await tester.pumpWidget(
    MaterialApp(
      home: GuestsScreen(api: t.api, token: 'tok-admin'),
    ),
  );
  await tester.pumpAndSettle();
  return t;
}

/// The list's own scrolling (the field to find a guest scrolls too, inside it).
Finder listScroll() =>
    find.descendant(of: find.byKey(const ValueKey('guests-list')), matching: find.byType(Scrollable)).first;

Future<void> tapKey(WidgetTester tester, String key) async {
  if (find.byKey(ValueKey(key)).evaluate().isEmpty) {
    await tester.scrollUntilVisible(find.byKey(ValueKey(key)), 150, scrollable: listScroll());
  }
  await tester.ensureVisible(find.byKey(ValueKey(key)));
  await tester.pumpAndSettle(); // where it scrolled to is laid out before the tap is aimed
  await tester.tap(find.byKey(ValueKey(key)));
  await tester.pumpAndSettle();
}

/// Every text inside the row with that key, in order (a line in two colours as the one line it reads as).
List<String> row(WidgetTester tester, String key) => [
  for (final text in tester.widgetList<Text>(
    find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(Text)),
  ))
    text.data ?? text.textSpan?.toPlainText() ?? '',
];

/// The guests listed, top to bottom, by what the list calls them.
List<String> listed(WidgetTester tester) => [
  for (final element in find.byWidgetPredicate((w) => w.key is ValueKey<String> && _isRow(w.key!)).evaluate())
    row(tester, (element.widget.key! as ValueKey<String>).value)[1],
];

bool _isRow(Key key) => (key as ValueKey<String>).value.startsWith('guest-row:');

String chip(WidgetTester tester, String key) =>
    (tester.widget<ChoiceChip>(find.byKey(ValueKey('guests:$key'))).label as Text).data!;

bool picked(WidgetTester tester, String key) => tester.widget<ChoiceChip>(find.byKey(ValueKey('guests:$key'))).selected;

void main() {
  group('what the list reads', () {
    test('the hub\'s answer, read into names', () {
      final report = GuestsReport.fromJson(year());
      expect((report.first, report.last, report.days), (DateTime(2025, 11, 17), DateTime(2026, 11, 16), 365));
      expect((report.regularVisits, report.regularDays, report.lapsedDays, report.newDays), (3, 90, 60, 30));
      expect(report.nowMs, ms(2026, 11, 16, 21));
      final totals = report.totals;
      expect((totals.guests, totals.visits, totals.spent, totals.perVisit), (5, 15, '306.45', '20.43'));
      expect((totals.regulars, totals.lapsed, totals.fresh), (2, 1, 1));
      final guest = report.guests[1];
      expect((guest.phone, guest.name, guest.note), (linda, 'Linda Chen', 'Allergic to peanuts'));
      expect((guest.visits, guest.spent, guest.perVisit, guest.money), (5, '109.65', '21.93', 109.65));
      expect((guest.last, guest.first), (DateTime(2026, 11, 14), DateTime(2026, 3, 2)));
      expect((guest.sinceMs, guest.ordersEver, guest.lately), (ms(2025, 3, 2), 12, 4));
      expect((guest.regular, guest.lapsed, guest.isNew), (true, false, false));
      expect(guest.favourites.map((dish) => (dish.item, dish.name, dish.count)), [
        ('EGGROLL', 'Egg roll', 6),
        ('GTC', "General Tso's Chicken", 4),
        ('TSINGTAO', 'Tsingtao', 2),
      ]);
      expect((guest.number, guest.called), ('781 555 0101', 'Linda Chen'));
      // a number no order of which has a name is called by the number
      expect((report.guests[2].name, report.guests[2].called, report.guests[2].isNew), ('', '781 555 0104', true));
      expect(report.guests.first.lapsed, isTrue);
    });

    test('one guest read closely', () {
      final detail = GuestDetail.fromJson(lindaClosely());
      expect((detail.guest.phone, detail.guest.favourites.length), (linda, 5));
      expect(detail.guest.favourites[3].item, isNull); // a dish that was typed has no code
      expect((detail.noteBy, detail.noteMs), ('Amy', ms(2026, 11, 3)));
      final latest = detail.latest.first;
      expect((latest.orderId, latest.orderNo, latest.day), ('l5', 41, DateTime(2026, 11, 14)));
      expect((latest.kind, latest.net, latest.dishWords), ('takeout', '31.90', "2 Egg roll, General Tso's Chicken"));
      expect(detail.latest.map((visit) => visit.orderId), ['l5', 'l4', 'l3']);
      // no note: nobody wrote it, at no time
      final bare = GuestDetail.fromJson({'guest': lindaRow()..['note'] = ''});
      expect((bare.noteBy, bare.noteMs), ('', null));
      expect(bare.latest, isEmpty);
    });

    test('an answer with nothing in it lists nobody', () {
      final report = GuestsReport.fromJson({'first': '2025-11-17', 'last': '2026-11-16'});
      expect(report.guests, isEmpty);
      expect((report.totals.guests, report.totals.spent, report.totals.perVisit), (0, '0.00', null));
      expect(
        (report.days, report.regularVisits, report.regularDays, report.lapsedDays, report.newDays),
        (365, 3, 90, 60, 30),
      );
    });

    test('the lists picked out of all the guests', () {
      final guests = GuestsReport.fromJson(year()).guests;
      List<String> of(GuestList list) => [for (final guest in guestsOf(guests, list)) guest.called];
      expect(of(GuestList.all), ['Omar Haddad', 'Linda Chen', '781 555 0104', 'Priya Patel', 'Tess Moreau']);
      expect(of(GuestList.regulars), ['Linda Chen', 'Priya Patel']);
      expect(of(GuestList.lapsed), ['Omar Haddad']);
      expect(of(GuestList.fresh), ['781 555 0104']);
      expect(GuestList.values.map((list) => list.words), ['All', 'Regulars', 'Stopped coming', 'New']);
    });

    test('the orders the list can stand in', () {
      final guests = GuestsReport.fromJson(year()).guests;
      List<String> names(GuestSort sort) => [for (final guest in sortedGuests(guests, sort)) guest.called];
      expect(names(GuestSort.spent), ['Omar Haddad', 'Linda Chen', '781 555 0104', 'Priya Patel', 'Tess Moreau']);
      expect(names(GuestSort.visits), ['Linda Chen', 'Omar Haddad', 'Priya Patel', '781 555 0104', 'Tess Moreau']);
      expect(names(GuestSort.latest), ['Linda Chen', '781 555 0104', 'Priya Patel', 'Omar Haddad', 'Tess Moreau']);
      // equals: the other figures tell them apart, and then the name
      Guest one(String name, String phone, {String spent = '10.00', int visits = 2, int day = 5}) => Guest(
        phone: phone,
        name: name,
        spent: spent,
        visits: visits,
        last: DateTime(2026, 11, day),
        first: DateTime(2026),
      );
      final same = [one('beth', '3'), one('Adam', '2'), one('Carl', '1', day: 9), one('Dora', '4', visits: 3)];
      expect([for (final guest in sortedGuests(same, GuestSort.spent)) guest.name], ['Dora', 'Carl', 'Adam', 'beth']);
      expect([for (final guest in sortedGuests(same, GuestSort.latest)) guest.name], ['Carl', 'Dora', 'Adam', 'beth']);
      expect(GuestSort.values.map((sort) => sort.words), ['Spent', 'Visits', 'Latest']);
    });

    test('a guest is found by the words of their name, or by digits of their number', () {
      final guests = GuestsReport.fromJson(year()).guests;
      List<String> named(String words) => [for (final guest in guestsNamed(guests, words)) guest.called];
      expect(named('chen'), ['Linda Chen']);
      expect(named('PATEL pri'), ['Priya Patel']);
      expect(named('a'), ['Omar Haddad', 'Linda Chen', 'Priya Patel', 'Tess Moreau']);
      expect(named('0104'), ['781 555 0104']);
      expect(named('(781) 555-0102'), ['Omar Haddad']);
      expect(named('+1 781 555 0103'), ['Priya Patel']);
      expect(named('555 01'), hasLength(5));
      expect(named('  '), hasLength(5));
      expect(named('pizza'), isEmpty);
      expect(named('9999'), isEmpty);
    });
  });

  group('the calls', () {
    testWidgets('carry the manager\'s token, and one guest is asked for by the digits of the number', (tester) async {
      final t = await terminal(tester);
      t.hub.guests = year();
      t.hub.guestDetails = {linda: lindaClosely()};
      final report = await t.api.guestsReport('tok-admin');
      expect(t.hub.guestsAsks, 1);
      expect(t.hub.guestsAuth, 'Bearer tok-admin');
      expect(report.guests, hasLength(5));
      t.hub.guestsAuth = null;
      final detail = await t.api.guestDetail('tok-admin', '(781) 555-0101');
      expect(t.hub.guestAsks, [linda]);
      expect(t.hub.guestsAuth, 'Bearer tok-admin');
      expect(detail.latest, hasLength(3));
      // a number with no visit in the year
      await expectLater(
        t.api.guestDetail('tok-admin', omar),
        throwsA(
          isA<ApiException>()
              .having((err) => err.status, 'status', 404)
              .having((err) => err.detail?['error'], 'error', 'no_guest'),
        ),
      );
    });
  });

  group('the screen', () {
    testWidgets('Location settings opens Guests with the manager\'s token', (tester) async {
      final t = await terminal(tester);
      t.hub.guests = year();
      tester.view.physicalSize = const Size(1100, 2800);
      await tester.pumpWidget(
        MaterialApp(
          home: LocationSettingsScreen(api: t.api, token: 'tok-admin', device: 't1'),
        ),
      );
      await tester.pumpAndSettle();
      await bringUp(tester, 'guests-report');
      expect(find.text('Phone customers: visits, what they spent, favourites'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('guests-report')));
      await tester.pumpAndSettle();
      expect(find.byType(GuestsScreen), findsOneWidget);
      expect(t.hub.guestsAsks, 1);
      expect(t.hub.guestsAuth, 'Bearer tok-admin');
      expect(find.byKey(const ValueKey('guests-total')), findsOneWidget);
    });

    testWidgets('it opens on every guest of the year, the one who spent most first', (tester) async {
      final t = await pumpGuests(tester);
      expect(t.hub.guestsAsks, 1);
      expect(t.hub.guestAsks, isEmpty); // nobody is read closely until they are opened
      expect(find.text('The last 12 months'), findsOneWidget);
      expect(find.text('Everyone who ordered with a phone number, Nov 17, 2025 to Nov 16, 2026.'), findsOneWidget);
      expect(row(tester, 'guests-total'), ['Guests', '5', '2 regulars · 1 stopped coming · 1 new']);
      expect(row(tester, 'guests-spent'), ['They spent', r'$306.45', r'15 visits · $20.43 a visit']);
      expect(
        [
          for (final key in ['all', 'regulars', 'lapsed', 'new']) chip(tester, key),
        ],
        ['All 5', 'Regulars 2', 'Stopped coming 1', 'New 1'],
      );
      expect(picked(tester, 'all'), isTrue);
      expect(listed(tester), ['Omar Haddad', 'Linda Chen', '781 555 0104', 'Priya Patel', 'Tess Moreau']);
      expect(row(tester, 'guest-row:$omar'), [
        '1',
        'Omar Haddad',
        '4 visits',
        r'$131.60',
        '781 555 0102 · last Aug 20 · stopped coming',
      ]);
      expect(row(tester, 'guest-row:$linda'), [
        '2',
        'Linda Chen',
        '5 visits',
        r'$109.65',
        '781 555 0101 · last Nov 14 · regular',
      ]);
      // no name on any order: the number is what they are called, and it is not said twice
      expect(row(tester, 'guest-row:$sam'), ['3', '781 555 0104', '2 visits', r'$34.85', 'last Nov 10 · new']);
      // one visit, and a day of last year says its year
      expect(row(tester, 'guest-row:$tess'), [
        '5',
        'Tess Moreau',
        '1 visit',
        r'$3.50',
        '781 555 0105 · last Dec 20, 2025',
      ]);
      expect(find.text('5 guests'), findsOneWidget);
      expect(find.byKey(const ValueKey('guests-note')), findsOneWidget);
    });

    testWidgets('Regulars, Stopped coming and New are each a list, numbered from one, that says what it means', (
      tester,
    ) async {
      await pumpGuests(tester);
      await tapKey(tester, 'guests:regulars');
      expect((picked(tester, 'regulars'), picked(tester, 'all')), (true, false));
      expect(listed(tester), ['Linda Chen', 'Priya Patel']);
      expect(row(tester, 'guest-row:$priya').first, '2');
      expect(find.text('2 guests: 3 visits or more in the last 90 days'), findsOneWidget);
      await tapKey(tester, 'guests:lapsed');
      expect(listed(tester), ['Omar Haddad']);
      expect(find.text('1 guest: 3 visits or more in the year, and none for 60 days'), findsOneWidget);
      await tapKey(tester, 'guests:new');
      expect(listed(tester), ['781 555 0104']);
      expect(find.text('1 guest: their first order ever was in the last 30 days'), findsOneWidget);
      // the totals above stay those of every guest
      expect(row(tester, 'guests-total')[1], '5');
      await tapKey(tester, 'guests:all');
      expect(listed(tester), hasLength(5));
      // a list with nobody on it says so, in the hub's own numbers
      final quiet = year();
      quiet['guests'] = [(quiet['guests'] as List)[4]];
      quiet['totals'] = {'guests': 1, 'visits': 1, 'spent': '3.50', 'per_visit': '3.50'};
      quiet['regular_visits'] = 4;
      quiet['regular_days'] = 60;
      await pumpGuests(tester, guests: quiet);
      expect(chip(tester, 'regulars'), 'Regulars 0');
      expect(row(tester, 'guests-total'), ['Guests', '1', '0 regulars · 0 stopped coming · 0 new']);
      expect(row(tester, 'guests-spent'), ['They spent', r'$3.50', r'1 visit · $3.50 a visit']);
      await tapKey(tester, 'guests:regulars');
      expect(listed(tester), isEmpty);
      expect(find.text('No guest here.'), findsOneWidget);
      expect(find.textContaining('A regular came 4 times or more in the last 60 days.'), findsOneWidget);
    });

    testWidgets('Visits ranks by how often they came, and Latest by who was here last', (tester) async {
      await pumpGuests(tester);
      await tapKey(tester, 'guests-by:visits');
      expect(listed(tester), ['Linda Chen', 'Omar Haddad', 'Priya Patel', '781 555 0104', 'Tess Moreau']);
      expect(row(tester, 'guest-row:$linda').first, '1');
      await tapKey(tester, 'guests-by:latest');
      expect(listed(tester), ['Linda Chen', '781 555 0104', 'Priya Patel', 'Omar Haddad', 'Tess Moreau']);
      // the order stays when another list is picked
      await tapKey(tester, 'guests:regulars');
      expect(listed(tester), ['Linda Chen', 'Priya Patel']);
      await tapKey(tester, 'guests-by:spent');
      await tapKey(tester, 'guests:all');
      expect(listed(tester).first, 'Omar Haddad');
    });

    testWidgets('a guest is found by name or by number while the keyboard stays, and nobody found is said', (
      tester,
    ) async {
      await pumpGuests(tester);
      await tester.tap(find.byKey(const ValueKey('guests-find')));
      await tester.pump();
      await tester.enterText(find.byKey(const ValueKey('guests-find')), 'chen');
      await tester.pumpAndSettle();
      expect(listed(tester), ['Linda Chen']);
      expect(find.text('1 guest'), findsOneWidget);
      expect(row(tester, 'guest-row:$linda').first, '1');
      final field = tester.widget<EditableText>(
        find.descendant(of: find.byKey(const ValueKey('guests-find')), matching: find.byType(EditableText)),
      );
      expect(field.focusNode.hasFocus, isTrue);
      await tester.enterText(find.byKey(const ValueKey('guests-find')), '555-0104');
      await tester.pumpAndSettle();
      expect(listed(tester), ['781 555 0104']);
      await tester.enterText(find.byKey(const ValueKey('guests-find')), 'pizza');
      await tester.pumpAndSettle();
      expect(listed(tester), isEmpty);
      expect(find.text('No guest by that name or number.'), findsOneWidget);
      await tapKey(tester, 'guests-find-clear');
      expect(listed(tester), hasLength(5));
      // within one list
      await tapKey(tester, 'guests:regulars');
      await tester.enterText(find.byKey(const ValueKey('guests-find')), 'a');
      await tester.pumpAndSettle();
      expect(listed(tester), ['Linda Chen', 'Priya Patel']);
      await tester.enterText(find.byKey(const ValueKey('guests-find')), 'omar');
      await tester.pumpAndSettle();
      expect(find.text('No guest by that name or number.'), findsOneWidget);
    });

    testWidgets('a regular is green and one who stopped coming is red; a new guest is neither', (tester) async {
      await pumpGuests(tester);
      TextSpan last(String key) {
        final line = tester
            .widgetList<Text>(find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(Text)))
            .firstWhere((text) => text.textSpan != null);
        return (line.textSpan! as TextSpan).children!.last as TextSpan;
      }

      final error = Theme.of(tester.element(find.byKey(const ValueKey('guests-total')))).colorScheme.error;
      expect((last('guest-row:$omar').text, last('guest-row:$omar').style!.color), ('stopped coming', error));
      expect(last('guest-row:$linda').text, 'regular');
      expect(last('guest-row:$linda').style!.color, isNot(error));
      expect(last('guest-row:$linda').style!.color, isNotNull);
      expect(last('guest-row:$priya').style!.color, last('guest-row:$linda').style!.color);
      expect(last('guest-row:$sam').text, 'last Nov 10 · new');
      expect(last('guest-row:$sam').style, isNull);
    });

    testWidgets('a guest opens to their note, favourite dishes and latest visits, and closes again', (tester) async {
      final t = await pumpGuests(tester);
      expect(find.byKey(const ValueKey('guest-more:$linda')), findsNothing);
      // what the list already knows is there at once; the visits come when the hub has read them
      final held = t.hub.guestHeld = Completer<void>();
      await tester.tap(find.byKey(const ValueKey('guest-row:$linda')));
      await tester.pump();
      await tester.pump();
      expect(t.hub.guestAsks, [linda]);
      expect(t.hub.guestsAuth, 'Bearer tok-admin');
      expect(find.byKey(const ValueKey('guest-reading:$linda')), findsOneWidget);
      expect(row(tester, 'guest-more:$linda'), [
        'Note: Allergic to peanuts',
        'A guest since Mar 2, 2025 · 12 orders in all',
        r'$21.93 a visit · 4 visits in the last 90 days',
        'Favourite dishes',
        'Egg roll',
        '6×',
        "General Tso's Chicken",
        '4×',
        'Tsingtao',
        '2×',
        'Latest visits',
      ]);
      held.complete();
      t.hub.guestHeld = null;
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('guest-reading:$linda')), findsNothing);
      expect(row(tester, 'guest-more:$linda'), [
        'Note: Allergic to peanuts (Amy, Nov 3)',
        'A guest since Mar 2, 2025 · 12 orders in all',
        r'$21.93 a visit · 4 visits in the last 90 days',
        'Favourite dishes',
        'Egg roll',
        '6×',
        "General Tso's Chicken",
        '4×',
        'Tsingtao',
        '2×',
        'Lobster ginger scallion',
        '1×',
        'Chicken wings',
        '1×',
        'Latest visits',
        'Sat, Nov 14 · To go',
        r'$31.90',
        "2 Egg roll, General Tso's Chicken",
        'Mon, Nov 2 · Delivery',
        r'$24.90',
        "2 General Tso's Chicken",
        'Sat, Oct 10 · Tables',
        r'$13.00',
        '2 Tsingtao',
      ]);
      // closed and opened again: the hub is not asked twice
      await tapKey(tester, 'guest-row:$linda');
      expect(find.byKey(const ValueKey('guest-more:$linda')), findsNothing);
      await tapKey(tester, 'guest-row:$linda');
      expect(find.byKey(const ValueKey('guest-visit:$linda:l5')), findsOneWidget);
      expect(t.hub.guestAsks, [linda]);
    });

    testWidgets('a visit opens the history of its check', (tester) async {
      final t = await pumpGuests(tester);
      await tapKey(tester, 'guest-row:$linda');
      await tapKey(tester, 'guest-visit:$linda:l4');
      expect(find.byType(CheckHistoryScreen), findsOneWidget);
      expect(t.hub.historyAsks, ['l4']);
      expect(t.hub.historyAuth, 'Bearer tok-admin');
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(CheckHistoryScreen), findsNothing);
      expect(find.byKey(const ValueKey('guest-more:$linda')), findsOneWidget); // the guest is still open
    });

    testWidgets('a guest the hub cannot read closely says why, each guest by itself, and can be asked again', (
      tester,
    ) async {
      final t = await pumpGuests(tester, before: (hub) => hub.refuseGuest = 401);
      await tapKey(tester, 'guest-row:$linda');
      String said(String phone) => tester.widget<Text>(find.byKey(ValueKey('guest-error:$phone'))).data!;
      expect(said(linda), "The manager's hour here is over: go back and open Location again.");
      // what the list knows of them is still there
      expect(find.text('A guest since Mar 2, 2025 · 12 orders in all'), findsOneWidget);
      expect(find.byKey(const ValueKey('guest-dish:$linda:Egg roll')), findsOneWidget);
      t.hub.refuseGuest = null;
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('guest-error:$linda')), findsNothing);
      expect(find.byKey(const ValueKey('guest-visit:$linda:l5')), findsOneWidget);
      // a guest whose last visit has just left the year: the hub's own words, not "an older hub"
      await tapKey(tester, 'guest-row:$tess');
      expect(said(tess), 'No visit from this number in the last year.');
      expect(find.text('A guest since Sep 22, 2025 · 2 orders in all'), findsOneWidget);
      expect(find.byKey(const ValueKey('guest-visit:$linda:l5')), findsOneWidget);
      expect(t.hub.guestAsks, [linda, linda, tess]);
    });

    testWidgets('Read again asks the hub for the list and for every guest that is open', (tester) async {
      final t = await pumpGuests(tester);
      await tapKey(tester, 'guest-row:$linda');
      final moved = year();
      (moved['guests'] as List)[1] = lindaRow()
        ..['visits'] = 6
        ..['spent'] = '140.65';
      moved['totals'] = {...moved['totals'] as Map<String, dynamic>, 'visits': 16, 'spent': '337.45'};
      t.hub.guests = moved;
      t.hub.guestDetails = {
        linda: {
          ...lindaClosely(),
          'latest': [
            visit('l6', 52, '2026-11-16', 'takeout', '31.00', [favourite('GTC', "General Tso's Chicken", 2)]),
          ],
        },
      };
      await tester.tap(find.byKey(const ValueKey('guests-refresh')));
      await tester.pumpAndSettle();
      expect(t.hub.guestsAsks, 2);
      expect(t.hub.guestAsks, [linda, linda]);
      expect(listed(tester).first, 'Linda Chen');
      expect(row(tester, 'guest-row:$linda').sublist(2, 4), ['6 visits', r'$140.65']);
      expect(find.byKey(const ValueKey('guest-visit:$linda:l6')), findsOneWidget);
      expect(find.byKey(const ValueKey('guest-visit:$linda:l5')), findsNothing);
      expect(row(tester, 'guests-spent')[1], r'$337.45');
    });

    testWidgets('another list or order starts from its top; reading again stays where it was', (tester) async {
      final many = year();
      many['guests'] = [
        for (var i = 0; i < 60; i++)
          guest(
            '78155502${'$i'.padLeft(2, '0')}',
            'Guest number $i',
            60 - i,
            '${900 - i}.00',
            '15.00',
            '2026-10-${'${1 + i % 28}'.padLeft(2, '0')}',
            '2026-01-05',
            sinceMs: ms(2026, 1, 5),
            regular: i.isEven,
          ),
      ];
      many['totals'] = {'guests': 60, 'visits': 1830, 'spent': '52230.00', 'per_visit': '28.54', 'regulars': 30};
      await pumpGuests(tester, size: const Size(390, 844), guests: many);
      expect(tester.takeException(), isNull);
      expect(chip(tester, 'all'), 'All 60');
      double offset() => tester.state<ScrollableState>(listScroll()).position.pixels;
      Future<void> down() async {
        await tester.drag(find.byKey(const ValueKey('guests-list')), const Offset(0, -150));
        await tester.pumpAndSettle();
      }

      await down();
      final scrolled = offset();
      expect(scrolled, greaterThan(100));
      await tester.tap(find.byKey(const ValueKey('guests-refresh')));
      await tester.pumpAndSettle();
      expect(offset(), scrolled);
      await tester.tap(find.byKey(const ValueKey('guests:regulars')));
      await tester.pumpAndSettle();
      expect(offset(), 0);
      expect(listed(tester).first, 'Guest number 0');
      await down();
      await tester.ensureVisible(find.byKey(const ValueKey('guests-by:latest')));
      await tester.pumpAndSettle();
      expect(offset(), greaterThan(0));
      await tester.tap(find.byKey(const ValueKey('guests-by:latest')));
      await tester.pumpAndSettle();
      expect(offset(), 0);
      // far down a long list the rows are still numbered and named
      await tester.tap(find.byKey(const ValueKey('guests:all')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('guests-by:spent')));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.byKey(const ValueKey('guests-note')), 400, scrollable: listScroll());
      expect(row(tester, 'guest-row:7815550259').take(2), ['60', 'Guest number 59']);
      expect(tester.takeException(), isNull);
    });

    testWidgets('while the hub reads the year, the screen says so, and the lists wait for their counts', (
      tester,
    ) async {
      final held = Completer<void>();
      final t = await terminal(tester);
      t.hub
        ..guests = year()
        ..guestsHeld = held;
      await tester.pumpWidget(
        MaterialApp(
          home: GuestsScreen(api: t.api, token: 'tok-admin'),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('guests-reading')), findsOneWidget);
      expect(find.text('Many days can take some seconds the first time.'), findsOneWidget);
      expect(find.byKey(const ValueKey('guests-total')), findsNothing);
      expect(chip(tester, 'regulars'), 'Regulars');
      held.complete();
      t.hub.guestsHeld = null;
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('guests-reading')), findsNothing);
      expect(chip(tester, 'regulars'), 'Regulars 2');
      expect(listed(tester), hasLength(5));
    });

    testWidgets('the manager\'s hour is over, the hub is older, refuses or does not answer: the screen says which', (
      tester,
    ) async {
      final over = await pumpGuests(tester, before: (hub) => hub.refuseGuests = 401);
      expect(find.text("The manager's hour here is over: go back and open Location again."), findsOneWidget);
      expect(over.hub.guestsAsks, 0);
      await pumpGuests(tester, older: true);
      expect(find.text('This hub is older than the guest list. Update the hub to see it here.'), findsOneWidget);
      final refused = await pumpGuests(
        tester,
        before: (hub) => hub
          ..refuseGuests = 409
          ..salesRefusal = 'The hub could not read its orders.',
      );
      expect(find.text('The hub could not read its orders.'), findsOneWidget);
      refused.hub.refuseGuests = null;
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('guests-error')), findsNothing);
      expect(row(tester, 'guests-total')[1], '5');
      final down = await pumpGuests(tester, before: (hub) => hub.down = true);
      expect(find.text('The hub is not answering'), findsOneWidget);
      down.hub.down = false;
    });

    testWidgets('on a small phone a long list fits, guests open, in the dark too', (tester) async {
      final big = year();
      big['guests'] = [
        for (var i = 0; i < 40; i++)
          guest(
            '78155503${'$i'.padLeft(2, '0')}',
            'Bartholomew Maximilian Featherstonehaugh-Cholmondeley the $i',
            123456 - i,
            '12345678.90',
            '1234.56',
            '2025-12-${'${1 + i % 28}'.padLeft(2, '0')}',
            '2025-11-20',
            sinceMs: ms(2021, 1, 5),
            ordersEver: 1234567,
            lately: 123456,
            regular: i.isEven,
            lapsed: i.isOdd,
            isNew: true,
            note: 'Allergic to peanuts, shellfish and sesame; always asks for the round table by the window',
            favourites: [
              favourite('D1', 'Chef\'s seasonal speciality with three delights and scallions', 123456),
              favourite(null, 'Lobster ginger scallion, twice cooked, sauce on the side', 12345),
            ],
          ),
      ];
      big['totals'] = {
        'guests': 1234567,
        'visits': 12345678,
        'spent': '1234567890.12',
        'per_visit': '12345.67',
        'regulars': 123456,
        'lapsed': 123456,
        'new': 123456,
      };
      Map<String, dynamic> closely(String phone) => {
        ...about(),
        'guest': (big['guests'] as List).cast<Map<String, dynamic>>().firstWhere((row) => row['phone'] == phone),
        'note_by': 'Bartholomew the manager of the evening',
        'note_ms': ms(2025, 11, 3),
        'latest': [
          for (var n = 0; n < 10; n++)
            visit('v$phone$n', 1000 + n, '2025-12-${10 + n}', n.isEven ? 'takeout' : 'dine_in', '123456.78', [
              favourite('D1', 'Chef\'s seasonal speciality with three delights and scallions', 12),
              favourite(null, 'Lobster ginger scallion, twice cooked, sauce on the side', 3),
            ]),
        ],
      };
      for (final dark in [false, true]) {
        final t = await terminal(tester);
        t.hub.guests = big;
        t.hub.guestDetails = {'7815550300': closely('7815550300'), '7815550301': closely('7815550301')};
        tester.view.physicalSize = const Size(320, 568);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(
          MaterialApp(
            theme: dark ? ThemeData.dark() : null,
            home: GuestsScreen(api: t.api, token: 'tok-admin'),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tapKey(tester, 'guest-row:7815550300');
        await tapKey(tester, 'guest-row:7815550301');
        expect(tester.takeException(), isNull);
        for (var i = 0; i < 8; i++) {
          await tester.drag(find.byKey(const ValueKey('guests-list')), const Offset(0, -500));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }
        await tester.drag(find.byKey(const ValueKey('guests-list')), const Offset(0, 9000));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('guests:lapsed')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
    });
  });
}
