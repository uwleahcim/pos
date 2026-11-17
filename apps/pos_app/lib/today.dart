/// Today so far, as the hub reckons it for one screen (`GET /reports/today`, docs/today.md): the day's
/// report as it stands, the whole of the same weekday a week earlier, and how far each had come by this time
/// of day. The hub does every sum; this is its answer read into names, and the words the screen says them
/// with.
library;

import 'day_report.dart';
import 'sales_report.dart';

/// One hour of the night on both days: what the dishes rung in it sell for.
typedef HourBeside = ({int? hour, String now, String before});

String _s(Object? value, [String or = '']) => value is String ? value : or;
int _i(Object? value) => value is num ? value.toInt() : 0;
Map<String, dynamic> _map(Object? value) => value is Map ? value.cast<String, dynamic>() : const {};

class TodayReport {
  const TodayReport({
    required this.day,
    required this.before,
    this.nowMs = 0,
    this.paceNow = '0.00',
    this.paceBefore = '0.00',
    this.perCheck,
    this.hours = const [],
    this.openCount = 0,
    this.openTotal = '0.00',
    this.openDue = '0.00',
  });

  factory TodayReport.fromJson(Map<String, dynamic> json) {
    final pace = _map(json['pace']), open = _map(json['open']);
    return TodayReport(
      day: DayReport.fromJson(_map(json['day'])),
      before: SalesSpan.fromJson(_map(json['before'])),
      nowMs: _i(json['now_ms']),
      paceNow: _s(pace['now'], '0.00'),
      paceBefore: _s(pace['before'], '0.00'),
      perCheck: json['per_check'] is String ? json['per_check'] as String : null,
      hours: [
        if (json['hours'] is List)
          for (final row in json['hours'] as List)
            if (row is Map)
              (
                hour: row['hour'] is num ? (row['hour'] as num).toInt() : null,
                now: _s(row['now'], '0.00'),
                before: _s(row['before'], '0.00'),
              ),
      ],
      openCount: _i(open['count']),
      openTotal: _s(open['total'], '0.00'),
      openDue: _s(open['due'], '0.00'),
    );
  }

  /// The day that is running, exactly as The day reads it.
  final DayReport day;

  /// The same weekday a week earlier, the whole of it.
  final SalesSpan before;

  /// The hub's clock when it reckoned this.
  final int nowMs;

  /// The dishes rung in by this time of day, before comps and tax: today, and on [before]'s day.
  final String paceNow;
  final String paceBefore;

  /// Today's net sales for each check; null before the first.
  final String? perCheck;

  /// The hours either day sold anything in, in the order a night runs, dishes with no time kept last.
  final List<HourBeside> hours;

  /// The checks open at this moment, tonight's and any left open from an earlier day: how many, what they
  /// come to, and what is not paid on them.
  final int openCount;
  final String openTotal;
  final String openDue;

  /// The open checks, the oldest first: the ones left from an earlier day, then tonight's.
  List<DayCheck> get openChecks => [...day.earlier, ...day.open];
}

const _weekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];

/// The day held beside today, as a person names it: "last Monday".
String lastWeekday(DateTime day) => 'last ${_weekdays[day.weekday - 1]}';

/// Where tonight stands against the same time a week ago: [words] ("13.6% ahead of last Monday at this
/// time"), and [up] true when ahead, false when behind, null when neither can be said. Empty words when
/// nothing was rung in on either day.
Change paceWords(String now, String before, DateTime beforeDay) {
  final a = double.tryParse(now) ?? 0, b = double.tryParse(before) ?? 0;
  final then = lastWeekday(beforeDay);
  if (a == 0 && b == 0) return (words: '', up: null);
  if (b == 0) return (words: 'Nothing had been rung in by this time $then', up: null);
  if (a == b) return (words: 'Level with $then at this time', up: null);
  final moved = changeWords(a, b);
  final percent = moved.words.replaceFirst(RegExp(r'^(up|down) '), '');
  return (words: '$percent ${moved.up! ? 'ahead of' : 'behind'} $then at this time', up: moved.up);
}

/// How long ago [sinceMs] was at [nowMs], as a person says it: "5 min", "1 h 20 min", "2 days".
String sinceWords(int nowMs, int sinceMs) {
  final minutes = ((nowMs - sinceMs) / 60000).floor().clamp(0, 1 << 31);
  if (minutes >= 48 * 60) return '${minutes ~/ (24 * 60)} days';
  return minutesWords(minutes);
}

/// Time worked as a person says it: "31 h 30 min", "45 min".
String workedWords(int ms) => minutesWords((ms / 60000).round());
