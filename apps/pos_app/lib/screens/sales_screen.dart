import 'package:flutter/material.dart';

import '../api.dart';
import '../day_report.dart';
import '../sales_report.dart';
import '../timeclock.dart' show hoursMinutes;
import 'theme.dart';

/// Asks which days to add up; null when the calendar was closed without any.
typedef PickSpan = Future<DateTimeRange?> Function(BuildContext context, DateTimeRange? from);

Future<DateTimeRange?> _deviceSpan(BuildContext context, DateTimeRange? from) {
  final now = DateTime.now();
  return showDateRangePicker(
    context: context,
    initialDateRange: from,
    firstDate: DateTime(now.year - 2, now.month, now.day),
    lastDate: DateTime(now.year, now.month, now.day + 60), // an order can be rung for a day to come
    helpText: 'The days to add up',
    saveText: 'Read',
  );
}

/// Sales over any days, for a manager (docs/sales-report.md): one day, the seven or the twenty-eight just
/// gone, or any days picked on the calendar, each figure beside the same days whole weeks earlier. The
/// headline figures first (net sales, checks, guests, the average check and guest, how long a table stood,
/// and the hours worked where the time clock is used), then what the checks come to, each day, each hour,
/// each category and kind of order, the money taken and the comps. The hub does every sum. One column, so
/// it reads the same on a phone.
class SalesScreen extends StatefulWidget {
  const SalesScreen({
    super.key,
    required this.api,
    required this.token,
    this.now = DateTime.now,
    this.pickSpan = _deviceSpan,
  });

  final PosApi api;

  /// The manager's session (`POST /admin/session`): every call here carries it.
  final String token;

  /// The time on this device: which day yesterday was.
  final DateTime Function() now;
  final PickSpan pickSpan;

  @override
  State<SalesScreen> createState() => _SalesScreenState();
}

