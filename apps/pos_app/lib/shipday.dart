/// Shipday's deliveries and drivers, as the hub last heard of them (docs/shipday.md). The restaurant's
/// delivery orders are dispatched in Shipday: a driver is given each one there and says in Shipday's app
/// how far along it is. The hub asks Shipday for them with the restaurant's own key and says beside each
/// which check on the POS it is.
///
/// Four things can be changed there from here by a person's tap: a delivery is given to a driver, taken back
/// from one, marked as it goes, and said to be ready for pickup ([ShipdayChanged]). The first three never
/// happen by themselves. The last the hub also does by itself where the location has it so
/// ([ShipdayBoard.tellsReady]): a delivery whose check is marked Ready on the POS is told to Shipday as ready
/// for pickup, once, and its card then says when ([ShipdayOrder.toldReady]).
///
/// The other way, the hub follows Shipday by itself where the location has it so ([ShipdayBoard.movesChecks]):
/// a delivery picked up there takes its check Out here, and one delivered there closes it unless money is
/// still due. What Shipday last said is on the check ([ShipdaySaid]), for a screen to say beside it.
library;

import 'phone.dart' show formatPhoneNumber;
import 'takeout.dart' show clockTime;

int? _whole(Object? value) => value is num && value.isFinite ? value.toInt() : null;

String _text(Object? value) => value is String ? value : '';

/// "1 driver", "3 drivers".
String _counted(int count, String one, String many) => count == 1 ? '1 $one' : '$count $many';

/// Shipday's words for where a delivery stands, as its own apps show them. A word this build does not know
/// says so and guesses nothing.
String shipdayStateWords(String state) => switch (state) {
  'NOT_ASSIGNED' => 'No driver yet',
  'NOT_ACCEPTED' => 'Not accepted yet',
  'NOT_STARTED_YET' => 'Accepted',
  'STARTED' => 'Started',
  'PICKED_UP' => 'Picked up',
  'READY_TO_DELIVER' => 'Ready to deliver',
  'ALREADY_DELIVERED' => 'Delivered',
  'FAILED_DELIVERY' => 'Failed',
  'INCOMPLETE' => 'Incomplete',
  'GONE' => 'No longer listed',
  _ => 'Shipday does not say',
};

/// What a delivery can be marked as, in Shipday's own words and in the order a delivery goes. The last three
/// end it ([shipdayEnds]).
const shipdaySteps = ['STARTED', 'PICKED_UP', 'READY_TO_DELIVER', 'ALREADY_DELIVERED', 'FAILED_DELIVERY', 'INCOMPLETE'];

/// The marks that end a delivery: it leaves Shipday's list of active ones.
const shipdayEnds = {'ALREADY_DELIVERED', 'FAILED_DELIVERY', 'INCOMPLETE'};

/// Whether a driver's id on a check is one of Shipday's drivers (`shipday:501`, or `shipday` for one Shipday
/// did not name): nobody of the POS's own staff. The hub writes it when Shipday takes a check Out.
bool isShipdayDriver(String driverId) => driverId == 'shipday' || driverId.startsWith('shipday:');

/// A driver by name as a check says who has it: "Tom Reyes (Shipday)" for one of Shipday's, so nobody takes
/// them for the Tom on the POS's own staff.
String driverCalled(String name, String driverId) => isShipdayDriver(driverId) ? '$name (Shipday)' : name;

/// What Shipday last said of a delivery, as the hub wrote it onto its check (the order's field `shipday`,
/// docs/shipday.md, "Shipday moves the check"). Only the hub writes it.
class ShipdaySaid {
  const ShipdaySaid({required this.state, this.atMs, this.id, this.number = ''});

  static ShipdaySaid? of(Object? json) {
    if (json is! Map) return null;
    final state = _text(json['state']);
    if (state.isEmpty) return null;
    return ShipdaySaid(
      state: state,
      atMs: _whole(json['at_ms']),
      id: _whole(json['id']),
      number: _text(json['number']),
    );
  }

  /// Shipday's word for where the delivery stood: `PICKED_UP`, `ALREADY_DELIVERED`, `FAILED_DELIVERY` or
  /// `INCOMPLETE`.
  final String state;

  /// When (ms): the moment Shipday named where the hub could take its word for it, else when the hub heard.
  final int? atMs;

