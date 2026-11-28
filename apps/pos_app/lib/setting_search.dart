import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'hub_keys.dart';
import 'powers.dart';

/// The search of Location settings (docs/location-settings.md, "Finding a setting"): every row of the
/// screen and every setting inside the pages and dialogs its rows open, by the name the screen gives it,
/// with the words people say for it that the screen does not. What is typed is looked for in all of them
/// and the best matches come first.
///
/// The list is written out here, by hand: a new row of Location, or a new setting in one of its pages,
/// gets its line in [locationSettings] (a test goes through the screen and fails for a row without one,
/// and opens every line to see that it leads where it says).

/// Where a setting stands on the page that holds it: the widget with a key, or the words that head it.
@immutable
class Spot {
  /// The widget whose key is `ValueKey(key)`.
  const Spot.key(String this.key) : words = null;

  /// The first text that reads exactly [words]: a heading, a label.
  const Spot.words(String this.words) : key = null;

  final String? key;
  final String? words;

  @override
  bool operator ==(Object other) => other is Spot && other.key == key && other.words == words;

  @override
  int get hashCode => Object.hash(key, words);

  @override
  String toString() => key != null ? 'Spot.key($key)' : 'Spot.words($words)';
}

/// One thing the search can find.
@immutable
class SettingEntry {
  const SettingEntry(this.row, this.title, {this.spot, this.under, this.about = '', this.also = ''});

  /// The key of the row of Location settings it is: the row the search takes the manager to. With a
  /// [spot], the row that opens the page the setting is on.
  final String row;

  /// Its name, as the screen says it.
  final String title;

  /// Where it stands on the page its row opens; null for the row itself.
  final Spot? spot;

  /// For a setting that stands on Location itself under another (a break under the time clock): the key
  /// of that row. It names where the setting is, and is where the search goes while the setting itself is
  /// not on the screen (the time clock is off).
  final String? under;

  /// One line on what it is for, under its name in the results.
  final String about;

  /// The words people say for it that its name does not have ("86", "permissions", "receipt").
  final String also;

  /// Whether it is a row of Location itself, not something inside or under one.
  bool get isRow => spot == null && under == null;
}

