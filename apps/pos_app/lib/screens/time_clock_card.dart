import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../api.dart';
import '../timeclock.dart';

/// The words of the hub's answer to a PIN typed at the clock, when it is not a person: for the pad and for
/// the card's own PIN box.
String clockPinRefusal(ApiException err) => switch (err.status) {
  401 => 'Wrong PIN',
  423 => 'Too many tries. Wait a minute.',
  null => 'The hub is not answering',
  _ => err.message == 'off' ? 'The time clock is off' : clockRefusal(err.message, message: _said(err)),
};

String? _said(ApiException err) => err.detail?['message'] as String?;

/// A person at the time clock (docs/time-clock.md), after their PIN: who they are, where they stand, and the
/// punches that fit it. Off the clock there is Clock in; on it, Clock out and Start break; on a break, End
/// break and Clock out. One punch, and the card says what the hub recorded and at what time: the time is the
/// hub's, never this screen's.
///
/// It is drawn in place, with no route of its own: the sign-in pad shows it where the pad was, on a locked
/// screen too, where no dialog can open. Left alone it closes itself, since its buttons are somebody's
/// punches.
class TimeClockCard extends StatefulWidget {
  const TimeClockCard({
    super.key,
    required this.api,
    required this.device,
    required this.pin,
    required this.stand,
    required this.onClose,
    this.offerOrders = false,
    this.closesAfter = const Duration(seconds: 30),
  });

  final PosApi api;
  final String device;

  /// The PIN the person typed, and what the hub answered it.
  final String pin;
  final ClockStand stand;

  /// The card is done with. With the person as a sign-in answers them when they asked to go on to the
  /// orders ([offerOrders]); with null otherwise.
  final void Function(Map<String, dynamic>? staff) onClose;

  /// After clocking in the card offers to go on to the orders with the same PIN.
  final bool offerOrders;

  /// How long the card waits untouched before it closes.
  final Duration closesAfter;

  @override
  State<TimeClockCard> createState() => _TimeClockCardState();
}

class _TimeClockCardState extends State<TimeClockCard> {
  static final _random = math.Random();

  late ClockStand _stand = widget.stand;
  String? _message;
  bool _busy = false;
  bool _punched = false;
  Timer? _closes;

  /// The punch that got no answer, by what it was: tapped again it is the same punch, so it counts once.
  final _unanswered = <String, String>{};

  @override
  void initState() {
    super.initState();
    _armClose();
  }

  @override
  void dispose() {
    _closes?.cancel();
    super.dispose();
  }

  void _armClose() {
    _closes?.cancel();
    _closes = Timer(widget.closesAfter, () {
      if (mounted) widget.onClose(null);
    });
  }

  String _newId() {
    final id =
        '${widget.device}-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
        '-${_random.nextInt(1 << 30).toRadixString(36)}';
    return id.length <= 64 ? id : id.substring(id.length - 64);
  }