  /// Shipday's own id and number for the delivery.
  final int? id;
  final String number;

  bool get delivered => state == 'ALREADY_DELIVERED';
  bool get pickedUp => state == 'PICKED_UP';

  /// "Shipday: delivered 6:55 PM", "Shipday: failed 7:02 PM".
  String get words =>
      ['Shipday: ${shipdayStateWords(state).toLowerCase()}', if (atMs != null) clockTime(atMs!)].join(' ');
}

/// What a screen says beside an open delivery of what Shipday said of it, where that is more than the check
/// says itself: "Shipday: delivered 6:55 PM" on one that stays open for its money, "Shipday: failed 7:02 PM",
/// "Shipday: picked up 6:40 PM" on one the POS never sent out. Null where there is nothing to add: Shipday
/// said nothing, the check is closed or marked delivered, or it is out as Shipday said.
String? shipdaySaysBeside(ShipdaySaid? said, {required bool open, required String stage}) {
  if (said == null || !open || stage == 'picked_up') return null;
  if (said.pickedUp && stage == 'out') return null;
  return said.words;
}

/// What the screen says once a delivery was marked: "Marked picked up."
String shipdayMarkedWords(String step) => 'Marked ${shipdayStateWords(step).toLowerCase()}.';

/// Why an asking of Shipday got no answer, for a person: what is wrong, and what to do about it.
String shipdayTroubleWords(String reason, String said) => switch (reason) {
  'refused' =>
    'Shipday refused the key. Copy it again from Shipday (My Account) and replace it under Location, Keys '
        'and connections.',
  'limit' => 'Shipday says it is being asked too often. The hub waits before it asks again.',
  'unreachable' => 'Shipday is not answering. The hub may have no way out to the internet right now.',
  'slow' => 'Shipday is taking too long to answer.',
  'unreadable' => 'Shipday answered something the hub could not read.',
  _ => said.trim().isEmpty ? 'Shipday did not answer.' : 'Shipday did not answer: ${said.trim()}.',
};

/// The driver a delivery was given to, as far as the delivery says.
class ShipdayCarrier {
  const ShipdayCarrier({required this.id, this.name = '', this.phone = ''});

  static ShipdayCarrier? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = _whole(json['id']);
    if (id == null) return null;
    return ShipdayCarrier(id: id, name: _text(json['name']), phone: _text(json['phone']));
  }

  final int id;
  final String name;
  final String phone;

  /// What to call them: a driver Shipday names by a number only is "Driver 501".
  String get called => name.trim().isEmpty ? 'Driver $id' : name.trim();
}

/// A driver of the Shipday account.
class ShipdayDriver {
  const ShipdayDriver({
    required this.id,
    this.name = '',
    this.phone = '',
    this.onShift = false,
    this.active = true,
    this.orders = 0,
  });

  static ShipdayDriver? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = _whole(json['id']);
    if (id == null) return null;
    return ShipdayDriver(
      id: id,
      name: _text(json['name']),
      phone: _text(json['phone']),
      onShift: json['on_shift'] == true,
      active: json['active'] != false,
      orders: _whole(json['orders']) ?? 0,
    );
  }

  final int id;
  final String name;
  final String phone;

  /// They said in Shipday's app that they are working now.
  final bool onShift;

  /// The account has not switched them off.
  final bool active;

  /// How many deliveries that are not finished they have.
  final int orders;

  String get called => name.trim().isEmpty ? 'Driver $id' : name.trim();
}

/// The check on the POS a delivery in Shipday is.
class ShipdayCheck {
  const ShipdayCheck({required this.orderId, this.orderNo, this.status = 'open', this.stage = '', this.by = ''});

  static ShipdayCheck? fromJson(Object? json) {
    if (json is! Map) return null;
    final orderId = _text(json['order_id']);
    if (orderId.isEmpty) return null;
    return ShipdayCheck(
      orderId: orderId,
      orderNo: _whole(json['order_no']),
      status: json['status'] is String ? json['status'] as String : 'open',
      stage: _text(json['stage']),
      by: _text(json['by']),
    );
  }

  final String orderId;
  final int? orderNo;

  /// `open`, `closed` or `void`.
  final String status;
  final String stage;

