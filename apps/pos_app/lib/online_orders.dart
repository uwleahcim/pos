/// An order that came from the restaurant's website by itself (docs/online-orders.md, "On the screens"):
/// what the hub keeps on it of where it came from, and the words the screens say of it. Nothing here writes
/// anything: where an order came from is the hub's to say, and a screen cannot make it up.
library;

import 'api.dart';
import 'day_report.dart' show dollars, methodLabel;
import 'takeout.dart' show clockTime, oneLine;

/// What a screen says of such an order, in the list of checks (as the mark's name) and on the order.
const fromTheWebsite = 'From the website';

/// The note the hub writes on the payment of an order that was paid on the website.
const paidOnlineNote = 'Paid online';

/// What the hub wrote on an order it took from the website (`online` on the order): the website's own
/// number for it, whether it is picked up or delivered, how the customer chose to pay there, and what they
/// were charged.
class OnlineOrder {
  const OnlineOrder({
    this.source = '',
    this.id = '',
    this.type = '',
    this.payment = '',
    this.total = '',
    this.store = '',
    this.test = false,
  });

  /// As an order carries it; null for an order that was rung in on a screen, whatever its channel says.
  static OnlineOrder? of(Map<String, dynamic> fields) {
    final about = fields['online'];
    if (about is! Map) return null;
    return OnlineOrder(
      source: oneLine(about['source']),
      id: oneLine(about['id']),
      type: oneLine(about['type']),
      payment: oneLine(about['payment']).toUpperCase(),
      total: oneLine(about['total']),
      store: oneLine(about['store']),
      test: about['test'] == true,
    );
  }

  final String source;

  /// Which of the restaurant's websites it came from, in the restaurant's own word for it ("Sushi site"),
  /// where it has several and named them; empty otherwise.
  final String store;

  /// It came from the account the restaurant only tests with: nobody is to make it, and it is no sale.
  final bool test;

  /// The website's own number for the order: what to look it up by in GloriaFood's app.
  final String id;
  final String type; // pickup | delivery

  /// How the customer chose to pay on the website, in GloriaFood's word: ONLINE, CASH, CARD, CARD_PHONE.
  final String payment;

  /// What the website charged, to the cent; empty when it gave no total.
  final String total;

  /// "GloriaFood" for the one website the hub takes orders from today, and a name nobody knows as it came.
  String get sourceName => source == 'gloriafood' ? 'GloriaFood' : source;
}

/// Whether a payment is the one the hub records for an order paid on the website: money taken outside the
/// POS, with the hub's own note.
bool paidOnline(Payment payment) => payment.method == 'elsewhere' && payment.note == paidOnlineNote;

/// How a payment was taken, in words: "Paid online" for the website's, otherwise as the reports say a
/// method ("Cash", "Card", "Paid elsewhere").
String paidAs(String method, String note) =>
    method == 'elsewhere' && note == paidOnlineNote ? paidOnlineNote : methodLabel(method);

/// How an order from the website is to be paid while the POS has taken nothing on it, by what the customer
/// chose there: "pays cash at pickup", "pays by card at the door". Null for an order that was rung in on a
/// screen, and for a way of paying this build does not know.
String? paysHow(Order order) {
  final online = order.online;
  if (online == null) return null;
  final where = order.isDelivery ? 'at the door' : 'at pickup';
  return switch (online.payment) {
    'CASH' => 'pays cash $where',
    'CARD' => 'pays by card $where',
    'CARD_PHONE' => 'pays by card over the phone',
    // the website took money and the hub recorded none of it: it was paid in more than one way there, or
    // the website gave no total (docs/online-orders.md, "The money")
    'ONLINE' => 'check ${online.sourceName} for what was paid online',
    _ => null,
  };
}

/// What an order from the account for testing says of itself, wherever it shows.
const testOrder = 'TEST ORDER';

/// What a screen says of where such an order came from: "From the website", and which website where the
/// restaurant has several ("From the website · Sushi site").
String fromWhere(OnlineOrder online) => online.store.isEmpty ? fromTheWebsite : '$fromTheWebsite · ${online.store}';

