import 'package:flutter/material.dart';

import '../menu.dart';

/// Who a tax-exempt check is for: the organisation and the number of its certificate of exemption, both
/// typed. The hub keeps them with the check, prints them on the bill and lists them in the day's report, so
/// neither can be left empty. Pops the two, trimmed; nothing when it was closed. A manager's PIN comes next.
class TaxExemptDialog extends StatefulWidget {
  const TaxExemptDialog({super.key});

  @override
  State<TaxExemptDialog> createState() => _TaxExemptDialogState();
}

class _TaxExemptDialogState extends State<TaxExemptDialog> {
  final _organisation = TextEditingController();
  final _certificate = TextEditingController();
  final _certificateFocus = FocusNode();

  @override
  void dispose() {
    _organisation.dispose();
    _certificate.dispose();
    _certificateFocus.dispose();
    super.dispose();
  }

  static String _words(String text) => text.trim().replaceAll(RegExp(r'\s+'), ' ');

  bool get _complete => _words(_organisation.text).isNotEmpty && _words(_certificate.text).isNotEmpty;

  void _done() {
    if (!_complete) return;
    Navigator.of(context).pop((organisation: _words(_organisation.text), certificate: _words(_certificate.text)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Tax exempt'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'No sales tax is charged on this check. Both are kept with it and print on the bill.',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('exempt-organisation'),
                controller: _organisation,
                autofocus: true,
                maxLength: TaxExempt.organisationMax,
                textCapitalization: TextCapitalization.words,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(labelText: 'Organisation', counterText: ''),
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _certificateFocus.requestFocus(),
              ),
              const SizedBox(height: 10),
              TextField(
                key: const ValueKey('exempt-certificate'),
                controller: _certificate,
                focusNode: _certificateFocus,
                maxLength: TaxExempt.certificateMax,
                textCapitalization: TextCapitalization.characters,
                textInputAction: TextInputAction.done,
                decoration: const InputDecoration(
                  labelText: 'Certificate number',
                  helperText: 'From their certificate of exemption.',
                  helperMaxLines: 2,
                  counterText: '',
                ),
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _done(),
              ),
              const SizedBox(height: 10),
              Text(
                'A manager puts in their PIN next.',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('exempt-next'),
          onPressed: _complete ? _done : null,
          child: const Text('Manager PIN'),
        ),
      ],
    );
  }
}
