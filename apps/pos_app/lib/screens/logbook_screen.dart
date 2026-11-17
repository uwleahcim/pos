import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../shift_notes.dart';
import '../takeout.dart' show clockTime;
import 'span_report.dart' show reportError;

/// What a manager typed for the log: what it is about, and the words.
typedef LogDraft = ({String subject, String text});

/// The manager's log (docs/shift-notes.md): what happened in a shift that the next manager should know,
/// each entry under one subject. The newest entry is first, under the day of service it was written in. A
/// subject's chip narrows the log to it, and the box finds the entries holding every word typed, in the
/// whole log, not only the page that is read. An entry is never changed or deleted: a mistaken one is
/// struck out, and stays readable. Everything here is behind the manager's session.
class LogbookScreen extends StatefulWidget {
  const LogbookScreen({super.key, required this.api, required this.token, required this.device, this.now});

  final PosApi api;

  /// The manager's session (`POST /admin/session`): every call here carries it.
  final String token;
  final String device;

  /// The clock the days are worded against; the terminal's own when left out.
  final DateTime Function()? now;

  @override
  State<LogbookScreen> createState() => _LogbookScreenState();
}

class _LogbookScreenState extends State<LogbookScreen> {
  /// The last reading: its subjects and their counts stand over the list.
  Logbook? _log;
  List<LogEntry> _entries = const [];
  bool _more = false;
  bool _reading = false; // older entries are being read
  String? _subject;
  String? _error;
  int _asked = 0;
  final _find = TextEditingController();
  Timer? _typing;