/// Everything the search of Location settings finds, in the order the screen has it.
final List<SettingEntry> locationSettings = List.unmodifiable([
  const SettingEntry(
    'board',
    'Sold out and running low',
    about: 'What is sold out, and what has a number left',
    also: '86 eighty-six out of stock count unavailable gone',
  ),
  const SettingEntry(
    'online-orders',
    'Online orders',
    about: 'How the orders from the website arrive, and the ones to look at',
    also: 'gloriafood website web internet',
  ),
  const SettingEntry(
    'today',
    'Today',
    about: 'The night as it stands, beside the same day last week',
    also: 'report sales now tonight live',
  ),
  const SettingEntry(
    'day-report',
    'The day',
    about: 'Sales, the money taken, what came off and what is still open',
    also: 'report end of day close out cash totals tips payments',
  ),
  const SettingEntry(
    'sales-report',
    'Sales',
    about: 'Any days, beside the same days the weeks before',
    also: 'report revenue compare week month',
  ),
  const SettingEntry(
    'dishes-report',
    'Dishes sold',
    about: 'Best to worst, with their sizes and options',
    also: 'report items product mix best sellers',
  ),
  const SettingEntry(
    'suggestions-report',
    'Suggestions taken',
    about: 'What was added from "Goes with", by person and by dish',
    also: 'report upsell goes with',
  ),
  const SettingEntry(
    'kitchen-times-report',
    'Kitchen times',
    about: 'How long tickets take, by station, hour and dish',
    also: 'report speed cook ticket time slow',
  ),
  const SettingEntry(
    'guests-report',
    'Guests',
    about: 'Phone customers: visits, what they spent, favourites',
    also: 'report customers regulars guest list tags',
  ),
  const SettingEntry(
    'waste-report',
    'Waste',
    about: 'What was made and not sold, by reason, by dish and by day',
    also: 'report waste log spoiled dropped thrown away',
  ),
  const SettingEntry(
    'adjustments-report',
    'Voids and comps report',
    about: 'What came off the checks: by reason, by person and by manager',
    also: 'discounts removed taken off',
  ),
  const SettingEntry(
    'contests',
    'Contests',
    about: 'A board of who rings in the most sales, or the most of a dish',
    also: 'competition leaderboard staff prize',
  ),
  const SettingEntry(
    'shift-notes',
    'Notes for the shift',
    about: 'What everybody sees once after signing in: the specials, what is out',
    also: 'specials announcement message briefing',
  ),
  const SettingEntry(
    'logbook',
    "Manager's log",
    about: 'What happened in a shift, by subject, for the next manager',
    also: 'logbook diary journal',
  ),
  const SettingEntry(
    'time-clock-hours',
    'Hours',
    about: 'Who is on the clock, what each person worked, and corrections',
    also: 'timesheet payroll punches shifts time clock',
  ),

  // the staff, who may do what and the hub's keys
  const SettingEntry(
    'staff-list',
    'Staff and PINs',
    about: 'Everybody who signs in here: names, roles and PINs',
    also: 'employees people person password code owner manager server bartender host forgot',
  ),
  const SettingEntry('staff-list', 'Add a person', spot: Spot.key('staff-add'), also: 'new employee hire staff'),
  const SettingEntry(
    'powers',
    'Who may do what',
    about: 'What each role may do, besides the managers and the owners',
    also: 'permissions roles rights access powers allow',
  ),
  for (final group in powerGroups)
    for (final power in group.powers)
      SettingEntry('powers', power.name, spot: Spot.key('power:${power.id}'), also: '${group.name} ${power.about}'),
  const SettingEntry(
    'hub-keys',
    'Keys and connections',
    about: "The hub's keys for the services outside the restaurant",
    also: 'api key token account service secret',
  ),
  for (final MapEntry(key: name, value: info) in hubKeyInfo.entries)
    SettingEntry('hub-keys', info.title, spot: Spot.key('key-$name'), also: '${info.short} ${info.about}'),

  // how a table's order is taken
  const SettingEntry(
    'coursing-enabled',
    'Course the dishes',
    about: 'Whether dishes are held and fired by course, and the courses by name',
    also: 'courses coursing appetizers entrees dessert fire hold',
  ),
  const SettingEntry('course-add', 'Add course', under: 'coursing-enabled', also: 'new course'),
  const SettingEntry(
    'seats-enabled',
    'Seat numbers',
    about: 'Whether a dish is rung in for a seat, or for the whole table',
    also: 'seats guest position',
  ),

  // to-go orders and deliveries
  const SettingEntry(
    'quote-times',
    'Quote times',
    about: 'The minutes promised for a new order: counter, phone, online, delivery',
    also: 'promise ready wait estimate pickup time how long',
  ),
  const SettingEntry('quote-times', 'Pay at pickup', spot: Spot.words('Pay at pickup'), also: 'unpaid pay later'),
  const SettingEntry(
    'quote-times',
    'Catering',
    spot: Spot.key('quote:catering'),
    also: 'minutes before ticket kitchen lead time',
  ),
  const SettingEntry(
    'quote-times',
    'Big orders',
    spot: Spot.words('Big orders'),
    also: 'large many dishes extra minutes later',
  ),
  const SettingEntry(
    'to-go-question',
    'To-go question',
    about: 'What a to-go order is asked before it is sent',
    also: 'bag utensils chopsticks napkins takeout pickup sauce',
  ),
  const SettingEntry(
    'to-go-question',
    'Ask before a to-go order is sent',
    spot: Spot.key('bag-enabled'),
    also: 'question on off',
  ),
  const SettingEntry('to-go-question', 'The question', spot: Spot.key('bag-words'), also: 'wording asks'),
  const SettingEntry(
    'to-go-question',
    'What it offers',
    spot: Spot.words('What it offers'),
    also: 'choices answers add choice',
  ),
  const SettingEntry(
    'delivery-fee',
    'Delivery fee',
    about: 'What a delivery costs, by the miles or by the minutes of the drive',
    also: 'charge price distance zone driver',
  ),
  const SettingEntry('delivery-fee', 'Charge for delivery', spot: Spot.key('fee-enabled'), also: 'fee on off free'),
  const SettingEntry(
    'delivery-fee',
    'The fee goes by',
    spot: Spot.key('fee-by'),
    also: 'miles minutes of the drive distance',
  ),
  const SettingEntry(
    'delivery-fee',
    'The prices',
    spot: Spot.words('The prices'),
    also: 'bands tiers zones up to add a price',
  ),
  const SettingEntry(
    'delivery-fee',
    'Custom fee past the last distance',
    spot: Spot.key('fee-custom'),
    also: 'far further out typed',
  ),
  const SettingEntry('delivery-fee', 'Charge sales tax on the fee', spot: Spot.key('fee-taxed'), also: 'taxed taxable'),
  const SettingEntry(
    'delivery-fee',
    'Looking the distance up',
    spot: Spot.words('Looking the distance up'),
    also: 'map service google geocodio lookup automatic how far',
  ),
  const SettingEntry(
    'delivery-fee',
    'Restaurant address',
    spot: Spot.key('fee-origin'),
    also: 'our address where we are origin street',
  ),
  const SettingEntry(
    'live-traffic',
    'Live traffic',
    about: 'A delivery is promised by the roads as they are right now',
    also: 'google maps drive time roads eta',
  ),
  const SettingEntry(
    'live-traffic',
    'Promise a delivery by the roads right now',
    spot: Spot.key('live-enabled'),
    also: 'traffic on off',
  ),
  const SettingEntry(
    'live-traffic',
    'Before the drive',
    spot: Spot.key('live-before'),
    also: 'minutes cooking getting it out of the door prep',
  ),
  const SettingEntry(
    'live-traffic',
    'Who is asked about the roads',
    spot: Spot.words('Who is asked about the roads'),
    also: 'map services order google mapbox azure',
  ),
  const SettingEntry(
    'address-list',
    'Address list',
    about: 'The list of addresses that comes up while one is typed',
    also: 'autocomplete suggestions street google mapbox azure map service',
  ),
  const SettingEntry(
    'address-list',
    'Nearby first',
    spot: Spot.words('Nearby first'),
    also: 'miles close to the restaurant radius',
  ),
  const SettingEntry(
    'shipday-moves',
    'Shipday moves the check',
    about: 'Picked up or delivered in Shipday takes a check Out or closes it by itself',
    also: 'delivery driver status sync follow automatic out delivered',
  ),
  const SettingEntry(
    'kitchen-notes',
    'Kitchen notes',
    about: 'The notes to the kitchen that take one tap on a dish',
    also: 'quick note message cook special request',
  ),
  const SettingEntry('kitchen-notes', 'Add note', spot: Spot.key('kitchen-note-add'), also: 'new kitchen note'),
  const SettingEntry(
    'waste-reasons',
    'Waste reasons',
    about: 'Why food is written into the waste log',
    also: 'spoiled dropped wrong order',
  ),
  const SettingEntry('waste-reasons', 'Add reason', spot: Spot.key('waste-reason-add'), also: 'new waste reason'),

  const SettingEntry(
    'points',
    'Points',
    about: 'What the guest who pays a check earns on it',
    also: 'loyalty rewards earn program',
  ),
  const SettingEntry('points', 'Points a dollar', spot: Spot.key('points-rate'), also: 'rate earn how many'),
  const SettingEntry('points', 'Tables and bar tabs', spot: Spot.key('points-dine-in'), also: 'what earns dine in'),
  const SettingEntry('points', 'To-go orders', spot: Spot.key('points-takeout'), also: 'what earns takeout pickup'),
  const SettingEntry('points', 'Deliveries', spot: Spot.key('points-delivery'), also: 'what earns delivery'),
  const SettingEntry('points', 'Catering orders', spot: Spot.key('points-catering'), also: 'what earns'),
  const SettingEntry(
    'points',
    'Alcoholic drinks',
    spot: Spot.key('points-alcohol'),
    also: 'what earns alcohol liquor beer wine bar',
  ),
  const SettingEntry(
    'points',
    'Points last (days)',
    spot: Spot.key('points-days'),
    also: 'expire expiry how long run out',
  ),

  // the floor
  const SettingEntry(
    'floor-plan',
    'Floor plan',
    about: 'Move, size and turn the tables, add and take off tables and rooms',
    also: 'map layout room table editor shape',
  ),
  const SettingEntry(
    'table-timers',
    'Table timers',
    about: 'The countdown ring on each table of the floor map',
    also: 'amber red minutes late waiting clock',
  ),
  const SettingEntry(
    'table-timers',
    'Countdown ring on each table',
    spot: Spot.key('timers-enabled'),
    also: 'timer on off',
  ),
  const SettingEntry(
    'table-timers',
    'Seated, nothing ordered',
    spot: Spot.key('timer-warn:sat'),
    also: 'minutes amber red',
  ),
  const SettingEntry('table-timers', 'Dishes not sent', spot: Spot.key('timer-warn:unsent'), also: 'minutes amber red'),
  const SettingEntry('table-timers', 'Course held', spot: Spot.key('timer-warn:held'), also: 'minutes amber red'),
  const SettingEntry('table-timers', 'Everything sent', spot: Spot.key('timer-warn:fired'), also: 'minutes amber red'),

  // the kitchen
  const SettingEntry(
    'kitchen-screens',
    'Kitchen screens',
    about: "When a ticket on a station's screen turns amber, and red",
    also: 'display monitor kds station minutes',
  ),
  const SettingEntry('kitchen-screens', 'Minutes until amber', spot: Spot.key('kitchen-warn'), also: 'warning'),
  const SettingEntry('kitchen-screens', 'Minutes until red', spot: Spot.key('kitchen-late'), also: 'late'),
  const SettingEntry(
    'voids',
    'Voids',
    about: "What voiding a sent dish takes: a manager's PIN or not, and the reasons to pick from",
    also: 'void cancel remove sent dish',
  ),
  const SettingEntry(
    'voids',
    'A manager approves each void',
    spot: Spot.key('voids-manager'),
    also: 'pin approval needs',
  ),
  const SettingEntry('voids', 'Reasons', spot: Spot.words('Reasons'), also: 'void reason why add reason'),

  // the time clock
  const SettingEntry(
    'time-clock-enabled',
    'Time clock',
    about: 'Whether staff clock in and out, and how the hours are counted',
    also: 'punch in out shifts payroll',
  ),
  const SettingEntry(
    'time-clock-none',
    'Time clock',
    about: 'Whether staff clock in and out, and how the hours are counted',
    also: 'punch in out shifts payroll',
  ),
  const SettingEntry(
    'time-clock-breaks-paid',
    'Breaks count as time worked',
    under: 'time-clock-enabled',
    also: 'paid unpaid break',
  ),
  const SettingEntry(
    'time-clock-week-row',
    'The pay week starts on',
    under: 'time-clock-enabled',
    also: 'monday sunday payroll week',
  ),

  // printing
  const SettingEntry(
    'printers',
    'Printers',
    about: 'Where each station prints, and what stands in when a printer is down',
    also: 'printer epson star receipt ticket ip address network station',
  ),
  const SettingEntry(
    'printers',
    'Print log',
    spot: Spot.key('printers-log'),
    also: 'reprint history what was printed paper',
  ),
  const SettingEntry('printers', 'Add printer', spot: Spot.key('printer-add'), also: 'new printer'),
  const SettingEntry(
    'printers',
    'Find printers on the network',
    spot: Spot.key('printer-scan'),
    also: 'scan search detect look for',
  ),
  const SettingEntry(
    'printers',
    'To-go orders print whole at',
    spot: Spot.key('takeout-station'),
    also: 'takeout station bag pack expo',
  ),
  const SettingEntry(
    'printers',
    'Language',
    spot: Spot.words('Language'),
    also: 'printer language auto esc pos star epson garbled',
  ),
  const SettingEntry(
    'printers',
    'When it is down, print its tickets at',
    spot: Spot.words('When it is down, print its tickets at'),
    also: 'fallback backup broken offline out of paper',
  ),
  const SettingEntry('printers', 'Test print', spot: Spot.words('Test print'), also: 'try sample'),
  const SettingEntry('printers', 'Prints for', spot: Spot.words('Prints for'), also: 'stations which station'),
  const SettingEntry('printers', 'Tickets', spot: Spot.words('Tickets'), also: 'one for all one per station separate'),
  const SettingEntry(
    'bill',
    'The bill',
    about: "Where the guest's bill prints, and what stands at its top and its foot",
    also: 'receipt check header footer',
  ),
  const SettingEntry('bill', 'Bills print at', spot: Spot.key('bill-printer'), also: 'printer receipt'),
  const SettingEntry(
    'bill',
    'Top of the bill',
    spot: Spot.key('bill-header'),
    also: 'header heading restaurant name address phone',
  ),
  const SettingEntry('bill', 'Foot of the bill', spot: Spot.key('bill-footer'), also: 'footer thank you message'),
  const SettingEntry('bill', 'Print a sample', spot: Spot.key('bill-sample'), also: 'test bill try'),
  const SettingEntry(
    'ticket-skips',
    'Screens that skip a station',
    about: 'Screens whose dishes print no ticket at a station, like the bar at its own',
    also: 'no ticket bar skip device',
  ),
  const SettingEntry('ticket-skips', 'Add a screen', spot: Spot.words('Add a screen'), also: 'device'),
  const SettingEntry(
    'tickets-numbered',
    'Number the tickets of one send',
    about: '"Ticket 2 of 3", when more than one station is cooking',
    also: 'kitchen ticket count',
  ),
  const SettingEntry(
    'tickets-also-at',
    'Name the other stations on each ticket',
    about: '"Also at: Wok 2, Sushi Bar", so a cook can time a dish against them',
    also: 'kitchen ticket',
  ),
  const SettingEntry(
    'tickets-paid',
    'Print PAID or NOT PAID on to-go orders',
    about: "On the takeout station's ticket, with what is still to collect",
    also: 'kitchen ticket unpaid',
  ),
  const SettingEntry(
    'tickets-moved',
    'Tell the kitchen when a table moves',
    about: 'A MOVED slip at each station still cooking for it, with the new table',
    also: 'kitchen ticket transfer',
  ),
  const SettingEntry(
    'tickets-pack',
    'Print a pack sheet with a catering order',
    about: 'With its first tickets, where to-go orders are packed: every dish with a box to tick',
    also: 'kitchen ticket packing list checklist',
  ),

  // phones and sign-in
  const SettingEntry(
    'desk-phones',
    'Desk phones',
    about: 'Which screen each desk phone is linked to',
    also: 'pbx extension phone call caller',
  ),
  const SettingEntry('desk-add', 'Add phone', under: 'desk-phones', also: 'new desk phone extension'),
  const SettingEntry(
    'faces-enabled',
    'Sign in by face',
    about: 'Face sign-in, and each person\'s enrollment and tag',
    also: 'face recognition camera enroll tag nfc badge fob card',
  ),
  const SettingEntry(
    'hands-free-switch',
    'Switch to whoever steps up',
    about: 'A face the camera knows, or a tag at the reader, makes the screen that person\'s',
    also: 'hands-free handsfree automatic switch user',
  ),
  const SettingEntry(
    'hands-free-away-row',
    'Sign out when the camera has not seen the person for',
    under: 'hands-free-switch',
    also: 'auto sign out lock away timeout seconds minutes hands-free',
  ),
]);

