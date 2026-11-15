import 'package:flutter/material.dart';

import '../voids.dart';
import 'menu_panel.dart' show ChoiceGrid, ChoiceTile;

/// Why a dish the kitchen already has is coming off: the location's reasons as buttons, laid out like a
/// dish's choices. A tap on a reason is the operator's word for the void, so nothing more is asked here
/// (a manager's PIN comes after, where the location wants one). "Keep it" walks away, and the keyboard's
/// focus starts there: Enter never voids a dish by accident.
class VoidDialog extends StatelessWidget {
  const VoidDialog({super.key, required this.title, required this.body, required this.reasons});

  final String title;
  final String body;
  final List<VoidReason> reasons;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(title),
      contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(body),
              const SizedBox(height: 12),
              Text('Why?', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              ChoiceGrid(
                children: [
                  for (final reason in reasons)
                    ChoiceTile(
                      key: ValueKey('void-reason:${reason.id}'),
                      groupLabel: 'Void',
                      name: reason.name,
                      available: true,
                      selected: false,
                      onTap: () => Navigator.of(context).pop(reason),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(autofocus: true, onPressed: () => Navigator.of(context).pop(), child: const Text('Keep it')),
      ],
    );
  }
}
