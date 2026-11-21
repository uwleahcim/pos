/// Contests for the staff as the hub tells them (docs/contests.md): who rang in the most of a dish, of a
/// category, or the most sales, between two days. A manager sets one up; the hub adds up who is ahead from
/// the same checks as the reports, each time it is asked. Nothing here is a sale or changes one, and the
/// app never counts anything itself: it words the hub's answer.
library;

import 'day_report.dart' show dollars;
import 'powers.dart' show roleLabel;

/// One person's row on a board.
class ContestRow {
  const ContestRow({
    required this.staffId,
    required this.name,
    this.role = '',
    this.count = 0,
    this.amount = '0.00',
    this.place,
  });

  factory ContestRow.fromJson(Map<String, dynamic> json) => ContestRow(
    staffId: json['staff_id'] as String? ?? '',
    name: json['name'] as String? ?? '',
    role: json['role'] as String? ?? '',
    count: json['count'] as int? ?? 0,
    amount: json['amount'] as String? ?? '0.00',
    place: json['place'] as int?,
  );

  final String staffId;
  final String name;
  final String role;

  /// How many dishes that count they rang in, and what those were sold for.
  final int count;
  final String amount;

  /// Their place, people level sharing one; null while nothing of theirs counts yet.
  final int? place;
}

/// How many and for how much: what a board adds up to, or what the people outside it rang.
class ContestSum {
  const ContestSum({this.count = 0, this.amount = '0.00'});

  factory ContestSum.fromJson(Map<String, dynamic>? json) =>
      ContestSum(count: json?['count'] as int? ?? 0, amount: json?['amount'] as String? ?? '0.00');

  final int count;
  final String amount;
}

/// One contest: how it was set up, where it stands in time, and as much of its board as the answer it came
/// in carries (none in the location's list, one person's view from `GET /contests`, the whole of it from
/// `GET /reports/contests/<id>`).
class Contest {
  const Contest({
    this.id,
    required this.name,
    this.note = '',
    this.counts = 'sales',
    this.item,
    this.category,
    this.what = '',
    required this.first,
    required this.last,
    this.roles = const ['server', 'bartender'],
    this.board = 'own',
    this.setBy = '',
    this.setMs = 0,
    this.state = 'running',
    this.shown = true,
    this.takesPart,
    this.me,
    this.of = 0,
    this.front = const [],
    this.standings,
    this.total,
    this.others,
  });

  factory Contest.fromJson(Map<String, dynamic> json) {
    final rows = json['standings'] as List?;
    final me = json['me'] as Map<String, dynamic>?;
    return Contest(
      id: json['id'] as String?,
      name: json['name'] as String? ?? '',
      note: json['note'] as String? ?? '',
      counts: json['counts'] as String? ?? 'sales',
      item: json['item'] as String?,
      category: json['category'] as String?,
      what: json['what'] as String? ?? '',
      first: json['first'] as String? ?? '',
      last: json['last'] as String? ?? '',
      roles: List<String>.from(json['roles'] as List? ?? const ['server', 'bartender']),
      board: json['board'] as String? ?? 'own',
      setBy: json['set_by'] as String? ?? '',
      setMs: json['set_ms'] as int? ?? 0,
      state: json['state'] as String? ?? 'running',
      shown: json['shown'] as bool? ?? true,
      takesPart: json['takes_part'] as bool?,
      me: me == null ? null : ContestRow.fromJson(me),
      of: json['of'] as int? ?? 0,
      front: List<String>.from(json['front'] as List? ?? const []),
      standings: rows == null ? null : [for (final row in rows) ContestRow.fromJson(row as Map<String, dynamic>)],
      total: json['total'] == null ? null : ContestSum.fromJson(json['total'] as Map<String, dynamic>),
      others: json['others'] == null ? null : ContestSum.fromJson(json['others'] as Map<String, dynamic>),
    );
  }

  /// Null for a contest the hub has not kept yet: it gives it one from its name.
  final String? id;
  final String name;

  /// The words under the name: what the winner gets.
  final String note;

  /// What counts: `sales` (the money of every dish), `dish` (one dish, [item]) or `category` ([category]).
  final String counts;
  final String? item;
  final String? category;

  /// What that dish or category is called.
  final String what;

  /// Its first and its last day of service, as the hub takes a day: `2026-11-21`.
  final String first;
  final String last;

  /// The roles that take part.
  final List<String> roles;

  /// Who sees the numbers: `own` (each person their own) or `all` (everybody the whole board).
  final String board;
  final String setBy;
  final int setMs;

  /// `coming`, `running` or `over`, by the hub's day.
  final String state;

  /// Whether the staff's screens show it: until a week after its last day.
  final bool shown;

  /// Whether the person asking takes part; null where nobody in particular asked.
  final bool? takesPart;

