import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../day_report.dart';
import '../live.dart';
import '../menu.dart';
import '../takeout.dart';
import '../today.dart';
import 'adjustments_screen.dart';
import 'check_history_screen.dart';
import 'day_report_screen.dart';
import 'dish_finder.dart';
import 'menu_editor.dart' show ManagerPinDialog;
import 'menu_panel.dart' show EightySixDialog;
import 'rush.dart';
import 'sales_screen.dart';
import 'span_report.dart';
import 'theme.dart';

/// Today (docs/today.md): the night as it stands, on one screen made for a phone. What was sold so far and
/// whether that is ahead of or behind the same weekday a week ago at this time, the checks still open, what
/// came off, who is on the clock, what is sold out (and a way to 86 a dish from here), the kitchen rush, and
/// the night hour by hour beside last week's.
///
/// It is the reports' screen: opened with the PIN of somebody who may see the reports, and every figure is
/// the hub's. It reads again by itself, within some seconds of a change and every half minute, and never
/// more often than that.
class TodayScreen extends StatefulWidget {
  const TodayScreen({super.key, required this.api, required this.token, this.holds, this.by, this.device = ''});

  final PosApi api;

  /// The session of whoever opened it (`POST /admin/session`).
  final String token;

  /// What that person may do (docs/roles.md); null for everything: a manager, or a hub older than the table.
  final Set<String>? holds;

  /// Who is at the screen, by name: the 86 board says who took a dish off.
  final String? by;

  /// This terminal, for the PIN box when the session's hour is over.
  final String device;

  @override
  State<TodayScreen> createState() => _TodayScreenState();
}

class _TodayScreenState extends State<TodayScreen> {
  /// How many open checks are listed before "Show all".
  static const _listed = 5;

  late String _token = widget.token;
  late Set<String>? _holds = widget.holds;
  TodayReport? _report;
  List<BoardRow>? _board;
  Quotes? _quotes;
  String? _error; // nothing to show, and why
  String? _stopped; // the session reads no more (its hour is over, or the power was taken back): why
  bool _away = false; // no hub answers: the figures are the last ones read
  bool _older = false; // the hub that answers has no such report
  bool _allOpen = false;
  bool _busy = false; // a change to the board or the rush is on its way
  Timer? _timer;
  late final _reader = Paced(const Duration(seconds: 20), _read);
  StreamSubscription<LiveChange>? _live;

