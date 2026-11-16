import 'package:flutter/material.dart';

import '../api.dart';
import '../day_report.dart';
import '../sales_report.dart';
import '../timeclock.dart' show hoursMinutes;
import 'dishes_screen.dart';
import 'span_report.dart';
import 'theme.dart';

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
    this.pickSpan = deviceSpan,
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

  /// How many times other days were picked: each time the list is a new one, laid out from its top (a list
  /// that stayed would keep its place among rows that are no longer the same).
  int _picked = 0;
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
      setState(() => _error = reportError(err, 'the sales report'));
    }
  }

  void _pick(SalesChoice choice) {
    if (_scroll.hasClients) _scroll.jumpTo(0); // other days are read from their top
    setState(() {
      _choice = choice;
      _report = null;
      _picked++;
    });
    _load();
  }

  Future<void> _pickOther() async {
    final picked = await askOtherDays(context, widget.pickSpan, _other, maxDays: _maxDays, prefix: 'sales');
    if (picked == null || !mounted) return;
    _other = picked;
    _pick(SalesChoice.other);
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
  }) => ReportLine(
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
    return ReportLine(
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
      SpanHeading(
        prefix: 'sales',
        first: span.first,
        last: span.last,
        beforeFirst: before.first,
        beforeLast: before.last,
        running: span.running,
        nowMs: report.nowMs,
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
      ReportLine('Dishes sold', dollars(span.gross), key: const ValueKey('sales-gross')),
      if (isMoney(span.discountTotal))
        ReportLine('Comps and discounts', dollars('-${span.discountTotal}'), key: const ValueKey('sales-discounts')),
      ReportLine('Net sales', dollars(span.net)),
      if (isMoney(span.charges)) ReportLine('Charges', dollars(span.charges)),
      if (isMoney(span.gratuity)) ReportLine('Gratuity', dollars(span.gratuity), under: 'Paid over to staff'),
      ReportLine(
        'Sales tax',
        dollars(span.tax),
        under: span.exempt.count > 0 ? span.exempt.words : '',
        underWide: true,
        key: const ValueKey('sales-tax'),
      ),
      ReportLine('Total', dollars(span.total), strong: true, key: const ValueKey('sales-total')),
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
        ListTile(
          key: const ValueKey('sales-dishes'),
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.format_list_numbered),
          title: const Text('Each dish of these days, best to worst'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => DishesScreen(
                api: widget.api,
                token: widget.token,
                now: widget.now,
                pickSpan: widget.pickSpan,
                choice: _choice,
                other: _other,
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
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

  @override
  Widget build(BuildContext context) {
    final report = _report;
    final Widget body;
    if (_error != null) {
      body = SpanError(prefix: 'sales', message: _error!, onRetry: _load);
    } else if (report == null) {
      body = SpanReading(prefix: 'sales', many: _choice == SalesChoice.fourWeeks || _choice == SalesChoice.other);
    } else {
      body = KeyedSubtree(
        key: ValueKey(_picked),
        child: ListView(
          key: const ValueKey('sales-list'),
          controller: _scroll,
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          children: _body(context, report),
        ),
      );
    }
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
              SpanChips(prefix: 'sales', choice: _choice, other: _other, onPick: _pick, onOther: _pickOther),
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
