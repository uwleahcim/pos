/// A station's screen (docs/kitchen-screens.md): what the station has to make, as the hub lists it
/// (`GET /kitchen/screen`), in the words its paper tickets use; or the pass (`GET /kitchen/pass`), where
/// every station's dishes of a ticket stand together with what each station has made, and a mark says a dish
/// went out. Nothing here is worked out on the terminal but three things: what this screen itself just
/// marked and the hub has not shown yet, laid over what was read; how long each ticket has been in the
/// kitchen; and the all-day counts, how many of each dish its tickets still wait for.
library;

import 'takeout.dart';

/// One dish of a ticket, as the paper says it.
class KitchenLine {
  const KitchenLine({
    required this.lineId,
    this.stations = const [],
    this.made = const [],
    required this.qty,
    required this.label,
    this.modifiers = const [],
    this.depths = const [],
    this.note = '',
    this.seat,
    this.header = '',
    this.allergy = '',
    this.isVoid = false,
    this.changed = false,
    this.doneMs,
    this.cooks = const [],
  });

  factory KitchenLine.fromJson(Map<String, dynamic> json) => KitchenLine(
    lineId: json['line_id'] as String? ?? '',
    stations: [for (final station in json['stations'] as List? ?? const []) station.toString()],
    made: [for (final station in json['made'] as List? ?? const []) station.toString()],
    qty: (json['qty'] as num?)?.toInt() ?? 1,
    label: json['label'] as String? ?? '',
    modifiers: [for (final modifier in json['modifiers'] as List? ?? const []) modifier.toString()],
    depths: [for (final depth in json['depths'] as List? ?? const []) (depth as num).toInt()],
    note: json['note'] as String? ?? '',
    seat: (json['seat'] as num?)?.toInt(),
    header: json['header'] as String? ?? '',
    allergy: json['allergy'] as String? ?? '',
    isVoid: json['void'] == true,
    changed: json['changed'] == true,
    doneMs: (json['done_ms'] as num?)?.toInt(),
    cooks: [
      for (final cook in json['cooks'] as List? ?? const [])
        (
          code: (cook as Map)['code']?.toString() ?? '',
          name: (cook['name'] ?? cook['code'])?.toString() ?? '',
          made: cook['made'] == true,
        ),
    ],
  );

  /// The line of the order this stands for. A dish made of parts is several of these with one id.
  final String lineId;

  /// The stations of this screen that make it: what a mark names.
  final List<String> stations;

  /// The ones of [stations] that said it is made.
  final List<String> made;
  final int qty;
  final String label;
  final List<String> modifiers;

  /// How far in each of [modifiers] stands: 1 is a choice on the choice above it.
  final List<int> depths;
  final String note;
  final int? seat;

  /// The combination this is a part of ("Pu Pu Platter"), when it is one.
  final String header;

  /// The allergy told for this dish's seat.
  final String allergy;

  /// Voided after it was sent: struck out until the cook marks it seen.
  final bool isVoid;

  /// Changed after it was sent.
  final bool changed;
  final int? doneMs;

  /// At the pass: where it is cooked, and whether that station has made it. Empty on a station's screen.
  final List<({String code, String name, bool made})> cooks;

  /// Every station of this screen that makes it said so; at the pass, it went out.
  bool get done => stations.isNotEmpty && stations.every(made.contains);

  /// At the pass: nothing of it is still being cooked.
  bool get cooked => cooks.every((cook) => cook.made);

  KitchenLine _marked(String station, bool isMade, int atMs) {
    if (!stations.contains(station) || made.contains(station) == isMade) return this;
    final now = isMade
        ? [...made, station]
        : [
            for (final other in made)
              if (other != station) other,
          ];
    final all = stations.every(now.contains);
    return KitchenLine(
      lineId: lineId,
      stations: stations,
      made: now,
      qty: qty,
      label: label,
      modifiers: modifiers,
      depths: depths,
      note: note,
      seat: seat,
      header: header,
      allergy: allergy,
      isVoid: isVoid,
      changed: changed,
      doneMs: all ? atMs : null,
      cooks: cooks,
    );
  }
}

/// The dishes of one send of an order that this screen's stations make.
class KitchenTicket {
  const KitchenTicket({
    required this.id,
    required this.orderId,
    required this.sinceMs,
    this.table = '',
    this.tab = '',
    this.orderNo,
    this.customer = '',
    this.toGo = false,
    this.channel = '',
    this.promisedMs,
    this.server = '',
    this.guests,
    this.course = '',
    this.allergies = const [],
    this.alsoAt = const [],
    this.lines = const [],
    this.doneMs,
  });

