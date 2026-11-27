import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api.dart';
import '../live.dart';
import '../print_log.dart';
import 'paper_view.dart';

/// The print log, for a manager: every paper the hub made, newest first, with the printer it was for and
/// how it ended (printed, printed at another printer, still being tried and why, never printed). A tap on
/// a print opens its paper on the screen as it came out, with what happened to it line by line; the button
/// in the bar shows every paper at once, one under the other, like the roll in the kitchen. Any of them
/// prints again with Reprint, at its own printer or at another; the paper that comes out is headed REPRINT
/// and the log lists it as one.
///
/// The log is read by printer, by type (the kitchen's tickets, the bar's, the bills, the reprints, the
/// rest: the hub says which this restaurant has) and by the prints with a problem, and it is searched from
/// the bar: the hub looks for the words on the papers themselves, and says which line it found them on.
///
/// The hub keeps the log and decides everything in it (docs/printing.md, "The print log"); this screen
/// reads it, and reads it again when the hub says a print was made, failed or came out. Behind the manager
/// PIN, from Location settings › Printers.
class PrintLogScreen extends StatefulWidget {
  const PrintLogScreen({super.key, required this.api, required this.token, this.printer, this.now});

  final PosApi api;
  final String token;

  /// The printer whose prints the log opens on, by its id; every printer's without.
  final String? printer;

  /// What time it is, for "Today" and "Yesterday"; the device's clock when left out.
  final DateTime Function()? now;

  @override
  State<PrintLogScreen> createState() => _PrintLogScreenState();
}

class _PrintLogScreenState extends State<PrintLogScreen> {
  static const _page = 50;

