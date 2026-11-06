import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../faces.dart';
import '../tags.dart';

/// A manager gives one staff member a tag: the person (or the manager) holds the badge to this screen's reader,
/// which types its id; or the id is typed in by hand. The hub keeps the id and refuses one that is already
/// someone else's. Pops the tag's last characters once kept, null when cancelled.
class TagEnrollDialog extends StatefulWidget {
  const TagEnrollDialog({
    super.key,
    required this.api,
    required this.token,
    required this.staff,
    required this.device,
    this.reader,
  });

  final PosApi api;
  final String token;
  final StaffEntry staff;
  final String device;

  /// This screen's reader; without one, the id is typed.
  final TagReader? reader;

  @override
  State<TagEnrollDialog> createState() => _TagEnrollDialogState();
}

class _TagEnrollDialogState extends State<TagEnrollDialog> {
  final _typed = TextEditingController();
  String? _error;
  bool _busy = false;
  bool _listening = false;

  @override
  void initState() {
    super.initState();
    _typed.addListener(() => setState(() {})); // the Save button follows the text
    _listen();
  }

  @override
  void dispose() {
    widget.reader?.cancel();
    _typed.dispose();
    super.dispose();
  }

  /// Waits for the reader's next tag, again after each miss, until the dialog goes.
  Future<void> _listen() async {
    final reader = widget.reader;
    if (reader == null || _listening) return;
    _listening = true;
    while (mounted) {
      final uid = await reader.next(timeout: const Duration(minutes: 5));
      if (!mounted) return;
      if (uid == null) continue;
      await _keep(uid);
      if (!mounted) return;
    }
  }

  Future<void> _keep(String uid) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final ends = await widget.api.setTag(widget.token, widget.staff.staffId, tagUid: uid, device: widget.device);
      if (mounted) Navigator.of(context).pop(ends);
    } on ApiException catch (err) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = switch (err.status) {
          409 => err.detail?['message'] as String? ?? 'That tag is someone else\'s',
          422 => 'That is not a tag id: 4 to 64 letters or digits',
          _ => err.message,
        };
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return AlertDialog(
      title: Text('A tag for ${widget.staff.name}'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                if (_busy)
                  const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.2))
                else
                  Icon(Icons.nfc, size: 28, color: scheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    widget.reader == null
                        ? 'This screen has no reader: type the id printed on the tag, or enroll from a screen with one.'
                        : 'Hold the tag to this screen\'s reader now.',
                    key: const ValueKey('tag-hint'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            TextField(
              key: const ValueKey('tag-typed'),
              controller: _typed,
              enabled: !_busy,
              autocorrect: false,
              decoration: const InputDecoration(
                isDense: true,
                labelText: 'Or type the tag\'s id',
                hintText: '04A2B3C4D5E6F7',
              ),
              onSubmitted: (_) => _keep(_typed.text.trim()),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(
                _error!,
                key: const ValueKey('tag-error'),
                style: TextStyle(color: scheme.error),
              ),
            ],
            const SizedBox(height: 8),
            Text(
              'The hub keeps the tag\'s id, nothing else; a tag is one person\'s at a time, and a new one replaces '
              'the old. With the location\'s hands-free switching on, a tag held to any terminal makes that screen '
              'the person\'s at once.',
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('tag-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('tag-save'),
          onPressed: _busy || _typed.text.trim().isEmpty ? null : () => _keep(_typed.text.trim()),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