  factory KitchenTicket.fromJson(Map<String, dynamic> json) => KitchenTicket(
    id: json['id'] as String? ?? '',
    orderId: json['order_id'] as String? ?? '',
    sinceMs: (json['since_ms'] as num?)?.toInt() ?? 0,
    table: json['table'] as String? ?? '',
    tab: json['tab'] as String? ?? '',
    orderNo: (json['order_no'] as num?)?.toInt(),
    customer: json['customer'] as String? ?? '',
    toGo: json['to_go'] == true,
    channel: json['channel'] as String? ?? '',
    promisedMs: (json['promised_ms'] as num?)?.toInt(),
    server: json['server'] as String? ?? '',
    guests: (json['guests'] as num?)?.toInt(),
    course: json['course'] as String? ?? '',
    allergies: [for (final told in json['allergies'] as List? ?? const []) told.toString()],
    alsoAt: [for (final station in json['also_at'] as List? ?? const []) station.toString()],
    lines: [
      for (final line in json['lines'] as List? ?? const [])
        KitchenLine.fromJson((line as Map).cast<String, dynamic>()),
    ],
    doneMs: (json['done_ms'] as num?)?.toInt(),
  );

  /// The order and the moment its dishes reached the kitchen: the same from one read to the next.
  final String id;
  final String orderId;

  /// Since when it is in the kitchen: what its minutes are counted from.
  final int sinceMs;
  final String table;
  final String tab;
  final int? orderNo;
  final String customer;
  final bool toGo;
  final String channel;
  final int? promisedMs;
  final String server;
  final int? guests;
  final String course;

  /// The allergies told on the order, as the paper heads a ticket with them.
  final List<String> allergies;

  /// The other stations cooking for the same send.
  final List<String> alsoAt;
  final List<KitchenLine> lines;

  /// When its last dish was marked; null while one is still to make.
  final int? doneMs;

  bool get done => lines.isNotEmpty && lines.every((line) => line.done);

  /// At the pass: every station has made its part of what has not gone out yet, so it is ready to go.
  bool get allMade {
    final waits = [
      for (final line in lines)
        if (!line.done && !line.isVoid) line,
    ];
    return waits.any((line) => line.cooks.isNotEmpty) && waits.every((line) => line.cooked);
  }

  /// Whose it is, as the head of the ticket says it: "Table 12", "Tab Mike", "#12 Linda".
  String get title {
    if (toGo) {
      final name = [if (orderNo != null) '#$orderNo', if (customer.isNotEmpty) customer].join(' ');
      return name.isEmpty ? 'To go' : name;
    }
    if (tab.isNotEmpty) return 'Tab $tab';
    return table.isEmpty ? 'No table' : 'Table $table';
  }

  /// The smaller line under it: "Amy · 4 guests · Mains", "Phone · ready 18:30".
  String get detail => [
    if (toGo && channel.isNotEmpty) channelLabel(channel),
    if (toGo && promisedMs != null) 'ready ${clockTime(promisedMs!)}',
    if (!toGo && server.isNotEmpty) server,
    if (!toGo && guests != null && guests! > 0) guests == 1 ? '1 guest' : '$guests guests',
    if (course.isNotEmpty) course,
  ].join(' · ');

  /// The whole minutes it has been in the kitchen at [now]; never below zero, whatever the clocks say.
  int minutes(DateTime now) {
    final passed = now.millisecondsSinceEpoch - sinceMs;
    return passed <= 0 ? 0 : passed ~/ 60000;
  }

  KitchenTicket _with(List<KitchenLine> now, int atMs) {
    final all = now.isNotEmpty && now.every((line) => line.done);
    return KitchenTicket(
      id: id,
      orderId: orderId,
      sinceMs: sinceMs,
      table: table,
      tab: tab,
      orderNo: orderNo,
      customer: customer,
      toGo: toGo,
      channel: channel,
      promisedMs: promisedMs,
      server: server,
      guests: guests,
      course: course,
      allergies: allergies,
      alsoAt: alsoAt,
      lines: now,
      doneMs: all ? (doneMs ?? atMs) : null,
    );
  }
}

/// After how many minutes in the kitchen a ticket turns amber ([warn]) and red ([late]) on every station's
/// screen, as the location has it; 0 for never.
class KitchenMinutes {
  const KitchenMinutes({this.warn = 10, this.late = 20});

  factory KitchenMinutes.fromJson(Map<String, dynamic> json) =>
      KitchenMinutes(warn: (json['warn'] as num?)?.toInt() ?? 10, late: (json['late'] as num?)?.toInt() ?? 20);

  final int warn;
  final int late;

  Map<String, dynamic> toJson() => {'warn': warn, 'late': late};

  /// "Amber after 10 min, red after 20 min"
  String get summary {
    if (warn == 0 && late == 0) return 'Tickets keep one colour however long they wait';
    final parts = [if (warn > 0) 'amber after $warn min', if (late > 0) 'red after $late min'].join(', ');
    return '${parts[0].toUpperCase()}${parts.substring(1)}';
  }
}

/// How a ticket stands against the location's minutes ([KitchenBoard.warn], [KitchenBoard.late]).
enum TicketAge { fresh, warn, late }

/// A station's screen as the hub lists it.
class KitchenBoard {
  const KitchenBoard({
    this.stations = const [],
    this.warn = 10,
    this.late = 20,
    this.tickets = const [],
    this.recent = const [],
    this.pass = false,
  });