  List<PrintEntry> _prints = const [];
  List<LogPrinter> _printers = const [];
  String? _next; // where the prints older than the ones shown start; null at the end of the log
  int _keeps = 14;
  late String? _printer = widget.printer;
  bool _trouble = false;
  String? _type; // one of [_types]; every type without
  String _q = ''; // what the log is searched for; nothing is no search
  List<String>? _types; // the types the hub reads its log by; null until it says, and from a hub older than them
  bool _searching = false; // the bar shows the box to type a search in
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  Timer? _typing;
  bool _everyPaper = false; // every print shows its paper, not only the ones opened
  final _open = <String>{};
  final _papers = <String, PrintPaper>{}; // by [_paperKey]: a paper never changes once it is out
  final _paperErrors = <String, String>{};
  final _asking = <String>{};
  final _sending = <String>{}; // the prints a reprint is being asked for
  final _problems = <String, String>{}; // why a reprint was not made, by print
  bool _read = false; // the hub answered once
  bool _old = false; // a hub from before the log
  bool _away = false; // the last read got no answer
  String? _refused; // the hub would not show the log, and why
  bool _more = false; // older prints are being read
  String _shown = ''; // what the last read said, in short: the same again draws nothing
  late final _poll = SafetyPoll(widget.api.live);
  late final _reader = Paced(const Duration(seconds: 1), _load);
  StreamSubscription<LiveChange>? _live;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!_old && _poll.due()) unawaited(_reader.now(must: false));
    });
    _live = widget.api.live.changes.listen((change) {
      if (!_old && (change.prints || change.everything)) _reader();
    });
    unawaited(_reader.now());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _typing?.cancel();
    unawaited(_live?.cancel());
    _reader.cancel();
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  static bool _sortsAfter(PrintEntry entry, PrintEntry other) =>
      entry.atMs < other.atMs || (entry.atMs == other.atMs && entry.jobId.compareTo(other.jobId) > 0);

  static String _mark(PrintLogPage page) => [
    for (final p in page.prints)
      '${p.jobId}|${p.status}|${p.tries}|${p.printedOn}|${p.reprints}|${p.events.length}|${p.found}',
    page.next ?? '',
    for (final p in page.printers) '${p.id}=${p.name}',
    page.types?.join(',') ?? '-',
  ].join('\n');

  /// Whether the log is still read the way it was when a read was sent: an answer to another question is
  /// not shown.
  bool _asksStill(String? printer, bool trouble, String? type, String q) =>
      printer == _printer && trouble == _trouble && type == _type && q == _q;

  /// Reads the newest prints. The older ones already on the screen stay under them.
  Future<void> _load() async {
    _poll.asked();
    final printer = _printer, trouble = _trouble, type = _type, q = _q;
    try {
      final page = await widget.api.printLog(
        widget.token,
        printer: printer,
        trouble: trouble,
        type: type,
        q: q,
        limit: _page,
      );
      if (!mounted || !_asksStill(printer, trouble, type, q)) return;
      if (page == null) return setState(() => _old = true);
      final mark = _mark(page);
      if (_read && !_away && _refused == null && mark == _shown) return;
      final newest = {for (final p in page.prints) p.jobId};
      final older = page.prints.isEmpty
          ? const <PrintEntry>[]
          : [
              for (final p in _prints)
                if (!newest.contains(p.jobId) && _sortsAfter(p, page.prints.last)) p,
            ];
      setState(() {
        _prints = [...page.prints, ...older];
        if (older.isEmpty) _next = page.next;
        _printers = page.printers;
        _keeps = page.keepsDays;
        _types = page.types;
        _shown = mark;
        _read = true;
        _away = false;
        _refused = null;
      });
    } on ApiException catch (err) {
      if (!mounted || !_asksStill(printer, trouble, type, q)) return;
      setState(() {
        _away = err.status == null;
        _refused = err.status == null ? null : _words(err);
      });
    }
  }

  /// The prints older than the ones shown.
  Future<void> _older() async {
    final from = _next;
    if (_more || from == null) return;
    final printer = _printer, trouble = _trouble, type = _type, q = _q;
    setState(() => _more = true);
    try {
      final page = await widget.api.printLog(
        widget.token,
        printer: printer,
        trouble: trouble,
        type: type,
        q: q,
        before: from,
        limit: _page,
      );
      if (!mounted || !_asksStill(printer, trouble, type, q)) return;
      final have = {for (final p in _prints) p.jobId};
      setState(() {
        _prints = [
          ..._prints,
          for (final p in page?.prints ?? const <PrintEntry>[])
            if (!have.contains(p.jobId)) p,
        ];
        _next = page?.next;
      });
    } on ApiException {
      // the button is still there to press again
    } finally {
      if (mounted) setState(() => _more = false);
    }
  }

  /// Reads the log another way: for one printer or all, the prints with a problem, one type or all
  /// ([type] with [typed]), searched for [q].
  void _show({String? printer, bool? trouble, bool allPrinters = false, String? type, bool typed = false, String? q}) {
    _typing?.cancel();
    setState(() {
      if (allPrinters) _printer = null;
      if (printer != null) _printer = printer;
      if (trouble != null) _trouble = trouble;
      if (typed) _type = type;
      if (q != null) _q = q;
      _prints = const [];
      _next = null;
      _read = false;
      _shown = '';
      _open.clear();
    });
    unawaited(_reader.now());
  }

  /// The box was typed in: the log is searched once the typing stops, not at every letter.
  void _typed(String text) {
    setState(() {}); // the button that empties the box
    _typing?.cancel();
    _typing = Timer(const Duration(milliseconds: 350), () => _find(text));
  }

  void _find(String text) {
    _typing?.cancel();
    final q = printSearch(text);
    if (q != _q) _show(q: q);
  }

  /// Opens the box to search in, or closes it: a closed box searches for nothing.
  void _searchOpen(bool open) {
    _typing?.cancel();
    setState(() => _searching = open);
    if (open) {
      _searchFocus.requestFocus();
    } else {
      _search.clear();
      if (_q.isNotEmpty) _show(q: '');
    }
  }

  /// Every print again, of the printer picked: no type, no search, not only the problems.
  void _everything() {
    _search.clear();
    setState(() => _searching = false);
    _show(trouble: false, typed: true, q: '');
  }

  static String _words(ApiException err) => switch (err.status) {
    null => 'The hub is not answering.',
    401 => 'The manager sign-in has run out. Go back and open the printers again.',
    403 => 'Only a manager reads the print log.',
    _ => err.detail?['message'] as String? ?? err.message,
  };

  /// A paper is asked for once: what came out does not change. One that went to a fallback printer after
  /// it was first looked at is another paper, since it then carries that printer's line.
  static String _paperKey(PrintEntry entry) => '${entry.jobId}|${entry.printedOn}';

  void _want(PrintEntry entry) {
    final key = _paperKey(entry);
    if (_papers.containsKey(key) || _asking.contains(key) || _paperErrors.containsKey(key)) return;
    _asking.add(key);
    unawaited(_readPaper(entry.jobId, key));
  }

  Future<void> _readPaper(String job, String key) async {
    try {
      final paper = await widget.api.printPaper(widget.token, job);
      if (!mounted) return;
      setState(() => _papers[key] = paper);
    } on ApiException catch (err) {
      if (!mounted) return;
      final gone = err.status == 404;
      setState(() => _paperErrors[key] = gone ? 'This paper is no longer in the log.' : _words(err));
    } finally {
      _asking.remove(key);
    }
  }

  Future<void> _reprint(PrintEntry entry, {LogPrinter? at}) async {
    if (_sending.contains(entry.jobId)) return;
    setState(() {
      _sending.add(entry.jobId);
      _problems.remove(entry.jobId);
    });
    try {
      final made = await widget.api.reprint(widget.token, entry.jobId, printer: at?.id);
      if (!mounted) return;
      final where = made.name.isNotEmpty ? made.name : (at?.name ?? 'the printer');
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('Reprint sent to $where')));
      unawaited(_reader.now());
    } on ApiException catch (err) {
      if (!mounted) return;
      final words = err.status == null ? 'The hub is not answering, so nothing was printed.' : _words(err);
      setState(() => _problems[entry.jobId] = words);
    } finally {
      if (mounted) setState(() => _sending.remove(entry.jobId));
    }
  }

  String _time(int ms) => TimeOfDay.fromDateTime(DateTime.fromMillisecondsSinceEpoch(ms)).format(context);

  static const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  static const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

  static String _date(DateTime day) => '${_weekdays[day.weekday - 1]} ${_months[day.month - 1]} ${day.day}';

  String _day(int ms) {
    final at = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = (widget.now ?? DateTime.now)();
    final days = DateTime(now.year, now.month, now.day).difference(DateTime(at.year, at.month, at.day)).inDays;
    return switch (days) {
      0 => 'Today',
      1 => 'Yesterday',
      _ => _date(at),
    };
  }

  @override
  Widget build(BuildContext context) {
    final Widget body;
    if (_old) {
      body = const _Says('This hub does not keep a print log yet. Update the hub.', key: ValueKey('log-old'));
    } else if (!_read) {
      final words = _refused ?? (_away ? 'The hub is not answering.' : null);
      body = words == null
          ? const Center(child: CircularProgressIndicator())
          : _Says(words, key: const ValueKey('log-away'), again: () => unawaited(_reader.now()));
    } else {
      body = _list(context);
    }
    return Scaffold(
      appBar: AppBar(
        title: _searching
            // Escape backs out of the search, like every level the keyboard is in
            ? CallbackShortcuts(
                bindings: {const SingleActivator(LogicalKeyboardKey.escape): () => _searchOpen(false)},
                child: TextField(
                  key: const ValueKey('log-search-box'),
                  controller: _search,
                  focusNode: _searchFocus,
                  textInputAction: TextInputAction.search,
                  inputFormatters: [LengthLimitingTextInputFormatter(100)], // as long as the hub reads
                  style: Theme.of(context).textTheme.titleMedium,
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: 'A dish, a table, a name',
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    suffixIconConstraints: const BoxConstraints(minWidth: 36, minHeight: 44),
                    suffixIcon: _search.text.isEmpty
                        ? null
                        : IconButton(
                            key: const ValueKey('log-search-clear'),
                            tooltip: 'Empty the search',
                            visualDensity: VisualDensity.compact,
                            icon: const Icon(Icons.clear, size: 18),
                            onPressed: () {
                              setState(_search.clear);
                              _find('');
                              _searchFocus.requestFocus();
                            },
                          ),
                  ),
                  onChanged: _typed,
                  onSubmitted: _find,
                ),
              )
            : const Text('Print log'),
        actions: [
          if (_types != null && !_old)
            IconButton(
              key: const ValueKey('log-search'),
              tooltip: _searching ? 'Close the search' : 'Search the prints',
              icon: Icon(_searching ? Icons.search_off : Icons.search),
              onPressed: () => _searchOpen(!_searching),
            ),
          IconButton(
            key: const ValueKey('log-papers'),
            tooltip: _everyPaper ? 'Show the list' : 'Show every paper',
            isSelected: _everyPaper,
            icon: const Icon(Icons.receipt_long_outlined),
            selectedIcon: const Icon(Icons.receipt_long),
            onPressed: _old ? null : () => setState(() => _everyPaper = !_everyPaper),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Column(
            children: [
              if (!_old) _filters(context),
              Expanded(child: body),
            ],
          ),
        ),
      ),
    );
  }

  /// Which printer's prints, and whether only the ones to look at: one line, on a phone too. Under it the
  /// types to read the log by, when the hub says them: one line as well, that slides sideways when the
  /// screen is narrower than its chips.
  Widget _filters(BuildContext context) {
    final types = _types;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _whose(context),
        if (types != null && types.isNotEmpty)
          SingleChildScrollView(
            key: const ValueKey('log-types'),
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Row(
              children: [
                for (final type in <String?>[null, ...types])
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      key: ValueKey('log-type:${type ?? 'all'}'),
                      label: Text(type == null ? 'All' : printTypeName(type)),
                      selected: _type == type,
                      showCheckmark: false,
                      visualDensity: VisualDensity.compact,
                      onSelected: (_) {
                        if (_type != type) _show(type: type, typed: true);
                      },
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _whose(BuildContext context) {
    final theme = Theme.of(context);
    final known = {for (final p in _printers) p.id};
    final picked = _printer;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Row(
        children: [
          Expanded(
            child: DropdownButton<String>(
              key: const ValueKey('log-printer'),
              isExpanded: true,
              isDense: true,
              underline: const SizedBox.shrink(),
              value: picked ?? '',
              style: theme.textTheme.titleSmall,
              items: [
                const DropdownMenuItem(
                  value: '',
                  child: Text('All printers', overflow: TextOverflow.ellipsis),
                ),
                for (final p in _printers)
                  DropdownMenuItem(
                    value: p.id,
                    child: Text(p.name.isEmpty ? p.id : p.name, overflow: TextOverflow.ellipsis),
                  ),
                // a printer that was taken off the list still has its prints
                if (picked != null && !known.contains(picked))
                  DropdownMenuItem(
                    value: picked,
                    child: Text(picked, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (id) {
                if (id == null || id == (picked ?? '')) return;
                id.isEmpty ? _show(allPrinters: true) : _show(printer: id);
              },
            ),
          ),
          const SizedBox(width: 8),
          FilterChip(
            key: const ValueKey('log-trouble'),
            label: const Text('Problems'),
            tooltip: 'Only the prints that did not come out, came out late, or came out at another printer',
            selected: _trouble,
            visualDensity: VisualDensity.compact,
            onSelected: (on) => _show(trouble: on),
          ),
        ],
      ),
    );
  }

  Widget _list(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    if (_prints.isEmpty) {
      final String words;
      if (_q.isNotEmpty || _type != null) {
        // "No bar tickets with a problem at this printer in the last 14 days have “duck” on them."
        final which = [
          'No ${printTypeThings(_type)}',
          if (_trouble) 'with a problem',
          if (_printer != null) 'at this printer',
          'in the last $_keeps days',
          if (_q.isNotEmpty) 'have “$_q” on them',
        ];
        words = '${which.join(' ')}.';
      } else {
        words = _trouble
            ? 'No problems in the last $_keeps days: every print came out at its own printer, first time.'
            : _printer != null
            ? 'Nothing was printed at this printer in the last $_keeps days.'
            : 'Nothing was printed in the last $_keeps days.';
      }
      return _Says(
        words,
        key: const ValueKey('log-none'),
        again: _q.isNotEmpty || _type != null ? _everything : null,
        againSays: 'Show all prints',
      );
    }
    // the rows of the list: a day's name where the day changes, then its prints, and what ends the list
    final rows = <Object>[];
    String? day;
    for (final entry in _prints) {
      final its = _day(entry.atMs);
      if (its != day) rows.add(day = its);
      rows.add(entry);
    }
    return ListView.builder(
      key: const ValueKey('log-list'),
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: rows.length + 1,
      itemBuilder: (context, i) {
        if (i == rows.length) return _foot(context);
        final row = rows[i];
        if (row is PrintEntry) return _print(context, row);
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
          child: Text('$row', style: theme.textTheme.labelLarge?.copyWith(color: scheme.onSurfaceVariant)),
        );
      },
    );
  }

  Widget _foot(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(
        children: [
          if (_away)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                'The hub is not answering. This is the log as it was last read.',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
              ),
            ),
          if (_next != null)
            TextButton.icon(
              key: const ValueKey('log-more'),
              onPressed: _more ? null : _older,
              icon: _more
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.expand_more),
              label: const Text('Older prints'),
            )
          else
            Text(
              'The log keeps the last $_keeps days.',
              key: const ValueKey('log-end'),
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          if (_types == null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Update the hub to read the log by kind of print and to search it.',
                key: const ValueKey('log-no-types'),
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
        ],
      ),
    );
  }

  /// The line of a paper a search found its words on, with the words it was searched for in bold.
  Widget _found(BuildContext context, PrintEntry entry) {
    final theme = Theme.of(context);
    final line = entry.found;
    final at = _q.isEmpty ? -1 : line.toLowerCase().indexOf(_q.toLowerCase());
    final hit = at >= 0 && at + _q.length <= line.length;
    const bold = TextStyle(fontWeight: FontWeight.w700);
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Text.rich(
        TextSpan(
          children: [
            const TextSpan(text: 'On the paper: '),
            if (hit) ...[
              TextSpan(text: line.substring(0, at)),
              TextSpan(text: line.substring(at, at + _q.length), style: bold),
              TextSpan(text: line.substring(at + _q.length)),
            ] else
              TextSpan(text: line),
          ],
        ),
        key: ValueKey('print-found:${entry.jobId}'),
        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurface),
      ),
    );
  }

  /// One print: its line in the log, and under it, when it is opened or every paper is shown, the paper.
  Widget _print(BuildContext context, PrintEntry entry) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final opened = _open.contains(entry.jobId);
    final shown = opened || _everyPaper;
    final failing = !entry.printed && (entry.lost || entry.tries > 0);
    final (icon, tint) = entry.printed
        ? (entry.trouble ? Icons.warning_amber_rounded : Icons.check_circle_outline, scheme.tertiary)
        : failing
        ? (Icons.error_outline, scheme.error)
        : (Icons.schedule, scheme.onSurfaceVariant);
    final where = entry.name.isEmpty ? entry.printer : entry.name;
    return Column(
      key: ValueKey('print:${entry.jobId}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          key: ValueKey('print-row:${entry.jobId}'),
          onTap: () => setState(() => opened ? _open.remove(entry.jobId) : _open.add(entry.jobId)),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Icon(icon, size: 20, color: tint, semanticLabel: entry.printed ? 'Printed' : 'Not printed'),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: '${_time(entry.atMs)}  ',
                              style: TextStyle(
                                color: scheme.onSurfaceVariant,
                                fontFeatures: const [FontFeature.tabularFigures()],
                              ),
                            ),
                            TextSpan(text: entry.line),
                          ],
                        ),
                        key: ValueKey('print-line:${entry.jobId}'),
                        style: theme.textTheme.titleSmall,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '$where · ${entry.outcome}',
                        key: ValueKey('print-outcome:${entry.jobId}'),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: failing ? scheme.error : scheme.onSurfaceVariant,
                        ),
                      ),
                      if (entry.found.isNotEmpty) _found(context, entry),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Icon(
                    opened ? Icons.expand_less : Icons.expand_more,
                    color: scheme.onSurfaceVariant,
                    semanticLabel: opened ? 'Close' : 'Open',
                  ),
                ),
              ],
            ),
          ),
        ),
        if (shown) _opened(context, entry, details: opened),
        Divider(height: 1, color: scheme.outlineVariant),
      ],
    );
  }

  /// Under a print's line: the paper, what happened to it (when the print itself was opened), and Reprint.
  Widget _opened(BuildContext context, PrintEntry entry, {required bool details}) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final key = _paperKey(entry);
    final paper = _papers[key];
    final failed = _paperErrors[key];
    if (paper == null && failed == null) _want(entry);
    final sending = _sending.contains(entry.jobId);
    final problem = _problems[entry.jobId];
    final others = [
      for (final p in _printers)
        if (p.id != entry.printer) p,
    ];
    final Widget sheet;
    if (paper != null) {
      sheet = PaperView(key: ValueKey('paper:${entry.jobId}'), pages: paper.pages);
    } else if (failed != null) {
      sheet = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(failed, style: theme.textTheme.bodySmall?.copyWith(color: scheme.error)),
          ),
          TextButton(onPressed: () => setState(() => _paperErrors.remove(key)), child: const Text('Try again')),
        ],
      );
    } else {
      sheet = const Padding(
        padding: EdgeInsets.all(24),
        child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    return Container(
      color: scheme.surfaceContainerLow,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(child: sheet),
          if (details) ...[const SizedBox(height: 12), _story(context, entry)],
          const SizedBox(height: 8),
          Wrap(
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 4,
            children: [
              FilledButton.tonalIcon(
                key: ValueKey('reprint:${entry.jobId}'),
                onPressed: sending ? null : () => _reprint(entry),
                icon: sending
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.print_outlined, size: 18),
                label: const Text('Reprint'),
              ),
              if (others.isNotEmpty)
                PopupMenuButton<LogPrinter>(
                  key: ValueKey('reprint-at:${entry.jobId}'),
                  tooltip: 'Reprint at another printer',
                  enabled: !sending,
                  onSelected: (printer) => _reprint(entry, at: printer),
                  itemBuilder: (context) => [
                    for (final p in others)
                      PopupMenuItem(
                        key: ValueKey('reprint-at:${entry.jobId}:${p.id}'),
                        value: p,
                        child: Text('Reprint at ${p.name.isEmpty ? p.id : p.name}'),
                      ),
                  ],
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            'At another printer',
                            style: theme.textTheme.labelLarge?.copyWith(color: scheme.primary),
                          ),
                        ),
                        Icon(Icons.arrow_drop_down, color: scheme.primary),
                      ],
                    ),
                  ),
                ),
            ],
          ),
          Text(
            problem ?? 'The paper comes out headed REPRINT.',
            key: ValueKey('reprint-note:${entry.jobId}'),
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(color: problem != null ? scheme.error : scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  /// What happened to a print, one thing a line, as the hub wrote it down.
  Widget _story(BuildContext context, PrintEntry entry) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final where = entry.name.isEmpty ? entry.printer : entry.name;
    final lines = <(int, String, bool)>[
      (entry.atMs, 'Sent to $where${entry.address.isEmpty ? '' : ' (${entry.address})'}', false),
      for (final e in entry.events)
        (
          e.ms,
          switch (e.what) {
            'failed' =>
              'Did not print: ${printerTrouble(e.text)}'
                  '${printerTrouble(e.text) == e.text ? '' : ' (${e.text})'}'
                  '${e.times > 1 ? ', ${e.times} times' : ''}',
            'moved' => 'Passed on to ${e.text}',
            'printed' => e.text.isEmpty ? 'Printed' : 'Printed at ${e.text}',
            'reprinted' => 'Printed again ${e.text}'.trim(),
            _ => e.text,
          },
          e.what == 'failed',
        ),
    ];
    final first = entry.firstMs;
    return Column(
      key: ValueKey('print-story:${entry.jobId}'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (entry.isReprint)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              [
                'A reprint',
                if (entry.by.isNotEmpty) ' asked for by ${entry.by}',
                if (first != null)
                  ' of the paper from ${_day(first) == 'Today' ? '' : '${_day(first)}, '}${_time(first)}',
                '.',
              ].join(),
              style: theme.textTheme.bodySmall,
            ),
          ),
        for (final (ms, words, bad) in lines)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 1),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 76,
                  child: Text(
                    _time(ms),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                Expanded(
                  child: Text(words, style: theme.textTheme.bodySmall?.copyWith(color: bad ? scheme.error : null)),
                ),
              ],
            ),
          ),
        if (entry.lost)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              'The hub restarted while it was still waiting, so it never came out. Reprint it if it is still wanted.',
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
            ),
          ),
      ],
    );
  }
}

/// A screen with one thing to say.
class _Says extends StatelessWidget {
  const _Says(this.words, {super.key, this.again, this.againSays = 'Try again'});

  final String words;
  final VoidCallback? again;
  final String againSays;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(words, textAlign: TextAlign.center, style: theme.textTheme.bodyMedium),
            if (again != null) ...[
              const SizedBox(height: 12),
              OutlinedButton(onPressed: again, child: Text(againSays)),
            ],
          ],
        ),
      ),
    );
  }
}
