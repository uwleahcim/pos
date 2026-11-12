import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'cache.dart';
import 'coursing.dart';
import 'desk_phone.dart';
import 'faces.dart';
import 'floor.dart';
import 'menu.dart';
import 'phone.dart';
import 'pricing.dart';
import 'printers.dart';
import 'settings.dart';
import 'takeout.dart';

/// Worker: the `/menu/items` answer split into one JSON text per dish, under the name [PosApi.item] reads
/// it back by, with the menu revision the answer carries. Decoding ten megabytes and encoding each dish
/// again takes long enough to be felt, so it runs off the UI thread (`compute`).
(int, Map<String, String>) splitItems((String, String) bodyAndLocale) {
  final (body, locale) = bodyAndLocale;
  final json = jsonDecode(body) as Map<String, dynamic>;
  final items = (json['items'] as List).cast<Map<String, dynamic>>();
  return (
    json['revision'] as int? ?? 0,
    {for (final d in items) PosApi._itemName(d['item'] as String, d['entry_id'] as String?, locale): jsonEncode(d)},
  );
}

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
    this.by = '',
    this.byId,
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
    by: json['by'] as String? ?? '',
    byId: json['by_id'] as String?,
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

  /// Who added the line, by name and by staff id, when the screen that added it knew: with hands-free switching
  /// a check one server opened is added to by another, and each dish says whose it is.
  final String by;
  final String? byId;

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
    by: by,
    byId: byId,
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
///
/// The reads a screen repeats (the open orders, the floor, the open check, the menu) say which answer they
/// already have, and a backend with nothing new says so in a few bytes: the call then returns the very same
/// object as last time, so a screen can tell with [identical] that there is nothing to redraw.
class PosApi {
  PosApi(this.settings, {http.Client? client, this.timeout = const Duration(seconds: 2), this.cache})
    : _client = client ?? http.Client();

  final Settings settings;
  final http.Client _client;
  final Duration timeout;
  final ReadCache? cache;
  final ValueNotifier<Connection> connection = ValueNotifier(const Connection());

  Future<Map<String, dynamic>> health() => _get('/health');

  /// The orders for a list, newest activity first: those at [status], or all of them. With [within], only
  /// the ones that changed that recently and the ones still open, so a list of every order is a day long,
  /// not the restaurant's whole history. Each line comes without its choices and price (`brief`): a list
  /// shows neither, and they are nine tenths of the answer; [order] reads one order whole.
  Future<List<Order>> listOrders({String? status, Duration? within}) => _repeated(
    '/orders',
    query: {'status': ?status, if (within != null) 'hours': (within.inMinutes / 60).toString(), 'brief': 'true'},
    (json) => (json['orders'] as List).map((o) => Order.fromJson(o as Map<String, dynamic>)).toList(),
  );

  Future<Order> order(String orderId) => _repeated('/orders/$orderId', Order.fromJson);

  /// The order this number opened last today, as the hub finds it (the digits match, the location's day,
  /// a voided order does not count), or null when the number opened none today.
  Future<Order?> lastOrder({required String phone}) async {
    final json = await _get('/orders/last', query: {'phone': phone});
    final order = json['order'];
    return order == null ? null : Order.fromJson(order as Map<String, dynamic>);
  }

  /// The floor plan with every table's open checks; the last one read when nothing answers.
  Future<FloorPlan> floor() => _repeated('/floor', FloorPlan.fromJson, remember: 'floor');

  /// 86 a size or option (`sold_out`), or bring it back (`available`).
  Future<void> set86(String targetId, {required bool soldOut, String? by}) =>
      _post('/menu/86', {'target_id': targetId, 'status': soldOut ? 'sold_out' : 'available', 'by': ?by});

  /// What the table owes. The tax rates on every new answer are kept for [savedTaxes].
  Future<Check> check(String orderId) => _repeated(
    '/orders/$orderId/check',
    Check.fromJson,
    fresh: (json) async => cache?.put('taxes', {
      'tax_lines': [
        for (final t in json['tax_lines'] as List? ?? const []) {...t as Map<String, dynamic>, 'amount': '0.00'},
      ],
      'tax_rate_pct': json['tax_rate_pct'] ?? '',
    }),
  );

  /// Minutes each channel promises a takeout order, and which channels may pay at pickup.
  Future<Quotes> quotes() async => Quotes.fromJson(await _get('/settings/quotes'));

  /// Whether dishes are coursed, the courses by name and where a new dish goes; the last answer read when
  /// nothing answers, so a check can still be coursed the usual way (ADR 6).
  Future<Coursing> coursing() => _repeated('/settings/coursing', Coursing.fromJson, remember: 'coursing');

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

