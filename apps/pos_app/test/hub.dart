import 'dart:async';
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

/// An answer as the hub sends it: JSON in UTF-8, said to be JSON, so that a name in Chinese or a "·" reads
/// in the app as it was written.
http.Response json(Object body, [int status = 200]) =>
    http.Response.bytes(utf8.encode(jsonEncode(body)), status, headers: const {'content-type': 'application/json'});

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

/// A line as the hub lists it. [sentMs] is when the kitchen got it, as a hub that tells the time says;
/// with it the line is sent whatever [fired] says. A line that is `fired` with no time is an older hub's.
Map<String, dynamic> line(String item, {String? course, bool fired = false, int? sentMs, double? rank}) => {
  'item': item,
  'qty': 1,
  'seat': 1,
  'course': ?course,
  'status': 'active',
  'fired': fired || sentMs != null,
  'sent_ms': ?sentMs,
  'rank': ?rank,
};

/// A pretend hub: its orders, the coursing and quote settings it keeps, and what the terminal sends it.
class Hub {
  final orders = <Map<String, dynamic>>[];

  /// Whether a line says when it was sent (`sent_ms`); false for a hub from before the check showed it.
  bool tellsSent = true;
  final sent = <(String, Map<String, dynamic>)>[];

  /// The operations of each call that brought some, as they came: what was sent together is one change.
  final batches = <List<Map<String, dynamic>>>[];
  final pins = <String>[];
  Map<String, dynamic> coursing = {'enabled': true, 'default': '1', 'courses': standard};
  Map<String, dynamic> quotes = {
    'minutes': {'counter': 15, 'phone': 20, 'online': 25, 'delivery': 45},
    'pay_at_pickup': ['phone'],
  };
  String? coursingAuth;
  String? refuse; // a reason the hub refuses the next coursing save with

  /// Table timers: the setting it keeps (`GET/PUT /settings/table_timers`; null for a hub older than them),
  /// the token the last save carried and a reason to refuse the next save with.
  Map<String, dynamic>? tableTimers = {
    'enabled': true,
    'stages': {
      'sat': {'warn': 5, 'late': 10},
      'unsent': {'warn': 5, 'late': 10},
      'held': {'warn': 15, 'late': 25},
      'fired': {'warn': 25, 'late': 0},
    },
  };
  String? tableTimersAuth;
  String? refuseTableTimers;

  /// The void rules it keeps (`GET/PUT /settings/voids`), the token the last save carried and a reason to
  /// refuse the next save with. Null is a hub older than the rules, which a terminal voids on with the
  /// operator's word alone: what the tests written before the rules still run against. [purposes] is what
  /// each manager's PIN was asked for (`POST /approvals`), and [report] what it says came off the register.
  Map<String, dynamic>? voids;
  String? voidsAuth;
  String? refuseVoids;
  final purposes = <String>[];
  Map<String, dynamic>? report;

  /// The allergens the menu names (`GET /menu/allergens`): what a server picks from when a guest tells of an
  /// allergy. Null is a hub older than allergies on the order (404). An `allergy` operation is kept on the
  /// order, and each dish is marked with what its `priced.contains` has of it, as the real hub does.
  List<Map<String, dynamic>>? allergens = [
    {'code': 'milk', 'name': 'Milk'},
    {'code': 'egg', 'name': 'Eggs'},
    {'code': 'fish', 'name': 'Fish'},
    {'code': 'crustacean', 'name': 'Crustacean shellfish'},
    {'code': 'tree_nut', 'name': 'Tree nuts'},
    {'code': 'peanut', 'name': 'Peanuts'},
    {'code': 'wheat', 'name': 'Wheat'},
    {'code': 'soy', 'name': 'Soybeans'},
    {'code': 'sesame', 'name': 'Sesame'},
  ];

  /// The time clock (docs/time-clock.md). [timeClock] is the setting it keeps (`GET/PUT /settings/time_clock`;
  /// null for a hub older than the clock) and [timeClockAuth] the token its last save carried. A PIN at the
  /// clock (`POST /timeclock/punch`) is Amy's 1111 or Ben's 2222; each punch that came is in [punches], and
  /// the hub's own clock is [clockNow], which a test moves. [shifts] are the shifts it holds, as the report
  /// lists them (`GET /timeclock/report`, whose asks are in [clockAsks]); [unended] is what a person's answer
  /// carries as the shift nobody clocked them out of. A manager's add, correction or removal is kept in
  /// [shiftChanges] as (method, path, body), and refused with [refuseShift] (an error code and its message).
  Map<String, dynamic>? timeClock;
  String? timeClockAuth;
  final punches = <Map<String, dynamic>>[];
  int clockNow = DateTime(2026, 11, 16, 16, 2).millisecondsSinceEpoch;
  final shifts = <Map<String, dynamic>>[];
  final unended = <String, Map<String, dynamic>>{};
  final clockAsks = <Map<String, String>>[];
  final shiftChanges = <(String, String, Map<String, dynamic>)>[];
  (String, String)? refuseShift;
  String? clockAuth;
  final _punched = <String, String>{}; // punch id -> staff id
  static const _atClock = {
    '1111': {'staff_id': 's1', 'name': 'Amy', 'role': 'server'},
    '2222': {'staff_id': 's2', 'name': 'Ben', 'role': 'bartender'},
  };

  /// The day's report (docs/day-report.md). [days] answers `GET /reports/day` by the day asked for ("" for
  /// the running one, which is [dayRunning]); a day it has nothing for reads all zeroes, and null is a hub
  /// older than the report. Each ask is in [dayAsks] ("" for none) and the token of the last one in
  /// [dayAuth]. `POST /reports/day/print` keeps its body in [dayPrints] and answers the printer
  /// [dayPrinter], or 409 `no_printer` when that is null. [refuseDay] answers both with a status instead.
  Map<String, Map<String, dynamic>>? days = {};
  String dayRunning = '2026-11-16';
  final dayAsks = <String>[];
  String? dayAuth;
  final dayPrints = <Map<String, dynamic>>[];
  String? dayPrinter = 'Takeout';
  int? refuseDay;

  /// Sales over a span of days (docs/sales-report.md). [sales] answers `GET /reports/sales` by the days asked
  /// for, written "2026-11-09..2026-11-15" ("" when none were named: the running day); a span it has nothing
  /// for reads all zeroes beside the same days whole weeks earlier, and null is a hub older than the
  /// report. Each ask is in [salesAsks] and the token of the last one in [salesAuth]. [refuseSales] answers
  /// with a status instead, saying [salesRefusal]. While [salesHeld] is set no answer goes out until a test
  /// completes it: a hub still adding up.
  Map<String, Map<String, dynamic>>? sales = {};
  Completer<void>? salesHeld;
  final salesAsks = <String>[];
  String? salesAuth;
  int? refuseSales;
  String salesRefusal = 'sign in with a manager PIN';

  /// Dishes sold over a span of days (docs/dishes-sold.md). [dishes] answers `GET /reports/dishes` by the
  /// days asked for, written as [sales] writes them; a span it has nothing for lists no dish, and null is a
  /// hub older than the list. Each ask is in [dishesAsks] and the token of the last one in [dishesAuth].
  /// [refuseDishes] answers with a status instead. While [dishesHeld] is set no answer goes out until a test
  /// completes it.
  Map<String, Map<String, dynamic>>? dishes = {};
  Completer<void>? dishesHeld;
  final dishesAsks = <String>[];
  String? dishesAuth;
  int? refuseDishes;

