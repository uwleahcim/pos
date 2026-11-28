import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/powers.dart';
import 'package:pos_app/screens/location_search.dart';
import 'package:pos_app/screens/location_settings_screen.dart';
import 'package:pos_app/screens/spotlight.dart';
import 'package:pos_app/setting_search.dart';

import 'hub.dart';
import 'location_rows.dart';

/// The search of Location settings (the owner, 2026-11-27: "implement a search for location settings").
/// A magnifier at the top of the screen; what is typed lists the settings it finds, the rows of the screen
/// and the settings inside the pages and dialogs they open, best match first; a tap goes to the setting and
/// lights it. Read docs/location-settings.md, "Finding a setting".

const phone = Size(390, 844);
const smallPhone = Size(320, 568);
const tablet = Size(1100, 800);

Finder key(String name) => find.byKey(ValueKey(name));

/// A result of the search, by the key of its row and, for a setting inside the row's page, its spot.
Finder found(String id) => key('found:$id');

/// Location settings as a manager's PIN opens it (or the PIN of someone who [holds] these powers).
Future<Terminal> pumpLocation(
  WidgetTester tester, {
  Size size = phone,
  Set<String>? holds,
  double textScale = 1,
  void Function(Hub hub) hub = everything,
}) async {
  final t = await terminal(tester);
  hub(t.hub);
  tester.view.physicalSize = size;
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              key: const ValueKey('open-location'),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  settings: const RouteSettings(name: 'location'),
                  builder: (_) =>
                      LocationSettingsScreen(api: t.api, token: 'tok-admin', holds: holds, staffId: 's3', device: 't1'),
                ),
              ),
              child: const Text('Location'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(key('open-location'));
  await tester.pumpAndSettle();
  return t;
}

/// Opens the search (when it is not open) and types.
Future<void> search(WidgetTester tester, String typed) async {
  if (key('location-search-box').evaluate().isEmpty) {
    await tester.tap(key('location-search'));
    await tester.pumpAndSettle();
  }
  await tester.enterText(key('location-search-box'), typed);
  await tester.pumpAndSettle();
}

/// The names of what the search lists, in its order.
List<String> listed(WidgetTester tester) => [
  for (final tile in tester.widgetList<ListTile>(
    find.descendant(of: key('location-search-results'), matching: find.byType(ListTile)),
  ))
    (tile.title! as Text).textSpan!.toPlainText(),
];

/// What a result says under its name.
String? saysUnder(WidgetTester tester, String id) => ((tester.widget<ListTile>(found(id)).subtitle) as Text?)?.data;

Future<void> pick(WidgetTester tester, String id) async {
  await tester.ensureVisible(found(id));
  await tester.pumpAndSettle();
  await tester.tap(found(id));
  await tester.pumpAndSettle();
}

/// Whether the keyboard's focus is on [finder] or on something in it.
bool focusIn(WidgetTester tester, Finder finder) {
  final at = FocusManager.instance.primaryFocus?.context;
  if (at == null) return false;
  final target = tester.element(finder);
  var inside = at == target;
  at.visitAncestorElements((above) {
    inside = inside || above == target;
    return !inside;
  });
  return inside;
}

/// Whether what [finder] finds is on the screen where a finger could reach it: itself, or (a row that is
/// empty at its middle, words at one end and buttons at the other) the words in it.
bool onScreen(Finder finder) {
  if (finder.evaluate().isEmpty) return false;
  if (finder.hitTestable().evaluate().isNotEmpty) return true;
  return find.descendant(of: finder, matching: find.byType(RichText)).hitTestable().evaluate().isNotEmpty;
}

/// The finder of a [Spot]: the widget with its key, or the text that reads its words.
Finder spotFinder(Spot spot) => spot.key != null ? key(spot.key!) : find.text(spot.words!);

/// The navigator's top route goes: a dialog or a page a result opened.
Future<void> back(WidgetTester tester) async {
  tester.state<NavigatorState>(find.byType(Navigator)).pop();
  await tester.pumpAndSettle();
}