/// The rows of [locationSettings] by their key: what a setting inside or under a row is said to be in.
final Map<String, SettingEntry> locationRows = {
  for (final entry in locationSettings)
    if (entry.isRow) entry.row: entry,
};

/// The words of [text] as the search compares them: lower case, letters and digits, an apostrophe gone
/// ("Manager's" is "managers").
List<String> searchWords(String text) => [
  for (final word in text.toLowerCase().replaceAll(RegExp("['’]"), '').split(RegExp('[^a-z0-9]+')))
    if (word.isNotEmpty) word,
];

/// Words that say nothing about a setting: left out of what was typed when it has other words.
const _small = {'a', 'an', 'the', 'of', 'to', 'for', 'in', 'on', 'at', 'and', 'or', 'is', 'my', 'how', 'do', 'i'};

/// How well a typed word [typed] is a word [word] of a setting: 3 the word itself, 2 its start (or the
/// word with the ending of more than one, "taxes" for "tax"), 1 inside it, 0 not at all.
int _grade(String typed, String word) {
  if (typed == word) return 3;
  if (word.startsWith(typed)) return 2;
  if (word.length >= 3 && !_small.contains(word) && (typed == '${word}s' || typed == '${word}es')) return 2;
  if (typed.length >= 3 && word.contains(typed)) return 1;
  return 0;
}

