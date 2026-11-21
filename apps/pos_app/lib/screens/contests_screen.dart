import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../contests.dart';
import '../live.dart';
import '../menu.dart';
import '../powers.dart';
import '../session.dart' show Staff;
import '../shift_notes.dart' show whenWords;
import 'dish_finder.dart';
import 'menu_editor.dart' show ManagerPinDialog;
import 'span_report.dart' show reportError;

/// Contests for the staff (docs/contests.md).
///
/// For everybody, from the menu of the list of checks: the contests that are running, about to start or
/// just over, each with the reader's own number and place and who is in front; and every name and number
/// only where the manager who set the contest up said everybody sees the whole board.
///
/// For a manager, once their PIN is typed (or from Location, which has it already): every contest the
/// location keeps with its whole board, and setting one up, changing it and taking it away. The hub adds up
/// who is ahead from the checks, the same ones the reports read; nothing here is a sale or changes one.
class ContestsScreen extends StatefulWidget {
  const ContestsScreen({
    super.key,
    required this.api,
    required this.device,
    this.staff,
    this.token,
    this.edits = false,
    this.now,
  });

  final PosApi api;
  final String device;

  /// Who is reading: the boards are read as they may see them, and a manager among them is offered the
  /// setting up.
  final Staff? staff;

  /// A session from Location (`POST /admin/session`): the screen then shows every contest with its whole
  /// board. Without one a manager types their PIN first.
  final String? token;

  /// Whether that session's holder may set contests up (a manager or an owner), not only read the boards.
  final bool edits;

  /// The clock "set up today 21:00" is worded against; the terminal's own when left out.
  final DateTime Function()? now;

  @override
  State<ContestsScreen> createState() => _ContestsScreenState();
}

class _ContestsScreenState extends State<ContestsScreen> {
  static const double _wide = 760; // as the waste log

  late String? _token = widget.token;
  late bool _edits = widget.token != null && widget.edits;
  MyContests? _mine;
  ContestList? _list;
  final _boards = <String, Contest>{}; // the whole board of each contest read so far, by its id
  final _reading = <String>{}; // the boards being read because somebody asked for them
  String? _error;
  bool _old = false; // the hub is older than contests
  int _asked = 0;
  late final _reader = Paced(const Duration(seconds: 10), _load);
  StreamSubscription<LiveChange>? _live;

  bool get _mayManage => _token != null ? _edits : alwaysRoles.contains(widget.staff?.role);
  DateTime get _now => widget.now?.call() ?? DateTime.now();

  @override
  void initState() {
    super.initState();
    // a dish rung in anywhere moves a board, and a contest set up elsewhere changes the list: read again,
    // at most every ten seconds
    _live = widget.api.live.changes.listen((change) {
      if (change.anyOrder) _reader();
    });
    _reader.now();
  }

  @override
  void dispose() {
    unawaited(_live?.cancel());
    _reader.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final ask = ++_asked;
    if (mounted) setState(() => _error = null);
    try {
      final token = _token;
      if (token == null) {
        final staff = widget.staff;
        final mine = staff == null ? const MyContests() : await widget.api.myContests(staff.staffId);
        if (!mounted || ask != _asked) return;
        setState(() => _mine = mine);
        return;
      }
      final list = await widget.api.contestList();
      if (!mounted || ask != _asked) return;
      if (list == null) {
        setState(() => _old = true);
        return;
      }
      // the boards of the contests on the staff's screens are read with the list; an older one is read
      // when somebody asks for it
      final wanted = [
        for (final contest in list.contests)
          if (contest.id != null && !contest.isComing && (contest.shown || _boards.containsKey(contest.id)))
            contest.id!,
      ];
      final read = await Future.wait([for (final id in wanted) _board(token, id)]);
      if (!mounted || ask != _asked) return;
      setState(() {
        _list = list;
        _boards.removeWhere((id, _) => !list.contests.any((c) => c.id == id));
        for (final board in read) {
          if (board?.id != null) _boards[board!.id!] = board;
        }
      });
    } on ApiException catch (err) {
      if (!mounted || ask != _asked) return;
      if (_expired(err)) return;
      if (err.status == 404 && err.detail?['error'] != 'unknown_staff') {
        setState(() => _old = true);
        return;
      }
      setState(() => _error = reportError(err, 'contests'));
    }
  }