/// What the order's own screen lists of an order from the website, a line each: that it is a test, what to
/// find it by on the website and on which of the restaurant's websites, and what the customer was charged.
List<String> onlineFacts(OnlineOrder online) => [
  if (online.test) 'A test order, from the account for testing. Do not make it. Void it when you are done.',
  [
    if (online.id.isNotEmpty) 'Order ${online.id}',
    if (online.sourceName.isNotEmpty) 'on ${online.sourceName}',
    if (online.store.isNotEmpty) '(${online.store})',
    if (online.type.isNotEmpty) '· ${online.type}',
  ].join(' '),
  if (online.total.isNotEmpty) 'Charged on the website: ${dollars(online.total)}',
].where((line) => line.isNotEmpty).toList();

// How the online orders are doing (docs/online-orders.md, "Under Location"). ---------------------------------

/// A count or a time as the hub sends it; null for anything that is no number.
int? _whole(Object? value) => value is num ? value.toInt() : null;

/// One thing a person should look at: an order that did not go on the POS, one that went on with something
/// to say of it, a table booked on the website that is not in the reservation book or is there with
/// something to say of it, or something the website sent that could not be read. By the website's own
/// number, with nothing of the customer.
class OnlineLook {
  const OnlineLook({
    this.id = '',
    this.kind = '',
    this.state = '',
    this.orderId = '',
    this.said = '',
    this.atMs = 0,
    this.isNew = false,
    this.store = '',
    this.test = false,
  });

  factory OnlineLook.fromJson(Map<String, dynamic> json) => OnlineLook(
    id: oneLine(json['id']),
    kind: oneLine(json['kind']),
    state: oneLine(json['state']),
    orderId: oneLine(json['order_id']),
    said: oneLine(json['said']),
    atMs: _whole(json['at_ms']) ?? _whole(json['fetched_ms']) ?? 0,
    isNew: json['new'] == true,
    store: oneLine(json['store']),
    test: json['test'] == true,
  );

  /// The website's own number for the order: what to look it up by in GloriaFood's app.
  final String id;
  final String kind; // pickup | delivery | table_reservation | order_ahead | unreadable | several | ...
  final String state; // placed | booked | kept | failed | new
  /// The POS's order it became; empty when it is on no check.
  final String orderId;

  /// What there is to say of it, in the hub's words.
  final String said;

  /// Since when it is as it is.
  final int atMs;

  /// Nobody has looked since.
  final bool isNew;

  /// Which of the restaurant's accounts it came from, by the name the restaurant gave it; empty when it has
  /// one account, or gave this one no name.
  final String store;

  /// It came from the account for testing.
  final bool test;

  /// Which account, for the row: "Sushi site", "Testing (test)"; empty when there is nothing to say.
  String get from => store.isEmpty ? (test ? 'test' : '') : (test ? '$store (test)' : store);

  /// It is a check on the POS, and what is said of it is about that check.
  bool get onThePos => state == 'placed' && orderId.isNotEmpty;

  /// It is a table that was booked on the website (with its dishes ordered ahead or without): it belongs in
  /// the reservation book, not on a check.
  bool get isTable => kind == 'table_reservation' || kind == 'order_ahead';

  /// It is in the reservation book, and what is said of it is about that reservation.
  bool get inTheBook => state == 'booked';

  /// It should be on the POS, in the book, or be read, and is not.
  bool get lost => state != 'placed' && state != 'booked' && state != 'kept';

  /// What it is, as a row's first words: "Order 1234567", "Reservation 1234567", or what it is when it has
  /// no number.
  String get name => switch (kind) {
    'unreadable' => 'Something the website sent',
    'several' => 'Orders from earlier days',
    _ when isTable => id.isEmpty ? 'A reservation' : 'Reservation $id',
    _ => id.isEmpty ? 'An order' : 'Order $id',
  };