  /// The guest list (docs/guest-list.md). [guests] answers `GET /reports/guests`; null is a hub older than
  /// the list. [guestDetails] answers `GET /reports/guests/<digits>` by the number asked for; one it has
  /// nothing for is `no_guest`. How often the list was asked is [guestsAsks], the numbers read closely are
  /// in [guestAsks], and the token of the last ask of either in [guestsAuth]. [refuseGuests] answers the
  /// list with a status instead, and [refuseGuest] one guest. While [guestsHeld] is set the list does not go
  /// out until a test completes it, and while [guestHeld] is set no guest does.
  Map<String, dynamic>? guests = {};
  Map<String, Map<String, dynamic>> guestDetails = {};
  Completer<void>? guestsHeld;
  Completer<void>? guestHeld;
  int guestsAsks = 0;
  final guestAsks = <String>[];
  String? guestsAuth;
  int? refuseGuests;
  int? refuseGuest;

  /// Notes for the shift (docs/shift-notes.md). [shiftNotes] are the notes that are up, the newest first,
  /// each as the hub answers it plus `seen_by`: the ids of the staff who have seen it. Null is a hub older
  /// than the notes. `GET /notes` answers them for one person (each ask is in [notesAsks]) and
  /// `POST /notes/seen` marks them ([notesSeenPosts]; [refuseNotesSeen] answers with a status instead and
  /// marks nothing). A manager's calls ([notesAuth] is the token of the last) read the board with who has
  /// seen each of [notesStaff], put a note up ([notesWritten]), change one ([notesChanged]: new words show
  /// it to everybody again) and take one down ([notesDown]), which moves it to [notesEarlier].
  /// [refuseNotes] answers every manager's call with a status and [refuseNote] one write with a reason.
  List<Map<String, dynamic>>? shiftNotes = [];
  List<Map<String, dynamic>> notesEarlier = [];
  Map<String, String> notesStaff = {'s1': 'Amy', 's2': 'Ben', 's3': 'Mike', 's4': 'Holly'};
  final notesAsks = <String>[];
  final notesSeenPosts = <(String, List<String>)>[];
  final notesWritten = <Map<String, dynamic>>[];
  final notesChanged = <(String, Map<String, dynamic>)>[];
  final notesDown = <String>[];
  String? notesAuth;
  int? refuseNotes;
  int? refuseNotesSeen;
  (int, String, String)? refuseNote;

  /// The manager's log (docs/shift-notes.md). [logbook] holds the entries, the newest first; null is a hub
  /// older than the log. `GET /logbook` answers [logPage] of them at a time, by subject and by the words
  /// asked for (each ask's query is in [logAsks]), `POST /logbook` writes one at the top ([logWritten]) and
  /// `POST /logbook/<id>/strike` strikes one out ([logStruck]). [logAuth] is the token of the last call and
  /// [refuseLog] answers with a status instead.
  List<Map<String, dynamic>>? logbook = [];
  int logPage = 50;
  final logAsks = <Map<String, String>>[];
  final logWritten = <Map<String, dynamic>>[];
  final logStruck = <String>[];
  String? logAuth;
  int? refuseLog;
  static const logSubjects = [
    ('guests', 'Guests'),
    ('staff', 'Staff'),
    ('kitchen', 'Kitchen'),
    ('bar', 'Bar'),
    ('repairs', 'Repairs'),
    ('deliveries', 'Deliveries'),
    ('money', 'Money'),
    ('other', 'Other'),
  ];

  /// A check's history (docs/check-history.md). [histories] answers `GET /orders/<id>/history` by the order
  /// asked for; one it has nothing for is `unknown_id`, and null is a hub older than the history. Each ask
  /// is in [historyAsks] and the token of the last one in [historyAuth]; [refuseHistory] answers with a
  /// status instead. [eventPhotos] answers `GET /events/photos/<id>` with a picture's bytes, 404 otherwise.
  Map<String, Map<String, dynamic>>? histories = {};
  final historyAsks = <String>[];
  String? historyAuth;
  int? refuseHistory;
  final eventPhotos = <String, List<int>>{};

  /// Unreachable: every call fails, as with the hub's cable pulled.
  bool down = false;

  /// It takes what it is sent and the answer never arrives: the cable pulled after the request left.
  bool deaf = false;

  /// The staff by name and role (`GET /staff`): who a table can be given to and who gives tables out. Null
  /// for a hub older than the list.
  List<Map<String, dynamic>>? roster = [
    {'staff_id': 's1', 'name': 'Amy', 'role': 'server', 'takes_tables': true, 'assigns_tables': false},
    {'staff_id': 's2', 'name': 'Ben', 'role': 'bartender', 'takes_tables': true, 'assigns_tables': false},
    {'staff_id': 's3', 'name': 'Mike', 'role': 'manager', 'takes_tables': true, 'assigns_tables': true},
    {'staff_id': 's4', 'name': 'Holly', 'role': 'host', 'takes_tables': false, 'assigns_tables': true},
  ];

  /// The floor it serves when a test changed it (the fixture otherwise), and what each person saved of their
  /// own settings (`PUT /staff/<id>/preferences`), in order.
  Map<String, dynamic>? floor;
  final prefsSaved = <(String, Map<String, dynamic>)>[];

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

  /// The menu it serves when a test changed it (the fixture otherwise), and the revision it is at.
  Map<String, dynamic>? menu;
  int revision = 0;

  /// The dishes it describes that have no fixture (`GET /menu/items/<code>`), by code, and every line it was
  /// asked to price (`POST /menu/price`). Like the real hub, it prices a dish that came with a typed price
  /// at that price and calls it what was typed for it.
  final items = <String, Map<String, dynamic>>{};
  final priced = <Map<String, dynamic>>[];

  /// The 86 board it lists (`GET /menu/86`) and every change a terminal asked for (`POST /menu/86`), which
  /// also takes the row off the board when it brings the dish back with no number.
  List<Map<String, dynamic>> board = [];
  final boardChanges = <Map<String, dynamic>>[];

  /// The check it serves for every order (it prices nothing itself), and its pricing rules. One that says
  /// `exempts` is a hub that can mark a check tax exempt; [refuseExempt] is a code and the words it refuses
  /// the next mark with, whatever PIN came.
  Map<String, dynamic>? check;
  (String, String)? refuseExempt;

  /// Every audit photo a terminal sent (`POST /events/photos`).
  final photosPut = <Map<String, dynamic>>[];
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

  /// What the tickets say beyond their dishes (`GET/PUT /settings/tickets`), the token the last save carried
  /// and a reason to refuse the next save with. Null is a hub older than the setting (404); one with no `paid`
  /// is a hub older than PAID / NOT PAID on the takeout ticket, and one with no `moved` is older than the
  /// MOVED slip a kitchen gets when a table moves.
  Map<String, dynamic>? ticketWords = {'numbered': true, 'also_at': true, 'paid': true, 'moved': true};
  String? ticketWordsAuth;
  String? refuseTicketWords;

  /// The stations each screen prints no ticket at (`GET/PUT /settings/ticket_skips`), the token the last save
  /// carried and a reason to refuse the next save with. Null is a hub older than the setting (404). Like the
  /// hub, it drops a screen saved with no station.
  Map<String, dynamic>? ticketSkips = {'screens': <Map<String, dynamic>>[]};
  String? ticketSkipsAuth;
  String? refuseTicketSkips;