  /// One whole board, or null when the hub would not give it: the card then offers to try again.
  Future<Contest?> _board(String token, String id) async {
    try {
      return await widget.api.contestBoard(token, id);
    } on ApiException catch (err) {
      if (err.status == 401 || err.status == 403) rethrow;
      return null;
    }
  }

  /// The manager's hour ran out on a screen that asked for the PIN itself: it goes back to what everybody
  /// sees, and the next change asks for the PIN again.
  bool _expired(ApiException err) {
    if (widget.token != null || _token == null || (err.status != 401 && err.status != 403)) return false;
    setState(() {
      _token = null;
      _edits = false;
      _list = null;
      _boards.clear();
    });
    _say("The manager's hour is over. Type the PIN again to change the contests.");
    _reader.now();
    return true;
  }

  void _say(String words, {String? key}) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.hideCurrentSnackBar();
    messenger?.showSnackBar(SnackBar(key: key == null ? null : ValueKey(key), content: Text(words)));
  }

  /// A manager's PIN, once: the screen then lists every contest with its whole board and offers the changes.
  Future<void> _unlock() async {
    final token = await showDialog<String>(
      context: context,
      builder: (_) => ManagerPinDialog(
        api: widget.api,
        device: widget.device,
        action: 'Open the contests',
        what: 'set up a contest',
        power: settingsPower,
      ),
    );
    if (token == null || !mounted) return;
    setState(() {
      _token = token;
      _edits = true;
    });
    await _reader.now();
  }

  /// The board of a contest that is off the staff's screens, asked for by a tap.
  Future<void> _showBoard(Contest contest) async {
    final token = _token, id = contest.id;
    if (token == null || id == null || _reading.contains(id)) return;
    setState(() => _reading.add(id));
    Contest? board;
    try {
      board = await _board(token, id);
    } on ApiException catch (err) {
      if (!mounted || _expired(err)) return;
    }
    if (!mounted) return;
    setState(() {
      _reading.remove(id);
      if (board != null) _boards[id] = board;
    });
    if (board == null) _say('The hub did not give that board. Try again.', key: 'contest-board-failed');
  }

  Future<void> _save(List<Contest> contests, String said, String key) async {
    final token = _token;
    if (token == null) return;
    try {
      await widget.api.saveContests(token, contests);
      if (!mounted) return;
      _say(said, key: key);
    } on ApiException catch (err) {
      if (!mounted || _expired(err)) return;
      _say(reportError(err, 'contests'), key: 'contest-refused');
    }
    if (mounted) await _reader.now();
  }

  Future<Contest?> _form(ContestList list, [Contest? contest]) => showDialog<Contest>(
    context: context,
    builder: (_) => ContestFormDialog(api: widget.api, list: list, contest: contest),
  );

  Future<void> _new() async {
    final list = _list;
    if (list == null) return;
    final made = await _form(list);
    if (made == null || !mounted) return;
    await _save([...list.contests, made], 'The contest is set up.', 'contest-made');
  }

  Future<void> _change(Contest contest) async {
    final list = _list;
    if (list == null) return;
    final changed = await _form(list, contest);
    if (changed == null || !mounted) return;
    await _save(
      [for (final c in list.contests) c.id == contest.id ? changed : c],
      'Changed. The board is added up again.',
      'contest-changed',
    );
  }

  Future<void> _takeAway(Contest contest) async {
    final list = _list;
    if (list == null) return;
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        title: Text('Take "${contest.name}" away?'),
        content: const Text('It is gone from every screen, with its board. No sale is touched.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Keep it')),
          FilledButton(
            key: const ValueKey('contest-away-sure'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Take away'),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    await _save(
      [
        for (final c in list.contests)
          if (c.id != contest.id) c,
      ],
      'Taken away.',
      'contest-away',
    );
  }

  /// The hub's day, which the words of a contest are said against; the terminal's own until it is known.
  DateTime _today(String said) => DateTime.tryParse(said) ?? _now;

  Widget _head(Contest contest, DateTime today) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final small = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2, right: 8),
              child: Icon(
                Icons.emoji_events_outlined,
                size: 20,
                color: contest.isOver ? scheme.onSurfaceVariant : scheme.primary,
              ),
            ),
            Expanded(
              child: Text(contest.name, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
            ),
            const SizedBox(width: 8),
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(
                stateWords(contest, today),
                key: ValueKey('contest-state:${contest.id}'),
                style: theme.textTheme.labelMedium?.copyWith(
                  color: contest.state == 'running' ? scheme.primary : scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          [countsWords(contest), daysWords(contest, today), rolesWords(contest.roles)].join(' · '),
          key: ValueKey('contest-about:${contest.id}'),
          style: small,
        ),
        if (contest.note.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(contest.note, style: theme.textTheme.bodyMedium),
          ),
      ],
    );
  }

  /// A board's rows: place, name, the figure it goes by and, where there is room, the other one.
  Widget _rows(Contest contest, List<ContestRow> rows, {bool both = false}) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final mine = widget.staff?.staffId;
    return Column(
      key: ValueKey('contest-rows:${contest.id}'),
      children: [
        for (final row in rows)
          Padding(
            key: ValueKey('contest-row:${contest.id}:${row.staffId}'),
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: DefaultTextStyle.merge(
              style: theme.textTheme.bodyLarge?.copyWith(
                fontWeight: _token == null && row.staffId == mine ? FontWeight.w700 : null,
                color: row.place == null ? scheme.onSurfaceVariant : null,
              ),
              child: Row(
                children: [
                  SizedBox(width: 30, child: Text(row.place == null ? '–' : '${row.place}')),
                  Expanded(
                    child: Text(
                      _token == null && row.staffId == mine ? '${row.name} (you)' : row.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (both && row.place != null)
                    Padding(
                      padding: const EdgeInsets.only(right: 10),
                      child: Text(
                        otherFigureWords(contest, row),
                        style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ),
                  Text(figureWords(contest, row), style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()])),
                ],
              ),
            ),
          ),
      ],
    );
  }

  /// A contest as the person signed in may see it.
  Widget _read(Contest contest, DateTime today) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final front = frontWords(contest);
    final rows = contest.standings;
    return Card(
      key: ValueKey('contest:${contest.id}'),
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _head(contest, today),
            const SizedBox(height: 10),
            Text(
              mineWords(contest),
              key: ValueKey('contest-mine:${contest.id}'),
              style: theme.textTheme.titleMedium?.copyWith(
                color: contest.me?.place == null ? scheme.onSurfaceVariant : scheme.onSurface,
              ),
            ),
            if (front.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(front, key: ValueKey('contest-front:${contest.id}'), style: theme.textTheme.bodyMedium),
              ),
            if (rows != null && rows.isNotEmpty && !contest.isComing) ...[
              const Divider(height: 20),
              _rows(contest, rows),
            ],
          ],
        ),
      ),
    );
  }

  /// A contest as a manager has it: how it is set up, its whole board, and the changes.
  Widget _managed(Contest contest, DateTime today) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final small = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final id = contest.id ?? '';
    final board = _boards[id];
    final others = board == null ? '' : othersWords(board);
    final front = board == null ? '' : frontWords(board);
    return Card(
      key: ValueKey('contest:$id'),
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: EdgeInsets.fromLTRB(14, 12, 14, _edits ? 2 : 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _head(contest, today),
            const SizedBox(height: 4),
            Row(
              children: [
                Icon(
                  contest.forAll ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                  size: 16,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(boardWords(contest), key: ValueKey('contest-board:$id'), style: small),
                ),
              ],
            ),
            if (board != null && !contest.isComing) ...[
              const Divider(height: 20),
              if (front.isNotEmpty && contest.isOver)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(front, key: ValueKey('contest-front:$id'), style: theme.textTheme.titleSmall),
                ),
              _rows(contest, board.standings ?? const [], both: true),
              if (others.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(others, key: ValueKey('contest-others:$id'), style: small),
                ),
            ] else if (!contest.isComing)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: ValueKey('contest-show:$id'),
                  onPressed: _reading.contains(id) ? null : () => _showBoard(contest),
                  icon: const Icon(Icons.leaderboard_outlined, size: 18),
                  label: Text(_reading.contains(id) ? 'Adding it up…' : 'Show the board'),
                ),
              ),
            if (contest.setBy.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Set up by ${contest.setBy}${contest.setMs > 0 ? ', ${whenWords(contest.setMs, _now)}' : ''}'
                  '${contest.shown ? '' : ' · off the staff\'s screens'}',
                  style: small,
                ),
              ),
            if (_edits)
              Align(
                alignment: Alignment.centerRight,
                child: OverflowBar(
                  spacing: 4,
                  alignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      key: ValueKey('contest-change:$id'),
                      onPressed: () => _change(contest),
                      child: const Text('Change'),
                    ),
                    TextButton(
                      key: ValueKey('contest-away:$id'),
                      onPressed: () => _takeAway(contest),
                      child: const Text('Take away'),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final list = _token == null ? null : _list;
    final mine = _token == null ? _mine : null;
    final Widget body;
    if (_old) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'This hub is older than contests. Update the hub to use them.',
            key: const ValueKey('contests-old'),
            textAlign: TextAlign.center,
            style: small,
          ),
        ),
      );
    } else if (_error != null && list == null && mine == null) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!, key: const ValueKey('contests-error'), textAlign: TextAlign.center),
              const SizedBox(height: 12),
              OutlinedButton(onPressed: () => _reader.now(), child: const Text('Try again')),
            ],
          ),
        ),
      );
    } else if (list == null && mine == null) {
      body = const Center(child: CircularProgressIndicator());
    } else {
      final contests = list?.contests ?? mine!.contests;
      final today = _today(list?.today ?? mine!.today);
      body = ListView(
        key: const ValueKey('contests-list'),
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
        children: [
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(_error!, key: const ValueKey('contests-error'), style: small),
            ),
          if (contests.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 12, 4, 12),
              child: Text(
                list == null
                    ? 'No contest is running.'
                    : _edits
                    ? 'No contest is set up. A contest ranks the staff by what they ring in: the most sales, '
                          'or the most of one dish or one category, between two days. It is a board to look '
                          'at: it changes no sale and nobody\'s pay.'
                    : 'No contest is set up.',
                key: const ValueKey('contests-none'),
                style: small,
              ),
            ),
          for (final contest in contests) list != null ? _managed(contest, today) : _read(contest, today),
          if (contests.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
              child: Text(
                'A dish counts for whoever rang it in, on the day of its check. Voided dishes do not count.',
                key: const ValueKey('contests-how'),
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
        ],
      );
    }
    final full = list != null && list.contests.length >= list.most;
    return Scaffold(
      appBar: AppBar(title: const Text('Contests')),
      // a tablet keeps a board as wide as it reads well: a name stays beside its number
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _wide),
            child: body,
          ),
        ),
      ),
      bottomNavigationBar: !_mayManage || _old || (list == null && mine == null)
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Center(
                  heightFactor: 1,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: _wide - 32),
                    child: SizedBox(
                      width: double.infinity,
                      child: list != null
                          ? FilledButton.icon(
                              key: const ValueKey('contest-new'),
                              onPressed: full ? null : _new,
                              icon: const Icon(Icons.add),
                              label: Text(full ? 'Take one away to set up another' : 'Set up a contest'),
                            )
                          : FilledButton.tonalIcon(
                              key: const ValueKey('contests-unlock'),
                              onPressed: _unlock,
                              icon: const Icon(Icons.lock_outline),
                              label: const Text('Set up or change contests'),
                            ),
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}

