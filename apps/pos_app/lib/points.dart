/// Points (docs/points.md): where the owner set a rate, the guest who pays a check earns points on it, so
/// many a dollar of what it came to before tax, charges and tips, less comps and discounts. The hub does
/// every sum and reads a guest's points off their checks; this is its rules read into names
/// ([PointsRules]), what a manager sends to change them ([PointsChange]), and the words the screens say a
/// count and a reason in. Nobody earns until somebody sets a rate, and nothing here takes anything off a
/// check: spending points is not part of it.
library;

String _s(Object? value, [String or = '']) => value is String ? value : or;
int _i(Object? value, [int or = 0]) => value is num ? value.toInt() : or;
DateTime? _day(Object? value) => value is String ? DateTime.tryParse(value) : null;

/// A count as people read it: "1,240".
String manyWords(int n) {
  final digits = '${n.abs()}';
  final grouped = StringBuffer(n < 0 ? '-' : '');
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) grouped.write(',');
    grouped.write(digits[i]);
  }
  return grouped.toString();
}

/// "1 point", "1,240 points".
String pointsWords(int points) => '${manyWords(points)} ${points == 1 ? 'point' : 'points'}';

/// The short form for where room is scarce, beside a name on a check: "1,240 pts".
String pointsShort(int points) => '${manyWords(points)} ${points == 1 ? 'pt' : 'pts'}';

/// A rate as the hub writes it ("1", "1.5", "0.25") read as a number; 0 for one that is none.
double rateOf(String rate) => double.tryParse(rate) ?? 0;

/// "1 point a dollar", "1.5 points a dollar".
String rateWords(String rate) => '$rate ${rateOf(rate) == 1 ? 'point' : 'points'} a dollar';

/// How long points last, as people say it: "a year", "90 days".
String lastWords(int days) => days == 365 ? 'a year' : '$days days';

/// Why a visit earned no points, in a few words; null where there is nothing to add: the visit earned
/// some, or the line already says why (another guest paid the check, or nobody said who did).
String? whyNoPoints(String why) => switch (why) {
  'off' => 'no points were given that day',
  'open' => 'no points until the check is closed',
  'kind' => 'this kind of order earns no points',
  'catering' => 'catering earns no points',
  'nothing' => 'nothing on it earns points',
  'gone' => 'its points ran out',
  _ => null,
};

/// What earns, as a rule set says it: the kinds of order, and whether alcoholic drinks do.
class PointsEarning {
  const PointsEarning({
    this.perDollar = '0',
    this.dineIn = true,
    this.takeout = true,
    this.delivery = true,
    this.catering = true,
    this.alcohol = false,
  });

  factory PointsEarning.fromJson(Map<String, dynamic> json) => PointsEarning(
    perDollar: _s(json['per_dollar'], '0'),
    dineIn: json['dine_in'] != false,
    takeout: json['takeout'] != false,
    delivery: json['delivery'] != false,
    catering: json['catering'] != false,
    alcohol: json['alcohol'] == true,
  );

  /// How many points a dollar earns, in the hub's own words ("1.5"); "0" is off.
  final String perDollar;

  /// Tables (a bar tab counts with them), to-go orders, deliveries and catering orders: each earns or not.
  final bool dineIn;
  final bool takeout;
  final bool delivery;
  final bool catering;

  /// Whether alcoholic drinks earn. Off unless the owner turned it on.
  final bool alcohol;

  bool get earns => rateOf(perDollar) > 0;

  /// What does not earn, for one line: "no points on to-go orders, catering or alcoholic drinks". Empty
  /// when everything earns.
  String get exceptWords {
    final not = [
      if (!dineIn) 'tables',
      if (!takeout) 'to-go orders',
      if (!delivery) 'deliveries',
      if (!catering) 'catering',
      if (!alcohol) 'alcoholic drinks',
    ];
    if (not.isEmpty) return '';
    final last = not.removeLast();
    return 'no points on ${not.isEmpty ? last : '${not.join(', ')} or $last'}';
  }
}

/// A rule set that was in force before the one of today, with its days.
class PointsEarlier {
  const PointsEarlier({required this.earning, required this.from, required this.until, this.by = ''});

  /// Null for a row with no days in it.
  static PointsEarlier? of(Object? json) {
    if (json is! Map) return null;
    final row = json.cast<String, dynamic>();
    final from = _day(row['from']), until = _day(row['until']);
    if (from == null || until == null) return null;
    return PointsEarlier(earning: PointsEarning.fromJson(row), from: from, until: until, by: _s(row['by']));
  }

