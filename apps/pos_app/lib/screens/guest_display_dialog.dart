import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api.dart';
import '../guest_display.dart';

/// What every guest display of the location shows besides the order, as a manager sets it
/// (docs/guest-display.md): whether a tip is suggested under the total, the percentages, and what they are
/// percentages of. Saved on the hub; every guest display follows at once.
///
/// The display only shows the amounts: nothing on it can be tapped, and no tip is taken by it.
class GuestDisplayDialog extends StatefulWidget {
  const GuestDisplayDialog({super.key, required this.api, required this.token, required this.rules});

  final PosApi api;
  final String token;
  final GuestDisplayRules rules;

  /// One line on the guest displays for the Location screen.
  static String summary(GuestDisplayRules? rules) => rules == null
      ? 'The hub has not answered about guest displays (an older hub: update it)'
      : '${rules.summary}. A device becomes a guest display in its own Settings.';

  @override
  State<GuestDisplayDialog> createState() => _GuestDisplayDialogState();
}

class _GuestDisplayDialogState extends State<GuestDisplayDialog> {
  late bool _tips = widget.rules.tips;
  late String _base = widget.rules.base;
  late final List<TextEditingController> _boxes = [
    for (var i = 0; i < GuestDisplayRules.most; i++)
      TextEditingController(text: i < widget.rules.percents.length ? '${widget.rules.percents[i]}' : ''),
  ];
  String? _message;
  bool _busy = false;

  @override
  void dispose() {
    for (final box in _boxes) {
      box.dispose();
    }
    super.dispose();
  }

  /// What a box holds: a whole percentage from 1 to 100, null for an empty one, -1 for anything else.
  int? _typed(int i) {
    final text = _boxes[i].text.trim();
    if (text.isEmpty) return null;
    final percent = int.tryParse(text);
    return percent != null && percent >= 1 && percent <= 100 ? percent : -1;
  }

  /// The percentages as typed, lowest first; null while a box is wrong, two are alike, or none is typed.
  List<int>? get _percents {
    final typed = [for (var i = 0; i < _boxes.length; i++) ?_typed(i)];
    if (typed.contains(-1) || typed.toSet().length != typed.length) return null;
    // with every box empty and the tips off, the ones kept stay kept
    if (typed.isEmpty) return _tips ? null : widget.rules.percents;
    return typed..sort();
  }

  String? _problem(int i) {
    final percent = _typed(i);
    if (percent == -1) return '1 to 100';
    if (percent != null && [for (var j = 0; j < i; j++) _typed(j)].contains(percent)) return 'Twice';
    return null;
  }

  Future<void> _save() async {
    final percents = _percents;
    if (percents == null) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final saved = await widget.api.saveGuestDisplayRules(
        widget.token,
        GuestDisplayRules(tips: _tips, percents: percents, base: _base),
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
    final percents = _percents;
    // $50.00 of food, so the figures mean something before they are saved
    final sample = percents == null
        ? null
        : GuestDisplayRules.listed([for (final percent in percents) percent])
              .replaceAllMapped(RegExp(r'(\d+)%'), (m) => '\$${(50 * int.parse(m[1]!) / 100).toStringAsFixed(2)}');

    return AlertDialog(
      title: const Text('Guest display'),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24), // a phone keeps its width
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'What every screen turned to the guests shows besides the order. A device becomes a guest '
                'display in its own Settings.',
                key: const ValueKey('guest-display-says'),
                style: theme.textTheme.bodyMedium,
              ),
              SwitchListTile(
                key: const ValueKey('guest-tips-on'),
                contentPadding: EdgeInsets.zero,
                value: _tips,
                onChanged: (on) => setState(() {
                  _tips = on;
                  _message = null;
                }),
                title: const Text('Suggest a tip'),
                subtitle: Text(
                  _tips
                      ? 'Under the total, each percentage with what it comes to. The guest reads them: nothing '
                            'on the display can be tapped.'
                      : 'Off: the display says nothing about a tip',
                ),
              ),
              const SizedBox(height: 8),
              Text('Percentages', style: theme.textTheme.labelLarge?.copyWith(color: scheme.primary)),
              const SizedBox(height: 10), // clear of the boxes' own labels, which stand on their upper edge
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < _boxes.length; i++) ...[
                    if (i > 0) const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        key: ValueKey('guest-tip-percent:$i'),
                        controller: _boxes[i],
                        keyboardType: TextInputType.number,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                        decoration: InputDecoration(
                          suffixText: '%',
                          border: const OutlineInputBorder(),
                          errorText: _problem(i),
                        ),
                        onChanged: (_) => setState(() => _message = null),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 6),
              Text(
                percents == null
                    ? (_tips && [for (var i = 0; i < _boxes.length; i++) _typed(i)].every((p) => p == null)
                          ? 'Type at least one percentage, or turn the suggestion off.'
                          : 'Whole percentages from 1 to 100, no two alike. A box left empty suggests one fewer.')
                    : 'On \$50.00 the display suggests $sample. A box left empty suggests one fewer.',
                key: const ValueKey('guest-tip-sample'),
                style: percents == null ? quiet?.copyWith(color: scheme.error) : quiet,
              ),
              const SizedBox(height: 12),
              Text('A percentage of', style: theme.textTheme.labelLarge?.copyWith(color: scheme.primary)),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ChoiceChip(
                    key: const ValueKey('guest-tip-base:before_tax'),
                    label: const Text('The check before tax'),
                    selected: _base == 'before_tax',
                    onSelected: (_) => setState(() => _base = 'before_tax'),
                  ),
                  ChoiceChip(
                    key: const ValueKey('guest-tip-base:after_tax'),
                    label: const Text('The total with tax'),
                    selected: _base == 'after_tax',
                    onSelected: (_) => setState(() => _base = 'after_tax'),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                _base == 'after_tax'
                    ? 'Of the total as the guest reads it: with tax, and with a charge such as a delivery fee.'
                    : 'Of the food and drink, less comps and discounts: no tax and no charge in it.',
                key: const ValueKey('guest-tip-base-says'),
                style: quiet,
              ),
              const SizedBox(height: 10),
              Text(
                'No tip is suggested on a check that already carries a gratuity (a large party, an online '
                'order that was tipped), nor once the check is paid in full.',
                style: quiet,
              ),
              if (_message != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    _message!,
                    key: const ValueKey('guest-display-problem'),
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
          key: const ValueKey('guest-display-save'),
          onPressed: _busy || percents == null ? null : _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