  factory KitchenBoard.fromJson(Map<String, dynamic> json) {
    List<KitchenTicket> listed(String key) => [
      for (final ticket in json[key] as List? ?? const [])
        KitchenTicket.fromJson((ticket as Map).cast<String, dynamic>()),
    ];
    return KitchenBoard(
      stations: [
        for (final station in json['stations'] as List? ?? const [])
          (
            code: (station as Map)['code']?.toString() ?? '',
            name: (station['name'] ?? station['code'])?.toString() ?? '',
          ),
      ],
      warn: (json['warn'] as num?)?.toInt() ?? 10,
      late: (json['late'] as num?)?.toInt() ?? 20,
      tickets: listed('tickets'),
      recent: listed('recent'),
      pass: json['pass'] == true,
    );
  }

  /// How many finished tickets a screen keeps at hand, as the hub does.
  static const keeps = 10;

  final List<({String code, String name})> stations;

  /// The minutes after which a ticket turns amber and red; 0 for never.
  final int warn;
  final int late;

  /// The ones still to make, the longest in the kitchen first.
  final List<KitchenTicket> tickets;

  /// The last ones finished, the latest first.
  final List<KitchenTicket> recent;

  /// The pass: every ticket whole, with what each station has made. [stations] is then the ones it
  /// watches, or empty for all of them.
  final bool pass;

  /// "Wok", "Wok · Fryer": the screen's stations by their names. "The pass", "The pass · Wok · Fryer".
  String get title => [if (pass) 'The pass', for (final station in stations) station.name].join(' · ');

  /// The all-day counts: how many of each dish the tickets on this screen still wait for, the most first.
  /// A dish made (at the pass: gone out) or voided is not counted.
  List<({String label, int qty})> get counts {
    final sums = <String, int>{};
    for (final ticket in tickets) {
      for (final line in ticket.lines) {
        if (!line.done && !line.isVoid) sums[line.label] = (sums[line.label] ?? 0) + line.qty;
      }
    }
    return [for (final MapEntry(key: label, value: qty) in sums.entries) (label: label, qty: qty)]
      ..sort((a, b) => a.qty != b.qty ? b.qty.compareTo(a.qty) : a.label.compareTo(b.label));
  }

  TicketAge age(KitchenTicket ticket, DateTime now) {
    final minutes = ticket.minutes(now);
    if (late > 0 && minutes >= late) return TicketAge.late;
    if (warn > 0 && minutes >= warn) return TicketAge.warn;
    return TicketAge.fresh;
  }

  /// The board with this screen's own marks laid over it: [local] gives, for an order, the operations of
  /// this device the read may not show yet (`Outbox.localOps`). A ticket whose last dish was just marked is
  /// among the finished at once, and one just brought back is where it was, without waiting for the hub.
  KitchenBoard withLocal(List<Map<String, dynamic>> Function(String orderId) local, {required int nowMs}) {
    var touched = false;
    KitchenTicket laid(KitchenTicket ticket) {
      final lines = List.of(ticket.lines);
      for (final op in local(ticket.orderId)) {
        if (op['kind'] != 'done') continue;
        final data = (op['data'] as Map?) ?? const {};
        final station = data['station'];
        final ids = data['line_ids'];
        if (station is! String || ids is! List) continue;
        for (var i = 0; i < lines.length; i++) {
          if (ids.contains(lines[i].lineId)) lines[i] = lines[i]._marked(station, data['done'] != false, nowMs);
        }
      }
      var same = true;
      for (var i = 0; i < lines.length; i++) {
        if (!identical(lines[i], ticket.lines[i])) same = false;
      }
      if (same) return ticket;
      touched = true;
      return ticket._with(lines, nowMs);
    }

    final all = [...tickets.map(laid), ...recent.map(laid)];
    if (!touched) return this;
    final open = [
      for (final ticket in all)
        if (!ticket.done) ticket,
    ]..sort((a, b) => a.sinceMs != b.sinceMs ? a.sinceMs.compareTo(b.sinceMs) : a.id.compareTo(b.id));
    final made =
        [
          for (final ticket in all)
            if (ticket.done) ticket,
        ]..sort(
          (a, b) =>
              (b.doneMs ?? 0) != (a.doneMs ?? 0) ? (b.doneMs ?? 0).compareTo(a.doneMs ?? 0) : a.id.compareTo(b.id),
        );
    return KitchenBoard(
      stations: stations,
      warn: warn,
      late: late,
      tickets: open,
      recent: made.length > keeps ? made.sublist(0, keeps) : made,
      pass: pass,
    );
  }
}

/// The operations that mark [lines] of a ticket made, or take that back ([made] false): one for each station
/// of this screen that makes any of them, naming its dishes. Only what would change is said, so a dish
/// already marked is not marked again.
List<(String, Map<String, dynamic>)> markOps(Iterable<KitchenLine> lines, {required bool made}) {
  final byStation = <String, List<String>>{};
  for (final line in lines) {
    for (final station in line.stations) {
      if (line.made.contains(station) == made) continue;
      final ids = byStation.putIfAbsent(station, () => []);
      if (!ids.contains(line.lineId)) ids.add(line.lineId);
    }
  }
  return [
    for (final MapEntry(key: station, value: ids) in byStation.entries)
      ('done', {'station': station, 'line_ids': ids, if (!made) 'done': false}),
  ];
}