  /// What became of it, as `hubctl online status` says it: only the one that should be on the POS or in the
  /// book and is not shouts.
  String get stateWords => switch (state) {
    'placed' => 'On the POS',
    'booked' => 'In the book',
    'kept' => isTable ? 'Not in the book' : 'Not on the POS',
    _ when kind == 'unreadable' => 'Could not be read',
    _ => isTable ? 'NOT IN THE BOOK' : 'NOT ON THE POS',
  };
}

/// Something that is wrong with the online orders right now, and stays so until it is mended.
class OnlineTrouble {
  const OnlineTrouble({
    this.code = '',
    this.sinceMs = 0,
    this.reason = '',
    this.urgent = false,
    this.count = 0,
    this.account = '',
    this.store = '',
    this.test = false,
  });

  factory OnlineTrouble.fromJson(Map<String, dynamic> json) => OnlineTrouble(
    code: oneLine(json['code']),
    sinceMs: _whole(json['since_ms']) ?? 0,
    reason: oneLine(json['reason']),
    urgent: json['urgent'] == true,
    count: _whole(json['count']) ?? 0,
    account: oneLine(json['account']),
    store: oneLine(json['store']),
    test: json['test'] == true,
  );

  /// Which of the restaurant's accounts does not answer, where it has several: its id, the name the
  /// restaurant gave it, and whether it is the one for testing. Empty where the hub asks one account.
  final String account;
  final String store;
  final bool test;

  /// The account in a few words, for a sentence: "Sushi site", "the first account"; null where the hub
  /// asks one account only and the trouble is of the online orders altogether.
  String? get _whose => account.isEmpty ? null : (store.isEmpty ? 'the first account' : store);

  final String code; // not_answering | pushes_refused
  final int sinceMs;

  /// Why, in the hub's few words.
  final String reason;

  /// No order is reaching the POS.
  final bool urgent;

  /// How many pushes were turned away (`pushes_refused`).
  final int count;

  /// What is wrong, in a few words: the alert's line and the head of its box.
  String get headline => switch (code) {
    'not_answering' when urgent && _whose != null => 'Online orders of $_whose are not reaching the POS',
    'not_answering' when urgent => 'Online orders are not reaching the POS',
    'not_answering' when _whose != null => 'GloriaFood does not answer the hub for $_whose',
    'not_answering' => 'GloriaFood does not answer the hub',
    'pushes_refused' => 'Online orders arrive a minute late',
    _ => 'Online orders: something is wrong',
  };

  /// The whole of it, with what to do.
  String get words {
    final since = sinceMs > 0 ? ' since ${clockTime(sinceMs)}' : '';
    final why = reason.isEmpty ? '' : ' ($reason)';
    final whose = _whose;
    return switch (code) {
      'not_answering' when urgent && whose != null =>
        'GloriaFood has not answered the hub for $whose$since$why. Until it does, look for that account\'s new '
            'orders in GloriaFood\'s own app and ring them in by hand. The other accounts are not affected.',
      'not_answering' when urgent =>
        'GloriaFood has not answered the hub$since$why. Until it does, look for new orders in GloriaFood\'s own '
            'app and ring them in by hand.',
      'not_answering' when whose != null && test =>
        'GloriaFood has not answered the hub for $whose, the account for testing,$since$why. No customer\'s '
            'order is held up by it.',
      'not_answering' when whose != null =>
        'The hub\'s asking for $whose has had no answer$since$why. Its orders still arrive, sent by GloriaFood, '
            'but nothing catches one that gets lost on the way.',
      'not_answering' =>
        'The hub\'s asking has had no answer$since$why. Orders still arrive, sent by GloriaFood, but nothing '
            'catches one that gets lost on the way.',
      'pushes_refused' =>
        'Orders arrive only by the hub\'s asking, once a minute: $count sent by GloriaFood ${count == 1 ? 'was' : 'were'} '
            'turned away$why. The key in GloriaFood\'s admin is probably not the one on the hub.',
      _ => reason.isEmpty ? 'The hub says something is wrong with the online orders.' : reason,
    };
  }
}

