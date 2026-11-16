import 'package:flutter/material.dart';

/// The name a bar tab goes by: asked when the tab is opened, and again to change it. It is what the tab is
/// found by in the list of checks and what heads its tickets and its bill, so it cannot be left empty.
/// Pops the name, trimmed; nothing when it was closed.
class TabDialog extends StatefulWidget {
  const TabDialog({super.key, this.name = ''});

  /// The name the tab has now; empty for a new tab.
  final String name;

  /// The longest name a tab takes: a line of a ticket in big letters.
  static const maxLength = 24;

  @override
  State<TabDialog> createState() => _TabDialogState();
}

class _TabDialogState extends State<TabDialog> {
  late final _name = TextEditingController(text: widget.name);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  String get _typed => _name.text.trim().replaceAll(RegExp(r'\s+'), ' ');

  void _done() {
    final name = _typed;
    if (name.isEmpty) return;
    Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) {
    final renaming = widget.name.isNotEmpty;
    return AlertDialog(
      title: Text(renaming ? 'Name on the tab' : 'Open a tab'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: TextField(
          key: const ValueKey('tab-name'),
          controller: _name,
          autofocus: true,
          maxLength: TabDialog.maxLength,
          textCapitalization: TextCapitalization.words,
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(
            labelText: 'Name on the tab',
            helperText: renaming ? null : 'It stays at the bar until the party is given a table.',
            helperMaxLines: 2,
            counterText: '',
          ),
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _done(),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('tab-open'),
          onPressed: _typed.isEmpty ? null : _done,
          child: Text(renaming ? 'Save' : 'Open tab'),
        ),
      ],
    );
  }
}
