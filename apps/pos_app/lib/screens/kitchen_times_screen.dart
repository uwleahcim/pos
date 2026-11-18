import 'package:flutter/material.dart';

import '../api.dart';
import '../day_report.dart' show dayName, hourLabel;
import '../kitchen_times.dart';
import '../sales_report.dart';
import 'span_report.dart';
import 'theme.dart';

/// How long the kitchen takes over any days, for a manager (docs/kitchen-times.md): one day, the seven or the
/// twenty-eight just gone, or any days picked on the calendar, beside the same days whole weeks earlier. The
/// tickets of every station that marks first (the average, the middle one, the longest, how many were late),
/// then how long a send took to go out where the pass or the servers say so, each station, each hour, each
/// day, the dishes from the slowest, and the longest tickets by name. Less time is the better figure, so
/// "quicker" is green and "slower" red. The hub does every sum. One column, so it reads the same on a phone.
class KitchenTimesScreen extends StatefulWidget {
  const KitchenTimesScreen({
    super.key,
    required this.api,
    required this.token,
    this.now = DateTime.now,
    this.pickSpan = deviceSpan,
  });

  final PosApi api;

  /// The manager's session (`POST /admin/session`): every call here carries it.
  final String token;

  /// The time on this device: which day yesterday was.
  final DateTime Function() now;
  final PickSpan pickSpan;

  @override
  State<KitchenTimesScreen> createState() => _KitchenTimesScreenState();
}

class _KitchenTimesScreenState extends State<KitchenTimesScreen> {
  SalesChoice _choice = SalesChoice.week;
  DateTimeRange? _other;
  KitchenTimes? _report;
  String? _error;
  int _asked = 0;

  /// How many times other days were picked: each time the list is a new one, laid out from its top.
  int _picked = 0;
  int _maxDays = 92;

  /// Every dish is listed, not only the slowest few.
  bool _everyDish = false;
  final _scroll = ScrollController();