/// One of the restaurant's accounts with GloriaFood, as the hub says how its asking goes (`accounts` of
/// `GET /online/status`, and of what `POST /online/fetch` answers).
class OnlineAccountAsked {
  const OnlineAccountAsked({
    this.id = '',
    this.name = '',
    this.test = false,
    this.asks = false,
    this.answered = false,
    this.answeredMs,
    this.reason = '',
    this.came = 0,
  });

  /// As the status lists it: whether the hub has its key, when it last answered and why it does not.
  factory OnlineAccountAsked.ofStatus(Map<String, dynamic> json) {
    final failure = json['last_failure'] is Map ? json['last_failure'] as Map : null;
    return OnlineAccountAsked(
      id: oneLine(json['id']),
      name: oneLine(json['name']),
      test: json['test'] == true,
      asks: json['configured'] == true,
      answered: failure == null && _whole(json['answered_ms']) != null,
      answeredMs: _whole(json['answered_ms']),
      reason: oneLine(failure?['reason']),
      came: _whole(json['came']) ?? 0,
    );
  }

  /// As an asking out of turn says it: whether it answered just now, why not, and how many orders it gave.
  factory OnlineAccountAsked.ofAsking(Map<String, dynamic> json) => OnlineAccountAsked(
    id: oneLine(json['id']),
    name: oneLine(json['name']),
    asks: true,
    answered: json['answered'] == true,
    reason: oneLine(json['reason']),
    came: _whole(json['came']) ?? 0,
  );

  final String id;

  /// What the restaurant calls it; the first account may have no name.
  final String name;
  final bool test;

  /// The hub has its key and asks it every minute.
  final bool asks;

  /// It answered the last asking; [reason] is why it did not.
  final bool answered;
  final int? answeredMs;
  final String reason;

  /// How many orders it brought: today, or in this asking.
  final int came;

  String get called => name.isNotEmpty ? name : 'First account';

  /// How its asking stands, for a line under "Asked for by the hub".
  String get words {
    if (!asks) return 'no key';
    if (reason.isNotEmpty) return reason;
    final at = answeredMs;
    return at == null ? 'not asked yet' : 'answered ${clockTime(at)}';
  }
}

/// What came of asking the website for orders now, out of the hub's own turn (`POST /online/fetch`: the
/// button "Ask now" on the screen Online orders). Nothing of a customer.
class OnlineAsked {
  const OnlineAsked({
    this.asked = false,
    this.soon = false,
    this.answered = false,
    this.reason = '',
    this.came = 0,
    this.known = 0,
    this.placed = 0,
    this.booked = 0,
    this.kept = 0,
    this.failed = 0,
    this.status,
    this.accounts = const [],
  });

  factory OnlineAsked.fromJson(Map<String, dynamic> json) {
    int count(Object? value) => _whole(value) ?? 0;
    final status = json['status'] is Map ? (json['status'] as Map).cast<String, dynamic>() : null;
    final asked = json['asked'] == true;
    // a hub from before the button says only that it asked: whether the website answered is then read off
    // the status that came with it
    final failure = status?['last_failure'] is Map ? status!['last_failure'] as Map : null;
    return OnlineAsked(
      asked: asked,
      soon: json['soon'] == true,
      answered: json['answered'] is bool ? json['answered'] == true : asked && failure == null,
      reason: oneLine(json.containsKey('reason') ? json['reason'] : failure?['reason']),
      came: count(json['came']),
      known: count(json['known']),
      placed: count(json['placed']),
      booked: count(json['booked']),
      kept: count(json['kept']),
      failed: count(json['failed']),
      status: status == null ? null : OnlineStatus.fromJson(status),
      accounts: [
        for (final row in json['accounts'] is List ? json['accounts'] as List : const [])
          if (row is Map) OnlineAccountAsked.ofAsking(row.cast<String, dynamic>()),
      ],
    );
  }

