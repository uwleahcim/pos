import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/camera.dart';
import 'package:pos_app/desk_phone_watcher.dart';
import 'package:pos_app/local_order.dart';
import 'package:pos_app/menu.dart';
import 'package:pos_app/outbox.dart';
import 'package:pos_app/phone.dart';
import 'package:pos_app/photos.dart';
import 'package:pos_app/queue_store.dart';
import 'package:pos_app/screens/order_screen.dart';
import 'package:pos_app/screens/orders_screen.dart';
import 'package:pos_app/session.dart';
import 'package:pos_app/settings.dart';
import 'package:pos_app/takeout.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'hub.dart' show homeIds, openHome;
import 'location_rows.dart';

/// Counter mode and takeout (architecture section 12): a to-go order is named and numbered, paid before the
/// kitchen sees it with the change worked out, marked ready from the list, and quoted by the hub's times.

Map<String, dynamic> fixture(String name) =>
    jsonDecode(File('test/fixtures/$name.json').readAsStringSync()) as Map<String, dynamic>;

http.Response json(Object body, [int status = 200]) => http.Response.bytes(utf8.encode(jsonEncode(body)), status);

final promised = DateTime.now().add(const Duration(minutes: 15)).millisecondsSinceEpoch;

/// A to-go order as the hub replays it: numbered, named, on a channel, with one line of two egg rolls.
Map<String, dynamic> takeout(
  String id, {
  int no = 7,
  String name = 'Linda',
  String channel = 'counter',
  String stage = 'new',
  bool fired = false,
  Map<String, dynamic> payments = const {},
}) => {
  'order_id': id,
  'status': 'open',
  'fields': {
    'order_type': 'takeout',
    'order_no': no,
    'customer_name': name,
    'channel': channel,
    'stage': stage,
    'promised_at': promised,
    'locale': 'en',
  },
  'lines': {
    'L1': {'item': 'Egg roll', 'qty': 2, 'seat': 1, 'course': '2', 'status': 'active', 'fired': fired},
  },
  'fired': fired ? {'2': '2026-11-01T18:00:00'} : {},
  'payments': payments,
};

const cash = {
  'P1': {'method': 'cash', 'amount': '10.71', 'tendered': '20.00', 'by': 'Amy'},
};

/// Two egg rolls at 5.00 with the 7% Winchester rate: 0.63 + 0.08 tax, 10.71 due until something is paid.
Map<String, dynamic> checkJson({bool paid = false}) => {
  'lines': [
    {'line_id': 'L1', 'name': 'Egg roll', 'qty': 2, 'total': '10.00'},
  ],
  'subtotal': '10.00',
  'tax_lines': [
    {'name': 'Massachusetts meals tax', 'rate_pct': '6.25', 'amount': '0.63'},
    {'name': 'Winchester meals tax', 'rate_pct': '0.75', 'amount': '0.08'},
  ],
  'tax_rate_pct': '7.00',
  'tax': '0.71',
  'total': '10.71',
  'payments': [
    if (paid) {'payment_id': 'P1', 'method': 'cash', 'amount': '10.71', 'tendered': '20.00', 'by': 'Amy'},
  ],
  'paid': paid ? '10.71' : '0.00',
  'due': paid ? '0.00' : '10.71',
};

/// A pretend hub: the orders it lists, the quote times it keeps, and everything the terminal sends it.
class Hub {
  final orders = <Map<String, dynamic>>[];
  final sent = <(String, Map<String, dynamic>)>[]; // (order id, op)
  final pins = <String>[];
  Map<String, dynamic> quotes = {
    'minutes': {'counter': 15, 'phone': 20, 'online': 25, 'delivery': 45},
    'pay_at_pickup': ['phone'],
  };
  String? quotesAuth;
  bool paid = false;

  /// Whether it marks an order that is brought to the customer on its papers (docs/delivery.md), and says
  /// so with its quotes, as the real hub does; false for a hub older than deliveries.
  bool delivers = true;
  Map<String, dynamic> get quotesOut => {...quotes, if (delivers) 'delivers': true};

  /// The rush (`PUT /settings/rush`): the minutes it was set to, in order, who asked, and when a rush set
  /// now runs out. It answers only when its quotes name a rush (`'rush': null` for none): the hub the tests
  /// start with is one from before the rush and before big orders.
  final rushSet = <int>[];
  String? rushAuth;
  int rushUntil = DateTime.now().add(const Duration(hours: 6)).millisecondsSinceEpoch;