  /// The guest's bill (`GET/PUT /settings/bill`): the setting with the printers by name; null is a hub older
  /// than the bill (404). The token the last save or sample carried, a reason to refuse the next one with,
  /// the bills asked for (order id, the printer the screen asked for or null) and the samples tried. A
  /// bill may be asked for one check of a split table ([billChecks], null for the whole table), and the
  /// hub answers how many bills went: one for each check its [check] lists, when none was asked for.
  Map<String, dynamic>? bill = {
    'printer': null,
    'header': <String>[],
    'footer': ['Thank you!'],
    'printers': [
      {'id': 'p1', 'name': 'Takeout'},
      {'id': 'p2', 'name': 'Bar'},
    ],
    'prints_at': 'p1',
    'usual': 'p1',
  };
  String? billAuth;
  String? refuseBill;
  final bills = <(String, String?)>[];
  final billChecks = <int?>[];
  final billSamples = <Map<String, dynamic>>[];

  /// The name of the printer a bill comes out of: the one asked for when it is there, else the location's.
  Map<String, dynamic> _billAt(String? asked) {
    final printers = (bill!['printers'] as List).cast<Map<String, dynamic>>();
    Map<String, dynamic>? named(Object? id) => printers.where((p) => p['id'] == id).firstOrNull;
    return named(asked) ?? named(bill!['printer']) ?? named(bill!['usual']) ?? {'id': '', 'name': ''};
  }

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
  static final _prefs = RegExp(r'^/staff/([^/]+)/preferences$');
  static final _samples = RegExp(r'^/admin/staff/([^/]+)/face/samples$');
  static final _face = RegExp(r'^/admin/staff/([^/]+)/face$');
  static final _tag = RegExp(r'^/admin/staff/([^/]+)/tag$');
  static final _check = RegExp(r'^/orders/([^/]+)/check$');
  static final _bill = RegExp(r'^/orders/([^/]+)/bill$');
  static final _order = RegExp(r'^/orders/([^/]+)$');
  static final _history = RegExp(r'^/orders/([^/]+)/history$');
  static final _photo = RegExp(r'^/events/photos/([^/]+)$');
  static final _shift = RegExp(r'^/timeclock/shifts/([^/]+)$');

  /// A shift as the hub answers it, with what it comes to counted at [clockNow].
  Map<String, dynamic> _counted(Map<String, dynamic> shift) {
    final paid = timeClock?['breaks_paid'] == true;
    final inMs = shift['in_ms'] as int;
    final outMs = shift['out_ms'] as int?;
    final end = outMs ?? clockNow;
    final breaks = (shift['breaks'] as List? ?? const []).cast<Map<String, dynamic>>();
    final breakMs = breaks.fold<int>(0, (sum, b) => sum + ((b['end_ms'] as int?) ?? end) - (b['start_ms'] as int));
    final removed = shift['removed'] == true;
    final onBreak = outMs == null && breaks.isNotEmpty && breaks.last['end_ms'] == null;
    return {
      'closed_by': '',
      'edited': false,
      'removed': false,
      ...shift,
      'breaks': breaks,
      'state': removed
          ? 'removed'
          : onBreak
          ? 'break'
          : outMs == null
          ? 'in'
          : 'out',
      'unended': shift['closed_by'] == 'system' && !removed,
      'span_ms': end - inMs,
      'break_ms': breakMs,
      'worked_ms': end - inMs - (paid ? 0 : breakMs),
    };
  }

  Map<String, dynamic>? _openOf(String staffId) =>
      shifts.where((s) => s['staff_id'] == staffId && s['out_ms'] == null && s['removed'] != true).firstOrNull;

