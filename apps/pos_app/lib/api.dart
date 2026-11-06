import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'cache.dart';
import 'coursing.dart';
import 'desk_phone.dart';
import 'floor.dart';
import 'menu.dart';
import 'phone.dart';
import 'pricing.dart';
import 'settings.dart';
import 'takeout.dart';

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
    this.rank = 0,
    this.modifiedAfterFire = false,
    this.fired = false,
    this.request,
    this.itemId,
    this.entryId,
    this.replaces,
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
    rank: (json['rank'] as num?)?.toDouble() ?? 0,
    modifiedAfterFire: json['modified_after_fire'] as bool? ?? false,
    fired: json['fired'] as bool? ?? false,
    request: json['request'] == null ? null : LineRequest.fromJson(json['request'] as Map<String, dynamic>),
    itemId: (json['priced'] as Map?)?['item'] as String?,
    entryId: (json['priced'] as Map?)?['entry_id'] as String?,
    replaces: json['replaces'] as String?,
  );

  final String lineId;
  final String item;
  final int qty;
  final String status;
  final int? seat;
  final String? course;
  final String note;

  /// Its place on the check: lines show, print and are charged in rank order (the order they were added,
  /// until a drag on the check moves one).
  final double rank;
  final bool modifiedAfterFire;

  /// Sent to the kitchen. Until then a line can simply come off; after, taking it off is a void.
  final bool fired;

  /// What was chosen, so the options sheet can reopen with it; null on a phase 0 typed line.
  final LineRequest? request;
  final String? itemId;
  final String? entryId;

  /// The line this one took the place of: an edit (other choices, a kitchen note) voids a line and adds the
  /// changed dish as a new one. A comp on the old line is on this one, here and on the hub.
  final String? replaces;

  bool get isActive => status == 'active';
  bool get isVoid => status == 'void';

  /// Taken off before it was fired: gone from the screen, kept only in the log.
  bool get isRemoved => status == 'removed';
  bool get canEdit => isActive && request != null && itemId != null;

  /// Shown from this device's own operations; the backend has not confirmed it yet.
  final bool pending;

  /// The same line with some fields changed; [clearCourse] takes the course off.
  Line copyWith({
    String? status,
    bool? fired,
    bool? pending,
    int? qty,
    String? note,
    int? seat,
    String? course,
    bool clearCourse = false,
    double? rank,
  }) => Line(
    lineId: lineId,
    item: item,
    qty: qty ?? this.qty,
    status: status ?? this.status,
    seat: seat ?? this.seat,
    course: clearCourse ? null : course ?? this.course,
    note: note ?? this.note,
    rank: rank ?? this.rank,
    modifiedAfterFire: modifiedAfterFire,
    fired: fired ?? this.fired,
    request: request,
    itemId: itemId,
    entryId: entryId,
    replaces: replaces,
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
    this.payments = const [],
  });

  /// A check the backend has not heard of yet (its create is still on the way).
  const Order.empty(this.orderId)
    : status = 'open',
      fields = const {},
      lines = const [],
      fired = const {},
      payments = const [];

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
      payments: (json['payments'] as Map<String, dynamic>? ?? const {}).entries
          .map((e) => Payment.fromJson(e.key, e.value as Map<String, dynamic>))
          .toList(),
    );
  }

  final String orderId;
  final String status;
  final Map<String, dynamic> fields;
  final List<Line> lines;
  final Map<String, String> fired;
  final List<Payment> payments;

  String get table => fields['table']?.toString() ?? '';

  // Counter mode and takeout (architecture section 12): numbered by the hub, named by the operator.
  bool get isTakeout => table.isEmpty;
  int? get orderNo => fields['order_no'] as int?;
  String get customerName => fields['customer_name']?.toString() ?? '';
  String get phone => fields['phone']?.toString() ?? '';
  String get channel => fields['channel']?.toString() ?? '';
  String get stage => fields['stage']?.toString() ?? 'new';
  int? get promisedAt => fields['promised_at'] as int?;
  bool get hasPaid => payments.isNotEmpty;
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

  /// The line that stands for [lineId] now: itself while it is active, else the line that replaced it (an
  /// edit voids a line and adds the changed dish as a new one), followed through further edits. A comp on
  /// a line is shown and estimated on this one, as the hub does.
  String currentLine(String lineId) {
    final replacedBy = <String, String>{};
    for (final line in lines) {
      final old = line.replaces;
      if (old != null && (!replacedBy.containsKey(old) || line.isActive)) replacedBy[old] = line.lineId;
    }
    final seen = <String>{};
    while (replacedBy.containsKey(lineId) && seen.add(lineId)) {
      if (lines.any((l) => l.lineId == lineId && l.isActive)) break;
      lineId = replacedBy[lineId]!;
    }
    return lineId;
  }
}