  /// The kitchen printers as the hub keeps them, with where they came from (the setting, or the hub's
  /// POS_PRINTERS until a manager saves).
  Future<PrinterSettings> printerSettings() async => PrinterSettings.fromJson(await _get('/settings/printers'));

  /// A manager (token from [adminSession]) sets the printers for the whole location. A printer without an id
  /// is new and gets one from the hub; the rest keep theirs, since fallbacks name them.
  Future<PrinterSettings> savePrinterSettings(String token, PrinterSettings printers) async => PrinterSettings.fromJson(
    await _withFailover(
      (base) => _client.put(
        Uri.parse('$base/settings/printers'),
        headers: {'content-type': 'application/json', ..._bearer(token)},
        body: jsonEncode(printers.toJson()),
      ),
    ),
  );

  /// The stations the menu prints at, with the printer serving each and the ones that have none yet.
  Future<StationList> printStations() async => StationList.fromJson(await _get('/print/stations'));

  /// The hub looks for printers (port 9100) on the subnets of [addresses] (this terminal's own and the hub's),
  /// of its printers and of itself, and says which language each one speaks. A few seconds (manager token).
  Future<List<FoundPrinter>> discoverPrinters(String token, {List<String> addresses = const []}) async {
    final json = await _post(
      '/print/discover',
      {'addresses': addresses},
      headers: _bearer(token),
      timeout: const Duration(seconds: 40),
    );
    return [
      for (final f in json['found'] as List? ?? const []) FoundPrinter.fromJson((f as Map).cast<String, dynamic>()),
    ];
  }