  /// Each of the restaurant's accounts by itself, where the hub asks several: whether it answered, why not,
  /// and how many orders it gave. Empty where the hub asks one.
  final List<OnlineAccountAsked> accounts;

  /// What this asking came to for one account, as a sentence: for trying that account's key. Null where
  /// the hub did not say each account by itself.
  String? wordsFor(String id) {
    final account = accounts.where((row) => row.id == id).firstOrNull;
    if (account == null) return null;
    if (!account.answered) return account.reason.isEmpty ? 'GloriaFood did not answer.' : '${account.reason}.';
    return account.came == 0
        ? 'GloriaFood answered: no new order. The key works.'
        : 'GloriaFood answered: ${account.came == 1 ? '1 order came' : '${account.came} orders came'}. The key works.';
  }

  /// Whether one account answered this asking; null where the hub did not say each by itself.
  bool? answeredFor(String id) => accounts.where((row) => row.id == id).firstOrNull?.answered;

  /// The website was asked. Not when it was asked a few seconds ago ([soon]), and not by a hub that cannot
  /// write orders down.
  final bool asked;

  /// It was asked so shortly before that the hub left it alone this time.
  final bool soon;

  /// It answered, and [reason] is why it did not.
  final bool answered;
  final String reason;

  /// How many orders it gave, and how many of them the hub had already.
  final int came;
  final int known;

  /// What the hub did just now with every order it had waiting: put on the POS, a booked table written into
  /// the reservation book, nothing the POS takes, could not be put on.
  final int placed;
  final int booked;
  final int kept;
  final int failed;

  /// How the online orders stand after it.
  final OnlineStatus? status;

  /// Something went wrong, or is left for a person.
  bool get bad => asked && (!answered || failed > 0);

  /// What to tell whoever asked.
  String get words {
    if (soon) return 'GloriaFood was asked a few seconds ago. Wait a moment and ask again.';
    if (!asked) return 'This hub cannot write orders down now, so it asked for none.';
    final did = [
      if (placed > 0) '$placed put on the POS',
      if (booked > 0) '$booked put in the reservation book',
      if (kept > 0) '$kept not for the POS',
      if (failed > 0) '$failed could not be put on (see To look at)',
    ].join(', ');
    final after = did.isEmpty ? '' : ' $did.';
    if (!answered) {
      final why = reason.isEmpty ? 'GloriaFood did not answer' : reason;
      return '$why. The hub asks again by itself within the minute.$after';
    }
    if (came == 0) return 'GloriaFood has no new order.$after';
    final here = known == 0
        ? ''
        : known < came
        ? ', $known of them here already'
        : came == 1
        ? ', and it was here already'
        : ', all of them here already';
    return '${came == 1 ? '1 order came' : '$came orders came'}$here.$after';
  }
}

/// How the online orders are doing, as the hub says it (`GET /online/status`): how they arrive, today's by
/// what became of them, the ones to look at, and what is wrong right now. Nothing of a customer.
class OnlineStatus {
  const OnlineStatus({
    this.asks = false,
    this.running = false,
    this.writable = true,
    this.answeredMs,
    this.takesPushes = false,
    this.pushedMs,
    this.came = 0,
    this.byPush = 0,
    this.byPoll = 0,
    this.placed = 0,
    this.booked = 0,
    this.kept = 0,
    this.failed = 0,
    this.unread = 0,
    this.waiting = 0,
    this.look = const [],
    this.news = 0,
    this.trouble = const [],
    this.accounts = const [],
  });

