import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'allergies.dart';
import 'bag.dart';
import 'cache.dart';
import 'check_history.dart';
import 'contests.dart';
import 'coursing.dart';
import 'customers.dart';
import 'day_report.dart';
import 'delivery_fee.dart';
import 'dishes_report.dart';
import 'desk_phone.dart';
import 'dish_names.dart';
import 'faces.dart';
import 'floor.dart';
import 'guests_report.dart';
import 'kitchen_notes.dart';
import 'kitchen_screen.dart';
import 'kitchen_times.dart';
import 'kitchen_word.dart';
import 'live.dart';
import 'menu.dart';
import 'online_orders.dart';
import 'orders_ahead.dart';
import 'prep_list.dart';
import 'phone.dart';
import 'powers.dart';
import 'pricing.dart';
import 'printers.dart';
import 'roster.dart';
import 'runs.dart';
import 'sales_report.dart';
import 'settings.dart';
import 'shift_notes.dart';
import 'suggestions_report.dart';
import 'takeout.dart';
import 'timeclock.dart';
import 'today.dart';
import 'voids.dart';
import 'reservations.dart';
import 'waitlist.dart';
import 'waste.dart';

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
    this.sentMs,
    this.request,
    this.itemId,
    this.entryId,
    this.zhName,
    this.replaces,
    this.by = '',
    this.byId,
    this.voidReason = '',
    this.allergy = const [],
    this.checks,
    this.kitchen,
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
    sentMs: (json['sent_ms'] as num?)?.toInt(),
    request: json['request'] == null ? null : LineRequest.fromJson(json['request'] as Map<String, dynamic>),
    itemId: (json['priced'] as Map?)?['item'] as String?,
    entryId: (json['priced'] as Map?)?['entry_id'] as String?,
    zhName: chineseLineName(json['priced']),
    replaces: json['replaces'] as String?,
    by: json['by'] as String? ?? '',
    byId: json['by_id'] as String?,
    voidReason: (json['voided'] as Map?)?['reason_name'] as String? ?? '',
    allergy: [
      for (final code in json['allergy'] as List? ?? const [])
        if (code is String) code,
    ],
    checks: checkNumbers(json['checks']),
    kitchen: KitchenWord.fromJson(json['kitchen']),
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

  /// When the kitchen got it, on the clock of the screen that sent it; null until it is sent, and from a
  /// hub that does not say yet. A dish that came over from another table keeps the time it was sent there.
  final int? sentMs;

  /// What was chosen, so the options sheet can reopen with it; null on a phase 0 typed line.
  final LineRequest? request;
  final String? itemId;
  final String? entryId;

  /// What the dish is called in Chinese, for a person who reads its names that way (docs/dish-names.md);
  /// null where the menu names it in English only. [item] stays what the line is recorded as.
  final String? zhName;

  /// The line this one took the place of: an edit (other choices, a kitchen note) voids a line and adds the
  /// changed dish as a new one. A comp on the old line is on this one, here and on the hub.
  final String? replaces;

  /// Who added the line, by name and by staff id, when the screen that added it knew: with hands-free switching
  /// a check one server opened is added to by another, and each dish says whose it is.
  final String by;
  final String? byId;

  /// Why it was voided, as the location names the reason; empty for a line that is not a void, and for a
  /// void made before reasons were asked.
  final String voidReason;

  /// What the menu says this dish has in it that its seat (or the whole table) told of an allergy to, by
  /// the menu's allergen codes, as the hub works it out. Empty says only that the menu lists nothing: the
  /// kitchen is told of the allergy either way.
  final List<String> allergy;

  /// The checks of a split table this dish was put on by hand, by number (several: shared between them);
  /// null while nobody did, and the split's own rule places it (its seat's check, or the first).
  final List<int>? checks;

  /// What the kitchen has said of the dish, as the hub reads the cooks' marks: ready, gone out, or one of
  /// its stations still working on it. Null while the kitchen has said nothing, which is every dish of a
  /// kitchen that works off paper, and from a hub older than these words.
  final KitchenWord? kitchen;

  bool get isActive => status == 'active';
  bool get isVoid => status == 'void';

  /// Taken off before it was fired: gone from the screen, kept only in the log.
  bool get isRemoved => status == 'removed';
  bool get canEdit => isActive && request != null && itemId != null;

  /// Shown from this device's own operations; the backend has not confirmed it yet.
  final bool pending;

  /// The same line with some fields changed; [clearCourse] takes the course off and [clearChecks] puts the
  /// dish back where the split places it. [kitchen] is the kitchen's word as it stands now.
  Line copyWith({
    String? status,
    bool? fired,
    int? sentMs,
    bool? pending,
    int? qty,
    String? note,
    int? seat,
    String? course,
    bool clearCourse = false,
    double? rank,
    List<int>? checks,
    bool clearChecks = false,
    KitchenWord? kitchen,
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
    sentMs: sentMs ?? this.sentMs,
    request: request,
    itemId: itemId,
    entryId: entryId,
    zhName: zhName,
    replaces: replaces,
    by: by,
    byId: byId,
    voidReason: voidReason,
    allergy: allergy,
    checks: clearChecks ? null : checks ?? this.checks,
    kitchen: kitchen ?? this.kitchen,
    pending: pending ?? this.pending,
  );
}