/// Money taken on an order: cash at the counter, or settled elsewhere (a phone order paid through another
/// system). `pending` until the hub has it.
class Payment {
  const Payment({
    required this.paymentId,
    required this.method,
    required this.amount,
    this.tendered,
    this.note = '',
    this.by = '',
    this.pending = false,
  });

  factory Payment.fromJson(String paymentId, Map<String, dynamic> json) => Payment(
    paymentId: paymentId,
    method: json['method'] as String? ?? 'cash',
    amount: json['amount']?.toString() ?? '0',
    tendered: json['tendered']?.toString(),
    note: json['note'] as String? ?? '',
    by: json['by'] as String? ?? '',
  );

  final String paymentId;
  final String method; // cash | elsewhere | card
  final String amount;
  final String? tendered;
  final String note;
  final String by;
  final bool pending;
}

class AppendResult {
  const AppendResult({required this.accepted, this.refused = const {}});
  final List<String> accepted;
  final Map<String, String> refused; // op id -> why
}

/// How a screen stands with its backends: green on the usual one, amber on a backup, red when nothing
/// answers. Red splits in two: capturing only (ADR 6: a menu is saved here, so orders can still be taken and
/// queued) and lost (no menu saved: nothing can be done until a backend answers).
enum ConnectionLevel { usual, backup, capturing, lost }

/// What the status icon shows: which address answers, whether it is the usual one, or none, and since when.
class Connection {
  const Connection({this.endpoint, this.error, this.capturing = false, this.since});
  final String? endpoint;
  final String? error;

  /// No backend answers, but the menu saved on this device still lets it take orders (ADR 6).
  final bool capturing;

  /// When this state began.
  final DateTime? since;

  bool get isOnline => endpoint != null;

  /// Which backend answers: `usual` is the first on the list, anything else is a backup.
  ConnectionLevel levelWith(List<String> endpoints) {
    if (endpoint == null) return capturing ? ConnectionLevel.capturing : ConnectionLevel.lost;
    return endpoint == endpoints.firstOrNull ? ConnectionLevel.usual : ConnectionLevel.backup;
  }

  Connection _since(DateTime? at) => Connection(endpoint: endpoint, error: error, capturing: capturing, since: at);
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
/// reaches a backend but is refused (4xx) is not retried elsewhere: the answer would be the same. With a
/// [ReadCache], the reads a screen needs to take an order (menu, dishes, floor, tax rates) are saved as they
/// come and served from disk when nothing answers at all (ADR 6).
class PosApi {
  PosApi(this.settings, {http.Client? client, this.timeout = const Duration(seconds: 2), this.cache})
    : _client = client ?? http.Client();

  final Settings settings;
  final http.Client _client;
  final Duration timeout;
  final ReadCache? cache;
  final ValueNotifier<Connection> connection = ValueNotifier(const Connection());

  Future<Map<String, dynamic>> health() => _get('/health');

  Future<List<Order>> listOrders({String? status}) async {
    final json = await _get('/orders', query: status == null ? null : {'status': status});
    return (json['orders'] as List).map((o) => Order.fromJson(o as Map<String, dynamic>)).toList();
  }

  Future<Order> order(String orderId) async => Order.fromJson(await _get('/orders/$orderId'));

