import 'package:flutter/material.dart';

import '../api.dart';
import '../day_report.dart' show dollars, kindLabel;
import '../paid_checks.dart';
import 'span_report.dart';

/// Who paid a check, said afterwards from the guest list (docs/guest-list.md, "Who paid, said afterwards").
///
/// A check with several guests is one guest's money: the one who paid. A tap on the check says which while
/// the party sits there. When nobody tapped, the check waits and its money counts for nobody; here whoever
/// may read the guest list says it, for as long as the list reads the visit. [WhoPaidCard] is one check
/// with its guests as buttons; [WhoPaidScreen] the checks that wait; [showWhoPaid] one check, opened from
/// a guest's visit. The hub keeps the word and does every sum. No money is taken by it and nothing is
/// written on the check.

/// What to say when the hub did not take or give who paid.
String _why(ApiException err, String what) => switch (err.status) {
  null => 'The hub is not answering: $what',
  401 || 403 => "The manager's hour here is over: go back and open Location again.",
  _ => (err.detail?['message'] as String?) ?? 'The hub did not take it (${err.message}).',
};

/// One check and its guests, each a button: tap the guest who paid. The one who paid is ticked; a tap on
/// them takes the word back, where it was a word (the number typed on a check pays without one).
class WhoPaidCard extends StatefulWidget {
  const WhoPaidCard({super.key, required this.api, required this.token, required this.check, this.onSaid});

  final PosApi api;

  /// The session of whoever may read the guest list: the name behind it is who said it.
  final String token;
  final PaidCheck check;

  /// Told the check as the hub keeps it, each time a word was taken.
  final ValueChanged<PaidCheck>? onSaid;

  @override
  State<WhoPaidCard> createState() => _WhoPaidCardState();
}

class _WhoPaidCardState extends State<WhoPaidCard> {
  late PaidCheck _check = widget.check;

  /// Less room beside a name than a button takes by itself: two names fit side by side on a small phone.
  static const _snug = EdgeInsetsDirectional.only(start: 12, end: 16);

  /// The guest whose word is on its way to the hub.
  String? _saying;
  String? _error;

  @override
  void didUpdateWidget(WhoPaidCard old) {
    super.didUpdateWidget(old);
    if (!identical(old.check, widget.check)) _check = widget.check;
  }

  Future<void> _tap(PaidGuest guest) async {
    if (_saying != null) return;
    // paying for want of a word (the number on the check, an only guest): there is no word to take back
    if (guest.pays && _check.saidBy.isEmpty) return;
    setState(() {
      _saying = guest.key;
      _error = null;
    });
    try {
      final now = await widget.api.sayPaid(widget.token, _check.orderId, guest.key, pays: !guest.pays);
      if (!mounted) return;
      setState(() {
        _check = now;
        _saying = null;
      });
      widget.onSaid?.call(now);
    } on ApiException catch (err) {
      if (!mounted) return;
      setState(() {
        _saying = null;
        _error = _why(err, 'who paid stays as it is.');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final small = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final local = MaterialLocalizations.of(context);
    final check = _check;
    final id = check.orderId;
    final opened = check.openedMs > 0 ? DateTime.fromMillisecondsSinceEpoch(check.openedMs) : null;
    return Column(
      key: ValueKey('who-paid:$id'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ReportLine(
          [
            local.formatMediumDate(check.day),
            check.table.isNotEmpty ? 'Table ${check.table}' : kindLabel(check.kind),
          ].join(' · '),
          dollars(check.net),
          under: [
            if (opened != null) local.formatTimeOfDay(TimeOfDay.fromDateTime(opened)),
            if (check.orderNo != null) '#${check.orderNo}',
          ].join(' · '),
          strong: true,
        ),
        Padding(
          padding: const EdgeInsets.only(top: 2, bottom: 4),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              // both kinds of button have a mark before the name, so a tap moves no name from under the finger
              for (final guest in check.guests)
                guest.pays
                    ? FilledButton.tonalIcon(
                        key: ValueKey('who-paid-guest:$id:${guest.key}'),
                        style: FilledButton.styleFrom(padding: _snug),
                        onPressed: () => _tap(guest),
                        icon: const Icon(Icons.check_circle, size: 18),
                        label: Text(guest.called),
                      )
                    : OutlinedButton.icon(
                        key: ValueKey('who-paid-guest:$id:${guest.key}'),
                        style: OutlinedButton.styleFrom(padding: _snug),
                        onPressed: _saying == null ? () => _tap(guest) : null,
                        icon: const Icon(Icons.radio_button_unchecked, size: 18),
                        label: Text(guest.called),
                      ),
            ],
          ),
        ),
        Text(
          _saying != null ? 'Telling the hub…' : check.standing,
          key: ValueKey('who-paid-standing:$id'),
          style: small,
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              _error!,
              key: ValueKey('who-paid-error:$id'),
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
            ),
          ),
      ],
    );
  }
}

