import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'floor.dart';
import 'menu.dart';
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
    this.fired = false,
    this.request,
    this.itemId,
    this.entryId,
    this.pending = false,
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
    fired: json['fired'] as bool? ?? false,
    request: json['request'] == null ? null : LineRequest.fromJson(json['request'] as Map<String, dynamic>),
    itemId: (json['priced'] as Map?)?['item'] as String?,
    entryId: (json['priced'] as Map?)?['entry_id'] as String?,
  );

  final String lineId;
  final String item;
  final int qty;
  final String status;
  final int? seat;
  final String? course;
  final String note;
  final bool modifiedAfterFire;

  /// Sent to the kitchen. Until then a line can simply come off; after, taking it off is a void.
  final bool fired;

  /// What was chosen, so the options sheet can reopen with it; null on a phase 0 typed line.
  final LineRequest? request;
  final String? itemId;
  final String? entryId;

  bool get isActive => status == 'active';
  bool get isVoid => status == 'void';

  /// Taken off before it was fired: gone from the screen, kept only in the log.
  bool get isRemoved => status == 'removed';
  bool get canEdit => isActive && request != null && itemId != null;

  /// Shown from this device's own operations; the backend has not confirmed it yet.
  final bool pending;

  Line copyWith({String? status, bool? fired, bool? pending, int? qty, String? note}) => Line(
    lineId: lineId,
    item: item,
    qty: qty ?? this.qty,
    status: status ?? this.status,
    seat: seat,
    course: course,
    note: note ?? this.note,
    modifiedAfterFire: modifiedAfterFire,
    fired: fired ?? this.fired,
    request: request,
    itemId: itemId,
    entryId: entryId,
    pending: pending ?? this.pending,
  );
}

/// An order as the backend replays it. A screen only lays its own unconfirmed operations over it
/// (see local_order.dart) so taps show at once; the backend's replay stays the authority.
class Order {
  const Order({
    required this.orderId,
    required this.status,
    required this.fields,
    required this.lines,
    required this.fired,
  });

  /// A check the backend has not heard of yet (its create is still on the way).
  const Order.empty(this.orderId) : status = 'open', fields = const {}, lines = const [], fired = const {};

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
  List<Line> get activeLines => lines.where((l) => l.isActive).toList();

  /// What the check panel lists: active lines and voids, not lines removed before they were fired.
  List<Line> get shownLines => lines.where((l) => !l.isRemoved).toList();

  /// Courses with a line not sent yet.
  Set<String> get heldCourses => {
    for (final l in activeLines)
      if (!l.fired) l.course ?? '',
  };
}

class AppendResult {
  const AppendResult({required this.accepted, this.refused = const {}});
  final List<String> accepted;
  final Map<String, String> refused; // op id -> why
}

/// What the status bar shows: which address answers, or none.
class Connection {
  const Connection({this.endpoint, this.error});
  final String? endpoint;
  final String? error;
  bool get isOnline => endpoint != null;
}

class ApiException implements Exception {
  ApiException(this.message, {this.status, this.detail});
  final String message;
  final int? status;

  /// The backend's `detail` object, when it sent one: the menu editor lists its `errors`.
  final Map<String, dynamic>? detail;
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

  /// The floor plan with every table's open checks.
  Future<FloorPlan> floor() async => FloorPlan.fromJson(await _get('/floor'));

  /// 86 a size or option (`sold_out`), or bring it back (`available`).
  Future<void> set86(String targetId, {required bool soldOut, String? by}) =>
      _post('/menu/86', {'target_id': targetId, 'status': soldOut ? 'sold_out' : 'available', 'by': ?by});

  Future<Check> check(String orderId) async => Check.fromJson(await _get('/orders/$orderId/check'));

  /// The menus open now on this channel, in the given language, and the revision they were read at.
  Future<(int, List<Menu>)> menus({String channel = 'pos', String locale = 'en'}) async {
    final json = await _get('/menu', query: {'channel': channel, 'locale': locale});
    final menus = (json['menus'] as List).map((m) => Menu.fromJson(m as Map<String, dynamic>)).toList();
    return (json['revision'] as int? ?? 0, menus);
  }

  /// Moves whenever a manager saves the menu: a screen showing the menu reloads when it does.
  Future<int> menuRevision() async => (await _get('/menu/revision'))['revision'] as int? ?? 0;

  Future<ItemDetail> item(String itemId, {String? entryId, String locale = 'en'}) async =>
      ItemDetail.fromJson(await _get('/menu/items/$itemId', query: {'entry': ?entryId, 'locale': locale}));

  /// The backend's price for a configured line, before it is added.
  Future<Priced> price(LineRequest request) async => Priced.fromJson(await _post('/menu/price', request.toJson()));

  /// Who this PIN belongs to; 401 for a wrong PIN, 423 while the device is locked out.
  Future<Map<String, dynamic>> signIn({required String device, String? pin, String? tagUid}) =>
      _post('/signin', {'device': device, 'pin': ?pin, 'tag_uid': ?tagUid});