  /// Their own row, when they take part.
  final ContestRow? me;

  /// How many people take part.
  final int of;

  /// Who is in front, by name: several when they are level, nobody while nothing counts yet.
  final List<String> front;

  /// Every row, the one in front first: only where the answer may carry it.
  final List<ContestRow>? standings;
  final ContestSum? total;

  /// What the people who do not take part rang of the same.
  final ContestSum? others;

  bool get byMoney => counts == 'sales';
  bool get forAll => board == 'all';
  bool get isOver => state == 'over';
  bool get isComing => state == 'coming';

  DateTime? get firstDay => DateTime.tryParse(first);
  DateTime? get lastDay => DateTime.tryParse(last);

  /// What the hub is sent to keep it: how it is set up, and nothing of where it stands.
  Map<String, dynamic> toJson() => {
    'id': ?id,
    'name': name,
    'note': note,
    'counts': counts,
    'item': counts == 'dish' ? item : null,
    'category': counts == 'category' ? category : null,
    'first': first,
    'last': last,
    'roles': roles,
    'board': board,
  };

  Contest copyWith({
    String? name,
    String? note,
    String? counts,
    String? item,
    String? category,
    String? what,
    String? first,
    String? last,
    List<String>? roles,
    String? board,
  }) => Contest(
    id: id,
    name: name ?? this.name,
    note: note ?? this.note,
    counts: counts ?? this.counts,
    item: item ?? this.item,
    category: category ?? this.category,
    what: what ?? this.what,
    first: first ?? this.first,
    last: last ?? this.last,
    roles: roles ?? this.roles,
    board: board ?? this.board,
    setBy: setBy,
    setMs: setMs,
    state: state,
    shown: shown,
  );
}

/// A category a contest can count, as the hub offers them.
class ContestCategory {
  const ContestCategory({required this.code, required this.name, this.menu = ''});

  factory ContestCategory.fromJson(Map<String, dynamic> json) => ContestCategory(
    code: json['code'] as String? ?? '',
    name: json['name'] as String? ?? '',
    menu: json['menu'] as String? ?? '',
  );

  final String code;
  final String name;

  /// The menu it stands on: Food, Drinks.
  final String menu;
}

/// The contests the location keeps, and what a form needs to set one up.
class ContestList {
  const ContestList({
    this.contests = const [],
    this.today = '',
    this.roles = const ['server', 'bartender', 'host', 'cashier', 'kitchen', 'driver', 'manager', 'owner'],
    this.standardRoles = const ['server', 'bartender'],
    this.categories = const [],
    this.most = 12,
    this.nameMax = 40,
    this.noteMax = 80,
    this.daysMax = 92,
    this.shownDays = 7,
  });

  factory ContestList.fromJson(Map<String, dynamic> json) {
    final limits = json['limits'] as Map<String, dynamic>? ?? const {};
    const fallback = ContestList();
    return ContestList(
      contests: [for (final c in json['contests'] as List? ?? const []) Contest.fromJson(c as Map<String, dynamic>)],
      today: json['today'] as String? ?? '',
      roles: json['roles'] is List ? List<String>.from(json['roles'] as List) : fallback.roles,
      standardRoles: json['standard_roles'] is List
          ? List<String>.from(json['standard_roles'] as List)
          : fallback.standardRoles,
      categories: [
        for (final c in json['categories'] as List? ?? const []) ContestCategory.fromJson(c as Map<String, dynamic>),
      ],
      most: limits['contests'] as int? ?? fallback.most,
      nameMax: limits['name'] as int? ?? fallback.nameMax,
      noteMax: limits['note'] as int? ?? fallback.noteMax,
      daysMax: limits['days'] as int? ?? fallback.daysMax,
      shownDays: limits['shown_days'] as int? ?? fallback.shownDays,
    );
  }

  final List<Contest> contests;

  /// The hub's day of service, `2026-11-21`.
  final String today;

  /// The roles that can take part, in the order the form lists them, and the ones a new contest starts with.
  final List<String> roles;
  final List<String> standardRoles;
  final List<ContestCategory> categories;

  /// How many contests the location keeps, old ones included.
  final int most;
  final int nameMax;
  final int noteMax;

  /// The most days one contest runs.
  final int daysMax;

  /// How many days after its last day a contest stays on the staff's screens.
  final int shownDays;

  /// How many are on the staff's screens now.
  int get shown => contests.where((c) => c.shown).length;
}

/// The contests on the staff's screens, as one person may see each.
class MyContests {
  const MyContests({this.contests = const [], this.today = ''});

  factory MyContests.fromJson(Map<String, dynamic> json) => MyContests(
    contests: [for (final c in json['contests'] as List? ?? const []) Contest.fromJson(c as Map<String, dynamic>)],
    today: json['today'] as String? ?? '',
  );

