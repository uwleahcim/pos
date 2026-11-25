import 'package:flutter/material.dart';

import '../api.dart';
import '../day_report.dart' show dollars, kindLabel;
import '../guests_report.dart';
import '../sales_report.dart' show Change;
import 'check_history_screen.dart';
import 'guest_edit_dialog.dart';
import 'guest_tag_mark.dart';
import 'span_report.dart';
import 'theme.dart';
import 'who_paid.dart';

/// The guest list, for a manager (docs/guest-list.md): every customer who ordered with a phone number in
/// the last year, with how often they came, what they spent and when they were last here; the regulars, the
/// guests who stopped coming and the new ones each a list of their own; by what they spent, how often they
/// came or who was here last; and a name or a number to find one. A guest opens to their favourite dishes
/// and their latest visits, each of which opens its check's history. The hub does every sum; this only
/// picks the lists out and puts them in order. Two things are written from here, both about the guest and
/// neither about their orders: the tags a manager puts on them ("VIP"), each of which is a list of its own,
/// and the one line of the note. A guest who carries a tag and has no order in the year is in the list too,
/// after the others (tagged from their reservation or the waitlist before their first order): their row
/// says so in place of visits and money, and their tags and note are changed like anybody's. One more thing
/// is said from here: who paid a check that several guests sat on, where nobody tapped it on the check
/// (`who_paid.dart`). The list says how many such checks wait, and a visit at such a table opens its check's
/// guests.
class GuestsScreen extends StatefulWidget {
  const GuestsScreen({super.key, required this.api, required this.token});

  final PosApi api;

  /// The manager's session (`POST /admin/session`): every call here carries it.
  final String token;

  @override
  State<GuestsScreen> createState() => _GuestsScreenState();
}

class _GuestsScreenState extends State<GuestsScreen> {
  GuestsReport? _report;
  String? _error;
  int _asked = 0;

  /// How many times the list was put in another order or another list was picked: each time it is a new
  /// list, laid out from its top.
  int _laid = 0;
  GuestList _list = GuestList.all;

  /// The tag whose guests the list is narrowed to; null for every guest of [_list].
  String? _tag;
  GuestSort _sort = GuestSort.spent;
  final _find = TextEditingController();
  final _scroll = ScrollController();

  /// The guests the list shows now, in its order: worked out when what it depends on changes, not each
  /// time the screen is drawn (a year of guests can be thousands).
  List<Guest> _shown = const [];

  /// The guests that are open (by number), what the hub said of each read closely, and what went wrong
  /// where it did not.
  final _open = <String>{};
  final _details = <String, GuestDetail>{};
  final _detailErrors = <String, String>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _find.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _reshow() {
    final report = _report;
    // a tag nobody of the list carries any more is no list to stay on
    if (report != null && _tag != null && report.carried.every((tag) => tag.tag != _tag)) _tag = null;
    _shown = report == null
        ? const []
        : sortedGuests(guestsNamed(guestsTagged(guestsOf(report.everyone, _list), _tag), _find.text), _sort);
  }

  Future<void> _load() async {
    final ask = ++_asked;
    setState(() => _error = null);
    try {
      final report = await widget.api.guestsReport(widget.token);
      if (!mounted || ask != _asked) return;
      setState(() {
        _report = report;
        // read again: what was read closely before may have moved too
        _details.clear();
        _detailErrors.clear();
        _reshow();
      });
      for (final phone in _open) {
        _loadDetail(phone);
      }
    } on ApiException catch (err) {
      if (!mounted || ask != _asked) return;
      setState(() => _error = reportError(err, 'the guest list'));
    }
  }