  /// The order this number opened last today, as the hub finds it (the digits match, the location's day,
  /// a voided order does not count), or null when the number opened none today.
  Future<Order?> lastOrder({required String phone}) async {
    final json = await _get('/orders/last', query: {'phone': phone});
    final order = json['order'];
    return order == null ? null : Order.fromJson(order as Map<String, dynamic>);
  }

  /// The floor plan with every table's open checks; the last one read when nothing answers.
  Future<FloorPlan> floor() async => FloorPlan.fromJson(await _remembered('floor', '/floor'));

  /// 86 a size or option (`sold_out`), or bring it back (`available`).
  Future<void> set86(String targetId, {required bool soldOut, String? by}) =>
      _post('/menu/86', {'target_id': targetId, 'status': soldOut ? 'sold_out' : 'available', 'by': ?by});

  /// What the table owes. The tax rates on every answer are kept for [savedTaxes].
  Future<Check> check(String orderId) async {
    final json = await _get('/orders/$orderId/check');
    await cache?.put('taxes', {
      'tax_lines': [
        for (final t in json['tax_lines'] as List? ?? const []) {...t as Map<String, dynamic>, 'amount': '0.00'},
      ],
      'tax_rate_pct': json['tax_rate_pct'] ?? '',
    });
    return Check.fromJson(json);
  }

  /// Minutes each channel promises a takeout order, and which channels may pay at pickup.
  Future<Quotes> quotes() async => Quotes.fromJson(await _get('/settings/quotes'));

  /// Whether dishes are coursed, the courses by name and where a new dish goes; the last answer read when
  /// nothing answers, so a check can still be coursed the usual way (ADR 6).
  Future<Coursing> coursing() async => Coursing.fromJson(await _remembered('coursing', '/settings/coursing'));

  /// A manager (token from [adminSession]) sets the coursing for every terminal. A course without an id is
  /// new; the answer carries the id the hub gave it.
  Future<Coursing> saveCoursing(String token, Coursing coursing) async => Coursing.fromJson(
    await _withFailover(
      (base) => _client.put(
        Uri.parse('$base/settings/coursing'),
        headers: {'content-type': 'application/json', ..._bearer(token)},
        body: jsonEncode(coursing.toJson()),
      ),
    ),
  );

  /// A manager (token from [adminSession]) sets the quote times for every terminal.
  Future<Quotes> saveQuotes(String token, Quotes quotes) async => Quotes.fromJson(
    await _withFailover(
      (base) => _client.put(
        Uri.parse('$base/settings/quotes'),
        headers: {'content-type': 'application/json', ..._bearer(token)},
        body: jsonEncode(quotes.toJson()),
      ),
    ),
  );

  /// Which screen each desk phone is linked to, as the hub keeps it.
  Future<DeskPhoneLinks> deskPhones() async => DeskPhoneLinks.fromJson(await _get('/settings/desk_phones'));

  /// A manager (token from [adminSession]) links the desk phones to screens for the whole location.
  Future<DeskPhoneLinks> saveDeskPhones(String token, DeskPhoneLinks links) async => DeskPhoneLinks.fromJson(
    await _withFailover(
      (base) => _client.put(
        Uri.parse('$base/settings/desk_phones'),
        headers: {'content-type': 'application/json', ..._bearer(token)},
        body: jsonEncode(links.toJson()),
      ),
    ),
  );

  /// The calls answered in the last two minutes on the desk phones linked to [device], each with when it was
  /// picked up on [clock], whether any phone is linked to the device at all, and the hub's cursor. With
  /// [hold], the hub keeps the request until a call newer than [after] (the last cursor) is there, or that
  /// long: a pick-up comes back the moment it happens.
  Future<AnsweredCalls> answeredCalls({
    required String device,
    int after = 0,
    Duration hold = Duration.zero,
    DateTime Function() clock = DateTime.now,
  }) async {
    final json = await _get(
      '/phones/answered',
      query: {'device': device, 'after': '$after', if (hold > Duration.zero) 'wait': '${hold.inSeconds}'},
      timeout: hold > Duration.zero ? hold + const Duration(seconds: 5) : null,
    );
    final now = clock();
    return AnsweredCalls(
      linked: json['linked'] as bool? ?? false,
      calls: [
        for (final call in json['calls'] as List? ?? const [])
          DeskPhoneCall.fromJson(call as Map<String, dynamic>, now: now),
      ],
      cursor: (json['cursor'] as num?)?.toInt() ?? 0,
    );
  }