  /// Whether the printer at [address] answers and which language it speaks, without printing (manager token).
  Future<FoundPrinter> identifyPrinter(String token, String address) async => FoundPrinter.fromJson(
    await _post('/print/identify', {'address': address}, headers: _bearer(token), timeout: const Duration(seconds: 15)),
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
    final json = cache?.peek('taxes');
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
  Future<(int, List<Menu>)> menus({String channel = 'pos', String locale = 'en'}) => _repeated(
    '/menu',
    query: {'channel': channel, 'locale': locale},
    remember: 'menu:$channel:$locale',
    (json) => (
      json['revision'] as int? ?? 0,
      (json['menus'] as List).map((m) => Menu.fromJson(m as Map<String, dynamic>)).toList(),
    ),
  );

  /// Moves whenever a manager saves the menu: a screen showing the menu reloads when it does.
  Future<int> menuRevision() async => (await _get('/menu/revision'))['revision'] as int? ?? 0;

  /// A dish's sizes and choices; the saved ones when nothing answers (any size of the dish, if this entry
  /// was never read: the backend prices the line for real once it is back).
  Future<ItemDetail> item(String itemId, {String? entryId, String locale = 'en'}) async {
    final name = _itemName(itemId, entryId, locale);
    try {
      return await _repeated(
        '/menu/items/$itemId',
        ItemDetail.fromJson,
        query: {'entry': ?entryId, 'locale': locale},
        remember: name,
      );
    } on ApiException catch (err) {
      if (err.status != null || cache == null) rethrow;
      final any = cache!.names('item:$itemId|').firstOrNull;
      final saved = any == null ? null : await cache!.get(any);
      if (saved == null) rethrow;
      return ItemDetail.fromJson(saved);
    }
  }

  /// Saves every dish's sizes and choices, in one read, so a dish can still be configured when no backend
  /// answers: once per menu [revision] per device, since the cache keeps the revision whose dishes it has,
  /// however many screens ask (one read at a time; a second screen asking meanwhile gets the same read).
  /// With this menu that is 559 dishes and over ten megabytes, so the answer is split and encoded off the
  /// UI thread, and nothing is downloaded at all when the dishes of this revision are already here. Returns
  /// how many were saved; nothing without a cache.
  Future<int> prefetchItems({required int revision, String channel = 'pos', String locale = 'en'}) {
    final cache = this.cache;
    if (cache == null || cache.itemsRevision(channel: channel, locale: locale) == revision) return Future.value(0);
    return _prefetching ??= _prefetchItems(cache, channel, locale).whenComplete(() => _prefetching = null);
  }

  Future<int>? _prefetching;

  Future<int> _prefetchItems(ReadCache cache, String channel, String locale) async {
    final body = await _getText(
      '/menu/items',
      query: {'channel': channel, 'locale': locale},
      timeout: const Duration(seconds: 15),
    );
    final (int, Map<String, String>) split;
    try {
      split = await compute(splitItems, (body, locale));
    } on FormatException catch (err) {
      throw ApiException('unreadable answer: $err');
    }
    final (revision, items) = split;
    await cache.saveItems(items, revision: revision, channel: channel, locale: locale);
    return items.length;
  }

  static String _itemName(String itemId, String? entryId, String locale) => 'item:$itemId|${entryId ?? ''}:$locale';

  /// The last answer of each read a screen repeats: the name the backend gave it (its `ETag`) and what it
  /// was parsed into. The most recently used [_keep] are kept (each open check is two of them).
  final _answers = <String, (String, Object)>{};
  static const _keep = 64;

  /// A read a screen repeats, parsed by [parse]. The request names the answer this device already has
  /// (`If-None-Match`); a backend with nothing newer answers 304 with no body, and the object parsed last
  /// time comes back as it is: nothing is downloaded, decoded, parsed or saved, and the caller can tell by
  /// [identical] that nothing changed. A backend that names nothing (one older than 2026-11-12) is simply
  /// read in full every time, as before.
  ///
  /// A new answer goes to [fresh] first. With [remember], it is also saved under that name in the
  /// [ReadCache], as the text it came as, and read back from there when no backend answers (a backend that
  /// answers and refuses is not papered over: the saved answer would be wrong).
  Future<T> _repeated<T extends Object>(
    String path,
    T Function(Map<String, dynamic> json) parse, {
    Map<String, String>? query,
    String? remember,
    Future<void> Function(Map<String, dynamic> json)? fresh,
  }) async {
    final key = query == null || query.isEmpty ? path : '$path?${Uri(queryParameters: query).query}';
    final had = _answers[key];
    final http.Response response;
    try {
      response = await _send(
        (base) => _client.get(
          Uri.parse('$base$path').replace(queryParameters: query),
          headers: had == null ? null : {'if-none-match': had.$1},
        ),
      );
    } on ApiException {
      final saved = remember == null ? null : await cache?.get(remember);
      if (saved == null) rethrow;
      return parse(saved);
    }
    if (response.statusCode == 304 && had != null && had.$2 is T) {
      _answers
        ..remove(key)
        ..[key] = had; // used last: the last to go
      if (remember != null) await cache?.touch(remember); // still what a backend says: the saved copy is as new
      return had.$2 as T;
    }
    if (response.statusCode >= 400) throw _refused(response);
    final Map<String, dynamic> json;
    try {
      json = jsonDecode(response.body) as Map<String, dynamic>;
    } on FormatException catch (err) {
      throw ApiException('unreadable answer: $err');
    }
    await fresh?.call(json);
    if (remember != null) await cache?.putText(remember, response.body);
    final value = parse(json);
    final etag = response.headers['etag'];
    _answers.remove(key);
    if (etag != null) {
      _answers[key] = (etag, value);
      if (_answers.length > _keep) _answers.remove(_answers.keys.first);
    }
    return value;
  }

  /// The backend's price for a configured line, before it is added.
  Future<Priced> price(LineRequest request) async => Priced.fromJson(await _post('/menu/price', request.toJson()));

  /// Who this PIN belongs to; 401 for a wrong PIN, 423 while the device is locked out.
  Future<Map<String, dynamic>> signIn({required String device, String? pin, String? tagUid}) =>
      _post('/signin', {'device': device, 'pin': ?pin, 'tag_uid': ?tagUid});

  /// Stores an event photo; sending the same photo twice is harmless.
  Future<Map<String, dynamic>> putPhoto(Map<String, dynamic> photo) => _post('/events/photos', photo);

  // Face sign-in: frames off the camera go to the hub, which knows the faces. ---------------------------

  /// Whether this location signs staff in by face, whether the hub has its models and how many are enrolled.
  Future<FaceStatus> faceStatus() async => FaceStatus.fromJson(await _get('/faces/status'));

  /// One frame off this screen's camera: whether a face is in it and, once the hub is sure of the person, who
  /// it is, in the shape a PIN sign-in answers. With [current] (who is signed in here) the hub says `same`
  /// while that person is the one at the screen and names only someone else.
  Future<FaceFrame> faceFrame({required String device, required Uint8List jpeg, String? current}) async =>
      FaceFrame.fromJson(
        await _post('/signin/face', {'device': device, 'jpeg_b64': base64Encode(jpeg), 'current': ?current}),
      );

  /// The location's hands-free switching (faces and tags alike).
  Future<HandsFree> handsFree() async => HandsFree.fromJson(await _get('/settings/presence'));

  /// A manager (token from [adminSession]) sets the hands-free switching for every terminal.
  Future<HandsFree> saveHandsFree(String token, HandsFree setting) async => HandsFree.fromJson(
    await _withFailover(
      (base) => _client.put(
        Uri.parse('$base/settings/presence'),
        headers: {'content-type': 'application/json', ..._bearer(token)},
        body: jsonEncode(setting.toJson()),
      ),
    ),
  );

  /// Makes a tag, as the reader typed it, a staff member's (manager token): the last characters of its id as
  /// the hub keeps it. 409 when it is someone else's, with their name in `detail.name`.
  Future<String> setTag(String token, String staffId, {required String tagUid, String? device}) async {
    final json = await _withFailover(
      (base) => _client.put(
        Uri.parse('$base/admin/staff/$staffId/tag'),
        headers: {'content-type': 'application/json', ..._bearer(token)},
        body: jsonEncode({'tag_uid': tagUid, 'device': ?device}),
      ),
    );
    return (json['tag'] as Map<String, dynamic>?)?['ends'] as String? ?? '';
  }

  /// Forgets a staff member's tag (manager token).
  Future<int> forgetTag(String token, String staffId) async =>
      ((await _withFailover(
                (base) => _client.delete(Uri.parse('$base/admin/staff/$staffId/tag'), headers: _bearer(token)),
              ))['removed']
              as num?)
          ?.toInt() ??
      0;

  /// Whether the location signs staff in by face (the manager's switch).
  Future<bool> faceSetting() async => (await _get('/settings/faces'))['enabled'] as bool? ?? false;

  /// A manager (token from [adminSession]) switches face sign-in on or off for every terminal.
  Future<bool> saveFaceSetting(String token, {required bool enabled}) async =>
      (await _withFailover(
            (base) => _client.put(
              Uri.parse('$base/settings/faces'),
              headers: {'content-type': 'application/json', ..._bearer(token)},
              body: jsonEncode({'enabled': enabled}),
            ),
          ))['enabled']
          as bool? ??
      false;

  /// The staff by name, each with their face enrollment (manager token).
  Future<List<StaffEntry>> adminStaff(String token) async => [
    for (final entry in (await _get('/admin/staff', headers: _bearer(token)))['staff'] as List? ?? const [])
      StaffEntry.fromJson(entry as Map<String, dynamic>),
  ];

  /// One view of a staff member for their enrollment (manager token); [replace] on the first view of a fresh
  /// enrollment drops the views kept before.
  Future<EnrollStep> enrollFace(
    String token,
    String staffId, {
    required String device,
    required Uint8List jpeg,
    bool replace = false,
  }) async => EnrollStep.fromJson(
    await _post(
      '/admin/staff/$staffId/face/samples',
      {'device': device, 'jpeg_b64': base64Encode(jpeg), 'replace': replace},
      headers: _bearer(token),
      timeout: const Duration(seconds: 10),
    ),
  );

  /// Forgets a staff member's face (manager token); they sign in by PIN until enrolled again.
  Future<int> forgetFace(String token, String staffId) async =>
      ((await _withFailover(
                (base) => _client.delete(Uri.parse('$base/admin/staff/$staffId/face'), headers: _bearer(token)),
              ))['removed']
              as num?)
          ?.toInt() ??
      0;

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

  /// A read whose body is handed over as it came, undecoded, for an answer too big to decode on the UI
  /// thread (every dish's choices at once).
  Future<String> _getText(String path, {Map<String, String>? query, Duration? timeout}) async {
    final response = await _send(
      (base) => _client.get(Uri.parse('$base$path').replace(queryParameters: query)),
      timeout: timeout,
    );
    if (response.statusCode >= 400) throw _refused(response);
    return response.body;
  }

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
    final response = await _send(send, timeout: timeout);
    if (response.statusCode >= 400) throw _refused(response);
    if (response.body.isEmpty) return <String, dynamic>{};
    try {
      return jsonDecode(response.body) as Map<String, dynamic>;
    } on FormatException catch (err) {
      throw ApiException('unreadable answer: $err');
    }
  }