  Future<void> _punch(String action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    _closes?.cancel(); // nothing closes under a punch on its way
    final id = _unanswered.putIfAbsent(action, _newId);
    try {
      final stand = await widget.api.clockPunch(device: widget.device, pin: widget.pin, action: action, punchId: id);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _stand = stand;
        _punched = true;
      });
    } on ApiException catch (err) {
      if (!mounted) return;
      if (err.status == null) {
        // Nothing answered: the punch may or may not have landed. Tapped again it is the same one.
        setState(() {
          _busy = false;
          _message = 'The hub did not answer. Tap again to make sure it is recorded.';
        });
        _armClose();
        return;
      }
      _unanswered.remove(action);
      // The punch did not fit: somebody clocked them in or out since the card came up. Look again.
      ClockStand? now;
      if (err.status == 409 && err.message != 'off') {
        try {
          now = await widget.api.clockPunch(device: widget.device, pin: widget.pin);
        } on ApiException {
          now = null;
        }
      }
      if (!mounted) return;
      setState(() {
        _busy = false;
        _message = clockPinRefusal(err);
        if (now != null) _stand = now;
      });
    }
    _armClose();
  }

  String _time(int ms) => TimeOfDay.fromDateTime(DateTime.fromMillisecondsSinceEpoch(ms)).format(context);

  String _day(int ms) =>
      MaterialLocalizations.of(context).formatMediumDate(clockDay(DateTime.fromMillisecondsSinceEpoch(ms)));

  /// What the shift has come to: the time worked, and the breaks when there were any.
  String _cameTo(ClockShift shift, {bool paid = false}) {
    final worked = '${hoursMinutes(shift.workedMs)} worked';
    if (shift.breakMs < 60000) return worked;
    return '$worked, ${hoursMinutes(shift.breakMs)} on breaks${paid ? ' (counted as worked)' : ''}';
  }

  /// The headline and the line under it: what the punch did, or where the person stands.
  (IconData, String, String?) _says(ClockStand stand) {
    final shift = stand.shift;
    final since = stand.sinceMs;
    switch (_punched ? stand.punched : null) {
      case 'in':
        return (Icons.check_circle, 'Clocked in at ${_time(shift?.inMs ?? stand.nowMs)}', null);
      case 'out':
        return (
          Icons.check_circle,
          'Clocked out at ${_time(shift?.outMs ?? stand.nowMs)}',
          shift == null ? null : 'This shift: ${_cameTo(shift, paid: stand.breaksPaid)}',
        );
      case 'break_start':
        return (Icons.check_circle, 'Break started at ${_time(since ?? stand.nowMs)}', null);
      case 'break_end':
        return (Icons.check_circle, 'Back from the break at ${_time(stand.nowMs)}', null);
    }
    return switch (stand.state) {
      'in' => (
        Icons.schedule,
        'On the clock since ${_time(since ?? stand.nowMs)}',
        shift == null ? null : '${_cameTo(shift, paid: stand.breaksPaid)} so far',
      ),
      'break' => (
        Icons.free_breakfast_outlined,
        'On a break since ${_time(since ?? stand.nowMs)}',
        since == null ? null : '${hoursMinutes(stand.nowMs - since)} so far',
      ),
      _ => (Icons.schedule, 'Not on the clock', null),
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final stand = _stand;
    final (icon, headline, under) = _says(stand);
    final unended = stand.unended;
    final big = FilledButton.styleFrom(minimumSize: const Size.fromHeight(52));
    final bigOutlined = OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52));
    Widget punch(String action, String label, {bool main = true}) => main
        ? FilledButton(
            key: ValueKey('clock-$action'),
            style: big,
            onPressed: _busy ? null : () => _punch(action),
            child: Text(label),
          )
        : OutlinedButton(
            key: ValueKey('clock-$action'),
            style: bigOutlined,
            onPressed: _busy ? null : () => _punch(action),
            child: Text(label),
          );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(stand.name, key: const ValueKey('clock-name'), style: theme.textTheme.headlineSmall),
        Text(
          stand.role.isEmpty ? 'Time clock' : '${stand.role[0].toUpperCase()}${stand.role.substring(1)} · Time clock',
          style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: _punched ? scheme.tertiary : scheme.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(headline, key: const ValueKey('clock-said'), style: theme.textTheme.titleMedium),
                  if (under != null)
                    Text(
                      under,
                      key: const ValueKey('clock-under'),
                      style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                ],
              ),
            ),
          ],
        ),
        if (unended != null) ...[
          const SizedBox(height: 12),
          Container(
            key: const ValueKey('clock-unended'),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: scheme.errorContainer, borderRadius: BorderRadius.circular(10)),
            child: Text(
              'Nobody clocked you out on ${_day(unended.inMs)}. Tell a manager when you left: until then '
              'that shift is counted to ${_time(unended.outMs ?? unended.inMs)}, when the night ended.',
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.onErrorContainer),
            ),
          ),
        ],
        if (_message != null) ...[
          const SizedBox(height: 12),
          Text(
            _message!,
            key: const ValueKey('clock-error'),
            style: TextStyle(color: scheme.error),
          ),
        ],
        const SizedBox(height: 16),
        if (_punched) ...[
          FilledButton(
            key: const ValueKey('clock-done'),
            style: big,
            onPressed: () => widget.onClose(null),
            child: const Text('Done'),
          ),
          if (widget.offerOrders && stand.state == 'in') ...[
            const SizedBox(height: 8),
            OutlinedButton(
              key: const ValueKey('clock-orders'),
              style: bigOutlined,
              onPressed: () => widget.onClose(stand.staff),
              child: const Text('Go to orders'),
            ),
          ],
        ] else ...[
          if (stand.state == 'out') punch('in', 'Clock in'),
          if (stand.state == 'in') ...[
            punch('out', 'Clock out'),
            const SizedBox(height: 8),
            punch('break_start', 'Start break', main: false),
          ],
          if (stand.state == 'break') ...[
            punch('break_end', 'End break'),
            const SizedBox(height: 8),
            punch('out', 'Clock out', main: false),
          ],
          const SizedBox(height: 4),
          TextButton(
            key: const ValueKey('clock-close'),
            onPressed: _busy ? null : () => widget.onClose(null),
            child: const Text('Close'),
          ),
        ],
      ],
    );
  }
}

/// The time clock from inside the POS: it asks for the person's own PIN, so nobody punches for whoever left
/// a screen signed in, then shows their [TimeClockCard].
class TimeClockDialog extends StatefulWidget {
  const TimeClockDialog({super.key, required this.api, required this.device});

  final PosApi api;
  final String device;

  @override
  State<TimeClockDialog> createState() => _TimeClockDialogState();
}

class _TimeClockDialogState extends State<TimeClockDialog> {
  final _pinBox = TextEditingController();
  String? _pin;
  ClockStand? _stand;
  String? _message;
  bool _busy = false;

  @override
  void dispose() {
    _pinBox.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    final pin = _pinBox.text.trim();
    if (_busy || pin.isEmpty) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final stand = await widget.api.clockPunch(device: widget.device, pin: pin);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _pin = pin;
        _stand = stand;
      });
    } on ApiException catch (err) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _pinBox.clear();
        _message = clockPinRefusal(err);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final stand = _stand;
    if (stand == null) {
      return AlertDialog(
        title: const Text('Time clock'),
        content: SizedBox(
          width: 280,
          child: TextField(
            key: const ValueKey('clock-pin'),
            controller: _pinBox,
            autofocus: true,
            obscureText: true,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(labelText: 'Your PIN', errorText: _message, errorMaxLines: 3),
            onSubmitted: (_) => _open(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
          FilledButton(key: const ValueKey('clock-open'), onPressed: _busy ? null : _open, child: const Text('Open')),
        ],
      );
    }
    return AlertDialog(
      content: SizedBox(
        width: 320,
        child: SingleChildScrollView(
          child: TimeClockCard(
            api: widget.api,
            device: widget.device,
            pin: _pin!,
            stand: stand,
            onClose: (_) => Navigator.of(context).pop(),
          ),
        ),
      ),
    );
  }
}