/// A contest being set up, or one being changed: its name, what counts, its days, who takes part, who sees
/// the numbers and what the winner gets. Pops the [Contest] as typed, or nothing when it was closed.
class ContestFormDialog extends StatefulWidget {
  const ContestFormDialog({super.key, required this.api, required this.list, this.contest});

  final PosApi api;

  /// What the hub offers: the roles, the categories, the limits and its day.
  final ContestList list;

  /// The contest being changed; null sets a new one up.
  final Contest? contest;

  @override
  State<ContestFormDialog> createState() => _ContestFormDialogState();
}

class _ContestFormDialogState extends State<ContestFormDialog> {
  late final _name = TextEditingController(text: widget.contest?.name ?? '');
  late final _note = TextEditingController(text: widget.contest?.note ?? '');
  late String _counts = widget.contest?.counts ?? 'sales';
  late String? _item = widget.contest?.item;
  late String? _category = widget.contest?.category;
  late String _what = widget.contest?.what ?? '';
  late DateTime _first = widget.contest?.firstDay ?? _today;
  late DateTime _last = widget.contest?.lastDay ?? _today.add(const Duration(days: 6));
  late final Set<String> _roles = {...widget.contest?.roles ?? widget.list.standardRoles};
  late bool _all = widget.contest?.forAll ?? false;