  @override
  void initState() {
    super.initState();
    // Every half minute by itself: the figure of a week ago moves with the clock even when nothing is rung.
    _timer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (_stopped != null || _older) return;
      unawaited(_reader.now(must: false));
      unawaited(_readBoard());
      unawaited(_readQuotes());
    });
    _live = widget.api.live.changes.listen((change) {
      if (_stopped != null || _older) return;
      if (change.anyOrder) _reader();
      if (change.menu || change.everything) unawaited(_readBoard());
      if (change.settings || change.everything) unawaited(_readQuotes());
    });
    unawaited(_reader.now());
    unawaited(_readBoard());
    unawaited(_readQuotes());
  }

  @override
  void dispose() {
    _timer?.cancel();
    unawaited(_live?.cancel());
    _reader.cancel();
    super.dispose();
  }

  bool _may(String power) => _holds == null || _holds!.contains(power);

  Future<void> _read() async {
    try {
      final report = await widget.api.today(_token);
      if (!mounted) return;
      setState(() {
        _report = report;
        _error = null;
        _away = false;
      });
    } on ApiException catch (err) {
      if (!mounted) return;
      setState(() {
        switch (err.status) {
          case 401:
            _stopped = 'The hour of this PIN is over.';
          case 403:
            _stopped = 'This PIN may no longer see the reports.';
          case 404:
            _older = true;
          case null:
            _away = true;
            if (_report == null) _error = 'The hub is not answering';
          default:
            if (_report == null) _error = (err.detail?['message'] as String?) ?? err.message;
        }
      });
    }
  }

  Future<void> _readBoard() async {
    try {
      final rows = await widget.api.board();
      if (mounted) setState(() => _board = rows);
    } on ApiException {
      // the board as last read stays
    }
  }

  Future<void> _readQuotes() async {
    try {
      final quotes = await widget.api.quotes();
      if (mounted && !identical(quotes, _quotes)) setState(() => _quotes = quotes);
    } on ApiException {
      // the quotes as last read stay
    }
  }

  /// The session's hour is over, or the power was taken back: another PIN, and the screen reads on with it.
  Future<void> _pinAgain() async {
    Set<String>? holds;
    final token = await showDialog<String>(
      context: context,
      builder: (_) => ManagerPinDialog(
        api: widget.api,
        device: widget.device,
        action: 'Open Today',
        what: "see today's figures",
        power: 'reports',
        onPowers: (powers) => holds = powers,
      ),
    );
    if (token == null || !mounted) return;
    setState(() {
      _token = token;
      _holds = holds;
      _stopped = null;
      _error = null;
    });
    unawaited(_reader.now());
  }

  void _say(String words, {Key? key}) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(key: key, content: Text(words)));
  }

  void _open(Widget screen) => Navigator.of(context).push(PosPageRoute<void>(builder: (_) => screen));

  /// A dish back on sale with no number: a sold-out dish comes back, a counted one is no longer counted.
  Future<void> _bringBack(BoardRow row) async {
    setState(() => _busy = true);
    try {
      await widget.api.set86(row.targetId, soldOut: false, by: widget.by);
      await _readBoard();
    } on ApiException catch (err) {
      if (mounted) _say('Could not bring it back: ${err.message}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 86 a dish from here: find it by name, then the same sheet a held dish opens on the order screen.
  Future<void> _eightySix() async {
    final entry = await showDialog<MenuEntry>(
      context: context,
      builder: (_) => DishFinderDialog(api: widget.api, title: '86 a dish'),
    );
    if (entry == null || !mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => EightySixDialog(api: widget.api, entry: entry, by: widget.by),
    );
    await _readBoard();
  }

  Future<void> _rush() async {
    final current = _quotes?.rushAt(DateTime.now()) ?? 0;
    final minutes = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => RushSheet(current: current),
    );
    if (minutes == null || minutes == current || !mounted) return;
    setState(() => _busy = true);
    try {
      final saved = await widget.api.saveRush(_token, minutes);
      if (!mounted) return;
      setState(() => _quotes = saved);
      _say(
        minutes == 0
            ? 'The rush is off. New orders get the usual quote.'
            : 'New to-go orders are quoted $minutes minutes longer on every screen, until closing.',
        key: const ValueKey('today-rush-said'),
      );
    } on ApiException catch (err) {
      if (!mounted) return;
      _say(switch (err.status) {
        401 => 'The hour of this PIN is over: type it again.',
        403 => 'Only ${widget.api.powers.value.whose('rush')} can add minutes to the quotes.',
        null => 'The hub is not answering: the rush is as it was.',
        _ => (err.detail?['message'] as String?) ?? err.message,
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _time(int ms) => TimeOfDay.fromDateTime(DateTime.fromMillisecondsSinceEpoch(ms)).format(context);

  @override
  Widget build(BuildContext context) {
    final report = _report;
    final Widget body;
    if (_older) {
      body = const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'This hub is older than Today. Update the hub to see it here.',
            key: ValueKey('today-older'),
            textAlign: TextAlign.center,
          ),
        ),
      );
    } else if (report == null && _stopped != null) {
      body = Center(
        child: Padding(padding: const EdgeInsets.all(24), child: _stoppedNote(context)),
      );
    } else if (report == null && _error != null) {
      body = SpanError(prefix: 'today', message: _error!, onRetry: () => unawaited(_reader.now()));
    } else if (report == null) {
      body = const Center(child: CircularProgressIndicator(key: ValueKey('today-reading')));
    } else {
      final list = LayoutBuilder(
        builder: (context, box) {
          final wide = box.maxWidth >= 840;
          final first = [_sales(context, report)];
          final rest = [
            _openChecks(context, report),
            _cameOff(context, report),
            if (report.day.clock != null) _onTheClock(context, report),
            _soldOut(context),
            _kitchen(context),
          ];
          final hours = report.hours.isEmpty ? null : _hours(context, report);
          return ListView(
            key: const ValueKey('today-list'),
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
            children: [
              // always the first of the list, also when the strip above says it instead: a list that loses
              // its first row while it is scrolled loses its place
              if (_stopped == null && !_away) _asOf(context, report) else const SizedBox.shrink(),
              if (wide)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: Column(children: [...first, ?hours])),
                    const SizedBox(width: 12),
                    Expanded(child: Column(children: rest)),
                  ],
                )
              else ...[
                ...first,
                ...rest,
                ?hours,
              ],
            ],
          );
        },
      );
      // What stands in the way of newer figures stays in sight however far the list is scrolled. The list
      // is the same one with and without it, so it stays where it was scrolled to.
      body = Column(
        children: [
          if (_stopped != null || _away) _standing(context, report),
          Expanded(key: const ValueKey('today-body'), child: list),
        ],
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Today'),
        actions: [
          IconButton(
            key: const ValueKey('today-refresh'),
            tooltip: 'Read again',
            icon: const Icon(Icons.refresh),
            onPressed: _stopped != null || _older
                ? null
                : () {
                    unawaited(_reader.now());
                    unawaited(_readBoard());
                    unawaited(_readQuotes());
                  },
          ),
        ],
      ),
      body: body,
    );
  }

  /// Why the screen reads no more, with the way to read on.
  Widget _stoppedNote(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(_stopped!, key: const ValueKey('today-stopped'), textAlign: TextAlign.center),
      const SizedBox(height: 8),
      FilledButton.tonal(key: const ValueKey('today-pin'), onPressed: _pinAgain, child: const Text('Type a PIN')),
    ],
  );

  /// The first line of the list: when the figures are from.
  Widget _asOf(BuildContext context, TodayReport report) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
      child: Text(
        'As of ${_time(report.nowMs)}. It reads again by itself.',
        key: const ValueKey('today-asof'),
        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
    );
  }

  /// A strip over the list that does not scroll away: the figures are old, and why. With the way to read on
  /// when it is the PIN that stands in the way, beside the words where there is room and under them on a
  /// phone.
  Widget _standing(BuildContext context, TodayReport report) {
    final scheme = Theme.of(context).colorScheme;
    final style = TextStyle(color: scheme.onErrorContainer);
    final at = _time(report.nowMs);
    return Material(
      key: const ValueKey('today-standing'),
      color: scheme.errorContainer,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
        child: _stopped == null
            ? Text(
                'The hub is not answering. These are the figures of $at.',
                key: const ValueKey('today-asof'),
                style: style,
              )
            : Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 12,
                runSpacing: 4,
                children: [
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_stopped!, key: const ValueKey('today-stopped'), style: style),
                      Text('These are the figures of $at.', style: style),
                    ],
                  ),
                  FilledButton(key: const ValueKey('today-pin'), onPressed: _pinAgain, child: const Text('Type a PIN')),
                ],
              ),
      ),
    );
  }

  /// One card of the screen. [foot] is the room under its last line: less under a button, which brings room
  /// of its own.
  Widget _card(String name, List<Widget> children, {double foot = 12}) => Card(
    key: ValueKey('today-$name'),
    margin: const EdgeInsets.only(bottom: 12),
    child: Padding(
      padding: EdgeInsets.fromLTRB(14, 12, 14, foot),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
    ),
  );

  Widget _title(BuildContext context, String title, [String figure = '']) {
    final style = Theme.of(context).textTheme.titleMedium;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Expanded(child: Text(title, style: style)),
          if (figure.isNotEmpty) Text(figure, style: style?.copyWith(fontFeatures: PosTheme.tabular)),
        ],
      ),
    );
  }

  Widget _sales(BuildContext context, TodayReport report) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = PosColors.of(context);
    final small = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final day = report.day, before = report.before;
    final then = lastWeekday(before.first);
    final pace = paceWords(report.paceNow, report.paceBefore, before.first);
    final paceColor = switch (pace.up) {
      true => theme.brightness == Brightness.dark ? colors.firedBorder : colors.firedText,
      false => scheme.error,
      null => scheme.onSurfaceVariant,
    };
    final counts = [
      '${day.checks} ${day.checks == 1 ? 'check' : 'checks'}',
      if (day.guests > 0) '${day.guests} ${day.guests == 1 ? 'guest' : 'guests'}',
      if (report.perCheck != null) '${dollars(report.perCheck!)} a check',
    ].join(' · ');
    return _card('sales', [
      Text('Net sales so far', style: theme.textTheme.labelLarge?.copyWith(color: scheme.onSurfaceVariant)),
      FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Text(
          dollars(day.net),
          key: const ValueKey('today-net'),
          style: theme.textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w700, fontFeatures: PosTheme.tabular),
        ),
      ),
      Text(counts, key: const ValueKey('today-counts')),
      if (pace.words.isNotEmpty) ...[
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (pace.up != null) ...[
              Icon(pace.up! ? Icons.trending_up : Icons.trending_down, size: 20, color: paceColor),
              const SizedBox(width: 6),
            ],
            Expanded(
              child: Text(
                pace.words,
                key: const ValueKey('today-pace'),
                style: theme.textTheme.titleSmall?.copyWith(color: paceColor, fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
        Text(
          'Dishes rung in by ${_time(report.nowMs)}, before comps and tax: ${dollars(report.paceNow)} today, '
          '${dollars(report.paceBefore)} then.',
          key: const ValueKey('today-pace-figures'),
          style: small,
        ),
      ],
      const SizedBox(height: 6),
      Text(
        before.checks == 0
            ? 'Nothing was sold $then.'
            : 'The whole of $then came to ${dollars(before.net)} net sales on ${before.checks} '
                  '${before.checks == 1 ? 'check' : 'checks'}.',
        key: const ValueKey('today-before'),
        style: small,
      ),
      const SizedBox(height: 4),
      Wrap(
        spacing: 4,
        children: [
          TextButton(
            key: const ValueKey('today-day'),
            onPressed: () => _open(DayReportScreen(api: widget.api, token: _token, device: widget.device)),
            child: const Text('The day in full'),
          ),
          TextButton(
            key: const ValueKey('today-sales-full'),
            onPressed: () => _open(SalesScreen(api: widget.api, token: _token)),
            child: const Text('Sales by day'),
          ),
        ],
      ),
    ], foot: 4);
  }

  Widget _openChecks(BuildContext context, TodayReport report) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final small = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final local = MaterialLocalizations.of(context);
    final checks = report.openChecks;
    final shown = _allOpen ? checks : checks.take(_listed).toList();
    final unsent = report.day.unsent, unpaid = report.day.unpaid.length;
    final history = _may('history');
    return _card('open', [
      _title(context, 'Open checks', '${report.openCount}'),
      Text(
        report.openCount == 0 ? 'No check is open.' : '${dollars(report.openDue)} not paid yet',
        key: const ValueKey('today-open-due'),
        style: small,
      ),
      if (unsent > 0)
        Text(
          '$unsent ${unsent == 1 ? 'dish was' : 'dishes were'} never sent to the kitchen.',
          key: const ValueKey('today-unsent'),
          style: small?.copyWith(color: scheme.error),
        ),
      for (final check in shown)
        InkWell(
          key: ValueKey('today-check:${check.orderId}'),
          onTap: history
              ? () => _open(CheckHistoryScreen(api: widget.api, token: _token, orderId: check.orderId))
              : null,
          child: ReportLine(
            check.where,
            dollars(check.due),
            underWide: true,
            under: [
              if (check.day.isNotEmpty)
                'from ${local.formatShortMonthDay(DateTime.tryParse(check.day) ?? report.day.day)}',
              if (check.server.isNotEmpty) check.server,
              if (check.openedMs != null) 'open ${sinceWords(report.nowMs, check.openedMs!)}',
              if (check.unsent > 0) '${check.unsent} not sent',
            ].join(' · '),
          ),
        ),
      if (checks.length > _listed)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            key: const ValueKey('today-open-all'),
            onPressed: () => setState(() => _allOpen = !_allOpen),
            child: Text(_allOpen ? 'Show the oldest $_listed' : 'Show all ${checks.length}'),
          ),
        ),
      if (unpaid > 0)
        Text(
          '$unpaid ${unpaid == 1 ? 'check was' : 'checks were'} closed without being paid in full: see The day.',
          key: const ValueKey('today-unpaid'),
          style: small,
        ),
      if (history && checks.isNotEmpty) Text('Tap a check to read its history.', style: small),
    ]);
  }

  Widget _cameOff(BuildContext context, TodayReport report) {
    final day = report.day;
    String times(int count) => count == 0 ? '' : '$count';
    final nothing =
        day.voids.count == 0 && !isMoney(day.discountTotal) && day.takenOff.count == 0 && day.voidedChecks.count == 0;
    return _card('off', [
      _title(context, 'Came off the checks'),
      if (nothing)
        Text('Nothing came off today.', key: const ValueKey('today-off-none'))
      else ...[
        ReportLine(
          'Voids',
          dollars(day.voids.amount),
          count: times(day.voids.count),
          key: const ValueKey('today-voids'),
        ),
        ReportLine('Comps and discounts', dollars(day.discountTotal), key: const ValueKey('today-discounts')),
        if (day.takenOff.count > 0)
          ReportLine('Taken off before sending', dollars(day.takenOff.amount), count: times(day.takenOff.count)),
        if (day.voidedChecks.count > 0)
          ReportLine('Checks voided whole', dollars(day.voidedChecks.amount), count: times(day.voidedChecks.count)),
      ],
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton(
          key: const ValueKey('today-adjustments'),
          onPressed: () => _open(AdjustmentsScreen(api: widget.api, token: _token)),
          child: const Text('Voids and comps report'),
        ),
      ),
    ], foot: 4);
  }

  Widget _onTheClock(BuildContext context, TodayReport report) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final clock = report.day.clock!;
    final before = report.before.clock?.netPerHour;
    return _card('clock', [
      _title(context, 'On the clock', '${clock.onNow.length}'),
      Text(
        clock.onNow.isEmpty ? 'Nobody is on the clock.' : clock.onNow.join(', '),
        key: const ValueKey('today-on-now'),
        style: small,
      ),
      ReportLine(
        'Hours worked today',
        workedWords(clock.workedMs),
        under: '${clock.people} ${clock.people == 1 ? 'person' : 'people'}',
        key: const ValueKey('today-worked'),
      ),
      if (clock.netPerHour != null)
        ReportLine(
          'Net sales per hour worked',
          dollars(clock.netPerHour!),
          underWide: true,
          under: before == null ? '' : 'The whole of ${lastWeekday(report.before.first)}: ${dollars(before)}',
          key: const ValueKey('today-per-hour'),
        ),
      if (clock.unended > 0)
        Text(
          '${clock.unended} ${clock.unended == 1 ? 'shift' : 'shifts'} nobody clocked out of.',
          style: small?.copyWith(color: theme.colorScheme.error),
        ),
    ]);
  }

  Widget _soldOut(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final small = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final rows = _board;
    final out = rows?.where((row) => row.soldOut).length ?? 0;
    return _card('86', [
      _title(context, 'Sold out', rows == null ? '' : '$out'),
      if (rows == null)
        Text('Reading the board', style: small)
      else if (rows.isEmpty)
        Text('Nothing is sold out, and no dish has a number left.', key: const ValueKey('today-86-none'), style: small),
      for (final row in rows ?? const <BoardRow>[])
        Row(
          key: ValueKey('today-86:${row.targetId}'),
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(row.name),
                  Text(
                    row.by == null || row.by!.isEmpty ? row.said : '${row.said} · ${row.by}',
                    style: small?.copyWith(color: row.soldOut ? scheme.error : scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            TextButton(
              key: ValueKey('today-86-back:${row.targetId}'),
              onPressed: _busy ? null : () => _bringBack(row),
              child: Text(row.soldOut ? 'Bring back' : 'No number'),
            ),
          ],
        ),
      const SizedBox(height: 4),
      Align(
        alignment: Alignment.centerLeft,
        child: FilledButton.tonalIcon(
          key: const ValueKey('today-86-add'),
          onPressed: _busy ? null : _eightySix,
          icon: const Icon(Icons.block),
          label: const Text('86 a dish'),
        ),
      ),
    ], foot: 8);
  }

  Widget _kitchen(BuildContext context) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final quotes = _quotes;
    final now = DateTime.now();
    final rush = quotes?.rush;
    final on = rush != null && rush.runsAt(now);
    return _card('kitchen', [
      _title(context, 'Kitchen', on ? '+${rush.minutes} min' : ''),
      Text(
        quotes == null
            ? 'Reading the quote times'
            : on
            ? 'The rush is on: every new to-go quote is ${rush.minutes} minutes longer, until closing'
                  '${rush.by.isEmpty ? '' : ' (${rush.by})'}.'
            : 'No rush: new to-go orders get the usual quote.',
        key: const ValueKey('today-rush'),
        style: small,
      ),
      if (quotes != null)
        Text(
          'Quoted now: ${quotes.minutesFor('counter', at: now)} min at the counter, '
          '${quotes.minutesFor('phone', at: now)} min by phone.',
          key: const ValueKey('today-quotes'),
          style: small,
        ),
      if (quotes != null && quotes.takesRush && _may('rush')) ...[
        const SizedBox(height: 4),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.tonalIcon(
            key: const ValueKey('today-rush-set'),
            onPressed: _busy ? null : _rush,
            icon: const Icon(Icons.local_fire_department_outlined),
            label: Text(on ? 'Change the rush' : 'Kitchen is busy'),
          ),
        ),
      ],
    ], foot: quotes != null && quotes.takesRush && _may('rush') ? 8 : 12);
  }

  Widget _hours(BuildContext context, TodayReport report) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return _card('hours', [
      _title(context, 'Hour by hour'),
      Text(
        'The dishes rung in each hour, before comps and tax. The thin bar and the small figure are '
        '${lastWeekday(report.before.first)}.',
        style: small,
      ),
      const SizedBox(height: 4),
      ...pairedBars(context, [
        for (final row in report.hours)
          (key: 'today-hour:${row.hour}', label: hourLabel(row.hour), now: row.now, before: row.before),
      ], labelWidth: 64),
    ]);
  }
}