  /// How the hub told the two are one: `number` (the website's number for the order is on both) or `phone`
  /// (the customer's phone number is).
  final String by;

  /// "Check #12", or "Its check" where the hub gave it no number yet.
  String get named => orderNo == null ? 'Its check' : 'Check #$orderNo';

  /// "Check #12", and what became of it where it is open no longer, or that it is out with a driver.
  String get words {
    final check = named;
    return switch (status) {
      'void' => '$check · voided',
      'closed' => '$check · closed',
      _ when stage == 'out' => '$check · out',
      _ when stage == 'ready' => '$check · ready',
      _ => check,
    };
  }
}

/// What the location says of Shipday (`GET /settings/shipday`, Location).
class ShipdaySetting {
  const ShipdaySetting({required this.movesChecks, this.tellsReady});

  factory ShipdaySetting.fromJson(Map<String, dynamic> json) => ShipdaySetting(
    movesChecks: json['moves_checks'] as bool? ?? true,
    tellsReady: json['tells_ready'] is bool ? json['tells_ready'] as bool : null,
  );

  /// What Shipday says of a delivery moves its check on the POS.
  final bool movesChecks;

  /// A delivery's check marked Ready on the POS tells Shipday it is ready for pickup. Null from a hub older
  /// than that, which tells Shipday only when somebody taps Ready for pickup.
  final bool? tellsReady;
}

/// One delivery as Shipday has it.
class ShipdayOrder {
  const ShipdayOrder({
    required this.id,
    this.number = '',
    this.state = 'UNKNOWN',
    this.name = '',
    this.address = '',
    this.phone = '',
    this.driver,
    this.placedMs,
    this.dueMs,
    this.assignedMs,
    this.startedMs,
    this.pickedUpMs,
    this.arrivedMs,
    this.deliveredMs,
    this.endedMs,
    this.etaMs,
    this.etaSaid = '',
    this.total,
    this.payment = '',
    this.items = 0,
    this.note = '',
    this.scheduled = false,
    this.check,
    this.steps = const [],
    this.readyMs,
    this.canReady = false,
  });