/// The checks that wait for who paid, the newest first, each with its guests to tap.
class WhoPaidScreen extends StatefulWidget {
  const WhoPaidScreen({super.key, required this.api, required this.token, this.onSaid});

  final PosApi api;
  final String token;

  /// Called each time the hub took a word: the figures of the guest list have moved.
  final VoidCallback? onSaid;

  @override
  State<WhoPaidScreen> createState() => _WhoPaidScreenState();
}

class _WhoPaidScreenState extends State<WhoPaidScreen> {
  List<PaidCheck>? _checks;
  String? _error;
  int _asked = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final ask = ++_asked;
    setState(() => _error = null);
    try {
      final checks = await widget.api.waitingChecks(widget.token);
      if (!mounted || ask != _asked) return;
      setState(() => _checks = checks);
    } on ApiException catch (err) {
      if (!mounted || ask != _asked) return;
      setState(() => _error = _why(err, 'the checks could not be read.'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final checks = _checks;
    final Widget body;
    if (_error != null) {
      body = SpanError(prefix: 'who-paid', message: _error!, onRetry: _load);
    } else if (checks == null) {
      body = const SpanReading(prefix: 'who-paid', many: true);
    } else {
      body = ListView(
        key: const ValueKey('who-paid-list'),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          Text(
            checks.isEmpty
                ? 'No check waits for who paid.'
                : 'Several guests sat on each of these checks and nobody said who paid, so its money counts '
                      'for no guest yet. Tap the guest who paid.',
            key: const ValueKey('who-paid-about'),
            style: checks.isEmpty ? theme.textTheme.bodyMedium : small,
          ),
          for (final check in checks) ...[
            const Divider(height: 21),
            WhoPaidCard(api: widget.api, token: widget.token, check: check, onSaid: (_) => widget.onSaid?.call()),
          ],
          if (checks.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(
                'It says who a check\'s money counts for in the guest list, and nothing else: no money is '
                'taken and nothing is written on the check. A check you said stays here until you read again, '
                'so a wrong tap can be put right: tap another name, or the ticked one to take it back.',
                key: const ValueKey('who-paid-note'),
                style: small,
              ),
            ),
        ],
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Who paid?'),
        actions: [
          IconButton(
            key: const ValueKey('who-paid-refresh'),
            tooltip: 'Read again',
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 640), child: body),
      ),
    );
  }
}

/// One check, read from the hub and shown with its guests to tap: what a guest's visit at a table of
/// several guests opens. True when a word was taken while it was open.
Future<bool> showWhoPaid(
  BuildContext context, {
  required PosApi api,
  required String token,
  required String orderId,
}) async {
  var said = false;
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      key: const ValueKey('who-paid-dialog'),
      title: const Text('Who paid?'),
      // a phone keeps its width for the names
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      contentPadding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: _OneCheck(api: api, token: token, orderId: orderId, onSaid: () => said = true),
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('who-paid-done'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
    ),
  );
  return said;
}

class _OneCheck extends StatefulWidget {
  const _OneCheck({required this.api, required this.token, required this.orderId, required this.onSaid});

  final PosApi api;
  final String token;
  final String orderId;
  final VoidCallback onSaid;

  @override
  State<_OneCheck> createState() => _OneCheckState();
}

class _OneCheckState extends State<_OneCheck> {
  PaidCheck? _check;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final check = await widget.api.paidCheck(widget.token, widget.orderId);
      if (!mounted) return;
      setState(() => _check = check);
    } on ApiException catch (err) {
      if (!mounted) return;
      setState(() => _error = _why(err, 'the check could not be read.'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final check = _check;
    if (_error != null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_error!, key: const ValueKey('who-paid-one-error')),
          TextButton(onPressed: _load, child: const Text('Try again')),
        ],
      );
    }
    if (check == null) {
      return const Padding(
        key: ValueKey('who-paid-one-reading'),
        padding: EdgeInsets.symmetric(vertical: 16),
        child: LinearProgressIndicator(),
      );
    }
    return WhoPaidCard(api: widget.api, token: widget.token, check: check, onSaid: (_) => widget.onSaid());
  }
}