  /// How the hub stands with the PBX: whether a PBX is configured and reached, and what it has seen.
  Future<Map<String, dynamic>> pbxStatus() => _get('/phones/status');

  /// Where a call stands on the hub, by the id a push carried: ringing, answered (and where), ended, unknown.
  Future<CallOnHub> callState(String callId) async => CallOnHub.fromJson(await _get('/phones/calls/$callId'));

  /// Registers one of this screen's push tokens with the hub: `voip` (iOS, for calls, with the extension the
  /// phone registers as) or `alert` (for a desk-phone pick-up). The answer says whether the hub has a key to
  /// push with (`configured`).
  Future<Map<String, dynamic>> registerPush({
    required String device,
    required String platform,
    required String kind,
    required String token,
    String extension = '',
  }) => _put('/push/devices', {
    'device': device,
    'platform': platform,
    'kind': kind,
    'token': token,
    'extension': extension,
  });

  /// No more pushes to this token (the phone was switched off here).
  Future<void> unregisterPush(String token) => _delete('/push/devices/$token');

  /// The hub's push relay: its key, the tokens registered, the extensions marked on the PBX, what went out.
  Future<Map<String, dynamic>> pushStatus() => _get('/push/status');

  /// A notification to this screen by hand, to see that the hub reaches it.
  Future<Map<String, dynamic>> testPush(String device) => _post('/push/test', {'device': device});

  /// The PBX's extensions as the hub sees them, lowest first, each with whether a phone is on it; empty while
  /// the hub is not watching a PBX. A manager picks a desk phone from them.
  Future<List<PbxExtension>> extensions() async {
    final json = await _get('/phones/extensions');
    return [
      for (final ext in json['extensions'] as List? ?? const [])
        if (PbxExtension.fromJson(ext as Map<String, dynamic>) case final found when found.extension.isNotEmpty) found,
    ];
  }

  /// The device names of the screens the hub has heard from, by name. A manager picks a desk phone's screen
  /// from them.
  Future<List<String>> devicesSeen() async {
    final json = await _get('/devices');
    return [
      for (final seen in json['devices'] as List? ?? const [])
        if ((seen as Map<String, dynamic>)['device'] case final String name when name.isNotEmpty) name,
    ];
  }

  /// The discount reasons and service charges this location allows, with who may apply them.
  Future<PricingRules> pricingRules() async => PricingRules.fromJson(await _get('/pricing/rules'));

  /// A manager's PIN for a discount or a charge on one order: the answer's `approval` goes on the operation.
  /// 401 is a wrong PIN, 403 not a manager, 423 locked after too many tries.
  Future<Map<String, dynamic>> approve({required String device, required String pin, required String orderId}) =>
      _post('/approvals', {'device': device, 'pin': pin, 'order_id': orderId});

  /// The tax rates from the last check any backend priced, as an empty estimated check: what a screen with
  /// no backend works a new check's tax from. Null until a check has been read on this device.
  Check? get savedTaxes {
    final json = cache?.get('taxes');
    if (json == null) return null;
    return Check(
      lines: const [],
      subtotal: '0.00',
      taxLines: (json['tax_lines'] as List? ?? const [])
          .map((t) => TaxLine.fromJson(t as Map<String, dynamic>))
          .toList(),
      tax: '0.00',
      taxRatePct: json['tax_rate_pct'] as String? ?? '',
      total: '0.00',
      estimated: true,
    );
  }

  /// The menus open now on this channel, in the given language, and the revision they were read at; the
  /// last ones read when nothing answers.
  Future<(int, List<Menu>)> menus({String channel = 'pos', String locale = 'en'}) async {
    final json = await _remembered('menu:$channel:$locale', '/menu', query: {'channel': channel, 'locale': locale});
    final menus = (json['menus'] as List).map((m) => Menu.fromJson(m as Map<String, dynamic>)).toList();
    return (json['revision'] as int? ?? 0, menus);
  }