  static ShipdayOrder? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = _whole(json['id']);
    if (id == null) return null;
    return ShipdayOrder(
      id: id,
      number: _text(json['number']),
      state: json['state'] is String ? json['state'] as String : 'UNKNOWN',
      name: _text(json['name']),
      address: _text(json['address']),
      phone: _text(json['phone']),
      driver: ShipdayCarrier.fromJson(json['driver']),
      placedMs: _whole(json['placed_ms']),
      dueMs: _whole(json['due_ms']),
      assignedMs: _whole(json['assigned_ms']),
      startedMs: _whole(json['started_ms']),
      pickedUpMs: _whole(json['picked_up_ms']),
      arrivedMs: _whole(json['arrived_ms']),
      deliveredMs: _whole(json['delivered_ms']),
      endedMs: _whole(json['ended_ms']),
      etaMs: _whole(json['eta_ms']),
      etaSaid: _text(json['eta_said']),
      total: json['total'] is String ? json['total'] as String : null,
      payment: _text(json['payment']),
      items: _whole(json['items']) ?? 0,
      note: _text(json['note']),
      scheduled: json['scheduled'] == true,
      check: ShipdayCheck.fromJson(json['pos']),
      // a word this build has no button for is left out: nothing is offered that it cannot name
      steps: [
        for (final step in json['steps'] is List ? json['steps'] as List : const [])
          if (step is String && shipdaySteps.contains(step)) step,
      ],
      readyMs: _whole(json['ready_ms']),
      canReady: json['can_ready'] == true,
    );
  }

  /// Shipday's own id for it, and the number Shipday's apps show it by.
  final int id;
  final String number;

  /// Where it stands, in Shipday's own word (`NOT_ASSIGNED`, `PICKED_UP`, ...); `UNKNOWN` for a word the
  /// hub does not know, `GONE` for one that left Shipday's list without Shipday saying what became of it.
  final String state;
  final String name;
  final String address;
  final String phone;

  /// Who has it; null while nobody does.
  final ShipdayCarrier? driver;

  /// Its times on the terminal's clock, each null until it happened.
  final int? placedMs;
  final int? dueMs;
  final int? assignedMs;
  final int? startedMs;
  final int? pickedUpMs;
  final int? arrivedMs;
  final int? deliveredMs;

  /// When it left Shipday's list of active deliveries; only on the ones that have.
  final int? endedMs;

  /// It is among the ones that finished today.
  bool get finished => endedMs != null;

  /// When Shipday expects it at the customer's, or what Shipday wrote instead of a time.
  final int? etaMs;
  final String etaSaid;

  /// What the customer pays in all, as Shipday has it ("42.75"); null where Shipday gave none.
  final String? total;

  /// `CASH`, `CREDIT_CARD`, or whatever else Shipday wrote.
  final String payment;
  final int items;

  /// The note for the driver.
  final String note;

  /// It was placed for a later time.
  final bool scheduled;

  /// The check it is on the POS; null where the hub found none.
  final ShipdayCheck? check;

  /// What it can be marked as from where it stands, as the hub says: Shipday's own words, in the order a
  /// delivery goes. Empty from a hub that marks nothing, and for one that is finished.
  final List<String> steps;

  /// It can be marked as something from where it stands.
  bool get canBeMarked => !finished && steps.isNotEmpty;

  /// When this hub told Shipday that it is ready for pickup (the food is made and waits for its driver);
  /// null where it did not. Shipday's own list never says so: this is the hub's word, kept for the day and
  /// forgotten when the hub restarts.
  final int? readyMs;

  /// The hub would tell Shipday that it is ready for pickup: it was not picked up yet, and this hub has not
  /// said so already. False from a hub older than that.
  final bool canReady;

  /// It can be said to be ready for pickup.
  bool get canBeSaidReady => !finished && canReady;

  /// "Ready for pickup · told 6:12 PM", once this hub told Shipday; null before.
  String? get toldReady => readyMs == null ? null : 'Ready for pickup · told ${clockTime(readyMs!)}';

  bool get needsDriver => state == 'NOT_ASSIGNED';
  bool get onItsWay => state == 'PICKED_UP' || state == 'READY_TO_DELIVER';
  bool get withDriver => state == 'NOT_ACCEPTED' || state == 'NOT_STARTED_YET' || state == 'STARTED';

  /// Nobody has it, so it can be given to a driver.
  bool get canBeGiven => !finished && needsDriver && driver == null;

  /// A driver has it and has not picked it up, so it can still be taken back.
  bool get canBeTakenBack => !finished && withDriver && driver != null;

  /// The customer's name, or the number Shipday shows it by where it has no name.
  String get title {
    final who = name.trim();
    if (who.isNotEmpty) return who;
    return number.isEmpty ? 'No name' : 'Order $number';
  }

  /// Who has it and the last thing that happened to it: "Tom Reyes · picked up 18:20".
  String get progress {
    final who = driver?.called;
    final (word, at) = switch (state) {
      'NOT_ASSIGNED' => ('placed', placedMs),
      'NOT_ACCEPTED' => ('offered', assignedMs),
      'NOT_STARTED_YET' => ('given', assignedMs),
      'STARTED' => ('started', startedMs),
      'PICKED_UP' => ('picked up', pickedUpMs),
      'READY_TO_DELIVER' => ('arrived', arrivedMs),
      'ALREADY_DELIVERED' => ('delivered', deliveredMs ?? endedMs),
      // Shipday gives no time for these: when the hub saw it gone from the list, which is close
      'FAILED_DELIVERY' => ('failed about', endedMs),
      'INCOMPLETE' => ('ended about', endedMs),
      _ => ('off the list about', endedMs),
    };
    return [
      if (who != null) who else if (needsDriver) 'No driver',
      if (at != null) '$word ${clockTime(at)}',
    ].join(' · ');
  }

  /// When it is expected at the customer's, where Shipday says: "there about 18:38".
  String? get expected {
    if (etaMs != null) return 'there about ${clockTime(etaMs!)}';
    if (etaSaid.trim().isNotEmpty) return 'Shipday says ${etaSaid.trim()}';
    return null;
  }

  /// The customer's number, what they pay and how, and when they want it.
  String get facts => [
    if (phone.trim().isNotEmpty) formatPhoneNumber(phone),
    if (total != null)
      switch (payment.toUpperCase()) {
        'CASH' => '\$$total cash',
        'CREDIT_CARD' || 'CARD' => '\$$total card',
        _ => '\$$total',
      },
    if (dueMs != null) 'wanted for ${clockTime(dueMs!)}',
  ].join(' · ');
}

