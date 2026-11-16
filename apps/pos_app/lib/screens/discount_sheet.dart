import 'package:flutter/material.dart';

import '../api.dart';
import '../face_signin.dart';
import '../menu.dart';
import '../pricing.dart';

/// A discount on the check or on one dish, from the location's fixed list of reasons (architecture section
/// 9): pick the reason, how much (a percentage, an amount or a comp) and what it is on. The hub's rules say
/// what each reason allows and whether a manager must put in a PIN first; the sheet shows those limits and
/// hands back an [Adjustment] for the screen to send, after the PIN when one is needed. Service charges
/// staff may put on themselves are offered at the bottom, and under them marking the whole check exempt
/// from sales tax ([taxExempt]; the screen asks for whom, then for the manager's PIN).
class DiscountSheet extends StatefulWidget {
  const DiscountSheet({
    super.key,
    required this.rules,
    required this.lines,
    this.existing = const [],
    this.taxExempt = false,
  });

  /// What "Tax exempt" hands back: the screen asks who the check is for and for the manager's PIN.
  static const exemptOp = 'tax_exempt';

  final PricingRules rules;
  final List<CheckLine> lines;
  final List<CheckDiscount> existing;

  /// Whether to offer "Tax exempt": the hub knows of it and the check pays its tax now.
  final bool taxExempt;

  @override
  State<DiscountSheet> createState() => _DiscountSheetState();
}

class _DiscountSheetState extends State<DiscountSheet> {
  static const _presets = [10, 15, 20, 25, 50];

  DiscountRule? _rule;
  String _kind = 'percent';
  String? _lineId; // null: the whole check
  final _value = TextEditingController();
  final _note = TextEditingController();

  @override
  void dispose() {
    _value.dispose();
    _note.dispose();
    super.dispose();
  }

  void _pick(DiscountRule rule) {
    setState(() {
      _rule = rule;
      _kind = ['percent', 'amount', 'comp'].firstWhere(rule.kinds.contains, orElse: () => rule.kinds.first);
      _value.text = rule.fixedPercent ?? '';
      if (!rule.onCheck && _lineId == null) _lineId = widget.lines.firstOrNull?.lineId;
      if (!rule.onLines) _lineId = null;
    });
  }

  /// Why Apply is off, or null when the choice is complete and within the rule.
  String? get _problem {
    final rule = _rule;
    if (rule == null) return 'Pick a reason';
    if (_lineId == null && !rule.onCheck) return 'Pick an item';
    if (_lineId != null && !rule.onLines) return '${rule.name} is for the whole check';
    return rule.problem(_kind, _value.text.trim());
  }