  /// Called with every operation as it arrives, for a test that plays the hub's part (a dish added shows
  /// on the order it serves).
  void Function(String orderId, Map<String, dynamic> op)? onOp;

  /// Finding a check: the closed checks of the last day ([past], listed after [orders] when a list asks for
  /// more than the open ones), the checks opened on a day by its date ([byDay], `GET /orders?day=`), and
  /// what every list of orders asked for.
  final past = <Map<String, dynamic>>[];
  final byDay = <String, List<Map<String, dynamic>>>{};
  final listsAsked = <Map<String, String>>[];

  /// What it answers for a caller's last order of the day (null: none), the numbers it was asked about, and
  /// whether it is down for that call.
  Map<String, dynamic>? lastOrder;
  final lastOrderAsked = <String>[];
  bool lastOrderDown = false;

  /// Customers: what it knows of each number, by its digits (`GET /customers/lookup`; a number it does not
  /// know is answered `known: false`), the numbers it was asked about, the notes it was given to keep as
  /// (digits, note, by) (`PUT /customers/{digits}`), what "same again" answers for a past order
  /// (`GET /orders/{id}/again`; 404 for one it does not list), whether it refuses to keep a note, and
  /// [customersOld] for a hub older than customers (404 on all of it).
  final customers = <String, Map<String, dynamic>>{};
  final customersAsked = <String>[];
  final notesKept = <(String, String, String?)>[];
  final again = <String, Map<String, dynamic>>{};
  bool notesRefused = false;
  bool customersOld = false;

  static Map<String, dynamic> _nobody(String digits) => {
    'phone': digits,
    'known': false,
    'name': '',
    'note': '',
    'orders': 0,
    'first_ms': null,
    'last_ms': null,
    'recent': <Object>[],
  };

  /// Desk phones (`GET /phones/answered`): whether one is linked to the asking device, the calls it lists
  /// (each with a `seq`; the hub's cursor is the highest), the devices that asked with the `after` and `wait`
  /// they sent, and whether it is down for that call. A request with `wait` is held until [pickUp] lists a
  /// call newer than its `after` or the wait is over; a hub from before held requests ([holds] false) answers
  /// at once.
  bool linked = false;
  final answered = <Map<String, dynamic>>[];
  final answeredAsked = <String>[];
  final answeredAfter = <int>[];
  final answeredWait = <int>[];
  bool answeredDown = false;
  bool holds = true;
  final _waiting = <Completer<void>>[];

  int get answeredCursor => answered.fold(0, (most, c) => math.max(most, (c['seq'] as int?) ?? 0));

  /// A desk phone picks up: the call is listed, and every held request is answered.
  void pickUp(Map<String, dynamic> call) {
    answered.add(call);
    for (final w in _waiting) {
      if (!w.isCompleted) w.complete();
    }
    _waiting.clear();
  }

  static final _ops = RegExp(r'^/orders/([^/]+)/ops$');
  static final _check = RegExp(r'^/orders/([^/]+)/check$');
  static final _order = RegExp(r'^/orders/([^/]+)$');
  static final _again = RegExp(r'^/orders/([^/]+)/again$');
  static final _customer = RegExp(r'^/customers/(\d+)$');