/// Why the last asking of Shipday got no answer.
class ShipdayTrouble {
  const ShipdayTrouble({this.sinceMs, this.reason = '', this.said = ''});

  static ShipdayTrouble? fromJson(Object? json) {
    if (json is! Map) return null;
    return ShipdayTrouble(sinceMs: _whole(json['since_ms']), reason: _text(json['reason']), said: _text(json['said']));
  }

  final int? sinceMs;

  /// `refused`, `limit`, `unreachable`, `slow`, `error` or `unreadable`.
  final String reason;
  final String said;

  String get words => shipdayTroubleWords(reason, said);
}

/// Shipday's deliveries and drivers as the hub last heard of them (`GET /shipday`).
class ShipdayBoard {
  const ShipdayBoard({
    this.on = false,
    this.read = false,
    this.trouble,
    this.eta = 'off',
    this.can = const {},
    this.movesChecks = false,
    this.tellsReady = false,
    this.orders = const [],
    this.done = const [],
    this.drivers = const [],
  });

  factory ShipdayBoard.fromJson(Map<String, dynamic> json) => ShipdayBoard(
    on: json['on'] == true,
    read: json['read'] == true,
    trouble: ShipdayTrouble.fromJson(json['trouble']),
    eta: json['eta'] is String ? json['eta'] as String : 'off',
    can: {...(json['can'] is List ? json['can'] as List : const []).whereType<String>()},
    movesChecks: json['moves_checks'] == true,
    tellsReady: json['tells_ready'] == true,
    orders: [for (final row in json['orders'] is List ? json['orders'] as List : const []) ?ShipdayOrder.fromJson(row)],
    done: [for (final row in json['done'] is List ? json['done'] as List : const []) ?ShipdayOrder.fromJson(row)],
    drivers: [
      for (final row in json['drivers'] is List ? json['drivers'] as List : const []) ?ShipdayDriver.fromJson(row),
    ],
  );

  /// The hub has a key for Shipday.
  final bool on;

  /// Shipday has answered at least once since the hub started, or since the key was typed.
  final bool read;

  /// Null, or why the last asking got no answer: the rest is then as it was last heard.
  final ShipdayTrouble? trouble;

  /// Whether Shipday says how far away a delivery is: `off` (not asked yet), `on`, or `plan` (the account's
  /// plan with Shipday does not include it).
  final String eta;

  /// What this hub changes in Shipday when a person asks. Empty from a hub that only reads.
  final Set<String> can;

  /// The hub gives a delivery to a driver and takes it back.
  bool get givesToDrivers => can.contains('driver');

  /// The hub marks a delivery as it goes (started, picked up, delivered, ...).
  bool get marks => can.contains('status');

  /// The hub tells Shipday that a delivery is ready for pickup.
  bool get saysReady => can.contains('ready');

  /// What Shipday says of a delivery moves its check on the POS: picked up takes it Out, delivered closes it
  /// unless money is due (Location, "Shipday moves the check"). False from a hub older than that, and where
  /// the location turned it off.
  final bool movesChecks;

  /// A delivery's check marked Ready on the POS tells Shipday it is ready for pickup, by itself (Location,
  /// "Ready tells Shipday"). False from a hub older than that, and where the location turned it off: then
  /// Shipday is told only by the Ready for pickup button.
  final bool tellsReady;

  /// The deliveries that are not finished, as Shipday lists them.
  final List<ShipdayOrder> orders;

  /// The ones that left that list during this day of service, the last first.
  final List<ShipdayOrder> done;
  final List<ShipdayDriver> drivers;

  List<ShipdayOrder> get needDriver => [
    for (final order in orders)
      if (order.needsDriver) order,
  ];

  List<ShipdayOrder> get withDriver => [
    for (final order in orders)
      if (order.withDriver) order,
  ];

  List<ShipdayOrder> get onTheWay => [
    for (final order in orders)
      if (order.onItsWay) order,
  ];

  /// Deliveries Shipday lists as active in a state this build has no heading for.
  List<ShipdayOrder> get others => [
    for (final order in orders)
      if (!order.needsDriver && !order.withDriver && !order.onItsWay) order,
  ];