  Future<void> _loadDetail(String phone) async {
    if (_details.containsKey(phone)) return;
    setState(() => _detailErrors.remove(phone));
    try {
      final detail = await widget.api.guestDetail(widget.token, phone);
      if (!mounted) return;
      setState(() => _details[phone] = detail);
    } on ApiException catch (err) {
      if (!mounted) return;
      // a guest whose last visit of the year has just left it: the hub says so in its own words
      final gone = err.status == 404 && err.detail?['error'] == 'no_guest';
      setState(
        () => _detailErrors[phone] = gone
            ? (err.detail?['message'] as String?) ?? 'No visit from this number in the last year.'
            : reportError(err, 'the guest list'),
      );
    }
  }

  void _toggle(Guest guest) {
    final opening = !_open.contains(guest.phone);
    setState(() => opening ? _open.add(guest.phone) : _open.remove(guest.phone));
    if (opening) _loadDetail(guest.phone);
  }

  /// The tags and the note of [guest], for a manager to change. What the hub kept stands on the screen at
  /// once: beside the guest, under them where they are open, and in the count of each tag.
  Future<void> _edit(Guest guest) async {
    final report = _report;
    if (report == null) return;
    final kept = await showDialog<GuestKept>(
      context: context,
      builder: (_) => GuestEditDialog(
        api: widget.api,
        token: widget.token,
        guest: guest,
        offered: [for (final tag in report.tags) tag.tag],
        noteMax: report.noteMax,
        tagMax: report.tagMax,
        tagsMost: report.tagsMost,
      ),
    );
    if (kept == null || !mounted) return;
    // a guest with no order is in the list for their tags: with the last one off, they are out of it
    final left = !guest.ordered && kept.tags.isEmpty;
    setState(() {
      _report = _report?.withKept(kept);
      final detail = _details[kept.phone];
      if (left) {
        _open.remove(kept.phone);
        _details.remove(kept.phone);
        _detailErrors.remove(kept.phone);
      } else if (detail != null) {
        _details[kept.phone] = detail.withKept(kept);
      }
      _reshow();
    });
    if (!left) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          key: const ValueKey('guest-left'),
          content: Text(
            '${guest.called} carries no tag now and has ${_noOrder(guest, report)}, so the list no longer shows them.',
          ),
        ),
      );
  }

  /// The checks that wait for who paid, each with its guests to tap. When something was said there, the
  /// list is read again: a check's money counts for a guest now.
  Future<void> _openWaiting() async {
    var said = false;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => WhoPaidScreen(api: widget.api, token: widget.token, onSaid: () => said = true),
      ),
    );
    if (said && mounted) _load();
  }

  /// The guests of the check of one visit, to say (or say otherwise) who paid it.
  Future<void> _whoPaid(GuestVisit visit) async {
    final said = await showWhoPaid(context, api: widget.api, token: widget.token, orderId: visit.orderId);
    if (said && mounted) _load();
  }

  /// Another list or order: it starts again from its top.
  void _relay(VoidCallback change) {
    if (_scroll.hasClients) _scroll.jumpTo(0);
    setState(() {
      change();
      _reshow();
      _laid++;
    });
  }

  static String _many(int n) {
    final digits = '$n';
    final grouped = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) grouped.write(',');
      grouped.write(digits[i]);
    }
    return grouped.toString();
  }

  static String _count(int n, String one, String more) => '${_many(n)} ${n == 1 ? one : more}';

  /// A day as the list says it: "Nov 14", with its year when that is not this one.
  String _dayWords(DateTime day, {bool weekday = false}) {
    final local = MaterialLocalizations.of(context);
    final thisYear = day.year == (_report?.last.year ?? day.year);
    if (!thisYear) return local.formatShortDate(day);
    return weekday ? local.formatMediumDate(day) : local.formatShortMonthDay(day);
  }

  /// What the list says of a guest with no visit in the days it reads: one who never ordered, or one whose
  /// orders are no visit of those days (older than them, for a day still to come, or with no dish on them).
  static String _noOrder(Guest guest, GuestsReport report) => guest.ordersEver > 0
      ? 'no visit in the last ${report.days == 365 ? '12 months' : '${report.days} days'}'
      : 'no order yet';

  /// What the foot of the list says when it shows guests with no order.
  static const _taggedToo =
      ' A guest who carries a tag and has no order in that time is listed too, after the others: nothing of '
      'theirs is in the visits or in what the guests spent.';

  /// What a list means, in the hub's own numbers.
  String _meaning(GuestsReport report) => switch (_list) {
    GuestList.all => '',
    GuestList.regulars => '${report.regularVisits} visits or more in the last ${report.regularDays} days',
    GuestList.lapsed => '${report.regularVisits} visits or more in the year, and none for ${report.lapsedDays} days',
    GuestList.fresh => 'their first order ever was in the last ${report.newDays} days',
  };

  Widget _chips(GuestsReport? report) {
    final totals = report?.totals;
    Widget chip(GuestList one, String key, int? count) => ChoiceChip(
      key: ValueKey('guests:$key'),
      label: Text(count == null ? one.words : '${one.words} ${_many(count)}'),
      selected: _list == one,
      onSelected: (_) => _relay(() => _list = one),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            chip(GuestList.all, 'all', totals == null ? null : totals.guests + report!.tagged.length),
            chip(GuestList.regulars, 'regulars', totals?.regulars),
            chip(GuestList.lapsed, 'lapsed', totals?.lapsed),
            chip(GuestList.fresh, 'new', totals?.fresh),
          ],
        ),
      ),
    );
  }

  /// The tags guests carry, each a list of its own: one line that runs on sideways, so that many tags take
  /// no more of a phone than one. It stands in the head of the list and scrolls away with it; picking a
  /// tag starts the list from its top, where the line is, with the tag picked first in it.
  Widget _tagLists(GuestsReport report) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: SingleChildScrollView(
      key: const ValueKey('guests-tags'),
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final tag in [
            ...report.carried.where((tag) => tag.tag == _tag),
            ...report.carried.where((tag) => tag.tag != _tag),
          ])
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilterChip(
                key: ValueKey('guests-tag:${tag.tag}'),
                avatar: _tag == tag.tag ? null : const Icon(Icons.sell_outlined, size: 16),
                label: Text('${tag.tag} ${_many(tag.guests)}'),
                selected: _tag == tag.tag,
                visualDensity: VisualDensity.compact,
                onSelected: (on) => _relay(() => _tag = on ? tag.tag : null),
              ),
            ),
        ],
      ),
    ),
  );

  /// What stands over the list: the year it reads, what all the guests came to, and how it is ordered.
  Widget _head(BuildContext context, GuestsReport report) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final local = MaterialLocalizations.of(context);
    final totals = report.totals;
    final meaning = [_meaning(report), if (_tag != null) 'tagged $_tag'].where((words) => words.isNotEmpty).join(', ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          report.days == 365 ? 'The last 12 months' : 'The last ${report.days} days',
          key: const ValueKey('guests-days'),
          style: theme.textTheme.titleMedium,
        ),
        Text(
          // the days run over two years, so each says its own
          'Everyone who ordered with a phone number, ${local.formatShortDate(report.first)} to '
          '${local.formatShortDate(report.last)}'
          '${report.tagged.isEmpty ? '' : ', and the tagged guests who did not'}.',
          key: const ValueKey('guests-span'),
          style: small,
        ),
        const SizedBox(height: 6),
        ReportLine(
          key: const ValueKey('guests-total'),
          'Guests',
          _many(totals.guests + report.tagged.length),
          under: [
            _count(totals.regulars, 'regular', 'regulars'),
            '${_many(totals.lapsed)} stopped coming',
            '${_many(totals.fresh)} new',
            if (report.tagged.isNotEmpty) '${_many(report.tagged.length)} with no order',
          ].join(' · '),
          strong: true,
          underWide: true,
        ),
        ReportLine(
          key: const ValueKey('guests-spent'),
          'They spent',
          dollars(totals.spent),
          under: [
            _count(totals.visits, 'visit', 'visits'),
            if (totals.perVisit != null) '${dollars(totals.perVisit!)} a visit',
          ].join(' · '),
          strong: true,
          underWide: true,
        ),
        if (report.saysPaid && report.waiting > 0)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Material(
              color: theme.colorScheme.secondaryContainer,
              borderRadius: BorderRadius.circular(8),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                key: const ValueKey('guests-waiting'),
                onTap: _openWaiting,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${_count(report.waiting, 'check waits', 'checks wait')} for who paid',
                              style: theme.textTheme.titleSmall?.copyWith(
                                color: theme.colorScheme.onSecondaryContainer,
                              ),
                            ),
                            Text(
                              '${dollars(report.waitingNet)} that counts for no guest yet. Tap to say who paid.',
                              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSecondaryContainer),
                            ),
                          ],
                        ),
                      ),
                      Icon(Icons.chevron_right, color: theme.colorScheme.onSecondaryContainer),
                    ],
                  ),
                ),
              ),
            ),
          ),
        const SizedBox(height: 10),
        SegmentedButton<GuestSort>(
          showSelectedIcon: false,
          style: const ButtonStyle(visualDensity: VisualDensity.compact),
          segments: [
            for (final sort in GuestSort.values)
              ButtonSegment(
                value: sort,
                label: Text(sort.words, key: ValueKey('guests-by:${sort.name}')),
              ),
          ],
          selected: {_sort},
          onSelectionChanged: (picked) => _relay(() => _sort = picked.first),
        ),
        const SizedBox(height: 8),
        if (report.carried.isNotEmpty) _tagLists(report),
        TextField(
          key: const ValueKey('guests-find'),
          controller: _find,
          textInputAction: TextInputAction.search,
          style: theme.textTheme.bodyMedium,
          decoration: InputDecoration(
            isDense: true,
            hintText: 'Find a name or a number',
            prefixIcon: const Icon(Icons.search, size: 18),
            prefixIconConstraints: const BoxConstraints(minWidth: 36, minHeight: 44),
            suffixIconConstraints: const BoxConstraints(minWidth: 36, minHeight: 44),
            contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
            border: const OutlineInputBorder(),
            suffixIcon: _find.text.isEmpty
                ? null
                : IconButton(
                    key: const ValueKey('guests-find-clear'),
                    tooltip: 'Every guest again',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.clear, size: 18),
                    onPressed: () => _relay(_find.clear),
                  ),
          ),
          // the list is not laid out anew: that would take the keyboard from the field
          onChanged: (_) => setState(_reshow),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 2),
          child: Text(
            _shown.isEmpty
                ? (_find.text.trim().isEmpty ? 'No guest here.' : 'No guest by that name or number.')
                : [_count(_shown.length, 'guest', 'guests'), if (meaning.isNotEmpty) meaning].join(': '),
            key: const ValueKey('guests-shown'),
            style: small,
          ),
        ),
      ],
    );
  }

  /// What stands under an open guest: the note, since when, their favourite dishes and their latest visits.
  Widget _more(BuildContext context, Guest listed, GuestsReport report) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final small = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final local = MaterialLocalizations.of(context);
    final detail = _details[listed.phone];
    final failed = _detailErrors[listed.phone];
    final guest = detail?.guest ?? listed;
    final since = local.formatShortDate(DateTime.fromMillisecondsSinceEpoch(guest.sinceMs));
    final noteMs = detail?.noteMs;
    final noteBy = [
      if (detail != null && detail.noteBy.isNotEmpty) detail.noteBy,
      if (noteMs != null) _dayWords(DateTime.fromMillisecondsSinceEpoch(noteMs)),
    ].join(', ');
    final tagsMs = detail?.tagsMs;
    final tagsBy = [
      if (detail != null && detail.tagsBy.isNotEmpty && tagsMs != null) detail.tagsBy,
      if (tagsMs != null) _dayWords(DateTime.fromMillisecondsSinceEpoch(tagsMs)),
    ].join(', ');

    Widget label(String words) => Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Text(words, style: theme.textTheme.labelMedium?.copyWith(color: scheme.primary)),
    );

    return Padding(
      key: ValueKey('guest-more:${listed.phone}'),
      padding: const EdgeInsets.only(left: 30, right: 28, bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (guest.tags.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(
                'Tags: ${guest.tags.join(', ')}${tagsBy.isEmpty ? '' : ' ($tagsBy)'}',
                key: ValueKey('guest-tags:${listed.phone}'),
              ),
            ),
          if (guest.note.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(
                'Note: ${guest.note}${noteBy.isEmpty ? '' : ' ($noteBy)'}',
                key: ValueKey('guest-note:${listed.phone}'),
              ),
            ),
          // what the restaurant keeps about them is written here; a hub older than tags only reads
          if (report.keeps)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: ValueKey('guest-edit:${listed.phone}'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                icon: const Icon(Icons.sell_outlined, size: 18),
                label: Text(guest.tags.isEmpty && guest.note.isEmpty ? 'Add a tag or a note' : 'Change tags and note'),
                onPressed: () => _edit(guest),
              ),
            ),
          if (!guest.ordered)
            // in the list for their tags: there is no visit, dish or money of the year to show
            Text(
              guest.ordersEver > 0
                  ? [
                      'A guest since $since',
                      '${_count(guest.ordersEver, 'order', 'orders')} in all',
                      _noOrder(guest, report),
                    ].join(' · ')
                  : 'No order from this number yet. They are in the list for the tags they carry.',
              key: ValueKey('guest-since:${listed.phone}'),
              style: small,
            )
          else ...[
            Text(
              ['A guest since $since', '${_count(guest.ordersEver, 'order', 'orders')} in all'].join(' · '),
              key: ValueKey('guest-since:${listed.phone}'),
              style: small,
            ),
            Text(
              [
                if (guest.perVisit != null) '${dollars(guest.perVisit!)} a visit',
                ?guest.paidWords, // some of their visits were tables another guest paid
                '${_count(guest.lately, 'visit', 'visits')} in the last ${report.regularDays} days',
              ].join(' · '),
              key: ValueKey('guest-rate:${listed.phone}'),
              style: small,
            ),
            if (guest.favourites.isNotEmpty) ...[
              label('Favourite dishes'),
              for (final dish in guest.favourites)
                ReportLine(
                  key: ValueKey('guest-dish:${listed.phone}:${dish.name}'),
                  dish.name,
                  '${_many(dish.count)}×',
                ),
            ],
            label('Latest visits'),
          ],
          if (failed != null)
            Row(
              children: [
                Expanded(
                  child: Text(failed, key: ValueKey('guest-error:${listed.phone}'), style: small),
                ),
                TextButton(onPressed: () => _loadDetail(listed.phone), child: const Text('Try again')),
              ],
            )
          else if (detail == null && guest.ordered)
            Padding(
              key: ValueKey('guest-reading:${listed.phone}'),
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: const LinearProgressIndicator(),
            )
          else if (detail != null)
            for (final visit in detail.latest) ...[
              InkWell(
                key: ValueKey('guest-visit:${listed.phone}:${visit.orderId}'),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => CheckHistoryScreen(api: widget.api, token: widget.token, orderId: visit.orderId),
                  ),
                ),
                child: ReportLine(
                  [
                    _dayWords(visit.day, weekday: true),
                    // the table by its name, where the hub says which
                    visit.table.isNotEmpty ? 'Table ${visit.table}' : kindLabel(visit.kind),
                  ].join(' · '),
                  // a visit at a table somebody else paid says so where its money would stand
                  visit.unpaidWords ?? dollars(visit.net),
                  under: visit.dishWords,
                  underWide: true,
                ),
              ),
              // a table of several guests: who paid it can be said here, or said otherwise
              if (report.saysPaid && visit.shared)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    key: ValueKey('guest-visit-paid:${listed.phone}:${visit.orderId}'),
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    icon: const Icon(Icons.how_to_reg_outlined, size: 18),
                    label: Text(visit.waits ? 'Say who paid' : 'Who paid'),
                    onPressed: () => _whoPaid(visit),
                  ),
                ),
            ],
        ],
      ),
    );
  }

  Widget _guest(BuildContext context, Guest guest, int rank, GuestsReport report) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final small = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final open = _open.contains(guest.phone);
    // "regular" in green and "stopped coming" in red, as up and down are in the other reports
    final Change? standing = guest.lapsed
        ? (words: 'stopped coming', up: false)
        : guest.regular
        ? (words: 'regular', up: true)
        : null;
    return Column(
      key: ValueKey('guest:${guest.phone}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          key: ValueKey('guest-row:${guest.phone}'),
          onTap: () => _toggle(guest),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 30,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 5),
                    child: Text('$rank', style: small?.copyWith(fontFeatures: PosTheme.tabular)),
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ReportLine(
                        guest.called,
                        // a guest with no order has no figure: the line under their name says so
                        guest.ordered ? dollars(guest.spent) : '',
                        count: guest.ordered ? _count(guest.visits, 'visit', 'visits') : '',
                        under: [
                          if (guest.name.isNotEmpty) guest.number,
                          guest.ordered ? 'last ${_dayWords(guest.last)}' : _noOrder(guest, report),
                          if (guest.isNew) 'new',
                        ].join(' · '),
                        change: standing,
                        underWide: true,
                      ),
                      if (guest.tags.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 3),
                          child: Wrap(
                            key: ValueKey('guest-marks:${guest.phone}'),
                            spacing: 6,
                            runSpacing: 4,
                            children: [for (final tag in guest.tags) GuestTagMark(tag)],
                          ),
                        ),
                    ],
                  ),
                ),
                SizedBox(
                  width: 28,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 3, left: 4),
                    child: Icon(
                      open ? Icons.expand_less : Icons.expand_more,
                      size: 22,
                      color: scheme.onSurfaceVariant,
                      semanticLabel: open ? 'Close' : 'Tags, note, favourite dishes and visits',
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (open) _more(context, guest, report),
        const Divider(height: 9),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final report = _report;
    final Widget body;
    if (_error != null) {
      body = SpanError(prefix: 'guests', message: _error!, onRetry: _load);
    } else if (report == null) {
      body = const SpanReading(prefix: 'guests', many: true);
    } else {
      final small = Theme.of(context).textTheme.bodySmall
          ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);
      final shown = _shown;
      body = KeyedSubtree(
        key: ValueKey(_laid),
        child: ListView.builder(
          key: const ValueKey('guests-list'),
          controller: _scroll,
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          itemCount: shown.length + 2,
          itemBuilder: (context, index) {
            if (index == 0) return _head(context, report);
            if (index <= shown.length) return _guest(context, shown[index - 1], index, report);
            return Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                'A guest is a phone number that ordered: a table with no number on its check is not in the '
                'list. A visit is an order with a dish on it; one voided whole is none. What a guest spent is '
                'what their checks came to before tax, charges and tips, less comps and discounts. A regular '
                'came ${report.regularVisits} times or more in the last ${report.regularDays} days. A guest '
                'stopped coming who came ${report.regularVisits} times or more in the year and not for '
                '${report.lapsedDays} days. A new guest placed their first order ever in the last '
                '${report.newDays} days.'
                '${report.keeps ? ' Open a guest to put a tag on them or to write their note.' : ''}'
                '${report.tagged.isEmpty ? '' : _taggedToo}',
                key: const ValueKey('guests-note'),
                style: small,
              ),
            );
          },
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Guests'),
        actions: [
          IconButton(
            key: const ValueKey('guests-refresh'),
            tooltip: 'Read again',
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Column(
            children: [
              _chips(report),
              Expanded(child: body),
            ],
          ),
        ),
      ),
    );
  }
}
