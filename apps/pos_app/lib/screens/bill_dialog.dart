import 'package:flutter/material.dart';

import '../api.dart';
import '../printers.dart';

/// The most lines the top or the foot of a bill takes, and the longest of them, as the hub holds them.
const maxBillLines = 8;
const maxBillLine = 64;

/// A box's text as the lines the hub keeps: an empty line between two others is a gap on the paper, the ones
/// at either end are dropped.
List<String> billLines(String text) {
  final lines = [for (final line in text.split('\n')) line.trim()];
  while (lines.isNotEmpty && lines.first.isEmpty) {
    lines.removeAt(0);
  }
  while (lines.isNotEmpty && lines.last.isEmpty) {
    lines.removeLast();
  }
  return lines;
}

/// The guest's bill as a manager sets it for the location: the printer bills come out of, the restaurant's own
/// lines at the top (the first prints big) and the lines that close it. A sample prints what is being tried
/// before any of it is saved. Saved on the hub, which prints every bill by it from the next one on.
class BillDialog extends StatefulWidget {
  const BillDialog({super.key, required this.api, required this.token, required this.bill});

  final PosApi api;
  final String token;
  final BillSettings bill;

  @override
  State<BillDialog> createState() => _BillDialogState();
}

class _BillDialogState extends State<BillDialog> {
  late String? _printer = widget.bill.chosen;
  late final _header = TextEditingController(text: widget.bill.header.join('\n'));
  late final _footer = TextEditingController(text: widget.bill.footer.join('\n'));
  String? _message;
  bool _wrong = false; // whether [_message] is a problem (red) or word of a sample on its way
  bool _busy = false;

  @override
  void dispose() {
    _header.dispose();
    _footer.dispose();
    super.dispose();
  }

  /// What is wrong with the lines as typed, in words; null when the hub will take them.
  String? _problem(List<String> header, List<String> footer) {
    for (final (what, lines) in [('top', header), ('foot', footer)]) {
      if (lines.length > maxBillLines) return 'The $what of the bill takes at most $maxBillLines lines';
      if (lines.any((line) => line.length > maxBillLine)) {
        return 'A line at the $what of the bill is at most $maxBillLine characters';
      }
    }
    return null;
  }

  Future<void> _run(Future<void> Function(List<String> header, List<String> footer) send) async {
    final header = billLines(_header.text);
    final footer = billLines(_footer.text);
    final problem = _problem(header, footer);
    if (problem != null) {
      setState(() {
        _message = problem;
        _wrong = true;
      });
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await send(header, footer);
    } on ApiException catch (err) {
      if (!mounted) return;
      setState(() {
        _message = err.detail?['message'] as String? ?? err.message;
        _wrong = true;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() => _run((header, footer) async {
    final saved = await widget.api.saveBillSettings(widget.token, printer: _printer, header: header, footer: footer);
    if (mounted) Navigator.of(context).pop(saved);
  });

  Future<void> _sample() => _run((header, footer) async {
    final at = await widget.api.printBillSample(widget.token, printer: _printer, header: header, footer: footer);
    if (!mounted) return;
    setState(() {
      _message = 'A sample is printing at ${at.isEmpty ? 'the printer' : at}. Nothing is saved yet.';
      _wrong = false;
    });
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final bill = widget.bill;
    final usual = bill.nameOf(bill.usual);
    final hint = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    return AlertDialog(
      title: const Text('The bill'),
      contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (bill.printers.isEmpty)
                Text(
                  'No printer is set up yet, so no bill can print. Add one under Printers.',
                  style: TextStyle(color: scheme.error),
                )
              else
                DropdownButtonFormField<String?>(
                  key: const ValueKey('bill-printer'),
                  initialValue: _printer,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Bills print at', isDense: true),
                  items: [
                    DropdownMenuItem(value: null, child: Text(usual == null ? 'The usual printer' : '$usual (usual)')),
                    for (final p in bill.printers) DropdownMenuItem(value: p.id, child: Text(p.name)),
                  ],
                  onChanged: _busy ? null : (id) => setState(() => _printer = id),
                ),
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'A screen can keep a printer of its own for its bills: hold the Bill button on a check there.',
                  style: hint,
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                key: const ValueKey('bill-header'),
                controller: _header,
                minLines: 3,
                maxLines: maxBillLines,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'Top of the bill',
                  alignLabelWithHint: true,
                  hintText: 'Restaurant name\nAddress\nPhone',
                  helperText: 'One line each. The first line prints big.',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                key: const ValueKey('bill-footer'),
                controller: _footer,
                minLines: 2,
                maxLines: maxBillLines,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Foot of the bill',
                  alignLabelWithHint: true,
                  hintText: 'Thank you!',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              if (_message != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _message!,
                    key: const ValueKey('bill-message'),
                    style: TextStyle(color: _wrong ? scheme.error : scheme.onSurfaceVariant),
                  ),
                ),
            ],
          ),
        ),
      ),
      actionsOverflowButtonSpacing: 4,
      actions: [
        TextButton.icon(
          key: const ValueKey('bill-sample'),
          onPressed: _busy || bill.printers.isEmpty ? null : _sample,
          icon: const Icon(Icons.print_outlined),
          label: const Text('Print a sample'),
        ),
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(key: const ValueKey('bill-save'), onPressed: _busy ? null : _save, child: const Text('Save')),
      ],
    );
  }
}