/// The checks a dish was put on, as the hub keeps them: numbers from 1 to [maxChecks], each once, lowest
/// first; one number alone counts as a list of one. Null for anything else, and for none at all.
List<int>? checkNumbers(Object? said) {
  final numbers = <int>{
    for (final n in said is List ? said : [said])
      if (n is int && n >= 1 && n <= maxChecks) n,
  }.toList()..sort();
  return numbers.isEmpty ? null : numbers;
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
    this.allergies = const [],
    this.discounts = const [],
    this.openedMs,
    this.due,
  });

  /// A check the backend has not heard of yet (its create is still on the way).
  const Order.empty(this.orderId)
    : status = 'open',
      fields = const {},
      lines = const [],
      fired = const {},
      payments = const [],
      allergies = const [],
      discounts = const [],
      openedMs = null,
      due = null;

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
      allergies: [
        for (final told in json['allergies'] as List? ?? const [])
          if (told is Map<String, dynamic>) Allergy.fromJson(told),
      ],
      discounts: [
        for (final MapEntry(:key, :value) in (json['discounts'] as Map<String, dynamic>? ?? const {}).entries)
          if (value is Map<String, dynamic> && value['active'] != false)
            (discountId: key, lineId: value['line_id'] as String?),
      ],
      openedMs: (json['opened_ms'] as num?)?.toInt(),
      due: json['due'] as String?,
    );
  }

  /// When the check was opened (wall-clock ms), as a list of checks says it; null on a read of one order,
  /// and from a hub older than the search of the checks.
  final int? openedMs;

  /// What is still to pay on a to-go order that took money, as a list of checks says it ("45.01", or "0.00"
  /// once it is paid up): a deposit is not the whole of it. Null on an order nothing was paid on, on a
  /// table's check, on a read of one order (its check says it) and from a hub older than deposits.
  final String? due;

  final String orderId;
  final String status;
  final Map<String, dynamic> fields;
  final List<Line> lines;
  final Map<String, String> fired;
  final List<Payment> payments;

  /// The allergies told at the table: the whole table's first (its seat is null), then each seat's.
  final List<Allergy> allergies;

  /// The discounts that stand on the order: each one's id and the dish it is on (null: the whole check).
  /// What they take off is the hub's to say (the check); this is for a dish that changes checks, whose
  /// discounts go with it.
  final List<({String discountId, String? lineId})> discounts;

  String get table => fields['table']?.toString() ?? '';

  /// A bar tab that has not sat down: a check opened with a name and no table. It is rung in and sent like
  /// a table's check, and is on no floor map; given a table, it is that table's check from then on.
  bool get isTab => table.isEmpty && fields['tab'] == true && (fields['order_type'] ?? 'dine_in') == 'dine_in';

  /// At a table: with seats to ring a dish in for, and on the floor map.
  bool get hasTable => table.isNotEmpty;

  /// "Linda's tab", or "A tab" when nobody named it.
  String get tabLabel => customerName.trim().isEmpty ? 'A tab' : "${customerName.trim()}'s tab";

  // Counter mode and takeout (architecture section 12): numbered by the hub, named by the operator.
  bool get isTakeout => table.isEmpty && !isTab;
  int? get orderNo => fields['order_no'] as int?;
  String get customerName => fields['customer_name']?.toString() ?? '';
  String get phone => fields['phone']?.toString() ?? '';
  String get channel => fields['channel']?.toString() ?? '';
  String get stage => fields['stage']?.toString() ?? 'new';
  int? get promisedAt => fields['promised_at'] as int?;
  int get quotedMinutes => (fields['quoted_minutes'] as num? ?? 0).toInt();

  /// The customer named the time ("for 18:30"), so it is theirs: a big order starts sooner, never later.
  bool get forLater => fields['for_later'] == true;

  /// What goes in the bag besides the food, as the to-go question was answered: nothing in the list when
  /// the customer wants nothing, null while nobody was asked.
  List<BagItem>? get bag => bagAnswer(fields);

  /// How many dishes are on the order: what a kitchen counts when it says an order is big.
  int get dishes => activeLines.fold(0, (n, l) => n + l.qty);
  bool get hasPaid => payments.isNotEmpty;

  /// What the hub keeps on an order it took from the restaurant's website (docs/online-orders.md); null for
  /// an order rung in on a screen, whatever its channel says.
  OnlineOrder? get online => OnlineOrder.of(fields);

  /// What the customer wrote for the whole order, on one line: an online order's instructions. It heads
  /// every station's ticket, on paper and on a kitchen screen.
  String get note => oneLine(fields['note']);

  /// How a to-go order leaves, where to, and the note that goes with it; on a catering order what its
  /// event needs: the guests too.
  EventDetails get event => EventDetails.of(fields);
  bool get isCatering => isTakeout && channel == 'catering';

  /// Brought to the customer by the restaurant's own driver (docs/delivery.md). A table's check never is.
  bool get isDelivery => isTakeout && fields['handover'] == 'delivery';

  /// What the delivery costs the customer, as it was picked (docs/delivery.md, "The delivery fee"): the
  /// band and what it cost then. Null while nobody said. The check charges it only while [isDelivery].
  OrderFee? get deliveryFee => OrderFee.of(fields['delivery_fee']);

  /// A delivery that left with a driver and is on its way: who has it ([driver], by name, and
  /// [driverId]) and when it left ([outAt], ms). Deliveries handed over in one go left at the same moment.
  bool get isOut => isDelivery && stage == 'out';
  String get driver => fields['driver']?.toString() ?? '';
  String get driverId => fields['driver_id']?.toString() ?? '';
  int? get outAt => (fields['out_at'] as num?)?.toInt();
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

  /// The hub's change feed: what tells the screens that an order, the menu or a setting changed, so they
  /// need not ask every two seconds. Not live until `start`ed (the app does, a test need not), and a screen
  /// under a feed that is not live polls as it always did.
  LiveFeed get live => _live ??= LiveFeed(this);
  LiveFeed? _live;

  Future<Map<String, dynamic>> health() => _get('/health');

  /// Opens the change feed of the backend at [base] (`GET /live`, server-sent events) and hands back the
  /// answer with its body still arriving; [LiveFeed] reads it. Not a call with failover: the feed follows
  /// the backend the other calls found. Asked for uncompressed, since a compressed stream holds a line back
  /// until the next ones fill its block.
  Future<http.StreamedResponse> openLive(String base) {
    final request = http.Request('GET', Uri.parse('$base/live').replace(queryParameters: {'device': settings.device}))
      ..headers['accept'] = 'text/event-stream'
      ..headers['accept-encoding'] = 'identity'
      ..headers['cache-control'] = 'no-store';
    final sent = _client.send(request);
    return sent.timeout(
      timeout,
      onTimeout: () {
        // Whatever still answers later is closed, not left open with nobody reading it.
        unawaited(
          sent.then((late) => late.stream.listen(null, onError: (Object _) {}).cancel(), onError: (Object _) {}),
        );
        throw TimeoutException('no answer from $base');
      },
    );
  }

  /// The orders for a list, newest activity first: those at [status], or all of them. With [within], only
  /// the ones that changed that recently and the ones still open, so a list of every order is a day long,
  /// not the restaurant's whole history. Each line comes without its choices and price (`brief`): a list
  /// shows neither, and they are nine tenths of the answer; [order] reads one order whole.
  ///
  /// With [day], the checks opened during that day's service instead (four in the morning to four the
  /// next, the location's time), open or not: what a manager looks through for an older check. [within]
  /// still goes along, though the day says it all: a hub from before days would otherwise answer with
  /// every order it ever took. Such a hub's orders carry no [Order.openedMs], which is how a screen tells.
  Future<List<Order>> listOrders({String? status, Duration? within, DateTime? day}) => _repeated(
    '/orders',
    query: {
      'status': ?status,
      if (day != null) 'day': isoDay(day),
      if (within != null) 'hours': (within.inMinutes / 60).toString(),
      'brief': 'true',
    },
    (json) => (json['orders'] as List).map((o) => Order.fromJson(o as Map<String, dynamic>)).toList(),
  );

  Future<Order> order(String orderId) => _repeated('/orders/$orderId', Order.fromJson);

  /// The orders ahead (docs/catering.md): every to-go order a customer named a time for that has not been
  /// handed over, by the day it is for, with the money on each. Null from a hub older than the list.
  Future<OrdersAhead?> ordersAhead() async {
    try {
      return await _repeated('/orders/ahead', OrdersAhead.fromJson);
    } on ApiException catch (err) {
      if (err.status == 404 || err.status == 405) return null;
      rethrow;
    }
  }

  /// The screen of these stations, by their codes (docs/kitchen-screens.md): the tickets they still have to
  /// make and the last ones they finished. With [pass], the pass instead: the dishes of these stations (of
  /// every station when none is named) whole on one ticket, with what each station has made. Null from a hub
  /// older than the screens, or than the pass.
  Future<KitchenBoard?> kitchenScreen(List<String> stations, {bool pass = false}) async {
    try {
      return await _repeated(
        pass ? '/kitchen/pass' : '/kitchen/screen',
        KitchenBoard.fromJson,
        query: stations.isEmpty ? null : {'stations': stations.join(',')},
      );
    } on ApiException catch (err) {
      if (err.status == 404 || err.status == 405) return null;
      rethrow;
    }
  }

  /// After how many minutes in the kitchen a ticket on a station's screen turns amber and red. Null from a
  /// hub older than the screens.
  Future<KitchenMinutes?> kitchenMinutes() async {
    try {
      return KitchenMinutes.fromJson(await _get('/settings/kitchen_screens'));
    } on ApiException catch (err) {
      if (err.status == 404 || err.status == 405) return null;
      rethrow;
    }
  }

  /// A manager (token from [adminSession]) sets those minutes for every station's screen.
  Future<KitchenMinutes> saveKitchenMinutes(String token, KitchenMinutes minutes) async => KitchenMinutes.fromJson(
    await _withFailover(
      (base) => _client.put(
        Uri.parse('$base/settings/kitchen_screens'),
        headers: {'content-type': 'application/json', ..._bearer(token)},
        body: jsonEncode(minutes.toJson()),
      ),
    ),
  );

  /// The prep list of [day] (a day of service, `2026-11-21`; docs/catering.md): what its orders ahead need
  /// made, added up for each station. Null from a hub older than the list.
  Future<PrepList?> prepList(String day) async {
    try {
      return await _repeated('/orders/ahead/prep', PrepList.fromJson, query: {'day': day});
    } on ApiException catch (err) {
      if (err.status == 404 || err.status == 405) return null;
      rethrow;
    }
  }

  /// The runs of [day] (`2026-11-16`), of the day of service that is running without one
  /// (docs/delivery.md): every driver who took a delivery out, their runs and what became of each bag. No
  /// money is in it. Null from a hub older than the runs.
  Future<RunsReport?> runs({String? day}) async {
    try {
      return await _repeated('/deliveries/runs', RunsReport.fromJson, query: day == null ? null : {'day': day});
    } on ApiException catch (err) {
      if (err.status == 404 || err.status == 405) return null;
      rethrow;
    }
  }

  /// Prints the prep list of [day] at [printer] (the one this screen keeps for its bills, by id) or, without
  /// one, where the location's bills print. Returns the name of the printer it was sent to. 409 with a
  /// `message` when the day has no dish or the location has no printer.
  Future<String> printPrep(String day, {String? printer}) async => _printedAt(
    await _post('/orders/ahead/prep/print', {'day': day, 'printer': ?printer}, timeout: const Duration(seconds: 6)),
  );

  /// Prints the pack sheet of [orderId] as the order stands at this moment (docs/catering.md), where pack
  /// sheets print: the takeout station's printer, else where the location's bills print. Returns the name
  /// of the printer it was sent to. 409 with a `message` when the order has no dish or the location has no
  /// printer.
  Future<String> printPackSheet(String orderId) async => _printedAt(
    await _post('/orders/$orderId/pack-sheet', const <String, dynamic>{}, timeout: const Duration(seconds: 6)),
  );

  /// The order this number opened last today, as the hub finds it (the digits match, the location's day,
  /// a voided order does not count), or null when the number opened none today.
  Future<Order?> lastOrder({required String phone}) async {
    final json = await _get('/orders/last', query: {'phone': phone});
    final order = json['order'];
    return order == null ? null : Order.fromJson(order as Map<String, dynamic>);
  }

  /// What the hub knows of the customer at this number: the name on their orders, how many they placed,
  /// the note kept about them and their latest orders. Null when nothing answers, from a hub older than
  /// customers, and for a number too short to be a customer's: a screen then works as it did before.
  Future<CustomerCard?> customer(String? phone) async {
    final digits = phoneDigits(phone);
    if (digits.length < customerDigits) return null;
    try {
      final json = await _get('/customers/lookup', query: {'phone': digits});
      return json['known'] is bool ? CustomerCard.fromJson(json) : null;
    } on ApiException {
      return null;
    }
  }

  /// Keeps the one line about the customer at this number (an empty one takes it off), with who wrote it.
  /// Hands back the note as the hub keeps it: on one line, cut to its length.
  Future<String> saveCustomerNote(String phone, String note, {String? by}) async {
    final json = await _put('/customers/${phoneDigits(phone)}', {'note': note, 'by': ?by});
    return json['note'] as String? ?? '';
  }

  /// "Same again": a past order's dishes as the menu sells them today, and the ones it no longer sells
  /// that way, each with why. Nothing is added by asking.
  Future<Again> again(String orderId) async => Again.fromJson(await _get('/orders/$orderId/again'));

  /// The floor plan with every table's open checks; the last one read when nothing answers.
  Future<FloorPlan> floor() => _repeated('/floor', FloorPlan.fromJson, remember: 'floor');

  /// The staff by name and role: who a table can be given to and who may give one. The last answer read
  /// when nothing answers, so a host can still seat a party for a server (ADR 6).
  Future<Roster> staff() => _repeated('/staff', Roster.fromJson, remember: 'staff');

  /// A host's word on tonight's turn for a table (docs/table-servers.md): [serverId] is in it ([on]) or out
  /// of it, says [staffId]. Answers with the turn as it stands: the staff ids of the people in it, whose
  /// turn it is first. The hub keeps the turn, so with no backend answering nothing is changed.
  Future<List<String>> sayTurn(String staffId, String serverId, {required bool on}) async {
    final json = await _post('/floor/turn', {'staff_id': staffId, 'server_id': serverId, 'on': on});
    return [for (final id in json['turn'] as List? ?? const []) '$id'];
  }

  /// The location's table timers: whether the floor map draws a countdown ring on each table, and the
  /// minutes each stage is given.
  Future<TableTimers> tableTimers() async => TableTimers.fromJson(await _get('/settings/table_timers'));

  /// A manager (token from [adminSession]) sets the table timers for every floor map.
  Future<TableTimers> saveTableTimers(String token, TableTimers timers) async => TableTimers.fromJson(
    await _withFailover(
      (base) => _client.put(
        Uri.parse('$base/settings/table_timers'),
        headers: {'content-type': 'application/json', ..._bearer(token)},
        body: jsonEncode(timers.toJson()),
      ),
    ),
  );

  /// The time now, in wall-clock ms, by the hub's clock as near as its answers tell it: what the countdowns
  /// on the floor map are measured with, so two screens whose own clocks disagree draw the same ring. Every
  /// answer says when the backend sent it, to the second; a device within two seconds of that is taken to be
  /// right, and one further off is corrected by the difference.
  int nowMs() => DateTime.now().millisecondsSinceEpoch + _hubAheadMs;
  int _hubAheadMs = 0;

  void _hearClock(String? date) {
    final hub = httpDateMs(date);
    if (hub == null) return;
    // The header drops the fraction of the second: half a second on average.
    final ahead = hub + 500 - DateTime.now().millisecondsSinceEpoch;
    if (ahead.abs() < 2000) {
      _hubAheadMs = 0;
    } else if ((ahead - _hubAheadMs).abs() > 1500) {
      _hubAheadMs = ahead; // not moved by the second the header rounds to, so a countdown does not jitter
    }
  }

  /// 86 a size or option (`sold_out`), or bring it back (`available`). With [left], a size that is on sale
  /// gets that number left instead: every one sold takes it down, one taken off a check gives it back, the
  /// hub marks it sold out at zero and the number clears overnight. Without it a number already there is
  /// taken off.
  Future<void> set86(String targetId, {required bool soldOut, int? left, String? by}) => _post('/menu/86', {
    'target_id': targetId,
    'status': soldOut ? 'sold_out' : 'available',
    'remaining': ?(soldOut ? null : left),
    'by': ?by,
  });

  /// The 86 board: what is sold out, then every dish with a number left, the fewest first.
  Future<List<BoardRow>> board() async => [
    for (final row in (await _get('/menu/86'))['items'] as List? ?? const [])
      BoardRow.fromJson(row as Map<String, dynamic>),
  ];

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

  /// Minutes each channel promises a takeout order, which channels may pay at pickup, the rush a manager
  /// set for tonight and the minutes a big order adds; the last answer read when nothing answers, so an
  /// order taken with no hub is still quoted the location's way (ADR 6).
  Future<Quotes> quotes() => _repeated('/settings/quotes', Quotes.fromJson, remember: 'quotes');

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

  /// A manager (token from [adminSession]) says the kitchen is behind: [minutes] more on every quote made
  /// from now on, on every terminal, until the night is over; 0 takes it off. Answers with the quotes as
  /// they stand now.
  Future<Quotes> saveRush(String token, int minutes) async => Quotes.fromJson(
    await _withFailover(
      (base) => _client.put(
        Uri.parse('$base/settings/rush'),
        headers: {'content-type': 'application/json', ..._bearer(token)},
        body: jsonEncode({'minutes': minutes}),
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

  /// What the kitchen tickets of one send say about each other at this location ("Ticket 2 of 3", "Also at"),
  /// and whether a to-go order's takeout ticket says PAID or NOT PAID.
  Future<TicketWords> ticketWords() async => TicketWords.fromJson(await _get('/settings/tickets'));

  /// A manager (token from [adminSession]) turns any of the lines on or off; the next ticket prints by it.
  Future<TicketWords> saveTicketWords(String token, TicketWords words) async => TicketWords.fromJson(
    await _withFailover(
      (base) => _client.put(
        Uri.parse('$base/settings/tickets'),
        headers: {'content-type': 'application/json', ..._bearer(token)},
        body: jsonEncode(words.toJson()),
      ),
    ),
  );

  /// The stations each screen prints no ticket at, as the hub keeps them. Null from a hub older than that,
  /// where every screen prints everywhere.
  Future<TicketSkips?> ticketSkips() async {
    try {
      return TicketSkips.fromJson(await _get('/settings/ticket_skips'));
    } on ApiException catch (err) {
      if (err.status == 404) return null;
      rethrow;
    }
  }

  /// A manager (token from [adminSession]) says which stations each screen prints no ticket at, the whole
  /// list at once. The next send prints by it.
  Future<TicketSkips> saveTicketSkips(String token, TicketSkips skips) async => TicketSkips.fromJson(
    await _withFailover(
      (base) => _client.put(
        Uri.parse('$base/settings/ticket_skips'),
        headers: {'content-type': 'application/json', ..._bearer(token)},
        body: jsonEncode(skips.toJson()),
      ),
    ),
  );

  /// The guest's bill at this location: where it prints, what stands at its top and foot, and the printers
  /// by name. Null from a hub older than the bill, which prints none.
  Future<BillSettings?> billSettings() async {
    try {
      return BillSettings.fromJson(await _get('/settings/bill'));
    } on ApiException catch (err) {
      if (err.status == 404) return null;
      rethrow;
    }
  }

  /// A manager (token from [adminSession]) sets where the location's bills print ([printer], a printer's id;
  /// null for the usual one) and the lines at their top and foot. The next bill prints by it.
  Future<BillSettings> saveBillSettings(
    String token, {
    required String? printer,
    required List<String> header,
    required List<String> footer,
  }) async => BillSettings.fromJson(
    await _withFailover(
      (base) => _client.put(
        Uri.parse('$base/settings/bill'),
        headers: {'content-type': 'application/json', ..._bearer(token)},
        body: jsonEncode({'printer': printer, 'header': header, 'footer': footer}),
      ),
    ),
  );

  /// Prints the guest's bill for [orderId] as the hub reckons its check at this moment: at [printer] (the one
  /// this screen keeps for its bills, by id) or, without one, where the location's bills print. Returns the
  /// name of the printer it was sent to and how many bills went: a table that pays on several checks gets
  /// one for each, or the one of [check] alone. 409 with a `message` when the check is empty, the table has
  /// no such check or the location has no printer.
  Future<({String at, int bills})> printBill(String orderId, {String? printer, int? check}) async {
    final answer = await _post('/orders/$orderId/bill', {
      'printer': ?printer,
      'check': ?check,
    }, timeout: const Duration(seconds: 6));
    return (at: _printedAt(answer), bills: (answer['bills'] as num?)?.toInt() ?? 1);
  }

  /// A made-up bill under the lines being tried, at the printer being tried (null for the usual one), before
  /// any of it is saved (manager token). Returns the name of the printer it was sent to.
  Future<String> printBillSample(
    String token, {
    required String? printer,
    required List<String> header,
    required List<String> footer,
  }) async => _printedAt(
    await _post(
      '/print/bill-sample',
      {'printer': printer, 'header': header, 'footer': footer},
      headers: _bearer(token),
      timeout: const Duration(seconds: 6),
    ),
  );

  static String _printedAt(Map<String, dynamic> answer) {
    final at = answer['printed_at'];
    return at is Map ? (at['name'] ?? at['id'] ?? '').toString() : '';
  }

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

  /// A manager's PIN for a discount or a charge on one order (`adjust`), or for the void of a dish the
  /// kitchen already has (`void`): the answer's `approval` goes on the operation. 401 is a wrong PIN, 403 not
  /// a manager, 423 locked after too many tries.
  Future<Map<String, dynamic>> approve({
    required String device,
    required String pin,
    required String orderId,
    String purpose = 'adjust',
  }) => _post('/approvals', {'device': device, 'pin': pin, 'order_id': orderId, 'purpose': purpose});

  /// What voiding a dish the kitchen already has takes at this location: a manager's PIN or not, and the
  /// reasons to pick from. The last answer read when nothing answers, so the reasons still show (ADR 6).
  /// Null from a hub older than the rule, which asks for nothing.
  Future<VoidRules?> voidRules() async {
    try {
      final rules = await _repeated('/settings/voids', VoidRules.fromJson, remember: 'voids');
      return rules.reasons.isEmpty ? null : rules;
    } on ApiException catch (err) {
      if (err.status == 404) return null;
      rethrow;
    }
  }

  /// The one question asked before a to-go order is sent (docs/to-go-question.md), as the location set it:
  /// whether it is asked, its words and what it offers. The last answer read when nothing answers, so an
  /// order taken in an outage is still asked about (ADR 6). Null from a hub older than the question, which
  /// keeps no answer: the screen then asks nothing.
  Future<BagQuestion?> bagQuestion() async {
    try {
      return await _repeated('/settings/bag', BagQuestion.fromJson, remember: 'bag');
    } on ApiException catch (err) {
      if (err.status == 404) return null;
      rethrow;
    }
  }

  /// A manager (token from [adminSession]) sets the to-go question for every terminal. A choice without an
  /// id is new; the answer carries the id the hub gave it.
  Future<BagQuestion> saveBagQuestion(String token, BagQuestion question) async => BagQuestion.fromJson(
    await _withFailover(
      (base) => _client.put(
        Uri.parse('$base/settings/bag'),
        headers: {'content-type': 'application/json', ..._bearer(token)},
        body: jsonEncode(question.toJson()),
      ),
    ),
  );

  /// What a delivery costs the customer here (docs/delivery.md, "The delivery fee"): whether a fee is
  /// charged, by miles or minutes, and the prices. The last list read when nothing answers, so a delivery
  /// taken in an outage is still asked what it costs (ADR 6). Null from a hub older than the fee, which
  /// charges none: the form then asks nothing.
  Future<DeliveryFees?> deliveryFees() async {
    try {
      return await _repeated('/settings/delivery_fee', DeliveryFees.fromJson, remember: 'delivery_fee');
    } on ApiException catch (err) {
      if (err.status == 404 || err.status == 405) return null;
      rethrow;
    }
  }

  /// A manager (token from [adminSession]) sets what a delivery costs for every terminal. The answer is the
  /// list as the hub keeps it: in order of how far the bands reach.
  Future<DeliveryFees> saveDeliveryFees(String token, DeliveryFees fees) async => DeliveryFees.fromJson(
    await _withFailover(
      (base) => _client.put(
        Uri.parse('$base/settings/delivery_fee'),
        headers: {'content-type': 'application/json', ..._bearer(token)},
        body: jsonEncode(fees.toJson()),
      ),
    ),
  );

  /// How far a delivery's address is from the restaurant, and the band of the fee it falls in (docs/
  /// delivery.md, "Looking the distance up"): the hub asks its map service, which is sent the two addresses
  /// and nothing else. It may take a few seconds. Throws [ApiException] when there is no distance: 409 where
  /// the hub looks nothing up, 424 with the words for the form in its detail when the service gave none.
  ///
  /// With the customer's [phone] the hub first looks at their own earlier deliveries: one to this address
  /// says how far it is, and nobody is asked ("Customers who order again"). The number goes no further than
  /// the hub. [fresh] asks the map service all the same.
  ///
  /// [now] says the delivery is for now. Where live traffic is turned on ("Live traffic") the hub then
  /// also asks how long the drive is at this minute, beside the distance, and the answer carries it
  /// ([FeeLookup.driveNow]).
  Future<FeeLookup> deliveryDistance(String address, {String phone = '', bool fresh = false, bool now = false}) async {
    final digits = phoneDigits(phone);
    final answer = await _post('/delivery/distance', {
      'address': address,
      if (digits.isNotEmpty) 'phone': digits,
      if (fresh) 'fresh': true,
      if (now) 'now': true,
    }, timeout: const Duration(seconds: 9));
    try {
      return FeeLookup.fromJson(answer);
    } on FormatException catch (err) {
      throw ApiException(err.message);
    }
  }

  /// Live traffic for deliveries as the location has it (docs/delivery.md, "Live traffic"): whether a
  /// delivery for now is promised by the roads as they are, the minutes the kitchen needs before the
  /// drive, and what the hub has for it. Null from a hub older than live traffic.
  Future<LiveDrive?> liveDrive() async {
    try {
      return LiveDrive.fromJson(await _get('/settings/live_drive'));
    } on ApiException catch (err) {
      if (err.status == 404 || err.status == 405) return null;
      rethrow;
    }
  }

  /// A manager (token from [adminSession]) turns live traffic on or off and says how long the kitchen
  /// needs before the drive. Orders already taken keep the time they were promised.
  Future<LiveDrive> saveLiveDrive(String token, LiveDrive setting) async => LiveDrive.fromJson(
    await _withFailover(
      (base) => _client.put(
        Uri.parse('$base/settings/live_drive'),
        headers: {'content-type': 'application/json', ..._bearer(token)},
        body: jsonEncode(setting.toJson()),
      ),
    ),
  );

  /// The one-tap notes as this terminal last read them, for a dish's sheet opened before the hub answers
  /// again: the buttons are there at once.
  List<String> kitchenNotesKnown = const [];

  /// The location's one-tap notes to the kitchen (docs/kitchen-notes.md), in the order the buttons show. The
  /// last list read when nothing answers, so the buttons are there in an outage (ADR 6). Null from a hub
  /// older than the notes: the note is typed then, as before.
  Future<KitchenNotes?> kitchenNotes() async {
    try {
      final read = await _repeated('/settings/kitchen_notes', KitchenNotes.fromJson, remember: 'kitchen_notes');
      kitchenNotesKnown = read.notes;
      return read;
    } on ApiException catch (err) {
      if (err.status != 404) rethrow;
      kitchenNotesKnown = const [];
      return null;
    }
  }

  /// A manager (token from [adminSession]) lists the one-tap notes for every terminal.
  Future<KitchenNotes> saveKitchenNotes(String token, KitchenNotes notes) async {
    final saved = KitchenNotes.fromJson(
      await _withFailover(
        (base) => _client.put(
          Uri.parse('$base/settings/kitchen_notes'),
          headers: {'content-type': 'application/json', ..._bearer(token)},
          body: jsonEncode(notes.toJson()),
        ),
      ),
    );
    kitchenNotesKnown = saved.notes;
    return saved;
  }

  /// The allergens the menu names, in its order: what a server picks from when a guest tells of an allergy.
  /// The last list read when nothing answers, so an allergy can still be noted (ADR 6). Null from a hub
  /// older than allergies on the order, which would refuse the operation: the screen then offers none.
  Future<List<Allergen>?> allergens() async {
    try {
      return await _repeated('/menu/allergens', remember: 'allergens', (json) {
        final listed = json['allergens'];
        if (listed is! List) throw ApiException('no allergens in the answer', status: 404);
        return [for (final a in listed) Allergen.fromJson(a as Map<String, dynamic>)];
      });
    } on ApiException catch (err) {
      if (err.status == 404) return null;
      rethrow;
    }
  }

  /// A manager (token from [adminSession]) sets the void rules for every terminal. A reason without an id is
  /// new; the answer carries the id the hub gave it.
  Future<VoidRules> saveVoidRules(String token, VoidRules rules) async => VoidRules.fromJson(
    await _withFailover(
      (base) => _client.put(
        Uri.parse('$base/settings/voids'),
        headers: {'content-type': 'application/json', ..._bearer(token)},
        body: jsonEncode(rules.toJson()),
      ),
    ),
  );

  /// What came off the register since [sinceMs] (wall-clock ms) and why: voids of sent dishes, discounts
  /// and comps, with totals by reason, by who did it and by who approved it.
  Future<AdjustmentsReport> adjustmentsReport({required int sinceMs}) async =>
      AdjustmentsReport.fromJson(await _get('/reports/adjustments', query: {'since': '$sinceMs'}));

  // The time clock (docs/time-clock.md). --------------------------------------------------------------------

  /// Whether the location uses the time clock and how it counts the hours. The last answer read when
  /// nothing answers, so the pad keeps its Time clock button. Null from a hub older than the clock.
  Future<ClockSetting?> clockSetting() async {
    try {
      return await _repeated('/settings/time_clock', ClockSetting.fromJson, remember: 'time_clock');
    } on ApiException catch (err) {
      if (err.status == 404) return null;
      rethrow;
    }
  }

  /// A manager (token from [adminSession]) turns the clock on or off, or changes how it counts.
  Future<ClockSetting> saveClockSetting(String token, ClockSetting setting) async => ClockSetting.fromJson(
    await _withFailover(
      (base) => _client.put(
        Uri.parse('$base/settings/time_clock'),
        headers: {'content-type': 'application/json', ..._bearer(token)},
        body: jsonEncode(setting.toJson()),
      ),
    ),
  );

  /// A person at the clock, known by their own [pin] exactly as at sign-in. [action] is `state` (only look),
  /// `in`, `out`, `break_start` or `break_end`; the hub stamps the time. [punchId] names the punch, so one
  /// sent again after no answer counts once. 401 for a wrong PIN, 423 after too many, 409 when the punch
  /// does not fit where they stand (`already_in`, `not_in`, `on_break`, `not_on_break`) or the clock is `off`.
  Future<ClockStand> clockPunch({
    required String device,
    required String pin,
    String action = 'state',
    String? punchId,
  }) async => ClockStand.fromJson(
    await _post('/timeclock/punch', {'device': device, 'pin': pin, 'action': action, 'punch_id': ?punchId}),
  );

  /// The hours of the shifts that began from [sinceMs] up to [untilMs] (manager token): who is on the clock
  /// now, what each person worked, and each shift with its log.
  Future<ClockReport> clockReport(String token, {required int sinceMs, required int untilMs}) async =>
      ClockReport.fromJson(
        await _get('/timeclock/report', query: {'since': '$sinceMs', 'until': '$untilMs'}, headers: _bearer(token)),
      );

  /// A manager writes a shift in for somebody who never clocked in. With no [outMs] they are on the clock
  /// from [inMs]. The hub wants the [reason] and keeps it in the log.
  Future<ClockShift> addShift(
    String token, {
    required String staffId,
    required int inMs,
    int? outMs,
    List<ClockBreak> breaks = const [],
    required String reason,
    String? device,
  }) async => ClockShift.fromJson(
    await _post('/timeclock/shifts', {
      'staff_id': staffId,
      'in_ms': inMs,
      'out_ms': outMs,
      'breaks': [for (final b in breaks) b.toJson()],
      'reason': reason,
      'device': device ?? '',
    }, headers: _bearer(token)),
  );

  /// A manager's correction: the whole of the shift's times as they should be, and why. The log keeps what
  /// they were.
  Future<ClockShift> editShift(
    String token,
    String shiftId, {
    required int inMs,
    int? outMs,
    List<ClockBreak> breaks = const [],
    required String reason,
    String? device,
  }) async => ClockShift.fromJson(
    await _withFailover(
      (base) => _client.put(
        Uri.parse('$base/timeclock/shifts/$shiftId'),
        headers: {'content-type': 'application/json', ..._bearer(token)},
        body: jsonEncode({
          'in_ms': inMs,
          'out_ms': outMs,
          'breaks': [for (final b in breaks) b.toJson()],
          'reason': reason,
          'device': device ?? '',
        }),
      ),
    ),
  );

  /// A manager takes a shift off (a punch made by mistake): it stays in the report, marked, and counts for
  /// nothing.
  Future<ClockShift> removeShift(String token, String shiftId, {required String reason, String? device}) async =>
      ClockShift.fromJson(
        await _withFailover(
          (base) => _client.delete(
            Uri.parse('$base/timeclock/shifts/$shiftId')
                .replace(queryParameters: {'reason': reason, 'device': device ?? ''}),
            headers: _bearer(token),
          ),
        ),
      );

  // Notes for the shift and the manager's log (docs/shift-notes.md). -----------------------------------------

  /// The notes that are up, the newest first, each with whether [staffId] has seen it. Null from a hub
  /// older than the notes.
  Future<MyNotes?> shiftNotes(String staffId) async {
    try {
      return MyNotes.fromJson(await _get('/notes', query: {'staff_id': staffId}));
    } on ApiException catch (err) {
      if (err.status == 404) return null;
      rethrow;
    }
  }

  /// [staffId] has seen these notes: the hub does not show them to that person again. Answers their notes
  /// as they stand now.
  Future<MyNotes> notesSeen(String staffId, Iterable<String> noteIds) async => MyNotes.fromJson(
    await _post('/notes/seen', {
      'staff_id': staffId,
      'note_ids': [...noteIds],
    }),
  );

  /// A manager's list of the notes (token from [adminSession]): the ones that are up, each with who has
  /// seen it and who has not yet, and the ones that came down lately.
  Future<NotesBoard> notesBoard(String token) async =>
      NotesBoard.fromJson(await _get('/notes/board', headers: _bearer(token)));

  /// A manager puts a note up. [lasts] is `tonight` (it comes down when the night is over) or `stays`.
  /// 409 `too_many` when as many are up as the hub allows.
  Future<ShiftNote> writeNote(String token, {required String text, required String lasts}) async =>
      ShiftNote.fromJson(await _post('/notes', {'text': text, 'lasts': lasts}, headers: _bearer(token)));

  /// A manager changes a note that is up. New words show it to everybody again. 409 `ended` for one that
  /// has come down meanwhile.
  Future<ShiftNote> changeNote(String token, String noteId, {required String text, required String lasts}) async =>
      ShiftNote.fromJson(
        await _withFailover(
          (base) => _client.put(
            Uri.parse('$base/notes/$noteId'),
            headers: {'content-type': 'application/json', ..._bearer(token)},
            body: jsonEncode({'text': text, 'lasts': lasts}),
          ),
        ),
      );

  /// A manager takes a note down. The hub keeps it; nobody is shown it any more.
  Future<void> takeNoteDown(String token, String noteId) =>
      _withFailover((base) => _client.delete(Uri.parse('$base/notes/$noteId'), headers: _bearer(token)));

  /// The manager's log, the newest entry first (manager token): of one [subject] or of all, holding every
  /// word of [find], from before the entry named [before] (the last one of the page read before).
  Future<Logbook> logbook(String token, {String? subject, String find = '', String? before}) async => Logbook.fromJson(
    await _get(
      '/logbook',
      query: {'subject': ?subject, if (find.trim().isNotEmpty) 'q': find.trim(), 'before': ?before},
      headers: _bearer(token),
    ),
  );

  /// A manager writes an entry in the log, under one of the hub's subjects.
  Future<LogEntry> writeLogEntry(String token, {required String subject, required String text, String? device}) async =>
      LogEntry.fromJson(
        await _post('/logbook', {'subject': subject, 'text': text, 'device': device ?? ''}, headers: _bearer(token)),
      );

  /// A manager strikes an entry out. It stays in the log, readable, with who struck it and when.
  Future<LogEntry> strikeLogEntry(String token, String entryId) async =>
      LogEntry.fromJson(await _post('/logbook/$entryId/strike', const <String, dynamic>{}, headers: _bearer(token)));

  // The waste log (docs/waste-log.md). -----------------------------------------------------------------------

  /// One day of the waste log, the newest entry first, with the location's reasons: the day that is running,
  /// or [day] ("2026-11-16"). 404 from a hub older than the log.
  Future<WasteDay> wasteDay({String? day}) async => WasteDay.fromJson(await _get('/waste', query: {'day': ?day}));

  /// Somebody writes down food that was wasted: a dish of the menu ([variantId], which the hub names and
  /// prices itself) or something typed ([name]), how many, and a reason of the location's list.
  Future<WasteEntry> logWaste({
    required String staffId,
    String? variantId,
    String? entryId,
    String name = '',
    required int qty,
    required String reason,
    String note = '',
    String? device,
  }) async => WasteEntry.fromJson(
    await _post('/waste', {
      'staff_id': staffId,
      'variant_id': ?variantId,
      'entry_id': ?entryId,
      'name': name,
      'qty': qty,
      'reason': reason,
      'note': note,
      'device': device ?? '',
    }),
  );

  /// Strikes an entry out: the person who wrote it, the day they wrote it ([staffId]), or a manager any day
  /// ([token]). It stays in the log, readable, and counts in no total.
  Future<WasteEntry> strikeWaste(String entryId, {String staffId = '', String? token}) async => WasteEntry.fromJson(
    await _post('/waste/$entryId/strike', {'staff_id': staffId}, headers: token == null ? null : _bearer(token)),
  );

  /// The waste of a span of days added up by day, by reason and by dish (manager token). The days are asked
  /// as [salesReport] asks them. 404 from a hub older than the log.
  Future<WasteReport> wasteReport(String token, {String? from, String? to}) async =>
      WasteReport.fromJson(await _get('/reports/waste', query: {'from': ?from, 'to': ?to}, headers: _bearer(token)));

  /// The location's reasons for the waste log, in the order the buttons show. Null from a hub older than
  /// the log.
  Future<WasteReasons?> wasteReasons() async {
    try {
      return WasteReasons.fromJson(await _get('/settings/waste'));
    } on ApiException catch (err) {
      if (err.status == 404) return null;
      rethrow;
    }
  }

  /// A manager (token from [adminSession]) lists the reasons for every terminal.
  Future<WasteReasons> saveWasteReasons(String token, List<String> reasons) async => WasteReasons.fromJson(
    await _withFailover(
      (base) => _client.put(
        Uri.parse('$base/settings/waste'),
        headers: {'content-type': 'application/json', ..._bearer(token)},
        body: jsonEncode({'reasons': reasons}),
      ),
    ),
  );

  // Contests for the staff (docs/contests.md). ---------------------------------------------------------------

  /// The contests the location keeps, each with where it stands in time and whether the staff's screens show
  /// it, and what a form needs to set one up. No number is in it. The very same object as last time while
  /// nothing changed, and the last list read when nothing answers. Null from a hub older than contests.
  Future<ContestList?> contestList() async {
    try {
      return await _repeated('/settings/contests', ContestList.fromJson, remember: 'contests');
    } on ApiException catch (err) {
      if (err.status == 404) return null;
      rethrow;
    }
  }

  /// A manager (token from [adminSession]) sets the contests: the whole list, a new one without an id.
  Future<ContestList> saveContests(String token, List<Contest> contests) async => ContestList.fromJson(
    await _withFailover(
      (base) => _client.put(
        Uri.parse('$base/settings/contests'),
        headers: {'content-type': 'application/json', ..._bearer(token)},
        body: jsonEncode({
          'contests': [for (final contest in contests) contest.toJson()],
        }),
      ),
    ),
  );

  /// The contests on the staff's screens as [staffId] may see each: their own number and place, who is in
  /// front, and the whole board only where the manager said everybody sees it. The hub adds a board up from
  /// the checks of all its days, and the first reading of a long contest takes it some seconds, so this
  /// waits as long as the sales report does.
  Future<MyContests> myContests(String staffId) async =>
      MyContests.fromJson(await _get('/contests', query: {'staff_id': staffId}, timeout: const Duration(seconds: 90)));

  /// One contest with its whole board (a token whose holder may read the reports). It waits as long as
  /// [myContests], for the same reason.
  Future<Contest> contestBoard(String token, String contestId) async => Contest.fromJson(
    await _get('/reports/contests/$contestId', headers: _bearer(token), timeout: const Duration(seconds: 90)),
  );

  // Online orders (docs/online-orders.md). -------------------------------------------------------------------

  /// How the online orders are doing: how they arrive, today's by what became of them, the ones to look at
  /// and what is wrong right now. The very same object as last time while nothing changed. Null from a hub
  /// older than online orders.
  Future<OnlineStatus?> onlineStatus() async {
    try {
      return await _repeated('/online/status', OnlineStatus.fromJson);
    } on ApiException catch (err) {
      if (err.status == 404) return null;
      rethrow;
    }
  }

  /// Somebody ([by], by name) looked at the online orders to look at: they stay listed, and no screen says
  /// they are new any more. Answers how the online orders stand after it. 404 from a hub older than that.
  Future<OnlineStatus> onlineSeen(String by) async =>
      OnlineStatus.fromJson(await _post('/online/seen', {'by': by.length > 80 ? by.substring(0, 80) : by}));

  /// Asks the website for orders now, out of the hub's own turn: the button "Ask now". Answers with what
  /// came of it and how the online orders stand after. The hub waits for the website, so this waits longer
  /// than most calls. 409 from a hub with no key for asking.
  Future<OnlineAsked> onlineFetch() async => OnlineAsked.fromJson(
    await _post('/online/fetch', const <String, dynamic>{}, timeout: const Duration(seconds: 30)),
  );

  // The waitlist (docs/waitlist.md). ------------------------------------------------------------------------

  /// Tonight's waitlist: who is waiting, in the order they came, and who went off the list earlier. The very
  /// same object as last time while nobody changed it. With no backend answering it is the list as it was
  /// last read. Null from a hub older than the waitlist.
  Future<Waitlist?> waitlist() async {
    try {
      return await _repeated('/waitlist', Waitlist.fromJson, remember: 'waitlist');
    } on ApiException catch (err) {
      if (err.status == 404) return null;
      rethrow;
    }
  }

  /// The wait the hub suggests telling a party that comes now, by how many they are, from how tonight's
  /// parties waited (docs/waitlist.md, "A suggested wait"). It is a help and never in the way: nothing from
  /// a hub older than it, and nothing where no hub answers soon.
  Future<WaitSuggestions> waitSuggestions() async {
    try {
      return WaitSuggestions.fromJson(await _get('/waitlist/suggest'));
    } on ApiException {
      return WaitSuggestions.none;
    }
  }

  static Map<String, dynamic> _party(String staffId, String name, int size, String phone, int? quoted, String note) => {
    'staff_id': staffId,
    'name': name,
    'size': size,
    'phone': phone,
    'quoted_minutes': quoted,
    'note': note,
  };

  /// [staffId] puts a party on the list, behind the ones already waiting. [quotedMinutes] is the wait they
  /// were told; null when no time was given. Answers the list as it stands, with the new [Waitlist.party].
  /// 422 with the hub's reason for what it does not take; 409 `too_many` with the list full.
  Future<Waitlist> addParty(
    String staffId, {
    required String name,
    required int size,
    String phone = '',
    int? quotedMinutes,
    String note = '',
  }) async => Waitlist.fromJson(await _post('/waitlist', _party(staffId, name, size, phone, quotedMinutes, note)));

  /// Puts right what a waiting party told the host. Its place on the list stays. 409 `not_waiting` for a
  /// party that went off the list meanwhile.
  Future<Waitlist> changeParty(
    String staffId,
    String partyId, {
    required String name,
    required int size,
    String phone = '',
    int? quotedMinutes,
    String note = '',
  }) async =>
      Waitlist.fromJson(await _put('/waitlist/$partyId', _party(staffId, name, size, phone, quotedMinutes, note)));

  /// The party was told its table is ready; with [on] false, it was not after all.
  Future<Waitlist> partyCalled(String staffId, String partyId, {bool on = true}) async =>
      Waitlist.fromJson(await _post('/waitlist/$partyId/called', {'staff_id': staffId, 'on': on}));

  /// The party sat down at [table]; [orderId] is the check opened for it. A party another screen sat first
  /// stays where that screen put it: [Waitlist.party] says where.
  Future<Waitlist> seatParty(String staffId, String partyId, {required String table, String orderId = ''}) async =>
      Waitlist.fromJson(
        await _post('/waitlist/$partyId/seat', {'staff_id': staffId, 'table': table, 'order_id': orderId}),
      );

  /// The party went off the list without a table: [why] is `left` or `no_show`.
  Future<Waitlist> partyLeft(String staffId, String partyId, {String why = 'left'}) async =>
      Waitlist.fromJson(await _post('/waitlist/$partyId/left', {'staff_id': staffId, 'why': why}));

  /// A party that went off the list tonight is put back where it stood.
  Future<Waitlist> partyBack(String staffId, String partyId) async =>
      Waitlist.fromJson(await _post('/waitlist/$partyId/back', {'staff_id': staffId}));

  // The reservation book (docs/reservations.md). -------------------------------------------------------------

  /// A day's reservations ([day] as `2026-11-21`; the hub's today when null): the tables still booked, in
  /// the order of their times, the reservations that ended, and the days ahead that have any. The very same
  /// object as last time while nobody changed it. With no backend answering, today's book is the one last
  /// read. Null from a hub older than the book.
  Future<Book?> reservations({String? day}) async {
    try {
      return await _repeated(
        '/reservations',
        Book.fromJson,
        query: day == null ? null : {'day': day},
        remember: day == null ? 'reservations' : null,
      );
    } on ApiException catch (err) {
      if (err.status == 404) return null;
      rethrow;
    }
  }

  /// The tables the customer at [phone] has booked, today and ahead, the soonest first: for a call about
  /// a reservation. Null when the number is too short to be a customer's, when nothing answers, and from a
  /// hub older than this: a screen then works as it did before.
  Future<CallerTables?> callerTables(String? phone) async {
    final digits = phoneDigits(phone);
    if (digits.length < customerDigits) return null;
    try {
      final json = await _get('/reservations/caller', query: {'phone': digits});
      final booked = json['booked'];
      if (booked is! List) return null;
      return (
        today: json['today'] as String? ?? '',
        booked: [
          for (final row in booked)
            if (row is Map) Booking.fromJson(row.cast<String, dynamic>()),
        ],
      );
    } on ApiException {
      return null;
    }
  }

  static Map<String, dynamic> _booking(
    String staffId,
    String name,
    int size,
    String day,
    String time,
    String phone,
    String note,
    String table,
  ) => {
    'staff_id': staffId,
    'name': name,
    'size': size,
    'day': day,
    'time': time,
    'phone': phone,
    'note': note,
    'table': table,
  };

  /// [staffId] books a table for [day] (`2026-11-21`, a day of service) at [time] (`18:30` on the
  /// restaurant's clock), holding [table] when one is named. Answers that day's book as it stands, with the
  /// new [Book.booking]. 422 with the hub's reason for what it does not take.
  Future<Book> addBooking(
    String staffId, {
    required String name,
    required int size,
    required String day,
    required String time,
    String phone = '',
    String note = '',
    String table = '',
  }) async => Book.fromJson(await _post('/reservations', _booking(staffId, name, size, day, time, phone, note, table)));

  /// Puts a standing reservation right. Answers the book of the day it is for now. 409 `not_booked` for
  /// one that sat down or was taken out of the book meanwhile.
  Future<Book> changeBooking(
    String staffId,
    String bookingId, {
    required String name,
    required int size,
    required String day,
    required String time,
    String phone = '',
    String note = '',
    String table = '',
  }) async => Book.fromJson(
    await _put('/reservations/$bookingId', _booking(staffId, name, size, day, time, phone, note, table)),
  );

  /// The party of a reservation of today is here and waits for its table; with [on] false, it is not.
  Future<Book> bookingArrived(String staffId, String bookingId, {bool on = true}) async =>
      Book.fromJson(await _post('/reservations/$bookingId/arrived', {'staff_id': staffId, 'on': on}));

  /// The party sat down at [table]; [orderId] is the check opened for it. A party another screen sat first
  /// stays where that screen put it: [Book.booking] says where.
  Future<Book> seatBooking(String staffId, String bookingId, {required String table, String orderId = ''}) async =>
      Book.fromJson(
        await _post('/reservations/$bookingId/seat', {'staff_id': staffId, 'table': table, 'order_id': orderId}),
      );

  /// The reservation ended without a table: [why] is `cancelled` or `no_show`.
  Future<Book> cancelBooking(String staffId, String bookingId, {String why = 'cancelled'}) async =>
      Book.fromJson(await _post('/reservations/$bookingId/cancel', {'staff_id': staffId, 'why': why}));

  /// A reservation that ended stands in the book again, for the time it had.
  Future<Book> bookingBack(String staffId, String bookingId) async =>
      Book.fromJson(await _post('/reservations/$bookingId/back', {'staff_id': staffId}));

  // A check's history (docs/check-history.md). ---------------------------------------------------------------

  /// Everything that happened to one check, oldest first (manager token): who did what, at which screen and
  /// when. 404 with `unknown_id` for a check the hub has never heard of, and a plain 404 from a hub older
  /// than the history.
  Future<CheckHistory> checkHistory(String token, String orderId) async =>
      CheckHistory.fromJson(await _get('/orders/$orderId/history', headers: _bearer(token)));

  /// The picture taken with a step (a JPEG), as long as the hub keeps it; null once it is gone, or while no
  /// hub answers.
  Future<Uint8List?> eventPhoto(String photoId) async {
    try {
      final response = await _send((base) => _client.get(Uri.parse('$base/events/photos/$photoId')));
      return response.statusCode == 200 && response.bodyBytes.isNotEmpty ? response.bodyBytes : null;
    } on ApiException {
      return null;
    }
  }

  // The day's report (docs/day-report.md). ------------------------------------------------------------------

  /// The day's report (manager token) for [day], named as the hub names a day ("2026-11-16"); without one,
  /// the day of service that is running. 404 from a hub older than the report.
  Future<DayReport> dayReport(String token, {String? day}) async =>
      DayReport.fromJson(await _get('/reports/day', query: {'day': ?day}, headers: _bearer(token)));

  /// Today so far beside the same weekday a week ago (docs/today.md), with the token of somebody who may
  /// see the reports. 404 from a hub older than it.
  Future<TodayReport> today(String token) async =>
      TodayReport.fromJson(await _get('/reports/today', headers: _bearer(token)));

  /// The sales of the days [from] to [to] (manager token), each named as the hub names a day
  /// ("2026-11-16"), and of as many days whole weeks earlier to hold beside them (docs/sales-report.md);
  /// without either, the day of service that is running. The first reading of many days takes the hub some
  /// seconds, so this waits far longer than other calls. 404 from a hub older than the report, 422 with a
  /// `message` for a span the hub will not add up.
  Future<SalesReport> salesReport(String token, {String? from, String? to}) async => SalesReport.fromJson(
    await _get(
      '/reports/sales',
      query: {'from': ?from, 'to': ?to},
      headers: _bearer(token),
      timeout: const Duration(seconds: 90),
    ),
  );

  /// The days [from] to [to] as a table for a spreadsheet (manager token): a line a day and a line of totals
  /// (docs/sales-report.md, "For the accountant"). The days are asked as [salesReport] asks them, and it
  /// waits as long: the same checks are read. 404 from a hub older than the table.
  Future<SalesSheet> salesSheet(String token, {String? from, String? to}) async => SalesSheet.fromJson(
    await _get(
      '/reports/sales/sheet',
      query: {'from': ?from, 'to': ?to},
      headers: _bearer(token),
      timeout: const Duration(seconds: 90),
    ),
  );

  /// The dishes sold in a span of days and in as many days whole weeks earlier (manager token), each with its
  /// sizes and options (docs/dishes-sold.md). The days are asked as [salesReport] asks them, and it waits as
  /// long: the same checks are read. 404 from a hub older than the list.
  Future<DishesReport> dishesReport(String token, {String? from, String? to}) async => DishesReport.fromJson(
    await _get(
      '/reports/dishes',
      query: {'from': ?from, 'to': ?to},
      headers: _bearer(token),
      timeout: const Duration(seconds: 90),
    ),
  );

  /// How long the kitchen took in a span of days, and in as many days whole weeks earlier (manager token):
  /// its tickets as the kitchen screens marked them, by station, hour, day and dish (docs/kitchen-times.md).
  /// The days are asked as [salesReport] asks them, and it waits as long. 404 from a hub older than it.
  Future<KitchenTimes> kitchenTimes(String token, {String? from, String? to}) async => KitchenTimes.fromJson(
    await _get(
      '/reports/kitchen',
      query: {'from': ?from, 'to': ?to},
      headers: _bearer(token),
      timeout: const Duration(seconds: 90),
    ),
  );

  /// The suggestions taken in a span of days (manager token): the dishes added from the tray "Goes with ..."
  /// under the dish each went with, and who rang them in (docs/goes-with.md). The days are asked as
  /// [salesReport] asks them, and it waits as long: the same checks are read. 404 from a hub older than it.
  Future<SuggestionsReport> suggestionsReport(String token, {String? from, String? to}) async =>
      SuggestionsReport.fromJson(
        await _get(
          '/reports/suggestions',
          query: {'from': ?from, 'to': ?to},
          headers: _bearer(token),
          timeout: const Duration(seconds: 90),
        ),
      );

  /// The guest list (manager token): every customer who ordered with a phone number in the last year, with
  /// how often they came, what they spent and what they order most (docs/guest-list.md). A year of orders
  /// is read, so it waits as long as [salesReport]. 404 from a hub older than the list.
  Future<GuestsReport> guestsReport(String token) async => GuestsReport.fromJson(
    await _get('/reports/guests', headers: _bearer(token), timeout: const Duration(seconds: 90)),
  );

  /// One guest of the list read closely (manager token): more of their favourite dishes and their latest
  /// visits. 404 `no_guest` for a number with no visit in the year.
  Future<GuestDetail> guestDetail(String token, String phone) async => GuestDetail.fromJson(
    await _get('/reports/guests/${phoneDigits(phone)}', headers: _bearer(token), timeout: const Duration(seconds: 30)),
  );

  /// Whoever may read the guest list (token) keeps the [note] and the [tags] of the guest at this number:
  /// either or both; one left out stays as it is, an empty one is taken off. Hands back both as the hub
  /// keeps them now, each with who wrote it and when. 422 with a `message` for tags the hub will not keep;
  /// 404 or 405 from a hub older than tags.
  Future<GuestKept> keepGuest(String token, String phone, {String? note, List<String>? tags}) async =>
      GuestKept.fromJson(
        await _withFailover(
          (base) => _client.put(
            Uri.parse('$base/reports/guests/${phoneDigits(phone)}'),
            headers: {'content-type': 'application/json', ..._bearer(token)},
            body: jsonEncode({'note': ?note, 'tags': ?tags}),
          ),
        ),
      );

  /// Prints the day's report (manager token) at [printer] (the one this screen keeps for its bills, by id)
  /// or, without one, where the location's bills print. Returns the name of the printer it was sent to.
  /// 409 with a `message` when the location has no printer.
  Future<String> printDay(String token, {String? day, String? printer}) async => _printedAt(
    await _post(
      '/reports/day/print',
      {'day': ?day, 'printer': ?printer},
      headers: _bearer(token),
      timeout: const Duration(seconds: 6),
    ),
  );

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

  /// A token for the back office; 403 when the PIN's owner may not open it. With [power], when they may not
  /// do that one thing (docs/roles.md): a manager and an owner always may, and so may a role the location
  /// handed the power to. The answer says which `powers` its owner holds (a hub older than the table says
  /// nothing: there only a manager gets a token).
  Future<Map<String, dynamic>> adminSession({required String device, required String pin, String? power}) =>
      _post('/admin/session', {'device': device, 'pin': pin, 'power': ?power});

  /// Who may do what at this location, as this app last read it ([readPowers]); until then, and with a hub
  /// older than the table, the standard one: what the hub did before the table could be changed.
  final ValueNotifier<Powers> powers = ValueNotifier(Powers.standard);

  /// The location's table of who may do what, as the hub has it now; null from a hub older than the table.
  /// [powers] follows.
  Future<Powers?> powersTable() async {
    try {
      return powers.value = Powers.fromJson(await _get('/settings/powers'));
    } on ApiException catch (err) {
      if (err.status != 404) rethrow;
      powers.value = Powers.standard; // a hub older than the table does what the standard one says
      return null;
    }
  }

  /// Reads the location's table of who may do what into [powers]. With no backend answering it stays as it
  /// was last read: the hub weighs every step itself, so a table that is behind only shows an entry too
  /// many or too few.
  Future<Powers> readPowers() async {
    try {
      await powersTable();
    } on ApiException {
      // keeps what it has
    }
    return powers.value;
  }

  /// A manager or an owner (token from [adminSession]) hands powers out, or takes them back.
  Future<Powers> savePowers(String token, Powers next) async {
    final saved = Powers.fromJson(
      await _withFailover(
        (base) => _client.put(
          Uri.parse('$base/settings/powers'),
          headers: {'content-type': 'application/json', ..._bearer(token)},
          body: jsonEncode(next.toJson()),
        ),
      ),
    );
    return powers.value = saved;
  }

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
        _hearClock(response.headers['date']);
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
    _live?.dispose();
    _client.close();
    connection.dispose();
    powers.dispose();
  }
}

/// A day as the hub takes one: `2026-11-14`.
String isoDay(DateTime day) =>
    '${day.year.toString().padLeft(4, '0')}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
final _httpDate = RegExp(r'^\w{3}, (\d{2}) (\w{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2}) GMT$');

/// An HTTP `Date` header ("Fri, 13 Nov 2026 11:32:36 GMT") as wall-clock ms, or null when it is not one.
int? httpDateMs(String? header) {
  final found = header == null ? null : _httpDate.firstMatch(header.trim());
  if (found == null) return null;
  final month = _months.indexOf(found[2]!) + 1;
  if (month == 0) return null;
  int part(int i) => int.parse(found[i]!);
  return DateTime.utc(part(3), month, part(1), part(4), part(5), part(6)).millisecondsSinceEpoch;
}
