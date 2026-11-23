import 'package:flutter/material.dart';

/// A tag a guest carries ("VIP"), as a small label: under their name in the guest list, beside what the
/// restaurant knows of them where their call and their order are taken, and at the host stand on the call
/// that rings, on their reservation and on their party on the waitlist (docs/guest-list.md, "Tags and the
/// note" and "Where the tags show").
class GuestTagMark extends StatelessWidget {
  const GuestTagMark(this.tag, {super.key});

  final String tag;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(color: scheme.secondaryContainer, borderRadius: BorderRadius.circular(4)),
      child: Text(tag, style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSecondaryContainer)),
    );
  }
}