  /// How many dishes the list shows until all of them are asked for.
  static const _dishesShown = 10;
  static const _prefix = 'kitchen-times';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final ask = ++_asked;
    setState(() => _error = null);
    final (from, to) = spanOf(_choice, widget.now(), first: _other?.start, last: _other?.end);
    try {
      final report = await widget.api.kitchenTimes(widget.token, from: from, to: to);
      if (!mounted || ask != _asked) return;
      setState(() {
        _report = report;
        _maxDays = report.maxDays;
      });
    } on ApiException catch (err) {
      if (!mounted || ask != _asked) return;
      setState(() => _error = reportError(err, 'the kitchen times'));
    }
  }

  void _pick(SalesChoice choice) {
    if (_scroll.hasClients) _scroll.jumpTo(0); // other days are read from their top
    setState(() {
      _choice = choice;
      _report = null;
      _everyDish = false;
      _picked++;
    });
    _load();
  }

  Future<void> _pickOther() async {
    final picked = await askOtherDays(context, widget.pickSpan, _other, maxDays: _maxDays, prefix: _prefix);
    if (picked == null || !mounted) return;
    _other = picked;
    _pick(SalesChoice.other);
  }

  static String _count(int n, String one, String more) => '$n ${n == 1 ? one : more}';

  /// A time of the span with the one before under it, and how much quicker or slower it is.
  Widget _time(String key, String words, int? now, int? before, {bool strong = false}) => ReportLine(
    key: ValueKey('$_prefix-$key'),
    words,
    tookWords(now),
    under: now != null && before != null ? '${tookWords(before)} before' : '',
    change: tookChange(now, before),
    strong: strong,
  );

  /// The figures of some tickets, or of the sends that went out: the average, the middle one, the longest,
  /// how many were late and how many were timed, then the ones nobody finished marking.
  List<Widget> _took(
    BuildContext context,
    String key,
    Took now,
    Took before, {
    required int lateMin,
    required String average,
    required String half,
    required String timed,
    required String open,
  }) {
    final small = Theme.of(context).textTheme.bodySmall
        ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);
    String share(Took took) => '${(took.late * 100 / took.tickets).round()}%';
    final counted = changeWords(now.tickets, before.tickets);
    return [
      _time('$key-avg', average, now.avgMs, before.avgMs, strong: true),
      _time('$key-median', half, now.medianMs, before.medianMs),
      _time('$key-longest', 'Longest', now.longestMs, before.longestMs),
      if (lateMin > 0)
        ReportLine(
          key: ValueKey('$_prefix-$key-late'),
          'Took ${minutesWords(lateMin)} or more',
          '${now.late}',
          under: [
            if (now.tickets > 0) '${share(now)} of them',
            if (before.tickets > 0) '${share(before)} before',
          ].join(' · '),
        ),
      ReportLine(
        key: ValueKey('$_prefix-$key-count'),
        timed,
        '${now.tickets}',
        under: counted.words == 'nothing before' ? '' : '${before.tickets} before',
        change: counted,
        judged: false, // more tickets are neither better nor worse
      ),
      if (now.open > 0)
        Padding(
          key: ValueKey('$_prefix-$key-open'),
          padding: const EdgeInsets.only(top: 4),
          child: Text('${now.open} more $open: in none of these times.', style: small),
        ),
    ];
  }

  /// A row for each hour or day: its name, a bar as long as its average stands against the slowest, the
  /// average and how many tickets it is of. The bar is the red of a late ticket on the kitchen screens where
  /// the average is late, and quiet otherwise.
  List<Widget> _bars(
    BuildContext context,
    List<({String key, String label, Took took})> rows, {
    required double labelWidth,
    required int lateMin,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final small = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant, fontFeatures: PosTheme.tabular);
    final late = PosColors.of(context).timerLate;
    var most = 0;
    for (final row in rows) {
      final avg = row.took.avgMs ?? 0;
      if (avg > most) most = avg;
    }
    return [
      for (final row in rows)
        Padding(
          key: ValueKey(row.key),
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            children: [
              SizedBox(width: labelWidth, child: Text(row.label)),
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: FractionallySizedBox(
                    widthFactor: most <= 0 ? 0 : ((row.took.avgMs ?? 0) / most).clamp(0.0, 1.0).toDouble(),
                    child: Container(
                      height: 8,
                      decoration: BoxDecoration(
                        color: lateMin > 0 && (row.took.avgMs ?? 0) >= lateMin * 60000 ? late : scheme.outline,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                ),
              ),
              SizedBox(
                width: 100,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      tookWords(row.took.avgMs),
                      textAlign: TextAlign.end,
                      style: const TextStyle(fontFeatures: PosTheme.tabular),
                    ),
                    Text(
                      row.took.tickets == 0 ? 'none timed' : _count(row.took.tickets, 'ticket', 'tickets'),
                      textAlign: TextAlign.end,
                      style: small,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
    ];
  }

  List<Widget> _body(BuildContext context, KitchenTimes report) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final small = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final local = MaterialLocalizations.of(context);
    final span = report.span, before = report.before;
    final late = report.lateMin;
    final many = calendarDays(span.first, span.last) > 1;
    final days = many ? 'these days' : 'this day';
    final unmarked = span.silent.fold(0, (sum, row) => sum + row.took.open);
    final dishes = _everyDish ? span.dishes : span.dishes.take(_dishesShown).toList();
    String sent(int ms) {
      final at = DateTime.fromMillisecondsSinceEpoch(ms);
      final time = TimeOfDay.fromDateTime(at).format(context);
      return many ? '${local.formatMediumDate(at)}, $time' : time;
    }

    return [
      SpanHeading(
        prefix: _prefix,
        first: span.first,
        last: span.last,
        beforeFirst: before.first,
        beforeLast: before.last,
        running: span.running,
        nowMs: report.nowMs,
      ),
      const SizedBox(height: 6),
      if (span.made.tickets > 0)
        ..._took(
          context,
          'made',
          span.made,
          before.made,
          lateMin: late,
          average: 'Average ticket',
          half: 'Half were made within',
          timed: 'Tickets timed',
          open: span.made.open == 1 ? 'was sent and not marked made' : 'were sent and not marked made',
        )
      else
        Padding(
          key: const ValueKey('$_prefix-nothing'),
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                // where the servers say what went out and no cook marks, the sends below still have times
                'No ticket was marked made on $days, so '
                '${span.out.tickets > 0 ? 'no station has a time' : 'there is nothing to time'}.'
                '${unmarked == 0 ? '' : ' ${_count(unmarked, 'ticket was', 'tickets were')} sent.'}',
              ),
              const SizedBox(height: 4),
              Text(
                'The times come from the kitchen screens, where a cook taps each dish when it is made. A kitchen '
                'that works off paper alone has none. A screen is set up on its own device, under Settings › '
                'Kitchen screen.',
                style: small,
              ),
            ],
          ),
        ),
      if (span.out.tickets > 0) ...[
        const Divider(height: 28),
        _Heading('Until it went out', tookWords(span.out.avgMs), key: const ValueKey('$_prefix-out')),
        Text(
          'A send is each time an order goes to the kitchen. It is timed from then until the last dish of it was '
          'marked gone out, at the pass or by its server.',
          style: small,
        ),
        const SizedBox(height: 4),
        ..._took(
          context,
          'out',
          span.out,
          before.out,
          lateMin: late,
          average: 'Average',
          half: 'Half went out within',
          timed: 'Sends timed',
          open: span.out.open == 1 ? 'was not marked gone out' : 'were not marked gone out',
        ),
      ],
      if (span.stations.isNotEmpty || span.silent.isNotEmpty) ...[
        const Divider(height: 28),
        const _Heading('By station', '', key: ValueKey('$_prefix-by-station')),
        for (final row in span.stations)
          ReportLine(
            key: ValueKey('$_prefix-station:${row.code}'),
            row.name,
            tookWords(row.took.avgMs),
            count: _count(row.took.tickets, 'ticket', 'tickets'),
            under: [
              'half within ${tookWords(row.took.medianMs)}',
              'longest ${tookWords(row.took.longestMs)}',
              if (late > 0 && row.took.late > 0) '${row.took.late} took ${minutesWords(late)} or more',
              if (row.took.open > 0) '${row.took.open} not marked',
            ].join(' · '),
            underWide: true,
          ),
        for (final row in span.silent)
          Padding(
            key: ValueKey('$_prefix-silent:${row.code}'),
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Text(
              '${row.name}: ${_count(row.took.open, 'ticket', 'tickets')} sent, none marked made. '
              'In none of the times.',
              style: small,
            ),
          ),
      ],
      if (span.hours.isNotEmpty) ...[
        const Divider(height: 28),
        const _Heading('By hour', '', key: ValueKey('$_prefix-by-hour')),
        Text(
          'The average ticket by the hour it was sent in'
          '${many ? ': every day of the span together' : ''}.'
          '${late > 0 ? ' A red bar is an average of ${minutesWords(late)} or more.' : ''}',
          style: small,
        ),
        const SizedBox(height: 4),
        ..._bars(
          context,
          [
            for (final row in span.hours)
              (key: '$_prefix-hour:${row.hour}', label: hourLabel(row.hour), took: row.took),
          ],
          labelWidth: 64,
          lateMin: late,
        ),
      ],
      if (span.days.length > 1) ...[
        const Divider(height: 28),
        const _Heading('By day', '', key: ValueKey('$_prefix-by-day')),
        const SizedBox(height: 4),
        ..._bars(
          context,
          [
            for (final row in span.days)
              if (row.day != null)
                (key: '$_prefix-day:${dayName(row.day!)}', label: local.formatMediumDate(row.day!), took: row.took),
          ],
          labelWidth: 92,
          lateMin: late,
        ),
      ],
      if (span.dishes.isNotEmpty) ...[
        const Divider(height: 28),
        const _Heading('Dishes, slowest first', '', key: ValueKey('$_prefix-dishes')),
        Text(
          'Each dish from when it was sent until the last station that cooks it marked it made: its average, '
          'and how many times it was timed.',
          style: small,
        ),
        const SizedBox(height: 4),
        for (final row in dishes)
          ReportLine(
            key: ValueKey('$_prefix-dish:${row.name}'),
            row.name,
            tookWords(row.took.avgMs),
            count: '${row.took.tickets}×',
            under: 'longest ${tookWords(row.took.longestMs)}',
          ),
        if (!_everyDish && span.dishes.length > _dishesShown)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: const ValueKey('$_prefix-every-dish'),
              onPressed: () => setState(() => _everyDish = true),
              child: Text('All ${span.dishes.length} dishes'),
            ),
          ),
      ],
      if (span.slowest.isNotEmpty) ...[
        const Divider(height: 28),
        const _Heading('Longest tickets', '', key: ValueKey('$_prefix-slowest')),
        for (final (place, row) in span.slowest.indexed)
          ReportLine(
            key: ValueKey('$_prefix-slow:$place'),
            row.title,
            tookWords(row.tookMs),
            under: '${row.station} · sent ${sent(row.sentMs)}',
            underWide: true,
          ),
      ],
      Padding(
        padding: const EdgeInsets.only(top: 16),
        child: Text(
          "A ticket is one station's dishes of one send of an order, as on that station's screen. It is timed "
          'from when it was sent (an order sent ahead: from when its time came) until the station marked the '
          'last of its dishes made. Only what was marked is timed. A dish voided or taken off is left out, and '
          'so is a check voided whole. The middle time says more than the average where a few tickets were '
          'marked late. A day runs from 4 AM to 4 AM.',
          key: const ValueKey('$_prefix-note'),
          style: small,
        ),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final report = _report;
    final Widget body;
    if (_error != null) {
      body = SpanError(prefix: _prefix, message: _error!, onRetry: _load);
    } else if (report == null) {
      body = SpanReading(prefix: _prefix, many: _choice == SalesChoice.fourWeeks || _choice == SalesChoice.other);
    } else {
      body = KeyedSubtree(
        key: ValueKey(_picked),
        child: ListView(
          key: const ValueKey('$_prefix-list'),
          controller: _scroll,
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          children: _body(context, report),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Kitchen times'),
        actions: [
          IconButton(
            key: const ValueKey('$_prefix-refresh'),
            tooltip: 'Read again',
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Column(
            children: [
              SpanChips(prefix: _prefix, choice: _choice, other: _other, onPick: _pick, onOther: _pickOther),
              Expanded(child: body),
            ],
          ),
        ),
      ),
    );
  }
}

/// A section's name, with a figure on the right where one sums it up.
class _Heading extends StatelessWidget {
  const _Heading(this.title, this.total, {super.key});

  final String title;
  final String total;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(child: Text(title, style: theme.textTheme.titleLarge)),
          if (total.isNotEmpty)
            Text(total, style: theme.textTheme.titleLarge?.copyWith(fontFeatures: PosTheme.tabular)),
        ],
      ),
    );
  }
}
