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
import 'package:pos_app/queue_store.dart';
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

  /// The PBX's extensions (`GET /phones/extensions`, with whether the hub reaches the PBX) and the screens the
  /// hub hears from (`GET /devices`), for the pull-downs under Desk phones.
  List<Map<String, dynamic>> extensions = [];
  bool extensionsConnected = false;
  List<String> devices = [];

  /// The check it serves for every order (it prices nothing itself), and its pricing rules.
  Map<String, dynamic>? check;
  Map<String, dynamic>? rules;

  /// Face sign-in: how the hub stands (`GET /faces/status`), the location's switch, what it answers to each
  /// frame (in order, the last one repeating), the staff it lists for a manager, what it answers to each
  /// enrollment view (in order, the last one repeating), and what it received.
  Map<String, dynamic> faceStatus = {
    'enabled': false,
    'ready': false,
    'active': false,
    'enrolled': 0,
    'model': null,
    'error': null,
  };
  Map<String, dynamic> facesSetting = {'enabled': false};
  List<Map<String, dynamic>> faceAnswers = [];
  final frames = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> staffList = [];
  List<Map<String, dynamic>> enrollAnswers = [];

  /// Tags: whose each id is (`POST /signin` with `tag_uid`), the ids a manager gave people, and the id
  /// another person already has (a 409 on giving it again).
  Map<String, Map<String, dynamic>> tags = {};
  final tagged = <(String, String)>[]; // (staff id, tag id) per PUT
  final tagsForgotten = <String>[];
  String? tagTakenBy;
  Map<String, dynamic> handsFree = {'switch': true, 'away_seconds': 60};

  /// Printers: the setting it keeps (`GET/PUT /settings/printers`), the token the last save carried, a reason
  /// to refuse the next save with, the stations it lists (`GET /print/stations`), what a scan finds, what it
  /// says about an address, and the test prints asked for.
  Map<String, dynamic> printers = {'printers': [], 'takeout_station': 'takeout', 'source': 'none'};
  String? printersAuth;
  String? refusePrinters;
  Map<String, dynamic> stations = {'stations': [], 'missing': [], 'takeout_station': 'takeout'};
  List<Map<String, dynamic>> found = [];
  Map<String, dynamic> identity = {'reachable': false};
  final scans = <Map<String, dynamic>>[];
  final identified = <String>[]; // the addresses `/print/identify` was asked about, in order
  final testPrints = <String>[];
  final enrolled = <(String, bool)>[]; // (staff id, replace) per view posted
  final forgotten = <String>[];
  String? faceAuth; // the token the last manager call about faces carried
  bool faces = true; // false: an older hub, which has none of the face calls

  static final _ops = RegExp(r'^/orders/([^/]+)/ops$');
  static final _samples = RegExp(r'^/admin/staff/([^/]+)/face/samples$');
  static final _face = RegExp(r'^/admin/staff/([^/]+)/face$');
  static final _tag = RegExp(r'^/admin/staff/([^/]+)/tag$');
  static final _check = RegExp(r'^/orders/([^/]+)/check$');
  static final _order = RegExp(r'^/orders/([^/]+)$');

  /// Every request that reached the hub, as `METHOD path?query`, and how many of its reads it answered with
  /// "nothing new" (304).
  final requests = <String>[];
  int unchanged = 0;

  /// Whether the hub names its answers (an `ETag` on every read, 304 for a read the terminal already has),
  /// as hubs do since 2026-11-12. Off, it is an older hub: every read comes in full.
  bool namesAnswers = true;

  /// The hub as the terminal reaches it: [answer], with every read named like the real hub names them.
  Future<http.Response> handle(http.Request request) async {
    requests.add('${request.method} ${request.url.path}${request.url.hasQuery ? '?${request.url.query}' : ''}');
    final response = await answer(request);
    if (!namesAnswers || request.method != 'GET' || response.statusCode != 200) return response;
    final etag = 'W/"${base64Encode(response.bodyBytes).hashCode}-${response.bodyBytes.length}"';
    if (request.headers['if-none-match'] == etag) {
      unchanged += 1;
      return http.Response('', 304, headers: {'etag': etag});
    }
    return http.Response.bytes(response.bodyBytes, 200, headers: {...response.headers, 'etag': etag});
  }

  Future<http.Response> answer(http.Request request) async {
    final path = request.url.path;
    if (path == '/orders') return json({'orders': orders});
    if (path == '/signin' && request.method == 'POST') {
      final body = jsonDecode(request.body) as Map;
      final tagUid = body['tag_uid'] as String?;
      if (tagUid != null) {
        final owner = tags[tagUid.toUpperCase()];
        if (owner == null) {
          return json({
            'detail': {'error': 'unknown_credential'},
          }, 401);
        }
        return json({...owner, 'method': 'tag'});
      }
      final pin = body['pin'];
      pins.add(pin as String? ?? '');
      if (pin != '1111') {
        return json({
          'detail': {'error': 'unknown_credential'},
        }, 401);
      }
      return json({'staff_id': 's1', 'name': 'Amy', 'role': 'server', 'method': 'pin'});
    }
    if (!faces &&
        (path.startsWith('/faces') ||
            path.startsWith('/admin/staff') ||
            path == '/settings/faces' ||
            path == '/settings/presence')) {
      return json({'detail': 'Not Found'}, 404);
    }
    if (path == '/signin/face' && request.method == 'POST') {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      frames.add(body);
      final answer = faceAnswers.isEmpty
          ? {'face': false, 'reason': 'no_face', 'candidate': null, 'score': null, 'signed_in': null}
          : faceAnswers[frames.length - 1 < faceAnswers.length ? frames.length - 1 : faceAnswers.length - 1];
      return json(answer);
    }
    if (_samples.hasMatch(path) && request.method == 'POST') {
      faceAuth = request.headers['authorization'];
      final id = _samples.firstMatch(path)!.group(1)!;
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      enrolled.add((id, body['replace'] as bool? ?? false));
      final n = enrolled.where((e) => e.$1 == id).length;
      final answer = enrollAnswers.isEmpty
          ? {'accepted': true, 'reason': null, 'samples': n, 'wanted': 5, 'done': n >= 5, 'looks_like': null}
          : enrollAnswers[n - 1 < enrollAnswers.length ? n - 1 : enrollAnswers.length - 1];
      if (answer['accepted'] == true) {
        for (final s in staffList) {
          if (s['staff_id'] == id) s['face'] = {'samples': answer['samples'], 'updated_at': 1730000000.0, 'stale': 0};
        }
      }
      return json(answer);
    }
    if (_tag.hasMatch(path) && request.method == 'PUT') {
      faceAuth = request.headers['authorization'];
      final id = _tag.firstMatch(path)!.group(1)!;
      final uid = ((jsonDecode(request.body) as Map)['tag_uid'] as String).toUpperCase();
      if (tagTakenBy != null) {
        return json({
          'detail': {'error': 'tag_taken', 'name': tagTakenBy, 'message': "That tag is $tagTakenBy's"},
        }, 409);
      }
      tagged.add((id, uid));
      final clean = uid.replaceAll(RegExp(r'[\s:-]'), ''); // the hub keeps the id without separators
      final ends = clean.substring(clean.length - 4);
      for (final s in staffList) {
        if (s['staff_id'] == id) s['tag'] = {'enrolled': true, 'ends': ends, 'updated_at': 1730000000.0};
      }
      return json({
        'staff_id': id,
        'tag': {'enrolled': true, 'ends': ends, 'updated_at': 1730000000.0},
      });
    }
    if (_tag.hasMatch(path) && request.method == 'DELETE') {
      faceAuth = request.headers['authorization'];
      final id = _tag.firstMatch(path)!.group(1)!;
      tagsForgotten.add(id);
      for (final s in staffList) {
        if (s['staff_id'] == id) s['tag'] = {'enrolled': false, 'ends': null, 'updated_at': 0.0};
      }
      return json({'staff_id': id, 'removed': 1});
    }
    if (_face.hasMatch(path) && request.method == 'DELETE') {
      faceAuth = request.headers['authorization'];
      final id = _face.firstMatch(path)!.group(1)!;
      forgotten.add(id);
      for (final s in staffList) {
        if (s['staff_id'] == id) s['face'] = {'samples': 0, 'updated_at': 0.0, 'stale': 0};
      }
      return json({'staff_id': id, 'removed': 1});
    }
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
      case '/settings/printers':
        if (request.method == 'PUT') {
          printersAuth = request.headers['authorization'];
          if (refusePrinters != null) {
            return json({
              'detail': {'error': 'bad_value', 'message': refusePrinters},
            }, 422);
          }
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          var n = 0;
          printers = {
            ...body,
            'printers': [
              for (final p in body['printers'] as List) {...p as Map, 'id': (p['id'] as String?) ?? 'p${++n}'},
            ],
            'source': 'settings',
          };
        }
        return json(printers);
      case '/print/stations':
        return json(stations);
      case '/print/discover':
        printersAuth = request.headers['authorization'];
        scans.add(jsonDecode(request.body) as Map<String, dynamic>);
        return json({'subnets': [], 'found': found});
      case '/print/identify':
        printersAuth = request.headers['authorization'];
        final address = (jsonDecode(request.body) as Map)['address'] as String;
        identified.add(address);
        return json({'address': address, ...identity});
      case '/print/test':
        final printer = (jsonDecode(request.body) as Map)['printer'] as String;
        final known = (printers['printers'] as List).any((p) => (p as Map)['id'] == printer);
        if (!known) {
          return json({
            'detail': {'error': 'no_such_printer'},
          }, 404);
        }
        testPrints.add(printer);
        return json({'job_id': 'test:$printer', 'status': 'queued'}, 202);
      case '/phones/status':
        return json(pbxStatus);
      case '/faces/status':
        return json(faceStatus);
      case '/settings/faces':
        if (request.method == 'PUT') {
          faceAuth = request.headers['authorization'];
          facesSetting = jsonDecode(request.body) as Map<String, dynamic>;
          faceStatus = {...faceStatus, 'enabled': facesSetting['enabled']};
        }
        return json(facesSetting);
      case '/settings/presence':
        if (request.method == 'PUT') {
          faceAuth = request.headers['authorization'];
          handsFree = jsonDecode(request.body) as Map<String, dynamic>;
        }
        return json(handsFree);
      case '/admin/staff':
        faceAuth = request.headers['authorization'];
        if (faceAuth == null) {
          return json({
            'detail': {'error': 'sign_in'},
          }, 401);
        }
        return json({'staff': staffList});
      case '/phones/extensions':
        return json({'extensions': extensions, 'connected': extensionsConnected});
      case '/devices':
        return json({
          'devices': [
            for (final device in devices) {'device': device, 'seen_ms': 1730000000000},
          ],
        });
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
            'by': data['by'] ?? '',
            'by_id': data['by_id'],
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
  final outbox = Outbox(api, settings, store: MemoryStore());
  final photos = PhotoQueue(api, settings, NoCamera(), session, store: MemoryStore());
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
