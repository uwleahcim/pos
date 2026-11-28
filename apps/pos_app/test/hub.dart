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
import 'package:pos_app/customers.dart' show customerDigits, phoneDigits;
import 'package:pos_app/outbox.dart';
import 'package:pos_app/phone.dart';
import 'package:pos_app/photos.dart';
import 'package:pos_app/powers.dart';
import 'package:pos_app/printers.dart' show PrinterConfig;
import 'package:pos_app/queue_store.dart';
import 'package:pos_app/screens/home_bar.dart';
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

  /// Whether it marks an order that is brought to the customer on its papers (docs/delivery.md), and says
  /// so with its quotes, as the real hub does; false for a hub older than deliveries. [quotesOut] is what
  /// it answers: the quotes it keeps, and that word.
  bool delivers = true;
  Map<String, dynamic> get quotesOut => {...quotes, if (delivers) 'delivers': true};

  /// Whether it keeps a to-go order's step as it is told (ready, out with a driver, delivered and closed),
  /// as the real hub does, so a screen that reads the orders again shows it. Off, a step is only among
  /// what was [sent], which is all the tests of the list of checks look at.
  bool keepsStages = false;
  String? coursingAuth;
  String? refuse; // a reason the hub refuses the next coursing save with

  /// Whether a table has seats (`GET/PUT /settings/seats`); null is a hub older than the setting, which
  /// answers as it does for anything it has no word for. [seatsAuth] is who last set it.
  bool? seats = true;
  String? seatsAuth;

  /// What it knows of a customer, by the number's digits (`GET /customers/lookup`): a number it does not
  /// list is answered as everything is that this hub has no word for.
  final customers = <String, Map<String, dynamic>>{};

  /// The tags on a number, and nothing else about it (`GET /customers/tags`, what a call that rings asks):
  /// by the number's digits; null is a hub older than the call, which answers as it does for anything it
  /// has no word for. [tagAsks] are the numbers asked about, as their digits. [tagsDown] fails the call as
  /// if no hub answered.
  Map<String, List<String>>? ringTags;
  final tagAsks = <String>[];
  bool tagsDown = false;

  /// The tags of the guests seated on a check (`GET /orders/{id}/tags`, what a table's check asks): the
  /// tags [ringTags] has for the number of every reservation and every party seated with that check's id,
  /// each once, as the real hub answers. A hub with no [ringTags] is older than the call too.
  /// [tableTagAsks] are the checks asked about; [tableTagsDown] fails the call as if no hub answered.
  final tableTagAsks = <String>[];
  bool tableTagsDown = false;

  /// Who sits on a check (`GET /orders/{id}/seated`): every reservation and every party seated with that
  /// check's id, the first to sit first, each with its name, size, note and the tags of its number, and
  /// all their tags together, as the real hub answers. A hub that keeps no book and no waitlist has no
  /// such call, and with [seatedCall] off neither has one that keeps them: a hub that says the tags and
  /// not yet who. [seatedAsks] are the checks asked about; [tableTagsDown] fails this call too.
  bool seatedCall = true;
  final seatedAsks = <String>[];

  /// Who pays a check (`POST /orders/{id}/payer`): with [payerCall] on, the hub takes the word, and its
  /// answer about who sits says for each party the `key` it is known by, whether it left a number
  /// (`listed`) and whether it `pays`, as the real hub does. Off, as every hub before it: none of that, and
  /// no such call. [payers] is the party that pays each check, by its key; [payerSaid] every word taken, as
  /// (check, party, pays, by whom); [payerDown] fails the call as if no hub answered.
  bool payerCall = false;
  bool payerDown = false;
  final payers = <String, String>{};
  final payerSaid = <(String, String, bool, String)>[];

  /// Who paid, said afterwards from the guest list (`GET /reports/guests/payers`, `GET` and `POST
  /// /reports/guests/payers/{id}`). [paidChecks] is every check the hub noted guests on, by its id, each as
  /// the hub answers one; null is a hub older than this, which says no `waiting` in the guest list either.
  /// The ones that `waits` are the list, the newest first, and what the guest list says of them
  /// (`waiting`) is counted from them. A word is kept as the real hub keeps it: that guest pays and no
  /// other, said by [paidBy]; taken back, the number typed on the check pays, or its only guest, or it
  /// waits. [paidSaid] is every word taken, as (check, guest, pays); [paidAsks] the checks read one by one;
  /// [paidListAsks] how often the list was read; [paidAuth] the token of the last of these calls;
  /// [paidDown] fails these calls as if no hub answered, and [refusePaid] answers the word with that status.
  Map<String, Map<String, dynamic>>? paidChecks;
  final paidSaid = <(String, String, bool)>[];
  final paidAsks = <String>[];
  int paidListAsks = 0;
  String? paidAuth;
  String paidBy = 'Mike';
  bool paidDown = false;
  int? refusePaid;

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

  /// What a delivery costs the customer (`GET/PUT /settings/delivery_fee`, docs/delivery.md, "The delivery
  /// fee"), the token the last save carried and a reason to refuse the next save with. Null is a hub older
  /// than the fee, which charges none: what the tests written before it still run against. [milesFees] is
  /// a list by miles, as a location might set it.
  Map<String, dynamic>? deliveryFees;
  String? deliveryFeesAuth;
  String? refuseDeliveryFees;

  /// [milesFees] on a hub that lets the fee of a delivery further than the last band be typed ("A custom
  /// fee for a delivery further away"), and [mapFees] on one: what a hub of today says. [milesFees] and
  /// [mapFees] themselves say nothing of it, as a hub older than the custom fee does.
  static Map<String, dynamic> get customFees => {...milesFees, 'custom': true};
  static Map<String, dynamic> get customMapFees => {...mapFees, 'custom': true};

  /// Six prices by miles: more than a form shows as a button each ("More than four prices").
  static Map<String, dynamic> get manyFees => {
    'enabled': true,
    'by': 'miles',
    'bands': [
      {'up_to': '0.5', 'fee': '0.00'},
      {'up_to': '1', 'fee': '2.00'},
      {'up_to': '2', 'fee': '3.00'},
      {'up_to': '3', 'fee': '4.00'},
      {'up_to': '4.5', 'fee': '5.00'},
      {'up_to': '8', 'fee': '8.50'},
    ],
    'taxed': false,
    'custom': true,
  };

  static Map<String, dynamic> get milesFees => {
    'enabled': true,
    'by': 'miles',
    'bands': [
      {'up_to': '2', 'fee': '3.00'},
      {'up_to': '4.5', 'fee': '5.00'},
      {'up_to': '8', 'fee': '8.50'},
    ],
    'taxed': false,
  };

  /// [milesFees] on a hub with a map service and the restaurant's own address: a delivery's distance is
  /// looked up (docs/delivery.md, "Looking the distance up").
  static Map<String, dynamic> get mapFees => {
    ...milesFees,
    'origin': '1 Restaurant Row, Winchester',
    'maps': true,
    'lookup': true,
    'services': ['geocodio'],
  };

  /// [mapFees] on a hub with a second map service, asked when the first gives no distance ("A second map
  /// service"): what it alone knows is in [secondDistances].
  static Map<String, dynamic> get twoMapFees => {
    ...mapFees,
    'services': ['geocodio', 'google'],
  };

  /// [twoMapFees] on a hub where a manager turned live traffic on ("Live traffic"): a delivery for now is
  /// also told how long the drive is at this minute ([drivesNow]). [quietFees] is such a hub with live
  /// traffic left off.
  static Map<String, dynamic> get liveFees => {...twoMapFees, 'live': true};
  static Map<String, dynamic> get quietFees => {...twoMapFees, 'live': false};

  /// How long the drive to each address is right now, in minutes, as the service that knows the roads
  /// says it. An address not in it is one nobody could say for, and so is every address while [noRoads].
  final drivesNow = <String, int>{'12 Elm St, Winchester': 14, '4 Oak Rd, Woburn': 30, '3 Newbuild Way, Winchester': 6};
  bool noRoads = false;

  /// Live traffic as the hub has it (`GET/PUT /settings/live_drive`), the token the last save carried and
  /// a reason to refuse the next save with. Null is a hub older than live traffic. [liveOn] is one that
  /// has all it takes and is turned on; [liveOff] one that has all it takes and is off.
  Map<String, dynamic>? liveDrive;
  String? liveDriveAuth;
  String? refuseLiveDrive;
  static Map<String, dynamic> get liveOn => {
    'enabled': true,
    'before': 25,
    'traffic': true,
    'origin': true,
    'live': true,
  };
  static Map<String, dynamic> get liveOff => {...liveOn, 'enabled': false, 'live': false};

  /// Who is asked how far a delivery goes and who the drive right now (`GET/PUT /settings/drive_lookups`,
  /// docs/delivery.md, "Which service is asked first"): under `distance` and `traffic`, every service of
  /// that kind in the order they are asked, each with whether it is on, whether the hub has its key and
  /// what it has left today. Null is a hub older than the order. [driveLookupsSaved] is what each save
  /// sent, [driveLookupsAuth] the token of the last, and [refuseDriveLookups] a reason to refuse the next
  /// save with. On such a hub an answer about an address says who measured it and what that one has left.
  Map<String, dynamic>? driveLookups;
  String? driveLookupsAuth;
  final driveLookupsSaved = <Map<String, dynamic>>[];
  String? refuseDriveLookups;

  /// What each map service for the drive is called, and the words its terms want beside its figures.
  static const driveTitles = {
    'geocodio': 'Geocodio',
    'google': 'Google Maps',
    'mapbox': 'Mapbox',
    'azure': 'Azure Maps',
  };
  static const driveCredits = {
    'google': 'Google Maps',
    'mapbox': '\u00a9 Mapbox \u00a9 OpenStreetMap',
    'azure': 'Azure Maps',
  };

  /// One service as the hub says it stands: [left] of its day's [most] lookups, all of them unless said.
  static Map<String, dynamic> driveService(
    String name, {
    bool on = true,
    bool key = true,
    int most = 500,
    int? left,
    String? failing,
  }) => {
    'name': name,
    'title': driveTitles[name],
    'credit': driveCredits[name],
    'on': on,
    'key': key,
    'asks': on && key,
    'asked_today': key ? most - (left ?? most) : 0,
    'failed_today': failing == null ? 0 : 1,
    'daily_most': key ? most : null,
    'left': key ? left ?? most : null,
    'last_failure': key ? failing : null,
    'failing': key ? failing : null,
  };

  /// These services, asked one thing, in this order.
  static Map<String, dynamic> driveOrderOf(List<Map<String, dynamic>> services) => {
    'order': [for (final one in services) one['name']],
    'services': services,
  };

  /// A hub with a key for all four, as it stands before anybody changed a thing: Geocodio and then Google
  /// are asked how far, Google the roads, and Mapbox and Azure Maps wait to be turned on.
  static Map<String, dynamic> get driveLookupsUsual => {
    'distance': driveOrderOf([
      driveService('geocodio', left: 488),
      driveService('google', most: 100, left: 97),
      driveService('mapbox', on: false),
      driveService('azure', on: false, most: 15),
    ]),
    'traffic': driveOrderOf([
      driveService('google', most: 150, left: 141),
      driveService('mapbox', on: false),
      driveService('azure', on: false, most: 15),
    ]),
  };

  /// The names of the services that are asked for [purpose], in the order they are.
  List<String> driveAsking(String purpose) => [
    for (final one in ((driveLookups?[purpose] as Map?)?['services'] as List? ?? const []).cast<Map>())
      if (one['asks'] == true) one['name'] as String,
  ];

  /// What an answer says of the service that gave it, for the badge beside its figure.
  Map<String, dynamic> _driveLeft(String purpose, String name) {
    final one = ((driveLookups?[purpose] as Map?)?['services'] as List? ?? const [])
        .cast<Map>()
        .where((one) => one['name'] == name)
        .firstOrNull;
    return {'title': driveTitles[name] ?? name, 'left': one?['left'], 'daily_most': one?['daily_most']};
  }

  Future<http.Response> _driveLookups(http.Request request) async {
    final had = driveLookups;
    if (had == null) return json({'detail': 'Not Found'}, 404);
    if (request.method == 'PUT') {
      driveLookupsAuth = request.headers['authorization'];
      if (refuseDriveLookups != null) {
        return json({
          'detail': {'error': 'bad_value', 'message': refuseDriveLookups},
        }, 422);
      }
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      driveLookupsSaved.add(body);
      driveLookups = {
        for (final purpose in ['distance', 'traffic'])
          purpose: () {
            final all = ((had[purpose] as Map)['services'] as List).cast<Map<String, dynamic>>();
            final sent = body[purpose] as Map<String, dynamic>?;
            if (sent == null) return had[purpose];
            // one that is not named stays as it is, and one the order leaves out follows as it stood
            final asked = sent['order'] is List ? (sent['order'] as List).cast<String>() : const <String>[];
            return driveOrderOf([
              for (final one in [
                for (final name in asked) ...all.where((one) => one['name'] == name),
                ...all.where((one) => !asked.contains(one['name'])),
              ])
                {
                  ...one,
                  'on': sent[one['name']] is bool ? sent[one['name']] : one['on'],
                  'asks': (sent[one['name']] is bool ? sent[one['name']] : one['on']) == true && one['key'] == true,
                },
            ]);
          }(),
      };
      // the fee's setting and live traffic's say who is asked now
      final distance = driveAsking('distance'), traffic = driveAsking('traffic');
      final fees = deliveryFees;
      if (fees != null && fees.containsKey('maps')) {
        deliveryFees = {
          ...fees,
          'maps': distance.isNotEmpty,
          'lookup': distance.isNotEmpty && '${fees['origin'] ?? ''}'.isNotEmpty,
          'services': distance,
        };
      }
      final live = liveDrive;
      if (live != null) {
        final on = live['enabled'] == true && traffic.isNotEmpty && live['origin'] == true;
        liveDrive = {...live, 'traffic': traffic.isNotEmpty, 'live': on};
        if (deliveryFees?.containsKey('live') ?? false) deliveryFees = {...deliveryFees!, 'live': on};
      }
    }
    return json(driveLookups!);
  }

  /// How far the addresses it knows are (`POST /delivery/distance`): what the map says of each, as
  /// `{'miles': '3.2', 'minutes': 9}`. An address it does not know is one the map could not find. Every
  /// body it was asked with is in [distanceAsks]; [refuseDistance] is a reason the map gives no distance
  /// for ("unreachable"), and [distanceWaits], when set, holds each answer back until it completes.
  final distances = <String, Map<String, dynamic>>{
    '12 Elm St, Winchester': {'miles': '3.2', 'minutes': 9},
    '4 Oak Rd, Woburn': {'miles': '9.3', 'minutes': 21},
    '9 Main St, Winchester': {'miles': '1.1', 'minutes': 4},
  };
  final distanceAsks = <Map<String, dynamic>>[];
  String? refuseDistance;
  Completer<void>? distanceWaits;

  /// What customers' own earlier deliveries say ("Customers who order again"): by the number's digits and
  /// then the address, what the map said that time. A form that sends the number is answered from here,
  /// `saved`, and the map is not asked (so [refuseDistance] does not matter), unless it says `fresh`.
  final savedDistances = <String, Map<String, Map<String, dynamic>>>{};

  /// Who measured a distance and from where, as the hub says beside every answer and is sent back with
  /// the pick.
  static const mapMark = {'service': 'geocodio', 'from': '0a1b2c3d'};

  /// What the second map service says of the addresses the first gives no distance for ("A second map
  /// service"), on a hub whose fees name two services. Its answers say who measured them, the name to
  /// show beside them, and that they are not to be kept ([secondSays]).
  final secondDistances = <String, Map<String, dynamic>>{
    '3 Newbuild Way, Winchester': {'miles': '1.6', 'minutes': 5},
    '70 Far End Rd, Burlington': {'miles': '9.4', 'minutes': 22},
  };
  static const secondSays = {'service': 'google', 'from': '0a1b2c3d', 'credit': 'Google Maps', 'keep': false};

  /// The list of addresses while typing (`POST /addresses/suggest`): what the hub lists for the letters
  /// typed, by those letters on one line and in small letters. Null is a hub older than the list. Every
  /// body it was asked with is in [addressAsks]; [addressWaits], when set, holds each answer back until it
  /// completes; [addressesDown] fails the call as if no hub answered. For the restaurant's own address
  /// (`own` false) only a map service's lines are listed.
  Map<String, List<Map<String, dynamic>>>? addressLists;
  final addressAsks = <Map<String, dynamic>>[];
  Completer<void>? addressWaits;
  bool addressesDown = false;

  /// One line of such a list, as the hub says it. [parts] are the address's parts where the map service
  /// told them apart (`street`, `unit`, `city`, `state`, `zip`), and [ref] the service's own name for the
  /// place where its list leaves the ZIP out and the hub can be asked for it ([addressWholes]).
  static Map<String, dynamic> addressLine(
    String address, {
    String from = 'orders',
    String? main,
    String rest = '',
    Map<String, String>? parts,
    String? ref,
  }) => {'address': address, 'main': main ?? address, 'rest': rest, 'from': from, 'parts': ?parts, 'ref': ?ref};

  /// The parts of a tapped line that its list left out (`POST /addresses/whole`), by the service's own name
  /// for the place. A name that is not in it gets `parts` null, as from a service that did not answer.
  /// Every body the hub was asked with is in [wholeAsks]; [wholeWaits], when set, holds each answer back
  /// until it completes. A hub older than the parts ([addressWholes] null) has no such call.
  Map<String, Map<String, String>>? addressWholes = {};
  final wholeAsks = <Map<String, dynamic>>[];
  Completer<void>? wholeWaits;

  /// A hub that knows Elm Street from its own orders and two more from Google, for "12 el" and "12 elm".
  static Map<String, List<Map<String, dynamic>>> get elmLists {
    final listed = [
      addressLine('12 Elm St, Winchester', from: 'customer'),
      addressLine('12 Elm Ct, Woburn'),
      addressLine('12 Elm Street, Medford, MA', from: 'google', main: '12 Elm Street', rest: 'Medford, MA'),
      addressLine('12 Elmwood Road, Winchester, MA', from: 'google', main: '12 Elmwood Road', rest: 'Winchester, MA'),
    ];
    return {'12 el': listed, '12 elm': listed, '12 elm s': listed.sublist(0, 3)};
  }

  /// The list's setting (`GET/PUT /settings/address_list`) and the token the last save carried; null is a
  /// hub older than the list. Under `services`, every map service in the order they are asked, each with
  /// whether a manager turned it on and whether the hub has a key for it; a setting without them is a hub
  /// from before there were several, which knows Google alone. [addressTry] is what a try of a map service
  /// says (`POST /settings/address_list/try`), [addressTries] how often one was tried and [addressTried]
  /// which service each try named (null for a try that named none).
  Map<String, dynamic>? addressList;
  String? addressListAuth;
  Map<String, dynamic> addressTry = {'ok': true, 'found': 3, 'reason': null, 'message': '', 'left': 9411};
  int addressTries = 0;
  final addressTried = <String?>[];

  /// What each save of the list's setting sent, on a hub that knows the services.
  final addressSaved = <Map<String, dynamic>>[];

  /// What each map service is called, and the words under a list with one of its answers.
  static const addressTitles = {'google': 'Google Maps', 'mapbox': 'Mapbox', 'azure': 'Azure Maps'};
  static const addressCredits = {
    'google': 'Google Maps',
    'mapbox': '\u00a9 Mapbox \u00a9 OpenStreetMap',
    'azure': 'Azure Maps',
  };
  static const addressMost = {'google': 9500, 'mapbox': 95000, 'azure': 47500};

  /// One map service under `services`, as the hub says it stands.
  static Map<String, dynamic> addressService(
    String name, {
    bool on = false,
    bool key = true,
    int? left,
    bool resting = false,
  }) {
    final most = addressMost[name]!;
    final had = key ? (left ?? most) : null;
    return {
      'name': name,
      'title': addressTitles[name],
      'credit': addressCredits[name],
      'on': on,
      'key': key,
      'asks': on && key,
      'left': had,
      'monthly_most': most,
      'used_up': had != null && had < 1,
      'resting': key && resting,
    };
  }

  /// A hub with keys for Google and Mapbox and none for Azure Maps, all three off.
  static Map<String, dynamic> get addressListOff =>
      addressListOf([addressService('google'), addressService('mapbox'), addressService('azure', key: false)]);

  /// The setting of these services, with what an app from before there were several reads beside them.
  /// [near] is how far around the restaurant addresses come first (null: a hub that does not say), and
  /// [origin] whether the hub knows the restaurant's own address. The services stand in the order they are
  /// asked, which the hub says under `order` unless it is one from before the order was the location's
  /// own ([ordered] false).
  static Map<String, dynamic> addressListOf(
    List<Map<String, dynamic>> services, {
    double? near = 4.0,
    bool origin = true,
    bool ordered = true,
  }) {
    final google = services.firstWhere((one) => one['name'] == 'google');
    return {
      for (final one in services) one['name'] as String: one['on'],
      if (near != null) ...{'near_miles': near, 'origin_set': origin},
      if (ordered) 'order': [for (final one in services) one['name']],
      'service': google['key'],
      'asks': google['asks'],
      'credit': 'Google Maps',
      'services': services,
    };
  }

  /// A hub from before there were several services: Google alone.
  static Map<String, dynamic> get addressListOld => {
    'google': false,
    'service': true,
    'asks': false,
    'credit': 'Google Maps',
  };

  /// How many free lookups the service that answered a list has left this month; null is a hub that does
  /// not say (one from before there were several).
  int? addressLeft = 9412;

  /// The rules of the points (docs/points.md; `GET/PUT /settings/points`); null is a hub older than points.
  /// A save is kept as the real hub keeps it: the rate, what earns and the days as sent, in force from
  /// [pointsToday] by [pointsKeeper]. [pointsSaves] is every save as it was sent and [pointsAuth] the token
  /// of the last; [refusePoints] answers the next save with the hub's words for a value it does not take,
  /// and [pointsDown] fails it as if no hub answered.
  Map<String, dynamic>? points;
  final pointsSaves = <Map<String, dynamic>>[];
  String? pointsAuth;
  String? refusePoints;
  bool pointsDown = false;
  String pointsToday = '2026-11-16';
  String pointsKeeper = 'Mike';

  /// The points of each guest by the digits of their number, for who sits on a check (`points` of a party
  /// in `GET /orders/{id}/seated`): a number not listed has 0. Null, as on a hub where no rate was ever
  /// set, says nothing of points there.
  Map<String, int>? guestPoints;

  /// What a hub says of the points before anybody set a rate.
  static Map<String, dynamic> get pointsOff => {
    'on': false,
    'ever': false,
    'per_dollar': '0',
    'alcohol': false,
    'dine_in': true,
    'takeout': true,
    'delivery': true,
    'catering': true,
    'days': 365,
    'from': null,
    'by': '',
    'since': null,
    'earlier': <Map<String, dynamic>>[],
    'today': '2026-11-16',
    'per_dollar_most': '100',
    'days_least': 30,
    'days_most': 365,
  };

  /// One point a dollar since the first of November, set by Mike.
  static Map<String, dynamic> get pointsOn => {
    ...pointsOff,
    'on': true,
    'ever': true,
    'per_dollar': '1',
    'from': '2026-11-01',
    'by': 'Mike',
    'since': '2026-11-01',
  };

  Future<http.Response> _points(http.Request request) async {
    final had = points;
    if (had == null) return json({'detail': 'Not Found'}, 404);
    if (request.method != 'PUT') return json(had);
    if (pointsDown) throw const SocketException('down');
    pointsAuth = request.headers['authorization'];
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    pointsSaves.add(body);
    if (refusePoints != null) {
      return json({
        'detail': {'error': 'bad_value', 'message': refusePoints},
      }, 422);
    }
    const earning = ['per_dollar', 'alcohol', 'dine_in', 'takeout', 'delivery', 'catering'];
    final on = (double.tryParse('${body['per_dollar'] ?? had['per_dollar']}') ?? 0) > 0;
    final changed = earning.any((name) => body.containsKey(name) && body[name] != had[name]);
    final was = had['on'] == true || had['ever'] == true;
    points = {
      ...had,
      for (final name in [...earning, 'days'])
        if (body.containsKey(name)) name: body[name],
      'on': on,
      'ever': was || on,
      if (changed && (was || on)) ...{
        'from': pointsToday,
        'by': pointsKeeper,
        'since': had['since'] ?? pointsToday,
        'earlier': [
          if (was && had['from'] != pointsToday)
            {
              for (final name in earning) name: had[name],
              'from': had['from'],
              'by': had['by'],
              'until': DateTime.parse(pointsToday).subtract(const Duration(days: 1)).toIso8601String().substring(0, 10),
            },
          ...(had['earlier'] as List? ?? const []),
        ],
      },
    };
    return json(points!);
  }

  Future<http.Response> _suggest(http.Request request) async {
    final lists = addressLists;
    if (lists == null) return json({'detail': 'Not Found'}, 404);
    if (addressesDown) throw const SocketException('down');
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    addressAsks.add(body);
    await addressWaits?.future;
    final typed = '${body['typed']}'.trim().replaceAll(RegExp(r'\s+'), ' ');
    final listed = lists[typed.toLowerCase()] ?? const <Map<String, dynamic>>[];
    bool own(Map<String, dynamic> one) => one['from'] == 'customer' || one['from'] == 'orders';
    final shown = [
      for (final one in listed)
        if (body['own'] != false || !own(one)) one,
    ];
    final answered = shown.where((one) => !own(one)).map((one) => one['from'] as String).firstOrNull;
    return json({
      'typed': typed,
      'suggestions': shown,
      'credit': addressCredits[answered],
      if (addressLeft != null) ...{
        'service': answered,
        'title': addressTitles[answered],
        'left': answered == null ? null : addressLeft,
        'monthly_most': addressMost[answered],
      },
    });
  }

  Future<http.Response> _distance(http.Request request) async {
    final fees = deliveryFees;
    if (fees == null || !fees.containsKey('lookup')) return json({'detail': 'Not Found'}, 404);
    if (fees['lookup'] != true) {
      return json({
        'detail': {'error': 'no_lookup', 'message': 'this hub has no map service to ask'},
      }, 409);
    }
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    distanceAsks.add(body);
    await distanceWaits?.future;
    final kept = body['fresh'] == true ? null : savedDistances[body['phone']]?[body['address']];
    final first = kept ?? (refuseDistance == null ? distances[body['address']] : null);
    // whatever the first says, the second is tried
    final second = first == null && (fees['services'] as List? ?? const []).length > 1
        ? secondDistances[body['address']]
        : null;
    final said = first ?? second;
    if (said == null) {
      final reason = refuseDistance ?? 'not_found';
      return json({
        'detail': {
          'error': 'lookup_failed',
          'reason': reason,
          'message': reason == 'not_found'
              ? 'The map service could not find that address. Check it, or pick the fee by hand.'
              : 'The map service is not answering. Pick the fee by hand.',
        },
      }, 424);
    }
    final far = fees['by'] == 'minutes' ? (said['minutes'] as int).toDouble() : double.parse('${said['miles']}');
    final charged = fees['enabled'] == true && (fees['bands'] as List).isNotEmpty;
    Map? band;
    if (charged) {
      for (final listed in (fees['bands'] as List).cast<Map>()) {
        if (far <= double.parse('${listed['up_to']}')) {
          band = listed;
          break;
        }
      }
    }
    // on a hub that knows the order: the first that is asked measured what the first knows, the next one
    // the rest; and the first that is asked about the roads says the drive right now
    final asking = driveAsking('distance'), roads = driveAsking('traffic').firstOrNull;
    final who = driveLookups == null
        ? null
        : kept != null
        ? 'geocodio'
        : second != null && asking.length > 1
        ? asking[1]
        : asking.firstOrNull;
    return json({
      ...said,
      'by': fees['by'],
      'band': band,
      'beyond': charged && band == null,
      ...mapMark,
      // a hub that knows of second services says both of every answer
      if (fees.containsKey('services')) ...{'credit': null, 'keep': true},
      if (second != null) ...secondSays,
      if (who != null) ...{
        'service': who,
        'credit': driveCredits[who],
        'keep': who == 'geocodio',
        ..._driveLeft('distance', who),
      },
      'saved': kept != null,
      // a hub that knows of live traffic says the drive right now, or that nobody could say
      if (fees.containsKey('live'))
        'drive_now': fees['live'] == true && body['now'] == true && !noRoads && drivesNow[body['address']] != null
            ? {
                'minutes': drivesNow[body['address']],
                'before': liveDrive?['before'] ?? 25,
                'credit': driveLookups == null ? 'Google Maps' : driveCredits[roads],
                if (driveLookups != null && roads != null) ...{'service': roads, ..._driveLeft('traffic', roads)},
              }
            : null,
    });
  }

  /// A band's reach as the hub writes it: "2", "2.5".
  static String _reach(Object? value) => double.parse('$value').toString().replaceFirst(RegExp(r'\.0$'), '');

  /// A picked fee as the hub fills it in from its prices: the band's price, what it goes by, whether it is
  /// taxed. No band: no fee on purpose. A band it does not list: nothing is kept.
  Map<String, dynamic>? _feeFor(Object? picked) {
    if (picked is! Map) return null;
    // what the map said of the address travels with the pick, and is kept beside it
    final told = {if (picked['measured'] case final Map measured) 'measured': measured};
    final fees = deliveryFees;
    // a custom fee, for a delivery further than the bands reach: the amount as it was typed
    if (picked['custom'] case final String typed) {
      return {'by': 'custom', 'up_to': null, 'amount': typed, 'taxed': fees?['taxed'] == true, ...told};
    }
    if (picked['up_to'] == null) return {'up_to': null, 'amount': '0.00', ...told};
    for (final band in (fees?['bands'] as List? ?? const []).cast<Map>()) {
      if (band['up_to'] == _reach(picked['up_to'])) {
        return {
          'by': fees!['by'],
          'up_to': band['up_to'],
          'amount': band['fee'],
          'taxed': fees['taxed'] == true,
          ...told,
        };
      }
    }
    return null;
  }

  /// The to-go question it keeps (`GET/PUT /settings/bag`, docs/to-go-question.md), the token the last save
  /// carried and a reason to refuse the next save with. Null is a hub older than the question, which a
  /// terminal sends its to-go orders to with nothing asked: what the tests written before it still run
  /// against. [standardBag] is the question as a new hub has it.
  Map<String, dynamic>? bag;
  String? bagAuth;
  String? refuseBag;
  static Map<String, dynamic> get standardBag => {
    'enabled': true,
    'question': 'What goes in the bag?',
    'choices': [
      {'id': 'chopsticks', 'name': 'Chopsticks'},
      {'id': 'forks', 'name': 'Forks'},
      {'id': 'napkins', 'name': 'Napkins'},
    ],
  };

  /// The one-tap notes to the kitchen it keeps (`GET/PUT /settings/kitchen_notes`, docs/kitchen-notes.md),
  /// the token the last save carried and a reason to refuse the next save with. Null is a hub older than the
  /// notes, on which a dish's note is typed: what the tests written before them still run against.
  List<String>? kitchenNotes;
  String? kitchenNotesAuth;
  String? refuseKitchenNotes;
  static List<String> get standardKitchenNotes => [
    'Rush',
    'Split for 2',
    'Well done',
    'Less oil',
    'Less salt',
    'See server',
  ];

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

  /// Today so far (docs/today.md). [today] answers `GET /reports/today`; null is a hub older than it. Each
  /// ask's token is in [todayAuth] and they are counted in [todayAsks]. [refuseToday] answers with a status
  /// instead: 403 as the hub words a power taken back.
  Map<String, dynamic>? today;
  int todayAsks = 0;
  String? todayAuth;
  int? refuseToday;

  /// The rush (`PUT /settings/rush`), on a hub whose quotes name one (`'rush': null` for none): the minutes
  /// it was set to, in order, and the token of the last ask.
  final rushSet = <int>[];
  String? rushAuth;

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

  /// The same days as a table for a spreadsheet (docs/sales-report.md, "For the accountant"). [sheets]
  /// answers `GET /reports/sales/sheet` by the days asked for, written as [sales] writes them; a span it has
  /// nothing for reads a line of zeroes for each of its days, and null is a hub older than the table. Each
  /// ask is in [sheetAsks] and the token of the last one in [sheetAuth]. [refuseSheet] answers with a status
  /// instead. While [sheetHeld] is set no answer goes out until a test completes it.
  Map<String, Map<String, dynamic>>? sheets = {};
  Completer<void>? sheetHeld;
  final sheetAsks = <String>[];
  String? sheetAuth;
  int? refuseSheet;

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

  /// Suggestions taken over a span of days (docs/goes-with.md). [suggestions] answers
  /// `GET /reports/suggestions` by the days asked for, written as [sales] writes them; a span it has nothing
  /// for took nothing, and null is a hub older than the report. Each ask is in [suggestionsAsks] and the
  /// token of the last one in [suggestionsAuth]. [refuseSuggestions] answers with a status instead. While
  /// [suggestionsHeld] is set no answer goes out until a test completes it.
  Map<String, Map<String, dynamic>>? suggestions = {};
  Completer<void>? suggestionsHeld;
  final suggestionsAsks = <String>[];
  String? suggestionsAuth;
  int? refuseSuggestions;

  /// How long the kitchen took over a span of days (docs/kitchen-times.md). [kitchenTimes] answers
  /// `GET /reports/kitchen` by the days asked for, written as [sales] writes them; a span it has nothing for
  /// timed nothing, and null is a hub older than the report. Each ask is in [kitchenTimesAsks] and the token
  /// of the last one in [kitchenTimesAuth]. [refuseKitchenTimes] answers with a status instead. While
  /// [kitchenTimesHeld] is set no answer goes out until a test completes it.
  Map<String, Map<String, dynamic>>? kitchenTimes = {};
  Completer<void>? kitchenTimesHeld;
  final kitchenTimesAsks = <String>[];
  String? kitchenTimesAuth;
  int? refuseKitchenTimes;

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

  /// What the guest list writes about a guest (`PUT /reports/guests/<digits>`): every call is in
  /// [guestKeeps], the number with what was sent. The hub keeps it as the real one does: the guest's row in
  /// [guests] and in [guestDetails] gets the note and the tags sent (one left out stays), the tags each
  /// once and in the order of the alphabet, with [guestKeeper] as who wrote what changed at [clockNow].
  /// [refuseKeep] answers with that status instead and keeps nothing, [keepRefusal] its reason; while
  /// [keepHeld] is set no answer goes out until a test completes it.
  final guestKeeps = <(String, Map<String, dynamic>)>[];
  String guestKeeper = 'Mike';

  /// The name each number was tagged by (the `name` sent with its tags), kept while it carries a tag, as
  /// the real hub does. A hub whose list says `tagged` (the numbers that carry a tag and have no order in
  /// the year) keeps that list too: a number of no guest that is given a tag gets a row there under its
  /// name, and one whose last tag is taken off leaves it.
  final tagNames = <String, String>{};

  /// The row the real hub lists for a number that carries a tag and has no visit in the year.
  static Map<String, dynamic> taggedRow(
    String phone,
    String name,
    List<String> tags, {
    String note = '',
    int? sinceMs,
    int ordersEver = 0,
  }) => {
    'phone': phone,
    'name': name,
    'note': note,
    'tags': tags,
    'visits': 0,
    'spent': '0.00',
    'per_visit': null,
    'last': null,
    'first': null,
    'since_ms': sinceMs,
    'orders_ever': ordersEver,
    'lately': 0,
    'regular': false,
    'lapsed': false,
    'new': false,
    'favourites': <Map<String, dynamic>>[],
  };
  int? refuseKeep;
  String keepRefusal = 'a guest carries 6 tags at most';
  Completer<void>? keepHeld;

  /// The box that tags a guest from their reservation or the waitlist (`GET /reports/guests/tags`,
  /// docs/guest-list.md): [tagBox] false is a hub older than it, which takes "tags" for a guest's number
  /// and knows none. It offers the two standard tags and every tag some number of [ringTags] carries, each
  /// with how many do, and says what the number asked about carries. [tagBoxAsks] are the numbers asked
  /// about, each with the token its ask carried; [refuseTagBox] answers with that status instead, and
  /// [tagBoxDown] fails the call as if no hub answered. A tag kept for a number ([_keepGuest]) is then on
  /// that number in [ringTags] and on its reservations and its parties, as the real hub answers them.
  bool tagBox = true;
  final tagBoxAsks = <(String, String?)>[];
  int? refuseTagBox;
  bool tagBoxDown = false;

  http.Response _tagBox(http.Request request) {
    if (tagBoxDown) throw const SocketException('down');
    final digits = phoneDigits(request.url.queryParameters['phone']);
    tagBoxAsks.add((digits, request.headers['authorization']));
    if (refuseTagBox != null) {
      return json({
        'detail': {'error': refuseTagBox == 403 ? 'not_allowed' : 'sign_in', 'message': 'sign in with a manager PIN'},
      }, refuseTagBox!);
    }
    final kept = ringTags ?? const <String, List<String>>{};
    final counts = <String, int>{'VIP': 0, 'Friend of the house': 0};
    for (final tags in kept.values) {
      for (final tag in tags) {
        counts[tag] = (counts[tag] ?? 0) + 1;
      }
    }
    final offered = counts.entries.toList()
      ..sort((a, b) => a.value != b.value ? b.value - a.value : a.key.toLowerCase().compareTo(b.key.toLowerCase()));
    final carried = kept[digits] ?? const <String>[];
    return json({
      'tags': [
        for (final one in offered) {'tag': one.key, 'guests': one.value},
      ],
      'tag_max': 24,
      'tags_most': 6,
      'phone': digits,
      'carried': carried,
      'tags_by': carried.isEmpty ? '' : guestKeeper,
      'tags_ms': carried.isEmpty ? null : clockNow,
    });
  }

  /// The checks that wait for who paid, the newest first.
  List<Map<String, dynamic>> _waitingChecks() =>
      [
        for (final check in paidChecks!.values)
          if (check['waits'] == true) check,
      ]..sort((a, b) {
        final day = (b['day'] as String).compareTo(a['day'] as String);
        return day != 0 ? day : (b['opened_ms'] as int? ?? 0).compareTo(a['opened_ms'] as int? ?? 0);
      });

  /// What the guest list says of them: how many, and what they come to.
  Map<String, dynamic> _waiting() {
    final waits = _waitingChecks();
    final cents = waits.fold<int>(0, (sum, check) => sum + (double.parse(check['net'] as String) * 100).round());
    return {'checks': waits.length, 'net': (cents / 100).toStringAsFixed(2)};
  }

  http.Response _paid(http.Request request, String path) {
    paidAuth = request.headers['authorization'];
    if (paidDown) throw const SocketException('down');
    if (path == '/reports/guests/payers') {
      paidListAsks++;
      return json({'first': '2025-11-17', 'last': '2026-11-16', 'now_ms': clockNow, 'checks': _waitingChecks()});
    }
    final id = path.substring('/reports/guests/payers/'.length);
    final check = paidChecks![id];
    if (request.method == 'GET') paidAsks.add(id);
    if (check == null) {
      return json({
        'detail': {
          'error': 'no_check',
          'message': 'This check is no visit of the last year, or the hub noted no guest on it.',
        },
      }, 404);
    }
    if (request.method == 'GET') return json(check);
    if (refusePaid != null) {
      return json({
        'detail': {'error': 'sign_in', 'message': salesRefusal},
      }, refusePaid!);
    }
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    final key = body['guest'] as String? ?? '';
    final pays = body['pays'] != false;
    final guests = (check['guests'] as List).cast<Map<String, dynamic>>();
    if (guests.every((guest) => guest['key'] != key)) {
      return json({
        'detail': {'error': 'unknown_guest', 'message': 'This guest is not a guest of this check any more.'},
      }, 404);
    }
    paidSaid.add((id, key, pays));
    final one = guests.firstWhere((guest) => guest['key'] == key);
    final wasBy = check['said_by'] as String? ?? '';
    // the guest somebody said: this one now, or whoever was said before when the word taken back is not theirs
    final before = wasBy.isEmpty ? null : guests.where((guest) => guest['pays'] == true).firstOrNull;
    final said = pays ? (one['typed'] == true ? null : one) : (identical(before, one) ? null : before);
    // for want of a word: the number typed on the check, or its only guest
    final byItself =
        guests.where((guest) => guest['typed'] == true).firstOrNull ?? (guests.length == 1 ? guests.single : null);
    final payer = said ?? byItself;
    paidChecks![id] = {
      ...check,
      'guests': [
        for (final guest in guests) {...guest, 'pays': identical(guest, payer)},
      ],
      'waits': payer == null,
      'said_by': said == null ? '' : (pays ? paidBy : wasBy),
    };
    return json(paidChecks![id]!);
  }

  Future<http.Response> _keepGuest(http.Request request, String phone) async {
    guestsAuth = request.headers['authorization'];
    final sent = jsonDecode(request.body) as Map<String, dynamic>;
    guestKeeps.add((phone, sent));
    if (keepHeld != null) await keepHeld!.future;
    if (refuseKeep != null) {
      return json({
        'detail': {'error': refuseKeep == 422 ? 'bad_value' : 'sign_in', 'message': keepRefusal},
      }, refuseKeep!);
    }
    final ordered = (guests?['guests'] as List? ?? const []).cast<Map<String, dynamic>>();
    final others = guests?['tagged'] is List ? (guests!['tagged'] as List).cast<Map<String, dynamic>>() : null;
    final rows = [...ordered, ...?others];
    final listed = rows.where((row) => row['phone'] == phone).firstOrNull;
    final detail = guestDetails[phone];
    final row = listed ?? (detail?['guest'] as Map<String, dynamic>?) ?? <String, dynamic>{'phone': phone};
    final was = (
      note: row['note'] as String? ?? '',
      tags: [...?((row['tags'] as List?)?.cast<String>() ?? ringTags?[phone])],
    );
    final note = sent.containsKey('note') ? (sent['note'] as String).trim().replaceAll(RegExp(r'\s+'), ' ') : was.note;
    final tags = sent.containsKey('tags')
        ? ({for (final tag in (sent['tags'] as List).cast<String>()) tag.toLowerCase(): tag}.values.toList()
            ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase())))
        : was.tags;
    final sameNote = note == was.note, sameTags = '$tags' == '${was.tags}';
    final before = detail ?? const <String, dynamic>{};
    final answer = <String, dynamic>{
      'phone': phone,
      'note': note,
      'note_by': sameNote ? (before['note_by'] ?? '') : guestKeeper,
      'note_ms': note.isEmpty ? null : (sameNote ? before['note_ms'] : clockNow),
      'tags': tags,
      'tags_by': sameTags ? (before['tags_by'] ?? '') : guestKeeper,
      'tags_ms': tags.isEmpty ? null : (sameTags ? before['tags_ms'] : clockNow),
    };
    for (final kept in [?listed, ?(detail?['guest'] as Map<String, dynamic>?)]) {
      kept['note'] = note;
      kept['tags'] = tags;
    }
    // the name comes with the tags and stays while the number carries one
    final said = (sent['name'] as String? ?? '').trim().replaceAll(RegExp(r'\s+'), ' ');
    if (tags.isEmpty) {
      tagNames.remove(phone);
    } else if (said.isNotEmpty) {
      tagNames[phone] = said;
    }
    if (others != null && ordered.every((row) => row['phone'] != phone)) {
      others.removeWhere((row) => row['phone'] == phone && tags.isEmpty);
      final mine = others.where((row) => row['phone'] == phone).firstOrNull;
      if (mine != null) {
        mine['name'] = tagNames[phone] ?? '';
      } else if (tags.isNotEmpty) {
        others.add(taggedRow(phone, tagNames[phone] ?? '', tags, note: note));
      }
      others.sort((a, b) {
        final one = a['name'] as String, other = b['name'] as String;
        if (one.isEmpty != other.isEmpty) return one.isEmpty ? 1 : -1;
        final named = one.toLowerCase().compareTo(other.toLowerCase());
        return named != 0 ? named : (a['phone'] as String).compareTo(b['phone'] as String);
      });
    }
    // the tags are the number's wherever it turns up: on its call, its reservations and its parties
    ringTags?[phone] = tags;
    for (final row in [...?bookings, ...?parties]) {
      if (row.containsKey('tags') && phoneDigits(row['phone'] as String?) == phone) row['tags'] = tags;
    }
    if (detail != null) {
      for (final name in ['note_by', 'note_ms', 'tags_by', 'tags_ms']) {
        detail[name] = answer[name];
      }
    }
    return json(answer);
  }

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

  /// The hub's keys (docs/hub-keys.md). [hubKeys] is how each stands, by name, as `GET /hub/keys` says it;
  /// null is a hub older than keys typed in the app. Only Mike's token reads or changes them
  /// ([hubKeysAuth] keeps the last one sent). `PUT /hub/keys/<name>` puts the typed key in force as one typed
  /// in the app by Mike at [keysAtMs], keeping its last four characters (and for Apple's its ids) and never
  /// the key: what was typed is in [keysTyped]. [refuseHubKey] answers 422 with these words instead.
  /// `DELETE` removes it ([keysRemoved]). [hubKeysKept] false is a hub with nowhere to keep one.
  ///
  /// The restaurant's accounts with GloriaFood ("Several accounts", docs/online-orders.md): the first one
  /// is always there, called [firstAccountName] and for testing when [firstAccountTest], with the key
  /// `online`. [onlineAccounts] are the further ones (`{id, name, test}`), each with the key `online:<id>`
  /// kept in [accountKeys]; null is a hub from before there could be several, which lists none and knows
  /// none of the calls. `POST /hub/online/accounts` adds one ([accountsAdded] keeps what was typed, the key
  /// too), `PUT` names it or says it is for testing ([accountsChanged]) and `DELETE` removes it with its key
  /// ([accountsRemoved]). [refuseAccount] answers 422 with these words instead.
  ///
  /// The way in for GloriaFood's pushes (docs/online-orders.md, "Push"): the keys `online_push` and
  /// `online_tunnel`, and beside the keys [wayIn], which is the address GloriaFood sends to, whether the push
  /// door could be told its key, and how the tunnel stands ([tunnelStands]). Null is a hub from before these
  /// were typed in the app: it lists neither key, says nothing of the way in and knows none of its calls.
  /// A typed token starts the tunnel (`starting`, with [tunnelShown] as the start of its id), and every look
  /// at the keys after that takes the next of [tunnelNext] as how it stands ([hubKeysAsks] counts the looks).
  /// `PUT /hub/online/push/address` remembers the address ([addressesTyped]; [refuseAddress] answers 422
  /// with these words instead), and `POST /hub/online/push/try` answers [wayTried] ([wayTries] counts them),
  /// or 409 while the hub has no key for pushes.
  ///
  /// The texts to customers (docs/texts.md): the key `texts` is the restaurant's Twilio account, and beside
  /// the keys [texts] says how the texts are doing. Null is a hub from before texts really went out: it
  /// lists no such key, says nothing of the texts and does not know the try. A typed account turns the
  /// texts on (`provider` becomes `twilio`, sent from what was typed) and a removed one turns them off.
  /// `POST /hub/texts/try` answers [textTried] ([textTries] keeps the numbers typed), or 409 without an
  /// account.
  Map<String, Map<String, dynamic>>? hubKeys = {
    for (final name in [
      'maps',
      'maps_google',
      'maps_mapbox',
      'maps_azure',
      'online',
      'online_push',
      'online_tunnel',
      'push_apple',
      'texts',
    ])
      name: noKey(name),
  };
  Map<String, dynamic>? texts = textsStand();
  Map<String, dynamic> textTried = {'ok': true, 'state': 'delivered', 'code': null, 'said': ''};
  final textTries = <String>[];

  /// How the texts are doing, as the hub says it: off without a [sender], and with one the last day's
  /// count and the last text that did not go.
  static Map<String, dynamic> textsStand({
    String sender = '',
    int texts = 0,
    int failed = 0,
    Map<String, dynamic>? lastFailed,
  }) => sender.isEmpty
      ? {'provider': 'log', 'sender': '', 'day': null, 'last_failed': null}
      : {
          'provider': 'twilio',
          'sender': sender,
          'day': {'texts': texts, 'delivered': texts - failed, 'failed': failed},
          'last_failed': lastFailed,
        };
  Map<String, dynamic>? wayIn = {'address': '', 'door': true, 'tunnel_told': true, 'tunnel': tunnelStands('off')};
  final tunnelNext = <Map<String, dynamic>>[];
  String tunnelShown = '6ff42ae2';
  int hubKeysAsks = 0;
  final addressesTyped = <String>[];
  String? refuseAddress;
  Map<String, dynamic> wayTried = {
    'door': {'ok': true, 'reason': null, 'code': 401},
    'outside': null,
  };
  int wayTries = 0;

  /// How the tunnel stands, as the hub's tunnel program says it.
  static Map<String, dynamic> tunnelStands(
    String state, {
    bool there = true,
    int? sinceMs,
    String? reason,
    String said = '',
  }) => {'there': there, 'state': state, 'since_ms': sinceMs, 'reason': reason, 'said': said, 'version': '2026.10.0'};

  /// The two keys of the way in, which a hub from before them does not list.
  static const wayInKeys = {'online_push', 'online_tunnel'};
  List<Map<String, dynamic>>? onlineAccounts = [];
  String firstAccountName = '';
  bool firstAccountTest = false;
  final accountKeys = <String, Map<String, dynamic>>{};
  final accountsAdded = <Map<String, dynamic>>[];
  final accountsChanged = <(String, Map<String, dynamic>)>[];
  final accountsRemoved = <String>[];
  String? refuseAccount;
  int _accountIds = 0;
  bool hubKeysKept = true;
  String? hubKeysAuth;
  String? refuseHubKey;
  int keysAtMs = 1795000000000;
  final keysTyped = <(String, Map<String, dynamic>)>[];
  final keysRemoved = <String>[];

  /// A key nobody set, and one put on the hub in its terminal.
  static Map<String, dynamic> noKey(String name) => {
    'name': name,
    'set': false,
    'source': null,
    'ending': '',
    'shown': <String, dynamic>{},
    'by': '',
    'at_ms': null,
    'removed': false,
    'unreadable': false,
  };
  static Map<String, dynamic> hubKey(String name, {String ending = ''}) => {
    ...noKey(name),
    'set': true,
    'source': 'hub',
    'ending': ending,
  };

  /// The staff a manager changes in the app (docs/staff.md). [staffKept] is everybody on the list as
  /// `GET /hub/staff` says them; null is a hub older than the staff kept in the app. [staffSource] says
  /// whose list signs in (`hub`, `demo`, `app`) and [staffRoles] the roles the manager asking can give. Only
  /// Mike's token reads or changes it ([staffAuth] keeps the last one sent). `POST /hub/staff` adds
  /// somebody ([staffAdded] keeps what was typed, the PIN too, which no answer has), `PUT` changes a name, a
  /// role or a PIN ([staffChanged]) and `DELETE` takes somebody off ([staffRemoved]); each makes the list
  /// the app's, with a PIN set by Mike at [staffAtMs]. [refuseStaff] answers with this status, error and
  /// words instead.
  List<Map<String, dynamic>>? staffKept = [
    onStaff('s1', 'Amy', 'server'),
    onStaff('s2', 'Ben', 'bartender'),
    onStaff('s3', 'Mike', 'manager', you: true),
    onStaff('s4', 'Holly', 'host'),
  ];
  String staffSource = 'hub';
  List<String> staffRoles = ['server', 'bartender', 'host', 'cashier', 'kitchen', 'driver', 'manager', 'owner'];
  final staffAdded = <Map<String, dynamic>>[];
  final staffChanged = <(String, Map<String, dynamic>)>[];
  final staffRemoved = <String>[];
  (int, String, String)? refuseStaff;
  String? staffAuth;
  int staffAsks = 0;
  static const staffAtMs = 1795000000000;

  /// One person as `GET /hub/staff` lists them: where their PIN is [from], and what the manager asking may
  /// do to them ([you]: not their own role, not take themselves off; [ownerOnly]: nothing at all;
  /// [firstOwner]: nobody is an owner yet, so [you] may make themselves one).
  static Map<String, dynamic> onStaff(
    String id,
    String name,
    String role, {
    bool you = false,
    bool ownerOnly = false,
    bool firstOwner = false,
    String from = 'hub',
    String by = '',
    int? atMs,
  }) => {
    'staff_id': id,
    'name': name,
    'role': role,
    'you': you,
    'pin': {'from': from, 'by': by, 'at_ms': atMs},
    'can': {
      'change': !ownerOnly,
      'role': !ownerOnly && (!you || firstOwner),
      'remove': !ownerOnly && !you,
      'why': ownerOnly
          ? 'owner_only'
          : you
          ? 'yourself'
          : null,
    },
  };

  /// Makes its staff the demo staff, whose PINs are in the guide.
  void demoStaff() {
    staffSource = 'demo';
    staffKept = [
      for (final person in staffKept!)
        {
          ...person,
          'pin': {'from': 'demo', 'by': '', 'at_ms': null},
        },
    ];
  }

  /// What `GET /hub/staff` answers, and every call that changes the staff after it.
  Map<String, dynamic> staffSaid() => {
    'staff': staffKept,
    'source': staffSource,
    'roles': staffRoles,
    'demo_pins': staffKept!.where((person) => (person['pin'] as Map)['from'] == 'demo').length,
  };

  http.Response _staff(http.Request request) {
    if (staffKept == null) return json({'detail': 'Not Found'}, 404);
    staffAuth = request.headers['authorization'];
    if (staffAuth != 'Bearer tok-admin') {
      return json({
        'detail': {'error': 'not_allowed', 'power': 'settings'},
      }, staffAuth == null ? 401 : 403);
    }
    final id = request.url.pathSegments.length > 2 ? request.url.pathSegments[2] : null;
    if (request.method == 'GET') {
      staffAsks++;
      return json(staffSaid());
    }
    final typed = request.method == 'DELETE'
        ? const <String, dynamic>{}
        : jsonDecode(request.body) as Map<String, dynamic>;
    if (request.method == 'POST') staffAdded.add(typed);
    if (request.method == 'PUT') staffChanged.add((id!, typed));
    if (request.method == 'DELETE') staffRemoved.add(id!);
    final refused = refuseStaff;
    if (refused != null) {
      return json({
        'detail': {'error': refused.$2, 'message': refused.$3},
      }, refused.$1);
    }
    const byMike = {'from': 'app', 'by': 'Mike', 'at_ms': staffAtMs};
    final kept = staffKept!;
    if (request.method == 'POST') {
      final made = 's${kept.length + staffRemoved.length + 1}';
      kept.add({...onStaff(made, typed['name'] as String, typed['role'] as String), 'pin': byMike});
      staffSource = 'app';
      return json({...staffSaid(), 'added': made});
    }
    final at = kept.indexWhere((person) => person['staff_id'] == id);
    if (at < 0) {
      return json({
        'detail': {'error': 'unknown_staff', 'message': 'Nobody on the staff has this id.'},
      }, 404);
    }
    if (request.method == 'DELETE') {
      kept.removeAt(at);
    } else {
      kept[at] = {
        ...kept[at],
        if (typed['name'] != null) 'name': typed['name'],
        if (typed['role'] != null) 'role': typed['role'],
        if (typed['pin'] != null) 'pin': byMike,
      };
    }
    staffSource = 'app';
    return json(staffSaid());
  }

  Future<http.Response> _keys(http.Request request) async {
    if (hubKeys == null) return json({'detail': 'Not Found'}, 404);
    hubKeysAuth = request.headers['authorization'];
    if (hubKeysAuth != 'Bearer tok-admin') {
      return json({
        'detail': {'error': 'not_allowed', 'power': 'settings'},
      }, hubKeysAuth == null ? 401 : 403);
    }
    if (request.url.path.startsWith('/hub/online/accounts')) return _accounts(request);
    if (request.url.path.startsWith('/hub/online/push/')) return _wayIn(request);
    if (request.url.path == '/hub/texts/try') {
      if (texts == null) return json({'detail': 'Not Found'}, 404);
      textTries.add((jsonDecode(request.body) as Map<String, dynamic>)['to'] as String);
      if (hubKeys!['texts']!['set'] != true) {
        return json({
          'detail': {'error': 'no_service', 'message': 'this hub has no Twilio account yet'},
        }, 409);
      }
      return json({...hubKeysSaid(), 'tried': textTried});
    }
    final name = request.url.pathSegments.length > 2 ? request.url.pathSegments[2] : null;
    // an account's own key: `online:<id>`, of an account this hub has
    final further = name != null && name.startsWith('online:') ? name.substring(7) : null;
    final ofAccount = further != null && (onlineAccounts ?? const []).any((account) => account['id'] == further);
    final held = ofAccount ? accountKeys : hubKeys!;
    final older = (wayIn == null && wayInKeys.contains(name)) || (texts == null && name == 'texts');
    if (name != null && !ofAccount && (!hubKeys!.containsKey(name) || older)) {
      return json({
        'detail': {'error': 'unknown_key', 'message': 'this hub holds no key of that name'},
      }, 404);
    }
    if (request.method == 'PUT' && name != null) {
      final typed = jsonDecode(request.body) as Map<String, dynamic>;
      keysTyped.add((name, typed));
      if (refuseHubKey != null) {
        return json({
          'detail': {'error': 'bad_value', 'message': refuseHubKey},
        }, 422);
      }
      final key = typed['key'] as String;
      held[name] = {
        ...noKey(name),
        'set': true,
        'source': 'app',
        'ending': name == 'push_apple' || key.length < 16 ? '' : key.substring(key.length - 4),
        'shown': name == 'push_apple'
            ? {
                'key_id': typed['key_id'],
                'team_id': typed['team_id'],
                'bundle_id': '${typed['bundle_id'] ?? ''}'.isEmpty ? 'org.chinasky.posApp' : typed['bundle_id'],
              }
            : name == 'online_tunnel'
            ? {'tunnel': tunnelShown}
            : name == 'texts'
            ? {'account': typed['account'], 'sender': typed['sender'], 'key_sid': typed['key_sid'] ?? ''}
            : <String, dynamic>{},
        'by': 'Mike',
        'at_ms': keysAtMs,
      };
      if (name == 'texts') {
        held[name] = {...held[name]!, 'ending': ''};
        texts = textsStand(sender: typed['sender'] as String);
      }
      // the tunnel's program has not looked at the new token yet
      if (name == 'online_tunnel') wayIn = {...wayIn!, 'tunnel': tunnelStands('starting')};
    }
    if (request.method == 'DELETE' && name != null) {
      keysRemoved.add(name);
      held[name] = {...noKey(name), 'by': 'Mike', 'at_ms': keysAtMs, 'removed': true};
      if (name == 'online_tunnel') wayIn = {...wayIn!, 'tunnel': tunnelStands('off')};
      if (name == 'texts') texts = textsStand();
    }
    if (request.method == 'GET') {
      hubKeysAsks += 1;
      if (wayIn != null && tunnelNext.isNotEmpty) wayIn = {...wayIn!, 'tunnel': tunnelNext.removeAt(0)};
    }
    return json(hubKeysSaid());
  }

  http.Response _wayIn(http.Request request) {
    if (wayIn == null) return json({'detail': 'Not Found'}, 404);
    final typed = request.body.isEmpty ? <String, dynamic>{} : jsonDecode(request.body) as Map<String, dynamic>;
    if (request.url.path == '/hub/online/push/address' && request.method == 'PUT') {
      final address = typed['address'] as String;
      addressesTyped.add(address);
      if (refuseAddress != null) {
        return json({
          'detail': {'error': 'bad_value', 'message': refuseAddress},
        }, 422);
      }
      // as the hub cleans it: no https:// before it, no path after
      final name = address.trim().toLowerCase().replaceFirst(RegExp('^https?://'), '').split('/').first;
      wayIn = {...wayIn!, 'address': name};
      return json(hubKeysSaid());
    }
    if (request.url.path == '/hub/online/push/try' && request.method == 'POST') {
      wayTries += 1;
      if (hubKeys!['online_push']!['set'] != true) {
        return json({
          'detail': {'error': 'no_key', 'message': 'this hub has no key for pushes'},
        }, 409);
      }
      return json({...hubKeysSaid(), 'tried': wayTried});
    }
    return json({'detail': 'Method Not Allowed'}, 405);
  }

  /// What `GET /hub/keys` answers, and every call that changes a key or an account after it.
  Map<String, dynamic> hubKeysSaid() => {
    'keys': [
      for (final key in hubKeys!.values)
        if ((wayIn != null || !wayInKeys.contains(key['name'])) && (texts != null || key['name'] != 'texts')) key,
    ],
    'kept': hubKeysKept,
    'way_in': ?wayIn,
    'texts': ?texts,
    if (onlineAccounts != null)
      'online_accounts': [
        {'id': 'main', 'name': firstAccountName, 'test': firstAccountTest, 'key': hubKeys!['online']},
        for (final account in onlineAccounts!)
          {...account, 'key': accountKeys['online:${account['id']}'] ?? noKey('online:${account['id']}')},
      ],
  };

  http.Response _accounts(http.Request request) {
    final accounts = onlineAccounts;
    if (accounts == null) return json({'detail': 'Not Found'}, 404);
    final id = request.url.pathSegments.length > 3 ? request.url.pathSegments[3] : null;
    final typed = request.body.isEmpty ? <String, dynamic>{} : jsonDecode(request.body) as Map<String, dynamic>;
    http.Response refused() => json({
      'detail': {'error': 'bad_value', 'message': refuseAccount},
    }, 422);
    if (request.method == 'POST' && id == null) {
      accountsAdded.add(typed);
      if (refuseAccount != null) return refused();
      final made = 'a${_accountIds += 1}';
      final key = typed['key'] as String;
      accounts.add({'id': made, 'name': typed['name'], 'test': typed['test'] == true});
      accountKeys['online:$made'] = {
        ...noKey('online:$made'),
        'set': true,
        'source': 'app',
        'ending': key.length < 16 ? '' : key.substring(key.length - 4),
        'by': 'Mike',
        'at_ms': keysAtMs,
      };
      return json({...hubKeysSaid(), 'added': made});
    }
    final at = accounts.indexWhere((account) => account['id'] == id);
    if (id != 'main' && at < 0) {
      return json({
        'detail': {'error': 'unknown_account', 'message': 'this hub has no such account'},
      }, 404);
    }
    if (request.method == 'PUT') {
      accountsChanged.add((id!, typed));
      if (refuseAccount != null) return refused();
      if (id == 'main') {
        if (typed['name'] != null) firstAccountName = typed['name'] as String;
        if (typed['test'] != null) firstAccountTest = typed['test'] == true;
      } else {
        accounts[at] = {
          ...accounts[at],
          if (typed['name'] != null) 'name': typed['name'],
          if (typed['test'] != null) 'test': typed['test'] == true,
        };
      }
      return json(hubKeysSaid());
    }
    if (request.method == 'DELETE') {
      if (id == 'main') {
        return json({
          'detail': {'error': 'first_account', 'message': 'the first account stays: remove its key instead'},
        }, 409);
      }
      accountsRemoved.add(id!);
      accounts.removeAt(at);
      accountKeys.remove('online:$id');
      return json(hubKeysSaid());
    }
    return json({'detail': 'Method Not Allowed'}, 405);
  }

  /// The push relay as the keys page tries it: [pushDevices] are the screens that registered for
  /// notifications (`GET /push/status`), [pushTests] the ones a test went to (`POST /push/test`), and
  /// [pushRefused] is what Apple said instead of taking it ("BadDeviceToken").
  List<String> pushDevices = [];
  final pushTests = <String>[];
  String? pushRefused;

  http.Response _push(http.Request request) {
    if (request.url.path == '/push/test') {
      final device = (jsonDecode(request.body) as Map)['device'] as String;
      pushTests.add(device);
      final ok = pushRefused == null;
      return json({
        'device': device,
        'kind': 'alert',
        'configured': true,
        'tokens': 1,
        'sent': ok ? 1 : 0,
        'results': [
          {'ok': ok, 'status': ok ? 200 : 400, 'reason': pushRefused},
        ],
      });
    }
    return json({
      'configured': hubKeys?['push_apple']?['set'] == true,
      'list': [
        for (final device in pushDevices)
          for (final kind in ['alert', 'voip'])
            {'device': device, 'platform': 'ios', 'kind': kind, 'extension': '', 'token': 'abcd1234…'},
      ],
    });
  }

  /// Who may do what (docs/roles.md). [powers] is the table `GET /settings/powers` answers, for each power
  /// the roles it is handed to; null is a hub older than the table, where only Mike's PIN opens or approves
  /// anything. `PUT` lays the powers it names over it ([powersAuth] keeps its token; only Mike's is taken;
  /// [refusePowers] answers 422 with these words instead). [people] are the staff the pretend hub knows by
  /// PIN: `POST /admin/session` gives each a token of their own (`tok-admin` for Mike, `tok-<id>` for the
  /// rest) when the table hands their role the `power` asked for, or with none asked anything a session is
  /// for, and says which powers they hold ([sessionsFor] keeps each `power` asked); `POST /approvals` takes
  /// their PIN by the same table.
  Map<String, List<String>>? powers = {for (final id in powersById.keys) id: Powers.standard.handedTo(id)};

  /// The roles it hands powers to. A hub older than drivers (docs/delivery.md) knows [firstRoles] and has
  /// no `deliver` in its table: see [olderThanDrivers].
  List<String> handed = handedRoles;

  /// Makes it a hub from before drivers: five roles, no `deliver` in the table, a staff list that says
  /// nothing of who delivers.
  void olderThanDrivers() {
    handed = firstRoles;
    powers = {...?powers}..remove('deliver');
    roster = [
      for (final row in roster ?? const <Map<String, dynamic>>[]) {...row}..remove('delivers'),
    ];
  }

  /// Makes its staff a restaurant's that delivers: Tom and Wei are drivers, Mike the manager can take one
  /// out too, and nobody else is offered.
  void withDrivers() {
    roster = [
      for (final row in roster ?? const <Map<String, dynamic>>[]) {...row, 'delivers': row['role'] == 'manager'},
      {
        'staff_id': 'd1',
        'name': 'Tom',
        'role': 'driver',
        'takes_tables': false,
        'assigns_tables': false,
        'delivers': true,
      },
      {
        'staff_id': 'd2',
        'name': 'Wei',
        'role': 'driver',
        'takes_tables': false,
        'assigns_tables': false,
        'delivers': true,
      },
    ];
  }

  String? powersAuth;
  String? refusePowers;
  final sessionsFor = <String?>[];
  static const people = {
    '9999': ('s3', 'Mike', 'manager'),
    '1111': ('s1', 'Amy', 'server'),
    '2222': ('s2', 'Ben', 'bartender'),
    '3333': ('s4', 'Holly', 'host'),
  };

  /// What a role holds by [powers], as the hub lists it with a session: every power for a manager, and the
  /// settings after them.
  List<String> heldBy(String role) => [
    for (final id in powersById.keys)
      if (Powers(powers ?? Powers.standard.roles).holds(role, id)) id,
    if (alwaysRoles.contains(role)) settingsPower,
  ];

  /// Contests for the staff (docs/contests.md). [contests] is the location's list as the hub keeps it; null
  /// is a hub older than contests. `GET /settings/contests` answers it, each with where it stands on
  /// [contestsToday], and what a form needs. `PUT /settings/contests` keeps the list sent ([contestsSaved]
  /// holds each body, [contestsAuth] the token of the last): a new one is given an id from its name and
  /// what it counts is named from [contestDishes] and [contestCategories]; [refuseContests] answers 422
  /// with these words instead. [contestBoards] holds each contest's rows by its id (the one in front first)
  /// and [contestOthers] what the people outside it rang. `GET /contests?staff_id=` answers the contests on
  /// the staff's screens as that person may see each ([contestAsks] keeps who asked), and
  /// `GET /reports/contests/<id>` the whole board ([contestBoardAsks] keeps the ids, [contestBoardAuth] the
  /// token of the last; [refuseContestBoard] is a status it answers with instead).
  List<Map<String, dynamic>>? contests = [];
  String contestsToday = '2026-11-16';
  final contestsSaved = <Map<String, dynamic>>[];
  String? contestsAuth;
  String? refuseContests;
  final contestBoards = <String, List<Map<String, dynamic>>>{};
  final contestOthers = <String, Map<String, dynamic>>{};
  final contestAsks = <String>[];
  final contestBoardAsks = <String>[];
  String? contestBoardAuth;
  int? refuseContestBoard;
  static const contestDishes = {'TSINGTAO': 'Tsingtao', 'MAITAI': 'Mai Tai', 'WINGS': 'Chicken wings'};
  static const contestCategories = [
    {'code': 'sides', 'name': 'Appetizers', 'menu': 'Food'},
    {'code': 'chefs', 'name': "Chef's Specials", 'menu': 'Food'},
    {'code': 'beer', 'name': 'Beer', 'menu': 'Drinks'},
    {'code': 'cocktails', 'name': 'Cocktails', 'menu': 'Drinks'},
  ];

  /// A contest as the hub keeps it: on sales, for the Monday the tests run on, unless said otherwise.
  static Map<String, dynamic> contest(
    String id,
    String name, {
    String counts = 'sales',
    String? item,
    String? category,
    String what = '',
    String first = '2026-11-16',
    String last = '2026-11-16',
    List<String> roles = const ['server', 'bartender'],
    String board = 'own',
    String note = '',
  }) => {
    'id': id,
    'name': name,
    'note': note,
    'counts': counts,
    'item': item,
    'category': category,
    'what': what,
    'first': first,
    'last': last,
    'roles': roles,
    'board': board,
    'set_by': 'Mike',
    'set_ms': DateTime(2026, 11, 16, 15).millisecondsSinceEpoch,
  };

  /// A row of a board: [place] null is somebody with nothing yet.
  static Map<String, dynamic> contestRow(
    String staffId,
    String name,
    int? place, {
    int count = 0,
    String amount = '0.00',
    String role = 'server',
  }) => {'staff_id': staffId, 'name': name, 'role': role, 'count': count, 'amount': amount, 'place': place};

  Map<String, dynamic> _contestAbout(Map<String, dynamic> contest) {
    final today = DateTime.parse(contestsToday);
    final first = DateTime.parse(contest['first'] as String), last = DateTime.parse(contest['last'] as String);
    return {
      ...contest,
      'state': today.isBefore(first) ? 'coming' : (today.isAfter(last) ? 'over' : 'running'),
      'shown': !today.isAfter(last.add(const Duration(days: 7))),
      'days': last.difference(first).inDays + 1,
    };
  }

  Map<String, dynamic> _contestList() => {
    'contests': [for (final contest in contests!) _contestAbout(contest)],
    'today': contestsToday,
    'roles': ['server', 'bartender', 'host', 'cashier', 'kitchen', 'driver', 'manager', 'owner'],
    'standard_roles': ['server', 'bartender'],
    'categories': contestCategories,
    'limits': {'contests': 12, 'name': 40, 'note': 80, 'days': 92, 'shown_days': 7},
  };

  static final _contestBoard = RegExp(r'^/reports/contests/([^/]+)$');

  /// Contests: the location's list, a save of it, what one person sees, and one whole board.
  http.Response _contests(http.Request request) {
    final path = request.url.path;
    if (contests == null) return json({'detail': 'Not Found'}, 404);
    List<Map<String, dynamic>> rows(String id) => contestBoards[id] ?? const [];
    List<String> front(String id) => [
      for (final row in rows(id))
        if (row['place'] == 1) row['name'] as String,
    ];
    final whole = _contestBoard.firstMatch(path)?.group(1);
    if (whole != null) {
      contestBoardAuth = request.headers['authorization'];
      contestBoardAsks.add(whole);
      if (contestBoardAuth == null || refuseContestBoard != null) {
        return json({
          'detail': {'error': 'sign_in', 'message': 'sign in with a manager PIN'},
        }, refuseContestBoard ?? 401);
      }
      final contest = contests!.where((c) => c['id'] == whole).firstOrNull;
      if (contest == null) {
        return json({
          'detail': {'error': 'unknown_contest', 'message': 'There is no such contest.'},
        }, 404);
      }
      var count = 0, amount = 0.0;
      for (final row in rows(whole)) {
        count += row['count'] as int;
        amount += double.parse(row['amount'] as String);
      }
      return json({
        ..._contestAbout(contest),
        'standings': rows(whole),
        'total': {'count': count, 'amount': amount.toStringAsFixed(2)},
        'others': contestOthers[whole] ?? {'count': 0, 'amount': '0.00'},
        'front': front(whole),
        'of': rows(whole).length,
        'today': contestsToday,
        'now_ms': clockNow,
      });
    }
    if (path == '/contests') {
      final staffId = request.url.queryParameters['staff_id'] ?? '';
      contestAsks.add(staffId);
      return json({
        'contests': [
          for (final contest in contests!.map(_contestAbout))
            if (contest['shown'] == true)
              {
                ...contest,
                'takes_part': rows(contest['id'] as String).any((row) => row['staff_id'] == staffId),
                'me': rows(contest['id'] as String).where((row) => row['staff_id'] == staffId).firstOrNull,
                'of': rows(contest['id'] as String).length,
                'front': front(contest['id'] as String),
                'standings': contest['board'] == 'all' ? rows(contest['id'] as String) : null,
              },
        ],
        'today': contestsToday,
        'now_ms': clockNow,
      });
    }
    if (request.method == 'PUT') {
      contestsAuth = request.headers['authorization'];
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      contestsSaved.add(body);
      if (contestsAuth == null) {
        return json({
          'detail': {'error': 'sign_in', 'message': 'sign in with a manager PIN'},
        }, 401);
      }
      if (refuseContests != null) {
        return json({
          'detail': {'error': 'bad_value', 'message': refuseContests},
        }, 422);
      }
      final before = {for (final contest in contests!) contest['id']: contest};
      contests = [
        for (final sent in (body['contests'] as List).cast<Map<String, dynamic>>())
          {
            ...?before[sent['id']],
            ...sent,
            'id':
                sent['id'] ??
                (sent['name'] as String)
                    .toLowerCase()
                    .replaceAll(RegExp('[^a-z0-9]+'), '-')
                    .replaceAll(RegExp(r'^-|-$'), ''),
            'what': switch (sent['counts']) {
              'dish' => contestDishes[sent['item']] ?? before[sent['id']]?['what'] ?? '',
              'category' =>
                contestCategories.where((c) => c['code'] == sent['category']).firstOrNull?['name'] ??
                    before[sent['id']]?['what'] ??
                    '',
              _ => '',
            },
            'set_by': before[sent['id']]?['set_by'] ?? 'Mike',
            'set_ms': before[sent['id']]?['set_ms'] ?? clockNow,
          },
      ];
    }
    return json(_contestList());
  }

  /// The waste log (docs/waste-log.md). [waste] holds today's entries, the newest first; null is a hub older
  /// than the log. `GET /waste` answers them with [wasteReasons]. `POST /waste` writes one at the top by
  /// whoever the body names ([wasteWritten] keeps the bodies), a dish named and priced from [wasteDishes];
  /// [refuseWaste] answers 422 with these words instead. `POST /waste/<id>/strike` strikes one out
  /// ([wasteStruck]: the entry, the staff id and the token it came with); [refuseWasteStrike] answers 409
  /// with these words instead. `GET /reports/waste` adds [waste] up, or answers [wasteReport] when a test
  /// set one ([wasteAsks] keeps each ask's days, [wasteAuth] the token of the last, and [refuseWasteReport]
  /// answers with a status instead). `GET` and `PUT
  /// /settings/waste` keep [wasteReasons] ([wasteReasonsAuth], [refuseWasteReasons]). [wasteDays] holds the
  /// entries of earlier days by their day, which `GET /waste?day=` answers ([wasteDayAsks] keeps the days
  /// asked) and a strike finds too.
  List<Map<String, dynamic>>? waste = [];
  final wasteDays = <String, List<Map<String, dynamic>>>{};
  final wasteDayAsks = <String?>[];
  List<String> wasteReasons = ['Dropped', 'Burnt', 'Made wrong', 'Expired', 'Spoiled', 'Staff meal'];
  final wasteWritten = <Map<String, dynamic>>[];
  final wasteStruck = <(String, String, String?)>[];
  final wasteAsks = <Map<String, String>>[];
  Map<String, dynamic>? wasteReport;
  String? wasteAuth;
  String? wasteReasonsAuth;
  String? refuseWaste;
  int? refuseWasteReport; // a status `GET /reports/waste` answers with instead
  String? refuseWasteStrike;
  String? refuseWasteReasons;
  static const wasteDishes = {
    'GTC:quart': ("General Tso's Chicken (Quart)", 'GTC', '24.95'),
    'GTC:pint': ("General Tso's Chicken (Pint)", 'GTC', '13.95'),
    'EGGROLL:regular': ('Egg roll', 'EGGROLL', '3.50'),
    'WINGS:6pc': ('Chicken wings', 'WINGS', '8.95'),
    'BB:regular': ('Beef with Broccoli', 'BB', '14.95'),
  };
  static const wasteStaff = {'s1': 'Amy', 's2': 'Ben', 's3': 'Mike', 's4': 'Holly', 's5': 'Wei'};

  /// An entry of the waste log as the hub answers it, written at [atMs] (now when left out).
  Map<String, dynamic> wasteEntry(
    String id,
    String name,
    int qty,
    String reason, {
    String? each,
    String by = 'Amy',
    String byId = 's1',
    String note = '',
    int? atMs,
    int? struckMs,
    String struckBy = '',
    String? variantId,
  }) => {
    'id': id,
    'at_ms': atMs ?? clockNow,
    'day': '2026-11-16',
    'name': name,
    'qty': qty,
    'reason': reason,
    'item': each == null ? null : (variantId ?? name).split(':').first,
    'variant_id': variantId,
    'each': each,
    'value': each == null ? null : (double.parse(each) * qty).toStringAsFixed(2),
    'note': note,
    'by_id': byId,
    'by': by,
    'struck_ms': struckMs,
    'struck_by': struckBy,
  };

  static Map<String, dynamic> _wasteTotal(Iterable<Map<String, dynamic>> entries) {
    var count = 0, unpriced = 0, value = 0.0, n = 0;
    for (final entry in entries) {
      n++;
      count += entry['qty'] as int;
      if (entry['value'] == null) {
        unpriced += entry['qty'] as int;
      } else {
        value += double.parse(entry['value'] as String);
      }
    }
    return {'entries': n, 'count': count, 'value': value.toStringAsFixed(2), 'unpriced': unpriced};
  }

  static final _wasteStrike = RegExp(r'^/waste/([^/]+)/strike$');

  /// The waste log: the day, a new entry, an entry struck out, the days added up.
  http.Response _waste(http.Request request) {
    final path = request.url.path;
    if (waste == null) return json({'detail': 'Not Found'}, 404);
    final standing = [
      for (final entry in waste!)
        if (entry['struck_ms'] == null) entry,
    ];
    if (path == '/reports/waste') {
      wasteAuth = request.headers['authorization'];
      wasteAsks.add(request.url.queryParameters);
      if (wasteAuth == null || refuseWasteReport != null) {
        return json({
          'detail': {'error': 'sign_in', 'message': 'sign in with a manager PIN'},
        }, refuseWasteReport ?? 401);
      }
      if (wasteReport != null) return json(wasteReport!);
      List<Map<String, dynamic>> by(String Function(Map<String, dynamic>) key, {bool dishes = false}) {
        final groups = <String, List<Map<String, dynamic>>>{};
        for (final entry in standing) {
          groups.putIfAbsent(key(entry), () => []).add(entry);
        }
        final rows = [
          for (final group in groups.values)
            {
              'name': dishes ? group.last['name'] : key(group.first),
              if (dishes) 'typed': group.last['item'] == null,
              ..._wasteTotal(group),
            },
        ];
        rows.sort((a, b) => double.parse(b['value'] as String).compareTo(double.parse(a['value'] as String)));
        return rows;
      }

      final from = request.url.queryParameters['from'] ?? '2026-11-16';
      final to = request.url.queryParameters['to'] ?? from;
      return json({
        'from': from,
        'to': to,
        'total': _wasteTotal(standing),
        'struck': waste!.length - standing.length,
        'days': [
          if (from != to) {'day': from, ..._wasteTotal(const [])},
          {'day': to, ..._wasteTotal(standing)},
        ],
        'reasons': by((e) => e['reason'] as String),
        'dishes': by(
          (e) => (e['variant_id'] ?? 'typed:${(e['name'] as String).toLowerCase()}') as String,
          dishes: true,
        ),
        'max_days': 92,
        'now_ms': clockNow,
      });
    }
    final strike = _wasteStrike.firstMatch(path)?.group(1);
    if (strike != null) {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final token = request.headers['authorization'];
      wasteStruck.add((strike, body['staff_id'] as String? ?? '', token));
      if (refuseWasteStrike != null) {
        return json({
          'detail': {'error': 'not_yours', 'message': refuseWasteStrike},
        }, 409);
      }
      final entry = [...waste!, ...wasteDays.values.expand((day) => day)].where((e) => e['id'] == strike).firstOrNull;
      if (entry == null) {
        return json({
          'detail': {'error': 'unknown_entry', 'message': 'There is no such entry.'},
        }, 404);
      }
      entry['struck_ms'] ??= clockNow;
      entry['struck_by'] = token != null ? 'Mike' : (wasteStaff[body['staff_id']] ?? '');
      return json(entry);
    }
    if (request.method == 'POST') {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      wasteWritten.add(body);
      if (refuseWaste != null) {
        return json({
          'detail': {'error': 'bad_reason', 'message': refuseWaste},
        }, 422);
      }
      final dish = wasteDishes[body['variant_id']];
      final entry = wasteEntry(
        'w-new-${wasteWritten.length}',
        dish?.$1 ?? body['name'] as String,
        body['qty'] as int,
        body['reason'] as String,
        each: dish?.$3,
        variantId: body['variant_id'] as String?,
        note: body['note'] as String? ?? '',
        byId: body['staff_id'] as String,
        by: wasteStaff[body['staff_id']] ?? '',
      );
      waste!.insert(0, entry);
      return json(entry);
    }
    final asked = request.url.queryParameters['day'];
    wasteDayAsks.add(asked);
    if (asked != null && asked != '2026-11-16') {
      final entries = wasteDays[asked] ?? const <Map<String, dynamic>>[];
      return json({
        'day': asked,
        'today': false,
        'entries': entries,
        'total': _wasteTotal(entries.where((e) => e['struck_ms'] == null)),
        'reasons': wasteReasons,
        'limits': {'name': 60, 'note': 120, 'qty': 999},
        'now_ms': clockNow,
      });
    }
    return json({
      'day': '2026-11-16',
      'today': true,
      'entries': waste,
      'total': _wasteTotal(standing),
      'reasons': wasteReasons,
      'limits': {'name': 60, 'note': 120, 'qty': 999},
      'now_ms': clockNow,
    });
  }

  /// Online orders (docs/online-orders.md): how they are doing, as the hub answers `GET /online/status`
  /// ([onlineStatus] makes one); null is a hub older than online orders, which the tests written before
  /// them run against. [onlineAsks] counts the asks. `POST /online/seen` keeps who looked in [onlineSeenBy],
  /// and from then on no row is new; a hub that cannot write ([onlineReadOnly]) refuses that with 503.
  /// [onlineDown] fails every call of these as if no hub answered, while the rest of the hub goes on.
  Map<String, dynamic>? online;
  int onlineAsks = 0;
  final onlineSeenBy = <String>[];
  bool onlineReadOnly = false;
  bool onlineDown = false;

  /// "Ask now" (`POST /online/fetch`): [onlineFetches] counts the presses that reached the hub, each
  /// answered with [onlineFetched] (what that round did) and the status as [online] has it then, after
  /// [onlineOnFetch] ran (a test moves the status there, as the round would). While [onlineFetchHeld] is
  /// set the answer waits for it. A hub with no key for asking refuses with 409.
  int onlineFetches = 0;
  Map<String, dynamic> onlineFetched = const {
    'asked': true,
    'answered': true,
    'reason': null,
    'soon': false,
    'came': 0,
    'known': 0,
    'placed': 0,
    'booked': 0,
    'kept': 0,
    'failed': 0,
  };
  void Function()? onlineOnFetch;
  Completer<void>? onlineFetchHeld;

  /// How the online orders are doing, as a hub with both keys says it on a quiet day: [look] are the ones
  /// to look at ([onlineLook] makes one) and [trouble] what is wrong right now.
  static Map<String, dynamic> onlineStatus({
    bool asks = true,
    bool pushes = true,
    bool running = true,
    bool writable = true,
    int? answeredMs,
    int? pushedMs,
    int came = 0,
    int byPush = 0,
    int placed = 0,
    int booked = 0,
    int kept = 0,
    int failed = 0,
    int unread = 0,
    int waiting = 0,
    List<Map<String, dynamic>> look = const [],
    List<Map<String, dynamic>> trouble = const [],
    List<Map<String, dynamic>>? accounts,
  }) => {
    'accounts': ?accounts,
    'configured': asks,
    'source': asks ? 'gloriafood' : null,
    'running': asks && running,
    'writable': writable,
    'asked_ms': answeredMs,
    'answered_ms': answeredMs,
    'last_failure': null,
    'push': {'configured': pushes, 'pushed_ms': pushedMs, 'refused': null},
    'today': {
      'came': came,
      'by_push': byPush,
      'by_poll': came - byPush,
      'placed': placed,
      'booked': booked, // tables booked on the website that went into the reservation book
      'kept': kept,
      'failed': failed,
      'unread': unread,
    },
    'waiting': waiting,
    'look': look,
    'seen_ms': 0,
    'news': look.where((row) => row['new'] == true).length,
    'trouble': trouble,
  };

  /// One of the restaurant's accounts as the status lists it: whether the hub has its key, when GloriaFood
  /// last answered for it, why it does not ([reason]) and how many orders it brought today.
  static Map<String, dynamic> onlineAccount(
    String id, {
    String name = '',
    bool test = false,
    bool configured = true,
    int? answeredMs,
    String? reason,
    int came = 0,
  }) => {
    'id': id,
    'name': name,
    'test': test,
    'configured': configured,
    'asked_ms': answeredMs,
    'answered_ms': answeredMs,
    'last_failure': reason == null ? null : {'at_ms': answeredMs ?? 0, 'reason': reason},
    'came': came,
  };

  /// One to look at, by the website's number: what became of it ([state]), since when, and what the hub says.
  /// [store] and [test] say which of several accounts brought it.
  static Map<String, dynamic> onlineLook(
    String id, {
    required int atMs,
    String kind = 'pickup',
    String state = 'failed',
    String? orderId,
    String said = '',
    bool isNew = true,
    String? store,
    bool test = false,
  }) => {
    'store': ?store,
    if (test) 'test': true,
    'source': 'gloriafood',
    'id': id,
    'kind': kind,
    'state': state,
    'order_id': orderId,
    'said': said,
    'tries': 5,
    'fetched_ms': atMs,
    'settled_ms': atMs,
    'via': 'push',
    'at_ms': atMs,
    'new': isNew,
  };

  http.Response _online(http.Request request) {
    final status = online;
    if (status == null) return json({'detail': 'Not Found'}, 404);
    if (onlineDown) throw const SocketException('down');
    if (request.url.path == '/online/status' && request.method == 'GET') {
      onlineAsks += 1;
      return json(status);
    }
    if (request.url.path == '/online/fetch' && request.method == 'POST') {
      if (status['configured'] != true) {
        return json({
          'detail': {'error': 'no_key', 'message': 'This hub has no key for online orders.'},
        }, 409);
      }
      onlineFetches += 1;
      onlineOnFetch?.call();
      return json({...onlineFetched, 'status': online});
    }
    if (request.url.path == '/online/seen' && request.method == 'POST') {
      if (onlineReadOnly) {
        return json({
          'detail': {'error': 'read_only', 'message': 'This hub cannot write that down now.'},
        }, 503);
      }
      onlineSeenBy.add((jsonDecode(request.body) as Map)['by'] as String? ?? '');
      return json(
        online = {
          ...status,
          'seen_ms': clockNow,
          'news': 0,
          'look': [
            for (final row in (status['look'] as List).cast<Map<String, dynamic>>()) {...row, 'new': false},
          ],
        },
      );
    }
    return json({'detail': 'Not Found'}, 404);
  }

  /// The waitlist (docs/waitlist.md). [parties] are tonight's parties in the order they came, each as the hub
  /// answers it ([waitParty] makes one); null is a hub older than the list, which the tests written before
  /// it run against. `GET /waitlist` answers them ([waitAsks] counts the asks) and every change that came is
  /// in [waitPosts], as its method and path and what it carried. The hub's clock is [clockNow].
  /// [refuseWait] answers the next change with a status and a reason, and [waitDown] fails every call of the
  /// list as if no hub answered, while the rest of the hub goes on.
  ///
  /// [waitSuggest] are the waits `GET /waitlist/suggest` suggests, a row for each band of sizes ([suggested]
  /// makes one); null is a hub older than the suggestion, which refuses the call as such a hub does (405: it
  /// knows the path only for putting a party right). [suggestAsks] counts the asks.
  List<Map<String, dynamic>>? parties;
  List<Map<String, dynamic>>? waitSuggest;
  int suggestAsks = 0;
  int waitAsks = 0;
  final waitPosts = <(String, Map<String, dynamic>)>[];
  (int, String, String)? refuseWait;
  bool waitDown = false;

  /// A wait the hub suggests for parties of [from] to [to] guests, and what it goes by.
  static Map<String, dynamic> suggested(
    int from,
    int to,
    int minutes, {
    int? about,
    String by = 'pace',
    int ahead = 0,
    int each = 5,
    int? longest,
    int seated = 4,
    bool like = true,
  }) => {
    'from': from,
    'to': to,
    'minutes': minutes,
    'about_minutes': about ?? minutes,
    'by': by,
    'ahead': ahead,
    'each_minutes': each,
    'longest_minutes': longest,
    'seated': seated,
    'like': like,
  };

  /// A waiting party as the hub answers it: [quoted] minutes told (none when null), counted from [atMs].
  static Map<String, dynamic> waitParty(
    String id,
    String name,
    int size, {
    required int atMs,
    int? quoted,
    String phone = '',
    String note = '',
    String by = 'Holly',
    int? calledMs,
    List<String>? tags, // what its number carries in the guest list; null from a hub older than that
  }) => {
    'id': id,
    'name': name,
    'size': size,
    'phone': phone,
    'quoted_minutes': quoted,
    'note': note,
    'tags': ?tags,
    'at_ms': atMs,
    'by': by,
    'called_ms': calledMs,
    'status': 'waiting',
    'due_ms': quoted == null ? null : atMs + quoted * 60000,
    'amber_ms': quoted == null ? null : atMs + (quoted > 5 ? quoted - 5 : 0) * 60000,
    'seated_ms': null,
    'table': '',
    'table_label': '',
    'order_id': '',
    'left_ms': null,
    'left_why': '',
    'ended_by': '',
    'waited_minutes': null,
  };

  /// The reservation book (docs/reservations.md). [bookings] are its reservations, each as the hub answers
  /// it ([booking] makes one); null is a hub older than the book, which the tests written before it run
  /// against. The hub's day of service is [bookToday]. `GET /reservations` answers a day's book (each day
  /// asked for is in [bookAsks], null for today's) and every change that came is in [bookPosts], as its
  /// method and path and what it carried. [refuseBook] answers the next change with a status and a reason,
  /// and [bookDown] fails every call of the book as if no hub answered, while the rest of the hub goes on.
  List<Map<String, dynamic>>? bookings;
  String bookToday = '2026-11-16';
  final bookAsks = <String?>[];
  final bookPosts = <(String, Map<String, dynamic>)>[];
  (int, String, String)? refuseBook;
  bool bookDown = false;

  /// Who calls (`GET /reservations/caller`): the numbers it was asked about, as their digits. A hub with
  /// the book but [callersOld] has no such call yet, and answers as it did before it (405).
  final callersAsked = <String>[];
  bool callersOld = false;

  /// The moment a table is booked for: [time] ("18:30") in [day]'s service ("2026-11-16"), where a time
  /// before four in the morning is after that day's midnight.
  static int bookedAt(String day, String time) {
    final on = DateTime.parse(day);
    final hour = int.parse(time.split(':')[0]), minute = int.parse(time.split(':')[1]);
    return DateTime(on.year, on.month, on.day + (hour < 4 ? 1 : 0), hour, minute).millisecondsSinceEpoch;
  }

  /// A standing reservation as the hub answers it.
  static Map<String, dynamic> booking(
    String id,
    String name,
    int size, {
    String day = '2026-11-16',
    required String time,
    String table = '',
    String phone = '',
    String note = '',
    String by = 'Holly',
    String online = '',
    int? arrivedMs,
    int? atMs,
    List<String>? tags, // what its number carries in the guest list; null from a hub older than that
  }) {
    // [atMs] is for a test that runs by the real clock: the moment itself, with [time] as its words
    final at = atMs ?? bookedAt(day, time);
    return {
      'id': id,
      'name': name,
      'size': size,
      'phone': phone,
      'note': note,
      'tags': ?tags,
      'at_ms': at,
      'day': day,
      'time': time,
      'table': table,
      'table_label': table,
      'made_ms': at - 86400000,
      'by': online.isEmpty ? by : 'the website',
      'online': online, // the website's own number for one that was booked there
      'status': 'booked',
      'soon_ms': at - 15 * 60000,
      'late_ms': at + 15 * 60000,
      'arrived_ms': arrivedMs,
      'seated_ms': null,
      'seated_table': '',
      'seated_label': '',
      'order_id': '',
      'ended_ms': null,
      'ended_by': '',
    };
  }

  /// The tables booked for today, as the hub tells the floor map (`holds` of `GET /floor`): under each
  /// table, the standing reservations of [bookToday] that hold it, the earliest first.
  Map<String, List<Map<String, dynamic>>> get tableHolds {
    final held = [
      for (final b in bookings ?? const <Map<String, dynamic>>[])
        if (b['day'] == bookToday && b['status'] == 'booked' && b['table'] != '') b,
    ]..sort((a, b) => (a['at_ms'] as int).compareTo(b['at_ms'] as int));
    final holds = <String, List<Map<String, dynamic>>>{};
    for (final b in held) {
      holds.putIfAbsent(b['table'] as String, () => []).add(holdOf(b));
    }
    return holds;
  }

  /// Who sits at the tables, as the hub tells the floor map (`seated` of `GET /floor`): under the id of each
  /// open check on the floor, the reservations and the parties of the waitlist that were seated with it,
  /// the first to sit first, each by its name with the tags its number carries ([ringTags]). No number and
  /// no note. With [seatedOnFloor] off the hub is older than it and says nothing.
  bool seatedOnFloor = true;
  Map<String, List<Map<String, dynamic>>> get floorSeated {
    final open = {
      for (final checks in ((floor ?? fixture('floor'))['status'] as Map? ?? const {}).values)
        for (final check in checks as List) (check as Map)['order_id'],
    };
    final sat = [
      for (final row in [...?bookings, ...?parties])
        if (row['seated_ms'] != null && open.contains(row['order_id'])) row,
    ]..sort((a, b) => (a['seated_ms'] as int).compareTo(b['seated_ms'] as int));
    final seated = <String, List<Map<String, dynamic>>>{};
    for (final row in sat) {
      seated.putIfAbsent(row['order_id'] as String, () => []).add({
        'name': row['name'],
        'tags': [...?ringTags?[phoneDigits(row['phone'] as String?)]],
      });
    }
    return seated;
  }

  /// What the floor map is told of a reservation that holds a table: no number and no note.
  static Map<String, dynamic> holdOf(Map<String, dynamic> booking) {
    final at = booking['at_ms'] as int;
    return {
      'id': booking['id'],
      'name': booking['name'],
      'size': booking['size'],
      'at_ms': at,
      'time': booking['time'],
      'arrived_ms': booking['arrived_ms'],
      'held_ms': at - 90 * 60000,
      'soon_ms': at - 15 * 60000,
      'late_ms': at + 15 * 60000,
      'until_ms': at + 90 * 60000,
    };
  }

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

  /// An order's recorded calls (docs/call-recordings.md). [calls] answers `GET /orders/<id>/calls` by the
  /// order asked for, each call as the hub lists it ([recorded] makes one); an order it has nothing for has
  /// none, and null is a hub older than call recordings. [callsProblem] is the hub's word for a phone server
  /// that did not answer its last look. Each ask is in [callsAsks]. [callAudio] answers
  /// `GET /orders/<id>/calls/<call>/audio` with a recording's bytes, to a session whose holder may listen
  /// (the power `calls` in [powers]): each ask is in [audioAsks] and the token of the last in [audioAuth];
  /// [refuseAudio] answers with that status and error instead, once when [refuseAudioOnce].
  Map<String, List<Map<String, dynamic>>>? calls = {};
  String? callsProblem;
  final callsAsks = <String>[];
  final callAudio = <String, List<int>>{};
  final audioAsks = <String>[];
  String? audioAuth;
  (int, String)? refuseAudio;
  bool refuseAudioOnce = false;

  /// A recorded call as the hub lists it.
  static Map<String, dynamic> recorded(
    String id,
    int startedMs, {
    bool out = false,
    int? seconds = 95,
    bool stereo = false,
    bool opened = false,
  }) => {
    'id': id,
    'direction': out ? 'out' : 'in',
    'started_ms': startedMs,
    'seconds': seconds,
    'stereo': stereo,
    'extension': out ? '200' : '',
    'opened': opened,
  };

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

  /// Tonight's turn for a table (`turn` of `GET /floor`, docs/table-servers.md): the staff ids of the people
  /// in it, whose turn it is first. Null for a hub older than the turn. Every word a host said of it
  /// (`POST /floor/turn`) is kept in [turnSaid]: somebody put in goes to the end, somebody taken out is
  /// gone. A reason in [refuseTurn] refuses every word with it.
  List<String>? turn;
  final turnSaid = <Map<String, dynamic>>[];
  String? refuseTurn;

  /// The floor it serves when a test changed it (the fixture otherwise), and what each person saved of their
  /// own settings (`PUT /staff/<id>/preferences`), in order.
  Map<String, dynamic>? floor;

  /// The floor editor (`GET/PUT/DELETE /settings/floor_plan`): whether the hub has it at all (an older one
  /// has not), the plan a manager saved (null for the hub's own), every plan that was sent, the token the
  /// last change carried, the tables in use, and a refusal for the next save: (status, error, message).
  bool floorEditor = true;
  Map<String, dynamic>? floorDrawn;
  final floorPlansSent = <Map<String, dynamic>>[];
  String? floorPlanAuth;
  List<String> floorBusy = [], floorBooked = [];
  (int, String, String)? refuseFloorPlan;

  /// The plan as the floor editor is told it.
  Map<String, dynamic> get floorPlanNow {
    final plan = floorDrawn ?? floor ?? fixture('floor');
    return {
      'width': plan['width'],
      'height': plan['height'],
      'rooms': plan['rooms'],
      'tables': plan['tables'],
      'edited': floorDrawn != null,
      'by': floorDrawn == null ? '' : 'Mike',
      'saved_ms': floorDrawn == null ? 0 : clockNow,
      'busy': floorBusy,
      'booked': floorBooked,
    };
  }

  /// What the hub makes of a plan the editor sent: a new room gets an id from its name, a table said to be
  /// in room "#2" is in the third room, and the plan is as large as its tables reach.
  static Map<String, dynamic> _cleanFloor(Map<String, dynamic> sent) {
    final rooms = [
      for (final room in (sent['rooms'] as List).cast<Map<String, dynamic>>())
        {
          'id': room['id'] ?? (room['name'] as String).toLowerCase().replaceAll(RegExp('[^a-z0-9]+'), '-'),
          'name': room['name'],
        },
    ];
    final tables = [
      for (final table in (sent['tables'] as List).cast<Map<String, dynamic>>())
        {
          ...table,
          'room': switch (table['room']) {
            final String room when room.startsWith('#') => rooms[int.parse(room.substring(1))]['id'],
            final room => room,
          },
        },
    ];
    // (the hub keeps the plan a margin of 60 from its corner: every table moves by the same amount)
    double near(String at, String size) => tables.fold(
      double.infinity,
      (least, table) => min(least, (table[at] as num).toDouble() - (table[size] as num).toDouble() / 2),
    );
    final dx = tables.isEmpty ? 0.0 : 60 - near('x', 'w'), dy = tables.isEmpty ? 0.0 : 60 - near('y', 'h');
    for (final table in tables) {
      table['x'] = (table['x'] as num).toDouble() + dx;
      table['y'] = (table['y'] as num).toDouble() + dy;
    }
    double far(String at, String size) =>
        tables.fold(0, (most, table) => max(most, (table[at] as num).toDouble() + (table[size] as num).toDouble() / 2));
    return {'width': far('x', 'w') + 60, 'height': far('y', 'h') + 60, 'rooms': rooms, 'tables': tables};
  }

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

  /// The orders ahead it lists (`GET /orders/ahead`, docs/catering.md). Null is a hub older than the list,
  /// which takes "ahead" for the id of an order it does not have.
  Map<String, dynamic>? ahead;

  /// The prep lists it makes, by day of service (`GET /orders/ahead/prep?day=`, docs/catering.md); a day it
  /// has none for is a day with no dish ahead. Null is a hub older than the prep list (404). [prepPrints] are
  /// the lists printed (the day, the printer asked for) and [refusePrep] a reason to refuse the next with.
  Map<String, Map<String, dynamic>>? prep = {};
  final prepPrints = <(String, String?)>[];
  String? refusePrep;

  /// The drivers' runs it lists, by day of service (`GET /deliveries/runs?day=`, docs/delivery.md); asked
  /// with no day, the ones of [runsToday], the day it says is running. A day it has none for is a day nobody
  /// delivered on. Null is a hub older than the runs (404).
  Map<String, Map<String, dynamic>>? runs = {};
  String runsToday = '2026-11-16';

  /// The stations' screens (`GET /kitchen/screen?stations=`, docs/kitchen-screens.md): every ticket in the
  /// kitchen, as the hub words it, each line with the `stations` that make it and the ones that `made` it. A
  /// screen is answered with the tickets that have a dish of its stations, the finished ones under `recent`.
  /// Null is a hub older than the screens (404). A `done` operation marks the dishes it names, as on the hub.
  /// The pass (`GET /kitchen/pass?stations=`) is answered from the same tickets: every dish of the stations
  /// it watches (none named: all), each with its `cooks`, `done` once a `done` named `*pass` said it went
  /// out. [kitchenPassKnown] false is a hub older than the pass (404).
  /// [kitchenMinutes] is the setting (`GET/PUT /settings/kitchen_screens`), with the token the last save
  /// carried and a reason to refuse the next save with.
  List<Map<String, dynamic>>? kitchen = [];
  bool kitchenPassKnown = true;

  /// A reason the hub refuses the marks it is sent with, while this is set.
  String? refuseMarks;
  Map<String, dynamic> kitchenMinutes = {'warn': 10, 'late': 20};
  String? kitchenMinutesAuth;
  String? refuseKitchenMinutes;

  /// The screen of [codes] as the hub answers it; with [pass], the pass that watches them (none: all).
  Map<String, dynamic> _kitchenScreen(List<String> codes, {bool pass = false}) {
    final open = <Map<String, dynamic>>[], made = <Map<String, dynamic>>[];
    final names = {for (final station in stations['stations'] as List) (station as Map)['code']: station['name']};
    for (final ticket in kitchen!) {
      final rows = <Map<String, dynamic>>[];
      for (final line in (ticket['lines'] as List).cast<Map<String, dynamic>>()) {
        final here = [
          for (final station in line['stations'] as List)
            if (codes.contains(station) || (pass && codes.isEmpty)) station,
        ];
        if (here.isEmpty) continue;
        final out = line['out'] == true;
        final said = [
          for (final station in line['made'] as List? ?? const [])
            if (here.contains(station)) station,
        ];
        // (a dish that went out is made at its stations too)
        final done = pass ? out : out || said.length == here.length;
        if (done && line['void'] == true) continue;
        rows.add(
          {
              ...line,
              'stations': pass ? ['*pass'] : here,
              'made': pass ? [if (out) '*pass'] : (out ? here : said),
              'done': done,
              'done_ms': !done ? null : (out ? line['out_ms'] : line['done_ms']),
              if (pass)
                'cooks': [
                  for (final station in here)
                    {'code': station, 'name': names[station] ?? station, 'made': said.contains(station)},
                ],
            }
            ..remove('out')
            ..remove('out_ms'),
        );
      }
      if (rows.isEmpty) continue;
      final all = rows.every((row) => row['done'] == true);
      final listed = {
        ...ticket,
        'id': '${ticket['order_id']}:${ticket['since_ms']}',
        'lines': rows,
        if (pass && codes.isEmpty) 'also_at': const <String>[], // every station is on it: nobody else cooks
      };
      if (all) {
        listed['done_ms'] = rows.map((row) => row['done_ms'] as int? ?? 0).reduce(max);
        made.add(listed);
      } else {
        open.add(listed);
      }
    }
    open.sort((a, b) => (a['since_ms'] as int).compareTo(b['since_ms'] as int));
    made.sort((a, b) => (b['done_ms'] as int).compareTo(a['done_ms'] as int));
    return {
      if (pass) 'pass': true,
      'stations': [
        for (final code in [...codes]..sort()) {'code': code, 'name': names[code] ?? code},
      ],
      ...kitchenMinutes,
      'tickets': open,
      'recent': made.take(10).toList(),
    };
  }

  /// A station's word on some dishes of an order: made, or not after all.
  void _made(String orderId, List<Map<String, dynamic>> ops) {
    for (final op in ops) {
      if (op['kind'] != 'done') continue;
      final data = (op['data'] as Map).cast<String, dynamic>();
      final at = int.parse((op['hlc'] as String).split('-').first);
      for (final ticket in kitchen ?? const <Map<String, dynamic>>[]) {
        if (ticket['order_id'] != orderId) continue;
        for (final line in (ticket['lines'] as List).cast<Map<String, dynamic>>()) {
          if (!(data['line_ids'] as List).contains(line['line_id'])) continue;
          if (data['station'] == '*pass') {
            line['out'] = data['done'] != false;
            line['out_ms'] = at;
            continue;
          }
          if (!(line['stations'] as List).contains(data['station'])) continue;
          final said = {...(line['made'] as List? ?? const [])};
          data['done'] == false ? said.remove(data['station']) : said.add(data['station']);
          line['made'] = said.toList();
          line['done_ms'] = at;
        }
      }
    }
  }

  /// The orders whose pack sheet was printed (`POST /orders/{id}/pack-sheet`); null is a hub older than pack
  /// sheets (404), and [refusePack] a reason to refuse the next with.
  List<String>? packSheets = [];
  String? refusePack;

  /// The labels that were printed for the bags of a to-go order (`POST /orders/{id}/bag-labels`): the order
  /// and how many bags; null is a hub older than labels (404), and [refuseLabels] a reason to refuse the
  /// next with.
  List<(String, Object?)>? bagLabels = [];
  String? refuseLabels;

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

  /// The print log (`GET /print/log`, `GET /print/log/paper`, `POST /print/log/reprint`): the prints it has,
  /// newest first, and the paper of each by its job; null is a hub older than the log (404). [printLogAsks] is
  /// what each read of the log asked for, [paperAsks] the jobs whose paper was read, [reprints] what was
  /// asked to be printed again, with the token each carried in [printLogAuth]. [logPrinters] are the printers
  /// it names for a reprint, and [refuseReprint] the words it refuses the next one with (409).
  /// [printLogTypes] are the types it reads its log by (`type`), and it searches it (`q`): in a print's
  /// title, its printer and who asked for it, then on the lines of its paper, which it then says (`found`).
  /// Null is a hub from before both: it says no `types` and reads neither. While [papersHeld] is set no
  /// paper goes out until a test completes it; [papersAtOnce] is the most papers that were ever being
  /// asked for at the same time.
  List<Map<String, dynamic>>? printLog = [];
  List<String>? printLogTypes = ['kitchen', 'bar', 'bill', 'reprint', 'other'];
  final papers = <String, List<List<Map<String, dynamic>>>>{};
  List<Map<String, dynamic>> logPrinters = [];
  final printLogAsks = <Map<String, String>>[];
  final paperAsks = <String>[];
  Completer<void>? papersHeld;
  int papersAtOnce = 0;
  int _papersOut = 0;
  final reprints = <Map<String, dynamic>>[];
  String? printLogAuth;
  String? refuseReprint;

  /// The types the log lists a print under, as the hub works them out.
  static Set<String> _printTypes(Map<String, dynamic> p) {
    final places = [for (final place in p['places'] as List? ?? const []) '$place'];
    return {
      if ((p['sort'] ?? 'ticket') == 'ticket' && places.isNotEmpty)
        ...places
      else
        p['sort'] == 'bill' ? 'bill' : 'other',
      if ('${p['reprint_of'] ?? ''}'.isNotEmpty) 'reprint',
    };
  }

  /// Where a search finds its words in a print: nothing to show when its own line has them, the line of
  /// its paper when that does, null when neither.
  String? _printFound(Map<String, dynamic> p, String q) {
    final about = [p['title'], p['name'], p['by']].join(' ').toLowerCase();
    if (about.contains(q)) return '';
    for (final page in papers[p['job_id']] ?? const <List<Map<String, dynamic>>>[]) {
      for (final step in page) {
        final wrote = step['k'] == 'cols' ? '${step['left']}  ${step['right']}' : '${step['text'] ?? ''}';
        final said = wrote.trim().split(RegExp(r'\s+')).join(' '); // a line of the paper, one space between words
        if (said.toLowerCase().contains(q)) return said;
      }
    }
    return null;
  }

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
  static final _pack = RegExp(r'^/orders/([^/]+)/pack-sheet$');
  static final _labels = RegExp(r'^/orders/([^/]+)/bag-labels$');
  static final _order = RegExp(r'^/orders/([^/]+)$');
  static final _tableTags = RegExp(r'^/orders/([^/]+)/tags$');
  static final _seatedOn = RegExp(r'^/orders/([^/]+)/seated$');
  static final _payerOf = RegExp(r'^/orders/([^/]+)/payer$');

  /// Who sits on the check [id], as the hub answers it.
  Map<String, dynamic> _whoSits(String id) {
    List<String> carried(Map<String, dynamic> row) => [...?ringTags?[phoneDigits(row['phone'] as String?)]];
    String from(Map<String, dynamic> row) => row.containsKey('seated_table') ? 'reservation' : 'waitlist';
    final sat = [
      for (final row in [...?bookings, ...?parties])
        if (row['seated_ms'] != null && row['order_id'] == id) row,
    ]..sort((a, b) => (a['seated_ms'] as int).compareTo(b['seated_ms'] as int));
    final all = <String, String>{};
    for (final row in sat) {
      for (final tag in carried(row)) {
        all.putIfAbsent(tag.toLowerCase(), () => tag);
      }
    }
    return {
      'order_id': id,
      'parties': [
        for (final row in sat)
          {
            'from': from(row),
            'name': row['name'],
            'size': row['size'],
            'note': row['note'],
            'tags': carried(row),
            if (payerCall) ...{
              'key': '${from(row)}:${row['id']}',
              'listed': phoneDigits(row['phone'] as String?).length >= customerDigits,
              'pays': payers[id] == '${from(row)}:${row['id']}',
            },
            // a count where a rate was ever set and the party left a number: never the number itself
            if (guestPoints != null)
              'points': phoneDigits(row['phone'] as String?).length >= customerDigits
                  ? guestPoints![phoneDigits(row['phone'] as String?)] ?? 0
                  : null,
          },
      ],
      'tags': all.values.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase())),
      if (payerCall) 'payer': true,
    };
  }

  static final _history = RegExp(r'^/orders/([^/]+)/history$');
  static final _calls = RegExp(r'^/orders/([^/]+)/calls$');
  static final _callAudio = RegExp(r'^/orders/([^/]+)/calls/([^/]+)/audio$');
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

  static final _partyPath = RegExp(r'^/waitlist/([^/]+)(?:/(called|seat|left|back))?$');

  /// Tonight's list as the hub answers it, with the [party] a change was made to.
  Map<String, dynamic> _waitOut([Map<String, dynamic>? party]) {
    int ended(Map<String, dynamic> p) => (p['seated_ms'] ?? p['left_ms']) as int;
    final waiting = [
      for (final p in parties!)
        if (p['status'] == 'waiting') p,
    ];
    final earlier = [
      for (final p in parties!)
        if (p['status'] != 'waiting') p,
    ]..sort((a, b) => ended(b).compareTo(ended(a)));
    final waits = [
      for (final p in earlier)
        if (p['status'] == 'seated') (p['seated_ms'] as int) - (p['at_ms'] as int),
    ];
    return {
      'waiting': waiting,
      'earlier': earlier,
      'counts': {
        'waiting': waiting.length,
        'guests': waiting.fold<int>(0, (sum, p) => sum + (p['size'] as int)),
        'seated': waits.length,
        'left': earlier.length - waits.length,
        'average_wait_minutes': waits.isEmpty ? null : (waits.reduce((a, b) => a + b) / waits.length / 60000).round(),
      },
      'quotes': [5, 10, 15, 20, 30, 45, 60, 90],
      'most': 60,
      'most_guests': 60,
      'name_max': 24,
      'note_max': 60,
      'party': ?party,
    };
  }

  /// The waitlist: the list, and each change to a party of it.
  http.Response _waitlist(http.Request request) {
    final path = request.url.path;
    if (parties == null) return json({'detail': 'Not Found'}, 404);
    if (waitDown) throw const SocketException('down');
    http.Response refused(int status, String error, String message) => json({
      'detail': {'error': error, 'message': message},
    }, status);
    if (path == '/waitlist' && request.method == 'GET') {
      waitAsks += 1;
      return json(_waitOut());
    }
    if (path == '/waitlist/suggest' && request.method == 'GET') {
      suggestAsks += 1;
      final rows = waitSuggest;
      if (rows == null) return json({'detail': 'Method Not Allowed'}, 405);
      return json({
        'suggest': rows,
        'quotes': [5, 10, 15, 20, 30, 45, 60, 90],
      });
    }
    final body = (jsonDecode(request.body) as Map).cast<String, dynamic>();
    waitPosts.add(('${request.method} $path', body));
    final refuse = refuseWait;
    if (refuse != null) {
      refuseWait = null;
      return refused(refuse.$1, refuse.$2, refuse.$3);
    }
    final who = notesStaff[body['staff_id']];
    if (who == null) return refused(404, 'unknown_staff', 'Nobody here has this id.');
    Map<String, dynamic> told(Map<String, dynamic> party) {
      final quoted = body['quoted_minutes'] as int?;
      final at = party['at_ms'] as int;
      return party..addAll({
        'name': (body['name'] as String).trim(),
        'size': body['size'],
        'phone': body['phone'] ?? '',
        'quoted_minutes': quoted,
        'note': body['note'] ?? '',
        'due_ms': quoted == null ? null : at + quoted * 60000,
        'amber_ms': quoted == null ? null : at + (quoted > 5 ? quoted - 5 : 0) * 60000,
      });
    }

    if (path == '/waitlist') {
      if ((body['name'] as String).trim().isEmpty) return refused(422, 'no_name', 'The name cannot be left empty.');
      final party = told(waitParty('p${parties!.length + 1}', '', 1, atMs: clockNow, by: who));
      parties!.add(party);
      return json(_waitOut(party));
    }
    final match = _partyPath.firstMatch(path);
    final party = match == null ? null : parties!.where((p) => p['id'] == match.group(1)).firstOrNull;
    if (match == null || party == null) {
      return refused(404, 'unknown_party', "This party is not on tonight's list.");
    }
    final waiting = party['status'] == 'waiting';
    final gone = refused(409, 'not_waiting', '${party['name']} is off the list. Put them back first.');
    void ends(String status) => party.addAll({
      'status': status,
      'ended_by': who,
      'waited_minutes': (clockNow - (party['at_ms'] as int)) ~/ 60000,
    });
    switch (match.group(2)) {
      case null:
        if (!waiting) return gone;
        told(party);
      case 'called':
        if (!waiting) return gone;
        party['called_ms'] = body['on'] == false ? null : party['called_ms'] ?? clockNow;
      case 'seat':
        if (party['status'] == 'left') return gone;
        if (waiting) {
          ends('seated');
          party.addAll({
            'seated_ms': clockNow,
            'table': body['table'],
            'table_label': body['table'],
            'order_id': body['order_id'] ?? '',
          });
        }
      case 'left':
        if (party['status'] == 'seated') return gone;
        if (waiting) {
          ends('left');
          party.addAll({'left_ms': clockNow, 'left_why': body['why'] ?? 'left'});
        }
      case 'back':
        party.addAll({
          'status': 'waiting',
          'seated_ms': null,
          'table': '',
          'table_label': '',
          'order_id': '',
          'left_ms': null,
          'left_why': '',
          'ended_by': '',
          'waited_minutes': null,
        });
    }
    return json(_waitOut(party));
  }

  static final _bookingPath = RegExp(r'^/reservations/([^/]+)(?:/(arrived|seat|cancel|back))?$');

  /// A day's book as the hub answers it, with the [changed] reservation a change was made to.
  Map<String, dynamic> _bookOut(String day, [Map<String, dynamic>? changed]) {
    int at(Map<String, dynamic> b) => b['at_ms'] as int;
    int ended(Map<String, dynamic> b) => (b['seated_ms'] ?? b['ended_ms']) as int;
    final ofDay = [
      for (final b in bookings!)
        if (b['day'] == day) b,
    ];
    final booked = [
      for (final b in ofDay)
        if (b['status'] == 'booked') b,
    ]..sort((a, b) => at(a).compareTo(at(b)));
    final earlier = [
      for (final b in ofDay)
        if (b['status'] != 'booked') b,
    ]..sort((a, b) => ended(b).compareTo(ended(a)));
    Map<String, dynamic> out(Map<String, dynamic> b) {
      final near = [
        for (final other in booked)
          if (b['status'] == 'booked' && b['table'] != '' && other['id'] != b['id'] && other['table'] == b['table'])
            if ((at(other) - at(b)).abs() < 90 * 60000) other,
      ]..sort((x, y) => (at(x) - at(b)).abs().compareTo((at(y) - at(b)).abs()));
      return {
        ...b,
        'clash': near.isEmpty ? null : {'id': near.first['id'], 'name': near.first['name'], 'at_ms': at(near.first)},
      };
    }

    final ahead = <String, (int, int)>{};
    for (final b in bookings!) {
      final on = b['day'] as String;
      if (b['status'] != 'booked' || on.compareTo(bookToday) < 0) continue;
      final (parties, guests) = ahead[on] ?? (0, 0);
      ahead[on] = (parties + 1, guests + (b['size'] as int));
    }
    int count(String status) => earlier.where((b) => b['status'] == status).length;
    return {
      'day': day,
      'today': bookToday,
      'booked': [for (final b in booked) out(b)],
      'earlier': [for (final b in earlier) out(b)],
      'counts': {
        'booked': booked.length,
        'guests': booked.fold<int>(0, (sum, b) => sum + (b['size'] as int)),
        'seated': count('seated'),
        'cancelled': count('cancelled'),
        'no_show': count('no_show'),
      },
      'ahead': [
        for (final on in ahead.keys.toList()..sort()) {'day': on, 'parties': ahead[on]!.$1, 'guests': ahead[on]!.$2},
      ],
      'whys': [
        {'id': 'cancelled', 'name': 'Cancelled'},
        {'id': 'no_show', 'name': 'No-show'},
      ],
      'hold_minutes': 90,
      'most_guests': 60,
      'most_ahead_days': 366,
      'name_max': 24,
      'note_max': 80,
      'booking': ?(changed == null ? null : out(changed)),
    };
  }

  /// A day's book as this hub answers it.
  Map<String, dynamic> bookFor(String day) => _bookOut(day);

  /// The reservation book: a day of it, and each change to a reservation.
  http.Response _reservations(http.Request request) {
    final path = request.url.path;
    if (bookings == null) return json({'detail': 'Not Found'}, 404);
    if (bookDown) throw const SocketException('down');
    http.Response refused(int status, String error, String message) => json({
      'detail': {'error': error, 'message': message},
    }, status);
    if (path == '/reservations' && request.method == 'GET') {
      final day = request.url.queryParameters['day'];
      bookAsks.add(day);
      return json(_bookOut(day ?? bookToday));
    }
    if (path == '/reservations/caller' && request.method == 'GET') {
      if (callersOld) return json({'detail': 'Method Not Allowed'}, 405);
      final digits = phoneDigits(request.url.queryParameters['phone']);
      callersAsked.add(digits);
      final theirs = [
        for (final b in bookings!)
          if (b['status'] == 'booked' && (b['day'] as String).compareTo(bookToday) >= 0)
            if (digits.length >= 7 && phoneDigits(b['phone'] as String?) == digits) b,
      ]..sort((a, b) => (a['at_ms'] as int).compareTo(b['at_ms'] as int));
      return json({'phone': digits, 'today': bookToday, 'booked': theirs});
    }
    final body = (jsonDecode(request.body) as Map).cast<String, dynamic>();
    bookPosts.add(('${request.method} $path', body));
    final refuse = refuseBook;
    if (refuse != null) {
      refuseBook = null;
      return refused(refuse.$1, refuse.$2, refuse.$3);
    }
    final who = notesStaff[body['staff_id']];
    if (who == null) return refused(404, 'unknown_staff', 'Nobody here has this id.');
    Map<String, dynamic> told(Map<String, dynamic> b) {
      final day = body['day'] as String, time = (body['time'] as String).padLeft(5, '0');
      final at = bookedAt(day, time);
      return b..addAll({
        'name': (body['name'] as String).trim(),
        'size': body['size'],
        'phone': body['phone'] ?? '',
        'note': body['note'] ?? '',
        'at_ms': at,
        'day': day,
        'time': time,
        'table': body['table'] ?? '',
        'table_label': body['table'] ?? '',
        'soon_ms': at - 15 * 60000,
        'late_ms': at + 15 * 60000,
        if (day != bookToday) 'arrived_ms': null,
      });
    }

    if (path == '/reservations') {
      if ((body['name'] as String).trim().isEmpty) return refused(422, 'no_name', 'The name cannot be left empty.');
      if ((body['day'] as String).compareTo(bookToday) < 0) {
        return refused(422, 'past_day', 'A table is booked for today or a later day.');
      }
      final made = told(booking('b${bookings!.length + 1}', '', 1, time: '12:00', by: who))..['made_ms'] = clockNow;
      bookings!.add(made);
      return json(_bookOut(made['day'] as String, made));
    }
    final match = _bookingPath.firstMatch(path);
    final b = match == null ? null : bookings!.where((b) => b['id'] == match.group(1)).firstOrNull;
    if (match == null || b == null) return refused(404, 'unknown_booking', 'This reservation is not in the book.');
    final standing = b['status'] == 'booked';
    final gone = refused(409, 'not_booked', "${b['name']}'s reservation is not standing. Put it back first.");
    final notToday = refused(409, 'not_today', 'This reservation is for another day.');
    final today = b['day'] == bookToday;
    switch (match.group(2)) {
      case null:
        if (!standing) return gone;
        told(b);
      case 'arrived':
        if (!standing) return gone;
        if (!today) return notToday;
        b['arrived_ms'] = body['on'] == false ? null : b['arrived_ms'] ?? clockNow;
      case 'seat':
        if (b['status'] != 'seated') {
          if (!standing) return gone;
          if (!today) return notToday;
          b.addAll({
            'status': 'seated',
            'seated_ms': clockNow,
            'seated_table': body['table'],
            'seated_label': body['table'],
            'order_id': body['order_id'] ?? '',
            'ended_by': who,
          });
        }
      case 'cancel':
        final why = body['why'] as String? ?? 'cancelled';
        if (b['status'] == 'seated') return gone;
        if (why == 'no_show' && !today) return notToday;
        if (b['status'] != why) b.addAll({'status': why, 'ended_ms': clockNow, 'ended_by': who});
      case 'back':
        b.addAll({
          'status': 'booked',
          'seated_ms': null,
          'seated_table': '',
          'seated_label': '',
          'order_id': '',
          'ended_ms': null,
          'ended_by': '',
        });
    }
    return json(_bookOut(b['day'] as String, b));
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

  /// Conversations by text with customers (docs/text-inbox.md). [textThreads] are the conversations as
  /// `GET /texts` lists them, the one with the newest text first; null is a hub older than them (404).
  /// [textsOf] are the texts of each, by its number, the oldest first. [textsOn] false is a hub with no
  /// Twilio account, [textsNumber] the number the restaurant texts from, [textsListening] whether Twilio
  /// answers the hub. [textPosts] are the texts sent from a screen (the number, what the call carried),
  /// [textReads] the conversations opened (the number, who), [refuseText] what the next text is refused
  /// with (status, error, words), [textPictures] the pictures by text and place (`t1/0`), and [textAsks]
  /// how often the count for the button was asked for.
  List<Map<String, dynamic>>? textThreads;
  final textsOf = <String, List<Map<String, dynamic>>>{};
  bool textsOn = true;
  String textsNumber = '+17815550100';
  Map<String, dynamic> textsListening = {'ok': true, 'at_ms': 0, 'said': ''};
  final textPosts = <(String, Map<String, dynamic>)>[];
  final textReads = <(String, String)>[];
  (int, String, String)? refuseText;
  final textPictures = <String, List<int>>{};
  int textAsks = 0;

  /// A text as the hub lists it.
  static Map<String, dynamic> aText(
    String id,
    String phone,
    String body, {
    required int atMs,
    bool inbound = true,
    String? state,
    String kind = '',
    String orderId = '',
    String by = '',
    String channel = 'sms',
    List<String> pictures = const [],
    int? code,
    String said = '',
  }) => {
    'id': id,
    'phone': phone,
    'inbound': inbound,
    'body': body,
    'at_ms': atMs,
    'state': state ?? (inbound ? 'received' : 'delivered'),
    'channel': channel,
    'pictures': [
      for (final (n, type) in pictures.indexed) {'n': n, 'type': type, 'image': type.startsWith('image/')},
    ],
    'pictures_n': pictures.length,
    'code': code,
    'said': said,
    'kind': kind,
    'order_id': orderId,
    'by': by,
  };

  /// Puts a conversation on the hub: its [texts] the oldest first, [unread] of the customer's not opened.
  void conversation(
    String phone,
    List<Map<String, dynamic>> texts, {
    String name = '',
    int unread = 0,
    int? stoppedMs,
  }) {
    textsOf[phone] = [...texts];
    final threads = textThreads ??= [];
    threads.removeWhere((thread) => thread['phone'] == phone);
    threads.add(_textThread(phone, name: name, unread: unread, stoppedMs: stoppedMs));
    _sortThreads();
  }

  Map<String, dynamic> _textThread(String phone, {String name = '', int unread = 0, int? stoppedMs}) {
    final last = textsOf[phone]?.lastOrNull;
    final digits = phone.replaceAll(RegExp(r'\D'), '');
    return {
      'phone': phone,
      'digits': digits.length == 11 && digits.startsWith('1') ? digits.substring(1) : digits,
      'name': name,
      'unread': unread,
      'read_by': '',
      'stopped_ms': stoppedMs,
      'last': last == null
          ? null
          : {
              'body': last['body'],
              'at_ms': last['at_ms'],
              'inbound': last['inbound'],
              'state': last['state'],
              'pictures_n': last['pictures_n'],
              'kind': last['kind'],
            },
    };
  }

  void _sortThreads() => textThreads!.sort(
    (a, b) => ((b['last'] as Map?)?['at_ms'] as int? ?? 0).compareTo((a['last'] as Map?)?['at_ms'] as int? ?? 0),
  );

  static final _textsWith = RegExp(r'^/texts/with/([^/]+)(/read)?$');
  static final _textPicture = RegExp(r'^/texts/picture/([^/]+)/(\d+)$');

  http.Response _texts(http.Request request) {
    final threads = textThreads;
    if (threads == null) return json({'detail': 'Not Found'}, 404);
    final path = request.url.path;
    final unread = threads.where((thread) => (thread['unread'] as int) > 0).length;
    if (path == '/texts/unread') {
      textAsks += 1;
      return json({'on': textsOn, 'unread': unread});
    }
    if (path == '/texts') {
      final q = (request.url.queryParameters['q'] ?? '').toLowerCase();
      bool holds(Map<String, dynamic> thread) => [
        thread['name'],
        thread['phone'],
        for (final text in textsOf[thread['phone']] ?? const <Map<String, dynamic>>[]) text['body'],
      ].join(' ').toLowerCase().contains(q);
      return json({
        'on': textsOn,
        'number': textsOn ? textsNumber : '',
        'listening': textsListening,
        'unread': unread,
        'threads': [
          for (final thread in threads)
            if (holds(thread)) thread,
        ],
      });
    }
    final picture = _textPicture.firstMatch(path);
    if (picture != null) {
      final bytes = textPictures['${picture.group(1)}/${picture.group(2)}'];
      if (bytes == null) {
        return json({
          'detail': {'error': 'unknown_picture', 'message': 'There is no such picture.'},
        }, 404);
      }
      return http.Response.bytes(bytes, 200, headers: const {'content-type': 'image/png'});
    }
    final one = _textsWith.firstMatch(path);
    if (one == null) return json({'detail': 'Not Found'}, 404);
    final phone = Uri.decodeComponent(one.group(1)!);
    final texts = textsOf[phone] ??= [];
    Map<String, dynamic> thread() =>
        threads.where((thread) => thread['phone'] == phone).firstOrNull ?? _textThread(phone);
    if (request.method == 'GET') {
      final before = int.tryParse(request.url.queryParameters['before_ms'] ?? '');
      final limit = int.tryParse(request.url.queryParameters['limit'] ?? '') ?? 100;
      final shown = [
        for (final text in texts)
          if (before == null || (text['at_ms'] as int) < before) text,
      ];
      return json({
        'on': textsOn,
        'thread': thread(),
        'texts': shown.length > limit ? shown.sublist(shown.length - limit) : shown,
        'more': shown.length > limit,
        'wrap': texts.isEmpty
            ? {'before': 'China Sky: ', 'after': '\nReply STOP to opt out.'}
            : {'before': '', 'after': ''},
      });
    }
    final body = (jsonDecode(request.body) as Map).cast<String, dynamic>();
    final staffId = body['staff_id'] as String? ?? '';
    if (one.group(2) != null) {
      textReads.add((phone, staffId));
      final at = threads.indexWhere((thread) => thread['phone'] == phone);
      if (at >= 0) threads[at] = {...threads[at], 'unread': 0};
      return json(thread());
    }
    textPosts.add((phone, body));
    final refused = refuseText;
    if (refused != null) {
      refuseText = null;
      return json({
        'detail': {'error': refused.$2, 'message': refused.$3},
      }, refused.$1);
    }
    final typed = body['body'] as String;
    final by = (roster ?? const <Map<String, dynamic>>[]).where((row) => row['staff_id'] == staffId).firstOrNull;
    final text = aText(
      body['id'] as String,
      phone,
      texts.isEmpty ? 'China Sky: $typed\nReply STOP to opt out.' : typed,
      atMs: clockNow,
      inbound: false,
      state: 'waiting',
      by: by?['name'] as String? ?? '',
    );
    texts.add(text);
    final had = thread();
    threads.removeWhere((thread) => thread['phone'] == phone);
    threads.add(
      _textThread(
        phone,
        name: (had['name'] as String).isEmpty ? body['name'] as String? ?? '' : had['name'] as String,
        unread: had['unread'] as int,
        stoppedMs: had['stopped_ms'] as int?,
      ),
    );
    _sortThreads();
    return json(text);
  }

  Future<http.Response> answer(http.Request request) async {
    final path = request.url.path;
    if (path == '/orders') return json({'orders': orders});
    if (path.startsWith('/texts')) return _texts(request);
    if (path == '/customers/lookup') {
      final known = customers[phoneDigits(request.url.queryParameters['phone'])];
      if (known != null) return json(known);
    }
    if (path == '/customers/tags' && ringTags != null) {
      if (tagsDown) throw const SocketException('down');
      final digits = phoneDigits(request.url.queryParameters['phone']);
      tagAsks.add(digits);
      return json({'phone': digits, 'tags': ringTags![digits] ?? const <String>[]});
    }
    final whoSits = _seatedOn.firstMatch(path);
    if (whoSits != null) {
      if (!seatedCall || (bookings == null && parties == null)) return json({'detail': 'Not Found'}, 404);
      if (tableTagsDown) throw const SocketException('down');
      final id = whoSits.group(1)!;
      seatedAsks.add(id);
      return json(_whoSits(id));
    }
    final whoPays = _payerOf.firstMatch(path);
    if (whoPays != null && request.method == 'POST') {
      if (!payerCall) return json({'detail': 'Not Found'}, 404);
      if (payerDown) throw const SocketException('down');
      final id = whoPays.group(1)!;
      final body = (jsonDecode(request.body) as Map).cast<String, dynamic>();
      final party = body['party'] as String? ?? '';
      final sits = (_whoSits(id)['parties'] as List).cast<Map<String, dynamic>>();
      final found = sits.where((row) => row['key'] == party).firstOrNull;
      if (found == null) {
        return json({
          'detail': {'error': 'unknown_party', 'message': 'This party does not sit on this check any more.'},
        }, 404);
      }
      if (found['listed'] != true) {
        return json({
          'detail': {'error': 'no_number', 'message': '${found['name']} left no phone number.'},
        }, 409);
      }
      payerSaid.add((id, party, body['pays'] != false, body['staff_id'] as String? ?? ''));
      if (body['pays'] != false) {
        payers[id] = party;
      } else if (payers[id] == party) {
        payers.remove(id);
      }
      return json(_whoSits(id));
    }
    final seatedOn = _tableTags.firstMatch(path);
    if (seatedOn != null) {
      if (ringTags == null) return json({'detail': 'Not Found'}, 404);
      if (tableTagsDown) throw const SocketException('down');
      final id = seatedOn.group(1)!;
      tableTagAsks.add(id);
      final tags = <String, String>{};
      for (final row in [...?bookings, ...?parties]) {
        if (row['seated_ms'] == null || row['order_id'] != id) continue;
        for (final tag in ringTags![phoneDigits(row['phone'] as String?)] ?? const <String>[]) {
          tags.putIfAbsent(tag.toLowerCase(), () => tag);
        }
      }
      return json({
        'order_id': id,
        'tags': tags.values.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase())),
      });
    }
    if (path == '/notes' || path.startsWith('/notes/')) return _notes(request);
    if (path == '/hub/staff' || path.startsWith('/hub/staff/')) return _staff(request);
    if (path == '/hub/keys' ||
        path.startsWith('/hub/keys/') ||
        path.startsWith('/hub/online/accounts') ||
        path.startsWith('/hub/online/push/') ||
        path == '/hub/texts/try') {
      return _keys(request);
    }
    if (path == '/push/status' || path == '/push/test') return _push(request);
    if (path == '/online/fetch' && onlineFetchHeld != null && !onlineDown) await onlineFetchHeld!.future;
    if (path.startsWith('/online/')) return _online(request);
    if (path == '/waitlist' || path.startsWith('/waitlist/')) return _waitlist(request);
    if (path == '/reservations' || path.startsWith('/reservations/')) return _reservations(request);
    if (path == '/logbook' || path.startsWith('/logbook/')) return _logbook(request);
    if (path == '/waste' || path.startsWith('/waste/') || path == '/reports/waste') return _waste(request);
    if (path == '/contests' || path == '/settings/contests' || path.startsWith('/reports/contests/')) {
      return _contests(request);
    }
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
      if (refuseMarks == null) _made(id, ops);
      _moveOnFloor(id, ops);
      final refused = [
        ..._exempt(id, ops),
        if (refuseMarks != null)
          for (final op in ops)
            if (op['kind'] == 'done')
              {
                'op_id': op['op_id'],
                'error': 'invalid_op',
                'problems': [
                  {'code': 'bad_request', 'message': refuseMarks},
                ],
              },
      ];
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
    if (path == '/orders/ahead') {
      return ahead == null ? json({'detail': 'no such order'}, 404) : json(ahead!);
    }
    if (path == '/kitchen/screen') {
      if (kitchen == null) return json({'detail': 'Not Found'}, 404);
      return json(_kitchenScreen((request.url.queryParameters['stations'] ?? '').split(',')));
    }
    if (path == '/kitchen/pass') {
      if (kitchen == null || !kitchenPassKnown) return json({'detail': 'Not Found'}, 404);
      final watched = (request.url.queryParameters['stations'] ?? '').split(',').where((code) => code.isNotEmpty);
      return json(_kitchenScreen(watched.toList(), pass: true));
    }
    if (path == '/deliveries/runs') {
      if (runs == null) return json({'detail': 'Not Found'}, 404);
      final day = request.url.queryParameters['day'] ?? runsToday;
      return json(
        runs![day] ??
            {'day': day, 'runs': 0, 'delivered': 0, 'back': 0, 'out': 0, 'no_driver': 0, 'drivers': <dynamic>[]},
      );
    }
    if (path == '/orders/ahead/prep') {
      if (prep == null) return json({'detail': 'Not Found'}, 404);
      final day = request.url.queryParameters['day'] ?? '';
      return json(
        prep![day] ??
            {
              'day': day,
              'orders': <dynamic>[],
              'count': 0,
              'guests': 0,
              'dishes': 0,
              'unsent': 0,
              'stations': <dynamic>[],
            },
      );
    }
    if (path == '/orders/ahead/prep/print') {
      if (prep == null) return json({'detail': 'Not Found'}, 404);
      if (refusePrep != null) {
        return json({
          'detail': {'error': 'no_printer', 'message': refusePrep},
        }, 409);
      }
      final body = jsonDecode(request.body) as Map;
      prepPrints.add((body['day'] as String? ?? '', body['printer'] as String?));
      return json({
        'job_id': 'prep-${prepPrints.length}',
        'day': body['day'],
        'printed_at': {'id': 'front', 'name': 'Takeout'},
      }, 202);
    }
    if (_pack.hasMatch(path)) {
      if (packSheets == null) return json({'detail': 'Not Found'}, 404);
      if (refusePack != null) {
        return json({
          'detail': {'error': 'no_printer', 'message': refusePack},
        }, 409);
      }
      packSheets!.add(_pack.firstMatch(path)!.group(1)!);
      return json({
        'job_id': 'pack-${packSheets!.length}',
        'printed_at': {'id': 'front', 'name': 'Takeout'},
      }, 202);
    }
    if (_labels.hasMatch(path)) {
      if (bagLabels == null) return json({'detail': 'Not Found'}, 404);
      if (refuseLabels != null) {
        return json({
          'detail': {'error': 'no_printer', 'message': refuseLabels},
        }, 409);
      }
      final bags = (jsonDecode(request.body) as Map)['bags'];
      bagLabels!.add((_labels.firstMatch(path)!.group(1)!, bags));
      return json({
        'job_id': 'labels-${bagLabels!.length}',
        'bags': bags,
        'printed_at': {'id': 'front', 'name': 'Takeout'},
      }, 202);
    }
    if (_order.hasMatch(path)) {
      final id = _order.firstMatch(path)!.group(1)!;
      final order = orders.where((o) => o['order_id'] == id).firstOrNull;
      return order == null ? json({'detail': 'not found'}, 404) : json(order);
    }
    if (_calls.hasMatch(path)) {
      if (calls == null) return json({'detail': 'Not Found'}, 404);
      final id = _calls.firstMatch(path)!.group(1)!;
      callsAsks.add(id);
      final order = orders.where((o) => o['order_id'] == id).firstOrNull;
      if (order == null) {
        return json({
          'detail': {'error': 'unknown_id', 'message': 'There is no such check.'},
        }, 404);
      }
      return json({
        'order_id': id,
        'phone': phoneDigits(((order['fields'] as Map?)?['phone'])?.toString()),
        'linked': true,
        'problem': callsProblem,
        'calls': calls![id] ?? const <Map<String, dynamic>>[],
      });
    }
    if (_callAudio.hasMatch(path)) {
      if (calls == null) return json({'detail': 'Not Found'}, 404);
      final found = _callAudio.firstMatch(path)!;
      final (id, call) = (found.group(1)!, found.group(2)!);
      audioAsks.add(call);
      audioAuth = request.headers['authorization'];
      final token = (audioAuth ?? '').replaceFirst('Bearer ', '');
      final role = token == 'tok-admin'
          ? 'manager'
          : people.values.where((person) => 'tok-${person.$1}' == token).firstOrNull?.$3;
      if (role == null) {
        return json({
          'detail': {'error': 'sign_in', 'message': 'sign in with a manager PIN'},
        }, 401);
      }
      if (!heldBy(role).contains('calls')) {
        return json({
          'detail': {'error': 'not_allowed', 'role': role, 'power': 'calls'},
        }, 403);
      }
      final refuse = refuseAudio;
      if (refuse != null) {
        if (refuseAudioOnce) refuseAudio = null;
        return json({
          'detail': {'error': refuse.$2, 'message': 'no'},
        }, refuse.$1);
      }
      final sound = (calls![id] ?? const []).any((c) => c['id'] == call) ? callAudio[call] : null;
      if (sound == null) {
        return json({
          'detail': {'error': 'unknown_call', 'message': "That call is not one of this order's."},
        }, 404);
      }
      return http.Response.bytes(sound, 200, headers: const {'content-type': 'audio/mpeg'});
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
      return json(paidChecks == null ? guests! : {...guests!, 'waiting': _waiting()});
    }
    if (paidChecks != null && (path == '/reports/guests/payers' || path.startsWith('/reports/guests/payers/'))) {
      return _paid(request, path);
    }
    if (path == '/reports/guests/tags' && request.method == 'GET' && tagBox && guests != null) {
      return _tagBox(request);
    }
    if (path.startsWith('/reports/guests/')) {
      if (guests == null) return json({'detail': 'Not Found'}, 404);
      if (request.method == 'PUT') {
        // a hub that lists guests and keeps no tags yet has nothing to write them with
        if (guests!['tags'] is! List) return json({'detail': 'Method Not Allowed'}, 405);
        return _keepGuest(request, path.substring('/reports/guests/'.length));
      }
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
    if (path == '/reports/suggestions') {
      if (suggestions == null) return json({'detail': 'Not Found'}, 404);
      suggestionsAuth = request.headers['authorization'];
      if (refuseSuggestions != null) {
        return json({
          'detail': {'error': refuseSuggestions == 422 ? 'too_long' : 'sign_in', 'message': salesRefusal},
        }, refuseSuggestions!);
      }
      final from = request.url.queryParameters['from'], to = request.url.queryParameters['to'];
      final asked = from == null && to == null ? '' : '${from ?? to}..${to ?? from}';
      suggestionsAsks.add(asked);
      if (suggestionsHeld != null) await suggestionsHeld!.future;
      final first = from ?? to ?? dayRunning, last = to ?? from ?? dayRunning;
      return json(
        suggestions![asked] ??
            {
              'from': first,
              'to': last,
              'days': DateTime.parse(last).difference(DateTime.parse(first)).inDays + 1,
              'running': last == dayRunning,
              'taken': 0,
              'amount': '0.00',
              'dishes': <Object>[],
              'staff': <Object>[],
              'max_days': 92,
              'now_ms': clockNow,
            },
      );
    }
    if (path == '/reports/kitchen') {
      if (kitchenTimes == null) return json({'detail': 'Not Found'}, 404);
      kitchenTimesAuth = request.headers['authorization'];
      if (refuseKitchenTimes != null) {
        return json({
          'detail': {'error': refuseKitchenTimes == 422 ? 'too_long' : 'sign_in', 'message': salesRefusal},
        }, refuseKitchenTimes!);
      }
      final from = request.url.queryParameters['from'], to = request.url.queryParameters['to'];
      final asked = from == null && to == null ? '' : '${from ?? to}..${to ?? from}';
      kitchenTimesAsks.add(asked);
      if (kitchenTimesHeld != null) await kitchenTimesHeld!.future;
      final first = DateTime.parse('${from ?? to ?? dayRunning}T00:00:00Z');
      final last = DateTime.parse('${to ?? from ?? dayRunning}T00:00:00Z');
      final back = Duration(days: 7 * ((last.difference(first).inDays + 7) ~/ 7));
      String name(DateTime day) => day.toIso8601String().substring(0, 10);
      return json(
        kitchenTimes![asked] ??
            {
              'span': {'first': name(first), 'last': name(last), 'running': name(last) == dayRunning},
              'before': {'first': name(first.subtract(back)), 'last': name(last.subtract(back))},
              'late_min': 0,
              'max_days': 92,
              'now_ms': clockNow,
            },
      );
    }
    if (path == '/reports/today') {
      if (today == null) return json({'detail': 'Not Found'}, 404);
      todayAsks += 1;
      todayAuth = request.headers['authorization'];
      if (refuseToday != null) {
        return json({
          'detail': refuseToday == 403
              ? {'error': 'not_allowed', 'role': 'host', 'power': 'reports'}
              : {'error': 'sign_in', 'message': 'sign in with a manager PIN'},
        }, refuseToday!);
      }
      return json(today!);
    }
    if (path == '/reports/sales/sheet') {
      if (sheets == null) return json({'detail': 'Not Found'}, 404);
      sheetAuth = request.headers['authorization'];
      if (refuseSheet != null) {
        return json({
          'detail': {'error': 'sign_in', 'message': 'sign in with a manager PIN'},
        }, refuseSheet!);
      }
      final from = request.url.queryParameters['from'], to = request.url.queryParameters['to'];
      final asked = from == null && to == null ? '' : '${from ?? to}..${to ?? from}';
      sheetAsks.add(asked);
      if (sheetHeld != null) await sheetHeld!.future;
      final first = DateTime.parse('${from ?? to ?? dayRunning}T00:00:00Z');
      final last = DateTime.parse('${to ?? from ?? dayRunning}T00:00:00Z');
      String name(DateTime day) => day.toIso8601String().substring(0, 10);
      return json(
        sheets![asked] ??
            {
              'first': name(first),
              'last': name(last),
              'running': name(last) == dayRunning,
              'columns': ['Day', 'Checks', 'Total'],
              'rows': [
                for (var day = first; !day.isAfter(last); day = day.add(const Duration(days: 1)))
                  [name(day), '0', '0.00'],
              ],
              'total': ['Total', '0', '0.00'],
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
      case '/settings/seats':
        if (seats == null) return json({'detail': 'Not Found'}, 404);
        if (request.method == 'PUT') {
          seatsAuth = request.headers['authorization'];
          seats = (jsonDecode(request.body) as Map<String, dynamic>)['enabled'] as bool;
        }
        return json({'enabled': seats});
      case '/settings/quotes':
        if (request.method == 'PUT') quotes = jsonDecode(request.body) as Map<String, dynamic>;
        return json(quotesOut);
      case '/settings/rush':
        if (!quotes.containsKey('rush')) return json({'detail': 'Not Found'}, 404);
        rushAuth = request.headers['authorization'];
        final minutes = (jsonDecode(request.body) as Map)['minutes'] as int;
        rushSet.add(minutes);
        final until = DateTime.now().add(const Duration(hours: 6)).millisecondsSinceEpoch;
        quotes = {
          ...quotes,
          'rush': minutes > 0 ? {'minutes': minutes, 'until': until, 'by': 'Mike'} : null,
        };
        return json(quotesOut);
      case '/settings/kitchen_screens':
        if (kitchen == null) return json({'detail': 'Not Found'}, 404);
        if (request.method == 'PUT') {
          kitchenMinutesAuth = request.headers['authorization'];
          if (refuseKitchenMinutes != null) {
            return json({
              'detail': {'error': 'bad_value', 'message': refuseKitchenMinutes},
            }, 422);
          }
          kitchenMinutes = {...kitchenMinutes, ...jsonDecode(request.body) as Map<String, dynamic>};
        }
        return json(kitchenMinutes);
      case '/settings/floor_plan':
        if (!floorEditor) return json({'detail': 'Not Found'}, 404);
        if (request.method == 'GET') return json(floorPlanNow);
        floorPlanAuth = request.headers['authorization'];
        if (floorPlanAuth != 'Bearer tok-admin') {
          return json({
            'detail': {'error': 'forbidden'},
          }, 403);
        }
        if (refuseFloorPlan case (final status, final error, final message)) {
          return json({
            'detail': {'error': error, 'message': message},
          }, status);
        }
        if (request.method == 'DELETE') {
          floorDrawn = null;
        } else {
          final sent = jsonDecode(request.body) as Map<String, dynamic>;
          floorPlansSent.add(sent);
          floorDrawn = _cleanFloor(sent);
        }
        return json(floorPlanNow);
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
      case '/settings/bag':
        if (bag == null) return json({'detail': 'Not Found'}, 404);
        if (request.method == 'PUT') {
          bagAuth = request.headers['authorization'];
          if (refuseBag != null) {
            return json({
              'detail': {'error': 'bad_value', 'message': refuseBag},
            }, 422);
          }
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          bag = {
            ...body,
            if ((body['question'] as String? ?? '').isEmpty) 'question': 'What goes in the bag?',
            // a choice new on the screen gets its id from its name, as the hub gives it
            'choices': [
              for (final c in body['choices'] as List)
                {
                  ...c as Map,
                  'id': c['id'] ?? (c['name'] as String).toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-'),
                },
            ],
          };
        }
        return json(bag!);
      case '/settings/delivery_fee':
        if (deliveryFees == null) return json({'detail': 'Not Found'}, 404);
        if (request.method == 'PUT') {
          deliveryFeesAuth = request.headers['authorization'];
          if (refuseDeliveryFees != null) {
            return json({
              'detail': {'error': 'bad_value', 'message': refuseDeliveryFees},
            }, 422);
          }
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final had = deliveryFees!;
          deliveryFees = {
            ...body,
            // kept in order of how far they reach, each as the hub writes it
            'bands': [
              for (final band in (body['bands'] as List).cast<Map>())
                {'up_to': _reach(band['up_to']), 'fee': double.parse('${band['fee']}').toStringAsFixed(2)},
            ]..sort((a, b) => double.parse(a['up_to']!).compareTo(double.parse(b['up_to']!))),
            // a hub that knows the lookup says whether it has a map service and whether it looks up
            if (had.containsKey('maps')) ...{
              'maps': had['maps'],
              'lookup': had['maps'] == true && '${body['origin'] ?? ''}'.isNotEmpty,
              if (had.containsKey('services')) 'services': had['services'],
            } else
              'origin': null,
          }..removeWhere((key, value) => key == 'origin' && value == null);
        }
        return json(deliveryFees!);
      case '/delivery/distance':
        return _distance(request);
      case '/settings/drive_lookups':
        return _driveLookups(request);
      case '/addresses/suggest':
        return _suggest(request);
      case '/addresses/whole':
        final wholes = addressWholes;
        if (wholes == null) return json({'detail': 'Not Found'}, 404);
        if (addressesDown) throw const SocketException('down');
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        wholeAsks.add(body);
        await wholeWaits?.future;
        return json({'parts': wholes[body['ref']]});
      case '/settings/address_list':
        if (addressList == null) return json({'detail': 'Not Found'}, 404);
        if (request.method == 'PUT') {
          addressListAuth = request.headers['authorization'];
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final had = addressList!;
          final services = had['services'] as List?;
          if (services == null) {
            final google = body['google'] == true;
            addressList = {...had, 'google': google, 'asks': google && had['service'] == true};
          } else {
            // one that is not named stays as it is, and so do how far nearby reaches and the order
            addressSaved.add(body);
            final ordered = had['order'] is List;
            final asked = ordered && body['order'] is List ? (body['order'] as List).cast<String>() : const <String>[];
            final all = services.cast<Map<String, dynamic>>();
            addressList = addressListOf(
              [
                for (final one in [
                  for (final name in asked) ...all.where((one) => one['name'] == name),
                  ...all.where((one) => !asked.contains(one['name'])),
                ])
                  {
                    ...one,
                    'on': body[one['name']] is bool ? body[one['name']] : one['on'],
                    'asks': (body[one['name']] is bool ? body[one['name']] : one['on']) == true && one['key'] == true,
                  },
              ],
              near: had['near_miles'] == null ? null : ((body['near_miles'] ?? had['near_miles']) as num).toDouble(),
              origin: had['origin_set'] != false,
              ordered: ordered,
            );
          }
        }
        return json(addressList!);
      case '/settings/points':
        return _points(request);
      case '/settings/address_list/try':
        if (addressList == null) return json({'detail': 'Not Found'}, 404);
        addressTries++;
        final asked = request.body.isEmpty ? null : (jsonDecode(request.body) as Map<String, dynamic>)['service'];
        addressTried.add(asked as String?);
        final services = addressList!['services'] as List?;
        final name = services == null ? 'google' : asked ?? 'google'; // an older hub tries Google whatever is named
        final key = services == null
            ? addressList!['service'] == true
            : services.cast<Map<String, dynamic>>().any((one) => one['name'] == name && one['key'] == true);
        if (!key) {
          return json({
            'detail': {
              'error': 'no_service',
              'message': name == 'google'
                  ? 'this hub has no Google Maps key'
                  : 'this hub has no key for ${addressTitles[name]}',
            },
          }, 409);
        }
        return json({...addressTry, 'service': name});
      case '/settings/live_drive':
        if (liveDrive == null) return json({'detail': 'Not Found'}, 404);
        if (request.method == 'PUT') {
          liveDriveAuth = request.headers['authorization'];
          if (refuseLiveDrive != null) {
            return json({
              'detail': {'error': 'bad_value', 'message': refuseLiveDrive},
            }, 422);
          }
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final had = liveDrive!;
          final live = body['enabled'] == true && had['traffic'] == true && had['origin'] == true;
          liveDrive = {...had, 'enabled': body['enabled'] == true, 'before': body['before'], 'live': live};
          // the fee's answer says it too, on a hub that knows of live traffic
          if (deliveryFees?.containsKey('live') ?? false) deliveryFees = {...deliveryFees!, 'live': live};
        }
        return json(liveDrive!);
      case '/settings/kitchen_notes':
        if (kitchenNotes == null) return json({'detail': 'Not Found'}, 404);
        if (request.method == 'PUT') {
          kitchenNotesAuth = request.headers['authorization'];
          if (refuseKitchenNotes != null) {
            return json({
              'detail': {'error': 'bad_value', 'message': refuseKitchenNotes},
            }, 422);
          }
          kitchenNotes = [...(jsonDecode(request.body) as Map<String, dynamic>)['notes'] as List].cast<String>();
        }
        return json({'notes': kitchenNotes});
      case '/settings/waste':
        if (waste == null) return json({'detail': 'Not Found'}, 404);
        if (request.method == 'PUT') {
          wasteReasonsAuth = request.headers['authorization'];
          if (refuseWasteReasons != null) {
            return json({
              'detail': {'error': 'bad_value', 'message': refuseWasteReasons},
            }, 422);
          }
          wasteReasons = [...(jsonDecode(request.body) as Map<String, dynamic>)['reasons'] as List].cast<String>();
        }
        return json({
          'reasons': wasteReasons,
          'limits': {'reasons': 12, 'reason': 24},
        });
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
      case '/print/log':
        if (printLog == null) return json({'detail': 'Not Found'}, 404);
        printLogAuth = request.headers['authorization'];
        final asked = request.url.queryParameters;
        printLogAsks.add(asked);
        final type = printLogTypes == null ? null : asked['type'];
        final q = printLogTypes == null ? '' : (asked['q'] ?? '').toLowerCase();
        var listed = [
          for (final p in printLog!)
            if ((asked['printer'] == null || p['printer'] == asked['printer']) &&
                (asked['only'] != 'trouble' ||
                    p['status'] != 'printed' ||
                    ((p['tries'] as int?) ?? 0) > 0 ||
                    ((p['printed_on'] ?? p['address']) != p['address'])) &&
                (type == null || _printTypes(p).contains(type)))
              if (q.isEmpty)
                p
              else if (_printFound(p, q) case final String where)
                {...p, if (where.isNotEmpty) 'found': where},
        ];
        final before = asked['before'];
        if (before != null) {
          final at = listed.indexWhere((p) => '${p['at_ms']}:${p['job_id']}' == before);
          listed = listed.sublist(at + 1);
        }
        final limit = int.parse(asked['limit'] ?? '50');
        final page = listed.take(limit).toList();
        return json({
          'prints': page,
          'next': listed.length > limit ? '${page.last['at_ms']}:${page.last['job_id']}' : null,
          'printers': logPrinters,
          'keeps_days': 14,
          'types': ?printLogTypes,
        });
      case '/print/log/paper':
        if (printLog == null) return json({'detail': 'Not Found'}, 404);
        printLogAuth = request.headers['authorization'];
        final job = request.url.queryParameters['job']!;
        paperAsks.add(job);
        if (++_papersOut > papersAtOnce) papersAtOnce = _papersOut;
        try {
          if (papersHeld != null) await papersHeld!.future;
          await Future<void>.value(); // a paper takes a moment: the next one is asked for meanwhile
        } finally {
          _papersOut--;
        }
        final entry = printLog!.where((p) => p['job_id'] == job).firstOrNull;
        if (entry == null || papers[job] == null) {
          return json({
            'detail': {'error': 'no_such_print', 'message': 'That print is no longer in the log.'},
          }, 404);
        }
        return json({...entry, 'pages': papers[job]});
      case '/print/log/reprint':
        if (printLog == null) return json({'detail': 'Not Found'}, 404);
        printLogAuth = request.headers['authorization'];
        final asked = jsonDecode(request.body) as Map<String, dynamic>;
        reprints.add(asked);
        final first = printLog!.where((p) => p['job_id'] == asked['job']).firstOrNull;
        if (first == null) {
          return json({
            'detail': {'error': 'no_such_print', 'message': 'That print is no longer in the log.'},
          }, 404);
        }
        if (refuseReprint != null) {
          return json({
            'detail': {'error': 'no_printer', 'message': refuseReprint, 'printers': logPrinters},
          }, 409);
        }
        final at = logPrinters.where((p) => p['id'] == (asked['printer'] ?? first['printer'])).firstOrNull;
        final made = {
          ...first,
          'job_id': 'reprint:${reprints.length}',
          'at_ms': (printLog!.first['at_ms'] as int) + 60000,
          'printer': at?['id'] ?? first['printer'],
          'name': at?['name'] ?? first['name'],
          'address': at?['address'] ?? first['address'],
          'status': 'waiting',
          'printed_ms': null,
          'printed_on': '',
          'tries': 0,
          'error': '',
          'reprint_of': first['reprint_of'] == '' || first['reprint_of'] == null
              ? first['job_id']
              : first['reprint_of'],
          'first_ms': first['printed_ms'] ?? first['at_ms'],
          'by': 'Mike',
          'reprints': 0,
          'events': <Map<String, dynamic>>[],
        };
        first['reprints'] = ((first['reprints'] as int?) ?? 0) + 1;
        printLog!.insert(0, made);
        papers[made['job_id'] as String] = [
          for (final page in papers[first['job_id']] ?? const <List<Map<String, dynamic>>>[])
            [
              {'k': 'line', 'text': '*** REPRINT ***', 'big': true, 'bold': true, 'center': true, 'invert': true},
              ...page,
            ],
        ];
        return json({
          'print': made,
          'printed_at': {'id': made['printer'], 'name': made['name']},
        }, 202);
      case '/print/test':
        final printer = (jsonDecode(request.body) as Map)['printer'] as String;
        final known = (printers['printers'] as List).any((p) => (p as Map)['id'] == printer);
        if (!known) {
          return json({
            'detail': {'error': 'no_such_printer'},
          }, 404);
        }
        testPrints.add(printer);
        // one demo ticket for each ticket the printer prints a send on, as the hub does
        final asked = (printers['printers'] as List).firstWhere((p) => (p as Map)['id'] == printer) as Map;
        final tickets = PrinterConfig.fromJson(asked.cast<String, dynamic>()).sets.length;
        return json({'job_id': 'test:$printer', 'status': 'queued', 'tickets': tickets}, 202);
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
      case '/settings/powers':
        if (powers == null) return json({'detail': 'Not Found'}, 404);
        if (request.method == 'PUT') {
          powersAuth = request.headers['authorization'];
          if (powersAuth != 'Bearer tok-admin') {
            return json({
              'detail': {'error': 'not_allowed', 'power': 'settings'},
            }, powersAuth == null ? 401 : 403);
          }
          if (refusePowers != null) {
            return json({
              'detail': {'error': 'bad_value', 'message': refusePowers},
            }, 422);
          }
          final named = (jsonDecode(request.body) as Map<String, dynamic>)['roles'] as Map<String, dynamic>;
          powers = {...powers!, for (final entry in named.entries) entry.key: List<String>.from(entry.value as List)};
        }
        return json({'roles': powers, 'handed': handed, 'always': alwaysRoles.toList()});
      case '/admin/session':
        final body = jsonDecode(request.body) as Map;
        final pin = body['pin'] as String;
        pins.add(pin);
        final power = body['power'] as String?;
        sessionsFor.add(power);
        // a PIN the pretend hub does not know is nobody's it lets in, as it always was
        final (id, name, role) = people[pin] ?? ('', '', 'nobody');
        final held = heldBy(role);
        final allowed = power == null ? held.any({...sessionPowers, settingsPower}.contains) : held.contains(power);
        if (powers == null ? pin != '9999' : !allowed) {
          return json({
            'detail': {'error': 'not_allowed', 'role': role, 'power': ?power},
          }, 403);
        }
        return json({
          'token': pin == '9999' ? 'tok-admin' : 'tok-$id',
          'staff_id': id,
          'name': name,
          'role': role,
          if (powers != null) 'powers': held,
        });
      case '/floor':
        // a hub with a reservation book says which tables are booked for today, and one that keeps a turn
        // for a table who is in it
        return json({
          ...floor ?? fixture('floor'),
          if (bookings != null) 'holds': tableHolds,
          if (turn != null) 'turn': turn,
          if (seatedOnFloor && (bookings != null || parties != null)) 'seated': floorSeated,
        });
      case '/floor/turn' when request.method == 'POST':
        final word = jsonDecode(request.body) as Map<String, dynamic>;
        if (refuseTurn != null) {
          return json({
            'detail': {'error': 'not_allowed', 'message': refuseTurn},
          }, 403);
        }
        turnSaid.add(word);
        final id = word['server_id'] as String;
        turn = [
          for (final other in turn ?? const <String>[])
            if (other != id) other,
          if (word['on'] == true) id,
        ];
        return json({'turn': turn});
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
        // a PIN for a discount on one order: Mike (9999) approves, and whoever the table hands the purpose
        // to; anyone else is no manager
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        pins.add(body['pin'] as String);
        final purpose = body['purpose'] as String? ?? 'adjust';
        purposes.add(purpose);
        final (id, name, role) = people[body['pin']] ?? ('s1', 'Amy', 'server');
        if (!people.containsKey(body['pin']) || !heldBy(role).contains(purpose)) {
          return json({
            'detail': {'error': 'not_allowed', 'role': role, 'power': purpose},
          }, 403);
        }
        return json({'approval': 'tok-${body['order_id']}', 'staff_id': id, 'name': name, 'role': role, 'expires': 1});
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

  /// A floor a test set up counts the dishes ready at a check as the hub does: made and not gone out, with
  /// when the last of them was made.
  void _readyOnFloor(String orderId, Map<String, dynamic> lines) {
    final plan = floor;
    if (plan == null) return;
    final ready = [
      for (final line in lines.values.cast<Map>())
        if (line['status'] == 'active')
          if (line['kitchen'] case {'ready_ms': final int at} && final Map said when said['out_ms'] == null)
            (line['qty'] as int? ?? 1, at),
    ];
    for (final checks in (plan['status'] as Map? ?? const {}).values) {
      for (final check in (checks as List).cast<Map<String, dynamic>>()) {
        if (check['order_id'] != orderId) continue;
        check
          ..remove('ready')
          ..remove('ready_ms');
        if (ready.isEmpty) continue;
        check['ready'] = ready.fold(0, (n, dish) => n + dish.$1);
        check['ready_ms'] = ready.map((dish) => dish.$2).reduce(max);
      }
    }
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
        case 'set_field' when data.containsKey('guests'):
          // the party's size: the seats of the order screen, or the party alone where a table has no seats
          (order['fields'] as Map)['guests'] = data['guests'];
        case 'set_field' when data.containsKey('table') || data.containsKey('merged_into'):
          // the check moved to another table, or was emptied into another check
          for (final field in const ['table', 'merged_into']) {
            if (data.containsKey(field)) (order['fields'] as Map)[field] = data[field];
          }
        case 'set_field' when data.containsKey('phone'):
          // a guest's number typed on a table's check or a bar tab, with the name where one was typed;
          // taken off again, the field is gone
          for (final field in const ['phone', 'customer_name']) {
            if (!data.containsKey(field)) continue;
            final fields = order['fields'] as Map;
            data[field] == null ? fields.remove(field) : fields[field] = data[field];
          }
        case 'set_field' when data.containsKey('customer_name'):
          // the name on a bar tab, changed
          (order['fields'] as Map)['customer_name'] = data['customer_name'];
        case 'set_field' when data.containsKey('bag'):
          // what goes in the bag of a to-go order, answered
          (order['fields'] as Map)['bag'] = data['bag'];
        case 'set_field' when data.containsKey('delivery_fee'):
          // what a delivery costs, picked: the hub fills in the band's price
          order['fields'] = <String, dynamic>{
            ...(order['fields'] as Map).cast<String, dynamic>(),
            'delivery_fee': _feeFor(data['delivery_fee']),
          };
        case 'set_field' when keepsStages && (data.containsKey('stage') || data.containsKey('driver')):
          // a to-go order's step, and who a delivery left with (docs/delivery.md)
          // a map of its own: the one a test wrote may hold no nulls, and coming back names nobody
          order['fields'] = <String, dynamic>{
            ...(order['fields'] as Map).cast<String, dynamic>(),
            for (final field in const ['stage', 'driver', 'driver_id', 'out_at'])
              if (data.containsKey(field)) field: data[field],
          };
        case 'close' when keepsStages:
          order['status'] = 'closed';
        case 'void_line':
          final line = lines[data['line_id']] as Map?;
          if (line != null) line['status'] = line['fired'] == true ? 'void' : 'removed';
        case 'done' when data['station'] == '*pass':
          // the pass, or the server who carried them, says dishes went out (or not after all): the kitchen's
          // word on each follows, and the floor counts what is still ready at the check
          final at = int.tryParse((op['hlc'] as String? ?? '').split('-').first);
          for (final id in data['line_ids'] as List) {
            final line = lines[id] as Map?;
            final said = (line?['kitchen'] as Map?)?.cast<String, dynamic>();
            if (line == null || said == null) continue;
            line['kitchen'] = data['done'] == false ? ({...said}..remove('out_ms')) : {...said, 'out_ms': at};
          }
          _readyOnFloor(orderId, lines);
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

/// A screen tall enough for the whole of the device's Settings with nothing to scroll, and room for the
/// cards still to come: for the tests that tap Save at its foot. A height that just fits the screen as it
/// is today pushes Save out with the next card added above it.
const wholeSettings = Size(900, 4000);

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

/// The list of orders on a terminal whose hub a test has already set up; with [phone], its softphone.
Future<void> pumpOrdersOn(WidgetTester tester, Terminal t, {PhoneClient? phone}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: OrdersScreen(
        api: t.api,
        outbox: t.outbox,
        settings: t.settings,
        session: t.session,
        camera: NoCamera(),
        photos: t.photos,
        phone: phone,
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byTooltip('List of checks'));
  await tester.pumpAndSettle();
}

Future<void> stop(WidgetTester tester) => tester.pumpWidget(const SizedBox()); // stops the refresh timers

/// Taps one of the home screen's ways out by its id ("location", docs/home-screen.md): its button in the
/// bar where it stands there, its tile in the menu behind More otherwise. What it opens is the test's to
/// pump for, as after any tap.
Future<void> openHome(WidgetTester tester, String id) async {
  final inBar = find.byKey(ValueKey('home-quick:$id'));
  if (inBar.evaluate().isNotEmpty) return tester.tap(inBar);
  await openMore(tester);
  final tile = find.byKey(ValueKey('home-tile:$id'));
  await tester.ensureVisible(tile);
  await tester.pumpAndSettle();
  await tester.tap(tile);
}

/// Opens the menu behind More on the home screen.
Future<void> openMore(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('home-more')));
  await tester.pumpAndSettle();
}

/// A tile of the home screen's menu, by its id.
Finder homeTile(String id) => find.byKey(ValueKey('home-tile:$id'));

/// The ids of every way out of the home screen for whoever is signed in: the buttons of its row and the
/// tiles of its menu, without opening it.
Set<String> homeIds(WidgetTester tester) => {
  for (final entry in tester.widget<HomeBar>(find.byType(HomeBar)).entries) entry.id,
};

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