  /// `POST /timeclock/punch`: who the PIN is, and where they stand after what they asked.
  http.Response _punch(Map<String, dynamic> body) {
    punches.add(body);
    if (timeClock?['enabled'] != true) {
      return json({
        'detail': {'error': 'off', 'message': 'This location does not use the time clock'},
      }, 409);
    }
    final who = _atClock[body['pin']];
    pins.add(body['pin'] as String? ?? '');
    if (who == null) {
      return json({
        'detail': {'error': 'unknown_credential'},
      }, 401);
    }
    final id = who['staff_id']!;
    final action = body['action'] as String? ?? 'state';
    final punchId = body['punch_id'] as String?;
    var shown = _openOf(id);
    http.Response refused(String code, String message) => json({
      'detail': {'error': code, 'message': message},
    }, 409);
    if (action != 'state' && (punchId == null || !_punched.containsKey(punchId))) {
      final open = _openOf(id);
      switch (action) {
        case 'in':
          if (open != null) return refused('already_in', '${who['name']} is already on the clock');
          shown = {'shift_id': 'sh${shifts.length + 1}', ...who, 'in_ms': clockNow, 'out_ms': null, 'breaks': []};
          shifts.add(shown);
        case 'out':
          if (open == null) return refused('not_in', '${who['name']} is not on the clock');
          final breaks = (open['breaks'] as List).cast<Map<String, dynamic>>();
          if (breaks.isNotEmpty && breaks.last['end_ms'] == null) breaks.last['end_ms'] = clockNow;
          open['out_ms'] = clockNow;
          open['closed_by'] = 'self';
        case 'break_start':
          if (open == null) return refused('not_in', '${who['name']} is not on the clock');
          (open['breaks'] as List).add(<String, dynamic>{'start_ms': clockNow, 'end_ms': null});
        case 'break_end':
          if (open == null) return refused('not_in', '${who['name']} is not on the clock');
          final breaks = (open['breaks'] as List).cast<Map<String, dynamic>>();
          if (breaks.isEmpty || breaks.last['end_ms'] != null) {
            return refused('not_on_break', '${who['name']} is not on a break');
          }
          breaks.last['end_ms'] = clockNow;
      }
      if (punchId != null) _punched[punchId] = id;
    }
    final current = _openOf(id);
    final counted = current == null ? null : _counted(current);
    final breaks = (current?['breaks'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
    return json({
      'staff': {...who, 'method': 'pin', 'preferences': <String, dynamic>{}},
      'breaks_paid': timeClock?['breaks_paid'] == true,
      'state': counted?['state'] ?? 'out',
      'since_ms': counted == null
          ? null
          : counted['state'] == 'break'
          ? breaks.last['start_ms']
          : current!['in_ms'],
      'now_ms': clockNow,
      'shift': counted ?? (shown == null ? null : _counted(shown)),
      'unended': unended[id] == null ? null : _counted(unended[id]!),
      'punched': action == 'state' ? null : action,
    });
  }

  /// `GET /timeclock/report`: the shifts that began in the time asked for, and what they come to.
  http.Response _clockReport(Uri url) {
    clockAsks.add(url.queryParameters);
    final since = int.parse(url.queryParameters['since']!), until = int.parse(url.queryParameters['until']!);
    final listed = [
      for (final s in shifts)
        if ((s['in_ms'] as int) >= since && (s['in_ms'] as int) < until) _counted(s),
    ];
    final people = <String, Map<String, dynamic>>{};
    for (final s in listed.where((s) => s['removed'] != true)) {
      final person = people.putIfAbsent(
        s['staff_id'] as String,
        () => {
          'staff_id': s['staff_id'],
          'name': s['name'],
          'role': s['role'],
          'worked_ms': 0,
          'break_ms': 0,
          'shifts': 0,
          'unended': 0,
          'open': 0,
        },
      );
      person['worked_ms'] = (person['worked_ms'] as int) + (s['worked_ms'] as int);
      person['break_ms'] = (person['break_ms'] as int) + (s['break_ms'] as int);
      person['shifts'] = (person['shifts'] as int) + 1;
      person['unended'] = (person['unended'] as int) + (s['unended'] == true ? 1 : 0);
      person['open'] = (person['open'] as int) + (s['out_ms'] == null ? 1 : 0);
    }
    return json({
      'since_ms': since,
      'until_ms': until,
      'now_ms': clockNow,
      'breaks_paid': timeClock?['breaks_paid'] == true,
      'on_now': [
        for (final s in shifts)
          if (s['out_ms'] == null && s['removed'] != true) _counted(s),
      ],
      'people': people.values.toList(),
      'worked_ms': people.values.fold<int>(0, (sum, p) => sum + (p['worked_ms'] as int)),
      'break_ms': people.values.fold<int>(0, (sum, p) => sum + (p['break_ms'] as int)),
      'unended': people.values.fold<int>(0, (sum, p) => sum + (p['unended'] as int)),
      'shifts': listed,
      'enabled': timeClock?['enabled'] == true,
      'week_starts': timeClock?['week_starts'] ?? 'mon',
    });
  }

  /// A manager's add (`POST /timeclock/shifts`), correction (`PUT`) or removal (`DELETE`) of a shift.
  http.Response _changeShift(http.Request request, String? shiftId) {
    clockAuth = request.headers['authorization'];
    final body = request.method == 'DELETE'
        ? <String, dynamic>{...request.url.queryParameters}
        : jsonDecode(request.body) as Map<String, dynamic>;
    shiftChanges.add((request.method, request.url.path, body));
    final refusal = refuseShift;
    if (refusal != null) {
      return json({
        'detail': {'error': refusal.$1, 'message': refusal.$2},
      }, refusal.$1.startsWith('bad_') ? 422 : 409);
    }
    if ((body['reason'] as String? ?? '').trim().isEmpty) {
      return json({
        'detail': {'error': 'reason_needed', 'message': 'Say why: the log keeps it with the change'},
      }, 409);
    }
    final entry = {
      'entry_id': 'e${shiftChanges.length}',
      'at_ms': clockNow,
      'by_id': 's3',
      'by': 'Mike',
      'device': body['device'] ?? '',
      'reason': body['reason'],
    };
    Map<String, dynamic> times(Map<String, dynamic> of) => {
      'in_ms': of['in_ms'],
      'out_ms': of['out_ms'],
      'breaks': of['breaks'] ?? [],
    };
    if (shiftId == null) {
      final who = (roster ?? const []).where((s) => s['staff_id'] == body['staff_id']).firstOrNull;
      if (who == null) {
        return json({
          'detail': {'error': 'unknown_staff', 'message': 'Nobody on the staff has that id'},
        }, 404);
      }
      final shift = <String, dynamic>{
        'shift_id': 'sh${shifts.length + 1}',
        'staff_id': who['staff_id'],
        'name': who['name'],
        'role': who['role'],
        ...times(body),
        'closed_by': body['out_ms'] == null ? '' : 'manager',
        'edited': true,
        'log': [
          {...entry, 'action': 'add', 'before': null, 'after': times(body)},
        ],
      };
      shifts.add(shift);
      return json(_counted(shift));
    }
    final shift = shifts.where((s) => s['shift_id'] == shiftId).firstOrNull;
    if (shift == null) {
      return json({
        'detail': {'error': 'unknown_shift', 'message': 'No such shift'},
      }, 404);
    }
    final before = times(shift);
    final log = [...(shift['log'] as List? ?? const [])];
    if (request.method == 'DELETE') {
      shift['removed'] = true;
      shift['out_ms'] ??= clockNow;
      log.add({...entry, 'action': 'remove', 'before': before, 'after': null});
    } else {
      shift.addAll(times(body));
      shift['closed_by'] = body['out_ms'] == null ? '' : 'manager';
      log.add({...entry, 'action': 'edit', 'before': before, 'after': times(body)});
    }
    shift['edited'] = true;
    shift['log'] = log;
    return json(_counted(shift));
  }

  /// Every request that reached the hub, as `METHOD path?query`, and how many of its reads it answered with
  /// "nothing new" (304).
  final requests = <String>[];
  int unchanged = 0;

  /// Whether the hub names its answers (an `ETag` on every read, 304 for a read the terminal already has),
  /// as hubs do since 2026-11-12. Off, it is an older hub: every read comes in full.
  bool namesAnswers = true;

  /// The hub as the terminal reaches it: [answer], with every read named like the real hub names them.
  Future<http.Response> handle(http.Request request) async {
    if (down) throw http.ClientException('connection refused', request.url);
    requests.add('${request.method} ${request.url.path}${request.url.hasQuery ? '?${request.url.query}' : ''}');
    final response = await answer(request);
    if (deaf) throw http.ClientException('no answer came back', request.url);
    if (!namesAnswers || request.method != 'GET' || response.statusCode != 200) return response;
    final etag = 'W/"${base64Encode(response.bodyBytes).hashCode}-${response.bodyBytes.length}"';
    if (request.headers['if-none-match'] == etag) {
      unchanged += 1;
      return http.Response('', 304, headers: {'etag': etag});
    }
    return http.Response.bytes(response.bodyBytes, 200, headers: {...response.headers, 'etag': etag});
  }

  static final _note = RegExp(r'^/notes/([^/]+)$');
  static final _strike = RegExp(r'^/logbook/([^/]+)/strike$');

  Map<String, dynamic> _noteOut(Map<String, dynamic> note) => {
    for (final entry in note.entries)
      if (entry.key != 'seen_by') entry.key: entry.value,
  };

  Map<String, dynamic> _notesFor(String staffId) => {
    'notes': [
      for (final note in shiftNotes!)
        {..._noteOut(note), 'seen': (note['seen_by'] as List? ?? const []).contains(staffId)},
    ],
    'unseen': shiftNotes!.where((note) => !(note['seen_by'] as List? ?? const []).contains(staffId)).length,
    'now_ms': clockNow,
  };

  /// Notes for the shift: what one person reads and marks, and a manager's board and changes.
  http.Response _notes(http.Request request) {
    final path = request.url.path;
    if (shiftNotes == null) return json({'detail': 'Not Found'}, 404);
    if (path == '/notes' && request.method == 'GET') {
      final staffId = request.url.queryParameters['staff_id'] ?? '';
      notesAsks.add(staffId);
      return json(_notesFor(staffId));
    }
    if (path == '/notes/seen') {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final staffId = body['staff_id'] as String;
      final ids = [...(body['note_ids'] as List).cast<String>()];
      if (refuseNotesSeen != null) {
        return json({
          'detail': {'error': 'read_only'},
        }, refuseNotesSeen!);
      }
      notesSeenPosts.add((staffId, ids));
      for (final note in shiftNotes!) {
        final seen = note['seen_by'] as List? ?? (note['seen_by'] = <String>[]);
        if (ids.contains(note['id']) && !seen.contains(staffId)) seen.add(staffId);
      }
      return json(_notesFor(staffId));
    }
    // the rest is a manager's
    notesAuth = request.headers['authorization'];
    if (refuseNotes != null) {
      return json({
        'detail': {'error': 'sign_in', 'message': 'sign in with a manager PIN'},
      }, refuseNotes!);
    }
    if (path == '/notes/board') {
      return json({
        'notes': [
          for (final note in shiftNotes!)
            {
              ..._noteOut(note),
              'seen': [
                for (final id in (note['seen_by'] as List? ?? const []).cast<String>())
                  if (notesStaff.containsKey(id)) {'staff_id': id, 'name': notesStaff[id], 'at_ms': note['at_ms']},
              ],
              'waiting': [
                for (final entry in notesStaff.entries)
                  if (!(note['seen_by'] as List? ?? const []).contains(entry.key)) entry.value,
              ],
            },
        ],
        'earlier': [for (final note in notesEarlier) _noteOut(note)],
        'staff': notesStaff.length,
        'most': 12,
        'text_max': 500,
        'earlier_days': 14,
        'now_ms': clockNow,
      });
    }
    if (path == '/notes' && request.method == 'POST') {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      notesWritten.add(body);
      if (refuseNote != null) {
        return json({
          'detail': {'error': refuseNote!.$2, 'message': refuseNote!.$3},
        }, refuseNote!.$1);
      }
      final note = <String, dynamic>{
        'id': 'n${notesWritten.length}',
        'text': body['text'],
        'by': 'Mike',
        'at_ms': clockNow,
        'until_ms': body['lasts'] == 'stays' ? null : clockNow + 12 * 3600 * 1000,
        'lasts': body['lasts'],
        'edited_ms': null,
        'seen_by': <String>['s3'],
      };
      shiftNotes!.insert(0, note);
      return json(_noteOut(note));
    }
    final id = _note.firstMatch(path)?.group(1);
    final note = shiftNotes!.where((n) => n['id'] == id).firstOrNull;
    if (note == null) {
      final ended = notesEarlier.any((n) => n['id'] == id);
      return json({
        'detail': ended
            ? {'error': 'ended', 'message': 'This note has come down. Write it again as a new note.'}
            : {'error': 'unknown_note', 'message': 'There is no such note.'},
      }, ended ? 409 : 404);
    }
    if (request.method == 'PUT') {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      notesChanged.add((id!, body));
      if (body['text'] != note['text']) {
        note['edited_ms'] = clockNow;
        note['seen_by'] = <String>['s3'];
      }
      note['text'] = body['text'];
      note['lasts'] = body['lasts'];
      note['until_ms'] = body['lasts'] == 'stays' ? null : clockNow + 12 * 3600 * 1000;
      return json(_noteOut(note));
    }
    if (request.method == 'DELETE') {
      notesDown.add(id!);
      shiftNotes!.remove(note);
      notesEarlier.insert(0, {
        ...note,
        'ended_ms': clockNow,
        'removed_by': 'Mike',
        'seen_count': (note['seen_by'] as List? ?? const []).length,
      });
      return json({..._noteOut(note), 'removed_ms': clockNow, 'removed_by': 'Mike'});
    }
    return json({'detail': 'Method Not Allowed'}, 405);
  }

  /// The manager's log: a page of it by subject and by words, a new entry, an entry struck out.
  http.Response _logbook(http.Request request) {
    final path = request.url.path;
    if (logbook == null) return json({'detail': 'Not Found'}, 404);
    logAuth = request.headers['authorization'];
    if (refuseLog != null) {
      return json({
        'detail': {'error': 'sign_in', 'message': 'sign in with a manager PIN'},
      }, refuseLog!);
    }
    final strike = _strike.firstMatch(path)?.group(1);
    if (strike != null) {
      final entry = logbook!.where((e) => e['id'] == strike).firstOrNull;
      if (entry == null) {
        return json({
          'detail': {'error': 'unknown_entry', 'message': 'There is no such entry.'},
        }, 404);
      }
      logStruck.add(strike);
      entry['struck_ms'] ??= clockNow;
      entry['struck_by'] = 'Mike';
      return json(entry);
    }
    if (request.method == 'POST') {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      logWritten.add(body);
      final at = DateTime.fromMillisecondsSinceEpoch(clockNow).subtract(const Duration(hours: 4));
      final entry = <String, dynamic>{
        'id': 'e-new-${logWritten.length}',
        'subject': body['subject'],
        'subject_name': logSubjects.firstWhere((s) => s.$1 == body['subject']).$2,
        'text': body['text'],
        'by': 'Mike',
        'at_ms': clockNow,
        'day': at.toIso8601String().substring(0, 10),
        'struck_ms': null,
        'struck_by': '',
      };
      logbook!.insert(0, entry);
      return json(entry);
    }
    final query = request.url.queryParameters;
    logAsks.add(query);
    final words = (query['q'] ?? '').toLowerCase().split(' ').where((w) => w.isNotEmpty).toList();
    bool holds(Map<String, dynamic> e) => words.every((w) => '${e['text']} ${e['by']}'.toLowerCase().contains(w));
    final counts = <String, int>{};
    for (final entry in logbook!) {
      if (entry['struck_ms'] == null && holds(entry)) {
        counts[entry['subject'] as String] = (counts[entry['subject']] ?? 0) + 1;
      }
    }
    var found = [
      for (final entry in logbook!)
        if ((query['subject'] == null || entry['subject'] == query['subject']) && holds(entry)) entry,
    ];
    final before = query['before'];
    if (before != null) {
      final at = found.indexWhere((e) => e['id'] == before);
      found = at < 0 ? [] : found.sublist(at + 1);
    }
    return json({
      'subjects': [
        for (final (id, name) in logSubjects) {'id': id, 'name': name, 'count': counts[id] ?? 0},
      ],
      'count': counts.values.fold<int>(0, (sum, n) => sum + n),
      'entries': found.take(logPage).toList(),
      'more': found.length > logPage,
      'text_max': 2000,
    });
  }

  Future<http.Response> answer(http.Request request) async {
    final path = request.url.path;
    if (path == '/orders') return json({'orders': orders});
    if (path == '/notes' || path.startsWith('/notes/')) return _notes(request);
    if (path == '/logbook' || path.startsWith('/logbook/')) return _logbook(request);
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
      batches.add(ops);
      _apply(id, ops);
      _moveOnFloor(id, ops);
      final refused = _exempt(id, ops);
      final left = {for (final r in refused) r['op_id']};
      return json({
        'accepted': [
          for (final op in ops)
            if (!left.contains(op['op_id'])) op['op_id'],
        ],
        if (refused.isNotEmpty) 'refused': refused,
        'cursor': sent.length,
      }, 202);
    }
    if (_bill.hasMatch(path)) {
      if (bill == null) return json({'detail': 'Not Found'}, 404);
      if (refuseBill != null) {
        return json({
          'detail': {'error': 'no_printer', 'message': refuseBill},
        }, 409);
      }
      final body = jsonDecode(request.body) as Map;
      final asked = body['printer'] as String?;
      bills.add((_bill.firstMatch(path)!.group(1)!, asked));
      billChecks.add(body['check'] as int?);
      final checks = (check?['checks'] as List?)?.length ?? 0;
      return json({
        'job_id': 'bill-${bills.length}',
        'status': 'queued',
        'bills': body['check'] != null || checks == 0 ? 1 : checks,
        'printed_at': _billAt(asked),
      }, 202);
    }
    if (_check.hasMatch(path)) {
      return json(check ?? {'lines': [], 'subtotal': '0.00', 'tax_rate_pct': '7.00', 'tax': '0.00', 'total': '0.00'});
    }
    if (path.startsWith('/menu/items/')) {
      final code = path.split('/').last;
      return json(items[code] ?? fixture('item_${code.toLowerCase()}'));
    }
    if (_prefs.hasMatch(path) && request.method == 'PUT') {
      final id = _prefs.firstMatch(path)!.group(1)!;
      final saved = jsonDecode(request.body) as Map<String, dynamic>;
      prefsSaved.add((id, saved));
      return json({'staff_id': id, 'preferences': saved});
    }
    if (_order.hasMatch(path)) {
      final id = _order.firstMatch(path)!.group(1)!;
      final order = orders.where((o) => o['order_id'] == id).firstOrNull;
      return order == null ? json({'detail': 'not found'}, 404) : json(order);
    }
    if (_history.hasMatch(path)) {
      if (histories == null) return json({'detail': 'Not Found'}, 404);
      historyAuth = request.headers['authorization'];
      if (refuseHistory != null) {
        return json({
          'detail': {'error': 'sign_in', 'message': 'sign in with a manager PIN'},
        }, refuseHistory!);
      }
      final id = _history.firstMatch(path)!.group(1)!;
      historyAsks.add(id);
      final history = histories![id];
      if (history != null) return json(history);
      return json({
        'detail': {'error': 'unknown_id', 'message': 'There is no such check.'},
      }, 404);
    }
    if (_photo.hasMatch(path) && request.method == 'GET') {
      final picture = eventPhotos[_photo.firstMatch(path)!.group(1)!];
      return picture == null ? json({'detail': 'no such photo'}, 404) : http.Response.bytes(picture, 200);
    }
    if (path == '/reports/day' || path == '/reports/day/print') {
      if (days == null) return json({'detail': 'Not Found'}, 404);
      dayAuth = request.headers['authorization'];
      if (refuseDay != null) {
        return json({
          'detail': {'error': 'sign_in', 'message': 'sign in with a manager PIN'},
        }, refuseDay!);
      }
      if (path == '/reports/day/print') {
        final asked = jsonDecode(request.body) as Map<String, dynamic>;
        dayPrints.add(asked);
        if (dayPrinter == null) {
          return json({
            'detail': {'error': 'no_printer', 'message': 'No printer is set up for this location.'},
          }, 409);
        }
        return json({
          'job_id': 'day-${dayPrints.length}',
          'day': asked['day'] ?? dayRunning,
          'printed_at': {'id': 'front', 'name': dayPrinter},
        }, 202);
      }
      final asked = request.url.queryParameters['day'] ?? '';
      dayAsks.add(asked);
      final day = asked.isEmpty ? dayRunning : asked;
      return json(days![asked] ?? {'day': day, 'today': day == dayRunning, 'now_ms': clockNow});
    }
    if (path == '/reports/guests') {
      if (guests == null) return json({'detail': 'Not Found'}, 404);
      guestsAuth = request.headers['authorization'];
      if (refuseGuests != null) {
        return json({
          'detail': {'error': 'sign_in', 'message': salesRefusal},
        }, refuseGuests!);
      }
      guestsAsks++;
      if (guestsHeld != null) await guestsHeld!.future;
      return json(guests!);
    }
    if (path.startsWith('/reports/guests/')) {
      if (guests == null) return json({'detail': 'Not Found'}, 404);
      guestsAuth = request.headers['authorization'];
      final phone = path.substring('/reports/guests/'.length);
      guestAsks.add(phone);
      if (guestHeld != null) await guestHeld!.future;
      if (refuseGuest != null) {
        return json({
          'detail': {'error': 'sign_in', 'message': salesRefusal},
        }, refuseGuest!);
      }
      final detail = guestDetails[phone];
      if (detail == null) {
        return json({
          'detail': {'error': 'no_guest', 'message': 'No visit from this number in the last year.'},
        }, 404);
      }
      return json(detail);
    }
    if (path == '/reports/dishes') {
      if (dishes == null) return json({'detail': 'Not Found'}, 404);
      dishesAuth = request.headers['authorization'];
      if (refuseDishes != null) {
        return json({
          'detail': {'error': refuseDishes == 422 ? 'too_long' : 'sign_in', 'message': salesRefusal},
        }, refuseDishes!);
      }
      final from = request.url.queryParameters['from'], to = request.url.queryParameters['to'];
      final asked = from == null && to == null ? '' : '${from ?? to}..${to ?? from}';
      dishesAsks.add(asked);
      if (dishesHeld != null) await dishesHeld!.future;
      final first = DateTime.parse('${from ?? to ?? dayRunning}T00:00:00Z');
      final last = DateTime.parse('${to ?? from ?? dayRunning}T00:00:00Z');
      final back = Duration(days: 7 * ((last.difference(first).inDays + 7) ~/ 7));
      String name(DateTime day) => day.toIso8601String().substring(0, 10);
      return json(
        dishes![asked] ??
            {
              'span': {'first': name(first), 'last': name(last), 'running': name(last) == dayRunning},
              'before': {'first': name(first.subtract(back)), 'last': name(last.subtract(back))},
              'dishes': <Object>[],
              'categories': <Object>[],
              'max_days': 92,
              'now_ms': clockNow,
            },
      );
    }
    if (path == '/reports/sales') {
      if (sales == null) return json({'detail': 'Not Found'}, 404);
      salesAuth = request.headers['authorization'];
      if (refuseSales != null) {
        return json({
          'detail': {'error': refuseSales == 422 ? 'too_long' : 'sign_in', 'message': salesRefusal},
        }, refuseSales!);
      }
      final from = request.url.queryParameters['from'], to = request.url.queryParameters['to'];
      final asked = from == null && to == null ? '' : '${from ?? to}..${to ?? from}';
      salesAsks.add(asked);
      if (salesHeld != null) await salesHeld!.future;
      final first = DateTime.parse('${from ?? to ?? dayRunning}T00:00:00Z');
      final last = DateTime.parse('${to ?? from ?? dayRunning}T00:00:00Z');
      final back = Duration(days: 7 * ((last.difference(first).inDays + 7) ~/ 7));
      String name(DateTime day) => day.toIso8601String().substring(0, 10);
      return json(
        sales![asked] ??
            {
              'span': {'first': name(first), 'last': name(last), 'running': name(last) == dayRunning},
              'before': {'first': name(first.subtract(back)), 'last': name(last.subtract(back))},
              'max_days': 92,
              'now_ms': clockNow,
            },
      );
    }
    if (path.startsWith('/timeclock/') || path == '/settings/time_clock') {
      if (timeClock == null) return json({'detail': 'Not Found'}, 404);
      if (path == '/settings/time_clock') {
        if (request.method == 'PUT') {
          timeClockAuth = request.headers['authorization'];
          timeClock = {...timeClock!, ...jsonDecode(request.body) as Map<String, dynamic>};
        }
        return json(timeClock!);
      }
      if (path == '/timeclock/punch') return _punch(jsonDecode(request.body) as Map<String, dynamic>);
      if (path == '/timeclock/report') {
        clockAuth = request.headers['authorization'];
        return _clockReport(request.url);
      }
      if (path == '/timeclock/shifts') return _changeShift(request, null);
      final shift = _shift.firstMatch(path);
      if (shift != null) return _changeShift(request, shift.group(1));
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
      case '/settings/table_timers':
        if (tableTimers == null) return json({'detail': 'Not Found'}, 404);
        if (request.method == 'PUT') {
          tableTimersAuth = request.headers['authorization'];
          if (refuseTableTimers != null) {
            return json({
              'detail': {'error': 'bad_value', 'message': refuseTableTimers},
            }, 422);
          }
          tableTimers = jsonDecode(request.body) as Map<String, dynamic>;
        }
        return json(tableTimers!);
      case '/settings/voids':
        if (voids == null) return json({'detail': 'Not Found'}, 404);
        if (request.method == 'PUT') {
          voidsAuth = request.headers['authorization'];
          if (refuseVoids != null) {
            return json({
              'detail': {'error': 'bad_value', 'message': refuseVoids},
            }, 422);
          }
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          voids = {
            ...body,
            // a reason new on the screen gets its id from its name, as the hub gives it
            'reasons': [
              for (final r in body['reasons'] as List)
                {
                  ...r as Map,
                  'id': r['id'] ?? (r['name'] as String).toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-'),
                },
            ],
          };
        }
        return json(voids!);
      case '/reports/adjustments':
        return report == null ? json({'detail': 'Not Found'}, 404) : json(report!);
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
      case '/settings/tickets':
        if (ticketWords == null) return json({'detail': 'Not Found'}, 404);
        if (request.method == 'PUT') {
          ticketWordsAuth = request.headers['authorization'];
          if (refuseTicketWords != null) {
            return json({
              'detail': {'error': 'bad_value', 'message': refuseTicketWords},
            }, 422);
          }
          ticketWords = {...ticketWords!, ...jsonDecode(request.body) as Map<String, dynamic>};
        }
        return json(ticketWords!);
      case '/settings/ticket_skips':
        if (ticketSkips == null) return json({'detail': 'Not Found'}, 404);
        if (request.method == 'PUT') {
          ticketSkipsAuth = request.headers['authorization'];
          if (refuseTicketSkips != null) {
            return json({
              'detail': {'error': 'bad_value', 'message': refuseTicketSkips},
            }, 422);
          }
          final asked = jsonDecode(request.body) as Map<String, dynamic>;
          ticketSkips = {
            'screens': [
              for (final screen in (asked['screens'] as List).cast<Map<String, dynamic>>())
                if ((screen['stations'] as List).isNotEmpty) screen,
            ],
          };
        }
        return json(ticketSkips!);
      case '/settings/bill':
        if (bill == null) return json({'detail': 'Not Found'}, 404);
        if (request.method == 'PUT') {
          billAuth = request.headers['authorization'];
          if (refuseBill != null) {
            return json({
              'detail': {'error': 'bad_value', 'message': refuseBill},
            }, 422);
          }
          final asked = jsonDecode(request.body) as Map<String, dynamic>;
          bill = {...bill!, ...asked, 'prints_at': asked['printer'] ?? bill!['usual']};
        }
        return json(bill!);
      case '/print/bill-sample':
        billAuth = request.headers['authorization'];
        final tried = jsonDecode(request.body) as Map<String, dynamic>;
        billSamples.add(tried);
        final at = (bill!['printers'] as List).cast<Map<String, dynamic>>().firstWhere(
          (p) => p['id'] == (tried['printer'] ?? bill!['usual']),
        );
        return json({'job_id': 'sample-${billSamples.length}', 'status': 'queued', 'printed_at': at}, 202);
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
      case '/staff':
        if (roster == null) return json({'detail': 'Not Found'}, 404);
        return json({'staff': roster});
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
        return json(floor ?? fixture('floor'));
      case '/menu':
        return json({...menu ?? fixture('menu'), if (revision != 0) 'revision': revision});
      case '/menu/revision':
        return json({'revision': revision});
      case '/menu/86':
        if (request.method == 'POST') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          boardChanges.add(body);
          if (body['status'] == 'available' && body['remaining'] == null) {
            board = [
              for (final row in board)
                if (row['target_id'] != body['target_id']) row,
            ];
          }
        }
        return json({'items': board});
      case '/menu/allergens':
        return allergens == null ? json({'detail': 'Not Found'}, 404) : json({'allergens': allergens});
      case '/menu/price':
        final asked = jsonDecode(request.body) as Map<String, dynamic>;
        priced.add(asked);
        if (asked['price'] != null) {
          return json({'name': asked['name'] ?? 'Market fish', 'unit_price': asked['price']});
        }
        return json({'name': "General Tso's Chicken (Quart)", 'unit_price': '26.95'});
      case '/pricing/rules':
        return json(rules ?? {'discounts': [], 'charges': []});
      case '/events/photos' when request.method == 'POST':
        // an audit photo: kept as it came (its event and the operation it belongs to), picture and all
        final photo = jsonDecode(request.body) as Map<String, dynamic>;
        photosPut.add(photo);
        return json({'photo_id': photo['photo_id'], 'bytes': 7}, 202);
      case '/approvals':
        // a manager's PIN for a discount on one order: Mike (9999) approves, anyone else is no manager
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        pins.add(body['pin'] as String);
        purposes.add(body['purpose'] as String? ?? 'adjust');
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

  /// A check marked exempt from sales tax (docs/tax-exempt.md), on the [check] it serves, as the real hub
  /// does it: the mark needs the token a manager's PIN bought for this order, and is refused in the hub's
  /// words without one (or with [refuseExempt]); the check then charges no tax and says for whom, by whom
  /// and how much tax that was. Taking the mark off charges the tax again.
  List<Map<String, dynamic>> _exempt(String orderId, List<Map<String, dynamic>> ops) {
    String sum(Object? a, Object? b, int sign) =>
        (double.parse('${a ?? 0}') + sign * double.parse('${b ?? 0}')).toStringAsFixed(2);
    final refused = <Map<String, dynamic>>[];
    for (final op in ops.where((op) => op['kind'] == 'set_field')) {
      final data = (op['data'] as Map).cast<String, dynamic>();
      final now = check;
      if (!data.containsKey('tax_exempt') || now == null) continue;
      final mark = data['tax_exempt'] as Map?;
      final stood = now['tax_exempt'] as Map?;
      if (mark == null) {
        if (stood == null) continue;
        check = {
          ...now,
          'tax': stood['tax'],
          'total': sum(now['total'], stood['tax'], 1),
          if (now['due'] != null) 'due': sum(now['due'], stood['tax'], 1),
        }..remove('tax_exempt');
        continue;
      }
      final problem =
          refuseExempt ??
          (data['approval'] == 'tok-$orderId'
              ? null
              : ('needs_approval', "Marking a check tax exempt needs a manager's PIN."));
      if (problem != null) {
        refused.add({
          'op_id': op['op_id'],
          'error': 'invalid_exemption',
          'problems': [
            {'code': problem.$1, 'message': problem.$2},
          ],
        });
        continue;
      }
      check = {
        ...now,
        'tax_exempt': {
          'organisation': mark['organisation'],
          'certificate': mark['certificate'],
          'approved_by': 'Mike',
          'approved_by_id': 's3',
          'by': data['by'] ?? '',
          'at_ms': 1800000000000,
          'tax': now['tax'],
        },
        'tax': '0.00',
        'total': sum(now['total'], now['tax'], -1),
        if (now['due'] != null) 'due': sum(now['due'], now['tax'], -1),
      };
    }
    return refused;
  }

  /// A floor a test set up follows its checks: one that moves sits at its new table, one emptied into
  /// another check is off the map, and one handed over is its new server's.
  void _moveOnFloor(String orderId, List<Map<String, dynamic>> ops) {
    final plan = floor;
    if (plan == null) return;
    final status = <String, List<Map<String, dynamic>>>{
      for (final MapEntry(:key, :value) in (plan['status'] as Map? ?? const {}).entries)
        key as String: [...(value as List).cast<Map<String, dynamic>>()],
    };
    for (final op in ops.where((op) => op['kind'] == 'set_field')) {
      final data = (op['data'] as Map).cast<String, dynamic>();
      final at = status.keys.where((t) => status[t]!.any((c) => c['order_id'] == orderId)).firstOrNull;
      if (at == null) {
        // a bar tab the hub lists is at no table until it is given one: then it is that table's check
        final tab = orders.where((o) => o['order_id'] == orderId && (o['fields'] as Map)['tab'] == true).firstOrNull;
        if (tab == null || data['table'] == null) return;
        status.putIfAbsent(data['table'] as String, () => []).add({
          'order_id': orderId,
          'guests': data['guests'],
          'server': data['server'] ?? (tab['fields'] as Map)['server'],
          'server_id': data['server_id'] ?? (tab['fields'] as Map)['server_id'],
          'opened_ms': 1800000000000,
          'items': (tab['lines'] as Map).length,
          'fired': <String>[],
          'held': <String>[],
          'total': '0.00',
        });
        continue;
      }
      final check = status[at]!.firstWhere((c) => c['order_id'] == orderId);
      if (data.containsKey('server')) {
        check['server'] = data['server'];
        check['server_id'] = data['server_id'];
      }
      if (data.containsKey('guests')) check['guests'] = data['guests'];
      if (data['table'] != null || data['merged_into'] != null) {
        status[at]!.remove(check);
        if (status[at]!.isEmpty) status.remove(at);
      }
      if (data['table'] != null) status.putIfAbsent(data['table'] as String, () => []).add(check);
    }
    floor = {...plan, 'status': status};
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
          // a dish that comes from another check is filled in from there: what it is, and whether it was sent
          final from = data['from'] as Map?;
          final source =
              (orders.where((o) => o['order_id'] == from?['order_id']).firstOrNull?['lines'] as Map?)?[from?['line_id']]
                  as Map?;
          lines[data['line_id'] as String] = {
            'item': source?['item'] ?? data['item'],
            'qty': source?['qty'] ?? data['qty'] ?? 1,
            'seat': data['seat'],
            'course': data['course'],
            'note': data['note'] ?? '',
            'request': data['request'],
            'replaces': data['replaces'], // an edit: the line this one took the place of
            'by': data['by'] ?? '',
            'by_id': data['by_id'],
            'status': 'active',
            'fired': source?['fired'] == true,
            'sent_ms': ?source?['sent_ms'], // it keeps the time it was sent at its old table
            'moved_from': ?from,
            'rank': data['rank'] ?? (ranks.isEmpty ? 1.0 : ranks.reduce(max) + 1),
          };
        case 'move_line':
          // gone to another check: off this one with no void, sent or not
          final line = lines[data['line_id']] as Map?;
          if (line != null && line['status'] == 'active') {
            line['status'] = 'removed';
            line['moved_to'] = data['to'];
          }
        case 'set_line':
          final line = lines[data['line_id']] as Map?;
          for (final field in const ['qty', 'seat', 'course', 'note', 'rank', 'checks']) {
            if (line != null && data.containsKey(field)) line[field] = data[field];
          }
        case 'set_field' when data.containsKey('split'):
          // how the table pays: the one field of an order these tests read back
          (order['fields'] as Map)['split'] = data['split'];
        case 'set_field' when data.containsKey('table') || data.containsKey('merged_into'):
          // the check moved to another table, or was emptied into another check
          for (final field in const ['table', 'merged_into']) {
            if (data.containsKey(field)) (order['fields'] as Map)[field] = data[field];
          }
        case 'set_field' when data.containsKey('customer_name'):
          // the name on a bar tab, changed
          (order['fields'] as Map)['customer_name'] = data['customer_name'];
        case 'void_line':
          final line = lines[data['line_id']] as Map?;
          if (line != null) line['status'] = line['fired'] == true ? 'void' : 'removed';
        case 'fire':
          // what was waiting is sent now, by the stamp of the screen that sent it; a hub that [tellsSent]
          final at = int.tryParse((op['hlc'] as String? ?? '').split('-').first);
          for (final line in lines.values.cast<Map>()) {
            if (line['status'] == 'active' && (data['course'] == '*' || line['course'] == data['course'])) {
              if (line['fired'] != true && tellsSent) line['sent_ms'] = at;
              line['fired'] = true;
            }
          }
        case 'allergy':
          final told = [...(order['allergies'] as List? ?? const []).cast<Map<String, dynamic>>()];
          told.removeWhere((a) => a['seat'] == data['seat']);
          if ((data['allergens'] as List).isNotEmpty || (data['note'] as String).isNotEmpty) {
            told.add({
              'seat': data['seat'],
              'allergens': data['allergens'],
              'note': data['note'],
              'by': data['by'] ?? '',
              'by_id': data['by_id'],
            });
          }
          order['allergies'] = told..sort((a, b) => (a['seat'] as int? ?? 0).compareTo(b['seat'] as int? ?? 0));
      }
    }
    // each dish against the table's allergy and its own seat's, by what the menu says it contains
    final told = (order['allergies'] as List? ?? const []).cast<Map<String, dynamic>>();
    for (final line in lines.values.cast<Map>()) {
      final contains = ((line['priced'] as Map?)?['contains'] as List?) ?? const [];
      line['allergy'] = <String>{
        for (final a in told)
          if (a['seat'] == null || a['seat'] == line['seat'])
            for (final code in a['allergens'] as List)
              if (contains.contains(code)) code as String,
      }.toList();
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
  await pumpOrdersOn(tester, t);
  return t;
}

/// The list of orders on a terminal whose hub a test has already set up.
Future<void> pumpOrdersOn(WidgetTester tester, Terminal t) async {
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
}

Future<void> stop(WidgetTester tester) => tester.pumpWidget(const SizedBox()); // stops the refresh timers

/// A pretend hub that also has the change feed (`GET /live`): the other calls go to [hub], and the test
/// says what the feed tells with [hello], [changed], [beat] and [drop]. With [beats], it writes its
/// heartbeat by itself for as long as the test pumps time.
class LiveHub {
  LiveHub(this.hub, {this.base = 'http://hub:8000'});

  final Hub hub;
  final String base;

  /// The streams terminals hold open now, and how many were ever opened and closed by the terminal.
  final open = <StreamController<List<int>>>[];
  int opened = 0;
  int hungUp = 0;

  /// What the feed call carried last, and what an older hub answers it with (404), or null for a hub that has it.
  http.BaseRequest? asked;
  int? refuse;

  /// Unreachable: every call fails, the feed's included.
  bool down = false;
  Timer? _beats;

  http.Client get client => MockClient.streaming(handle);

  Future<http.StreamedResponse> handle(http.BaseRequest request, http.ByteStream body) async {
    if (down) throw const SocketException('down');
    if (request.url.path == '/live') {
      asked = request;
      hub.requests.add('GET /live');
      if (refuse != null) return http.StreamedResponse(Stream.value(utf8.encode('{"detail":"Not Found"}')), refuse!);
      opened += 1;
      late final StreamController<List<int>> stream;
      stream = StreamController<List<int>>(
        onCancel: () {
          hungUp += 1;
          open.remove(stream);
        },
      );
      open.add(stream);
      return http.StreamedResponse(stream.stream, 200, headers: {'content-type': 'text/event-stream; charset=utf-8'});
    }
    final copy = http.Request(request.method, request.url)
      ..headers.addAll(request.headers)
      ..bodyBytes = await body.toBytes();
    final response = await hub.handle(copy);
    return http.StreamedResponse(Stream.value(response.bodyBytes), response.statusCode, headers: response.headers);
  }

  void _write(String text) {
    for (final stream in [...open]) {
      stream.add(utf8.encode(text));
    }
  }

  void say(String event, Map<String, dynamic> data) => _write('event: $event\ndata: ${jsonEncode(data)}\n\n');

  void hello({double heartbeat = 1.0}) => say('hello', {'cursor': 0, 'menu': 1, 'heartbeat': heartbeat});

  void changed({List<String> orders = const [], List<String> topics = const [], bool everything = false}) =>
      say('changed', {'orders': orders, 'topics': topics, if (everything) 'everything': true});

  void beat() => _write(':\n\n');

  /// Writes the heartbeat every second from now on (a timer of the test's own clock).
  void beats() => _beats ??= Timer.periodic(const Duration(seconds: 1), (_) => beat());

  /// The hub ends every stream, as it does when it restarts.
  void drop() {
    for (final stream in [...open]) {
      open.remove(stream);
      unawaited(stream.close());
    }
  }

  void close() {
    _beats?.cancel();
    _beats = null;
    drop();
  }
}