  final List<Contest> contests;
  final String today;
}

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// "Nov 21", with its year when that is not [today]'s.
String contestDay(DateTime day, DateTime today) {
  final words = '${_months[day.month - 1]} ${day.day}';
  return day.year == today.year ? words : '$words, ${day.year}';
}

/// "Sat Nov 21".
String _weekDay(DateTime day, DateTime today) => '${_weekdays[day.weekday - 1]} ${contestDay(day, today)}';

/// What a contest counts, in a few words: "Most sales", "Most Mai Tai sold".
String countsWords(Contest contest) => switch (contest.counts) {
  'sales' => 'Most sales',
  _ => contest.what.isEmpty ? 'Most sold' : 'Most ${contest.what} sold',
};

/// The days it runs: "Nov 21", or "Nov 1 to Nov 30".
String daysWords(Contest contest, DateTime today) {
  final first = contest.firstDay, last = contest.lastDay;
  if (first == null || last == null) return '';
  if (first == last) return contestDay(first, today);
  return '${contestDay(first, today)} to ${contestDay(last, today)}';
}

/// Where it stands in time, against the hub's day [today]: "Starts tomorrow", "Ends today", "9 days left",
/// "Ended yesterday", "Ended Mon Nov 9".
String stateWords(Contest contest, DateTime today) {
  final first = contest.firstDay, last = contest.lastDay;
  if (first == null || last == null) return '';
  // whole days, counted on a clock with no summer time in it
  final day = DateTime.utc(today.year, today.month, today.day);
  int daysTo(DateTime other) => DateTime.utc(other.year, other.month, other.day).difference(day).inDays;
  if (contest.isComing) {
    final ahead = daysTo(first);
    return ahead == 1 ? 'Starts tomorrow' : 'Starts ${_weekDay(first, today)}';
  }
  if (contest.isOver) {
    final ago = -daysTo(last);
    return ago == 1 ? 'Ended yesterday' : 'Ended ${_weekDay(last, today)}';
  }
  final left = daysTo(last);
  return left <= 0 ? 'Ends today' : (left == 1 ? '1 day left' : '$left days left');
}

/// The figure a row is ranked by: the money of a contest on sales, how many of any other.
String figureWords(Contest contest, ContestRow row) => contest.byMoney ? dollars(row.amount) : '${row.count}';

/// The row's other figure, said small beside it: "6 dishes", "$84.00".
String otherFigureWords(Contest contest, ContestRow row) =>
    contest.byMoney ? (row.count == 1 ? '1 dish' : '${row.count} dishes') : dollars(row.amount);

/// "1st", "2nd", "3rd", "11th", "22nd".
String placeWords(int place) {
  final tens = place % 100;
  if (tens >= 11 && tens <= 13) return '${place}th';
  return switch (place % 10) {
    1 => '${place}st',
    2 => '${place}nd',
    3 => '${place}rd',
    _ => '${place}th',
  };
}

String _named(List<String> names) => switch (names.length) {
  0 => '',
  1 => names.single,
  _ => '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}',
};

/// Where the person reading stands: "2nd of 6 · 14", "Nothing yet · 6 take part", or that they are not in it.
String mineWords(Contest contest) {
  final me = contest.me;
  if (contest.takesPart == false || me == null) return 'You are not in this one';
  if (contest.isComing) return 'You are in · ${contest.of} take part';
  final place = me.place;
  if (place == null) return 'Nothing yet · ${contest.of} take part';
  return '${placeWords(place)} of ${contest.of} · ${figureWords(contest, me)}';
}

/// Who is in front, or who won: "In front: Amy", "Level in front: Amy and Ben", "Won by Amy". Empty for a
/// contest that has not begun.
String frontWords(Contest contest) {
  if (contest.isComing) return '';
  final names = _named(contest.front);
  if (contest.isOver) return names.isEmpty ? 'Nobody rang any' : 'Won by $names';
  if (names.isEmpty) return 'Nobody has any yet';
  return contest.front.length > 1 ? 'Level in front: $names' : 'In front: $names';
}

/// Who takes part: "Servers, Bartenders".
String rolesWords(List<String> roles) => roles.map(roleLabel).join(', ');

/// Who sees the numbers, as the manager's list says it.
String boardWords(Contest contest) =>
    contest.forAll ? 'Everybody sees the whole board' : 'Each person sees only their own number';

/// What the others rang, for the manager: "Rung by people who are not in it: 3 · $21.00". Empty when they
/// rang none.
String othersWords(Contest contest) {
  final others = contest.others;
  if (others == null || others.count == 0) return '';
  final what = contest.byMoney ? dollars(others.amount) : '${others.count} · ${dollars(others.amount)}';
  return 'Rung by people who are not in it: $what';
}
