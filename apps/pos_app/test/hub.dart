import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/camera.dart';
import 'package:pos_app/outbox.dart';
import 'package:pos_app/photos.dart';
import 'package:pos_app/screens/orders_screen.dart';
import 'package:pos_app/session.dart';
import 'package:pos_app/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A pretend hub and a terminal talking to it, for the screen tests.
Map<String, dynamic> fixture(String name) =>
    jsonDecode(File('test/fixtures/$name.json').readAsStringSync()) as Map<String, dynamic>;

http.Response json(Object body, [int status = 200]) => http.Response.bytes(utf8.encode(jsonEncode(body)), status);

const standard = [
  {'id': 'drinks', 'name': 'Drinks'},
  {'id': '1', 'name': 'Appetizers'},
  {'id': '2', 'name': 'Entrees'},
  {'id': '3', 'name': 'Dessert'},
];

Map<String, dynamic> table(String id, Map<String, dynamic> lines) => {
  'order_id': id,
  'status': 'open',
  'fields': {'table': 'A1', 'guests': 2, 'order_type': 'dine_in'},
  'lines': lines,
  'fired': {},
};

Map<String, dynamic> line(String item, {String? course, bool fired = false, double? rank}) => {
  'item': item,
  'qty': 1,
  'seat': 1,
  'course': ?course,
  'status': 'active',
  'fired': fired,
  'rank': ?rank,
};

/// A pretend hub: its orders, the coursing and quote settings it keeps, and what the terminal sends it.
class Hub {
  final orders = <Map<String, dynamic>>[];
  final sent = <(String, Map<String, dynamic>)>[];
  final pins = <String>[];
  Map<String, dynamic> coursing = {'enabled': true, 'default': '1', 'courses': standard};
  Map<String, dynamic> quotes = {
    'minutes': {'counter': 15, 'phone': 20, 'online': 25, 'delivery': 45},
    'pay_at_pickup': ['phone'],
  };
  String? coursingAuth;
  String? refuse; // a reason the hub refuses the next coursing save with

  /// Desk phones: the links it keeps, the token the last save carried, a reason to refuse the next save with,
  /// and how it stands with the PBX (`GET /phones/status`).
  Map<String, dynamic> deskPhones = {'links': []};
  String? deskPhonesAuth;
  String? refuseDeskPhones;
  Map<String, dynamic> pbxStatus = {'configured': false, 'connected': false, 'answers': 0, 'pops': 0, 'links': 0};

  /// The check it serves for every order (it prices nothing itself), and its pricing rules.
  Map<String, dynamic>? check;
  Map<String, dynamic>? rules;

  static final _ops = RegExp(r'^/orders/([^/]+)/ops$');
  static final _check = RegExp(r'^/orders/([^/]+)/check$');
  static final _order = RegExp(r'^/orders/([^/]+)$');

  Future<http.Response> handle(http.Request request) async {
    final path = request.url.path;
    if (path == '/orders') return json({'orders': orders});
    if (_ops.hasMatch(path)) {
      final id = _ops.firstMatch(path)!.group(1)!;
      final ops = (jsonDecode(request.body) as List).cast<Map<String, dynamic>>();
      sent.addAll(ops.map((op) => (id, op)));
      _apply(id, ops);
      return json({'accepted': ops.map((o) => o['op_id']).toList(), 'cursor': sent.length}, 202);
    }
    if (_check.hasMatch(path)) {
      return json(check ?? {'lines': [], 'subtotal': '0.00', 'tax_rate_pct': '7.00', 'tax': '0.00', 'total': '0.00'});
    }
    if (path.startsWith('/menu/items/')) return json(fixture('item_${path.split('/').last.toLowerCase()}'));
    if (_order.hasMatch(path)) {
      final id = _order.firstMatch(path)!.group(1)!;
      final order = orders.where((o) => o['order_id'] == id).firstOrNull;
      return order == null ? json({'detail': 'not found'}, 404) : json(order);
    }
    switch (path) {
      case '/settings/coursing':
        if (request.method == 'PUT') {
          coursingAuth = request.headers['authorization'];
          if (refuse != null) {
            return json({
              'detail': {'error': 'bad_value', 'message': refuse},
            }, 422);
          }
          coursing = jsonDecode(request.body) as Map<String, dynamic>;
        }
        return json(coursing);
      case '/settings/quotes':
        if (request.method == 'PUT') quotes = jsonDecode(request.body) as Map<String, dynamic>;
        return json(quotes);
      case '/settings/desk_phones':
        if (request.method == 'PUT') {
          deskPhonesAuth = request.headers['authorization'];
          if (refuseDeskPhones != null) {
            return json({
              'detail': {'error': 'bad_value', 'message': refuseDeskPhones},
            }, 422);
          }
          deskPhones = jsonDecode(request.body) as Map<String, dynamic>;
        }
        return json(deskPhones);
      case '/phones/status':
        return json(pbxStatus);
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
      case '/menu/price':
        return json({'name': "General Tso's Chicken (Quart)", 'unit_price': '26.95'});
      case '/pricing/rules':
        return json(rules ?? {'discounts': [], 'charges': []});
      case '/approvals':
        // a manager's PIN for a discount on one order: Mike (9999) approves, anyone else is no manager
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        pins.add(body['pin'] as String);
        if (body['pin'] != '9999') {
          return json({
            'detail': {'error': 'not_allowed', 'role': 'server'},
          }, 403);
        }
        return json({
          'approval': 'tok-${body['order_id']}',
          'staff_id': 's3',
          'name': 'Mike',
          'role': 'manager',
          'expires': 1,
        });
    }
    return json({'revision': 0});
  }

