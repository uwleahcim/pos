import 'package:flutter/material.dart';

import '../api.dart';
import '../roster.dart';
import '../timeclock.dart';
import 'theme.dart';

/// Asks for a day, or a time of day, starting from the one given: the pickers of the device, or a test's.
typedef PickDay = Future<DateTime?> Function(BuildContext context, DateTime from);
typedef PickTime = Future<TimeOfDay?> Function(BuildContext context, TimeOfDay from, {String? help});

Future<DateTime?> _deviceDay(BuildContext context, DateTime from) {
  final now = DateTime.now();
  return showDatePicker(
    context: context,
    initialDate: from,
    firstDate: DateTime(from.year - 1, from.month, from.day),
    lastDate: from.isAfter(now) ? from : now,
  );
}

Future<TimeOfDay?> _deviceTime(BuildContext context, TimeOfDay from, {String? help}) =>
    showTimePicker(context: context, initialTime: from, helpText: help);

enum _Span { today, week, lastWeek, other }

/// The hours, for a manager (docs/time-clock.md): who is on the clock now, what each person worked today,
/// this pay week, last week or between two days, and every shift with its log. A shift is corrected or
/// taken off from its row and one is written in with Add a shift; each change wants its reason, and the log
/// keeps the times as they were. One column, so it reads the same on a phone.
class TimeClockScreen extends StatefulWidget {
  const TimeClockScreen({
    super.key,
    required this.api,
    required this.token,
    this.device,
    this.now = DateTime.now,
    this.pickDay = _deviceDay,
    this.pickTime = _deviceTime,
  });

  final PosApi api;

  /// The manager's session (`POST /admin/session`): every call here carries it.
  final String token;

  /// This terminal, for the log of a change.
  final String? device;

  /// The time on this device: which day is today and which week this one.
  final DateTime Function() now;
  final PickDay pickDay;
  final PickTime pickTime;

  @override
  State<TimeClockScreen> createState() => _TimeClockScreenState();
}

class _TimeClockScreenState extends State<TimeClockScreen> {
  _Span _span = _Span.today;
  DateTimeRange? _other;
  String _weekStarts = 'mon';
  ClockReport? _report;
  String? _error;
  int _asked = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// The stretch asked for: from the hour the night ends to the hour it ends again.
  (DateTime, DateTime) get _window {
    final now = widget.now();
    switch (_span) {
      case _Span.today:
        final day = clockDay(now);
        return (day, DateTime(day.year, day.month, day.day + 1, nightEndsHour));
      case _Span.week:
        final week = clockWeek(now, _weekStarts);
        return (week, DateTime(week.year, week.month, week.day + 7, nightEndsHour));
      case _Span.lastWeek:
        final week = clockWeek(now, _weekStarts);
        return (DateTime(week.year, week.month, week.day - 7, nightEndsHour), week);
      case _Span.other:
        final range = _other!;
        return (
          DateTime(range.start.year, range.start.month, range.start.day, nightEndsHour),
          DateTime(range.end.year, range.end.month, range.end.day + 1, nightEndsHour),
        );
    }
  }

  Future<void> _load() async {
    final ask = ++_asked;
    setState(() => _error = null);
    final (since, until) = _window;
    try {
      final report = await widget.api.clockReport(
        widget.token,
        sinceMs: since.millisecondsSinceEpoch,
        untilMs: until.millisecondsSinceEpoch,
      );
      if (!mounted || ask != _asked) return;
      setState(() {
        _report = report;
        _weekStarts = report.weekStarts;
      });
    } on ApiException catch (err) {
      if (!mounted || ask != _asked) return;
      setState(
        () => _error = switch (err.status) {
          401 || 403 => "The manager's hour here is over: go back and open Location again.",
          404 => 'This hub is older than the time clock. Update the hub to see hours here.',
          _ => err.message,
        },
      );
    }
  }

  void _pick(_Span span) {
    setState(() {
      _span = span;
      _report = null;
    });
    _load();
  }

