import 'package:flutter/material.dart';

import '../api.dart';
import '../day_report.dart' show dollars;
import '../sales_report.dart';
import '../waste.dart';
import 'span_report.dart';
import 'theme.dart';
import 'waste_dialog.dart';

/// The waste log (docs/waste-log.md): what the kitchen made or bought and did not sell. Anybody signed in
/// writes an entry and reads today's; whoever wrote one strikes it out, the same day. Opened by a manager
/// from Location (with their [token]) it also adds the days up, by reason, by dish and by day, and strikes
/// any entry. It stands beside the sales: nothing here is a check, a void or a comp.
class WasteScreen extends StatefulWidget {
  const WasteScreen({
    super.key,
    required this.api,
    required this.staffId,
    this.device,
    this.token,
    this.now = DateTime.now,
    this.pickSpan = deviceSpan,
  });

  final PosApi api;

  /// Who is signed in at this screen: who an entry written here is by.
  final String staffId;
  final String? device;

  /// A manager's session (`POST /admin/session`), when the screen was opened from Location.
  final String? token;

  /// The time on this device: which day yesterday was.
  final DateTime Function() now;
  final PickSpan pickSpan;

  @override
  State<WasteScreen> createState() => _WasteScreenState();
}

class _WasteScreenState extends State<WasteScreen> {
  WasteDay? _day;
  String? _error;
  bool _older = false; // the hub does not know the waste log

  /// The day whose entries a manager reads ("2026-11-15"); null is the day that is running. Everybody
  /// else reads that one only.
  String? _logDay;
  String? _today; // the day that is running, as the hub names it
  int _askedDay = 0;

  late bool _totals = widget.token != null; // a manager comes from Location to read the totals
  SalesChoice _choice = SalesChoice.week;
  DateTimeRange? _other;
  WasteReport? _report;
  String? _reportError;
  int _asked = 0;
  int _maxDays = 92;

  @override
  void initState() {
    super.initState();
    _load();
    if (widget.token != null) _loadReport();
  }

  Future<void> _load() async {
    final ask = ++_askedDay;
    setState(() => _error = null);
    try {
      final day = await widget.api.wasteDay(day: _logDay);
      if (!mounted || ask != _askedDay) return;
      setState(() {
        _day = day;
        if (day.today) _today = day.day;
      });
    } on ApiException catch (err) {
      if (!mounted || ask != _askedDay) return;
      setState(() {
        _older = err.status == 404;
        _error = switch (err.status) {
          404 => 'This hub is older than the waste log. Update the hub to use it.',
          null => 'The hub is not answering. The waste log is kept on the hub.',
          _ => err.detail?['message'] as String? ?? err.message,
        };
      });
    }
  }

  Future<void> _loadReport() async {
    final token = widget.token;
    if (token == null) return;
    final ask = ++_asked;
    setState(() => _reportError = null);
    final (from, to) = spanOf(_choice, widget.now(), first: _other?.start, last: _other?.end);
    try {
      final report = await widget.api.wasteReport(token, from: from, to: to);
      if (!mounted || ask != _asked) return;
      setState(() {
        _report = report;
        _maxDays = report.maxDays;
      });
    } on ApiException catch (err) {
      if (!mounted || ask != _asked) return;
      setState(() => _reportError = reportError(err, 'the waste log'));
    }
  }

  /// A manager reads another day's entries: one of the totals' days, or the day before or after.
  void _showDay(String day) {
    setState(() {
      _logDay = day == _today ? null : day;
      _day = null;
      _totals = false;
    });
    _load();
  }

  void _stepDay(int by) {
    final shown = DateTime.tryParse(_day?.day ?? '');
    if (shown != null) _showDay(isoDay(DateTime(shown.year, shown.month, shown.day + by)));
  }

  void _pick(SalesChoice choice) {
    setState(() {
      _choice = choice;
      _report = null;
    });
    _loadReport();
  }

  Future<void> _pickOther() async {
    final picked = await askOtherDays(context, widget.pickSpan, _other, maxDays: _maxDays, prefix: 'waste');
    if (picked == null || !mounted) return;
    _other = picked;
    _pick(SalesChoice.other);
  }