  Future<http.Response> handle(http.Request request) async {
    final path = request.url.path;
    if (path == '/orders') {
      final asked = request.url.queryParameters;
      listsAsked.add(asked);
      if (asked['day'] != null) return json({'orders': byDay[asked['day']] ?? const <Object>[]});
      return json({
        'orders': [...orders, if (asked['status'] != 'open') ...past],
      });
    }
    if (customersOld && (path.startsWith('/customers/') || _again.hasMatch(path))) {
      return json({'detail': 'Not Found'}, 404);
    }
    if (path == '/customers/lookup') {
      final digits = request.url.queryParameters['phone'] ?? '';
      customersAsked.add(digits);
      return json(customers[digits] ?? _nobody(digits));
    }
    if (_customer.hasMatch(path) && request.method == 'PUT') {
      if (notesRefused) {
        return json({
          'detail': {'error': 'read_only'},
        }, 503);
      }
      final digits = _customer.firstMatch(path)!.group(1)!;
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final note = body['note'] as String;
      notesKept.add((digits, note, body['by'] as String?));
      final had = customers[digits] ?? _nobody(digits);
      customers[digits] = {...had, 'note': note, 'known': note.isNotEmpty || (had['orders'] as int) > 0};
      return json({'phone': digits, 'note': note, 'max': 120});
    }
    if (_again.hasMatch(path)) {
      final answer = again[_again.firstMatch(path)!.group(1)!];
      return answer == null ? json({'detail': 'no such order'}, 404) : json(answer);
    }
    if (path == '/orders/last') {
      lastOrderAsked.add(request.url.queryParameters['phone'] ?? '');
      if (lastOrderDown) return json({'detail': 'down'}, 503);
      return json({'order': lastOrder});
    }
    if (path == '/phones/answered') {
      final q = request.url.queryParameters;
      answeredAsked.add(q['device'] ?? '');
      final after = int.tryParse(q['after'] ?? '') ?? 0;
      final wait = int.tryParse(q['wait'] ?? '') ?? 0;
      answeredAfter.add(after);
      answeredWait.add(wait);
      if (answeredDown) return json({'detail': 'down'}, 503);
      final newer = answered.any((c) => ((c['seq'] as int?) ?? 0) > after);
      if (holds && wait > 0 && !newer && after <= answeredCursor) {
        final woken = Completer<void>();
        _waiting.add(woken);
        await Future.any([woken.future, Future<void>.delayed(Duration(seconds: wait))]);
      }
      return json({'device': q['device'], 'linked': linked, 'calls': answered, 'cursor': answeredCursor});
    }
    if (_ops.hasMatch(path)) {
      final id = _ops.firstMatch(path)!.group(1)!;
      final ops = (jsonDecode(request.body) as List).cast<Map<String, dynamic>>();
      sent.addAll(ops.map((op) => (id, op)));
      for (final op in ops) {
        onOp?.call(id, op);
      }
      return json({'accepted': ops.map((o) => o['op_id']).toList(), 'cursor': sent.length}, 202);
    }
    if (_check.hasMatch(path)) return json(checkJson(paid: paid));
    if (_order.hasMatch(path)) {
      final id = _order.firstMatch(path)!.group(1)!;
      final order = orders.where((o) => o['order_id'] == id).firstOrNull;
      return order == null ? json({'detail': 'not found'}, 404) : json(order);
    }
    switch (path) {
      case '/settings/quotes':
        if (request.method == 'PUT') {
          quotesAuth = request.headers['authorization'];
          // What a save names is kept as sent; what it does not name (the rush, always) stays as it was.
          quotes = {...quotes, ...jsonDecode(request.body) as Map<String, dynamic>};
        }
        return json(quotesOut);
      case '/settings/rush':
        if (!quotes.containsKey('rush')) return json({'detail': 'Not Found'}, 404);
        rushAuth = request.headers['authorization'];
        final minutes = (jsonDecode(request.body) as Map)['minutes'] as int;
        rushSet.add(minutes);
        quotes = {
          ...quotes,
          'rush': minutes > 0 ? {'minutes': minutes, 'until': rushUntil, 'by': 'Mike'} : null,
        };
        return json(quotesOut);
      case '/admin/session':
        final pin = (jsonDecode(request.body) as Map)['pin'] as String;
        pins.add(pin);
        if (pin != '9999') {
          return json({
            'detail': {'error': 'not_allowed'},
          }, 403);
        }
        return json({'token': 'tok-admin', 'name': 'Mike', 'role': 'manager'});
      case '/floor':
        return json(fixture('floor'));
      case '/menu':
        return json(fixture('menu'));
    }
    return json({'revision': 0});
  }

  List<Map<String, dynamic>> opsFor(String orderId) => [
    for (final (id, op) in sent)
      if (id == orderId) op,
  ];
}

class Terminal {
  Terminal(this.hub, this.api, this.outbox, this.photos, this.session, this.settings);
  final Hub hub;
  final PosApi api;
  final Outbox outbox;
  final PhotoQueue photos;
  final Session session;
  final Settings settings;

  /// The desk-phone watcher the orders screen was given, when the test asked for one.
  DeskPhoneWatcher? deskPhones;
}