/// Whether [typed] is [word] with one letter wrong, missing, added or two swapped ("recipt", "delviery"):
/// what a typing mistake leaves. Short words are not guessed at.
bool _nearly(String typed, String word) {
  if (typed.length < 4 || word.length < 4) return false;
  // a word that goes on after what was typed counts by its start
  final against = word.length > typed.length + 1 ? word.substring(0, typed.length) : word;
  return _mistakes(typed, against) <= 1;
}

/// The typing mistakes between two words (an edit distance in which two swapped letters are one mistake).
int _mistakes(String a, String b) {
  if ((a.length - b.length).abs() > 1) return 2;
  var before = List<int>.filled(b.length + 1, 0);
  var row = List<int>.generate(b.length + 1, (j) => j);
  for (var i = 1; i <= a.length; i++) {
    final next = List<int>.filled(b.length + 1, 0)..[0] = i;
    for (var j = 1; j <= b.length; j++) {
      final same = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1);
      var least = math.min(math.min(row[j] + 1, next[j - 1] + 1), row[j - 1] + (same ? 0 : 1));
      if (i > 1 && j > 1 && a.codeUnitAt(i - 1) == b.codeUnitAt(j - 2) && a.codeUnitAt(i - 2) == b.codeUnitAt(j - 1)) {
        least = math.min(least, before[j - 2] + 1);
      }
      next[j] = least;
    }
    before = row;
    row = next;
  }
  return row[b.length];
}