  /// The answer of the first backend that answers at all (a refusal is an answer): the one that answered
  /// last first, then the others in the configured order.
  Future<http.Response> _send(Future<http.Response> Function(String base) send, {Duration? timeout}) async {
    Object? lastError;
    for (final base in _candidates()) {
      try {
        final response = await send(base).timeout(timeout ?? this.timeout);
        if (response.statusCode >= 500) {
          lastError = ApiException('server error at $base', status: response.statusCode);
          continue;
        }
        if (connection.value.endpoint != base) _become(Connection(endpoint: base));
        return response;
      } catch (err) {
        lastError = err;
      }
    }
    final message = settings.endpoints.isEmpty ? 'no backend address configured' : 'no backend answers: $lastError';
    _become(Connection(error: message, capturing: cache?.hasMenu ?? false));
    throw ApiException(message);
  }

  /// What a backend that read a request and refused it (4xx) said.
  static ApiException _refused(http.Response response) {
    Object? decoded;
    try {
      decoded = response.body.isEmpty ? null : jsonDecode(response.body);
    } on FormatException {
      decoded = null;
    }
    final detail = decoded is Map ? decoded['detail'] : null;
    return ApiException(
      _detail(decoded),
      status: response.statusCode,
      detail: detail is Map ? detail.cast<String, dynamic>() : null,
    );
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