  void _apply() {
    final rule = _rule!;
    Navigator.of(context).pop(
      Adjustment(
        op: 'discount',
        data: {
          'reason': rule.code,
          'kind': _kind,
          if (_kind != 'comp') 'value': _value.text.trim(),
          if (_lineId != null) 'line_id': _lineId,
          if (_note.text.trim().isNotEmpty) 'note': _note.text.trim(),
        },
        needsManager: rule.needsManager,
        label: rule.name,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final rule = _rule;
    final problem = _problem;
    final stacked = rule != null && !rule.stacks && widget.existing.isNotEmpty;
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Discount', style: theme.textTheme.titleLarge),
              const SizedBox(height: 12),
              Text('Reason', style: theme.textTheme.labelLarge),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  for (final r in widget.rules.discounts)
                    ChoiceChip(
                      key: ValueKey('reason:${r.code}'),
                      label: Text(r.name),
                      avatar: r.needsManager ? const Icon(Icons.lock_outline, size: 16) : null,
                      selected: rule?.code == r.code,
                      onSelected: (_) => _pick(r),
                    ),
                ],
              ),
              if (rule != null) ...[
                const SizedBox(height: 14),
                if (rule.kinds.length > 1)
                  SegmentedButton<String>(
                    segments: [
                      for (final kind in rule.kinds)
                        ButtonSegment(
                          value: kind,
                          label: Text(switch (kind) {
                            'percent' => '%',
                            'amount' => '\$',
                            _ => 'Comp',
                          }, key: ValueKey('kind:$kind')),
                        ),
                    ],
                    selected: {_kind},
                    showSelectedIcon: false,
                    onSelectionChanged: (s) => setState(() {
                      _kind = s.first;
                      _value.text = _kind == 'percent' ? rule.fixedPercent ?? '' : '';
                    }),
                  ),
                if (_kind == 'comp')
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      _lineId == null ? 'The whole check comes to nothing.' : 'The item comes to nothing.',
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                if (_kind == 'percent' && rule.fixedPercent == null)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Wrap(
                      spacing: 8,
                      children: [
                        for (final p in _presets)
                          if (rule.maxPercent == null || p <= double.parse(rule.maxPercent!))
                            ChoiceChip(
                              key: ValueKey('preset:$p'),
                              label: Text('$p%'),
                              selected: _value.text == '$p',
                              onSelected: (_) => setState(() => _value.text = '$p'),
                            ),
                      ],
                    ),
                  ),
                if (_kind != 'comp')
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: TextField(
                      key: const ValueKey('discount-value'),
                      controller: _value,
                      readOnly: rule.fixedPercent != null && _kind == 'percent',
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: InputDecoration(
                        labelText: _kind == 'percent' ? 'Percent off' : 'Amount off',
                        prefixText: _kind == 'amount' ? '\$ ' : null,
                        suffixText: _kind == 'percent' ? '%' : null,
                        helperText: _kind == 'percent'
                            ? (rule.fixedPercent != null
                                  ? 'Always ${rule.fixedPercent}%'
                                  : rule.maxPercent != null
                                  ? 'Up to ${rule.maxPercent}%'
                                  : null)
                            : (rule.maxAmount != null ? 'Up to \$${rule.maxAmount}' : null),
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String?>(
                  key: const ValueKey('discount-scope'),
                  initialValue: _lineId,
                  decoration: const InputDecoration(labelText: 'On'),
                  items: [
                    if (rule.onCheck) const DropdownMenuItem<String?>(value: null, child: Text('The whole check')),
                    if (rule.onLines)
                      for (final line in widget.lines)
                        DropdownMenuItem<String?>(
                          value: line.lineId,
                          child: Text('${line.qty}× ${line.name}', overflow: TextOverflow.ellipsis),
                        ),
                  ],
                  onChanged: (id) => setState(() => _lineId = id),
                ),
                const SizedBox(height: 10),
                TextField(
                  key: const ValueKey('discount-note'),
                  controller: _note,
                  decoration: const InputDecoration(labelText: 'Note (optional)'),
                ),
                if (stacked)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(
                      'This check already has a discount; ${rule.name} cannot go on the same items.',
                      style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
                    ),
                  ),
                if (rule.needsManager)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(
                      'A manager puts in their PIN next.',
                      style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ),
              ],
              if (widget.rules.manualCharges.isNotEmpty) ...[
                const SizedBox(height: 18),
                Text('Add a charge', style: theme.textTheme.labelLarge),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    for (final c in widget.rules.manualCharges)
                      ActionChip(
                        key: ValueKey('charge:${c.code}'),
                        label: Text(c.label),
                        onPressed: () => Navigator.of(context)
                            .pop(Adjustment(op: 'charge', data: {'code': c.code}, needsManager: false, label: c.name)),
                      ),
                  ],
                ),
              ],
              if (widget.taxExempt) ...[
                const SizedBox(height: 18),
                Text('Sales tax', style: theme.textTheme.labelLarge),
                const SizedBox(height: 6),
                ActionChip(
                  key: const ValueKey('tax-exempt'),
                  avatar: const Icon(Icons.lock_outline, size: 16),
                  label: const Text('Tax exempt'),
                  onPressed: () => Navigator.of(context).pop(
                    const Adjustment(op: DiscountSheet.exemptOp, data: {}, needsManager: true, label: 'Tax exempt'),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              LayoutBuilder(
                builder: (context, box) {
                  final why = rule != null && problem != null
                      ? Text(problem, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant))
                      : null;
                  final cancel = TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel'));
                  final apply = FilledButton(
                    key: const ValueKey('discount-apply'),
                    onPressed: problem == null ? _apply : null,
                    child: Text(rule?.needsManager ?? false ? 'Manager PIN' : 'Apply'),
                  );
                  // a small phone has no room for the reason beside the buttons, nor always for both buttons
                  if (box.maxWidth < 280) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        ?why,
                        if (why != null) const SizedBox(height: 8),
                        OverflowBar(
                          alignment: MainAxisAlignment.end,
                          overflowAlignment: OverflowBarAlignment.end,
                          spacing: 8,
                          overflowSpacing: 4,
                          children: [cancel, apply],
                        ),
                      ],
                    );
                  }
                  return Row(
                    children: [
                      if (why != null) Expanded(child: why) else const Spacer(),
                      cancel,
                      const SizedBox(width: 8),
                      apply,
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A manager's PIN on the spot, for one discount or charge on one order (`POST /approvals`). Pops the
/// approval token the operation carries; the hub records who the manager was, never the token.
class ApprovalDialog extends StatefulWidget {
  const ApprovalDialog({
    super.key,
    required this.api,
    required this.device,
    required this.orderId,
    required this.what,
    this.purpose = 'adjust',
  });

  final PosApi api;
  final String device;
  final String orderId;
  final String what;

  /// What the PIN is for on this order: a discount or a charge (`adjust`), a void of a sent dish (`void`), or
  /// marking the check tax exempt (`exempt`). The hub takes an approval for the one thing only.
  final String purpose;

  @override
  State<ApprovalDialog> createState() => _ApprovalDialogState();
}

class _ApprovalDialogState extends State<ApprovalDialog> {
  final _pin = TextEditingController();
  String? _message;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    FaceSignIn.hold(); // the manager leaning in to type is approving, not taking the screen over
  }

  @override
  void dispose() {
    FaceSignIn.release();
    _pin.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy || _pin.text.isEmpty) return;
    setState(() => _busy = true);
    try {
      final json = await widget.api.approve(
        device: widget.device,
        pin: _pin.text,
        orderId: widget.orderId,
        purpose: widget.purpose,
      );
      if (mounted) Navigator.of(context).pop(json['approval'] as String);
    } on ApiException catch (err) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _pin.clear();
        _message = switch (err.status) {
          401 => 'Wrong PIN',
          403 => 'Only a manager can approve this',
          423 => 'Too many tries. Wait a minute.',
          _ => err.message,
        };
      });
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Manager PIN'),
    content: SizedBox(
      width: 280,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${widget.what} needs a manager.'),
          const SizedBox(height: 10),
          TextField(
            key: const ValueKey('approval-pin'),
            controller: _pin,
            autofocus: true,
            obscureText: true,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(labelText: 'PIN', errorText: _message),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
      FilledButton(key: const ValueKey('approve'), onPressed: _busy ? null : _submit, child: const Text('Approve')),
    ],
  );
}