  Future<void> _write() async {
    final day = _day;
    if (day == null) return;
    final written = await showDialog<WasteEntry>(
      context: context,
      builder: (_) => WasteDialog(api: widget.api, staffId: widget.staffId, day: day, device: widget.device),
    );
    if (written == null || !mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('Written down: ${written.qty} × ${written.name}')));
    await _load();
    if (widget.token != null) await _loadReport();
  }

  /// Whether the person at this screen may strike this entry out: a manager any, the others their own of
  /// the day that is running.
  bool _mayStrike(WasteEntry entry, WasteDay day) =>
      !entry.struck && (widget.token != null || (day.today && entry.byId == widget.staffId));

  Future<void> _strike(WasteEntry entry) async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Strike this out?'),
        content: Text(
          '${entry.qty} × ${entry.name}, ${entry.reason}.\n\n'
          'It stays in the log, struck out, and is counted in no total.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Keep it')),
          FilledButton(
            key: const ValueKey('waste-strike-yes'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Strike out'),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await widget.api.strikeWaste(entry.id, staffId: widget.staffId, token: widget.token);
    } on ApiException catch (err) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            key: const ValueKey('waste-strike-problem'),
            content: Text(
              err.status == null
                  ? 'The hub is not answering, so it was not struck out.'
                  : err.detail?['message'] as String? ?? err.message,
            ),
          ),
        );
    }
    if (!mounted) return;
    await _load();
    if (widget.token != null) await _loadReport();
  }

  static String _time(BuildContext context, int atMs) =>
      TimeOfDay.fromDateTime(DateTime.fromMillisecondsSinceEpoch(atMs)).format(context);

  Widget _entry(BuildContext context, WasteEntry entry, WasteDay day) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final small = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final struck = entry.struck;
    final faded = struck ? scheme.onSurfaceVariant : null;
    final value = entry.value;
    return Padding(
      key: ValueKey('waste-entry:${entry.id}'),
      padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            constraints: const BoxConstraints(minWidth: 40),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: scheme.outlineVariant),
            ),
            child: Text(
              '${entry.qty}×',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleSmall?.copyWith(color: faded, fontFeatures: PosTheme.tabular),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.name,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: faded,
                    decoration: struck ? TextDecoration.lineThrough : null,
                  ),
                ),
                Text('${entry.reason} · ${entry.by} · ${_time(context, entry.atMs)}', style: small),
                if (entry.note.isNotEmpty) Text(entry.note, style: theme.textTheme.bodySmall?.copyWith(color: faded)),
                if (struck)
                  Text(
                    'Struck out by ${entry.struckBy}, ${_time(context, entry.struckMs!)}. Not counted.',
                    key: ValueKey('waste-struck:${entry.id}'),
                    style: small,
                  ),
              ],
            ),
          ),
          if (value != null)
            Padding(
              padding: const EdgeInsets.only(left: 8, top: 2),
              child: Text(
                dollars(value),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: faded,
                  fontFeatures: PosTheme.tabular,
                  decoration: struck ? TextDecoration.lineThrough : null,
                ),
              ),
            ),
          if (_mayStrike(entry, day))
            IconButton(
              key: ValueKey('waste-strike:${entry.id}'),
              tooltip: 'Strike out',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.format_strikethrough),
              onPressed: () => _strike(entry),
            )
          else
            const SizedBox(width: 8),
        ],
      ),
    );
  }

  Widget _log(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final day = _day;
    if (day == null) {
      final error = _error;
      if (error == null) return const Center(child: CircularProgressIndicator());
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(error, key: const ValueKey('waste-error'), textAlign: TextAlign.center),
              if (!_older) ...[
                const SizedBox(height: 12),
                OutlinedButton(onPressed: _load, child: const Text('Try again')),
              ],
            ],
          ),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        key: const ValueKey('waste-list'),
        padding: const EdgeInsets.only(bottom: 96), // the button stands over the end of the list
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(16, 12, widget.token == null ? 16 : 4, 4),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        day.today ? 'Today' : _dayName(context, day.day),
                        key: const ValueKey('waste-day'),
                        style: theme.textTheme.titleMedium,
                      ),
                      Text(
                        wasteSummary(day.total),
                        key: const ValueKey('waste-today'),
                        style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                // a manager reads the days before too: a mistake found the next morning is struck out there
                if (widget.token != null) ...[
                  IconButton(
                    key: const ValueKey('waste-day-back'),
                    tooltip: 'The day before',
                    icon: const Icon(Icons.chevron_left),
                    onPressed: () => _stepDay(-1),
                  ),
                  IconButton(
                    key: const ValueKey('waste-day-next'),
                    tooltip: 'The day after',
                    icon: const Icon(Icons.chevron_right),
                    onPressed: day.today ? null : () => _stepDay(1),
                  ),
                ],
              ],
            ),
          ),
          if (day.entries.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
              child: Text(
                day.today
                    ? 'What is dropped, burnt, made wrong or thrown out is written down here, with why. '
                          'It is not a sale and changes no check.'
                    : 'Nothing was written down that day.',
                key: const ValueKey('waste-empty'),
                style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
          for (final entry in day.entries) ...[_entry(context, entry, day), const Divider(height: 1, indent: 12)],
        ],
      ),
    );
  }

  static String _dayName(BuildContext context, String day) {
    final date = DateTime.tryParse(day);
    return date == null ? day : MaterialLocalizations.of(context).formatMediumDate(date);
  }

  Widget _rows(BuildContext context, String key, String title, List<WasteRow> rows, {bool days = false}) {
    final theme = Theme.of(context);
    Widget line(WasteRow row, Widget child) =>
        !days ? child : InkWell(key: ValueKey('waste-day:${row.name}'), onTap: () => _showDay(row.name), child: child);
    return Column(
      key: ValueKey('waste-by-$key'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 14, bottom: 2),
          child: Text(title, style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.primary)),
        ),
        if (days)
          Text(
            'A tap on a day opens its entries.',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        for (final row in rows)
          line(
            row,
            ReportLine(
              days ? _dayName(context, row.name) : row.name,
              // what has no price says so; a day with nothing says nothing
              row.total.count > 0 && row.total.count == row.total.unpriced
                  ? 'no price'
                  : row.total.count == 0
                  ? ''
                  : dollars(row.total.value),
              count: row.total.count == 0 ? '' : '${row.total.count}×',
              under: row.total.unpriced > 0 && row.total.unpriced < row.total.count
                  ? '${row.total.unpriced} with no price'
                  : (days && row.total.count == 0 ? 'nothing' : ''),
            ),
          ),
      ],
    );
  }

  Widget _totalsView(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final small = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final report = _report;
    final error = _reportError;
    final (first, last) = spanOf(_choice, widget.now(), first: _other?.start, last: _other?.end);
    return Column(
      children: [
        SpanChips(prefix: 'waste', choice: _choice, other: _other, onPick: _pick, onOther: _pickOther),
        Expanded(
          child: error != null
              ? SpanError(prefix: 'waste', message: error, onRetry: _loadReport)
              : report == null
              ? SpanReading(prefix: 'waste', many: first != last)
              : ListView(
                  key: const ValueKey('waste-totals'),
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                  children: [
                    Text(
                      spanDays(context, DateTime.parse(report.from), DateTime.parse(report.to)),
                      key: const ValueKey('waste-days'),
                      style: theme.textTheme.titleMedium,
                    ),
                    Text(
                      wasteSummary(report.total),
                      key: const ValueKey('waste-total'),
                      style: theme.textTheme.bodyLarge,
                    ),
                    Text(
                      "The menu's prices, not what the food cost. Nothing here is in the sales or out of them."
                      '${report.struck > 0 ? ' ${report.struck} struck out, not counted.' : ''}',
                      key: const ValueKey('waste-about'),
                      style: small,
                    ),
                    if (report.total.count > 0) ...[
                      _rows(context, 'reason', 'By reason', report.reasons),
                      _rows(context, 'dish', 'By dish', report.dishes),
                      if (report.days.length > 1) _rows(context, 'day', 'By day', report.days, days: true),
                    ],
                  ],
                ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final manager = widget.token != null;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Waste'),
        bottom: manager
            ? PreferredSize(
                preferredSize: const Size.fromHeight(52),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: SegmentedButton<bool>(
                      key: const ValueKey('waste-view'),
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment(value: true, label: Text('Totals')),
                        ButtonSegment(value: false, label: Text('Entries')),
                      ],
                      selected: {_totals},
                      onSelectionChanged: (picked) => setState(() => _totals = picked.first),
                    ),
                  ),
                ),
              )
            : null,
      ),
      // the totals are read with nothing standing over their numbers, and an entry is written into the day
      // that is running: the button is with today's entries
      floatingActionButton: _day == null || !_day!.today || (manager && _totals)
          ? null
          : FloatingActionButton.extended(
              key: const ValueKey('waste-log'),
              onPressed: _write,
              icon: const Icon(Icons.add),
              label: const Text('Log waste'),
            ),
      // a tablet keeps the rows as wide as they read well
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: manager && _totals ? _totalsView(context) : _log(context),
          ),
        ),
      ),
    );
  }
}