  /// Moves whenever a manager saves the menu: a screen showing the menu reloads when it does.
  Future<int> menuRevision() async => (await _get('/menu/revision'))['revision'] as int? ?? 0;

  /// A dish's sizes and choices; the saved ones when nothing answers (any size of the dish, if this entry
  /// was never read: the backend prices the line for real once it is back).
  Future<ItemDetail> item(String itemId, {String? entryId, String locale = 'en'}) async {
    final name = _itemName(itemId, entryId, locale);
    try {
      return ItemDetail.fromJson(
        await _remembered(name, '/menu/items/$itemId', query: {'entry': ?entryId, 'locale': locale}),
      );
    } on ApiException catch (err) {
      if (err.status != null || cache == null) rethrow;
      final any = cache!.names('item:$itemId|').firstOrNull;
      if (any == null) rethrow;
      return ItemDetail.fromJson(cache!.get(any)!);
    }
  }

  /// Saves every dish's sizes and choices with the menu, in one read, so a dish can still be configured
  /// when no backend answers. Returns how many were saved; nothing without a cache.
  Future<int> prefetchItems({String channel = 'pos', String locale = 'en'}) async {
    if (cache == null) return 0;
    final json = await _get(
      '/menu/items',
      query: {'channel': channel, 'locale': locale},
      timeout: const Duration(seconds: 15),
    );
    final items = (json['items'] as List).cast<Map<String, dynamic>>();
    await cache!.putAll({for (final d in items) _itemName(d['item'] as String, d['entry_id'] as String?, locale): d});
    return items.length;
  }

  static String _itemName(String itemId, String? entryId, String locale) => 'item:$itemId|${entryId ?? ''}:$locale';

  /// A read served from the cache when no backend answers. A backend that answers and refuses is not
  /// papered over: the saved answer would be wrong.
  Future<Map<String, dynamic>> _remembered(String name, String path, {Map<String, String>? query}) async {
    try {
      final json = await _get(path, query: query);
      await cache?.put(name, json);
      return json;
    } on ApiException catch (err) {
      if (err.status != null) rethrow;
      final saved = cache?.get(name);
      if (saved == null) rethrow;
      return saved;
    }
  }

  /// The backend's price for a configured line, before it is added.
  Future<Priced> price(LineRequest request) async => Priced.fromJson(await _post('/menu/price', request.toJson()));

  /// Who this PIN belongs to; 401 for a wrong PIN, 423 while the device is locked out.
  Future<Map<String, dynamic>> signIn({required String device, String? pin, String? tagUid}) =>
      _post('/signin', {'device': device, 'pin': ?pin, 'tag_uid': ?tagUid});

  /// Stores an event photo; sending the same photo twice is harmless.
  Future<Map<String, dynamic>> putPhoto(Map<String, dynamic> photo) => _post('/events/photos', photo);

  /// Saves what a staff member set for themselves (text size, contrast, language), for every device.
  Future<Map<String, dynamic>> putPreferences(String staffId, Map<String, dynamic> prefs) =>
      _put('/staff/$staffId/preferences', prefs);

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

  Future<Map<String, dynamic>> _put(String path, Object body) => _withFailover(
    (base) =>
        _client.put(Uri.parse('$base$path'), headers: {'content-type': 'application/json'}, body: jsonEncode(body)),
  );

  Future<Map<String, dynamic>> _delete(String path) => _withFailover((base) => _client.delete(Uri.parse('$base$path')));

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
        if (connection.value.endpoint != base) _become(Connection(endpoint: base));
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
    _become(Connection(error: message, capturing: cache?.hasMenu ?? false));
    throw ApiException(message);
  }

  /// Moves to `next`, keeping `since` while the state is the same one (another failed poll, say).
  void _become(Connection next) {
    final was = connection.value;
    final endpoints = settings.endpoints;
    final same = was.endpoint == next.endpoint && was.levelWith(endpoints) == next.levelWith(endpoints);
    connection.value = next._since(same ? was.since : DateTime.now());
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