/// Whether Location settings is what is on top: no page or dialog is open over it.
bool atLocation(WidgetTester tester) =>
    ModalRoute.of(tester.element(find.byType(LocationSettingsScreen, skipOffstage: false)))!.isCurrent;

/// Everything open over Location settings goes.
Future<void> backToLocation(WidgetTester tester) async {
  tester.state<NavigatorState>(find.byType(Navigator)).popUntil((route) => route.settings.name == 'location');
  await tester.pumpAndSettle();
}

List<String> titles(String typed, {Iterable<SettingEntry>? among}) => [
  for (final entry in findSettings(typed, among ?? locationSettings)) entry.title,
];

void main() {
  group('what a word finds', () {
    test('the row by its name comes first, then what is inside it', () {
      final fee = titles('delivery fee');
      expect(fee.first, 'Delivery fee');
      expect(fee, containsAll(['Charge for delivery', 'Charge sales tax on the fee', 'Restaurant address']));
      expect(titles('printers').first, 'Printers');
      expect(titles('printer').first, 'Printers', reason: 'the start of the name finds it');
      expect(titles('voids').first, 'Voids');
      expect(titles('points').first, 'Points');
      expect(titles('time clock').first, 'Time clock');
    });

    test('the words may come in any order, in capitals or not, with small words between', () {
      expect(titles('fee delivery').first, 'Delivery fee');
      expect(titles('STAFF pins').first, 'Staff and PINs');
      expect(titles('the fee for a delivery').first, 'Delivery fee');
      expect(titles('how do i add a printer').first, 'Add printer');
    });

    test('a setting inside a page is found by its own name', () {
      expect(titles('sales tax').first, 'Charge sales tax on the fee');
      expect(titles('tax'), containsAll(['Charge sales tax on the fee', 'Approve a tax-exempt check']));
      expect(titles('pay week').first, 'The pay week starts on');
      expect(titles('amber'), containsAll(['Minutes until amber', 'Table timers']));
      expect(titles('foot of the bill').first, 'Foot of the bill');
      expect(titles('breaks').first, 'Breaks count as time worked');
    });

    test('every power and every key of the hub is found by its name', () {
      expect(titles('approve a void').first, 'Approve a void');
      expect(titles('edit the menu').first, 'Edit the menu');
      expect(titles('twilio').first, 'Texts to customers (Twilio)');
      expect(titles('google maps').first, 'Google Maps');
      expect(titles('cloudflare').first, 'Cloudflare Tunnel (the way in)');
    });

    test('the words people say for a setting that its name does not have', () {
      expect(titles('86').first, 'Sold out and running low');
      expect(titles('permissions').first, 'Who may do what');
      expect(titles('loyalty').first, 'Points');
      expect(titles('receipt'), containsAll(['The bill', 'Printers']));
      expect(titles('employees').first, 'Staff and PINs');
      expect(titles('password').first, 'Staff and PINs');
      expect(titles('payroll'), containsAll(['Hours', 'Time clock', 'The pay week starts on']));
      expect(titles('fallback').first, 'When it is down, print its tickets at');
      expect(titles('nfc').first, 'Sign in by face');
    });

    test('run together, split or with an ending, a word still finds it', () {
      expect(titles('togo').first, 'To-go question');
      expect(titles('to go').first, 'To-go question');
      expect(titles('to-go question').first, 'To-go question');
      expect(titles('handsfree'), contains('Switch to whoever steps up'));
      expect(titles('timers').first, 'Table timers');
      expect(titles('taxes'), contains('Charge sales tax on the fee'));
      expect(titles("manager's log").first, "Manager's log");
      expect(titles('managers log').first, "Manager's log");
    });

    test('a typing mistake is forgiven when nothing is found as typed', () {
      expect(titles('recipt'), containsAll(['The bill', 'Printers']));
      expect(titles('delviery fee').first, 'Delivery fee');
      expect(titles('printr').first, 'Printers');
      expect(titles('pionts').first, 'Points');
      // not when the word as typed finds something: no guesses among real matches
      expect(titles('print'), isNot(contains('Points')));
    });

    test('every word typed must be found, and nonsense finds nothing', () {
      expect(titles('delivery printer'), isEmpty);
      expect(titles('zzzz'), isEmpty);
      expect(titles(''), isEmpty);
      expect(titles('   '), isEmpty);
    });

    test('only among the settings that are on the screen', () {
      final reports = [
        for (final entry in locationSettings)
          if (entry.row.endsWith('-report')) entry,
      ];
      expect(titles('printers', among: reports), isEmpty);
      expect(titles('sales', among: reports).first, 'Sales');
    });

    test('each setting is the first one its own name finds', () {
      // a name two settings share (Time clock on an older hub, Add reason in two dialogs) finds one of them
      for (final entry in locationSettings) {
        expect(titles(entry.title).first, entry.title, reason: 'typed: ${entry.title}');
      }
    });

    test('the list holds together: a setting inside or under a row names a row of the list', () {
      final ids = <String>{};
      for (final entry in locationSettings) {
        expect(ids.add(SettingResults.idOf(entry)), isTrue, reason: 'listed twice: ${SettingResults.idOf(entry)}');
        if (entry.isRow) continue;
        expect(locationRows, contains(entry.under ?? entry.row), reason: entry.title);
        expect(entry.spot != null && entry.under != null, isFalse, reason: '${entry.title}: inside a row or under one');
      }
      // every power the app knows and every key it words is there, so a new one is found without a line here
      final spots = {for (final entry in locationSettings) entry.spot?.key};
      for (final power in powersById.keys) {
        expect(spots, contains('power:$power'));
      }
    });

    test('what was typed is marked in a name', () {
      String marked(String typed, String title) =>
          [for (final (start, end) in foundIn(typed, title)) title.substring(start, end)].join('|');
      expect(marked('deliv', 'Delivery fee'), 'Deliv');
      expect(marked('fee delivery', 'Delivery fee'), 'Delivery|fee');
      expect(marked('tax', 'Charge sales tax on the fee'), 'tax');
      expect(marked('pin', 'Staff and PINs'), 'PIN');
      expect(marked('the bill', 'The bill'), 'bill', reason: 'a small word beside a telling one is not marked');
      expect(marked('zzz', 'Delivery fee'), '');
    });
  });

  group('on Location settings', () {
    testWidgets('a magnifier at the top opens the search; what is typed lists what it finds', (tester) async {
      await pumpLocation(tester);
      expect(find.text('Location settings'), findsOneWidget);
      expect(tester.widget<IconButton>(key('location-search')).tooltip, 'Search the settings');
      expect(key('location-search-box'), findsNothing);

      await tester.tap(key('location-search'));
      await tester.pumpAndSettle();
      // the box stands where the title was and has the keyboard; the screen is still there under it
      expect(find.text('Location settings'), findsNothing);
      expect(find.text('Search the settings'), findsOneWidget);
      expect(tester.widget<EditableText>(find.byType(EditableText).first).focusNode.hasFocus, isTrue);
      expect(onScreen(key('board')), isTrue);
      expect(key('location-search-results'), findsNothing);

      await search(tester, 'delivery');
      expect(listed(tester).first, 'Delivery fee');
      expect(listed(tester), containsAll(['Quote times', 'Charge for delivery', 'Take deliveries out']));
      expect(saysUnder(tester, 'delivery-fee'), 'What a delivery costs, by the miles or by the minutes of the drive');
      expect(saysUnder(tester, 'delivery-fee/fee-enabled'), 'In Delivery fee');
      expect(
        saysUnder(tester, 'quote-times'),
        'The minutes promised for a new order: counter, phone, online, delivery',
      );
      expect(onScreen(key('board')), isFalse, reason: 'the results stand where the list was');

      // each letter narrows it
      await search(tester, 'delivery fee');
      expect(listed(tester).first, 'Delivery fee');
      expect(listed(tester), isNot(contains('Take deliveries out')));
    });

    testWidgets('nothing found says so, and what to try', (tester) async {
      await pumpLocation(tester);
      await search(tester, 'zzzz');
      expect(find.text('Nothing here is called "zzzz"'), findsOneWidget);
      expect(key('location-search-results'), findsNothing);
      await search(tester, 'tax');
      expect(key('location-search-none'), findsNothing);
      expect(listed(tester), isNotEmpty);
    });

    testWidgets('the cross, Escape and Back each close the search and leave the screen as it was', (tester) async {
      await pumpLocation(tester);
      // scrolled down a little, to see that the list is where it was afterwards
      await tester.drag(find.byType(ListView).first, const Offset(0, -300));
      await tester.pumpAndSettle();
      final before = tester.getTopLeft(key('today')).dy;

      await search(tester, 'printers');
      await tester.tap(key('location-search-close'));
      await tester.pumpAndSettle();
      expect(key('location-search-box'), findsNothing);
      expect(find.text('Location settings'), findsOneWidget);
      expect(tester.getTopLeft(key('today')).dy, before);

      await search(tester, 'printers');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(key('location-search-box'), findsNothing);

      // Back closes the search first, and only then leaves the screen
      await search(tester, 'printers');
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(key('location-search-box'), findsNothing);
      expect(find.byType(LocationSettingsScreen), findsOneWidget);
      // opened again, it starts empty
      await tester.tap(key('location-search'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(key('location-search-box')).controller!.text, '');
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(LocationSettingsScreen), findsNothing);
    });

    testWidgets('a setting on the screen itself: the search closes, the screen scrolls to it and it is lit', (
      tester,
    ) async {
      await pumpLocation(tester);
      expect(onScreen(key('seats-enabled')), isFalse, reason: 'far down the list on a phone');
      await search(tester, 'seat');
      expect(listed(tester).first, 'Seat numbers');
      expect(tester.widget<ListTile>(found('seats-enabled')).trailing, isNull, reason: 'it opens nothing');
      await tester.tap(found('seats-enabled'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600)); // the screen has scrolled there
      expect(key('location-search-box'), findsNothing);
      expect(onScreen(key('seats-enabled')), isTrue);
      // lit: the ring is on the row
      final light = tester.state<SpotlightState>(find.byType(Spotlight).first);
      expect(light.litRect, isNotNull);
      final row = tester.getRect(key('seats-enabled'));
      final list = tester.getRect(find.byType(Spotlight).first);
      expect(light.litRect!.shift(list.topLeft), row.inflate(2));
      // and the keyboard goes on from it
      expect(focusIn(tester, key('seats-enabled')), isTrue);
      await tester.pumpAndSettle();
      expect(light.litRect, isNull, reason: 'the light fades by itself');
      // the switch is the switch: one tap and it waits for Save, as ever
      await tester.tap(key('seats-enabled'));
      await tester.pumpAndSettle();
      expect(saveWaiting(tester), 'Not saved: seats');
    });

    testWidgets('a setting that is under another: found where it stands, or at its row while it is not shown', (
      tester,
    ) async {
      await pumpLocation(
        tester,
        hub: (hub) {
          everything(hub);
          // the time clock is off: its breaks are not on the screen
          hub.timeClock = {'enabled': false, 'breaks_paid': false, 'week_starts': 'mon'};
        },
      );
      await search(tester, 'breaks');
      expect(listed(tester), ['Breaks count as time worked']);
      expect(saysUnder(tester, 'time-clock-breaks-paid'), 'Under Time clock');
      await pick(tester, 'time-clock-breaks-paid');
      expect(onScreen(key('time-clock-enabled')), isTrue, reason: 'the time clock is where it is turned on');
      await tester.tap(key('time-clock-enabled'));
      await tester.pumpAndSettle();
      await search(tester, 'breaks');
      await pick(tester, 'time-clock-breaks-paid');
      expect(onScreen(key('time-clock-breaks-paid')), isTrue);
    });

    testWidgets('a row that opens a dialog: it opens over the results, which are still there afterwards', (
      tester,
    ) async {
      await pumpLocation(tester);
      await search(tester, 'delivery fee');
      expect(tester.widget<ListTile>(found('delivery-fee')).trailing, isA<Icon>());
      await pick(tester, 'delivery-fee');
      expect(find.widgetWithText(AlertDialog, 'Delivery fee'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(listed(tester).first, 'Delivery fee');
      expect(tester.widget<TextField>(key('location-search-box')).controller!.text, 'delivery fee');
    });

    testWidgets('a setting inside a dialog: the dialog opens scrolled to it, and it is lit there', (tester) async {
      final t = await pumpLocation(tester, size: smallPhone);
      await search(tester, 'sales tax');
      expect(listed(tester).first, 'Charge sales tax on the fee');
      await tester.tap(found('delivery-fee/fee-taxed'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500)); // the dialog is in
      expect(find.widgetWithText(AlertDialog, 'Delivery fee'), findsOneWidget);
      expect(onScreen(key('fee-taxed')), isTrue, reason: 'under the prices: a small phone has to scroll to it');
      final light = tester.state<SpotlightState>(find.byType(Spotlight).last);
      expect(light.litRect, isNotNull);
      await tester.pumpAndSettle();
      expect(light.litRect, isNull);
      // changed and saved there like any other time
      await tester.tap(key('fee-taxed'));
      await tester.pumpAndSettle();
      await tester.tap(key('fee-save'));
      await tester.pumpAndSettle();
      expect(t.hub.deliveryFees!['taxed'], isTrue);
      expect(find.text('Delivery fee saved'), findsOneWidget);
      expect(listed(tester).first, 'Charge sales tax on the fee', reason: 'back at the results');
    });

    testWidgets('a setting far down a page of its own: the page opens there', (tester) async {
      await pumpLocation(tester, size: smallPhone);
      await search(tester, 'edit the menu');
      await pick(tester, 'powers/power:menu');
      expect(find.widgetWithText(AppBar, 'Who may do what'), findsOneWidget);
      expect(onScreen(key('power:menu')), isTrue, reason: 'the last power of a long page');
      await back(tester);
      expect(listed(tester).first, 'Edit the menu');
      // and one at the top of its page moves nothing
      await search(tester, 'approve a void');
      await pick(tester, 'powers/power:void');
      expect(onScreen(key('power:void')), isTrue);
      expect(onScreen(key('powers-intro')), isTrue);
    });

    testWidgets('a page that is still reading from the hub is waited for', (tester) async {
      await pumpLocation(tester);
      await search(tester, 'print whole');
      expect(listed(tester).first, 'To-go orders print whole at');
      await pick(tester, 'printers/takeout-station');
      expect(find.widgetWithText(AppBar, 'Printers'), findsOneWidget);
      expect(onScreen(key('takeout-station')), isTrue, reason: 'under every printer, once they are read');
    });

    testWidgets('Enter goes to the first thing found', (tester) async {
      await pumpLocation(tester);
      await search(tester, 'quote times');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AlertDialog, 'Quote times'), findsOneWidget);
    });

    testWidgets('Command-F and Control-F open the search from the keyboard', (tester) async {
      await pumpLocation(tester, size: tablet);
      await tester.tap(key('board')); // the keyboard is somewhere on the screen
      await tester.pumpAndSettle();
      await back(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pumpAndSettle();
      expect(key('location-search-box'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(key('location-search-box'), findsNothing);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(key('location-search-box'), findsOneWidget);
    });

    testWidgets('someone who reads the reports and sets nothing finds the reports and no setting', (tester) async {
      await pumpLocation(tester, holds: {'reports'});
      expect(find.text('Location'), findsOneWidget);
      expect(tester.widget<IconButton>(key('location-search')).tooltip, 'Search');
      await search(tester, 'printers');
      expect(key('location-search-none'), findsOneWidget);
      await search(tester, 'voids');
      expect(listed(tester), ['Voids and comps report']);
      await search(tester, 'sales');
      expect(listed(tester).first, 'Sales');
      await pick(tester, 'sales-report');
      expect(find.byType(LocationSettingsScreen).hitTestable(), findsNothing, reason: 'the report is open');
    });

    testWidgets('a row the hub has not answered for is shown where it stands, where it says why', (tester) async {
      await pumpLocation(
        tester,
        hub: (hub) {
          everything(hub);
          hub.points = null; // a hub from before points
        },
      );
      await search(tester, 'points');
      expect(listed(tester).first, 'Points');
      expect(tester.widget<ListTile>(found('points')).trailing, isNull, reason: 'it cannot open');
      await pick(tester, 'points');
      expect(key('location-search-box'), findsNothing);
      expect(onScreen(key('points')), isTrue);
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('what waits to be saved waits through a search, and Save is in reach all along', (tester) async {
      final t = await pumpLocation(tester);
      await search(tester, 'seat');
      await pick(tester, 'seats-enabled');
      await tester.tap(key('seats-enabled'));
      await tester.pumpAndSettle();
      expect(saveWaiting(tester), 'Not saved: seats');
      await search(tester, 'time clock');
      expect(saveWaiting(tester), 'Not saved: seats', reason: 'the bar stays under the results');
      // Back closes the search; Back again asks before the change is lost
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(key('location-search-box'), findsNothing);
      expect(find.text('Leave without saving?'), findsNothing);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('Leave without saving?'), findsOneWidget);
      await tester.tap(find.text('Keep editing'));
      await tester.pumpAndSettle();
      await search(tester, 'voids');
      await saveLocation(tester);
      expect(t.hub.seats, isFalse);
      expect(saveWaiting(tester), isNull);
      expect(listed(tester).first, 'Voids', reason: 'saved from among the results');
    });

    for (final (name, size, scale) in const [
      ('a phone', phone, 1.0),
      ('a small phone with large type', smallPhone, 1.3),
      ('a tablet', tablet, 1.0),
    ]) {
      testWidgets('the box and the results fit $name', (tester) async {
        await pumpLocation(tester, size: size, textScale: scale);
        await search(tester, 'print');
        expect(tester.takeException(), isNull);
        final box = tester.getRect(key('location-search-box'));
        final close = tester.getRect(key('location-search-close'));
        expect(box.right <= close.left && close.right <= size.width, isTrue);
        expect(box.width, greaterThan(150));
        for (final tile
            in find.descendant(of: key('location-search-results'), matching: find.byType(ListTile)).evaluate()) {
          final rect = tester.getRect(find.byWidget(tile.widget));
          expect(rect.left >= 0 && rect.right <= size.width, isTrue);
        }
      });
    }
  });

  group('the list of settings and the screen agree', () {
    // rows the screen names by something of their own: a person, a course, a desk phone
    bool ownName(String key) => RegExp(r'^(staff|course|desk-phone|person):').hasMatch(key);

    testWidgets('every row of the screen is in the list, so the search finds it', (tester) async {
      await pumpLocation(tester, size: wholeLocation);
      final rows = {
        for (final tile in find.byType(ListTile).evaluate())
          if (tile.widget.key case ValueKey<String>(:final value)) value,
        for (final tile in find.byType(SwitchListTile).evaluate())
          if (tile.widget.key case ValueKey<String>(:final value)) value,
      }.where((key) => !ownName(key)).toSet();
      expect(rows, isNotEmpty);
      final inList = {
        for (final entry in locationSettings)
          if (entry.spot == null) entry.row,
      };
      expect(rows.difference(inList), isEmpty, reason: 'rows of Location settings the search does not know');
    });

    testWidgets('every line of the list leads where it says, on a phone', (tester) async {
      await pumpLocation(tester);
      final missed = <String>[];
      for (final entry in locationSettings) {
        final id = SettingResults.idOf(entry);
        if (entry.row == 'time-clock-none') continue; // the row of a hub without a time clock
        await search(tester, entry.title);
        if (found(id).evaluate().isEmpty) {
          missed.add('$id: not found by "${entry.title}"');
          continue;
        }
        await pick(tester, id);
        final opened = !atLocation(tester);
        final spot = entry.spot;
        if (spot != null) {
          // a setting on a page or in a dialog: that is open, with the setting where it can be seen
          if (!opened) {
            missed.add('$id: nothing opened');
          } else if (!onScreen(spotFinder(spot))) {
            missed.add('$id: $spot is not on the screen of what opened');
          }
        } else if (!opened) {
          // a row that is set where it stands: the search is closed and the row is in sight
          final shown = key('location-search-box').evaluate().isEmpty && onScreen(key(entry.row));
          if (!shown) missed.add('$id: neither opened nor shown on the screen');
        }
        if (opened) await backToLocation(tester);
        if (tester.takeException() case final problem?) missed.add('$id: $problem');
      }
      expect(missed, isEmpty, reason: missed.join('\n'));
    });
  });
}

/// A hub where every part of Location settings has something to show: every setting answered, two
/// printers (one for two stations), the time clock on, a delivery fee that is charged and looked up, a to-go question that is asked.
void everything(Hub hub) {
  Map<String, dynamic> station(String code, String name, {String? printer, bool takeout = false}) => {
    'code': code,
    'name': name,
    'known': true,
    'dishes': 12,
    'choices': 0,
    'printer': printer,
    'takeout': takeout,
  };
  hub
    ..timeClock = {'enabled': true, 'breaks_paid': false, 'week_starts': 'mon'}
    ..quotes = {
      ...hub.quotes,
      'big_orders': {'dishes': 8, 'minutes': 10},
    }
    ..deliveryFees = Hub.customMapFees
    ..liveDrive = Hub.liveOn
    ..driveLookups = Hub.driveLookupsUsual
    ..addressList = Hub.addressListOff
    ..points = Hub.pointsOn
    ..bag = Hub.standardBag
    ..kitchenNotes = Hub.standardKitchenNotes
    ..voids = {
      'approval': 'manager',
      'reasons': [
        {'id': 'guest-changed-mind', 'name': 'Guest changed mind'},
        {'id': 'rung-in-wrong', 'name': 'Rung in wrong'},
      ],
    }
    ..online = Hub.onlineStatus()
    ..printers = {
      'printers': [
        {
          'id': 'wok',
          'station': 'wok1',
          'stations': ['wok1', 'wok2'],
          'address': '10.0.0.1',
          'dialect': 'escpos',
          'fallbacks': <String>[],
          'tickets': 'one',
          'groups': <List<String>>[],
        },
        {
          'id': 'bar',
          'station': 'bar',
          'stations': ['bar'],
          'address': '10.0.0.2',
          'dialect': 'star',
          'fallbacks': <String>[],
          'tickets': 'one',
          'groups': <List<String>>[],
        },
      ],
      'takeout_station': 'takeout',
      'source': 'settings',
    }
    ..stations = {
      'stations': [
        station('wok1', 'Wok 1', printer: 'wok'),
        station('wok2', 'Wok 2', printer: 'wok'),
        station('bar', 'Bar', printer: 'bar'),
        station('takeout', 'Takeout', takeout: true),
      ],
      'missing': <String>[],
      'takeout_station': 'takeout',
    }
    ..ticketWords = {'numbered': true, 'also_at': true, 'paid': true, 'moved': true, 'pack': true};
}