class _SalesScreenState extends State<SalesScreen> {
  SalesChoice _choice = SalesChoice.week;
  DateTimeRange? _other;
  SalesReport? _report;
  String? _error;
  int _asked = 0;
  int _maxDays = 92;
  final _scroll = ScrollController();

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
      final report = await widget.api.salesReport(widget.token, from: from, to: to);
      if (!mounted || ask != _asked) return;
      setState(() {
        _report = report;
        _maxDays = report.maxDays;
      });
    } on ApiException catch (err) {
      if (!mounted || ask != _asked) return;
      setState(
        () => _error = switch (err.status) {
          401 || 403 => "The manager's hour here is over: go back and open Location again.",
          404 => 'This hub is older than the sales report. Update the hub to see it here.',
          null => 'The hub is not answering',
          _ => (err.detail?['message'] as String?) ?? err.message,
        },
      );
    }
  }

  void _pick(SalesChoice choice) {
    if (_scroll.hasClients) _scroll.jumpTo(0); // other days are read from their top
    setState(() {
      _choice = choice;
      _report = null;
    });
    _load();
  }

  Future<void> _pickOther() async {
    final messenger = ScaffoldMessenger.of(context);
    final picked = await widget.pickSpan(context, _other);
    if (picked == null || !mounted) return;
    // counted on the calendar, so a night the clocks change is still one day
    final days =
        DateTime.utc(
          picked.end.year,
          picked.end.month,
          picked.end.day,
        ).difference(DateTime.utc(picked.start.year, picked.start.month, picked.start.day)).inDays +
        1;
    if (days > _maxDays) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            key: const ValueKey('sales-too-long'),
            content: Text('At most $_maxDays days at a time: that was $days. Pick fewer days.'),
          ),
        );
      return;
    }
    _other = picked;
    _pick(SalesChoice.other);
  }

  String _time(int atMs) => TimeOfDay.fromDateTime(DateTime.fromMillisecondsSinceEpoch(atMs)).format(context);

  /// "Mon, Nov 9 to Sun, Nov 15, 2026", or the whole date of a single day.
  String _days(SalesSpan span, {bool whole = true}) {
    final local = MaterialLocalizations.of(context);
    if (span.dayCount == 1) return whole ? local.formatFullDate(span.first) : local.formatMediumDate(span.first);
    final year = whole ? ', ${span.last.year}' : '';
    return '${local.formatMediumDate(span.first)} to ${local.formatMediumDate(span.last)}$year';
  }

  static num _n(String? amount) => double.tryParse(amount ?? '') ?? 0;

  /// A figure of the span with the one before under it and how far apart they are. A figure there was
  /// nothing of before says only that.
  Widget _figure(
    String key,
    String words, {
    required String now,
    required String before,
    required Change change,
    String note = '',
    bool judged = true,
  }) => _Line(
    key: ValueKey(key),
    words,
    now,
    under: [if (note.isNotEmpty) note, if (before != '–' && change.words != _nothing) '$before before'].join(' · '),
    change: change,
    judged: judged,
    strong: true,
  );

  static const _nothing = 'nothing before';

  /// A row of a split of the sales, with what the same name came to in the days before under it and how far
  /// apart the two are.
  Widget _split(
    String key,
    DayRow row,
    List<DayRow> before, {
    required String words,
    String count = '',
    List<String> about = const [],
    bool minus = false,
    bool judged = true,
  }) {
    final was = before.where((other) => other.name == row.name && other.group == row.group).firstOrNull;
    final amount = was?.amount ?? '0.00';
    final change = changeWords(_n(row.amount), _n(amount));
    return _Line(
      key: ValueKey(key),
      words,
      dollars(minus ? '-${row.amount}' : row.amount),
      count: count,
      under: [...about, if (change.words != _nothing) '${dollars(minus ? '-$amount' : amount)} before'].join(' · '),
      change: change,
      judged: judged,
    );
  }

  List<Widget> _body(BuildContext context, SalesReport report) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final small = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final span = report.span, before = report.before;
    final weeks = report.weeksBack;
    final many = span.dayCount > 1;
    final clock = span.clock, clockBefore = before.clock;
    String orDash(String? amount) => amount == null ? '–' : dollars(amount);
    String count(int n, String one, String more) => '$n ${n == 1 ? one : more}';

    final beforeHours = {for (final row in before.hours) row.hour: row};
    final hours = [...span.hours, ...before.hours.where((row) => span.hours.every((mine) => mine.hour != row.hour))]
      ..sort((a, b) => _place(a.hour).compareTo(_place(b.hour)));
    final spanHours = {for (final row in span.hours) row.hour: row};

    return [
      Text(_days(span), key: const ValueKey('sales-days'), style: theme.textTheme.titleMedium),
      Text(
        'Beside the same ${many ? 'days' : 'day'} ${weeks == 1 ? 'a week' : '$weeks weeks'} before: '
        '${_days(before, whole: false)}.',
        key: const ValueKey('sales-beside'),
        style: small,
      ),
      if (span.running)
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(
            '${many ? 'The last day' : 'The day'} is still running: read at ${_time(report.nowMs)}. '
            'Its figures will still move.',
            key: const ValueKey('sales-running'),
            style: small,
          ),
        ),
      const SizedBox(height: 6),
      _figure(
        'sales-net',
        'Net sales',
        now: dollars(span.net),
        before: dollars(before.net),
        change: changeWords(_n(span.net), _n(before.net)),
      ),
      _figure(
        'sales-checks',
        'Checks',
        now: '${span.checks}',
        before: '${before.checks}',
        change: changeWords(span.checks, before.checks),
      ),
      _figure(
        'sales-guests',
        'Guests',
        now: '${span.guests}',
        before: '${before.guests}',
        change: changeWords(span.guests, before.guests),
      ),
      _figure(
        'sales-per-check',
        'Average check',
        now: orDash(span.perCheck),
        before: orDash(before.perCheck),
        change: changeWords(_n(span.perCheck), _n(before.perCheck)),
      ),
      _figure(
        'sales-per-guest',
        'Average per guest',
        now: orDash(span.perGuest),
        before: orDash(before.perGuest),
        change: changeWords(_n(span.perGuest), _n(before.perGuest)),
      ),
      _figure(
        'sales-turn',
        'A table, opened to closed',
        now: span.turnMinutes == null ? '–' : minutesWords(span.turnMinutes!),
        before: before.turnMinutes == null ? '–' : minutesWords(before.turnMinutes!),
        change: changeWords(span.turnMinutes ?? 0, before.turnMinutes ?? 0),
        note: count(span.turnTables, 'table', 'tables'),
        judged: false,
      ),
      if (clock != null) ...[
        _figure(
          'sales-hours',
          'Hours worked',
          now: hoursMinutes(clock.workedMs),
          before: hoursMinutes(clockBefore?.workedMs ?? 0),
          change: changeWords(clock.workedMs, clockBefore?.workedMs ?? 0),
          note: count(clock.people, 'person', 'people'),
          judged: false,
        ),
        _figure(
          'sales-per-hour',
          'Net sales per hour worked',
          now: orDash(clock.netPerHour),
          before: orDash(clockBefore?.netPerHour),
          change: changeWords(_n(clock.netPerHour), _n(clockBefore?.netPerHour)),
        ),
        if (clock.unended > 0)
          Padding(
            key: const ValueKey('sales-unended'),
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '${count(clock.unended, 'shift', 'shifts')} nobody clocked out of: '
              'the hours are too many until ${clock.unended == 1 ? 'it is' : 'they are'} corrected under Hours.',
              style: TextStyle(color: scheme.error),
            ),
          ),
      ],
      const Divider(height: 28),
      _Heading('Sales', dollars(span.total), key: const ValueKey('sales-sales')),
      _Line('Dishes sold', dollars(span.gross), key: const ValueKey('sales-gross')),
      if (isMoney(span.discountTotal))
        _Line('Comps and discounts', dollars('-${span.discountTotal}'), key: const ValueKey('sales-discounts')),
      _Line('Net sales', dollars(span.net)),
      if (isMoney(span.charges)) _Line('Charges', dollars(span.charges)),
      if (isMoney(span.gratuity)) _Line('Gratuity', dollars(span.gratuity), under: 'Paid over to staff'),
      _Line('Sales tax', dollars(span.tax), key: const ValueKey('sales-tax')),
      _Line('Total', dollars(span.total), strong: true, key: const ValueKey('sales-total')),
      if (span.days.length > 1) ...[
        const Divider(height: 28),
        _Heading('By day', dollars(span.net), key: const ValueKey('sales-by-day')),
        Text(
          'Net sales of each day. The thin bar and the small figure are the same day '
          '${weeks == 1 ? 'a week' : '$weeks weeks'} before.',
          style: small,
        ),
        const SizedBox(height: 4),
        ..._bars(context, [
          for (final (i, day) in span.days.indexed)
            (
              key: 'sales-day:${dayName(day.day)}',
              label: MaterialLocalizations.of(context).formatMediumDate(day.day),
              now: day.net,
              before: i < before.days.length ? before.days[i].net : '0.00',
            ),
        ], labelWidth: 92),
      ],
      if (hours.isNotEmpty) ...[
        const Divider(height: 28),
        _Heading('By hour', dollars(span.gross), key: const ValueKey('sales-by-hour')),
        Text(
          'This and each list below splits the dishes sold, before comps and tax'
          '${many ? ': every day of the span added up by the hour of the day' : ''}.',
          style: small,
        ),
        const SizedBox(height: 4),
        ..._bars(context, [
          for (final row in hours)
            (
              key: 'sales-hour:${row.hour}',
              label: hourLabel(row.hour),
              now: spanHours[row.hour]?.amount ?? '0.00',
              before: beforeHours[row.hour]?.amount ?? '0.00',
            ),
        ], labelWidth: 64),
      ],
      if (span.categories.isNotEmpty) ...[
        const Divider(height: 28),
        _Heading('By category', dollars(span.gross), key: const ValueKey('sales-categories')),
        for (final menu in span.menus) ...[
          if (span.menus.length > 1) _Label(menu.name.isEmpty ? 'Other' : menu.name, amount: dollars(menu.amount)),
          for (final row in span.categoriesOf(menu.group))
            _split(
              'sales-category:${menu.group}:${row.name}',
              row,
              before.categories,
              words: row.name,
              count: '${row.count}×',
            ),
        ],
        const SizedBox(height: 10),
        const _Label('By kind of order'),
        for (final row in span.kinds)
          _split(
            'sales-kind:${row.name}',
            row,
            before.kinds,
            words: kindLabel(row.name),
            about: [count(row.count, 'check', 'checks'), if (row.guests > 0) count(row.guests, 'guest', 'guests')],
          ),
      ],
      const Divider(height: 28),
      _Heading('Money taken', dollars(span.takenTotal), key: const ValueKey('sales-taken')),
      Text('Every payment recorded in ${many ? 'these days' : 'the day'}, whatever check it was for.', style: small),
      if (span.taken.isEmpty) const Text('No payment was recorded.'),
      for (final row in span.taken)
        _split(
          'sales-taken:${row.name}',
          row,
          before.taken,
          words: methodLabel(row.name),
          about: [count(row.count, 'payment', 'payments')],
          judged: false,
        ),
      const Divider(height: 28),
      _Heading(
        'Comps and discounts',
        isMoney(span.discountTotal) ? dollars('-${span.discountTotal}') : '',
        key: const ValueKey('sales-off'),
      ),
      if (span.discounts.isEmpty) const Text('No comp and no discount.'),
      for (final row in span.discounts)
        _split(
          'sales-discount:${row.name}',
          row,
          before.discounts,
          words: row.name,
          count: '${row.count}×',
          minus: true,
          judged: false,
        ),
      Padding(
        padding: const EdgeInsets.only(top: 16),
        child: Text(
          'A day runs from 4 AM to 4 AM. A check counts on the day it was opened, or on the day it is for when '
          'that is later; a check voided whole is no sale. Every sale and every payment is in these figures. '
          "A table's time is the middle one of the tables closed: half stood longer, half not as long. "
          'Voids, and each check still open, are in The day.',
          key: const ValueKey('sales-note'),
          style: small,
        ),
      ),
    ];
  }

  /// Where an hour falls in a night: from 4 AM round to 3 AM, and dishes with no time kept last.
  static int _place(int? hour) => hour == null ? 24 : (hour - 4) % 24;

  /// Rows of two bars, the span's over the thin one of the days before, drawn to the same scale.
  List<Widget> _bars(
    BuildContext context,
    List<({String key, String label, String now, String before})> rows, {
    required double labelWidth,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final small = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant, fontFeatures: PosTheme.tabular);
    var most = 0.0;
    for (final row in rows) {
      for (final amount in [_n(row.now), _n(row.before)]) {
        if (amount > most) most = amount.toDouble();
      }
    }
    Widget bar(String amount, double height, Color color) => Align(
      alignment: Alignment.centerLeft,
      child: FractionallySizedBox(
        widthFactor: most <= 0 ? 0 : (_n(amount) / most).clamp(0.0, 1.0).toDouble(),
        child: Container(
          height: height,
          decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(height / 2)),
        ),
      ),
    );
    return [
      for (final row in rows)
        Padding(
          key: ValueKey(row.key),
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            children: [
              SizedBox(width: labelWidth, child: Text(row.label)),
              Expanded(
                child: Column(
                  children: [
                    bar(row.now, 8, scheme.primary),
                    const SizedBox(height: 3),
                    bar(row.before, 4, scheme.outline),
                  ],
                ),
              ),
              SizedBox(
                width: 100,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(dollars(row.now), style: const TextStyle(fontFeatures: PosTheme.tabular)),
                    Text(dollars(row.before), style: small),
                  ],
                ),
              ),
            ],
          ),
        ),
    ];
  }

  String _otherLabel(BuildContext context) {
    final other = _other;
    if (_choice != SalesChoice.other || other == null) return 'Other days';
    final local = MaterialLocalizations.of(context);
    final first = local.formatShortMonthDay(other.start);
    return DateUtils.isSameDay(other.start, other.end) ? first : '$first to ${local.formatShortMonthDay(other.end)}';
  }

  @override
  Widget build(BuildContext context) {
    final report = _report;
    final Widget body;
    if (_error != null) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!, key: const ValueKey('sales-error'), textAlign: TextAlign.center),
              const SizedBox(height: 12),
              OutlinedButton(onPressed: _load, child: const Text('Try again')),
            ],
          ),
        ),
      );
    } else if (report == null) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            key: const ValueKey('sales-reading'),
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              const Text('Adding up the days'),
              if (_choice == SalesChoice.fourWeeks || _choice == SalesChoice.other)
                Text(
                  'Many days can take some seconds the first time.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
            ],
          ),
        ),
      );
    } else {
      body = ListView(
        key: const ValueKey('sales-list'),
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: _body(context, report),
      );
    }
    Widget chip(SalesChoice choice, String key, String label) => ChoiceChip(
      key: ValueKey('sales:$key'),
      label: Text(label),
      selected: _choice == choice,
      onSelected: (_) => _pick(choice),
    );
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sales'),
        actions: [
          IconButton(
            key: const ValueKey('sales-refresh'),
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
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      chip(SalesChoice.today, 'today', 'Today'),
                      chip(SalesChoice.yesterday, 'yesterday', 'Yesterday'),
                      chip(SalesChoice.week, 'week', '7 days'),
                      chip(SalesChoice.fourWeeks, 'four-weeks', '4 weeks'),
                      ChoiceChip(
                        key: const ValueKey('sales:other'),
                        avatar: const Icon(Icons.date_range_outlined, size: 18),
                        label: Text(_otherLabel(context)),
                        selected: _choice == SalesChoice.other,
                        onSelected: (_) => _pickOther(),
                      ),
                    ],
                  ),
                ),
              ),
              Expanded(child: body),
            ],
          ),
        ),
      ),
    );
  }
}

