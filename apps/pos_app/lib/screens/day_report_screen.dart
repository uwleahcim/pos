import 'package:flutter/material.dart';

import '../api.dart';
import '../day_report.dart';
import '../timeclock.dart' show hoursMinutes;
import 'adjustments_screen.dart';
import 'check_history_screen.dart';
import 'theme.dart';
import 'time_clock_screen.dart';

Future<DateTime?> _deviceDay(BuildContext context, DateTime from) {
  final now = DateTime.now();
  return showDatePicker(
    context: context,
    initialDate: from.isAfter(now) ? now : from,
    firstDate: DateTime(now.year - 2, now.month, now.day),
    lastDate: DateTime(now.year, now.month, now.day + 60), // an order can be rung for a day to come
    helpText: 'The day to read',
  );
}

enum _Which { today, yesterday, other }

/// The day's report, for a manager (docs/day-report.md): what is still open before going home, what the day
/// sold and what its checks come to, the money taken by how it was paid, the sales by category, by kind of
/// order, by who rang them in and by hour, and what came off the checks. For the day that is running,
/// yesterday or any other day; Print puts it on paper where the bills print. The hub does every sum. One
/// column, so it reads the same on a phone.
class DayReportScreen extends StatefulWidget {
  const DayReportScreen({
    super.key,
    required this.api,
    required this.token,
    this.device,
    this.now = DateTime.now,
    this.pickDay = _deviceDay,
  });

  final PosApi api;

  /// The manager's session (`POST /admin/session`): every call here carries it.
  final String token;

  /// This terminal, for the screens opened from here.
  final String? device;

  /// The time on this device: which day yesterday was.
  final DateTime Function() now;
  final PickDay pickDay;

  @override
  State<DayReportScreen> createState() => _DayReportScreenState();
}

class _DayReportScreenState extends State<DayReportScreen> {
  _Which _which = _Which.today;
  DateTime? _other;
  DayReport? _report;
  String? _error;
  int _asked = 0;
  bool _printing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// The day asked for, as the hub names one; null for the day that is running, which the hub knows best.
  String? get _day => switch (_which) {
    _Which.today => null,
    _Which.yesterday => serviceDay(widget.now().subtract(const Duration(days: 1))),
    _Which.other => dayName(_other!),
  };

  Future<void> _load() async {
    final ask = ++_asked;
    setState(() => _error = null);
    try {
      final report = await widget.api.dayReport(widget.token, day: _day);
      if (mounted && ask == _asked) setState(() => _report = report);
    } on ApiException catch (err) {
      if (!mounted || ask != _asked) return;
      setState(
        () => _error = switch (err.status) {
          401 || 403 => "The manager's hour here is over: go back and open Location again.",
          404 => "This hub is older than the day's report. Update the hub to see it here.",
          null => 'The hub is not answering',
          _ => (err.detail?['message'] as String?) ?? err.message,
        },
      );
    }
  }

  void _pick(_Which which) {
    setState(() {
      _which = which;
      _report = null;
    });
    _load();
  }

  Future<void> _pickOther() async {
    final picked = await widget.pickDay(context, _other ?? widget.now());
    if (picked == null || !mounted) return;
    _other = picked;
    _pick(_Which.other);
  }