Future<Terminal> terminal(WidgetTester tester, {String role = 'manager'}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final settings = Settings(device: 't1', endpoints: ['http://hub:8000'], prefs: prefs);
  final hub = Hub();
  final api = PosApi(settings, client: MockClient(hub.handle));
  final session = Session(api)..staff = Staff(staffId: 's3', name: 'Mike', role: role, method: 'pin');
  final outbox = Outbox(api, settings, store: MemoryStore());
  final photos = PhotoQueue(api, settings, NoCamera(), session, store: MemoryStore());
  tester.view
    ..physicalSize = const Size(1100, 800)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  return Terminal(hub, api, outbox, photos, session, settings);
}

/// The list of orders, with the hub listing [orders]. With [deskPhones], the screen watches the desk phones
/// through the watcher it builds (stopped with the test); [before] runs once the terminal stands, before the
/// screen comes up.
Future<Terminal> pumpOrders(
  WidgetTester tester,
  List<Map<String, dynamic>> orders, {
  String role = 'manager',
  PhoneClient? phone,
  DeskPhoneWatcher Function(PosApi api, Settings settings)? deskPhones,
  Future<void> Function(Hub hub)? before,
  bool showList = true,
}) async {
  final t = await terminal(tester, role: role);
  t.hub.orders.addAll(orders);
  final watcher = t.deskPhones = deskPhones?.call(t.api, t.settings);
  if (watcher != null) addTearDown(watcher.stop);
  await before?.call(t.hub);
  await tester.pumpWidget(
    MaterialApp(
      home: OrdersScreen(
        api: t.api,
        outbox: t.outbox,
        settings: t.settings,
        session: t.session,
        camera: NoCamera(),
        photos: t.photos,
        phone: phone,
        deskPhones: watcher,
      ),
    ),
  );
  await tester.pumpAndSettle();
  if (showList) {
    await tester.tap(find.byTooltip('List of checks'));
    await tester.pumpAndSettle();
  }
  return t;
}

