import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/camera.dart';
import 'package:pos_app/coursing.dart';
import 'package:pos_app/desk_phone_watcher.dart';
import 'package:pos_app/face_signin.dart';
import 'package:pos_app/guest_display.dart';
import 'package:pos_app/idle_lock.dart';
import 'package:pos_app/main.dart';
import 'package:pos_app/outbox.dart';
import 'package:pos_app/phone.dart';
import 'package:pos_app/photos.dart';
import 'package:pos_app/print_relay.dart';
import 'package:pos_app/queue_store.dart';
import 'package:pos_app/screens/guest_display_dialog.dart';
import 'package:pos_app/screens/guest_display_screen.dart';
import 'package:pos_app/screens/location_settings_screen.dart';
import 'package:pos_app/screens/order_screen.dart';
import 'package:pos_app/screens/orders_screen.dart';
import 'package:pos_app/screens/pickup_board_screen.dart';
import 'package:pos_app/screens/settings_screen.dart';
import 'package:pos_app/screens/signin_screen.dart';
import 'package:pos_app/session.dart';
import 'package:pos_app/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'hub.dart';
import 'location_rows.dart';
import 'phone_test.dart' show FakeStack;

/// The guest display (docs/guest-display.md): a device linked to another screen shows, while nobody is
/// signed in on it, the order open on that screen as the bill would say it, turned to the customer. The
/// screen where the order is taken says which order it has open; the display reads what the hub makes of it.

/// A counter order as the hub words it for a guest: two dishes, one with choices.
Map<String, dynamic> counterOrder({
  String id = 'o7',
  List<Map<String, dynamic>>? lines,
  String total = '42.80',
  List<Map<String, dynamic>> paid = const [],
  String? due,
  bool paidInFull = false,
}) => {
  'order_id': id,
  'where': 'Order #7',
  'detail': 'Linda',
  'lines':
      lines ??
      [
        {'qty': 2, 'name': 'Jasmine Tea', 'amount': '20.00', 'notes': <dynamic>[]},
        {
          'qty': 1,
          'name': "General Gao's Chicken (Qt)",
          'amount': '20.00',
          'notes': [
            {'text': 'Brown rice +1.00', 'depth': 0},
            {'text': 'Spicy mayo', 'depth': 1},
          ],
        },
      ],
  'sums': [
    {'label': 'Subtotal', 'amount': '40.00'},
    {'label': 'Sales tax 7%', 'amount': '2.80'},
  ],
  'total': total,
  'paid': paid,
  'due': due,
  'paid_in_full': paidInFull,
};

/// The same order paid in cash, with the change.
Map<String, dynamic> paidOrder() => counterOrder(
  paid: [
    {'label': 'Paid cash', 'amount': '-42.80'},
    {'label': '50.00 handed over, 7.20 change', 'amount': ''},
  ],
  due: '0.00',
  paidInFull: true,
);

/// The tips the hub suggests for the counter order: 18%, 20% and 25% of its 40.00 before tax.
Map<String, dynamic> tipsOf40() => {
  'base': 'before_tax',
  'of': '40.00',
  'rows': [
    {'percent': 18, 'amount': '7.20'},
    {'percent': 20, 'amount': '8.00'},
    {'percent': 25, 'amount': '10.00'},
  ],
};

/// The hub knows whose order this is: what to call them, and whether they have been here before.
void known(Hub hub, String name, {bool back = false, String order = 'o7'}) =>
    hub.guestHosts[order] = {'name': name, 'back': back};

Map<String, dynamic> dish(int qty, String name, String amount) => {
  'qty': qty,
  'name': name,
  'amount': amount,
  'notes': <dynamic>[],
};

/// The screen `mac1` has this order open, and the hub words it for a guest like this.
void opens(Hub hub, Map<String, dynamic> view, {String screen = 'mac1'}) {
  hub.screenShows(screen, view['order_id'] as String);
  hub.guestViews[view['order_id'] as String] = view;
}

/// The screen `mac1` went back to its list of checks: it has no order open.
void leaves(Hub hub, {String screen = 'mac1'}) => hub.screenShows(screen, null);

Future<Terminal> pumpDisplay(WidgetTester tester, {Size? size, void Function(Hub hub)? hub}) async {
  final t = await terminal(tester);
  hub?.call(t.hub);
  if (size != null) tester.view.physicalSize = size;
  await tester.pumpWidget(
    MaterialApp(
      home: GuestDisplayScreen(api: t.api, of: 'mac1', onStaff: () {}),
    ),
  );
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300)); // the greeting has made way for what was read
  return t;
}

/// Takes the display's timers down with the screen, so no test leaves one running.
Future<void> away(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 2));
}

/// The next time the display asks by itself (it does every two seconds while no feed tells it).
Future<void> nextRead(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 2));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

/// Every word on the screen, top to bottom.
List<String> words(WidgetTester tester) => [
  for (final text in find.byType(Text).evaluate())
    if ((text.widget as Text).data case final said? when said.isNotEmpty) said,
];

String note(WidgetTester tester) => tester.widget<Text>(find.byKey(const ValueKey('guest-note'))).data!;

