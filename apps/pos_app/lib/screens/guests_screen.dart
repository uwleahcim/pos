import 'package:flutter/material.dart';

import '../api.dart';
import '../day_report.dart' show dollars, kindLabel;
import '../guests_report.dart';
import '../sales_report.dart' show Change;
import 'check_history_screen.dart';
import 'span_report.dart';
import 'theme.dart';

/// The guest list, for a manager (docs/guest-list.md): every customer who ordered with a phone number in
/// the last year, with how often they came, what they spent and when they were last here; the regulars, the
/// guests who stopped coming and the new ones each a list of their own; by what they spent, how often they
/// came or who was here last; and a name or a number to find one. A guest opens to their favourite dishes
/// and their latest visits, each of which opens its check's history. The hub does every sum; this only
/// picks the lists out and puts them in order. Nothing is written from here.
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
    _shown = report == null ? const [] : sortedGuests(guestsNamed(guestsOf(report.guests, _list), _find.text), _sort);
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
            chip(GuestList.all, 'all', totals?.guests),
            chip(GuestList.regulars, 'regulars', totals?.regulars),
            chip(GuestList.lapsed, 'lapsed', totals?.lapsed),
            chip(GuestList.fresh, 'new', totals?.fresh),
          ],
        ),
      ),
    );
  }

  /// What stands over the list: the year it reads, what all the guests came to, and how it is ordered.
  Widget _head(BuildContext context, GuestsReport report) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final local = MaterialLocalizations.of(context);
    final totals = report.totals;
    final meaning = _meaning(report);
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
          '${local.formatShortDate(report.last)}.',
          key: const ValueKey('guests-span'),
          style: small,
        ),
        const SizedBox(height: 6),
        ReportLine(
          key: const ValueKey('guests-total'),
          'Guests',
          _many(totals.guests),
          under: [
            _count(totals.regulars, 'regular', 'regulars'),
            '${_many(totals.lapsed)} stopped coming',
            '${_many(totals.fresh)} new',
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
          if (guest.note.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(
                'Note: ${guest.note}${noteBy.isEmpty ? '' : ' ($noteBy)'}',
                key: ValueKey('guest-note:${listed.phone}'),
              ),
            ),
          Text(
            ['A guest since $since', '${_count(guest.ordersEver, 'order', 'orders')} in all'].join(' · '),
            key: ValueKey('guest-since:${listed.phone}'),
            style: small,
          ),
          Text(
            [
              if (guest.perVisit != null) '${dollars(guest.perVisit!)} a visit',
              '${_count(guest.lately, 'visit', 'visits')} in the last ${report.regularDays} days',
            ].join(' · '),
            key: ValueKey('guest-rate:${listed.phone}'),
            style: small,
          ),
          if (guest.favourites.isNotEmpty) ...[
            label('Favourite dishes'),
            for (final dish in guest.favourites)
              ReportLine(key: ValueKey('guest-dish:${listed.phone}:${dish.name}'), dish.name, '${_many(dish.count)}×'),
          ],
          label('Latest visits'),
          if (failed != null)
            Row(
              children: [
                Expanded(
                  child: Text(failed, key: ValueKey('guest-error:${listed.phone}'), style: small),
                ),
                TextButton(onPressed: () => _loadDetail(listed.phone), child: const Text('Try again')),
              ],
            )
          else if (detail == null)
            Padding(
              key: ValueKey('guest-reading:${listed.phone}'),
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: const LinearProgressIndicator(),
            )
          else
            for (final visit in detail.latest)
              InkWell(
                key: ValueKey('guest-visit:${listed.phone}:${visit.orderId}'),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => CheckHistoryScreen(api: widget.api, token: widget.token, orderId: visit.orderId),
                  ),
                ),
                child: ReportLine(
                  [_dayWords(visit.day, weekday: true), kindLabel(visit.kind)].join(' · '),
                  dollars(visit.net),
                  under: visit.dishWords,
                  underWide: true,
                ),
              ),
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
                  child: ReportLine(
                    guest.called,
                    dollars(guest.spent),
                    count: _count(guest.visits, 'visit', 'visits'),
                    under: [
                      if (guest.name.isNotEmpty) guest.number,
                      'last ${_dayWords(guest.last)}',
                      if (guest.isNew) 'new',
                    ].join(' · '),
                    change: standing,
                    underWide: true,
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
                      semanticLabel: open ? 'Close' : 'Favourite dishes and visits',
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
                '${report.newDays} days.',
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