/// One setting as the search reads it.
class _Read {
  _Read(this.entry, SettingEntry? holder)
    : title = searchWords(entry.title),
      also = searchWords(entry.also),
      about = searchWords(entry.about),
      holder = holder == null ? const [] : searchWords(holder.title);

  final SettingEntry entry;
  final List<String> title;
  final List<String> also;
  final List<String> about;

  /// The name of the row it is in or under.
  final List<String> holder;

  late final String squashed = title.join();
}

/// How well [typed] finds [read], 0 for not at all. Every word typed must be found somewhere: in the
/// name (worth the most), in the other words for it, in the name of the row it is in, or in what it is for.
/// [runs] is what was typed run together, with its small words and without them: a name that is one of
/// them, starts with one or has one in it counts for more. With [guessing], a word with a typing mistake
/// in it is found too.
int _score(List<String> typed, Set<String> runs, _Read read, {required bool guessing}) {
  var score = 0;
  var allInTitle = true;
  for (final word in typed) {
    var best = 0;
    var inTitle = false;
    void look(List<String> words, int worth) {
      for (final candidate in words) {
        var grade = _grade(word, candidate);
        if (grade == 0 && guessing && _nearly(word, candidate)) grade = 1;
        if (grade * worth > best) {
          best = grade * worth;
          inTitle = identical(words, read.title);
        }
      }
    }

    look(read.title, 10);
    look(read.also, 4);
    look(read.holder, 3);
    look(read.about, 2);
    if (best == 0) return 0;
    if (!inTitle) allInTitle = false;
    score += best;
  }
  if (allInTitle) score += 15;
  // the name itself, its start, or a run of it
  if (runs.contains(read.squashed)) {
    score += 60;
  } else if (runs.any(read.squashed.startsWith)) {
    score += 40;
  } else if (runs.any(read.squashed.contains)) {
    score += 20;
  }
  if (read.entry.isRow) score += 12; // of two as good, the row before what is inside one
  // and the shorter name before the longer one that only has it in it ("Voids", "Voids and comps report")
  score -= math.min(math.max(read.title.length - typed.length, 0), 5) * 2;
  return math.max(score, 1);
}

