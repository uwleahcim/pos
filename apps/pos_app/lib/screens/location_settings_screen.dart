import 'package:flutter/material.dart';

import '../api.dart';
import '../coursing.dart';
import '../takeout.dart';
import 'quotes_dialog.dart';

/// What a manager sets for the whole location, for every terminal: whether dishes are coursed, the courses
/// by name in kitchen order (as many as the kitchen serves) and where a new dish goes, and the quote times.
/// The hub keeps them; a terminal reads them when it opens an order. Behind the manager PIN.
class LocationSettingsScreen extends StatefulWidget {
  const LocationSettingsScreen({super.key, required this.api, required this.token});

  final PosApi api;
  final String token;

  @override
  State<LocationSettingsScreen> createState() => _LocationSettingsScreenState();
}

/// One course as the screen edits it: its id once the hub has it, a key for the row either way.
class _Row {
  _Row(this.key, {this.id, required String name}) : controller = TextEditingController(text: name);
  final String key;
  final String? id;
  final TextEditingController controller;
  String get name => controller.text.trim();
}

class _LocationSettingsScreenState extends State<LocationSettingsScreen> {
  Coursing? _coursing;
  Quotes? _quotes;
  String? _loadError;
  bool _enabled = true;
  List<_Row> _rows = [];
  String? _defaultKey;
  int _added = 0;
  String? _message;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final row in _rows) {
      row.controller.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loadError = null);
    try {
      final coursing = await widget.api.coursing();
      final quotes = await widget.api.quotes();
      if (!mounted) return;
      setState(() {
        _quotes = quotes;
        _apply(coursing);
      });
    } on ApiException catch (err) {
      if (mounted) setState(() => _loadError = err.message);
    }
  }

  /// The screen as the hub has it; rows get the ids the hub gave them.
  void _apply(Coursing coursing) {
    for (final row in _rows) {
      row.controller.dispose();
    }
    _coursing = coursing;
    _enabled = coursing.enabled;
    _rows = [for (final c in coursing.courses) _Row(c.id, id: c.id, name: c.name)];
    _defaultKey = coursing.defaultCourse;
  }

  void _add() => setState(() {
    final row = _Row('new-${++_added}', name: '');
    _rows.add(row);
    _defaultKey ??= row.key;
  });

  void _remove(_Row row) => setState(() {
    _rows.remove(row);
    row.controller.dispose();
    if (_defaultKey == row.key) _defaultKey = _rows.firstOrNull?.key;
  });

  void _reorder(int from, int to) => setState(() => _rows.insert(to, _rows.removeAt(from)));

  Future<void> _save() async {
    if (_rows.any((r) => r.name.isEmpty)) {
      setState(() => _message = 'Every course needs a name.');
      return;
    }
    if (_enabled && _rows.isEmpty) {
      setState(() => _message = 'Coursing needs at least one course, or turn it off.');
      return;
    }
    // A course from the hub keeps its id; a new one gets one from its name, unique among the rest.
    final taken = {for (final r in _rows) ?r.id};
    final courses = <Course>[];
    String? defaultId;
    for (final row in _rows) {
      final id = row.id ?? newCourseId(row.name, taken);
      taken.add(id);
      courses.add(Course(id, row.name));
      if (row.key == _defaultKey) defaultId = id;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final saved = await widget.api.saveCoursing(
        widget.token,
        Coursing(enabled: _enabled, defaultCourse: defaultId ?? courses.firstOrNull?.id, courses: courses),
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _apply(saved);
      });
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Courses saved')));
    } on ApiException catch (err) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _message = err.detail?['message'] as String? ?? err.message;
      });
    }
  }

  Future<void> _quoteTimes() async {
    final saved = await showDialog<Quotes>(
      context: context,
      builder: (_) => QuotesDialog(api: widget.api, token: widget.token, quotes: _quotes ?? const Quotes()),
    );
    if (saved == null || !mounted) return;
    setState(() => _quotes = saved);
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Quote times saved')));
  }

  String get _quotesSummary {
    final quotes = _quotes;
    if (quotes == null) return 'Loading…';
    return '${[
      for (final c in const ['counter', 'phone', 'online', 'delivery']) '${channelLabel(c)} ${quotes.minutesFor(c)}',
    ].join(' · ')} min';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final Widget body;
    if (_loadError != null) {
      body = Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_loadError!, style: TextStyle(color: scheme.error)),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: _load, child: const Text('Try again')),
          ],
        ),
      );
    } else if (_coursing == null) {
      body = const Center(child: CircularProgressIndicator());
    } else {
      body = ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SwitchListTile(
                    key: const ValueKey('coursing-enabled'),
                    value: _enabled,
                    onChanged: (on) => setState(() => _enabled = on),
                    title: const Text('Course the dishes'),
                    subtitle: Text(
                      _enabled
                          ? 'Each dish goes to a course that is held and fired on its own'
                          : 'Every dish is sent together; the order screen shows no courses',
                    ),
                  ),
                  if (_enabled) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                      child: Text(
                        'In the order the kitchen serves them. The star marks where a new dish goes.',
                        style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ),
                    ReorderableListView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      buildDefaultDragHandles: false,
                      itemCount: _rows.length,
                      onReorderItem: _reorder,
                      itemBuilder: (context, i) => _courseRow(context, i),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          key: const ValueKey('course-add'),
                          onPressed: _add,
                          icon: const Icon(Icons.add),
                          label: const Text('Add course'),
                        ),
                      ),
                    ),
                  ],
                  if (_message != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                      child: Text(_message!, style: TextStyle(color: scheme.error)),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        FilledButton(
                          key: const ValueKey('coursing-save'),
                          onPressed: _busy ? null : _save,
                          child: const Text('Save'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: ListTile(
              key: const ValueKey('quote-times'),
              leading: const Icon(Icons.timer_outlined),
              title: const Text('Quote times'),
              subtitle: Text(_quotesSummary),
              trailing: const Icon(Icons.chevron_right),
              onTap: _quoteTimes,
            ),
          ),
        ],
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Location settings')),
      body: Center(
        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 640), child: body),
      ),
    );
  }

  /// A course: the handle to move it, its name, the star for the default, and the bin.
  Widget _courseRow(BuildContext context, int i) {
    final row = _rows[i];
    final scheme = Theme.of(context).colorScheme;
    final isDefault = row.key == _defaultKey;
    return Padding(
      key: ValueKey('course:${row.key}'),
      padding: const EdgeInsets.fromLTRB(8, 2, 8, 2),
      child: Row(
        children: [
          ReorderableDragStartListener(
            index: i,
            child: Padding(
              key: ValueKey('course-handle:${row.key}'),
              padding: const EdgeInsets.all(10),
              child: Icon(Icons.drag_handle, color: scheme.onSurfaceVariant),
            ),
          ),
          Expanded(
            child: TextField(
              key: ValueKey('course-name:${row.key}'),
              controller: row.controller,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(isDense: true, hintText: 'Course name'),
            ),
          ),
          IconButton(
            key: ValueKey('course-default:${row.key}'),
            tooltip: 'Where a new dish goes',
            icon: Icon(isDefault ? Icons.star : Icons.star_border, color: isDefault ? scheme.primary : null),
            onPressed: () => setState(() => _defaultKey = row.key),
          ),
          IconButton(
            key: ValueKey('course-delete:${row.key}'),
            tooltip: 'Remove',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _remove(row),
          ),
        ],
      ),
    );
  }
}