  DateTime get _today {
    final said = DateTime.tryParse(widget.list.today) ?? DateTime.now();
    return DateTime(said.year, said.month, said.day);
  }

  @override
  void dispose() {
    _name.dispose();
    _note.dispose();
    super.dispose();
  }

  int get _days =>
      DateTime.utc(
        _last.year,
        _last.month,
        _last.day,
      ).difference(DateTime.utc(_first.year, _first.month, _first.day)).inDays +
      1;

  /// What still keeps the contest from being saved, in words; null when nothing does.
  String? get _missing {
    if (_name.text.trim().isEmpty) return 'Give it a name.';
    if (_counts == 'dish' && (_item ?? '').isEmpty) return 'Pick the dish that counts.';
    if (_counts == 'category' && (_category ?? '').isEmpty) return 'Pick the category that counts.';
    if (_days < 1) return 'The last day is before the first.';
    if (_days > widget.list.daysMax) return 'A contest runs ${widget.list.daysMax} days at most.';
    if (_roles.isEmpty) return 'Somebody has to take part.';
    return null;
  }

  void _done() {
    if (_missing != null) return;
    Navigator.of(context).pop(
      Contest(
        id: widget.contest?.id,
        name: _name.text.trim(),
        note: _note.text.trim(),
        counts: _counts,
        item: _counts == 'dish' ? _item : null,
        category: _counts == 'category' ? _category : null,
        what: _counts == 'sales' ? '' : _what,
        first: isoDay(_first),
        last: isoDay(_last),
        roles: [
          for (final role in widget.list.roles)
            if (_roles.contains(role)) role,
        ],
        board: _all ? 'all' : 'own',
      ),
    );
  }