  /// The hub's replay, as far as these tests need it: an order read back shows what the terminal sent.
  void _apply(String orderId, List<Map<String, dynamic>> ops) {
    final order = orders.where((o) => o['order_id'] == orderId).firstOrNull;
    if (order == null) return;
    final lines = (order['lines'] as Map).cast<String, dynamic>();
    for (final op in ops) {
      final data = (op['data'] as Map).cast<String, dynamic>();
      switch (op['kind']) {
        case 'add_line':
          final ranks = [for (final l in lines.values) ((l as Map)['rank'] as num? ?? 0).toDouble()];
          lines[data['line_id'] as String] = {
            'item': data['item'],
            'qty': data['qty'] ?? 1,
            'seat': data['seat'],
            'course': data['course'],
            'note': data['note'] ?? '',
            'request': data['request'],
            'replaces': data['replaces'], // an edit: the line this one took the place of
            'status': 'active',
            'fired': false,
            'rank': data['rank'] ?? (ranks.isEmpty ? 1.0 : ranks.reduce(max) + 1),
          };
        case 'set_line':
          final line = lines[data['line_id']] as Map?;
          for (final field in const ['qty', 'seat', 'course', 'note', 'rank']) {
            if (line != null && data.containsKey(field)) line[field] = data[field];
          }
        case 'void_line':
          final line = lines[data['line_id']] as Map?;
          if (line != null) line['status'] = line['fired'] == true ? 'void' : 'removed';
        case 'fire':
          for (final line in lines.values.cast<Map>()) {
            if (line['status'] == 'active' && (data['course'] == '*' || line['course'] == data['course'])) {
              line['fired'] = true;
            }
          }
      }
    }
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
}

Future<Terminal> terminal(WidgetTester tester, {String role = 'manager'}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final settings = Settings(device: 't1', endpoints: ['http://hub:8000'], prefs: prefs);
  final hub = Hub();
  final api = PosApi(settings, client: MockClient(hub.handle));
  final session = Session(api)..staff = Staff(staffId: 's3', name: 'Mike', role: role, method: 'pin');
  final outbox = Outbox(api, settings, prefs: prefs);
  final photos = PhotoQueue(api, settings, NoCamera(), session, prefs: prefs);
  tester.view
    ..physicalSize = const Size(1100, 800)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  return Terminal(hub, api, outbox, photos, session, settings);
}

/// The list of orders, with the hub listing [orders].
Future<Terminal> pumpOrders(WidgetTester tester, List<Map<String, dynamic>> orders, {String role = 'manager'}) async {
  final t = await terminal(tester, role: role);
  t.hub.orders.addAll(orders);
  await tester.pumpWidget(
    MaterialApp(
      home: OrdersScreen(
        api: t.api,
        outbox: t.outbox,
        settings: t.settings,
        session: t.session,
        camera: NoCamera(),
        photos: t.photos,
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byTooltip('List of checks'));
  await tester.pumpAndSettle();
  return t;
}

Future<void> stop(WidgetTester tester) => tester.pumpWidget(const SizedBox()); // stops the refresh timers
