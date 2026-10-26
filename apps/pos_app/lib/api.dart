import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'settings.dart';

/// One line of an order, exactly as the backend reports it.
class Line {
  const Line({
    required this.lineId,
    required this.item,
    required this.qty,
    required this.status,
    this.seat,
    this.course,
    this.note = '',
    this.modifiedAfterFire = false,
  });

  factory Line.fromJson(String lineId, Map<String, dynamic> json) => Line(
    lineId: lineId,
    item: json['item'] as String? ?? '',
    qty: json['qty'] as int? ?? 1,
    status: json['status'] as String? ?? 'active',
    seat: json['seat'] as int?,
    course: json['course'] as String?,
    note: json['note'] as String? ?? '',
    modifiedAfterFire: json['modified_after_fire'] as bool? ?? false,
  );

  final String lineId;
  final String item;
  final int qty;
  final String status;
  final int? seat;
  final String? course;
  final String note;
  final bool modifiedAfterFire;

  bool get isVoid => status == 'void';
}

/// An order as the backend replays it. The app never computes this itself.
class Order {
  const Order({
    required this.orderId,
    required this.status,
    required this.fields,
    required this.lines,
    required this.fired,
  });

  factory Order.fromJson(Map<String, dynamic> json) {
    final lines = (json['lines'] as Map<String, dynamic>? ?? const {}).entries
        .map((e) => Line.fromJson(e.key, e.value as Map<String, dynamic>))
        .toList();
    return Order(
      orderId: json['order_id'] as String,
      status: json['status'] as String? ?? 'open',
      fields: Map<String, dynamic>.from(json['fields'] as Map? ?? const {}),
      lines: lines,
      fired: Map<String, String>.from(json['fired'] as Map? ?? const {}),
    );
  }

  final String orderId;
  final String status;
  final Map<String, dynamic> fields;
  final List<Line> lines;
  final Map<String, String> fired;

  String get table => fields['table']?.toString() ?? '';
  bool get isOpen => status == 'open';
  bool get isFired => fired.isNotEmpty;
  List<Line> get activeLines => lines.where((l) => !l.isVoid).toList();
}

/// What the status bar shows: which address answers, or none.
class Connection {
  const Connection({this.endpoint, this.error});
  final String? endpoint;
  final String? error;
  bool get isOnline => endpoint != null;
}

class ApiException implements Exception {
  ApiException(this.message, {this.status});
  final String message;
  final int? status;
  @override
  String toString() => status == null ? message : '$message ($status)';
}

/// The backend's three order log calls plus the list, with failover between addresses.
///
/// Every call tries the address that answered last, then the others in the configured order. A call that
/// reaches a backend but is refused (4xx) is not retried elsewhere: the answer would be the same.
class PosApi {
  PosApi(this.settings, {http.Client? client, this.timeout = const Duration(seconds: 2)})
    : _client = client ?? http.Client();

  final Settings settings;
  final http.Client _client;
  final Duration timeout;
  final ValueNotifier<Connection> connection = ValueNotifier(const Connection());

  Future<Map<String, dynamic>> health() => _get('/health');

  Future<List<Order>> listOrders({String? status}) async {
    final json = await _get('/orders', query: status == null ? null : {'status': status});
    return (json['orders'] as List).map((o) => Order.fromJson(o as Map<String, dynamic>)).toList();
  }

  Future<Order> order(String orderId) async => Order.fromJson(await _get('/orders/$orderId'));

  /// Who this PIN belongs to; 401 for a wrong PIN, 423 while the device is locked out.
  Future<Map<String, dynamic>> signIn({required String device, String? pin, String? tagUid}) =>
      _post('/signin', {'device': device, 'pin': ?pin, 'tag_uid': ?tagUid});

  /// Stores an event photo; sending the same photo twice is harmless.
  Future<Map<String, dynamic>> putPhoto(Map<String, dynamic> photo) => _post('/events/photos', photo);

  /// Appends operations; returns the op ids the backend had not seen before.
  Future<List<String>> appendOps(String orderId, List<Map<String, dynamic>> ops) async {
    final json = await _post('/orders/$orderId/ops', ops);
    return List<String>.from(json['accepted'] as List);
  }

  Future<Map<String, dynamic>> _get(String path, {Map<String, String>? query}) =>
      _withFailover((base) => _client.get(Uri.parse('$base$path').replace(queryParameters: query)));

  Future<Map<String, dynamic>> _post(String path, Object body) => _withFailover(
    (base) => _client.post(
      Uri.parse('$base$path'),
      headers: const {'content-type': 'application/json'},
      body: jsonEncode(body),
    ),
  );

  List<String> _candidates() {
    final configured = settings.endpoints;
    final current = connection.value.endpoint;
    if (current == null || !configured.contains(current)) return configured;
    return [current, ...configured.where((e) => e != current)];
  }

  Future<Map<String, dynamic>> _withFailover(Future<http.Response> Function(String base) send) async {
    Object? lastError;
    for (final base in _candidates()) {
      try {
        final response = await send(base).timeout(timeout);
        if (response.statusCode >= 500) {
          lastError = ApiException('server error at $base', status: response.statusCode);
          continue;
        }
        if (connection.value.endpoint != base) connection.value = Connection(endpoint: base);
        final decoded = response.body.isEmpty ? <String, dynamic>{} : jsonDecode(response.body);
        if (response.statusCode >= 400) {
          throw ApiException(_detail(decoded), status: response.statusCode);
        }
        return decoded as Map<String, dynamic>;
      } on ApiException {
        rethrow;
      } catch (err) {
        lastError = err;
      }
    }
    final message = settings.endpoints.isEmpty ? 'no backend address configured' : 'no backend answers: $lastError';
    connection.value = Connection(error: message);
    throw ApiException(message);
  }

  static String _detail(Object? decoded) {
    if (decoded is Map && decoded['detail'] != null) {
      final detail = decoded['detail'];
      if (detail is Map && detail['error'] != null) return detail['error'].toString();
      return detail.toString();
    }
    return 'refused';
  }

  void dispose() {
    _client.close();
    connection.dispose();
  }
}