  DateTime get _now => widget.now?.call() ?? DateTime.now();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _typing?.cancel();
    _find.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final ask = ++_asked;
    setState(() => _error = null);
    try {
      final log = await widget.api.logbook(widget.token, subject: _subject, find: _find.text);
      if (!mounted || ask != _asked) return;
      setState(() {
        _log = log;
        _entries = log.entries;
        _more = log.more;
        _reading = false;
      });
    } on ApiException catch (err) {
      if (!mounted || ask != _asked) return;
      setState(() => _error = reportError(err, "the manager's log"));
    }
  }

  /// The page before the last entry shown.
  Future<void> _older() async {
    if (_reading || _entries.isEmpty) return;
    final ask = _asked;
    setState(() => _reading = true);
    try {
      final log = await widget.api.logbook(widget.token, subject: _subject, find: _find.text, before: _entries.last.id);
      if (!mounted || ask != _asked) return; // another subject or search was picked meanwhile
      setState(() {
        _entries = [..._entries, ...log.entries];
        _more = log.more;
        _reading = false;
      });
    } on ApiException catch (err) {
      if (!mounted || ask != _asked) return;
      setState(() => _reading = false);
      _say(reportError(err, "the manager's log"));
    }
  }

  void _say(String words, {String? key}) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.hideCurrentSnackBar();
    messenger?.showSnackBar(SnackBar(key: key == null ? null : ValueKey(key), content: Text(words)));
  }

  void _pick(String? subject) {
    if (subject == _subject) return;
    setState(() => _subject = subject);
    _load();
  }

  /// The search waits for the typing to stop, so each letter is not a call to the hub.
  void _typed(String _) {
    setState(() {}); // the clear button
    _typing?.cancel();
    _typing = Timer(const Duration(milliseconds: 350), _load);
  }

  Future<void> _write() async {
    final log = _log;
    if (log == null) return;
    final typed = await showDialog<LogDraft>(
      context: context,
      builder: (_) => LogEntryDialog(subjects: log.subjects, subject: _subject, textMax: log.textMax),
    );
    if (typed == null || !mounted) return;
    try {
      await widget.api.writeLogEntry(widget.token, subject: typed.subject, text: typed.text, device: widget.device);
      if (!mounted) return;
      _say('Written in the log.', key: 'log-written');
    } on ApiException catch (err) {
      if (!mounted) return;
      _say(reportError(err, "the manager's log"), key: 'log-refused');
    }
    if (mounted) await _load();
  }

  Future<void> _strike(LogEntry entry) async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        title: const Text('Strike this entry out?'),
        content: const Text(
          'It stays in the log, crossed out, with your name and the time. Nothing in the log is deleted.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Leave it')),
          FilledButton(
            key: const ValueKey('log-strike-sure'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Strike out'),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    try {
      await widget.api.strikeLogEntry(widget.token, entry.id);
    } on ApiException catch (err) {
      if (!mounted) return;
      _say(reportError(err, "the manager's log"), key: 'log-refused');
    }
    if (mounted) await _load();
  }

  Widget _head(BuildContext context, Logbook log) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final finding = _find.text.trim().isNotEmpty;
    Widget chip(String? id, String name, int count) => ChoiceChip(
      key: ValueKey('log-of:${id ?? 'all'}'),
      label: Text('$name $count'),
      selected: _subject == id,
      onSelected: (_) => _pick(id),
    );
    final shown = _entries.length;
    final String told;
    if (shown == 0) {
      told = finding
          ? 'No entry holds that.'
          : _subject == null
          ? 'Nothing is written yet. Write what the next manager should know.'
          : 'No entry under this subject.';
    } else {
      told = finding ? 'Entries holding every word, the newest first.' : 'The newest first.';
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            chip(null, 'All', log.count),
            // a subject nothing is written under takes no room, unless it is the one being read
            for (final subject in log.subjects)
              if (subject.count > 0 || subject.id == _subject) chip(subject.id, subject.name, subject.count),
          ],
        ),
        const SizedBox(height: 8),
        TextField(
          key: const ValueKey('log-find'),
          controller: _find,
          textInputAction: TextInputAction.search,
          style: theme.textTheme.bodyMedium,
          decoration: InputDecoration(
            isDense: true,
            hintText: 'Find a word or a name',
            prefixIcon: const Icon(Icons.search, size: 18),
            prefixIconConstraints: const BoxConstraints(minWidth: 36, minHeight: 44),
            suffixIconConstraints: const BoxConstraints(minWidth: 36, minHeight: 44),
            contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
            border: const OutlineInputBorder(),
            suffixIcon: _find.text.isEmpty
                ? null
                : IconButton(
                    key: const ValueKey('log-find-clear'),
                    tooltip: 'Every entry again',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.clear, size: 18),
                    onPressed: () {
                      _typing?.cancel();
                      setState(_find.clear);
                      _load();
                    },
                  ),
          ),
          onChanged: _typed,
          onSubmitted: (_) {
            _typing?.cancel();
            _load();
          },
        ),
        Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 2),
          child: Text(told, key: const ValueKey('log-told'), style: small),
        ),
      ],
    );
  }

  Widget _entry(BuildContext context, LogEntry entry, DateTime now) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final grey = scheme.onSurfaceVariant;
    final struck = entry.struck;
    return Padding(
      key: ValueKey('log:${entry.id}'),
      padding: const EdgeInsets.only(top: 6, bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  [entry.subjectName, clockTime(entry.atMs), if (entry.by.isNotEmpty) entry.by].join(' · '),
                  style: theme.textTheme.labelMedium?.copyWith(color: struck ? grey : scheme.primary),
                ),
                const SizedBox(height: 2),
                Text(
                  entry.text,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: struck ? grey : scheme.onSurface,
                    decoration: struck ? TextDecoration.lineThrough : null,
                  ),
                ),
                if (struck)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      [
                        'Struck out',
                        if (entry.struckBy.isNotEmpty) 'by ${entry.struckBy},',
                        whenWords(entry.struckMs!, now),
                      ].join(' '),
                      style: theme.textTheme.bodySmall?.copyWith(color: grey),
                    ),
                  ),
              ],
            ),
          ),
          if (!struck)
            IconButton(
              key: ValueKey('log-strike:${entry.id}'),
              tooltip: 'Strike out',
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.format_strikethrough, size: 20, color: grey),
              onPressed: () => _strike(entry),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final log = _log;
    final Widget body;
    if (log == null) {
      body = _error == null
          ? const Center(child: CircularProgressIndicator())
          : Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_error!, key: const ValueKey('log-error'), textAlign: TextAlign.center),
                    const SizedBox(height: 12),
                    OutlinedButton(onPressed: _load, child: const Text('Try again')),
                  ],
                ),
              ),
            );
    } else {
      final now = _now;
      // the day of service the hub's clock is in: an entry after midnight is still last night's
      final today = now.subtract(const Duration(hours: 4));
      final rows = <Widget>[
        _head(context, log),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(_error!, key: const ValueKey('log-error'), style: theme.textTheme.bodySmall),
          ),
      ];
      String? day;
      for (final entry in _entries) {
        if (entry.day != day) {
          day = entry.day;
          rows.add(
            Padding(
              key: ValueKey('log-day:$day'),
              padding: const EdgeInsets.only(top: 12),
              child: Text(logDayWords(entry.day, today), style: theme.textTheme.titleSmall),
            ),
          );
          rows.add(const Divider(height: 10));
        }
        rows.add(_entry(context, entry, now));
      }
      if (_more) {
        rows.add(
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Align(
              child: OutlinedButton(
                key: const ValueKey('log-older'),
                onPressed: _reading ? null : _older,
                child: Text(_reading ? 'Reading…' : 'Older entries'),
              ),
            ),
          ),
        );
      }
      body = ListView(
        key: const ValueKey('log-list'),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        children: rows,
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text("Manager's log")),
      body: body,
      bottomNavigationBar: log == null
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: FilledButton.icon(
                  key: const ValueKey('log-write'),
                  onPressed: _write,
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text('Write in the log'),
                ),
              ),
            ),
    );
  }
}