  /// The drivers who are working now, the ones with the fewest deliveries first: who can take the next one.
  List<ShipdayDriver> get onShift {
    final working = [
      for (final driver in drivers)
        if (driver.onShift && driver.active) driver,
    ];
    final place = {for (final (index, driver) in working.indexed) driver.id: index};
    return working..sort((a, b) {
      final byLoad = a.orders.compareTo(b.orders);
      return byLoad != 0 ? byLoad : place[a.id]!.compareTo(place[b.id]!);
    });
  }

  /// The drivers of the account who are not working now, by name.
  List<ShipdayDriver> get offShift => [
    for (final driver in drivers)
      if (driver.active && !driver.onShift) driver,
  ];

  /// A few words for the button that opens the screen; null while there is nothing to say.
  String? get note {
    final waiting = needDriver.length;
    if (waiting > 0) return waiting == 1 ? '1 needs a driver' : '$waiting need a driver';
    if (orders.isNotEmpty) return '${orders.length} out';
    return null;
  }
}

/// What asking Shipday now came to (the screen's button), with the picture after it.
class ShipdayAsked {
  const ShipdayAsked({
    this.asked = false,
    this.answered = false,
    this.soon = false,
    this.reason = '',
    this.said = '',
    this.board,
  });

  factory ShipdayAsked.fromJson(Map<String, dynamic> json) => ShipdayAsked(
    asked: json['asked'] == true,
    answered: json['answered'] == true,
    soon: json['soon'] == true,
    reason: _text(json['reason']),
    said: _text(json['said']),
    board: json['shipday'] is Map ? ShipdayBoard.fromJson((json['shipday'] as Map).cast<String, dynamic>()) : null,
  );

  final bool asked;
  final bool answered;

  /// Shipday was asked a few seconds ago, so it was not asked again.
  final bool soon;
  final String reason;
  final String said;
  final ShipdayBoard? board;

  bool get bad => !answered && !soon;

  String get words {
    if (soon) return 'Shipday was asked a moment ago. This is what it said.';
    if (answered) return 'Shipday answered. This is how it stands now.';
    return shipdayTroubleWords(reason, said);
  }
}

/// What came of a change a person asked for in Shipday (a delivery given to a driver, taken back, marked as
/// it goes, or said ready for pickup), with the picture after it. The hub reads Shipday's list before it
/// sends anything and again after.
class ShipdayChanged {
  const ShipdayChanged({
    this.done = false,
    this.sent = false,
    this.shown = false,
    this.reason = '',
    this.said = '',
    this.told = '',
    this.board,
  });

  factory ShipdayChanged.fromJson(Map<String, dynamic> json) => ShipdayChanged(
    done: json['done'] == true,
    sent: json['sent'] == true,
    shown: json['shown'] == true,
    reason: _text(json['reason']),
    said: _text(json['said']),
    told: _text(json['told']),
    board: json['shipday'] is Map ? ShipdayBoard.fromJson((json['shipday'] as Map).cast<String, dynamic>()) : null,
  );

  /// Shipday made the change, as far as it said or its list shows.
  final bool done;

  /// Shipday was asked to make it. False where the hub sent nothing: the delivery no longer stood as this
  /// screen showed it, or Shipday could not be asked first.
  final bool sent;

  /// Shipday's list, read after the change, shows it.
  final bool shown;

  /// Why not: the hub's word for it.
  final String reason;
  final String said;

  /// What Shipday itself said of a change it would not make.
  final String told;
  final ShipdayBoard? board;

  bool get bad => !done;