  factory OnlineStatus.fromJson(Map<String, dynamic> json) {
    int count(Object? value) => _whole(value) ?? 0;
    List<Object?> rows(Object? value) => value is List ? value : const [];
    final push = json['push'] is Map ? json['push'] as Map : const <String, dynamic>{};
    final today = json['today'] is Map ? json['today'] as Map : const <String, dynamic>{};
    final look = [
      for (final row in rows(json['look']))
        if (row is Map) OnlineLook.fromJson(row.cast<String, dynamic>()),
    ];
    return OnlineStatus(
      asks: json['configured'] == true,
      running: json['running'] == true,
      writable: json['writable'] != false,
      answeredMs: _whole(json['answered_ms']),
      takesPushes: push['configured'] == true,
      pushedMs: _whole(push['pushed_ms']),
      came: count(today['came']),
      byPush: count(today['by_push']),
      byPoll: count(today['by_poll']),
      placed: count(today['placed']),
      booked: count(today['booked']),
      kept: count(today['kept']),
      failed: count(today['failed']),
      unread: count(today['unread']),
      waiting: count(json['waiting']),
      look: look,
      // a hub older than the count says which are new on none of them: nothing alerts
      news: json['news'] is num ? count(json['news']) : look.where((row) => row.isNew).length,
      trouble: [
        for (final row in rows(json['trouble']))
          if (row is Map) OnlineTrouble.fromJson(row.cast<String, dynamic>()),
      ],
      accounts: [
        for (final row in rows(json['accounts']))
          if (row is Map) OnlineAccountAsked.ofStatus(row.cast<String, dynamic>()),
      ],
    );
  }

  /// The restaurant's accounts with GloriaFood, the first account first, each with how its asking goes;
  /// empty on a hub from before there could be several.
  final List<OnlineAccountAsked> accounts;

  /// The accounts worth a line each: there are several, so "GloriaFood answered" needs saying of each.
  List<OnlineAccountAsked> get severalAccounts => accounts.length > 1 ? accounts : const [];

  /// The hub asks the website for orders every minute (it has the key for that).
  final bool asks;

  /// Its minute's round is running.
  final bool running;

  /// This hub can write orders down (a standby cannot, and takes none).
  final bool writable;

  /// When the website last answered the hub's asking.
  final int? answeredMs;

  /// The hub takes orders the website sends by itself (it has the key for those).
  final bool takesPushes;

  /// When the website last sent one.
  final int? pushedMs;

  // Today's orders, by what became of them and by how they came first. [booked] are the tables booked on
  // the website that went into the reservation book.
  final int came;
  final int byPush;
  final int byPoll;
  final int placed;
  final int booked;
  final int kept;
  final int failed;

  /// What the website sent today that could not be read.
  final int unread;

  /// Still to be put on the POS.
  final int waiting;

  /// The ones a person should look at, the newest first.
  final List<OnlineLook> look;

  /// How many of them nobody has looked at yet.
  final int news;

  /// What is wrong right now.
  final List<OnlineTrouble> trouble;

  /// Online orders are set up on this hub at all.
  bool get isOn => asks || takesPushes;

  /// The trouble that stops orders reaching the POS, when there is one.
  OnlineTrouble? get urgent => trouble.where((row) => row.urgent).firstOrNull;

  /// What a manager's screen is alerted to, in one line: that no order is reaching the POS, or how many
  /// there are to look at. Null while there is nothing to alert anybody to.
  String? get alert {
    final urgent = this.urgent;
    if (urgent != null) {
      final since = urgent.sinceMs > 0 ? ' since ${clockTime(urgent.sinceMs)}' : '';
      return '${urgent.headline}$since';
    }
    // not all of them are orders: something the website sent that could not be read is one too
    if (news > 0) return 'Online orders: $news to look at';
    return null;
  }

  /// One line for the row under Location.
  String get summary {
    if (!isOn) return 'Off: the hub has no key from GloriaFood';
    final alert = this.alert;
    if (alert != null) return alert;
    final late = trouble.firstOrNull;
    if (late != null) return late.headline;
    if (!writable) return 'This hub is the standby: it takes no online orders now';
    if (asks && !running) return 'The hub has stopped asking GloriaFood: sudo hubctl restart';
    final tables = booked == 0 ? '' : ', $booked in the reservation book';
    final today = came == 0 ? 'None yet today' : 'Today $came came, $placed on the POS$tables';
    return look.isEmpty ? today : '$today · ${look.length} to look at';
  }
}
