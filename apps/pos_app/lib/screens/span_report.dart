import 'package:flutter/material.dart';

import '../api.dart';
import '../sales_report.dart';
import 'theme.dart';

/// What the reports over a span of days share (Sales, Dishes sold): the buttons that pick the days, the
/// calendar for other days, the lines that name the days and the days they are held beside, what the
/// screen says while the hub adds up, or when it cannot, and the row every figure is written in. Each
/// widget's keys begin with the screen's own [prefix] ("sales", "dishes").

/// Asks which days to add up; null when the calendar was closed without any.
typedef PickSpan = Future<DateTimeRange?> Function(BuildContext context, DateTimeRange? from);

/// The device's own calendar.
Future<DateTimeRange?> deviceSpan(BuildContext context, DateTimeRange? from) {
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

/// Other days asked through [pickSpan]: null when none were picked, or more than [maxDays], which a snack
/// bar says (keyed "[prefix]-too-long").
Future<DateTimeRange?> askOtherDays(
  BuildContext context,
  PickSpan pickSpan,
  DateTimeRange? from, {
  required int maxDays,
  required String prefix,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final picked = await pickSpan(context, from);
  if (picked == null) return null;
  final days = calendarDays(picked.start, picked.end);
  if (days > maxDays) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          key: ValueKey('$prefix-too-long'),
          content: Text('At most $maxDays days at a time: that was $days. Pick fewer days.'),
        ),
      );
    return null;
  }
  return picked;
}

/// "Mon, Nov 9 to Sun, Nov 15, 2026", or the whole date of a single day.
String spanDays(BuildContext context, DateTime first, DateTime last, {bool whole = true}) {
  final local = MaterialLocalizations.of(context);
  if (DateUtils.isSameDay(first, last)) return whole ? local.formatFullDate(first) : local.formatMediumDate(first);
  final year = whole ? ', ${last.year}' : '';
  return '${local.formatMediumDate(first)} to ${local.formatMediumDate(last)}$year';
}

/// What to say when the hub did not give a report; [what] names it ("the sales report").
String reportError(ApiException err, String what) => switch (err.status) {
  401 || 403 => "The manager's hour here is over: go back and open Location again.",
  404 => 'This hub is older than $what. Update the hub to see it here.',
  null => 'The hub is not answering',
  _ => (err.detail?['message'] as String?) ?? err.message,
};

/// Today, Yesterday, 7 days, 4 weeks, and other days from the calendar.
class SpanChips extends StatelessWidget {
  const SpanChips({
    super.key,
    required this.prefix,
    required this.choice,
    required this.other,
    required this.onPick,
    required this.onOther,
  });

  final String prefix;
  final SalesChoice choice;

  /// The days last picked on the calendar.
  final DateTimeRange? other;
  final ValueChanged<SalesChoice> onPick;
  final VoidCallback onOther;

  String _otherLabel(BuildContext context) {
    final other = this.other;
    if (choice != SalesChoice.other || other == null) return 'Other days';
    final local = MaterialLocalizations.of(context);
    final first = local.formatShortMonthDay(other.start);
    return DateUtils.isSameDay(other.start, other.end) ? first : '$first to ${local.formatShortMonthDay(other.end)}';
  }

  @override
  Widget build(BuildContext context) {
    Widget chip(SalesChoice one, String key, String label) => ChoiceChip(
      key: ValueKey('$prefix:$key'),
      label: Text(label),
      selected: choice == one,
      onSelected: (_) => onPick(one),
    );
    return Padding(
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
              key: ValueKey('$prefix:other'),
              avatar: const Icon(Icons.date_range_outlined, size: 18),
              label: Text(_otherLabel(context)),
              selected: choice == SalesChoice.other,
              onSelected: (_) => onOther(),
            ),
          ],
        ),
      ),
    );
  }
}

/// The lines that head a report: its days, the days it is held beside, and that a day is still running.
class SpanHeading extends StatelessWidget {
  const SpanHeading({
    super.key,
    required this.prefix,
    required this.first,
    required this.last,
    required this.beforeFirst,
    required this.beforeLast,
    required this.running,
    required this.nowMs,
  });

  final String prefix;
  final DateTime first;
  final DateTime last;
  final DateTime beforeFirst;
  final DateTime beforeLast;
  final bool running;
  final int nowMs;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final days = calendarDays(first, last);
    final many = days > 1;
    final weeks = (days + 6) ~/ 7;
    final read = TimeOfDay.fromDateTime(DateTime.fromMillisecondsSinceEpoch(nowMs)).format(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(spanDays(context, first, last), key: ValueKey('$prefix-days'), style: theme.textTheme.titleMedium),
        Text(
          'Beside the same ${many ? 'days' : 'day'} ${weeks == 1 ? 'a week' : '$weeks weeks'} before: '
          '${spanDays(context, beforeFirst, beforeLast, whole: false)}.',
          key: ValueKey('$prefix-beside'),
          style: small,
        ),
        if (running)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              '${many ? 'The last day' : 'The day'} is still running: read at $read. '
              'Its figures will still move.',
              key: ValueKey('$prefix-running'),
              style: small,
            ),
          ),
      ],
    );
  }
}

/// While the hub adds up; [many] days can take it some seconds the first time.
class SpanReading extends StatelessWidget {
  const SpanReading({super.key, required this.prefix, required this.many});

  final String prefix;
  final bool many;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        key: ValueKey('$prefix-reading'),
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          const Text('Adding up the days'),
          if (many)
            Text(
              'Many days can take some seconds the first time.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
        ],
      ),
    ),
  );
}

/// The hub gave no report: why, and a way to ask again.
class SpanError extends StatelessWidget {
  const SpanError({super.key, required this.prefix, required this.message, required this.onRetry});

  final String prefix;
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(message, key: ValueKey('$prefix-error'), textAlign: TextAlign.center),
          const SizedBox(height: 12),
          OutlinedButton(onPressed: onRetry, child: const Text('Try again')),
        ],
      ),
    ),
  );
}

/// One row: words, how many when that is known, and an amount at the right edge; a quieter line under the
/// words for the figure before, ending with how far the two are apart ([change]). Where more is better
/// ([judged]), "up" is green and "down" red; the words say which either way.
class ReportLine extends StatelessWidget {
  const ReportLine(
    this.words,
    this.amount, {
    super.key,
    this.under = '',
    this.count = '',
    this.change,
    this.judged = true,
    this.strong = false,
    this.underWide = false,
  });

  final String words;
  final String amount;
  final String under;
  final String count;
  final Change? change;
  final bool judged;
  final bool strong;

  /// The quieter line runs under the figures too, the whole width of the row: for a line too long to stand
  /// under the words alone.
  final bool underWide;

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
    final quieter = under.isEmpty && moved == null
        ? null
        : Text.rich(
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
          );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: LayoutBuilder(
        builder: (context, box) {
          final line = Row(
            // the count and the amount sit on the line of the words, not above a second line under them
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(words, style: style),
                    if (quieter != null && !underWide) quieter,
                  ],
                ),
              ),
              // The figures never crowd the words out: where very long ones meet a very narrow row, they
              // are written smaller instead of running off the screen.
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: box.maxWidth > _wordsAtLeast ? box.maxWidth - _wordsAtLeast : 0),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
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
                ),
              ),
            ],
          );
          if (quieter == null || !underWide) return line;
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [line, quieter]);
        },
      ),
    );
  }

  /// The room the words keep, whatever the figures.
  static const _wordsAtLeast = 96.0;
}