void main() {
  group('what the hub answers', () {
    test('an order as a guest reads it', () {
      final view = GuestDisplay.fromJson({
        'of': 'mac1',
        'known': true,
        'head': ['China Sky', 'Winchester'],
        'showing': 'o7',
        'order': paidOrder(),
      });
      expect((view.name, view.showing, view.known), ('China Sky', 'o7', true));
      final order = view.order!;
      expect(
        (order.where, order.detail, order.total, order.due, order.paidInFull),
        ('Order #7', 'Linda', '42.80', '0.00', true),
      );
      expect(
        [for (final line in order.lines) (line.qty, line.name, line.amount)],
        [(2, 'Jasmine Tea', '20.00'), (1, "General Gao's Chicken (Qt)", '20.00')],
      );
      expect(order.lines.last.notes, [(text: 'Brown rice +1.00', depth: 0), (text: 'Spicy mayo', depth: 1)]);
      expect(
        [for (final row in order.sums) (row.label, row.amount)],
        [('Subtotal', '40.00'), ('Sales tax 7%', '2.80')],
      );
      expect(
        [for (final row in order.paid) (row.label, row.amount)],
        [('Paid cash', '-42.80'), ('50.00 handed over, 7.20 change', '')],
      );
    });

    test('nothing open, and a restaurant that never gave its name', () {
      final view = GuestDisplay.fromJson({'of': 'mac1', 'known': false, 'head': <dynamic>[], 'showing': null});
      expect((view.name, view.showing, view.order, view.left, view.known), ('', null, null, null, false));
    });

    test('the order the screen left, and whether it is paid', () {
      final view = GuestDisplay.fromJson({
        'of': 'mac1',
        'head': ['China Sky'],
        'showing': null,
        'order': null,
        'left': {'order_id': 'o7', 'paid_in_full': true},
      });
      expect(view.left, (orderId: 'o7', paidInFull: true, name: ''));
      expect(GuestDisplay.fromJson({'of': 'mac1', 'left': null}).left, isNull);
      final named = GuestDisplay.fromJson({
        'of': 'mac1',
        'left': {'order_id': 'o7', 'paid_in_full': true, 'name': 'Linda'},
      });
      expect(named.left, (orderId: 'o7', paidInFull: true, name: 'Linda'));
    });

    test('whose order it is, and how they are greeted', () {
      GuestDisplay of(Object? guest) => GuestDisplay.fromJson({'of': 'mac1', 'showing': 'o7', 'guest': guest});
      expect(of({'name': 'Linda', 'back': true}).guest, (name: 'Linda', back: true));
      expect(of(null).guest, isNull); // nobody to name, or a hub older than the greeting
      expect(guestGreeting((name: 'Linda', back: true)), 'Welcome back, Linda');
      expect(guestGreeting((name: 'Linda', back: false)), 'Welcome, Linda');
      expect(guestGreeting((name: 'Mr. Wong', back: true)), 'Welcome back, Mr. Wong');
      // a number that ordered before with no name on it: known, and not named
      expect(guestGreeting((name: '', back: true)), 'Welcome back');
      expect(guestGreeting((name: '', back: false)), '');
      expect(guestGreeting(null), '');
    });

    test('the tips the hub suggests', () {
      final order = GuestDisplay.fromJson({
        'of': 'mac1',
        'showing': 'o7',
        'order': {...counterOrder(), 'tips': tipsOf40()},
      }).order!;
      final tips = order.tips!;
      expect((tips.base, tips.of), ('before_tax', '40.00'));
      expect(tips.rows, [(percent: 18, amount: '7.20'), (percent: 20, amount: '8.00'), (percent: 25, amount: '10.00')]);
      expect(tips.basis, r'On $40.00 before tax');
      expect(
        GuestTips.fromJson({
          'base': 'after_tax',
          'of': '42.80',
          'rows': [
            {'percent': 20, 'amount': '8.56'},
          ],
        })!.basis,
        r'On the total of $42.80',
      );
      // none suggested: the location turned it off, a gratuity is on the check, an older hub
      expect(GuestDisplay.fromJson({'of': 'mac1', 'showing': 'o7', 'order': counterOrder()}).order!.tips, isNull);
      expect(GuestTips.fromJson({'base': 'before_tax', 'of': '40.00', 'rows': <dynamic>[]}), isNull);
    });

    test('what the location set for its guest displays', () {
      const start = GuestDisplayRules();
      expect((start.tips, start.base), (false, 'before_tax'));
      expect(start.percents, [18, 20, 25]);
      expect(start.summary, 'No tip is suggested');
      final rules = GuestDisplayRules.fromJson({
        'tips': true,
        'tip_percents': [15, 20],
        'tip_base': 'after_tax',
      });
      expect((rules.tips, rules.base), (true, 'after_tax'));
      expect(rules.percents, [15, 20]);
      expect(rules.summary, 'Suggests a tip of 15% and 20% of the total');
      expect(rules.toJson(), {
        'tips': true,
        'tip_percents': [15, 20],
        'tip_base': 'after_tax',
      });
      expect(const GuestDisplayRules(tips: true).summary, 'Suggests a tip of 18%, 20% and 25% before tax');
      expect(GuestDisplayRules.listed([20]), '20%');
    });
  });

  group('the screen', () {
    testWidgets('greets with the restaurant\'s name while no order is open', (tester) async {
      final t = await pumpDisplay(tester);
      expect(find.byKey(const ValueKey('guest-welcome')), findsOneWidget);
      expect(words(tester), ['China Sky', 'Welcome', 'Linked to mac1', 'Staff']);
      expect(t.hub.requests, contains('GET /guest-display?of=mac1'));
      await away(tester);
    });

    testWidgets('greets without a name where the location never gave one', (tester) async {
      await pumpDisplay(tester, hub: (hub) => hub.guestHead = const []);
      expect(words(tester), ['Welcome', 'Linked to mac1', 'Staff']);
      await away(tester);
    });

    testWidgets('shows the order as the bill would say it, and nothing else', (tester) async {
      await pumpDisplay(tester, hub: (hub) => opens(hub, counterOrder()));
      expect(find.byKey(const ValueKey('guest-order')), findsOneWidget);
      expect(words(tester), [
        'Order #7 · Linda',
        '2',
        'Jasmine Tea',
        '20.00',
        '1',
        "General Gao's Chicken (Qt)",
        'Brown rice +1.00',
        'Spicy mayo',
        '20.00',
        'Subtotal',
        '40.00',
        'Sales tax 7%',
        '2.80',
        'Total',
        r'$42.80',
        'Linked to mac1',
        'Staff',
      ]);
      // nothing was paid: nothing is said about paying
      expect(find.byKey(const ValueKey('guest-due')), findsNothing);
      expect(find.byKey(const ValueKey('guest-paid-in-full')), findsNothing);
      await away(tester);
    });

    testWidgets('a dish rung in on the linked screen is on the display at its next read', (tester) async {
      final t = await pumpDisplay(tester, hub: (hub) => opens(hub, counterOrder()));
      expect(find.text('Crab Rangoon'), findsNothing);
      final more = counterOrder(total: '51.90');
      (more['lines'] as List).add(dish(1, 'Crab Rangoon', '8.50'));
      opens(t.hub, more);
      await nextRead(tester);
      expect(find.text('Crab Rangoon'), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const ValueKey('guest-total'))).data, r'$51.90');
      await away(tester);
    });

    testWidgets('a hub with nothing new costs no redraw', (tester) async {
      final t = await pumpDisplay(tester, hub: (hub) => opens(hub, counterOrder()));
      final before = t.hub.unchanged;
      await nextRead(tester);
      await nextRead(tester);
      expect(t.hub.unchanged, before + 2); // answered "the one you have", twice
      expect(find.text('Jasmine Tea'), findsOneWidget);
      await away(tester);
    });

    testWidgets('part paid says what is due; paid in full says so, with the change', (tester) async {
      final t = await pumpDisplay(
        tester,
        hub: (hub) => opens(
          hub,
          counterOrder(
            paid: [
              {'label': 'Paid cash', 'amount': '-20.00'},
            ],
            due: '22.80',
          ),
        ),
      );
      expect(tester.widget<Text>(find.byKey(const ValueKey('guest-due'))).data, r'$22.80');
      expect(find.text('Paid cash'), findsOneWidget);
      expect(find.byKey(const ValueKey('guest-paid-in-full')), findsNothing);
      opens(t.hub, paidOrder());
      await nextRead(tester);
      expect(find.byKey(const ValueKey('guest-paid-in-full')), findsOneWidget);
      expect(find.text('Paid in full.'), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const ValueKey('guest-paid-thanks'))).data, 'Thank you!');
      expect(find.text('50.00 handed over, 7.20 change'), findsOneWidget);
      expect(find.byKey(const ValueKey('guest-due')), findsNothing);
      await away(tester);
    });

    testWidgets('a paid order that is left gets a thank you, then the next guest is greeted', (tester) async {
      final t = await pumpDisplay(tester, hub: (hub) => opens(hub, paidOrder()));
      expect(find.byKey(const ValueKey('guest-order')), findsOneWidget);
      leaves(t.hub);
      await nextRead(tester);
      expect(find.byKey(const ValueKey('guest-thanks')), findsOneWidget);
      expect(words(tester).take(3), ['Thank you!', 'We hope to see you again soon.', 'China Sky']);
      expect(find.text('Jasmine Tea'), findsNothing);
      await tester.pump(const Duration(seconds: 8));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('guest-welcome')), findsOneWidget);
      expect(find.byKey(const ValueKey('guest-thanks')), findsNothing);
      await away(tester);
    });

    testWidgets('an order paid and left in one tap is thanked for, though it was never seen paid', (tester) async {
      final t = await pumpDisplay(tester, hub: (hub) => opens(hub, counterOrder()));
      expect(find.byKey(const ValueKey('guest-paid-in-full')), findsNothing);
      // a card, or the exact cash: the payment closes the order screen, and the display reads once
      t.hub.guestViews['o7'] = paidOrder();
      leaves(t.hub);
      await nextRead(tester);
      expect(find.byKey(const ValueKey('guest-thanks')), findsOneWidget);
      expect(find.text('Jasmine Tea'), findsNothing);
      // and once only: the reads after it greet
      await tester.pump(const Duration(seconds: 8));
      await tester.pump(const Duration(milliseconds: 300));
      await nextRead(tester);
      expect(find.byKey(const ValueKey('guest-welcome')), findsOneWidget);
      await away(tester);
    });

    testWidgets('a payment that reaches the hub a moment after the order was left is still thanked for', (
      tester,
    ) async {
      final t = await pumpDisplay(tester, hub: (hub) => opens(hub, counterOrder()));
      leaves(t.hub);
      await nextRead(tester);
      expect(find.byKey(const ValueKey('guest-welcome')), findsOneWidget);
      t.hub.guestViews['o7'] = paidOrder(); // the payment and the word that the order was left are two calls
      await nextRead(tester);
      expect(find.byKey(const ValueKey('guest-thanks')), findsOneWidget);
      await away(tester);
    });

    testWidgets('an order paid long after it was left (from another screen) says nothing here', (tester) async {
      final t = await pumpDisplay(tester, hub: (hub) => opens(hub, counterOrder()));
      leaves(t.hub);
      await nextRead(tester);
      await tester.pump(const Duration(seconds: 6));
      t.hub.guestViews['o7'] = paidOrder();
      await nextRead(tester);
      expect(find.byKey(const ValueKey('guest-welcome')), findsOneWidget);
      expect(find.byKey(const ValueKey('guest-thanks')), findsNothing);
      await away(tester);
    });

    testWidgets('a paid order left for the next one, not yet rung up, is thanked for until its first dish', (
      tester,
    ) async {
      final t = await pumpDisplay(tester, hub: (hub) => opens(hub, paidOrder()));
      t.hub.screenShows('mac1', 'o8'); // straight on to the next guest
      await nextRead(tester);
      expect(find.byKey(const ValueKey('guest-thanks')), findsOneWidget);
      opens(t.hub, counterOrder(id: 'o8', lines: [dish(1, 'Egg Roll', '2.50')], total: '2.68'));
      await nextRead(tester);
      expect(find.byKey(const ValueKey('guest-thanks')), findsNothing);
      expect(find.text('Egg Roll'), findsOneWidget);
      await away(tester);
    });

    testWidgets('a display that comes up after a paid order was left says no thank you for it', (tester) async {
      await pumpDisplay(
        tester,
        hub: (hub) {
          opens(hub, paidOrder());
          leaves(hub);
        },
      );
      expect(find.byKey(const ValueKey('guest-welcome')), findsOneWidget);
      expect(find.byKey(const ValueKey('guest-thanks')), findsNothing);
      await away(tester);
    });

    testWidgets('the next order cuts the thank you short', (tester) async {
      final t = await pumpDisplay(tester, hub: (hub) => opens(hub, paidOrder()));
      leaves(t.hub);
      await nextRead(tester);
      expect(find.byKey(const ValueKey('guest-thanks')), findsOneWidget);
      opens(t.hub, counterOrder(id: 'o8', lines: [dish(1, 'Egg Roll', '2.50')], total: '2.68'));
      await nextRead(tester);
      expect(find.byKey(const ValueKey('guest-thanks')), findsNothing);
      expect(find.text('Egg Roll'), findsOneWidget);
      await away(tester);
    });

    testWidgets('an order left unpaid just goes: no thank you', (tester) async {
      final t = await pumpDisplay(tester, hub: (hub) => opens(hub, counterOrder()));
      leaves(t.hub);
      await nextRead(tester);
      expect(find.byKey(const ValueKey('guest-welcome')), findsOneWidget);
      expect(find.byKey(const ValueKey('guest-thanks')), findsNothing);
      await away(tester);
    });

    testWidgets('an order open on the linked screen with no dish yet still greets', (tester) async {
      final t = await pumpDisplay(tester, hub: (hub) => hub.showing['mac1'] = 'o9');
      expect(find.byKey(const ValueKey('guest-welcome')), findsOneWidget);
      // its first dish is rung in
      opens(t.hub, counterOrder(id: 'o9', lines: [dish(1, 'Egg Roll', '2.50')], total: '2.68'));
      await nextRead(tester);
      expect(find.text('Egg Roll'), findsOneWidget);
      await away(tester);
    });

    testWidgets('a hub that stops answering leaves the order up for ten seconds and no longer', (tester) async {
      final t = await pumpDisplay(tester, hub: (hub) => opens(hub, counterOrder()));
      t.hub.down = true;
      await nextRead(tester);
      expect(find.text('Jasmine Tea'), findsOneWidget); // a hub that restarts is back within seconds
      expect(note(tester), 'The hub is not answering.');
      await tester.pump(const Duration(seconds: 10));
      await tester.pump(const Duration(milliseconds: 300));
      // a guest is not shown a total that may be behind
      expect(find.text('Jasmine Tea'), findsNothing);
      expect(find.byKey(const ValueKey('guest-welcome')), findsOneWidget);
      expect(words(tester).first, 'China Sky'); // the name stays
      // the hub is back: so is the order
      t.hub.down = false;
      await nextRead(tester);
      expect(find.text('Jasmine Tea'), findsOneWidget);
      expect(note(tester), 'Linked to mac1');
      await away(tester);
    });

    testWidgets('a hub that stops answering takes the guest\'s name off as it takes the order off', (tester) async {
      final t = await pumpDisplay(
        tester,
        hub: (hub) {
          hub.screenShows('mac1', 'o7'); // opened, no dish yet: greeted by name
          known(hub, 'Linda', back: true);
        },
      );
      expect(words(tester).first, 'Welcome back, Linda');
      t.hub.down = true;
      await nextRead(tester);
      expect(words(tester).first, 'Welcome back, Linda'); // a hub that restarts is back within seconds
      await tester.pump(const Duration(seconds: 10));
      await tester.pump(const Duration(milliseconds: 300));
      // whose order is open there now is not known: the next guest is not greeted as Linda
      expect(words(tester), ['China Sky', 'Welcome', 'The hub is not answering.', 'Staff']);
      t.hub.down = false;
      await nextRead(tester);
      expect(words(tester).first, 'Welcome back, Linda');
      await away(tester);
    });

    testWidgets('a hub back within the ten seconds never took the order off', (tester) async {
      final t = await pumpDisplay(tester, hub: (hub) => opens(hub, counterOrder()));
      t.hub.down = true;
      await nextRead(tester);
      t.hub.down = false;
      await nextRead(tester);
      await tester.pump(const Duration(seconds: 12));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Jasmine Tea'), findsOneWidget);
      expect(note(tester), 'Linked to mac1');
      await away(tester);
    });

    testWidgets('says in its corner when the linked screen is not on, or the hub is older', (tester) async {
      final t = await pumpDisplay(tester, hub: (hub) => hub.screensOff.add('mac1'));
      expect(note(tester), 'Linked to mac1, which is not on.');
      expect(find.byKey(const ValueKey('guest-welcome')), findsOneWidget);
      t.hub.guestDisplays = false; // a hub from before guest displays
      await nextRead(tester);
      expect(note(tester), 'The hub is older than guest displays: update the hub.');
      expect(find.byKey(const ValueKey('guest-welcome')), findsOneWidget);
      await away(tester);
    });

    testWidgets('Staff is the only thing to tap', (tester) async {
      final t = await terminal(tester);
      opens(t.hub, counterOrder());
      var staff = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: GuestDisplayScreen(api: t.api, of: 'mac1', onStaff: () => staff++),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.tap(find.text('Jasmine Tea'));
      await tester.tap(find.byKey(const ValueKey('guest-total')));
      await tester.pump();
      expect(staff, 0);
      await tester.tap(find.byKey(const ValueKey('guest-staff')));
      expect(staff, 1);
      expect(find.byType(Dialog), findsNothing);
      await away(tester);
    });

    testWidgets('greets the guest by name over their order, and does not say the name twice', (tester) async {
      final t = await pumpDisplay(
        tester,
        hub: (hub) {
          opens(hub, counterOrder());
          known(hub, 'Linda', back: true);
        },
      );
      expect(tester.widget<Text>(find.byKey(const ValueKey('guest-hello'))).data, 'Welcome back, Linda');
      expect(tester.widget<Text>(find.byKey(const ValueKey('guest-where'))).data, 'Order #7');
      expect(words(tester).take(3), ['Welcome back, Linda', 'Order #7', '2']);
      // the name stands over the order number, and larger
      final hello = tester.getRect(find.byKey(const ValueKey('guest-hello')));
      final where = tester.getRect(find.byKey(const ValueKey('guest-where')));
      expect(hello.bottom, lessThanOrEqualTo(where.top));
      expect(hello.height, greaterThan(where.height));
      // a first visit is welcomed, not welcomed back
      known(t.hub, 'Linda');
      await nextRead(tester);
      expect(tester.widget<Text>(find.byKey(const ValueKey('guest-hello'))).data, 'Welcome, Linda');
      await away(tester);
    });

    testWidgets('a guest the hub knows by number alone is welcomed back; one it cannot name is not greeted', (
      tester,
    ) async {
      final t = await pumpDisplay(
        tester,
        hub: (hub) {
          opens(hub, counterOrder());
          known(hub, '', back: true);
        },
      );
      expect(tester.widget<Text>(find.byKey(const ValueKey('guest-hello'))).data, 'Welcome back');
      // what was typed on the order still tells them it is theirs
      expect(tester.widget<Text>(find.byKey(const ValueKey('guest-where'))).data, 'Order #7 · Linda');
      t.hub.guestHosts.clear();
      await nextRead(tester);
      expect(find.byKey(const ValueKey('guest-hello')), findsNothing);
      expect(tester.widget<Text>(find.byKey(const ValueKey('guest-where'))).data, 'Order #7 · Linda');
      await away(tester);
    });

    testWidgets('greets by name the moment the order is opened, before its first dish', (tester) async {
      final t = await pumpDisplay(
        tester,
        hub: (hub) {
          hub.screenShows('mac1', 'o7'); // opened from the caller's card: no dish on it yet
          known(hub, 'Linda', back: true);
        },
      );
      expect(find.byKey(const ValueKey('guest-welcome')), findsOneWidget);
      expect(words(tester), ['Welcome back, Linda', 'China Sky', 'Linked to mac1', 'Staff']);
      // the first dish: the order, under the same greeting
      opens(t.hub, counterOrder());
      await nextRead(tester);
      expect(find.byKey(const ValueKey('guest-order')), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const ValueKey('guest-hello'))).data, 'Welcome back, Linda');
      // the order is left unpaid: the next guest is not greeted as Linda
      leaves(t.hub);
      await nextRead(tester);
      expect(words(tester), ['China Sky', 'Welcome', 'Linked to mac1', 'Staff']);
      await away(tester);
    });

    testWidgets('thanks the guest by name: when the order is paid, and when it is left', (tester) async {
      final t = await pumpDisplay(
        tester,
        hub: (hub) {
          opens(hub, paidOrder());
          known(hub, 'Linda', back: true);
        },
      );
      expect(find.text('Paid in full.'), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const ValueKey('guest-paid-thanks'))).data, 'Thank you, Linda!');
      leaves(t.hub);
      await nextRead(tester);
      expect(find.byKey(const ValueKey('guest-thanks')), findsOneWidget);
      expect(words(tester).take(3), ['Thank you, Linda!', 'We hope to see you again soon.', 'China Sky']);
      // and the next guest is greeted as anyone is
      await tester.pump(const Duration(seconds: 8));
      await tester.pump(const Duration(milliseconds: 300));
      expect(words(tester), ['China Sky', 'Welcome', 'Linked to mac1', 'Staff']);
      await away(tester);
    });

    testWidgets('an order paid and left in one tap is thanked for by name too', (tester) async {
      final t = await pumpDisplay(
        tester,
        hub: (hub) {
          opens(hub, counterOrder());
          known(hub, 'Mr. Wong');
        },
      );
      t.hub.guestViews['o7'] = paidOrder();
      leaves(t.hub);
      await nextRead(tester);
      expect(words(tester).first, 'Thank you, Mr. Wong!');
      await away(tester);
    });

    testWidgets('suggests the tips the hub worked out, under the total, and takes none', (tester) async {
      var staff = 0;
      final t = await terminal(tester);
      opens(t.hub, {...counterOrder(), 'tips': tipsOf40()});
      await tester.pumpWidget(
        MaterialApp(
          home: GuestDisplayScreen(api: t.api, of: 'mac1', onStaff: () => staff++),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('guest-tips')), findsOneWidget);
      final said = words(tester);
      expect(said.sublist(said.indexOf('Total')), [
        'Total',
        r'$42.80',
        'Suggested tip',
        '18%',
        r'$7.20',
        '20%',
        r'$8.00',
        '25%',
        r'$10.00',
        r'On $40.00 before tax',
        'Linked to mac1',
        'Staff',
      ]);
      // under the total, side by side
      final total = tester.getRect(find.byKey(const ValueKey('guest-total')));
      final first = tester.getRect(find.byKey(const ValueKey('guest-tip:18')));
      final last = tester.getRect(find.byKey(const ValueKey('guest-tip:25')));
      expect(first.top, greaterThanOrEqualTo(total.bottom));
      expect((first.top, first.bottom), (last.top, last.bottom));
      expect(last.width, closeTo(first.width, 0.01));
      expect(last.left, greaterThan(first.right));
      // an amount is read, not tapped: nothing happens, and the total stays what it was
      final before = t.hub.requests.length;
      await tester.tap(find.byKey(const ValueKey('guest-tip:20')));
      await tester.pump();
      expect((staff, t.hub.requests.length), (0, before));
      expect(tester.widget<Text>(find.byKey(const ValueKey('guest-total'))).data, r'$42.80');
      await away(tester);
    });

    testWidgets('says what the tips are a percentage of, and nothing where the hub suggests none', (tester) async {
      final t = await pumpDisplay(
        tester,
        hub: (hub) => opens(hub, {
          ...counterOrder(),
          'tips': {
            'base': 'after_tax',
            'of': '42.80',
            'rows': [
              {'percent': 20, 'amount': '8.56'},
            ],
          },
        }),
      );
      expect(find.text(r'On the total of $42.80'), findsOneWidget);
      expect(find.byKey(const ValueKey('guest-tip:20')), findsOneWidget);
      expect(find.byKey(const ValueKey('guest-tip:18')), findsNothing);
      // the location turned the suggestion off, or the check now carries a gratuity
      opens(t.hub, counterOrder());
      await nextRead(tester);
      expect(find.byKey(const ValueKey('guest-tips')), findsNothing);
      expect(find.text('Suggested tip'), findsNothing);
      await away(tester);
    });

    testWidgets('part paid, the tips stand under what is still due; paid in full, they are gone', (tester) async {
      final t = await pumpDisplay(
        tester,
        hub: (hub) => opens(hub, {
          ...counterOrder(
            paid: [
              {'label': 'Paid cash', 'amount': '-20.00'},
            ],
            due: '22.80',
          ),
          'tips': tipsOf40(),
        }),
      );
      final due = tester.getRect(find.byKey(const ValueKey('guest-due')));
      expect(tester.getRect(find.byKey(const ValueKey('guest-tips'))).top, greaterThanOrEqualTo(due.bottom));
      opens(t.hub, paidOrder()); // the hub suggests none on a check paid in full
      await nextRead(tester);
      expect(find.byKey(const ValueKey('guest-tips')), findsNothing);
      expect(find.byKey(const ValueKey('guest-paid-in-full')), findsOneWidget);
      await away(tester);
    });

    testWidgets('a greeting and the tips on a small phone with large type overflow nothing', (tester) async {
      final t = await terminal(tester);
      opens(t.hub, {
        ...counterOrder(total: '1,042.80'),
        'tips': {
          'base': 'before_tax',
          'of': '1,000.00',
          'rows': [
            {'percent': 18, 'amount': '180.00'},
            {'percent': 20, 'amount': '200.00'},
            {'percent': 25, 'amount': '250.00'},
          ],
        },
      });
      known(t.hub, 'Bartholomew-Alexander', back: true);
      tester.view.physicalSize = const Size(320, 568);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(size: Size(320, 568), textScaler: TextScaler.linear(1.6)),
            child: GuestDisplayScreen(api: t.api, of: 'mac1', onStaff: () {}),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('guest-hello')), findsOneWidget);
      expect(find.byKey(const ValueKey('guest-tips')), findsOneWidget);
      expect(tester.takeException(), isNull);
      // the total is still in view: the tips never push it off
      final screen = tester.getRect(find.byType(GuestDisplayScreen));
      // and so are the tips: on a screen this small the sums may take a little more of it
      expect(screen.contains(tester.getRect(find.byKey(const ValueKey('guest-tip:25'))).bottomRight), isTrue);
      expect(screen.contains(tester.getRect(find.byKey(const ValueKey('guest-total'))).bottomRight), isTrue);
      await away(tester);
    });

    testWidgets('on a wide screen the total stands beside the dishes; on a phone under them', (tester) async {
      await pumpDisplay(tester, hub: (hub) => opens(hub, counterOrder()));
      var dishAt = tester.getTopLeft(find.text('Jasmine Tea'));
      var totalAt = tester.getTopLeft(find.text('Total'));
      expect(totalAt.dx, greaterThan(dishAt.dx + 400));
      await away(tester);

      await pumpDisplay(tester, size: const Size(390, 844), hub: (hub) => opens(hub, counterOrder()));
      dishAt = tester.getTopLeft(find.text('Jasmine Tea'));
      totalAt = tester.getTopLeft(find.text('Total'));
      expect(totalAt.dy, greaterThan(dishAt.dy));
      expect(totalAt.dx, lessThan(60));
      await away(tester);
    });

    testWidgets('a long order goes to its last dish, and the total stays in view on a small phone', (tester) async {
      final many = counterOrder(
        lines: [for (var i = 1; i <= 30; i++) dish(1, 'Dish number $i with a name that runs on and on', '12.50')],
        total: '401.25',
      );
      await pumpDisplay(tester, size: const Size(320, 568), hub: (hub) => opens(hub, many));
      await tester.pump(const Duration(milliseconds: 400));
      final screen = tester.getRect(find.byType(GuestDisplayScreen));
      final last = tester.getRect(find.byKey(const ValueKey('guest-line:29')));
      final total = tester.getRect(find.byKey(const ValueKey('guest-total')));
      expect(last.bottom, lessThanOrEqualTo(total.top)); // the last dish, above the sums
      expect(last.top, greaterThan(0));
      expect(screen.contains(total.bottomRight), isTrue);
      await away(tester);
    });

    testWidgets('large type on a small phone overflows nothing', (tester) async {
      final t = await terminal(tester);
      opens(t.hub, paidOrder());
      tester.view.physicalSize = const Size(320, 568);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(size: Size(320, 568), textScaler: TextScaler.linear(1.6)),
            child: GuestDisplayScreen(api: t.api, of: 'mac1', onStaff: () {}),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('Paid in full.'), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const ValueKey('guest-paid-thanks'))).data, 'Thank you!');
      expect(tester.takeException(), isNull);
      await away(tester);
    });
  });

  group('told by the hub', () {
    Future<(LiveHub, Terminal)> liveDisplay(WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({});
      final settings = Settings(
        device: 'ipad1',
        endpoints: ['http://hub:8000'],
        prefs: await SharedPreferences.getInstance(),
      );
      final hub = Hub();
      final live = LiveHub(hub);
      final api = PosApi(settings, client: live.client);
      final session = Session(api);
      final outbox = Outbox(api, settings, store: MemoryStore());
      final photos = PhotoQueue(api, settings, NoCamera(), session, store: MemoryStore());
      tester.view
        ..physicalSize = const Size(1100, 800)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      api.live.start();
      return (live, Terminal(hub, api, outbox, photos, session, settings));
    }

    int reads(Hub hub) => hub.requests.where((r) => r.startsWith('GET /guest-display?')).length;

    testWidgets('it waits to be told, and reads the moment the linked screen opens an order or adds a dish', (
      tester,
    ) async {
      final (live, t) = await liveDisplay(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: GuestDisplayScreen(api: t.api, of: 'mac1', onStaff: () {}),
        ),
      );
      await tester.pumpAndSettle();
      live.hello();
      live.beats();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(find.byKey(const ValueKey('guest-welcome')), findsOneWidget);

      // twenty seconds in which nothing happens: not one request
      t.hub.requests.clear();
      await tester.pump(const Duration(seconds: 20));
      await tester.pump();
      expect(reads(t.hub), 0);

      // the register opens an order with a dish on it: the hub says a screen shows something else
      opens(t.hub, counterOrder(lines: [dish(2, 'Jasmine Tea', '20.00')], total: '21.40'));
      live.changed(topics: ['showing']);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));
      expect(find.text('Jasmine Tea'), findsOneWidget);
      expect(reads(t.hub), 1);

      // a dish is rung in on that order: the hub says the order changed
      final more = counterOrder(total: '42.80');
      opens(t.hub, more);
      live.changed(orders: ['o7']);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 10));
      expect(find.text("General Gao's Chicken (Qt)"), findsOneWidget);

      // somebody else's order changes: nothing for this display to read
      t.hub.requests.clear();
      live.changed(orders: ['o99']);
      live.changed(topics: ['menu']);
      await tester.pump(const Duration(seconds: 2));
      expect(reads(t.hub), 0);

      // by itself it still asks once in thirty seconds, in case the hub never said
      await tester.pump(const Duration(seconds: 30));
      await tester.pump();
      expect(reads(t.hub), 1);

      // the money is taken and the order left in one tap: the hub hears that the order was left, and the
      // payment a moment after it. The display is still listening for that order
      leaves(t.hub);
      live.changed(topics: ['showing']);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('guest-welcome')), findsOneWidget);
      t.hub.guestViews['o7'] = paidOrder();
      live.changed(orders: ['o7']);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('guest-thanks')), findsOneWidget);

      await away(tester);
      live.close();
      t.api.dispose();
      await tester.pump();
    });
  });

  group('the screen where the order is taken', () {
    test('says nothing until the app starts it', () async {
      SharedPreferences.setMockInitialValues({});
      final settings = Settings(device: 'mac1', endpoints: ['http://hub:8000']);
      final hub = Hub();
      final api = PosApi(settings, client: LiveHub(hub).client);
      api.showing.open('o7');
      api.showing.close('o7');
      await Future<void>.delayed(Duration.zero);
      expect(hub.showingSaid, isEmpty);
      api.dispose();
    });

    testWidgets('says which order it has open, and that it left it', (tester) async {
      final t = await terminal(tester);
      t.api.showing.start(session: t.session);
      await tester.pump();
      // as the app comes up it has nothing open: an order left open when it was closed is taken off
      expect(t.hub.showingSaid, [('t1', null)]);
      t.api.showing.open('o7');
      await tester.pump();
      expect(t.hub.showingSaid.last, ('t1', 'o7'));
      // another order comes up before the first has gone (one check opened from another): it stays
      t.api.showing.open('o8');
      t.api.showing.close('o7');
      await tester.pump();
      await tester.pump();
      expect(t.hub.showingSaid.last, ('t1', 'o8'));
      t.api.showing.close('o8');
      await tester.pump();
      expect(t.hub.showingSaid.last, ('t1', null));
      expect(t.hub.showing, isEmpty);
    });

    testWidgets('nobody signed in: the guest is shown nothing, and the order again after signing in', (tester) async {
      final t = await terminal(tester);
      t.api.showing.start(session: t.session);
      t.api.showing.open('o7');
      await tester.pump();
      await tester.pump();
      expect(t.hub.showing, {'t1': 'o7'});
      t.session.lock(); // the screen stood idle: the sign-in pad lies over the order
      await tester.pump();
      expect(t.hub.showing, isEmpty);
      t.session.applySignIn({'staff_id': 's1', 'name': 'Amy', 'role': 'server'});
      await tester.pump();
      expect(t.hub.showing, {'t1': 'o7'}); // the order was still open under the pad
      t.session.signOut();
      await tester.pump();
      expect(t.hub.showing, isEmpty);
    });

    testWidgets('a hub that does not answer costs nothing, and is told when it is found again', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final settings = Settings(device: 'mac1', endpoints: ['http://hub:8000']);
      final hub = Hub();
      final live = LiveHub(hub);
      final api = PosApi(settings, client: live.client);
      live.down = true;
      api.showing.start();
      api.showing.open('o7');
      await tester.pump(const Duration(seconds: 5));
      expect(hub.showingSaid, isEmpty);
      expect(api.connection.value.error, isNull); // never a reason to say the hub is away
      // the hub is back (it may have restarted and forgotten): the feed connects, and the word is said afresh
      live.down = false;
      api.live.start();
      await api.health(); // a screen's own asking finds the hub, and the feed opens on it
      await tester.pump();
      live.hello();
      await tester.pump();
      await tester.pump();
      expect(hub.showingSaid.last, ('mac1', 'o7'));
      // found again once more with nothing changed: said again all the same
      final said = hub.showingSaid.length;
      live.drop();
      await tester.pump(const Duration(seconds: 2));
      live.hello();
      await tester.pump();
      await tester.pump();
      expect(hub.showingSaid.length, said + 1);
      live.close();
      api.dispose();
      await tester.pump();
    });

    testWidgets('a hub older than guest displays is asked once per order and never minded', (tester) async {
      final t = await terminal(tester);
      t.hub.guestDisplays = false;
      t.api.showing.start(session: t.session);
      t.api.showing.open('o7');
      await tester.pump();
      await tester.pump();
      expect(t.hub.requests.where((r) => r == 'POST /guest-display/showing').length, lessThanOrEqualTo(2));
      expect(t.api.connection.value.error, isNull);
    });

    testWidgets('the order screen says its order as it comes up and as it goes', (tester) async {
      final t = await terminal(tester);
      t.hub.orders.add(table('o1', {'L1': line('Egg Roll', course: '1')}));
      t.api.showing.start(session: t.session);
      await tester.pumpWidget(
        MaterialApp(
          home: OrderScreen(
            api: t.api,
            outbox: t.outbox,
            photos: t.photos,
            orderId: 'o1',
            coursing: Coursing.fromJson(t.hub.coursing),
            session: t.session,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(t.hub.showing, {'t1': 'o1'});
      await stop(tester);
      await tester.pump();
      expect(t.hub.showing, isEmpty);
    });
  });

  group('the device that is a guest display', () {
    test('a device is one thing only: a guest display, a pickup board or a kitchen screen', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final settings = Settings(device: 'ipad1', endpoints: ['http://hub:8000'], prefs: prefs);
      expect((settings.guestDisplay, settings.stands), (false, false));
      await settings.savePickupBoard(true);
      await settings.saveGuestDisplayOf('mac1');
      expect((settings.guestDisplayOf, settings.pickupBoard, settings.stands), ('mac1', false, true));
      await settings.saveKitchenStations(['wok']);
      expect((settings.guestDisplay, settings.kitchen), (false, true));
      await settings.saveGuestDisplayOf('mac-1 ');
      expect((settings.guestDisplayOf, settings.kitchen), ('mac1', false)); // as device names are kept
      await settings.savePickupBoard(true);
      expect((settings.guestDisplay, settings.pickupBoard), (false, true));
      // its own name is no screen to face the guest of
      await settings.saveGuestDisplayOf('IPAD1');
      expect((settings.guestDisplay, settings.pickupBoard), (false, true));
      // kept by the device
      await settings.saveGuestDisplayOf('mac1');
      expect((await Settings.load()).guestDisplayOf, 'mac1');
      await settings.saveGuestDisplayOf('');
      expect(((await Settings.load()).guestDisplayOf, settings.stands), ('', false));
    });

    test('the camera signs nobody in at a screen that faces the guest', () async {
      SharedPreferences.setMockInitialValues({});
      final settings = Settings(device: 'ipad1', endpoints: ['http://hub:8000'], guestDisplayOf: 'mac1');
      final api = PosApi(settings, client: LiveHub(Hub()).client);
      final session = Session(api);
      final faces = FaceSignIn(api, settings, NoCamera(), session);
      expect(faces.standing, isTrue);
      session.staff = const Staff(staffId: 's1', name: 'Amy', role: 'server', method: 'pin');
      expect(faces.standing, isFalse); // one of the staff signed in at its pad: a screen like any other
      faces.dispose();
      api.dispose();
    });

    testWidgets('the screen to link to is picked in the device\'s Settings, and kept with Save', (tester) async {
      final t = await terminal(tester);
      t.hub.devices = ['ipad1', 'mac1', 'mac2', 'T1'];
      await t.settings.savePickupBoard(true);
      tester.view.physicalSize = wholeSettings;
      await tester.pumpWidget(
        MaterialApp(
          home: SettingsScreen(settings: t.settings, api: t.api),
        ),
      );
      await tester.pumpAndSettle();
      final line = find.byKey(const ValueKey('guest-display-line'));
      expect(tester.widget<Text>(line).data, startsWith('For a screen turned to the guest at a register'));
      expect(tester.widget<Text>(line).data, endsWith('Pick that screen.'));
      // every screen the hub hears from, but not this one (t1, however it is spelled)
      expect(find.byKey(const ValueKey('guest-display-of:mac1')), findsOneWidget);
      expect(find.byKey(const ValueKey('guest-display-of:mac2')), findsOneWidget);
      expect(find.byKey(const ValueKey('guest-display-of:ipad1')), findsOneWidget);
      expect(find.byKey(const ValueKey('guest-display-of:T1')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('guest-display-of:mac1')));
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(line).data, contains('it shows the order open on mac1 as it is rung up'));
      // one thing only: the pickup board's switch went off with it
      expect(tester.widget<SwitchListTile>(find.byKey(const ValueKey('pickup-board-switch'))).value, isFalse);
      expect((t.settings.guestDisplayOf, t.settings.pickupBoard), ('', true)); // not before Save
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect((t.settings.guestDisplayOf, t.settings.pickupBoard), ('mac1', false));
    });

    testWidgets('tapped again it is a guest display no longer; a board or a station takes its place', (tester) async {
      final t = await terminal(tester);
      t.hub.devices = ['mac1'];
      await t.settings.saveGuestDisplayOf('mac2'); // linked to a screen that is switched off right now
      tester.view.physicalSize = wholeSettings;
      await tester.pumpWidget(
        MaterialApp(
          home: SettingsScreen(settings: t.settings, api: t.api),
        ),
      );
      await tester.pumpAndSettle();
      // the one it is linked to is still offered, though the hub does not hear from it
      ChoiceChip chip(String screen) => tester.widget<ChoiceChip>(find.byKey(ValueKey('guest-display-of:$screen')));
      expect((chip('mac1').selected, chip('mac2').selected), (false, true));
      await tester.tap(find.byKey(const ValueKey('guest-display-of:mac2')));
      await tester.pumpAndSettle();
      expect(chip('mac2').selected, isFalse);
      await tester.tap(find.byKey(const ValueKey('guest-display-of:mac1')));
      await tester.pumpAndSettle();
      expect(chip('mac1').selected, isTrue);
      // the pickup board is switched on: the link goes
      await tester.tap(find.byKey(const ValueKey('pickup-board-switch')));
      await tester.pumpAndSettle();
      expect(chip('mac1').selected, isFalse);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect((t.settings.guestDisplayOf, t.settings.pickupBoard), ('', true));
    });

    testWidgets('with no other screen up, or no hub, Settings says what to do', (tester) async {
      final t = await terminal(tester);
      t.hub.devices = ['t1'];
      tester.view.physicalSize = wholeSettings;
      await tester.pumpWidget(
        MaterialApp(
          home: SettingsScreen(settings: t.settings, api: t.api),
        ),
      );
      await tester.pumpAndSettle();
      final line = find.byKey(const ValueKey('guest-display-line'));
      expect(tester.widget<Text>(line).data, contains('No other screen is up right now'));
      await tester.pumpWidget(const SizedBox.shrink());
      t.hub.down = true;
      await tester.pumpWidget(
        MaterialApp(
          home: SettingsScreen(settings: t.settings, api: t.api),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(line).data, contains('could not be read from the hub'));
    });

    Future<Terminal> pumpDevice(WidgetTester tester, {int lockMinutes = 0}) async {
      final t = await terminal(tester);
      t.session.signOut();
      await t.settings.saveGuestDisplayOf('mac1');
      await t.settings.saveLockMinutes(lockMinutes);
      opens(t.hub, counterOrder());
      final lock = IdleLock(t.settings, t.session)..start();
      addTearDown(lock.dispose);
      await tester.pumpWidget(
        PosApp(
          settings: t.settings,
          api: t.api,
          outbox: t.outbox,
          session: t.session,
          camera: NoCamera(),
          photos: t.photos,
          relay: PrintRelay(t.api, t.settings),
          phone: PhoneClient(FakeStack()),
          deskPhones: DeskPhoneWatcher(t.api, t.settings),
          idleLock: lock,
        ),
      );
      await tester.pumpAndSettle();
      return t;
    }

    Future<void> pin(WidgetTester tester, String digits) async {
      for (final digit in digits.split('')) {
        await tester.tap(find.widgetWithText(FilledButton, digit));
        await tester.pump();
      }
      await tester.pumpAndSettle();
    }

    testWidgets('it stands while nobody is signed in; Staff brings the pad, and a PIN the orders', (tester) async {
      final t = await pumpDevice(tester);
      expect(find.byType(GuestDisplayScreen), findsOneWidget);
      expect(find.byType(SignInScreen), findsNothing);
      expect(find.byType(PickupBoardScreen), findsNothing);
      expect(find.text('Jasmine Tea'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('guest-staff')));
      await tester.pumpAndSettle();
      expect(find.byType(SignInScreen), findsOneWidget);
      expect(find.byType(GuestDisplayScreen), findsNothing);
      // the pad's way back names what this screen is
      expect(find.widgetWithText(TextButton, 'Guest display'), findsOneWidget);
      await pin(tester, '1111');
      expect(t.session.staff?.name, 'Amy');
      expect(find.byType(OrdersScreen), findsOneWidget);
      // signing out puts the display back, not the pad
      t.session.signOut();
      await tester.pumpAndSettle();
      expect(find.byType(GuestDisplayScreen), findsOneWidget);
      expect(find.byType(SignInScreen), findsNothing);
      await away(tester);
    });

    testWidgets('the pad goes back to the display from its bar, and by itself when left alone', (tester) async {
      await pumpDevice(tester);
      await tester.tap(find.byKey(const ValueKey('guest-staff')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('board-back')));
      await tester.pumpAndSettle();
      expect(find.byType(GuestDisplayScreen), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('guest-staff')));
      await tester.pumpAndSettle();
      expect(find.byType(SignInScreen), findsOneWidget);
      await tester.pump(const Duration(seconds: 61));
      await tester.pumpAndSettle();
      expect(find.byType(GuestDisplayScreen), findsOneWidget);
      expect(find.byType(SignInScreen), findsNothing);
      await away(tester);
    });

    testWidgets('a display that locked itself shows the display, never what a member of staff had open', (
      tester,
    ) async {
      final t = await pumpDevice(tester, lockMinutes: 5);
      await tester.tap(find.byKey(const ValueKey('guest-staff')));
      await tester.pumpAndSettle();
      await pin(tester, '1111');
      expect(find.byType(OrdersScreen), findsOneWidget);
      t.session.lock(); // nobody touched it for five minutes
      await tester.pumpAndSettle();
      expect(find.byType(GuestDisplayScreen), findsOneWidget);
      t.session.signOut();
      await tester.pumpAndSettle();
      await away(tester);
    });
  });

  group('what a manager sets under Location', () {
    Future<Terminal> pumpLocation(WidgetTester tester, {bool older = false, void Function(Hub hub)? hub}) async {
      final t = await terminal(tester);
      if (older) t.hub.guestDisplayRules = null;
      hub?.call(t.hub);
      await tester.pumpWidget(
        MaterialApp(
          home: LocationSettingsScreen(api: t.api, token: 'tok-admin', device: 't1'),
        ),
      );
      await tester.pumpAndSettle();
      await bringUp(tester, 'guest-display');
      return t;
    }

    String rowWords(WidgetTester tester) =>
        ((tester.widget<ListTile>(find.byKey(const ValueKey('guest-display'))).subtitle!) as Text).data!;

    String sample(WidgetTester tester) => tester.widget<Text>(find.byKey(const ValueKey('guest-tip-sample'))).data!;

    bool canSave(WidgetTester tester) =>
        tester.widget<FilledButton>(find.byKey(const ValueKey('guest-display-save'))).onPressed != null;

    Future<void> open(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('guest-display')));
      await tester.pumpAndSettle();
    }

    testWidgets('no tip is suggested until a manager turns it on', (tester) async {
      final t = await pumpLocation(tester);
      expect(rowWords(tester), 'No tip is suggested. A device becomes a guest display in its own Settings.');
      await open(tester);
      expect(tester.widget<SwitchListTile>(find.byKey(const ValueKey('guest-tips-on'))).value, isFalse);
      // the percentages it would start with, and what they come to on fifty dollars
      expect(
        [
          for (var i = 0; i < 3; i++)
            tester.widget<TextField>(find.byKey(ValueKey('guest-tip-percent:$i'))).controller!.text,
        ],
        ['18', '20', '25'],
      );
      expect(sample(tester), startsWith(r'On $50.00 the display suggests $9.00, $10.00 and $12.50.'));
      await tester.tap(find.byKey(const ValueKey('guest-tips-on')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('guest-display-save')));
      await tester.pumpAndSettle();
      expect(t.hub.guestDisplayRulesAuth, 'Bearer tok-admin');
      expect(t.hub.guestDisplayRules, {
        'tips': true,
        'tip_percents': [18, 20, 25],
        'tip_base': 'before_tax',
      });
      expect(find.text('Guest display saved'), findsOneWidget);
      expect(rowWords(tester), startsWith('Suggests a tip of 18%, 20% and 25% before tax.'));
    });

    testWidgets('the percentages are the manager\'s: fewer, others, and of the total with tax', (tester) async {
      final t = await pumpLocation(tester, hub: (hub) => hub.guestDisplayRules!['tips'] = true);
      await open(tester);
      await tester.enterText(find.byKey(const ValueKey('guest-tip-percent:0')), '22');
      await tester.enterText(find.byKey(const ValueKey('guest-tip-percent:1')), '15');
      await tester.enterText(find.byKey(const ValueKey('guest-tip-percent:2')), '');
      await tester.pumpAndSettle();
      // lowest first, whatever the order they were typed in
      expect(sample(tester), startsWith(r'On $50.00 the display suggests $7.50 and $11.00.'));
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('guest-tip-base-says'))).data,
        startsWith('Of the food and drink, less comps and discounts'),
      );
      await tester.tap(find.byKey(const ValueKey('guest-tip-base:after_tax')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('guest-tip-base-says'))).data,
        startsWith('Of the total as the guest reads it'),
      );
      await tester.tap(find.byKey(const ValueKey('guest-display-save')));
      await tester.pumpAndSettle();
      expect(t.hub.guestDisplayRules, {
        'tips': true,
        'tip_percents': [15, 22],
        'tip_base': 'after_tax',
      });
      expect(rowWords(tester), startsWith('Suggests a tip of 15% and 22% of the total.'));
    });

    testWidgets('a percentage that cannot be, one typed twice or none at all is not saved', (tester) async {
      final t = await pumpLocation(tester, hub: (hub) => hub.guestDisplayRules!['tips'] = true);
      await open(tester);
      await tester.enterText(find.byKey(const ValueKey('guest-tip-percent:0')), '0');
      await tester.pumpAndSettle();
      expect(find.text('1 to 100'), findsOneWidget);
      expect(canSave(tester), isFalse);
      await tester.enterText(find.byKey(const ValueKey('guest-tip-percent:0')), '20');
      await tester.pumpAndSettle();
      expect(find.text('Twice'), findsOneWidget); // on the second of the two, not on both
      expect(sample(tester), startsWith('Whole percentages from 1 to 100, no two alike.'));
      expect(canSave(tester), isFalse);
      for (var i = 0; i < 3; i++) {
        await tester.enterText(find.byKey(ValueKey('guest-tip-percent:$i')), '');
      }
      await tester.pumpAndSettle();
      expect(sample(tester), 'Type at least one percentage, or turn the suggestion off.');
      expect(canSave(tester), isFalse);
      // off, the boxes may stay empty: the percentages the hub has are kept for the day it is turned on
      await tester.tap(find.byKey(const ValueKey('guest-tips-on')));
      await tester.pumpAndSettle();
      expect(canSave(tester), isTrue);
      await tester.tap(find.byKey(const ValueKey('guest-display-save')));
      await tester.pumpAndSettle();
      expect(t.hub.guestDisplayRules, {
        'tips': false,
        'tip_percents': [18, 20, 25],
        'tip_base': 'before_tax',
      });
    });

    testWidgets('what the hub refuses is said in its words, and Cancel saves nothing', (tester) async {
      final t = await pumpLocation(tester);
      await open(tester);
      await tester.tap(find.byKey(const ValueKey('guest-tips-on')));
      await tester.pumpAndSettle();
      t.hub.refuseGuestDisplayRules = 'a tip is 1 to 100 percent';
      await tester.tap(find.byKey(const ValueKey('guest-display-save')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('guest-display-problem'))).data,
        'a tip is 1 to 100 percent',
      );
      expect(t.hub.guestDisplayRules!['tips'], isFalse);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('guest-display-save')), findsNothing);
      expect(rowWords(tester), startsWith('No tip is suggested.'));
    });

    testWidgets('the whole of it fits a phone, with large type', (tester) async {
      final t = await terminal(tester);
      tester.view.physicalSize = const Size(320, 568);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(size: Size(320, 568), textScaler: TextScaler.linear(1.6)),
            child: GuestDisplayDialog(api: t.api, token: 'tok-admin', rules: const GuestDisplayRules(tips: true)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      // Cancel and Save stay in reach at the foot, whatever the dialog holds
      final screen = tester.getRect(find.byType(MaterialApp));
      expect(screen.contains(tester.getRect(find.byKey(const ValueKey('guest-display-save'))).bottomRight), isTrue);
      expect(screen.contains(tester.getRect(find.text('Cancel')).topLeft), isTrue);
      // and the last of it is reached by scrolling
      await tester.ensureVisible(find.byKey(const ValueKey('guest-tip-base:after_tax')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('guest-tip-base:after_tax')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('a hub older than the option says so and has nothing to open', (tester) async {
      await pumpLocation(tester, older: true);
      expect(rowWords(tester), startsWith('The hub has not answered about guest displays'));
      await open(tester);
      expect(find.byKey(const ValueKey('guest-display-save')), findsNothing);
    });
  });
}