/// A new entry of the manager's log: what it is about (one of the hub's subjects) and the words. Pops a
/// [LogDraft], or nothing when it was closed.
class LogEntryDialog extends StatefulWidget {
  const LogEntryDialog({super.key, required this.subjects, this.subject, this.textMax = 2000});

  final List<LogSubject> subjects;

  /// The subject the log was narrowed to: the entry starts under it.
  final String? subject;
  final int textMax;

  @override
  State<LogEntryDialog> createState() => _LogEntryDialogState();
}

class _LogEntryDialogState extends State<LogEntryDialog> {
  final _text = TextEditingController();
  late String? _subject = widget.subject;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  bool get _ok => _subject != null && _text.text.trim().isNotEmpty;

  void _done() {
    if (_ok) Navigator.of(context).pop((subject: _subject!, text: _text.text.trim()));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24), // a phone keeps its width
      title: const Text('Write in the log'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('What is it about?', style: theme.textTheme.labelLarge),
              const SizedBox(height: 4),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final subject in widget.subjects)
                    ChoiceChip(
                      key: ValueKey('log-subject:${subject.id}'),
                      label: Text(subject.name),
                      selected: _subject == subject.id,
                      onSelected: (_) => setState(() => _subject = subject.id),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              TextField(
                key: const ValueKey('log-text'),
                controller: _text,
                autofocus: true,
                minLines: 4,
                maxLines: 10,
                maxLength: widget.textMax,
                keyboardType: TextInputType.multiline,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  hintText: 'What happened, and what the next manager should know',
                  hintMaxLines: 2,
                  border: OutlineInputBorder(),
                ),
                onChanged: (_) => setState(() {}),
              ),
              Text('An entry cannot be changed later, only struck out.', style: small),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(key: const ValueKey('log-save'), onPressed: _ok ? _done : null, child: const Text('Write it')),
      ],
    );
  }
}
