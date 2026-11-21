import 'package:flutter/material.dart';

import '../api.dart';
import '../day_report.dart' show dollars;
import '../sales_report.dart';
import '../suggestions_report.dart';
import 'span_report.dart';

/// Suggestions taken over any days, for a manager (docs/goes-with.md, "Suggestions taken"): how many dishes
/// were added from the tray "Goes with ..." on the order screen and for how much, who added them, and under
/// which dish, each with how many of that dish went out. A dish that suggests something and went out with
/// nothing added is listed too, after the others. The hub does every sum and puts every list in its order;
/// this only says them.
///
/// It reads the sales and changes none: a suggested dish is a sale like any other.
class SuggestionsScreen extends StatefulWidget {
  const SuggestionsScreen({
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
  State<SuggestionsScreen> createState() => _SuggestionsScreenState();
}

class _SuggestionsScreenState extends State<SuggestionsScreen> {
  SalesChoice _choice = SalesChoice.week;
  DateTimeRange? _other;
  SuggestionsReport? _report;
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
      final report = await widget.api.suggestionsReport(widget.token, from: from, to: to);
      if (!mounted || ask != _asked) return;
      setState(() {
        _report = report;
        _maxDays = report.maxDays;
      });
    } on ApiException catch (err) {
      if (!mounted || ask != _asked) return;
      setState(() => _error = reportError(err, 'the report of suggestions taken'));
    }
  }

  /// Other days: a new report, read from its top.
  void _pick(SalesChoice choice) {
    if (_scroll.hasClients) _scroll.jumpTo(0);
    setState(() {
      _choice = choice;
      _report = null;
    });
    _load();
  }

  Future<void> _pickOther() async {
    final picked = await askOtherDays(context, widget.pickSpan, _other, maxDays: _maxDays, prefix: 'suggestions');
    if (picked == null || !mounted) return;
    _other = picked;
    _pick(SalesChoice.other);
  }

  /// The rows of the report, top to bottom: the list builds only the ones near the screen.
  List<Widget> _rows(BuildContext context, SuggestionsReport report) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final small = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    Widget heading(String key, String words, String under) => Padding(
      key: ValueKey(key),
      padding: const EdgeInsets.only(top: 18, bottom: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(words, style: theme.textTheme.titleSmall?.copyWith(color: scheme.primary)),
          Text(under, style: small),
        ],
      ),
    );
    final read = TimeOfDay.fromDateTime(DateTime.fromMillisecondsSinceEpoch(report.nowMs)).format(context);
    final many = calendarDays(report.first, report.last) > 1;
    final took = report.took, nothing = report.tookNothing;
    return [
      Text(
        spanDays(context, report.first, report.last),
        key: const ValueKey('suggestions-days'),
        style: theme.textTheme.titleMedium,
      ),
      if (report.running)
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(
            '${many ? 'The last day' : 'The day'} is still running: read at $read. Its figures will still move.',
            key: const ValueKey('suggestions-running'),
            style: small,
          ),
        ),
      const SizedBox(height: 6),
      ReportLine(
        key: const ValueKey('suggestions-total'),
        'Suggested dishes added',
        manyWords(report.taken),
        strong: true,
      ),
      ReportLine(key: const ValueKey('suggestions-money'), 'They were sold for', dollars(report.amount), strong: true),
      if (report.dishes.isEmpty && report.staff.isEmpty)
        Padding(
          key: const ValueKey('suggestions-none'),
          padding: const EdgeInsets.symmetric(vertical: 20),
          child: const Text(
            'Nothing was added from "Goes with" in these days, and no dish that suggests something was sold. '
            'A manager says what goes with a dish in the menu editor, on the dish.',
            textAlign: TextAlign.center,
          ),
        ),
      if (report.staff.isNotEmpty) ...[
        heading('suggestions-by-staff', 'Who added them', 'Whoever rang the suggested dish in, the most first.'),
        for (final person in report.staff)
          ReportLine(
            key: ValueKey('suggestion-staff:${person.staffId ?? person.name}'),
            person.called,
            dollars(person.amount),
            count: '${manyWords(person.taken)}×',
          ),
      ],
      if (took.isNotEmpty) ...[
        heading('suggestions-by-dish', 'With which dish', 'Under each dish, what was added from its suggestions.'),
        for (final dish in took) ...[
          const Divider(height: 9),
          ReportLine(
            key: ValueKey('suggestion-dish:${dish.item}'),
            dish.name,
            dollars(dish.amount),
            count: '${manyWords(dish.taken)}×',
            under: dish.words,
            strong: true,
          ),
          for (final added in dish.added)
            Padding(
              padding: const EdgeInsets.only(left: 16),
              child: ReportLine(
                key: ValueKey('suggestion-added:${dish.item}:${added.item}'),
                added.name,
                // suggested with it today, and nobody took it in these days
                added.taken == 0 ? 'none' : dollars(added.amount),
                count: added.taken == 0 ? '' : '${manyWords(added.taken)}×',
              ),
            ),
        ],
      ],
      if (nothing.isNotEmpty) ...[
        heading(
          'suggestions-nothing',
          'Sold with nothing added',
          'They suggest something today, and nobody added it in these days.',
        ),
        for (final dish in nothing)
          ReportLine(
            key: ValueKey('suggestion-dish:${dish.item}'),
            dish.name,
            '${manyWords(dish.sold)} sold',
            under: dish.added.isEmpty ? '' : 'Suggests ${dish.added.map((added) => added.name).join(', ')}',
          ),
      ],
      Padding(
        padding: const EdgeInsets.only(top: 16),
        child: Text(
          'A dish counts here when it was added from the tray "Goes with" on the order screen, at its menu '
          'price, on the day of its check. The same dish rung from the menu is not counted, and neither is one '
          'voided or taken off. "Sold" is how many of the dish went out in these days on every kind of order, '
          'online ones too, where nothing is suggested. More than one dish can be added with one, so more can '
          'be added than were sold. Counting starts the day the hub and the apps were updated: nothing was '
          'marked before. A day runs from 4 AM to 4 AM.',
          key: const ValueKey('suggestions-note'),
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
      body = SpanError(prefix: 'suggestions', message: _error!, onRetry: _load);
    } else if (report == null) {
      body = SpanReading(prefix: 'suggestions', many: _choice == SalesChoice.fourWeeks || _choice == SalesChoice.other);
    } else {
      final rows = _rows(context, report);
      body = ListView.builder(
        key: const ValueKey('suggestions-list'),
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        itemCount: rows.length,
        itemBuilder: (context, index) => rows[index],
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Suggestions taken'),
        actions: [
          IconButton(
            key: const ValueKey('suggestions-refresh'),
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
              SpanChips(prefix: 'suggestions', choice: _choice, other: _other, onPick: _pick, onOther: _pickOther),
              Expanded(child: body),
            ],
          ),
        ),
      ),
    );
  }
}
