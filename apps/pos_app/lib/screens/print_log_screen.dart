import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api.dart';
import '../live.dart';
import '../paper_shelf.dart';
import '../print_log.dart';
import 'compact.dart';
import 'paper_view.dart';

/// The print log, for a manager: every paper the hub made, newest first, with the printer it was for and
/// how it ended (printed, printed at another printer, still being tried and why, never printed). A tap on
/// a print opens its paper on the screen as it came out, with what happened to it line by line, and
/// another tap closes it; **Expand all** in the bar opens every print at once, one paper under the other
/// like the roll in the kitchen, the ones listed later as well, and **Collapse all** closes them all. Any
/// of them prints again with Reprint, at its own printer or at another; the paper that comes out is headed
/// REPRINT and the log lists it as one.
///
/// The log is read by printer, by type (the kitchen's tickets, the bar's, the bills, the reprints, the
/// rest: the hub says which this restaurant has) and by the prints with a problem, and it is searched from
/// the bar: the hub looks for the words on the papers themselves, and says which line it found them on.
/// The words are marked where a print has them: in its line of the log and on its paper ([PrintFind]).
///
/// With every print open the list is still built a screenful at a time. The papers are read a few at a
/// time, the ones ahead in the list before they are scrolled to ([PaperShelf]); a paper that arrives draws
/// its own print again and nothing else, and a paper is drawn once however often the list is ([PaperView]).
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
  PrintFind? _marks; // where the words of [_q] are on a line, to mark them
  bool _all = false; // every print is open ("Expand all"), the ones listed later too
  final _turned = <String>{}; // the prints tapped since: open while the rest are closed, or closed while they are open
  late final _shelf = PaperShelf(
    (job) => widget.api.printPaper(widget.token, job),
    problem: (err) => err.status == 404 ? 'This paper is no longer in the log.' : _words(err),
  );
  final _sending = <String>{}; // the prints a reprint is being asked for
  final _problems = <String, String>{}; // why a reprint was not made, by print
  bool _read = false; // the hub answered once
  bool _old = false; // a hub from before the log
  bool _away = false; // the last read got no answer
  String? _refused; // the hub would not show the log, and why
  bool _more = false; // older prints are being read
  String _shown = ''; // what the last read said, in short: the same again draws nothing
  final _scroll = ScrollController();
  String? _heldAt; // the print the list starts at; the ones made since stand above it ([_hold])
  final _heldName = GlobalKey(); // the day's name above that print, while it has it
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
    _scroll.dispose();
    _shelf.dispose();
    super.dispose();
  }

  bool _isOpen(PrintEntry entry) => _all != _turned.contains(entry.jobId);

  /// Opens every print, or closes every one: the ones opened or closed by a tap as well.
  void _openAll(bool all) {
    setState(() {
      _all = all;
      _turned.clear();
    });
    _readAhead();
  }

  /// With every print open, the papers of the ones listed are read before they are scrolled to.
  void _readAhead() => _shelf.ahead(_all ? _prints : const []);

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
      final before = _prints;
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
        _hold(before);
      });
      _readAhead();
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
      _readAhead();
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
      if (q != null) {
        _q = q;
        _marks = PrintFind.of(q);
      }
      _prints = const [];
      _next = null;
      _read = false;
      _shown = '';
      _turned.clear();
      _heldAt = null;
    });
    _readAhead();
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
          if (!_old) _allButton(context),
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

  /// Opens every print at once, and closes them all once they are: its words beside it where there is room,
  /// the mark alone on a phone.
  Widget _allButton(BuildContext context) {
    final says = _all ? 'Collapse all' : 'Expand all';
    final icon = Icon(_all ? Icons.unfold_less : Icons.unfold_more);
    void pressed() => _openAll(!_all);
    if (compact(context)) {
      return IconButton(key: const ValueKey('log-all'), tooltip: says, icon: icon, onPressed: pressed);
    }
    return Padding(
      padding: const EdgeInsets.only(left: 4, right: 8),
      child: TextButton.icon(key: const ValueKey('log-all'), icon: icon, label: Text(says), onPressed: pressed),
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
    // The rows of the list are its prints, each with its day's name above it where the day changes, and
    // what ends the list. They are two lists back to back: the one that starts where the screen does is
    // the log as it stood when it was last read from its top, and the prints made since stand above it,
    // the newest highest. So a print that is made while an older one is being read comes in above the
    // screen and moves nothing on it.
    final prints = _prints;
    final held = _heldIndex(prints);
    // a row by its key, so that it keeps what it has built (its paper) when the rows are counted anew
    final above = <String, int>{for (var i = 0; i < held; i++) 'print:${prints[held - 1 - i].jobId}': i};
    final below = <String, int>{
      for (var i = held; i < prints.length; i++) 'print:${prints[i].jobId}': i - held,
      'log-foot': prints.length - held,
    };
    Widget row(int n) {
      if (n == prints.length) return KeyedSubtree(key: const ValueKey('log-foot'), child: _foot(context));
      return _print(context, prints[n], day: _headed(prints, n) ? _day(prints[n].atMs) : null, heldHere: n == held);
    }

    return CustomScrollView(
      key: const ValueKey('log-list'),
      controller: _scroll,
      center: _heldHere,
      slivers: [
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, i) => row(held - 1 - i),
            childCount: held,
            findChildIndexCallback: (key) => key is ValueKey<String> ? above[key.value] : null,
          ),
        ),
        SliverPadding(
          key: _heldHere,
          padding: const EdgeInsets.only(bottom: 24),
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, i) => row(held + i),
              childCount: prints.length - held + 1,
              findChildIndexCallback: (key) => key is ValueKey<String> ? below[key.value] : null,
            ),
          ),
        ),
      ],
    );
  }

  static const _heldHere = ValueKey('log-held');

  /// Where in [prints] the list is held: the print it starts at; the first one when it is held nowhere.
  int _heldIndex(List<PrintEntry> prints) {
    final at = _heldAt == null ? -1 : prints.indexWhere((p) => p.jobId == _heldAt);
    return at < 0 ? 0 : at;
  }

  /// Whether a print has its day's name above it: the first of the list, and the first of each day after.
  bool _headed(List<PrintEntry> prints, int n) => n == 0 || _day(prints[n - 1].atMs) != _day(prints[n].atMs);

  /// Whether the list is at its top: the newest print is the first thing on the screen and nothing is
  /// moving. A list not on the screen yet is.
  bool get _atTop {
    if (!_scroll.hasClients || !_scroll.position.hasContentDimensions) return true;
    final at = _scroll.position;
    return at.pixels <= at.minScrollExtent + 1 && !at.isScrollingNotifier.value;
  }

  /// The log was read again and is about to be drawn as [_prints]; it was drawn as [before]. Read from its
  /// top, the list starts at the newest print, which shows there as it comes. Read further down, it stays
  /// held where it was and the prints made since go above it; when the first of them takes the day's name
  /// from the print the list is held at, the list is moved by the height of that name, so that what is
  /// being read stays where it is.
  void _hold(List<PrintEntry> before) {
    if (_atTop) {
      _heldAt = _prints.firstOrNull?.jobId;
      if (_scroll.hasClients && _scroll.position.pixels != 0) _scroll.jumpTo(0);
      return;
    }
    final (was, now) = (_heldIndex(before), _heldIndex(_prints));
    if (was >= before.length || now >= _prints.length || before[was].jobId != _prints[now].jobId) return;
    if (!_headed(before, was) || _headed(_prints, now)) return;
    final name = _heldName.currentContext?.size?.height;
    if (name != null && !_scroll.position.isScrollingNotifier.value) _scroll.position.correctBy(-name);
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

  /// The line of a paper a search found its words on, with the words it was searched for marked, in bold.
  Widget _found(BuildContext context, PrintEntry entry) {
    final theme = Theme.of(context);
    final line = entry.found;
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Text.rich(
        TextSpan(
          children: [
            const TextSpan(text: 'On the paper: '),
            ...markedSpans(
              line,
              _marks?.on(line) ?? const [],
              marked: PaperView.marked.copyWith(fontWeight: FontWeight.w700),
            ),
          ],
        ),
        key: ValueKey('print-found:${entry.jobId}'),
        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurface),
      ),
    );
  }

  /// One print: its line in the log, with the words of a search marked in what it is called and in its
  /// printer's name, and under it, when it is open, the paper. Above it its [day]'s name, when it is the
  /// first of that day in the list; [heldHere] is the print the list is held at ([_hold]).
  Widget _print(BuildContext context, PrintEntry entry, {String? day, bool heldHere = false}) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final opened = _isOpen(entry);
    final failing = !entry.printed && (entry.lost || entry.tries > 0);
    final (icon, tint) = entry.printed
        ? (entry.trouble ? Icons.warning_amber_rounded : Icons.check_circle_outline, scheme.tertiary)
        : failing
        ? (Icons.error_outline, scheme.error)
        : (Icons.schedule, scheme.onSurfaceVariant);
    final where = entry.name.isEmpty ? entry.printer : entry.name;
    final find = _marks;
    // the hub looks for the words in the printer's name, not in how the print ended
    final named = entry.name.isEmpty || find == null ? const <TextRange>[] : find.on(where);
    final ended = TextStyle(color: failing ? scheme.error : scheme.onSurfaceVariant);
    return Column(
      key: ValueKey('print:${entry.jobId}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (day != null)
          Padding(
            key: heldHere ? _heldName : null,
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
            child: Text(day, style: theme.textTheme.labelLarge?.copyWith(color: scheme.onSurfaceVariant)),
          ),
        InkWell(
          key: ValueKey('print-row:${entry.jobId}'),
          onTap: () => setState(() => _turned.remove(entry.jobId) || _turned.add(entry.jobId)),
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
                            ...markedSpans(entry.line, find?.on(entry.line) ?? const []),
                          ],
                        ),
                        key: ValueKey('print-line:${entry.jobId}'),
                        style: theme.textTheme.titleSmall,
                      ),
                      const SizedBox(height: 2),
                      if (named.isEmpty)
                        Text(
                          '$where · ${entry.outcome}',
                          key: ValueKey('print-outcome:${entry.jobId}'),
                          style: theme.textTheme.bodySmall?.merge(ended),
                        )
                      else
                        Text.rich(
                          TextSpan(
                            children: [
                              ...markedSpans(where, named),
                              TextSpan(text: ' · ${entry.outcome}'),
                            ],
                          ),
                          key: ValueKey('print-outcome:${entry.jobId}'),
                          style: theme.textTheme.bodySmall?.merge(ended),
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
        if (opened) _opened(context, entry),
        Divider(height: 1, color: scheme.outlineVariant),
      ],
    );
  }

  /// Under a print's line: the paper, what happened to it, and Reprint.
  Widget _opened(BuildContext context, PrintEntry entry) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final sending = _sending.contains(entry.jobId);
    final problem = _problems[entry.jobId];
    final others = [
      for (final p in _printers)
        if (p.id != entry.printer) p,
    ];
    return Container(
      color: scheme.surfaceContainerLow,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: _Paper(shelf: _shelf, entry: entry, find: _marks),
          ),
          const SizedBox(height: 12),
          _story(context, entry),
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
            // who asked is searched too: a search for a name marks it here
            child: Text.rich(
              TextSpan(
                children: [
                  const TextSpan(text: 'A reprint'),
                  if (entry.by.isNotEmpty) ...[
                    const TextSpan(text: ' asked for by '),
                    ...markedSpans(entry.by, _marks?.on(entry.by) ?? const []),
                  ],
                  if (first != null)
                    TextSpan(
                      text: ' of the paper from ${_day(first) == 'Today' ? '' : '${_day(first)}, '}${_time(first)}',
                    ),
                  const TextSpan(text: '.'),
                ],
              ),
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

/// The paper of a print that is open: the paper once the hub gave it, the turning ring until then, or why
/// it did not come, with "Try again". It asks the shelf for its paper when it comes onto the screen, and it
/// alone is drawn again when the paper arrives.
class _Paper extends StatefulWidget {
  const _Paper({required this.shelf, required this.entry, this.find});

  final PaperShelf shelf;
  final PrintEntry entry;
  final PrintFind? find;

  @override
  State<_Paper> createState() => _PaperState();
}

class _PaperState extends State<_Paper> {
  late ValueListenable<PaperRead?> _read = widget.shelf.of(widget.entry);

  @override
  void initState() {
    super.initState();
    widget.shelf.want(widget.entry);
  }

  @override
  void didUpdateWidget(_Paper old) {
    super.didUpdateWidget(old);
    if (identical(old.shelf, widget.shelf) && PaperShelf.keyOf(old.entry) == PaperShelf.keyOf(widget.entry)) return;
    _read = widget.shelf.of(widget.entry); // it printed at another printer since: that is another paper
    widget.shelf.want(widget.entry);
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<PaperRead?>(
    valueListenable: _read,
    builder: (context, read, _) {
      final paper = read?.paper;
      if (paper != null) {
        return PaperView(key: ValueKey('paper:${widget.entry.jobId}'), pages: paper.pages, find: widget.find);
      }
      final problem = read?.problem;
      if (problem == null) {
        return const Padding(
          padding: EdgeInsets.all(24),
          child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)),
        );
      }
      final theme = Theme.of(context);
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(problem, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
          ),
          TextButton(onPressed: () => widget.shelf.again(widget.entry), child: const Text('Try again')),
        ],
      );
    },
  );
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