  Future<void> _pickDish() async {
    final picked = await showDialog<MenuEntry>(
      context: context,
      builder: (_) => DishFinderDialog(api: widget.api, title: 'Which dish counts?'),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _item = picked.item;
      _what = picked.name;
    });
  }

  Future<void> _pickDay({required bool first}) async {
    final today = _today;
    // a year either way, and as far as the contest already reaches: an old one opens on its own days
    var from = DateTime(today.year - 1, today.month, today.day);
    var until = DateTime(today.year + 1, today.month, today.day);
    for (final day in [_first, _last]) {
      if (day.isBefore(from)) from = day;
      if (day.isAfter(until)) until = day;
    }
    final picked = await showDatePicker(
      context: context,
      initialDate: first ? _first : _last,
      firstDate: from,
      lastDate: until,
      helpText: first ? 'The first day that counts' : 'The last day that counts',
    );
    if (picked == null || !mounted) return;
    setState(() {
      if (first) {
        // the contest keeps its length when its start moves
        final length = _days < 1 ? 1 : _days;
        _first = picked;
        _last = DateTime(picked.year, picked.month, picked.day + length - 1);
      } else {
        _last = picked;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final small = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final label = theme.textTheme.labelLarge?.copyWith(color: scheme.primary);
    final changing = widget.contest != null;
    final missing = _missing;
    final today = _today;
    final several = widget.list.categories.map((c) => c.menu).toSet().length > 1;
    // a category the menu no longer has stays picked on its contest, under the name it had
    final known = widget.list.categories.any((c) => c.code == _category);
    Widget counts(String value, String words) => ChoiceChip(
      key: ValueKey('contest-counts:$value'),
      label: Text(words),
      selected: _counts == value,
      onSelected: (_) => setState(() => _counts = value),
    );
    Widget day(String key, String words, DateTime at, {required bool first}) => Expanded(
      child: OutlinedButton(
        key: ValueKey(key),
        onPressed: () => _pickDay(first: first),
        style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10)),
        child: Column(
          children: [
            Text(words, style: small),
            Text(contestDay(at, today), maxLines: 1, overflow: TextOverflow.ellipsis),
          ],
        ),
      ),
    );
    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24), // a phone keeps its width
      title: Text(changing ? 'Change the contest' : 'Set up a contest'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      key: const ValueKey('contest-name'),
                      controller: _name,
                      autofocus: !changing,
                      maxLength: widget.list.nameMax,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: const InputDecoration(
                        labelText: 'Name',
                        hintText: 'Mai Tai month',
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                    Text('What counts', style: label),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        counts('sales', 'Sales'),
                        counts('dish', 'One dish'),
                        counts('category', 'One category'),
                      ],
                    ),
                    if (_counts == 'sales')
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text('The money of every dish a person rings in.', style: small),
                      ),
                    if (_counts == 'dish')
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: OutlinedButton.icon(
                          key: const ValueKey('contest-dish'),
                          onPressed: _pickDish,
                          icon: const Icon(Icons.search, size: 18),
                          label: Text((_item ?? '').isEmpty ? 'Pick the dish' : _what, overflow: TextOverflow.ellipsis),
                        ),
                      ),
                    if (_counts == 'category')
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: DropdownButtonFormField<String>(
                          key: const ValueKey('contest-category'),
                          initialValue: (_category ?? '').isEmpty ? null : _category,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Category',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          items: [
                            if (!known && (_category ?? '').isNotEmpty)
                              DropdownMenuItem(value: _category, child: Text('$_what (off the menu)')),
                            for (final category in widget.list.categories)
                              DropdownMenuItem(
                                value: category.code,
                                child: Text(
                                  several && category.menu.isNotEmpty
                                      ? '${category.name} · ${category.menu}'
                                      : category.name,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: (code) => setState(() {
                            _category = code;
                            _what = widget.list.categories.where((c) => c.code == code).firstOrNull?.name ?? _what;
                          }),
                        ),
                      ),
                    const SizedBox(height: 14),
                    Text('The days it runs', style: label),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        day('contest-first', 'First day', _first, first: true),
                        const SizedBox(width: 8),
                        day('contest-last', 'Last day', _last, first: false),
                      ],
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        _days < 1 ? 'The last day is before the first.' : (_days == 1 ? '1 day' : '$_days days'),
                        key: const ValueKey('contest-days'),
                        style: small?.copyWith(color: _days < 1 || _days > widget.list.daysMax ? scheme.error : null),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text('Who takes part', style: label),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        for (final role in widget.list.roles)
                          FilterChip(
                            key: ValueKey('contest-role:$role'),
                            label: Text(roleLabel(role)),
                            selected: _roles.contains(role),
                            onSelected: (on) => setState(() => on ? _roles.add(role) : _roles.remove(role)),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    SwitchListTile(
                      key: const ValueKey('contest-board-all'),
                      contentPadding: EdgeInsets.zero,
                      value: _all,
                      onChanged: (on) => setState(() => _all = on),
                      title: const Text('Everybody sees the whole board'),
                      subtitle: Text(
                        _all
                            ? 'Every name and every number, on every screen.'
                            : 'Off: each person sees only their own number and place, and who is in front.',
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      key: const ValueKey('contest-note'),
                      controller: _note,
                      maxLength: widget.list.noteMax,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: const InputDecoration(
                        labelText: 'What the winner gets',
                        hintText: 'Optional',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // what is still missing stays in sight over the buttons, however far the form is scrolled
            if (missing != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  missing,
                  key: const ValueKey('contest-missing'),
                  style: small?.copyWith(color: theme.colorScheme.error),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('contest-save'),
          onPressed: missing == null ? _done : null,
          child: Text(changing ? 'Save' : 'Set it up'),
        ),
      ],
    );
  }
}