  Future<void> _pickOther() async {
    final now = widget.now();
    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 1, now.month, now.day),
      lastDate: now,
      initialDateRange: _other,
      helpText: 'Shifts that began between',
    );
    if (range == null || !mounted) return;
    _other = range;
    _pick(_Span.other);
  }

  String _time(int ms) => TimeOfDay.fromDateTime(DateTime.fromMillisecondsSinceEpoch(ms)).format(context);

  String _day(int ms) => MaterialLocalizations.of(context).formatMediumDate(DateTime.fromMillisecondsSinceEpoch(ms));

  String _shortDay(DateTime day) => MaterialLocalizations.of(context).formatShortMonthDay(day);

  /// "4:02 PM – 10:31 PM", or "4:02 PM, still on the clock".
  String _fromTo(ClockShift shift) => shift.outMs == null
      ? '${_time(shift.inMs)}, still on the clock'
      : '${_time(shift.inMs)} – ${_time(shift.outMs!)}';

  Future<void> _openShift(ClockShift shift) async {
    final changed = await showDialog<bool>(
      context: context,
      builder: (_) => _ShiftDialog(
        api: widget.api,
        token: widget.token,
        device: widget.device,
        shift: shift,
        breaksPaid: _report?.breaksPaid ?? false,
        pickDay: widget.pickDay,
        pickTime: widget.pickTime,
      ),
    );
    if (changed == true && mounted) await _load();
  }

  Future<void> _addShift() async {
    Roster roster;
    try {
      roster = await widget.api.staff();
    } on ApiException {
      roster = Roster.none;
    }
    if (!mounted) return;
    if (roster.staff.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('The hub did not answer with the staff list. Try again.')));
      return;
    }
    final saved = await showDialog<ClockShift>(
      context: context,
      builder: (_) => ShiftEditDialog(
        api: widget.api,
        token: widget.token,
        device: widget.device,
        roster: roster,
        now: widget.now,
        pickDay: widget.pickDay,
        pickTime: widget.pickTime,
      ),
    );
    if (saved != null && mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final report = _report;
    final Widget body;
    if (_error != null) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Could not read the hours: $_error', textAlign: TextAlign.center),
              const SizedBox(height: 12),
              OutlinedButton(onPressed: _load, child: const Text('Try again')),
            ],
          ),
        ),
      );
    } else if (report == null) {
      body = const Center(child: CircularProgressIndicator());
    } else {
      final shifts = report.newestFirst;
      body = ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: [
          if (!report.enabled)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'The time clock is off: nobody can clock in. Turn it on under Location settings.',
                key: const ValueKey('clock-off'),
                style: TextStyle(color: scheme.error),
              ),
            ),
          _Heading(
            'On the clock now',
            report.onNow.isEmpty ? '' : '${report.onNow.length}',
            key: const ValueKey('on-now'),
          ),
          if (report.onNow.isEmpty)
            const Text('Nobody is on the clock.')
          else
            for (final shift in report.onNow)
              ListTile(
                key: ValueKey('on-now:${shift.staffId}'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(shift.state == 'break' ? Icons.free_breakfast_outlined : Icons.schedule),
                title: Text(shift.role.isEmpty ? shift.name : '${shift.name} · ${shift.role}'),
                subtitle: Text(
                  shift.state == 'break' && shift.breaks.isNotEmpty
                      ? 'In at ${_time(shift.inMs)} · on a break since ${_time(shift.breaks.last.startMs)}'
                      : 'In at ${_time(shift.inMs)}',
                ),
                trailing: Text(hoursMinutes(shift.workedMs), style: const TextStyle(fontFeatures: PosTheme.tabular)),
                onTap: () => _openShift(shift),
              ),
          const Divider(height: 28),
          _Heading('Hours', hoursMinutes(report.workedMs), key: const ValueKey('hours')),
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              report.breaksPaid
                  ? 'Breaks count as time worked. Each time is to the minute, with no rounding.'
                  : 'Breaks are taken out. Each time is to the minute, with no rounding.',
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          if (report.unended > 0)
            Container(
              key: const ValueKey('unended-note'),
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: scheme.errorContainer, borderRadius: BorderRadius.circular(10)),
              child: Text(
                '${report.unended == 1 ? 'One shift was' : '${report.unended} shifts were'} never clocked out. '
                'The hub closed ${report.unended == 1 ? 'it' : 'them'} when the night ended, so '
                '${report.unended == 1 ? 'its hours are' : 'their hours are'} too long: open '
                '${report.unended == 1 ? 'it' : 'each'} below and put the real time on it.',
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.onErrorContainer),
              ),
            ),
          if (report.people.isEmpty)
            const Text('No shift began in this time.')
          else
            for (final person in report.people)
              Padding(
                key: ValueKey('person:${person.staffId}'),
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(person.role.isEmpty ? person.name : '${person.name} · ${person.role}'),
                          Text(
                            [
                              '${person.shifts} ${person.shifts == 1 ? 'shift' : 'shifts'}',
                              if (person.breakMs >= 60000) '${hoursMinutes(person.breakMs)} on breaks',
                              if (person.open > 0) 'on the clock now',
                              if (person.unended > 0) '${person.unended} not clocked out',
                            ].join(' · '),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: person.unended > 0 ? scheme.error : scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(hoursMinutes(person.workedMs), style: const TextStyle(fontFeatures: PosTheme.tabular)),
                        Text(
                          '${decimalHours(person.workedMs)} hours',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                            fontFeatures: PosTheme.tabular,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
          const Divider(height: 28),
          Row(
            children: [
              Expanded(child: Text('Each shift', style: theme.textTheme.titleLarge)),
              TextButton.icon(
                key: const ValueKey('shift-add'),
                onPressed: _addShift,
                icon: const Icon(Icons.add),
                label: const Text('Add a shift'),
              ),
            ],
          ),
          if (shifts.isEmpty)
            const Text('No shift began in this time.')
          else
            for (final shift in shifts)
              ListTile(
                key: ValueKey('shift:${shift.shiftId}'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(
                  '${shift.name} · ${_day(shift.inMs)}',
                  style: shift.removed ? TextStyle(color: scheme.onSurfaceVariant) : null,
                ),
                subtitle: Text(
                  [
                    _fromTo(shift),
                    if (shift.breakMs >= 60000) '${hoursMinutes(shift.breakMs)} on breaks',
                    if (shift.removed)
                      'taken off'
                    else if (shift.unended)
                      'not clocked out'
                    else if (shift.writtenIn)
                      'written in'
                    else if (shift.edited)
                      'corrected',
                  ].join(' · '),
                  style: shift.unended ? TextStyle(color: scheme.error) : null,
                ),
                trailing: Text(
                  shift.removed ? '–' : hoursMinutes(shift.workedMs),
                  style: const TextStyle(fontFeatures: PosTheme.tabular),
                ),
                onTap: () => _openShift(shift),
              ),
        ],
      );
    }
    final other = _other;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Time clock'),
        actions: [IconButton(tooltip: 'Read again', icon: const Icon(Icons.refresh), onPressed: _load)],
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
                    runSpacing: 4,
                    children: [
                      for (final (span, label) in const [
                        (_Span.today, 'Today'),
                        (_Span.week, 'This week'),
                        (_Span.lastWeek, 'Last week'),
                      ])
                        ChoiceChip(
                          key: ValueKey('clock-span:${span.name}'),
                          label: Text(label),
                          selected: _span == span,
                          onSelected: (_) => _pick(span),
                        ),
                      ChoiceChip(
                        key: const ValueKey('clock-span:other'),
                        avatar: const Icon(Icons.date_range, size: 18),
                        label: Text(
                          _span == _Span.other && other != null
                              ? '${_shortDay(other.start)} – ${_shortDay(other.end)}'
                              : 'Other days',
                        ),
                        selected: _span == _Span.other,
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

/// One shift, opened from its row: its times, what it came to and its log, with the two things a manager
/// can do to it. Pops true when it was changed.
class _ShiftDialog extends StatelessWidget {
  const _ShiftDialog({
    required this.api,
    required this.token,
    required this.shift,
    required this.breaksPaid,
    required this.pickDay,
    required this.pickTime,
    this.device,
  });

  final PosApi api;
  final String token;
  final String? device;
  final ClockShift shift;
  final bool breaksPaid;
  final PickDay pickDay;
  final PickTime pickTime;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final local = MaterialLocalizations.of(context);
    String time(int ms) => TimeOfDay.fromDateTime(DateTime.fromMillisecondsSinceEpoch(ms)).format(context);
    String moment(int ms) => '${local.formatShortMonthDay(DateTime.fromMillisecondsSinceEpoch(ms))} ${time(ms)}';

    /// The times of a shift as the log kept them: "4:02 PM – 10:31 PM, 1 break".
    String times(Map<String, dynamic>? kept) {
      if (kept == null) return 'nothing';
      final inMs = (kept['in_ms'] as num?)?.toInt();
      final outMs = (kept['out_ms'] as num?)?.toInt();
      final breaks = (kept['breaks'] as List?)?.length ?? 0;
      return [
        if (inMs != null) outMs == null ? '${time(inMs)}, no clock-out' : '${time(inMs)} – ${time(outMs)}',
        if (breaks > 0) '$breaks ${breaks == 1 ? 'break' : 'breaks'}',
      ].join(', ');
    }

    Future<void> correct() async {
      final saved = await showDialog<ClockShift>(
        context: context,
        builder: (_) =>
            ShiftEditDialog(api: api, token: token, device: device, shift: shift, pickDay: pickDay, pickTime: pickTime),
      );
      if (saved != null && context.mounted) Navigator.of(context).pop(true);
    }

    Future<void> takeOff() async {
      final gone = await showDialog<bool>(
        context: context,
        builder: (_) => _TakeOffDialog(api: api, token: token, device: device, shift: shift),
      );
      if (gone == true && context.mounted) Navigator.of(context).pop(true);
    }

    return AlertDialog(
      title: Text(shift.role.isEmpty ? shift.name : '${shift.name} · ${shift.role}'),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(local.formatFullDate(DateTime.fromMillisecondsSinceEpoch(shift.inMs))),
              const SizedBox(height: 8),
              Text('Clocked in  ${time(shift.inMs)}'),
              for (final b in shift.breaks)
                Text(
                  b.endMs == null
                      ? 'Break  ${time(b.startMs)}, still on it'
                      : 'Break  ${time(b.startMs)} – ${time(b.endMs!)}',
                ),
              Text(shift.outMs == null ? 'Still on the clock' : 'Clocked out  ${time(shift.outMs!)}'),
              const SizedBox(height: 8),
              if (shift.removed)
                Text('Taken off: it counts for nothing.', style: TextStyle(color: scheme.error))
              else
                Text(
                  [
                    '${hoursMinutes(shift.workedMs)} worked (${decimalHours(shift.workedMs)} hours)',
                    if (shift.breakMs >= 60000)
                      '${hoursMinutes(shift.breakMs)} on breaks${breaksPaid ? ', counted as worked' : ''}',
                  ].join(' · '),
                  key: const ValueKey('shift-came-to'),
                  style: theme.textTheme.titleSmall,
                ),
              if (shift.unended)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'Nobody clocked out of this shift. The hub closed it at ${time(shift.outMs ?? shift.inMs)}, '
                    'when the night ended. Correct it with the time they really left.',
                    key: const ValueKey('shift-unended'),
                    style: TextStyle(color: scheme.error),
                  ),
                ),
              if (shift.log.isNotEmpty) ...[
                const Divider(height: 24),
                Text('What happened to it', style: theme.textTheme.labelLarge?.copyWith(color: scheme.primary)),
                for (final (i, entry) in shift.log.indexed)
                  Padding(
                    key: ValueKey('log:$i'),
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      [
                        moment(entry.atMs),
                        entry.byManager && entry.by.isNotEmpty ? '${entry.what} by ${entry.by}' : entry.what,
                        if (entry.reason.isNotEmpty) '"${entry.reason}"',
                        if (entry.action == 'edit') 'was ${times(entry.before)}, now ${times(entry.after)}',
                        if (entry.action == 'add') times(entry.after),
                        if (!entry.byManager && entry.device.isNotEmpty) 'at ${entry.device}',
                      ].join(' · '),
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        if (!shift.removed)
          TextButton(
            key: const ValueKey('shift-take-off'),
            onPressed: takeOff,
            style: TextButton.styleFrom(foregroundColor: scheme.error),
            child: const Text('Take off'),
          ),
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Close')),
        if (!shift.removed)
          FilledButton(key: const ValueKey('shift-correct'), onPressed: correct, child: const Text('Correct')),
      ],
    );
  }
}

/// Why a shift is taken off (a punch made by mistake). It is kept, marked, and counts for nothing.
class _TakeOffDialog extends StatefulWidget {
  const _TakeOffDialog({required this.api, required this.token, required this.shift, this.device});

  final PosApi api;
  final String token;
  final String? device;
  final ClockShift shift;

  @override
  State<_TakeOffDialog> createState() => _TakeOffDialogState();
}

class _TakeOffDialogState extends State<_TakeOffDialog> {
  final _reason = TextEditingController();
  String? _message;
  bool _busy = false;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _takeOff() async {
    if (_busy || _reason.text.trim().isEmpty) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await widget.api.removeShift(
        widget.token,
        widget.shift.shiftId,
        reason: _reason.text.trim(),
        device: widget.device,
      );
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (err) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _message = clockRefusal(err.message, message: err.detail?['message'] as String?);
      });
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text("Take off ${widget.shift.name}'s shift"),
    content: SizedBox(
      width: 320,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('It stays in the list, marked, and counts for no hours.'),
          const SizedBox(height: 8),
          TextField(
            key: const ValueKey('take-off-reason'),
            controller: _reason,
            autofocus: true,
            maxLength: 200,
            decoration: InputDecoration(labelText: 'Why', errorText: _message, errorMaxLines: 3),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _takeOff(),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
      FilledButton(
        key: const ValueKey('take-off-save'),
        onPressed: _busy || _reason.text.trim().isEmpty ? null : _takeOff,
        child: const Text('Take off'),
      ),
    ],
  );
}