/// The settings among [among] that [typed] finds, the best match first; of two as good, the one that comes
/// first on the screen. Every word typed must be found. A word run together or split differently than the
/// screen has it is found too ("togo", "sign in"), and when nothing is found as typed, a word with a typing
/// mistake in it is. At most [most] are returned.
List<SettingEntry> findSettings(String typed, Iterable<SettingEntry> among, {int most = 40}) {
  var words = searchWords(typed);
  if (words.isEmpty) return const [];
  final asTyped = words.join();
  final telling = [
    for (final word in words)
      if (!_small.contains(word)) word,
  ];
  if (telling.isNotEmpty) words = telling;
  final whole = words.join();
  final runs = {asTyped, whole};
  final reads = [for (final entry in among) _Read(entry, entry.isRow ? null : locationRows[entry.under ?? entry.row])];
  List<SettingEntry> ranked({required bool guessing}) {
    final found = <(int, int, SettingEntry)>[];
    for (final (index, read) in reads.indexed) {
      var score = _score(words, runs, read, guessing: guessing);
      // run together or split differently than the name has it
      if (score == 0 && runs.any((run) => run.length >= 4 && read.squashed.contains(run))) score = 20;
      if (score > 0) found.add((score, index, read.entry));
    }
    found.sort((a, b) => a.$1 != b.$1 ? b.$1.compareTo(a.$1) : a.$2.compareTo(b.$2));
    return [for (final (_, _, entry) in found.take(most)) entry];
  }

  final found = ranked(guessing: false);
  return found.isNotEmpty ? found : ranked(guessing: true);
}

/// The parts of [title] that [typed] found, as (start, end) in the title, in order and not overlapping:
/// what the results show in bold.
List<(int, int)> foundIn(String typed, String title) {
  final lower = title.toLowerCase();
  final marks = <(int, int)>[];
  final words = searchWords(typed);
  for (final word in words) {
    if (_small.contains(word) && words.length > 1) continue;
    // at the start of a word first, then anywhere
    var at = -1;
    for (final match in RegExp('(^|[^a-z0-9])(${RegExp.escape(word)})').allMatches(lower)) {
      at = match.end - word.length;
      break;
    }
    if (at < 0 && word.length >= 3) at = lower.indexOf(word);
    if (at >= 0) marks.add((at, at + word.length));
  }
  marks.sort((a, b) => a.$1.compareTo(b.$1));
  final merged = <(int, int)>[];
  for (final mark in marks) {
    if (merged.isNotEmpty && mark.$1 <= merged.last.$2) {
      merged[merged.length - 1] = (merged.last.$1, math.max(merged.last.$2, mark.$2));
    } else {
      merged.add(mark);
    }
  }
  return merged;
}