  final PointsEarning earning;
  final DateTime from;
  final DateTime until;
  final String by;
}

/// The rules of the points as the hub has them today (`GET /settings/points`, and the `points` of the
/// guest list). The guest list is told the first part only: whether anybody earns, what earns, and how
/// long points last.
class PointsRules {
  const PointsRules({
    this.on = false,
    this.ever = false,
    this.earning = const PointsEarning(),
    this.days = 365,
    this.from,
    this.by = '',
    this.since,
    this.earlier = const [],
    this.perDollarMost = '100',
    this.daysLeast = 30,
    this.daysMost = 365,
  });

  factory PointsRules.fromJson(Map<String, dynamic> json) => PointsRules(
    on: json['on'] == true,
    ever: json['ever'] == true,
    earning: PointsEarning.fromJson(json),
    days: _i(json['days'], 365),
    from: _day(json['from']),
    by: _s(json['by']),
    since: _day(json['since']),
    earlier: [
      if (json['earlier'] case final List rows)
        for (final row in rows) ?PointsEarlier.of(row),
    ],
    perDollarMost: _s(json['per_dollar_most'], '100'),
    daysLeast: _i(json['days_least'], 30),
    daysMost: _i(json['days_most'], 365),
  );

  /// Somebody earns today: a rate is set.
  final bool on;

  /// There can be points at all: a rate was set at some time, whether or not one is now. Where it is
  /// false no screen says anything about points.
  final bool ever;

  /// What earns today.
  final PointsEarning earning;

  /// How many days a check's points count for.
  final int days;

  /// Since when today's rules count and who set them; null and empty where none was ever set.
  final DateTime? from;
  final String by;

  /// The first day anything earned.
  final DateTime? since;

  /// The rule sets before today's, the newest first.
  final List<PointsEarlier> earlier;

  /// What a save is held to.
  final String perDollarMost;
  final int daysLeast;
  final int daysMost;

  /// One line on the rules for the Location screen and the head of the guest list.
  String get summary {
    if (!on) {
      return ever
          ? 'Off: nobody earns now. Points earned before still count for ${lastWords(days)} from their day'
          : 'Off: nobody earns points until you set how many a dollar earns';
    }
    final except = earning.exceptWords;
    return [
      'The guest who pays earns ${rateWords(earning.perDollar)}',
      if (except.isNotEmpty) except,
      'points last ${lastWords(days)}',
    ].join(' · ');
  }
}

/// What a manager saves (`PUT /settings/points`): the rate, what earns, and how long points last.
class PointsChange {
  const PointsChange({
    required this.perDollar,
    required this.dineIn,
    required this.takeout,
    required this.delivery,
    required this.catering,
    required this.alcohol,
    required this.days,
  });

  final String perDollar;
  final bool dineIn;
  final bool takeout;
  final bool delivery;
  final bool catering;
  final bool alcohol;
  final int days;

  Map<String, dynamic> toJson() => {
    'per_dollar': perDollar,
    'dine_in': dineIn,
    'takeout': takeout,
    'delivery': delivery,
    'catering': catering,
    'alcohol': alcohol,
    'days': days,
  };
}

/// A rate as somebody typed it, in the hub's own words: "1.50" is "1.5", "2." is "2", ".5" is "0.5". Null
/// for what is no rate: not a number, below 0, above [most], or with more than two decimals.
String? rateTyped(String typed, {String most = '100'}) {
  final text = typed.trim();
  if (!RegExp(r'^(\d+\.?\d{0,2}|\.\d{1,2})$').hasMatch(text)) return null;
  final value = double.tryParse(text.startsWith('.') ? '0$text' : text);
  if (value == null || value < 0 || value > rateOf(most)) return null;
  var words = value.toStringAsFixed(2);
  if (words.contains('.')) words = words.replaceFirst(RegExp(r'\.?0+$'), '');
  return words.isEmpty ? '0' : words;
}

/// Of a guest's points, the ones that stop counting first: how many, and the last day they count.
class PointsNext {
  const PointsNext({required this.points, required this.until});

  /// Null where nothing is said, or nothing runs out.
  static PointsNext? of(Object? json) {
    if (json is! Map) return null;
    final points = _i(json['points']), until = _day(json['until']);
    return points > 0 && until != null ? PointsNext(points: points, until: until) : null;
  }

  final int points;
  final DateTime until;
}