  /// Stores an event photo; sending the same photo twice is harmless.
  Future<Map<String, dynamic>> putPhoto(Map<String, dynamic> photo) => _post('/events/photos', photo);

  /// Appends operations; returns the op ids the backend had not seen before and the ones it refused
  /// (a line the menu would not sell), each with the reason.
  Future<AppendResult> appendOps(String orderId, List<Map<String, dynamic>> ops) async {
    final json = await _post('/orders/$orderId/ops', ops);
    return AppendResult(
      accepted: List<String>.from(json['accepted'] as List),
      refused: {
        for (final r in json['refused'] as List? ?? const [])
          (r as Map<String, dynamic>)['op_id'] as String: [
            for (final p in r['problems'] as List? ?? const []) (p as Map<String, dynamic>)['message'] as String? ?? '',
          ].join('; '),
      },
    );
  }

  /// The printers the backend knows: name, address, dialect.
  Future<List<Map<String, dynamic>>> printers() async =>
      ((await _get('/print/printers'))['printers'] as List).cast<Map<String, dynamic>>();

  /// One queued print job for a printer in `printers`, with its bytes, or null when there is none.
  Future<Map<String, dynamic>?> claimPrintJob({required String relay, required List<String> printers}) async =>
      (await _post('/print/jobs/claim', {'relay': relay, 'printers': printers}))['job'] as Map<String, dynamic>?;

  Future<void> printJobDone(String jobId, {required String by}) => _post('/print/jobs/$jobId/done', {'by': by});

  Future<void> printJobFailed(String jobId, {required String by, required String error}) =>
      _post('/print/jobs/$jobId/failed', {'by': by, 'error': error});

  Future<Map<String, dynamic>> testPrint(String printer) => _post('/print/test', {'printer': printer});

  // Menu editor: a manager's PIN buys a token for an hour; every other call carries it. -----------------

  /// A token for the menu editor; 403 when the PIN is not a manager's.
  Future<Map<String, dynamic>> adminSession({required String device, required String pin}) =>
      _post('/admin/session', {'device': device, 'pin': pin});

  /// The whole menu by kind, its revision, and what the backend's checks find.
  Future<Map<String, dynamic>> adminMenu(String token) =>
      _get('/admin/menu', headers: _bearer(token), timeout: const Duration(seconds: 15));

  /// Saves changes made from `revision`; 409 when someone saved since, 422 with `errors` when the menu
  /// would break. `dryRun` only checks.
  Future<Map<String, dynamic>> saveMenu(
    String token,
    List<Map<String, dynamic>> changes, {
    required int revision,
    bool dryRun = false,
  }) => _post(
    '/admin/menu/changes',
    {'changes': changes, 'revision': revision, 'dry_run': dryRun},
    headers: _bearer(token),
    timeout: const Duration(seconds: 15),
  );

  /// Who changed what, newest first.
  Future<List<Map<String, dynamic>>> menuAudit(String token, {int limit = 100}) async =>
      ((await _get('/admin/menu/audit', query: {'limit': '$limit'}, headers: _bearer(token)))['changes'] as List)
          .cast<Map<String, dynamic>>();

  static Map<String, String> _bearer(String token) => {'authorization': 'Bearer $token'};

  Future<Map<String, dynamic>> _get(
    String path, {
    Map<String, String>? query,
    Map<String, String>? headers,
    Duration? timeout,
  }) => _withFailover(
    (base) => _client.get(Uri.parse('$base$path').replace(queryParameters: query), headers: headers),
    timeout: timeout,
  );

  Future<Map<String, dynamic>> _post(String path, Object body, {Map<String, String>? headers, Duration? timeout}) =>
      _withFailover(
        (base) => _client.post(
          Uri.parse('$base$path'),
          headers: {'content-type': 'application/json', ...?headers},
          body: jsonEncode(body),
        ),
        timeout: timeout,
      );

  List<String> _candidates() {
    final configured = settings.endpoints;
    final current = connection.value.endpoint;
    if (current == null || !configured.contains(current)) return configured;
    return [current, ...configured.where((e) => e != current)];
  }

  Future<Map<String, dynamic>> _withFailover(
    Future<http.Response> Function(String base) send, {
    Duration? timeout,
  }) async {
    Object? lastError;
    for (final base in _candidates()) {
      try {
        final response = await send(base).timeout(timeout ?? this.timeout);
        if (response.statusCode >= 500) {
          lastError = ApiException('server error at $base', status: response.statusCode);
          continue;
        }
        if (connection.value.endpoint != base) connection.value = Connection(endpoint: base);
        final decoded = response.body.isEmpty ? <String, dynamic>{} : jsonDecode(response.body);
        if (response.statusCode >= 400) {
          final detail = decoded is Map ? decoded['detail'] : null;
          throw ApiException(
            _detail(decoded),
            status: response.statusCode,
            detail: detail is Map ? detail.cast<String, dynamic>() : null,
          );
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
