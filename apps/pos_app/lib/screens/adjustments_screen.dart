import 'package:flutter/material.dart';

import '../api.dart';
import '../voids.dart';
import 'theme.dart';

/// What came off the checks and why, for a manager: the dishes voided after the kitchen had them, and the
/// comps and discounts, each added up by reason, by who did it and by the manager who approved it, with
/// every void listed under them; and between the two, the dishes taken off before the kitchen saw them,
/// by who took them off and by check, the one longest on its check first. For today, the last 7 days or the
/// last 30. One column, so it reads the same on a phone.
class AdjustmentsScreen extends StatefulWidget {
  const AdjustmentsScreen({super.key, required this.api, this.now = DateTime.now});

  final PosApi api;

  /// The time on this device, to count the days back from.
  final DateTime Function() now;

  @override
  State<AdjustmentsScreen> createState() => _AdjustmentsScreenState();
}

class _AdjustmentsScreenState extends State<AdjustmentsScreen> {
  static const _spans = {0: 'Today', 7: '7 days', 30: '30 days'};

  int _days = 0;
  AdjustmentsReport? _report;
  String? _error;
  int _asked = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// From midnight today, or that many days before it.
  int get _sinceMs {
    final now = widget.now();
    return DateTime(now.year, now.month, now.day).subtract(Duration(days: _days)).millisecondsSinceEpoch;
  }

  Future<void> _load() async {
    final ask = ++_asked;
    setState(() => _error = null);
    try {
      final report = await widget.api.adjustmentsReport(sinceMs: _sinceMs);
      if (mounted && ask == _asked) setState(() => _report = report);
    } on ApiException catch (err) {
      if (mounted && ask == _asked) setState(() => _error = err.message);
    }
  }

  void _span(int days) {
    setState(() {
      _days = days;
      _report = null;
    });
    _load();
  }

  String _when(int atMs) {
    final at = DateTime.fromMillisecondsSinceEpoch(atMs);
    final time = TimeOfDay.fromDateTime(at).format(context);
    return _days == 0 ? time : '${MaterialLocalizations.of(context).formatShortMonthDay(at)} $time';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final report = _report;
    final Widget body;
    if (_error != null) {
      body = Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Could not read the report: $_error'),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: _load, child: const Text('Try again')),
          ],
        ),
      );
    } else if (report == null) {
      body = const Center(child: CircularProgressIndicator());
    } else {
      body = ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: [
          _Heading('Voids', report.voidTotal, '${report.voids.length} ${report.voids.length == 1 ? 'dish' : 'dishes'}'),
          if (!report.hasVoids)
            const Text('This hub is older than the void report. Update the hub to see voids here.')
          else if (report.voids.isEmpty)
            const Text('No dish was voided after it went to the kitchen.')
          else ...[
            _Totals('By reason', report.voidsByReason, blank: 'No reason given'),
            _Totals('By who voided', report.voidsByStaff, blank: 'Not recorded'),
            _Totals('By manager', report.voidsByApprover, blank: 'No manager'),
            const SizedBox(height: 6),
            Text('Each void', style: theme.textTheme.labelLarge?.copyWith(color: scheme.primary)),
            for (final (i, v) in report.voids.indexed)
              ListTile(
                key: ValueKey('void-row:$i'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text('${v.qty} × ${v.item}'),
                subtitle: Text(
                  [
                    _when(v.atMs),
                    if (v.where.isNotEmpty) v.where,
                    v.reason.isEmpty ? 'No reason given' : v.reason,
                    if (v.by.isNotEmpty) 'by ${v.by}',
                    if (v.approvedBy.isNotEmpty) '${v.approvedBy} approved',
                  ].join(' · '),
                ),
                trailing: Text('\$${v.amount}', style: const TextStyle(fontFeatures: PosTheme.tabular)),
              ),
          ],
          const Divider(height: 28),
          _Heading(
            'Taken off before sending',
            report.takenOffTotal,
            '${report.takenOffDishes} ${report.takenOffDishes == 1 ? 'dish' : 'dishes'}',
          ),
          if (!report.hasTakenOff)
            const Text('This hub is older than this list. Update the hub to see it here.')
          else if (report.takenOff.isEmpty)
            const Text('No dish was taken off a check before it was sent.')
          else ...[
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(
                'Rung in and taken off again before the kitchen saw them. Nothing printed, so no other '
                'report shows them. A dish changed for another is not counted.',
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
            _Totals('By who took it off', report.takenOffByStaff, blank: 'Not recorded'),
            _Totals('By check', report.takenOffByCheck, blank: 'No table or number'),
            const SizedBox(height: 6),
            Text(
              'Each one, longest on the check first',
              style: theme.textTheme.labelLarge?.copyWith(color: scheme.primary),
            ),
            for (final (i, t) in report.takenOffLongestFirst.indexed)
              ListTile(
                key: ValueKey('taken-off-row:$i'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text('${t.qty} × ${t.item}'),
                subtitle: Text(
                  [_when(t.atMs), if (t.where.isNotEmpty) t.where, if (t.who.isNotEmpty) t.who, t.onCheck].join(' · '),
                ),
                trailing: Text('\$${t.amount}', style: const TextStyle(fontFeatures: PosTheme.tabular)),
              ),
          ],
          const Divider(height: 28),
          _Heading(
            'Comps and discounts',
            report.discountTotal,
            '${report.discounts.length} on ${report.discounts.length == 1 ? 'a check' : 'checks'}',
          ),
          if (report.discounts.isEmpty)
            const Text('No comp or discount is on a check.')
          else ...[
            _Totals('By reason', report.discountsByReason, blank: 'No reason given', name: report.discountReason),
            _Totals('By who put it on', report.discountsByStaff, blank: 'Not recorded'),
            _Totals('By manager', report.discountsByApprover, blank: 'No manager'),
          ],
        ],
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Voids and comps'),
        actions: [IconButton(tooltip: 'Read again', icon: const Icon(Icons.refresh), onPressed: _load)],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
                child: Wrap(
                  spacing: 8,
                  children: [
                    for (final MapEntry(key: days, value: label) in _spans.entries)
                      ChoiceChip(
                        key: ValueKey('report-days:$days'),
                        label: Text(label),
                        selected: _days == days,
                        onSelected: (_) => _span(days),
                      ),
                  ],
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
  const _Heading(this.title, this.amount, this.count);

  final String title;
  final String amount;
  final String count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(child: Text(title, style: theme.textTheme.titleLarge)),
          Text(count, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(width: 10),
          // nothing at all comes from the hub as a bare 0
          Text(
            '\$${amount.contains('.') ? amount : '$amount.00'}',
            style: theme.textTheme.titleLarge?.copyWith(fontFeatures: PosTheme.tabular),
          ),
        ],
      ),
    );
  }
}

/// One way of adding the section up: a line per reason or person, how many times and what it came to.
class _Totals extends StatelessWidget {
  const _Totals(this.title, this.rows, {required this.blank, this.name});

  final String title;
  final List<ReportTotal> rows;

  /// What a line with no name is called (a void with no reason, nobody recorded).
  final String blank;

  /// A name for a key that is not one itself (a discount reason's code).
  final String Function(String key)? name;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.labelLarge?.copyWith(color: scheme.primary)),
          for (final row in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Expanded(child: Text(row.key.isEmpty ? blank : (name?.call(row.key) ?? row.key))),
                  if (row.count != null)
                    Text('${row.count}×', style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                  SizedBox(
                    width: 84,
                    child: Text(
                      '\$${row.amount}',
                      textAlign: TextAlign.end,
                      style: const TextStyle(fontFeatures: PosTheme.tabular),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