/// A section's name with what it came to on the right.
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
          Text(total, style: theme.textTheme.titleLarge?.copyWith(fontFeatures: PosTheme.tabular)),
        ],
      ),
    );
  }
}

/// The name of a list inside a section, with what it came to when that is worth saying.
class _Label extends StatelessWidget {
  const _Label(this.title, {this.amount});

  final String title;
  final String? amount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.primary);
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 2),
      child: Row(
        children: [
          Expanded(child: Text(title, style: style)),
          if (amount != null) Text(amount!, style: style?.copyWith(fontFeatures: PosTheme.tabular)),
        ],
      ),
    );
  }
}

/// One row: words, how many when that is known, and an amount at the right edge; a quieter line under the
/// words for the figure before, ending with how far the two are apart ([change]). Where more is better
/// ([judged]), "up" is green and "down" red; the words say which either way.
class _Line extends StatelessWidget {
  const _Line(
    this.words,
    this.amount, {
    super.key,
    this.under = '',
    this.count = '',
    this.change,
    this.judged = true,
    this.strong = false,
  });

  final String words;
  final String amount;
  final String under;
  final String count;
  final Change? change;
  final bool judged;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final small = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final style = TextStyle(fontWeight: strong ? FontWeight.w700 : null);
    final moved = change != null && change!.words.isNotEmpty ? change! : null;
    final colors = PosColors.of(context);
    final movedColor = !judged || moved?.up == null
        ? null
        : moved!.up!
        ? (theme.brightness == Brightness.dark ? colors.firedBorder : colors.firedText)
        : scheme.error;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        // the count and the amount sit on the line of the words, not above a second line under them
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(words, style: style),
                if (under.isNotEmpty || moved != null)
                  Text.rich(
                    TextSpan(
                      children: [
                        if (under.isNotEmpty) TextSpan(text: under),
                        if (under.isNotEmpty && moved != null) const TextSpan(text: ' · '),
                        if (moved != null)
                          TextSpan(
                            text: moved.words,
                            // "up" and "down" stand out; "the same" and "nothing before" do not
                            style: TextStyle(color: movedColor, fontWeight: moved.up == null ? null : FontWeight.w600),
                          ),
                      ],
                    ),
                    style: small,
                  ),
              ],
            ),
          ),
          if (count.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Text(count, style: small),
            ),
          // a column of its own, so the counts line up whatever the amounts
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 84),
            child: Padding(
              padding: const EdgeInsets.only(left: 12),
              child: Text(
                amount,
                textAlign: TextAlign.end,
                style: style.copyWith(fontFeatures: PosTheme.tabular),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