  Future<void> _print() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _printing = true);
    String said;
    try {
      final own = widget.api.settings.billPrinter;
      final at = await widget.api.printDay(widget.token, day: _day, printer: own.isEmpty ? null : own);
      said = at.isEmpty ? 'The day is printing' : 'The day is printing at $at';
    } on ApiException catch (err) {
      said = switch (err.status) {
        401 || 403 => "The manager's hour here is over: go back and open Location again.",
        null => 'The hub is not answering: nothing was printed',
        _ => (err.detail?['message'] as String?) ?? 'Could not print: ${err.message}',
      };
    }
    if (!mounted) return;
    setState(() => _printing = false);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(key: const ValueKey('day-printed'), content: Text(said)));
  }

  String _time(int? atMs) =>
      atMs == null ? '' : TimeOfDay.fromDateTime(DateTime.fromMillisecondsSinceEpoch(atMs)).format(context);

  /// A check that still needs something: a tap opens its whole history (docs/check-history.md).
  Widget _check(DayCheck check, {String? note}) => InkWell(
    key: ValueKey('day-check:${check.orderId}'),
    onTap: () => Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CheckHistoryScreen(api: widget.api, token: widget.token, orderId: check.orderId),
      ),
    ),
    child: _Line(
      check.where,
      dollars(check.due),
      under: [
        ?note,
        if (check.server.isNotEmpty) check.server,
        if (check.openedMs != null) 'opened ${_time(check.openedMs)}',
        if (check.unsent > 0) '${check.unsent} ${check.unsent == 1 ? 'dish' : 'dishes'} not sent',
      ].join(' · '),
    ),
  );

  List<Widget> _stillOpen(BuildContext context, DayReport report) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final clock = report.clock;
    final local = MaterialLocalizations.of(context);
    return [
      _Heading(
        report.today ? 'Still open' : 'Still open from this day',
        report.allClosed ? '' : dollars(report.due),
        key: const ValueKey('day-open'),
      ),
      if (report.allClosed)
        Row(
          key: const ValueKey('day-all-closed'),
          children: [
            Icon(Icons.check_circle, size: 20, color: PosColors.of(context).firedBorder),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                report.checks == 0 && report.today
                    ? 'Nothing is open.'
                    : 'Nothing: every check is closed and paid${clock != null ? ', and nobody is on the clock' : ''}.',
              ),
            ),
          ],
        )
      else ...[
        if (report.open.isNotEmpty) ...[
          _Label('${report.open.length} ${report.open.length == 1 ? 'check' : 'checks'} still open'),
          for (final check in report.open) _check(check),
        ],
        if (report.unpaid.isNotEmpty) ...[
          _Label('Closed, but not paid in full'),
          for (final check in report.unpaid) _check(check),
        ],
        if (report.earlier.isNotEmpty) ...[
          _Label('Open from earlier days'),
          for (final check in report.earlier)
            _check(check, note: local.formatShortMonthDay(DateTime.tryParse(check.day) ?? report.day)),
        ],
        if (report.open.isNotEmpty || report.unpaid.isNotEmpty || report.earlier.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              'Tap a check to read its history.',
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        if (report.unsent > 0)
          Padding(
            key: const ValueKey('day-unsent'),
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              '${report.unsent} ${report.unsent == 1 ? 'dish was' : 'dishes were'} never sent to the kitchen.',
              style: TextStyle(color: scheme.error),
            ),
          ),
        if (clock != null && clock.onNow.isNotEmpty)
          Padding(
            key: const ValueKey('day-on-clock'),
            padding: const EdgeInsets.only(top: 6),
            child: Text('Still on the clock: ${clock.onNow.join(', ')}'),
          ),
        if (clock != null && clock.unended > 0)
          Padding(
            key: const ValueKey('day-unended'),
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              '${clock.unended} ${clock.unended == 1 ? 'shift' : 'shifts'} nobody clocked out of: '
              'correct ${clock.unended == 1 ? 'it' : 'them'} under Hours.',
              style: TextStyle(color: scheme.error),
            ),
          ),
      ],
    ];
  }

  List<Widget> _body(BuildContext context, DayReport report) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final small = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final clock = report.clock;
    final most = report.hours.fold<double>(0, (m, row) {
      final amount = double.tryParse(row.amount) ?? 0;
      return amount > m ? amount : m;
    });
    final cameOff =
        report.discounts.isNotEmpty ||
        report.voids.count > 0 ||
        report.takenOff.count > 0 ||
        report.voidedChecks.count > 0;
    return [
      Text(
        MaterialLocalizations.of(context).formatFullDate(report.day),
        key: const ValueKey('day-date'),
        style: theme.textTheme.titleMedium,
      ),
      Text(
        report.today
            ? 'The day is still running: read at ${_time(report.nowMs)}. A day runs from 4 AM to 4 AM.'
            : 'From 4 AM that morning to 4 AM the next.',
        style: small,
      ),
      ..._stillOpen(context, report),
      const Divider(height: 28),
      _Heading('Sales', dollars(report.total), key: const ValueKey('day-sales')),
      _Line('Dishes sold', dollars(report.gross), key: const ValueKey('day-gross')),
      if (isMoney(report.discountTotal))
        _Line('Comps and discounts', dollars('-${report.discountTotal}'), key: const ValueKey('day-discounts')),
      _Line('Net sales', dollars(report.net), key: const ValueKey('day-net')),
      if (isMoney(report.charges)) _Line('Charges', dollars(report.charges)),
      if (isMoney(report.gratuity)) _Line('Gratuity', dollars(report.gratuity), under: 'Paid over to staff'),
      _Line(
        'Sales tax',
        dollars(report.tax),
        under: report.exempt.count > 0 ? report.exempt.words : '',
        key: const ValueKey('day-tax'),
      ),
      _Line('Total', dollars(report.total), strong: true, key: const ValueKey('day-total')),
      Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(
          '${report.checks} ${report.checks == 1 ? 'check' : 'checks'} · '
          '${report.guests} ${report.guests == 1 ? 'guest' : 'guests'}',
          key: const ValueKey('day-checks'),
          style: small,
        ),
      ),
      const Divider(height: 28),
      _Heading('Money taken', dollars(report.takenTotal), key: const ValueKey('day-taken')),
      Text('Every payment recorded during the day, whatever check it was for.', style: small),
      if (report.taken.isEmpty) const Text('No payment was recorded.'),
      for (final row in report.taken)
        _Line(
          key: ValueKey('day-taken:${row.name}'),
          methodLabel(row.name),
          dollars(row.amount),
          under: '${row.count} ${row.count == 1 ? 'payment' : 'payments'}',
        ),
      if (isMoney(report.forOtherDays))
        _Line(
          'Of it, for checks of other days',
          dollars(report.forOtherDays),
          faint: true,
          key: const ValueKey('day-other-days'),
        ),
      if (isMoney(report.onVoided))
        _Line(
          'Of it, on checks voided since',
          dollars(report.onVoided),
          under: 'Money was taken and the check then voided: see that it went back.',
          warn: true,
          key: const ValueKey('day-on-voided'),
        ),
      const SizedBox(height: 10),
      const _Label("The day's checks"),
      _Line('Come to', dollars(report.total)),
      _Line('Paid this day', dollars(report.paidThisDay), key: const ValueKey('day-paid')),
      if (isMoney(report.paidOtherDays))
        _Line('Paid on other days', dollars(report.paidOtherDays), key: const ValueKey('day-paid-other')),
      if (isMoney(report.over))
        _Line(
          'Paid over',
          dollars(report.over),
          under: 'More was paid than the check comes to',
          warn: true,
          key: const ValueKey('day-over'),
        ),
      _Line('Still owed', dollars(report.due), strong: true, warn: isMoney(report.due), key: const ValueKey('day-due')),
      Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text(
          'The cash in the drawer is not counted here yet, so nothing says over or short: '
          'count it against Cash above.',
          style: small,
        ),
      ),
      if (report.categories.isNotEmpty) ...[
        const Divider(height: 28),
        _Heading('By category', dollars(report.gross), key: const ValueKey('day-categories')),
        Text('This and each list below splits the dishes sold, before comps and tax.', style: small),
        for (final menu in report.menus) ...[
          if (report.menus.length > 1) _Label(menu.name.isEmpty ? 'Other' : menu.name, amount: dollars(menu.amount)),
          for (final row in report.categoriesOf(menu.group))
            _Line(
              key: ValueKey('day-category:${menu.group}:${row.name}'),
              row.name,
              dollars(row.amount),
              count: '${row.count}×',
            ),
        ],
        const SizedBox(height: 10),
        const _Label('By kind of order'),
        for (final row in report.kinds)
          _Line(
            key: ValueKey('day-kind:${row.name}'),
            kindLabel(row.name),
            dollars(row.amount),
            under: [
              '${row.count} ${row.count == 1 ? 'check' : 'checks'}',
              if (row.guests > 0) '${row.guests} ${row.guests == 1 ? 'guest' : 'guests'}',
            ].join(' · '),
          ),
        const SizedBox(height: 10),
        const _Label('Rung in by'),
        for (final (i, row) in report.staff.indexed)
          _Line(
            key: ValueKey('day-staff:$i'),
            row.name.isEmpty ? 'Nobody named' : row.name,
            dollars(row.amount),
            count: '${row.count}×',
          ),
        const SizedBox(height: 10),
        const _Label('By hour'),
        for (final row in report.hours)
          Padding(
            key: ValueKey('day-hour:${row.hour}'),
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              children: [
                SizedBox(width: 64, child: Text(hourLabel(row.hour))),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: FractionallySizedBox(
                      widthFactor: most <= 0 ? 0 : ((double.tryParse(row.amount) ?? 0) / most).clamp(0.0, 1.0),
                      child: Container(
                        height: 8,
                        decoration: BoxDecoration(color: scheme.primary, borderRadius: BorderRadius.circular(4)),
                      ),
                    ),
                  ),
                ),
                SizedBox(
                  width: 96,
                  child: Text(
                    dollars(row.amount),
                    textAlign: TextAlign.end,
                    style: const TextStyle(fontFeatures: PosTheme.tabular),
                  ),
                ),
              ],
            ),
          ),
      ],
      const Divider(height: 28),
      _Heading('Came off the checks', '', key: const ValueKey('day-off')),
      if (!cameOff) const Text('No comp, no discount and no void.'),
      for (final row in report.discounts)
        _Line(key: ValueKey('day-discount:${row.name}'), row.name, dollars('-${row.amount}'), count: '${row.count}×'),
      if (report.voids.count > 0)
        _Line(
          'Voided after sending',
          dollars(report.voids.amount),
          count: '${report.voids.count}×',
          key: const ValueKey('day-voids'),
        ),
      if (report.takenOff.count > 0)
        _Line(
          'Taken off before sending',
          dollars(report.takenOff.amount),
          count: '${report.takenOff.count}×',
          key: const ValueKey('day-taken-off'),
        ),
      if (report.voidedChecks.count > 0)
        _Line(
          'Checks voided whole',
          dollars(report.voidedChecks.amount),
          count: '${report.voidedChecks.count}×',
          key: const ValueKey('day-voided-checks'),
        ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton(
          key: const ValueKey('day-adjustments'),
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => AdjustmentsScreen(api: widget.api, token: widget.token),
            ),
          ),
          child: const Text('Each one, with who and why'),
        ),
      ),
      if (report.exempt.count > 0) ...[
        const Divider(height: 28),
        _Heading('Tax exempt', dollars(report.exempt.sales), key: const ValueKey('day-exempt')),
        Text(
          'Checks a manager marked exempt from sales tax. Their sales are in the figures above; '
          'only the tax was not charged.',
          style: small,
        ),
        _Line('Tax not charged', dollars(report.exempt.tax), key: const ValueKey('day-exempt-tax')),
        for (final row in report.exempt.checks)
          _Line(
            key: ValueKey('day-exempt:${row.check.orderId}'),
            row.organisation,
            dollars(row.check.total),
            under: [
              row.check.where,
              if (row.certificate.isNotEmpty) 'Certificate ${row.certificate}',
              if (row.approvedBy.isNotEmpty) 'approved by ${row.approvedBy}',
            ].join(' · '),
          ),
      ],
      if (report.typed.count > 0 || report.later.count > 0 || clock != null) ...[
        const Divider(height: 28),
        _Heading('Also', '', key: const ValueKey('day-also')),
        if (report.typed.count > 0)
          _Line(
            'Typed prices',
            dollars(report.typed.amount),
            count: '${report.typed.count}×',
            under: 'Off-menu dishes and market prices, in the sales above',
            key: const ValueKey('day-typed'),
          ),
        if (report.later.count > 0)
          _Line(
            'Rung for another day',
            dollars(report.later.amount),
            count: '${report.later.count}×',
            under: "Not in this day's sales: they count on the day they are for",
            key: const ValueKey('day-later'),
          ),
        if (clock != null)
          InkWell(
            key: const ValueKey('day-hours'),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) =>
                    TimeClockScreen(api: widget.api, token: widget.token, device: widget.device, now: widget.now),
              ),
            ),
            child: _Line(
              'Hours worked',
              hoursMinutes(clock.workedMs),
              under: '${clock.people} ${clock.people == 1 ? 'person' : 'people'} · open the hours',
            ),
          ),
      ],
    ];
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
              Text(_error!, key: const ValueKey('day-error'), textAlign: TextAlign.center),
              const SizedBox(height: 12),
              OutlinedButton(onPressed: _load, child: const Text('Try again')),
            ],
          ),
        ),
      );
    } else if (report == null) {
      body = const Center(child: CircularProgressIndicator());
    } else {
      body = ListView(
        key: const ValueKey('day-list'),
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: _body(context, report),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('The day'),
        actions: [
          IconButton(
            key: const ValueKey('day-print'),
            tooltip: 'Print it where the bills print',
            icon: const Icon(Icons.print_outlined),
            onPressed: report == null || _printing ? null : _print,
          ),
          IconButton(
            key: const ValueKey('day-refresh'),
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
                      ChoiceChip(
                        key: const ValueKey('day:today'),
                        label: const Text('Today'),
                        selected: _which == _Which.today,
                        onSelected: (_) => _pick(_Which.today),
                      ),
                      ChoiceChip(
                        key: const ValueKey('day:yesterday'),
                        label: const Text('Yesterday'),
                        selected: _which == _Which.yesterday,
                        onSelected: (_) => _pick(_Which.yesterday),
                      ),
                      ChoiceChip(
                        key: const ValueKey('day:other'),
                        avatar: const Icon(Icons.calendar_month_outlined, size: 18),
                        label: Text(
                          _which == _Which.other && _other != null
                              ? MaterialLocalizations.of(context).formatShortMonthDay(_other!)
                              : 'Another day',
                        ),
                        selected: _which == _Which.other,
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
/// words when there is more to say.
class _Line extends StatelessWidget {
  const _Line(
    this.words,
    this.amount, {
    super.key,
    this.under = '',
    this.count = '',
    this.strong = false,
    this.faint = false,
    this.warn = false,
  });

  final String words;
  final String amount;
  final String under;
  final String count;
  final bool strong;
  final bool faint;
  final bool warn;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final small = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final color = warn
        ? scheme.error
        : faint
        ? scheme.onSurfaceVariant
        : null;
    final style = TextStyle(fontWeight: strong ? FontWeight.w700 : null, color: color);
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
                if (under.isNotEmpty) Text(under, style: small),
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