/// The order screen for [order], pushed over a home page so the test sees it go back for the next customer.
/// [before] runs once the terminal stands, before the screen comes up.
Future<Terminal> pumpOrder(
  WidgetTester tester,
  Map<String, dynamic> order, {
  bool paid = false,
  void Function(Hub hub)? before,
}) async {
  final t = await terminal(tester);
  t.hub.orders.add(order);
  t.hub.paid = paid;
  before?.call(t.hub);
  await tester.pumpWidget(
    const MaterialApp(
      home: Scaffold(body: Center(child: Text('next customer'))),
    ),
  );
  final navigator = tester.state<NavigatorState>(find.byType(Navigator));
  unawaited(
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => OrderScreen(
          api: t.api,
          outbox: t.outbox,
          photos: t.photos,
          orderId: order['order_id'] as String,
          staffName: 'Amy',
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return t;
}

Future<void> stop(WidgetTester tester) => tester.pumpWidget(const SizedBox()); // stops the refresh timers

void main() {
  test('a to-go order carries its number, name, channel, stage, time and payments', () {
    final order = Order.fromJson(takeout('o1', fired: true, payments: cash));
    expect((order.isTakeout, order.orderNo, order.customerName, order.channel), (true, 7, 'Linda', 'counter'));
    expect((order.stage, order.promisedAt, order.hasPaid), ('new', promised, true));
    final payment = order.payments.single;
    expect(
      (payment.paymentId, payment.method, payment.amount, payment.tendered, payment.by),
      ('P1', 'cash', '10.71', '20.00', 'Amy'),
    );
    expect(const Order.empty('o2').stage, 'new');
    expect(Order.fromJson(takeout('o3', fired: true)).hasPaid, isFalse);
  });

  test('the quote times come from the hub, with the defaults for a channel it does not name', () {
    final quotes = Quotes.fromJson({
      'minutes': {'phone': 30},
      'pay_at_pickup': ['phone'],
    });
    expect((quotes.minutesFor('phone'), quotes.minutesFor('counter')), (30, 15));
    expect((quotes.mayPayAtPickup('phone'), quotes.mayPayAtPickup('counter')), (true, false));
    expect(quotes.toJson(), {
      'minutes': {'phone': 30},
      'pay_at_pickup': ['phone'],
    });
    expect(const Quotes().minutesFor('delivery'), 45);
  });

  test('a payment taken on this screen shows as pending and is counted once', () {
    final hub = Order.fromJson(takeout('o1'));
    final check = Check.fromJson(checkJson());
    expect(check.due, '10.71');
    expect(Check.fromJson({'total': '5.00'}).due, '5.00'); // an older hub: nothing paid means all of it is due
    final pay = {
      'order_id': 'o1',
      'kind': 'pay',
      'data': {'payment_id': 'P9', 'method': 'cash', 'amount': '10.71', 'tendered': '20.00', 'by': 'Amy'},
    };
    final order = withLocalOps(hub, [pay, pay]);
    final payment = order.payments.single;
    expect((payment.paymentId, payment.pending, payment.tendered), ('P9', true, '20.00'));
    expect(order.hasPaid, isTrue);

    final estimate = estimateCheck(check, order, const {});
    expect((estimate.estimated, estimate.total, estimate.paid, estimate.due), (true, '10.71', '10.71', '0.00'));
    expect(estimateCheck(check, hub, const {}), same(check));
  });

  testWidgets('a to-go order is paid in cash before it goes to the kitchen, with the change shown', (tester) async {
    final t = await pumpOrder(tester, takeout('o1'));
    expect(find.text('#7 Linda · ${clockTime(promised)}'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Pay & send'), findsOneWidget);
    expect(find.textContaining('Fire'), findsNothing); // no courses on a to-go order: everything goes at once

    await tester.tap(find.widgetWithText(TextButton, 'Pay & send'));
    await tester.pumpAndSettle();
    expect(find.text('Due \$10.71'), findsOneWidget);
    expect(find.byKey(const ValueKey('pay:later')), findsNothing); // the counter pays now
    expect(find.text('Exact'), findsOneWidget);
    for (final bill in ['15.00', '20.00', '50.00', '100.00']) {
      expect(find.byKey(ValueKey('tender:$bill')), findsOneWidget);
    }
    expect(find.text('Change \$0.00'), findsOneWidget);

    await tester.enterText(find.byKey(const ValueKey('tendered')), '5');
    await tester.pumpAndSettle();
    expect(find.text('Not enough'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('pay-send'))).onPressed, isNull);

    await tester.tap(find.byKey(const ValueKey('tender:20.00')));
    await tester.pumpAndSettle();
    expect(find.text('Change \$9.29'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('pay-send')));
    await tester.pumpAndSettle();

    final ops = t.hub.opsFor('o1');
    expect(ops.map((op) => op['kind']), ['pay', 'fire']);
    final pay = ops.first['data'] as Map<String, dynamic>;
    expect(pay['payment_id'], isNotEmpty);
    expect((pay['method'], pay['amount'], pay['tendered'], pay['by']), ('cash', '10.71', '20.00', 'Amy'));
    expect(pay.containsKey('note'), isFalse);
    expect(ops.last['data'], {'course': '*'});

    expect(find.byKey(const ValueKey('change-due')), findsOneWidget);
    expect(find.text('Change \$9.29'), findsOneWidget);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.text('next customer'), findsOneWidget); // back for the next one
    await stop(tester);
  });

  testWidgets('a phone order may go to the kitchen unpaid, or be marked paid elsewhere', (tester) async {
    final t = await pumpOrder(tester, takeout('o2', channel: 'phone'));
    await tester.tap(find.widgetWithText(TextButton, 'Pay & send'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('pay:later')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('pay:elsewhere')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('pay-note')), 'by phone');
    await tester.tap(find.byKey(const ValueKey('pay-send')));
    await tester.pumpAndSettle();
    var ops = t.hub.opsFor('o2');
    expect(ops.map((op) => op['kind']), ['pay', 'fire']);
    final pay = ops.first['data'] as Map<String, dynamic>;
    expect((pay['method'], pay['amount'], pay['note']), ('elsewhere', '10.71', 'by phone'));
    expect(pay.containsKey('tendered'), isFalse);
    expect(find.byKey(const ValueKey('change-due')), findsNothing);
    expect(find.text('next customer'), findsOneWidget);

    // The same order again, paying at pickup this time: nothing is taken and only the fire goes.
    t.hub.sent.clear();
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    unawaited(
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => OrderScreen(api: t.api, outbox: t.outbox, photos: t.photos, orderId: 'o2', staffName: 'Amy'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Pay & send'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('pay:later')));
    await tester.pumpAndSettle();
    expect(find.text('Nothing taken now; the ready text says to pay at pickup.'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Send'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('pay-send')));
    await tester.pumpAndSettle();
    ops = t.hub.opsFor('o2');
    expect(ops.map((op) => op['kind']), ['fire']);
    expect(find.text('next customer'), findsOneWidget);
    await stop(tester);
  });

  testWidgets('a paid order shows what was taken and nothing due', (tester) async {
    await pumpOrder(tester, takeout('o1', fired: true, payments: cash), paid: true);
    expect(find.byKey(const ValueKey('paid-P1')), findsOneWidget);
    expect(find.text('Paid cash (tendered 20.00)'), findsOneWidget);
    expect(find.text('−10.71'), findsOneWidget);
    expect(find.byKey(const ValueKey('due')), findsOneWidget);
    expect(find.text('Pay & send'), findsNothing); // nothing held, nothing owed
    expect(find.text('Send'), findsNothing);
    await stop(tester);
  });

  testWidgets('the list numbers to-go orders and moves them along: ready texts, picked up closes', (tester) async {
    final t = await pumpOrders(tester, [
      takeout('o1', fired: true, payments: cash),
      takeout('o2', no: 8, name: 'Wei', channel: 'phone', stage: 'ready', fired: true),
      takeout('o3', no: 9, name: 'Sam'), // still being taken: no step yet
      {
        'order_id': 'o4',
        'status': 'open',
        'fields': {'table': 'A1', 'guests': 2, 'order_type': 'dine_in'},
        'lines': {},
        'fired': {},
      },
    ]);
    expect(find.text('7'), findsOneWidget);
    expect(find.text('Linda · counter'), findsOneWidget);
    expect(find.text('2 items · open · fired · ready ${clockTime(promised)} · paid'), findsOneWidget);
    expect(find.text('Wei · phone'), findsOneWidget);
    expect(find.text('2 items · open · fired · ready ${clockTime(promised)} · pay at pickup · READY'), findsOneWidget);
    expect(find.text('Table A1'), findsOneWidget);
    expect(find.byKey(const ValueKey('ready-o1')), findsOneWidget);
    expect(find.byKey(const ValueKey('picked-up-o2')), findsOneWidget);
    expect(find.byKey(const ValueKey('ready-o3')), findsNothing);
    expect(find.byKey(const ValueKey('picked-up-o3')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('ready-o1')));
    await tester.pumpAndSettle();
    expect(t.hub.opsFor('o1').map((op) => op['kind']), ['set_field']);
    expect(t.hub.opsFor('o1').single['data'], {'stage': 'ready'});

    await tester.tap(find.byKey(const ValueKey('picked-up-o2')));
    await tester.pumpAndSettle();
    expect(t.hub.opsFor('o2').map((op) => op['kind']), ['set_field', 'close']);
    expect(t.hub.opsFor('o2').first['data'], {'stage': 'picked_up'});
    await stop(tester);
  });

  testWidgets('a to-go order starts from a name, a phone and the channel, timed by the hub quote', (tester) async {
    final t = await pumpOrders(tester, const []);
    await tester.tap(find.text('To go'));
    await tester.pumpAndSettle();
    expect(find.text('To-go order'), findsOneWidget);
    expect(find.text('Ready in about 15 min'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('takeout-start'))).onPressed, isNull);

    await tester.enterText(find.byKey(const ValueKey('takeout-name')), 'Linda');
    await tester.enterText(find.byKey(const ValueKey('takeout-phone')), '617 555 0100');
    await tester.tap(find.byKey(const ValueKey('channel:phone')));
    await tester.pumpAndSettle();
    expect(find.text('Ready in about 20 min'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('locale:zh')));
    await tester.pumpAndSettle();
    final before = DateTime.now();
    await tester.tap(find.byKey(const ValueKey('takeout-start')));
    await tester.pumpAndSettle();

    final (orderId, create) = t.hub.sent.single;
    expect(create['kind'], 'create');
    final data = create['data'] as Map<String, dynamic>;
    expect(
      (data['order_type'], data['channel'], data['customer_name'], data['phone']),
      ('takeout', 'phone', 'Linda', '617 555 0100'),
    );
    expect((data['locale'], data['quoted_minutes'], data['stage']), ('zh', 20, 'new'));
    expect(data.containsKey('for_later'), isFalse); // as soon as the quote allows: nobody named a time
    expect((data['server'], data['server_id']), ('Mike', 's3'));
    expect(data.containsKey('order_no'), isFalse); // the hub numbers it
    final promisedAt = DateTime.fromMillisecondsSinceEpoch(data['promised_at'] as int);
    expect(promisedAt.difference(before).inMinutes, inInclusiveRange(19, 20));

    // The new check opens at once, numbered once the hub has it, named now.
    expect(find.textContaining('#… Linda'), findsOneWidget);
    expect(t.outbox.localOps(orderId).map((op) => op['kind']), ['create']);
    await stop(tester);
  });

  testWidgets('a future order takes a day and a time; the kitchen prints it ahead by the quote', (tester) async {
    final t = await pumpOrders(tester, const []);
    await tester.tap(find.text('To go'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('takeout-name')), 'Linda');
    await tester.tap(find.byKey(const ValueKey('takeout-later')));
    await tester.pumpAndSettle();
    expect(find.text('Prints ahead of its time by the quote'), findsOneWidget);
    expect(find.text('Pick the time it is for.'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('takeout-start'))).onPressed, isNull);

    await tester.tap(find.text('Tomorrow'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('takeout-time')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Switch to text input mode'));
    await tester.pumpAndSettle();
    final fields = find.descendant(of: find.byType(Dialog).last, matching: find.byType(TextField));
    await tester.enterText(fields.at(0), '6');
    await tester.enterText(fields.at(1), '30');
    await tester.tap(find.text('PM'));
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.text('Pick the time it is for.'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('takeout-start')));
    await tester.pumpAndSettle();
    final data = t.hub.sent.single.$2['data'] as Map<String, dynamic>;
    final promisedAt = DateTime.fromMillisecondsSinceEpoch(data['promised_at'] as int);
    final tomorrow = DateTime.now().add(const Duration(days: 1));
    expect((promisedAt.year, promisedAt.month, promisedAt.day), (tomorrow.year, tomorrow.month, tomorrow.day));
    expect((promisedAt.hour, promisedAt.minute), (18, 30));
    expect((data['quoted_minutes'], data['for_later']), (15, true)); // the customer named the time
    await stop(tester);
  });

  testWidgets('a manager sets the quote times for every terminal; a server has no such button', (tester) async {
    final t = await pumpOrders(tester, const []);
    await openHome(tester, 'location');
    await tester.pumpAndSettle();
    expect(find.text('Manager PIN'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, '1111');
    await tester.tap(find.widgetWithText(FilledButton, 'Open location settings'));
    await tester.pumpAndSettle();
    expect(find.text('Only a manager can change location settings'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, '9999');
    await tester.tap(find.widgetWithText(FilledButton, 'Open location settings'));
    await tester.pumpAndSettle();
    expect(t.hub.pins, ['1111', '9999']);
    expect(find.text('Location settings'), findsOneWidget);

    await bringUp(tester, 'quote-times');
    await tester.tap(find.byKey(const ValueKey('quote-times')));
    await tester.pumpAndSettle();
    expect(find.text('Quote times'), findsNWidgets(2)); // the row and the dialog
    expect(tester.widget<TextField>(find.byKey(const ValueKey('quote:phone'))).controller!.text, '20');
    await tester.enterText(find.byKey(const ValueKey('quote:phone')), '25');
    await tester.tap(find.byKey(const ValueKey('pickup:online')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('quotes-save')));
    await tester.pumpAndSettle();

    expect(t.hub.quotesAuth, 'Bearer tok-admin');
    expect(t.hub.quotes, {
      'minutes': {'counter': 15, 'phone': 25, 'online': 25, 'delivery': 45, 'catering': 60},
      'pay_at_pickup': ['online', 'phone'],
    });
    expect(find.text('Quote times saved'), findsOneWidget);
    await stop(tester);

    await pumpOrders(tester, const [], role: 'server');
    expect(homeIds(tester), isNot(contains('location')));
    await stop(tester);
  });
}