/// A shift's times as a manager wants them: a correction of [shift], or with none a shift written in for
/// one of the [roster] who never clocked in. The day is the day of the clock-in; the clock-out and each
/// break are times of day after it, so a shift that runs past midnight needs no second date. A time nobody
/// touches is kept to the second it was punched at. The hub checks everything and wants the reason; what it
/// refuses is said under the reason. Pops the shift as saved.
class ShiftEditDialog extends StatefulWidget {
  const ShiftEditDialog({
    super.key,
    required this.api,
    required this.token,
    this.device,
    this.shift,
    this.roster = Roster.none,
    this.now = DateTime.now,
    this.pickDay = _deviceDay,
    this.pickTime = _deviceTime,
  });

  final PosApi api;
  final String token;
  final String? device;
  final ClockShift? shift;
  final Roster roster;
  final DateTime Function() now;
  final PickDay pickDay;
  final PickTime pickTime;

  @override
  State<ShiftEditDialog> createState() => _ShiftEditDialogState();
}

class _ShiftEditDialogState extends State<ShiftEditDialog> {
  final _reason = TextEditingController();
  late String? _staffId = widget.shift?.staffId ?? widget.roster.staff.firstOrNull?.staffId;
  late DateTime _in;
  DateTime? _out;
  var _breaks = <(DateTime, DateTime?)>[];
  String? _message;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final shift = widget.shift;
    if (shift == null) {
      // A shift written in starts as today's, from noon to nine: both are there to be changed.
      final day = clockDay(widget.now());
      _in = DateTime(day.year, day.month, day.day, 12);
      _out = firstAfter(_in, 21, 0);
      if (_out!.isAfter(widget.now())) _out = null;
      if (_in.isAfter(widget.now())) _in = DateTime(day.year, day.month, day.day - 1, 12);
    } else {
      _in = DateTime.fromMillisecondsSinceEpoch(shift.inMs);
      _out = shift.outMs == null ? null : DateTime.fromMillisecondsSinceEpoch(shift.outMs!);
      _breaks = [
        for (final b in shift.breaks)
          (
            DateTime.fromMillisecondsSinceEpoch(b.startMs),
            b.endMs == null ? null : DateTime.fromMillisecondsSinceEpoch(b.endMs!),
          ),
      ];
    }
  }

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  String _time(DateTime at) => TimeOfDay.fromDateTime(at).format(context);

  static DateTime _plusDays(DateTime at, int days) =>
      DateTime(at.year, at.month, at.day + days, at.hour, at.minute, at.second, at.millisecond);

  /// Another day: the whole shift moves to it, every time as it was.
  Future<void> _pickDay() async {
    final day = await widget.pickDay(context, _in);
    if (day == null || !mounted) return;
    final days =
        (DateTime(day.year, day.month, day.day).difference(DateTime(_in.year, _in.month, _in.day)).inHours / 24)
            .round();
    if (days == 0) return;
    setState(() {
      _in = _plusDays(_in, days);
      if (_out != null) _out = _plusDays(_out!, days);
      _breaks = [
        for (final (start, end) in _breaks) (_plusDays(start, days), end == null ? null : _plusDays(end, days)),
      ];
    });
  }

  /// Another time for the clock-in, on its day. A clock-out that would now be before it is the same time of
  /// day after it; the breaks stay where they are, and the hub says so when one is left outside the shift.
  Future<void> _pickIn() async {
    final at = await widget.pickTime(context, TimeOfDay.fromDateTime(_in), help: 'Clocked in at');
    if (at == null || !mounted) return;
    if (at.hour == _in.hour && at.minute == _in.minute) return; // the same minute: kept to its second
    setState(() {
      _in = DateTime(_in.year, _in.month, _in.day, at.hour, at.minute);
      final out = _out;
      if (out != null && !out.isAfter(_in)) {
        _out = firstAfter(_in.add(const Duration(minutes: 1)), out.hour, out.minute);
      }
    });
  }

  /// The clock-out is a time of day: the first one after the clock-in, so past midnight it is the next day.
  Future<void> _pickOut() async {
    final out = _out;
    final at = await widget.pickTime(context, TimeOfDay.fromDateTime(out ?? widget.now()), help: 'Clocked out at');
    if (at == null || !mounted) return;
    if (out != null && at.hour == out.hour && at.minute == out.minute) return;
    setState(() => _out = firstAfter(_in.add(const Duration(minutes: 1)), at.hour, at.minute));
  }

  Future<void> _pickBreak(int? i) async {
    final was = i == null ? null : _breaks[i];
    final start = await widget.pickTime(context, TimeOfDay.fromDateTime(was?.$1 ?? _in), help: 'The break started at');
    if (start == null || !mounted) return;
    final from = firstAfter(_in, start.hour, start.minute);
    final end = await widget.pickTime(
      context,
      TimeOfDay.fromDateTime(was?.$2 ?? from.add(const Duration(minutes: 30))),
      help: 'The break ended at',
    );
    if (end == null || !mounted) return;
    final one = (from, firstAfter(from, end.hour, end.minute));
    setState(() {
      if (i == null) {
        _breaks = [..._breaks, one]..sort((a, b) => a.$1.compareTo(b.$1));
      } else {
        _breaks = [..._breaks]
          ..[i] = one
          ..sort((a, b) => a.$1.compareTo(b.$1));
      }
    });
  }

  Future<void> _save() async {
    final staffId = _staffId;
    if (_busy || _reason.text.trim().isEmpty || staffId == null) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    final breaks = [
      for (final (start, end) in _breaks)
        ClockBreak(startMs: start.millisecondsSinceEpoch, endMs: end?.millisecondsSinceEpoch),
    ];
    try {
      final shift = widget.shift;
      final saved = shift == null
          ? await widget.api.addShift(
              widget.token,
              staffId: staffId,
              inMs: _in.millisecondsSinceEpoch,
              outMs: _out?.millisecondsSinceEpoch,
              breaks: breaks,
              reason: _reason.text.trim(),
              device: widget.device,
            )
          : await widget.api.editShift(
              widget.token,
              shift.shiftId,
              inMs: _in.millisecondsSinceEpoch,
              outMs: _out?.millisecondsSinceEpoch,
              breaks: breaks,
              reason: _reason.text.trim(),
              device: widget.device,
            );
      if (mounted) Navigator.of(context).pop(saved);
    } on ApiException catch (err) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _message = switch (err.status) {
          null => 'The hub is not answering. Nothing was changed.',
          401 || 403 => "The manager's hour here is over: go back and open Location again.",
          _ => clockRefusal(err.message, message: err.detail?['message'] as String?),
        };
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final shift = widget.shift;
    final out = _out;
    final nextDay = out != null && (out.day != _in.day || out.month != _in.month || out.year != _in.year);
    Widget row(String key, String label, String value, VoidCallback onTap, {Widget? trailing}) => InkWell(
      key: ValueKey(key),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            SizedBox(
              width: 92,
              child: Text(label, style: TextStyle(color: scheme.onSurfaceVariant)),
            ),
            Expanded(child: Text(value, style: theme.textTheme.titleSmall)),
            trailing ?? Icon(Icons.edit_outlined, size: 18, color: scheme.onSurfaceVariant),
          ],
        ),
      ),
    );
    return AlertDialog(
      title: Text(shift == null ? 'Add a shift' : "Correct ${shift.name}'s shift"),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (shift == null)
                DropdownButtonFormField<String>(
                  key: const ValueKey('shift-who'),
                  initialValue: _staffId,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Who'),
                  items: [
                    for (final person in widget.roster.staff)
                      DropdownMenuItem(
                        value: person.staffId,
                        child: Text(person.role.isEmpty ? person.name : '${person.name} · ${person.role}'),
                      ),
                  ],
                  onChanged: (id) => setState(() => _staffId = id),
                ),
              row('shift-day', 'Day', MaterialLocalizations.of(context).formatMediumDate(_in), _pickDay),
              row('shift-in', 'Clock in', _time(_in), _pickIn),
              row(
                'shift-out',
                'Clock out',
                out == null ? 'Still on the clock' : '${_time(out)}${nextDay ? ' (the next day)' : ''}',
                _pickOut,
                trailing: out == null
                    ? null
                    : IconButton(
                        key: const ValueKey('shift-out-clear'),
                        tooltip: 'Still on the clock',
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () => setState(() => _out = null),
                      ),
              ),
              for (final (i, (start, end)) in _breaks.indexed)
                row(
                  'shift-break:$i',
                  'Break',
                  end == null ? '${_time(start)}, still on it' : '${_time(start)} – ${_time(end)}',
                  () => _pickBreak(i),
                  trailing: IconButton(
                    key: ValueKey('shift-break-delete:$i'),
                    tooltip: 'No such break',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.delete_outline, size: 18),
                    onPressed: () => setState(() => _breaks = [..._breaks]..removeAt(i)),
                  ),
                ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const ValueKey('shift-break-add'),
                  onPressed: () => _pickBreak(null),
                  icon: const Icon(Icons.add),
                  label: const Text('Add a break'),
                ),
              ),
              TextField(
                key: const ValueKey('shift-reason'),
                controller: _reason,
                maxLength: 200,
                decoration: InputDecoration(
                  labelText: 'Why',
                  helperText: widget.shift == null
                      ? 'The log keeps it with the shift'
                      : 'The log keeps it, with the times as they were',
                  helperMaxLines: 2,
                  errorText: _message,
                  errorMaxLines: 3,
                ),
                onChanged: (_) => setState(() {}),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('shift-save'),
          onPressed: _busy || _reason.text.trim().isEmpty || _staffId == null ? null : _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