  /// What to tell the person who asked. [did] says the change as done ("Given to Tom Reyes."); [order] is
  /// the delivery as the picture after it has it, for who has it now and where it stands. [listed] is false
  /// for a change Shipday's list has no place for (ready for pickup): Shipday's own answer is then all there
  /// is to go by.
  String words(String did, {ShipdayOrder? order, bool listed = true}) {
    if (done) return shown || !listed ? did : 'Shipday took it. Its list does not show it yet.';
    final has = order?.driver?.called;
    final why = switch (reason) {
      'not_listed' => "It is no longer on Shipday's list.",
      'has_driver' => has == null ? 'It has a driver already.' : '$has has it already.',
      'no_driver' => 'Nobody has it any more.',
      'other_driver' => has == null ? 'Another driver has it now.' : '$has has it now.',
      'on_its_way' => 'It was picked up already.',
      'unsure' => 'Shipday says something of it this app does not know.',
      'unknown_driver' => 'Shipday no longer lists that driver.',
      'moved' =>
        order == null
            ? 'It stands elsewhere in Shipday by now.'
            : 'Shipday has it as "${shipdayStateWords(order.state)}" by now.',
      'not_a_step' => 'It cannot be marked as that from where it stands.',
      'no_key' => 'This hub has no key for Shipday.',
      'rejected' ||
      'not_found' => told.trim().isEmpty ? 'Shipday would not do it.' : 'Shipday would not do it: "${told.trim()}"',
      _ => shipdayTroubleWords(reason, said),
    };
    if (!sent) return '$why Nothing was changed.';
    // asked, and no word that it was done: the list read after it does not show it either
    return switch (reason) {
      'rejected' || 'not_found' => why,
      // no answer came, and nothing Shipday lists says whether it took: asking again does no harm
      _ when !listed => '$why It may not have been told. Tap again to be sure.',
      _ => "$why Shipday's list does not show the change.",
    };
  }
}

/// How the hub's asking of Shipday goes, for the page of its keys: no order and no customer in it.
class ShipdayAbout {
  const ShipdayAbout({
    this.on = false,
    this.running = false,
    this.answeredMs,
    this.trouble,
    this.eta = 'off',
    this.orders = 0,
    this.drivers = 0,
    this.onShift = 0,
  });

  factory ShipdayAbout.fromJson(Map<String, dynamic> json) => ShipdayAbout(
    on: json['on'] == true,
    running: json['running'] == true,
    answeredMs: _whole(json['answered_ms']),
    trouble: ShipdayTrouble.fromJson(json['trouble']),
    eta: json['eta'] is String ? json['eta'] as String : 'off',
    orders: _whole(json['orders']) ?? 0,
    drivers: _whole(json['drivers']) ?? 0,
    onShift: _whole(json['on_shift']) ?? 0,
  );

  final bool on;

  /// The hub asks by itself. False on a hub that only answers what it is asked, as a test's does.
  final bool running;
  final int? answeredMs;
  final ShipdayTrouble? trouble;
  final String eta;
  final int orders;
  final int drivers;
  final int onShift;

  /// What Shipday last listed: "3 deliveries out, 4 drivers, 2 on shift".
  static String listed(int orders, int drivers, int onShift) => [
    orders == 0 ? 'no delivery out' : _counted(orders, 'delivery out', 'deliveries out'),
    drivers == 0 ? 'no driver' : _counted(drivers, 'driver', 'drivers'),
    if (drivers > 0) '$onShift on shift',
  ].join(', ');

  /// How it stands, in a line; null while Shipday has not been asked yet.
  String? get words {
    final wrong = trouble;
    if (wrong != null) return wrong.words;
    if (answeredMs == null) return null;
    return 'Shipday last answered at ${clockTime(answeredMs!)}: ${listed(orders, drivers, onShift)}.';
  }

  /// What the account's plan leaves out, where Shipday said so.
  String? get planWords => eta == 'plan'
      ? "Shipday does not tell this account how far away a delivery is (it is part of Shipday's higher "
            'plans). Everything else is read.'
      : null;
}

/// What a try of the key came to: Shipday was asked once for its deliveries and its drivers.
class ShipdayTried {
  const ShipdayTried({required this.ok, this.reason = '', this.said = '', this.orders, this.drivers, this.onShift});

  factory ShipdayTried.fromJson(Map<String, dynamic> json) => ShipdayTried(
    ok: json['ok'] == true,
    reason: _text(json['reason']),
    said: _text(json['said']),
    orders: _whole(json['orders']),
    drivers: _whole(json['drivers']),
    onShift: _whole(json['on_shift']),
  );

  final bool ok;
  final String reason;
  final String said;
  final int? orders;
  final int? drivers;
  final int? onShift;

  bool get bad => !ok;

  String get words {
    if (!ok) return shipdayTroubleWords(reason, said);
    final listed = ShipdayAbout.listed(orders ?? 0, drivers ?? 0, onShift ?? 0);
    return 'Shipday answered: the key works. It lists $listed. Nothing was changed in Shipday.';
  }
}
