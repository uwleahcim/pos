import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api.dart';
import '../points.dart';

/// The rules of the points, as a manager sets them for the location (docs/points.md): how many points a
/// dollar earns, what earns, and how long points last. Saved on the hub. Nobody earns until a rate is set
/// here, and a rate of 0 turns earning off again.
///
/// What earns counts from the day it is saved: a check of an earlier day keeps what it earned, so the
/// dialog says since when the rules it shows have counted. Nothing here takes anything off a check, and
/// points cannot be spent yet.
class PointsDialog extends StatefulWidget {
  const PointsDialog({super.key, required this.api, required this.token, required this.rules});

  final PosApi api;
  final String token;
  final PointsRules rules;

  /// One line on the points for the Location screen.
  static String summary(PointsRules? rules) =>
      rules == null ? 'The hub has not answered about points (an older hub: update it)' : rules.summary;

  @override
  State<PointsDialog> createState() => _PointsDialogState();
}

class _PointsDialogState extends State<PointsDialog> {
  late final _rate = TextEditingController(text: widget.rules.on ? widget.rules.earning.perDollar : '');
  late final _days = TextEditingController(text: '${widget.rules.days}');
  late bool _dineIn = widget.rules.earning.dineIn;
  late bool _takeout = widget.rules.earning.takeout;
  late bool _delivery = widget.rules.earning.delivery;
  late bool _catering = widget.rules.earning.catering;
  late bool _alcohol = widget.rules.earning.alcohol;
  String? _message;
  bool _busy = false;

  @override
  void dispose() {
    _rate.dispose();
    _days.dispose();
    super.dispose();
  }

  /// The rate as typed: an empty box is 0, which is off.
  String? get _typedRate => _rate.text.trim().isEmpty ? '0' : rateTyped(_rate.text, most: widget.rules.perDollarMost);

  int? get _typedDays {
    final days = int.tryParse(_days.text.trim());
    return days != null && days >= widget.rules.daysLeast && days <= widget.rules.daysMost ? days : null;
  }

  String? get _rateProblem =>
      _typedRate == null ? 'A number from 0 to ${widget.rules.perDollarMost}, like 1 or 1.5' : null;

  String? get _daysProblem =>
      _typedDays == null ? 'From ${widget.rules.daysLeast} to ${widget.rules.daysMost} days' : null;

  /// A rate with no kind of order to earn it is no rule: the hub says so too.
  bool get _nothingEarns => rateOf(_typedRate ?? '0') > 0 && !_dineIn && !_takeout && !_delivery;

  Future<void> _save() async {
    final rate = _typedRate, days = _typedDays;
    if (rate == null || days == null || _nothingEarns) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final saved = await widget.api.savePoints(
        widget.token,
        PointsChange(
          perDollar: rate,
          dineIn: _dineIn,
          takeout: _takeout,
          delivery: _delivery,
          catering: _catering,
          alcohol: _alcohol,
          days: days,
        ),
      );
      if (mounted) Navigator.of(context).pop(saved);
    } on ApiException catch (err) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _message = err.status == null
            ? 'The hub is not answering: nothing was saved.'
            : err.detail?['message'] as String? ?? err.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final quiet = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final local = MaterialLocalizations.of(context);
    final rules = widget.rules;
    final rate = _typedRate;
    final earns = rate != null && rateOf(rate) > 0;
    // $20.00 of food at this rate, so the figure means something before it is saved
    final sample = earns ? (rateOf(rate) * 20).floor() : 0;

    Widget earnsOn(String key, String title, bool value, ValueChanged<bool> onChanged, {String? subtitle}) =>
        SwitchListTile(
          key: ValueKey('points-$key'),
          contentPadding: EdgeInsets.zero,
          dense: true,
          value: value,
          onChanged: (on) => setState(() => onChanged(on)),
          title: Text(title),
          subtitle: subtitle == null ? null : Text(subtitle),
        );

    return AlertDialog(
      title: const Text('Points'),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24), // a phone keeps its width
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'The guest who pays a check earns points on it, once the check is closed: so many a dollar of '
                'what it came to before tax, charges and tips, less comps and discounts. Points are counted '
                'and shown; they cannot be spent yet.',
                key: const ValueKey('points-says'),
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 16), // clear of the box's own label, which stands on its upper edge
              TextField(
                key: const ValueKey('points-rate'),
                controller: _rate,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d.]'))],
                decoration: InputDecoration(
                  labelText: 'Points a dollar',
                  hintText: '0',
                  border: const OutlineInputBorder(),
                  errorText: _rateProblem,
                  helperText: earns
                      ? 'A \$20.00 check earns ${pointsWords(sample)}'
                      : 'Off: nobody earns. Set 1 for one point a dollar',
                  helperMaxLines: 2, // whole on a small phone with large type
                ),
                onChanged: (_) => setState(() => _message = null),
              ),
              const SizedBox(height: 10),
              Text('What earns', style: theme.textTheme.labelLarge?.copyWith(color: scheme.primary)),
              earnsOn('dine-in', 'Tables and bar tabs', _dineIn, (on) => _dineIn = on),
              earnsOn('takeout', 'To-go orders', _takeout, (on) => _takeout = on),
              earnsOn('delivery', 'Deliveries', _delivery, (on) => _delivery = on),
              earnsOn('catering', 'Catering orders', _catering, (on) => _catering = on),
              earnsOn(
                'alcohol',
                'Alcoholic drinks',
                _alcohol,
                (on) => _alcohol = on,
                subtitle: _alcohol
                    ? 'Drinks earn like food'
                    : 'Off: the drinks on a check earn nothing, the food on it does',
              ),
              if (_nothingEarns)
                Text(
                  'Pick at least one kind of order that earns, or set the points a dollar to 0.',
                  key: const ValueKey('points-nothing-earns'),
                  style: TextStyle(color: scheme.error),
                ),
              const SizedBox(height: 10),
              TextField(
                key: const ValueKey('points-days'),
                controller: _days,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(
                  labelText: 'Points last (days)',
                  border: const OutlineInputBorder(),
                  errorText: _daysProblem,
                  helperText: 'From the day of the check. ${rules.daysMost} at most: the guest list reads a year',
                  helperMaxLines: 2,
                ),
                onChanged: (_) => setState(() => _message = null),
              ),
              const SizedBox(height: 10),
              Text(
                [
                  if (rules.from != null)
                    'These rules have counted since ${local.formatShortDate(rules.from!)}'
                        '${rules.by.isEmpty ? '' : ' (${rules.by})'}.',
                  'What you change about earning counts from today: a check of an earlier day keeps what it '
                      'earned. How long points last is one figure for all of them.',
                  if (rules.ever) 'Setting the points a dollar to 0 stops earning; points earned before still count.',
                ].join(' '),
                key: const ValueKey('points-since'),
                style: quiet,
              ),
              for (final was in rules.earlier)
                Text(
                  '${local.formatShortDate(was.from)} to ${local.formatShortDate(was.until)}: '
                  '${was.earning.earns ? rateWords(was.earning.perDollar) : 'off'}',
                  key: ValueKey('points-earlier:${was.from.toIso8601String().substring(0, 10)}'),
                  style: quiet,
                ),
              if (_message != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    _message!,
                    key: const ValueKey('points-problem'),
                    style: TextStyle(color: scheme.error),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('points-save'),
          onPressed: _busy || _typedRate == null || _typedDays == null || _nothingEarns ? null : _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
