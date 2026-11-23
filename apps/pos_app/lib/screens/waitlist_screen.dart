import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../live.dart';
import '../reservations.dart' show Book;
import '../table_timers.dart' show TimerLevel;
import '../takeout.dart' show clockTime;
import '../waitlist.dart';
import 'booked_mark.dart';
import 'guest_tag_mark.dart';
import 'party_dialog.dart';
import 'theme.dart';

/// What the waitlist was left with when a party is to sit down: the floor map comes up, and the next table
/// tapped is theirs.
class SeatParty {
  const SeatParty(this.party);

  final WaitParty party;
}

/// The waitlist was left for the reservation book (docs/reservations.md).
class OpenReservations {
  const OpenReservations();
}

/// The waitlist (docs/waitlist.md): the parties waiting for a table tonight, in the order they came. Each
/// says how long it has waited beside the wait it was told, amber when that time is nearly up and red once
/// it has passed. A party is put on the list with **Add party**, sits down with **Seat** (the floor map
/// comes up for its table), and a tap on it offers the rest: called, change, left, no-show. The ones that
/// went off the list tonight are underneath, each with a way back onto it.
///
/// At the top, when tables are booked for today that are still to sit down, a row says how many and which
/// is next (docs/reservations.md): a walk-in is told a wait with the book in sight. It leads to the book.
///
/// The hub keeps the list and tells this screen when another one changed it. Pops a [SeatParty] when a party
/// is to be seated and an [OpenReservations] for the reservation book; nothing otherwise.
class WaitlistScreen extends StatefulWidget {
  const WaitlistScreen({super.key, required this.api, required this.staffId, this.list, this.book, this.nowMs});

  final PosApi api;

  /// Who is at the screen: the list keeps who put a party on it and who took it off.
  final String staffId;

  /// The list as the screen underneath last read it, shown until the hub answers.
  final Waitlist? list;

  /// Today's reservation book as the screen underneath last read it, likewise.
  final Book? book;

  /// The hub's clock; the app's reading of it when null.
  final int Function()? nowMs;

  @override
  State<WaitlistScreen> createState() => _WaitlistScreenState();
}

enum _Do { seat, called, change, left, noShow }

class _WaitlistScreenState extends State<WaitlistScreen> {
  late Waitlist? _list = widget.list;
  late Book? _book = widget.book; // today's reservations, for the row of booked tables still to come
  bool _away = false; // no hub answers: the list is what was last read
  bool _older = false; // the hub that answers has no waitlist
  bool _earlier = false; // the parties that went off the list are shown
  String? _busy; // the party a change is on its way for
  Timer? _timer;
  // Rings once, at the next moment the clock alone changes a wait shown here: its minutes, or its colour.
  Timer? _clock;
  late final _poll = SafetyPoll(widget.api.live);
  late final _reader = Paced(const Duration(seconds: 1), _read);
  StreamSubscription<LiveChange>? _live;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (_poll.due()) unawaited(_reader.now(must: false));
    });
    _live = widget.api.live.changes.listen((change) {
      if (change.waitlist || change.reservations || change.everything) _reader();
    });
    unawaited(_reader.now());
    _armClock();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _clock?.cancel();
    unawaited(_live?.cancel());
    _reader.cancel();
    super.dispose();
  }

  int _now() => (widget.nowMs ?? widget.api.nowMs)();

  /// Today's book, for the row of booked tables. A hub that does not answer, or one older than the book,
  /// leaves the row as it was: the list is what this screen is for.
  Future<void> _readBook() async {
    try {
      final book = await widget.api.reservations();
      if (!mounted || identical(book, _book)) return;
      setState(() => _book = book);
      _armClock();
    } on ApiException {
      // the row keeps what it showed
    }
  }

  Future<void> _read() async {
    _poll.asked();
    unawaited(_readBook());
    try {
      final list = await widget.api.waitlist();
      if (!mounted) return;
      if (list == null) {
        if (!_older) setState(() => _older = true);
        return;
      }
      // with no hub answering, the api hands back the list as it was last read
      final away = !widget.api.connection.value.isOnline;
      if (identical(list, _list) && away == _away && !_older) return;
      setState(() {
        _list = list;
        _away = away;
        _older = false;
      });
      _armClock();
    } on ApiException {
      if (mounted && !_away) setState(() => _away = true);
    }
  }

  void _armClock() {
    _clock?.cancel();
    final now = _now();
    final turns = [?_list?.nextChange(now), ?_book?.nextChange(now)];
    if (turns.isEmpty) return;
    final next = turns.reduce((a, b) => a < b ? a : b);
    final wait = Duration(milliseconds: (next - now).clamp(1000, 60000) + 200);
    _clock = Timer(wait, () {
      if (!mounted) return;
      setState(() {});
      _armClock();
    });
  }

  void _say(String words, {Key? key}) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(key: key, content: Text(words)));
  }

  /// Makes one change at the hub and shows the list as it stands afterwards. What the hub refuses, and a hub
  /// that does not answer, is said in a line at the bottom.
  Future<Waitlist?> _change(String partyId, Future<Waitlist> Function() call) async {
    if (_busy != null) return null;
    setState(() => _busy = partyId);
    try {
      final list = await call();
      if (!mounted) return list;
      setState(() {
        _list = list;
        _away = false;
      });
      _armClock();
      return list;
    } on ApiException catch (err) {
      if (!mounted) return null;
      _say(
        err.status == null
            ? 'The hub cannot be reached, and the list is kept there. Try again in a moment.'
            : err.detail?['message'] as String? ?? err.message,
        key: const ValueKey('waitlist-problem'),
      );
      unawaited(_reader.now());
      return null;
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _add() async {
    final list = await showDialog<Waitlist>(
      context: context,
      builder: (_) => PartyDialog(api: widget.api, staffId: widget.staffId, list: _list ?? const Waitlist()),
    );
    if (list == null || !mounted) return;
    setState(() {
      _list = list;
      _away = false;
    });
    _armClock();
  }

  Future<void> _edit(WaitParty party) async {
    final list = await showDialog<Waitlist>(
      context: context,
      builder: (_) => PartyDialog(
        api: widget.api,
        staffId: widget.staffId,
        list: _list ?? const Waitlist(),
        party: party,
        nowMs: widget.nowMs,
      ),
    );
    if (list == null || !mounted) return;
    setState(() {
      _list = list;
      _away = false;
    });
    _armClock();
  }

  void _seat(WaitParty party) => Navigator.of(context).pop(SeatParty(party));

  /// A party was tapped: what can be done with it, as buttons.
  Future<void> _open(WaitParty party) async {
    final picked = await showModalBottomSheet<_Do>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _PartySheet(party: party, waited: party.waitedAt(_now())),
    );
    if (picked == null || !mounted) return;
    final api = widget.api, me = widget.staffId;
    switch (picked) {
      case _Do.seat:
        _seat(party);
      case _Do.called:
        await _change(party.id, () => api.partyCalled(me, party.id, on: party.calledMs == null));
      case _Do.change:
        await _edit(party);
      case _Do.left:
        final list = await _change(party.id, () => api.partyLeft(me, party.id));
        if (list != null && mounted) _undo(party, '${party.name} is off the list');
      case _Do.noShow:
        final list = await _change(party.id, () => api.partyLeft(me, party.id, why: 'no_show'));
        if (list != null && mounted) _undo(party, '${party.name} is off the list as a no-show');
    }
  }

  /// Says a party went off the list, with the way back beside it.
  void _undo(WaitParty party, String words) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          key: const ValueKey('party-off'),
          content: Text(words),
          action: SnackBarAction(label: 'Put back', onPressed: () => unawaited(_back(party, quiet: true))),
        ),
      );
  }

  Future<void> _back(WaitParty party, {bool quiet = false}) async {
    final list = await _change(party.id, () => widget.api.partyBack(widget.staffId, party.id));
    if (list == null || !mounted || quiet) return;
    _say(
      party.isSeated && party.tableLabel.isNotEmpty
          ? '${party.name} is back on the list. The check at ${party.tableLabel} stays as it is.'
          : '${party.name} is back on the list',
      key: const ValueKey('party-is-back'),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final list = _list;
    final now = _now();
    final waiting = list?.waiting ?? const <WaitParty>[];
    final earlier = list?.earlier ?? const <WaitParty>[];
    final counts = list?.counts ?? const WaitCounts();
    final toCome = _book?.toCome ?? const [];
    final muted = theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant);
    final width = MediaQuery.sizeOf(context).width;
    final side = width > 744 ? (width - 720) / 2 : 12.0;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Waitlist'),
            if (waiting.isNotEmpty)
              Text(
                '${waiting.length == 1 ? '1 party' : '${waiting.length} parties'} · ${guestWords(counts.guests)}',
                key: const ValueKey('waitlist-count'),
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
          ],
        ),
        actions: [
          // The way over to the reservation book: by its name where there is room for it.
          if (width < 600)
            IconButton(
              key: const ValueKey('waitlist-reservations'),
              tooltip: 'Reservations',
              onPressed: () => Navigator.of(context).pop(const OpenReservations()),
              icon: const Icon(Icons.event_available_outlined),
            )
          else
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: TextButton.icon(
                key: const ValueKey('waitlist-reservations'),
                onPressed: () => Navigator.of(context).pop(const OpenReservations()),
                icon: const Icon(Icons.event_available_outlined),
                label: const Text('Reservations'),
              ),
            ),
        ],
      ),
      floatingActionButton: _older
          ? null
          : FloatingActionButton.extended(
              key: const ValueKey('party-add'),
              onPressed: _add,
              icon: const Icon(Icons.person_add_alt_1_outlined),
              label: const Text('Add party'),
            ),
      body: Column(
        children: [
          if (_away && !_older)
            Material(
              key: const ValueKey('waitlist-away'),
              color: scheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: [
                    Icon(Icons.cloud_off_outlined, size: 20, color: scheme.onErrorContainer),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'The hub cannot be reached. This is the list as it was last read.',
                        style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onErrorContainer),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          Expanded(
            child: _older
                ? Center(
                    key: const ValueKey('waitlist-older'),
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        'This hub is older than the waitlist. Update the hub for it.',
                        style: muted,
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                : ListView(
                    key: const ValueKey('waitlist'),
                    // A tablet keeps the rows a hand's width: a name and its Seat button stay together.
                    padding: EdgeInsets.fromLTRB(side, 10, side, 88),
                    children: [
                      if (toCome.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: BookedToCome(
                            key: const ValueKey('waitlist-booked'),
                            toCome: toCome,
                            nowMs: now,
                            onTap: () => Navigator.of(context).pop(const OpenReservations()),
                          ),
                        ),
                      if (waiting.isEmpty)
                        Padding(
                          key: const ValueKey('waitlist-empty'),
                          padding: const EdgeInsets.symmetric(vertical: 36),
                          child: Column(
                            children: [
                              Icon(Icons.groups_2_outlined, size: 40, color: scheme.outline),
                              const SizedBox(height: 10),
                              Text(
                                list == null ? 'Reading the list…' : 'Nobody is waiting.',
                                style: muted,
                                textAlign: TextAlign.center,
                              ),
                            ],
                          ),
                        ),
                      for (final party in waiting)
                        _PartyCard(
                          key: ValueKey('party:${party.id}'),
                          party: party,
                          waited: party.waitedAt(now),
                          level: party.levelAt(now),
                          calledAgo: party.calledMs == null ? null : ((now - party.calledMs!) ~/ 60000).clamp(0, 999),
                          busy: _busy == party.id,
                          onTap: () => _open(party),
                          onSeat: () => _seat(party),
                        ),
                      if (earlier.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        ListTile(
                          key: const ValueKey('waitlist-earlier'),
                          dense: true,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          title: Text(
                            [
                              'Earlier tonight',
                              if (counts.seated > 0) '${counts.seated} seated',
                              if (counts.left > 0) '${counts.left} left',
                            ].join(' · '),
                            style: theme.textTheme.titleSmall,
                          ),
                          subtitle: counts.averageWaitMinutes == null
                              ? null
                              : Text('Seated after ${waitWords(counts.averageWaitMinutes!)} on average'),
                          trailing: Icon(_earlier ? Icons.expand_less : Icons.expand_more),
                          onTap: () => setState(() => _earlier = !_earlier),
                        ),
                        if (_earlier)
                          for (final party in earlier)
                            ListTile(
                              key: ValueKey('earlier:${party.id}'),
                              dense: true,
                              contentPadding: const EdgeInsets.only(left: 12, right: 4),
                              leading: _SizeBadge(size: party.size, muted: true),
                              title: Text(party.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                              subtitle: Text(
                                [
                                  if (party.isSeated)
                                    party.tableLabel.isEmpty ? 'Seated' : 'Seated at ${party.tableLabel}'
                                  else
                                    leftWords(party.leftWhy),
                                  if (party.waitedMinutes != null) 'after ${waitWords(party.waitedMinutes!)}',
                                  if (party.endedBy.isNotEmpty) party.endedBy,
                                ].join(' · '),
                              ),
                              trailing: TextButton(
                                key: ValueKey('party-back:${party.id}'),
                                onPressed: _busy != null ? null : () => _back(party),
                                child: const Text('Put back'),
                              ),
                            ),
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

/// How many guests a party is, in a square: what a host looks for first when a table of four comes free.
class _SizeBadge extends StatelessWidget {
  const _SizeBadge({required this.size, this.muted = false});

  final int size;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 40,
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: muted ? scheme.surfaceContainerHighest : scheme.primaryContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        '$size',
        semanticsLabel: guestWords(size),
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w800,
          color: muted ? scheme.onSurfaceVariant : scheme.onPrimaryContainer,
          fontFeatures: PosTheme.tabular,
        ),
      ),
    );
  }
}

/// One waiting party: how many, the name, how long it has waited beside what it was told, and **Seat**.
class _PartyCard extends StatelessWidget {
  const _PartyCard({
    super.key,
    required this.party,
    required this.waited,
    required this.level,
    required this.calledAgo,
    required this.busy,
    required this.onTap,
    required this.onSeat,
  });

  final WaitParty party;
  final int waited;
  final TimerLevel level;

  /// The minutes since it was told its table is ready; null when it was not.
  final int? calledAgo;
  final bool busy;
  final VoidCallback onTap;
  final VoidCallback onSeat;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final pos = PosColors.of(context);
    final (pill, pillText) = switch (level) {
      TimerLevel.ok => (scheme.surfaceContainerHighest, scheme.onSurface),
      TimerLevel.warn => (pos.timerWarn, pos.timerWarnText),
      TimerLevel.late => (pos.timerLate, pos.timerLateText),
    };
    final small = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final quoted = party.quotedMinutes;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: busy ? null : onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
          child: Row(
            children: [
              _SizeBadge(size: party.size),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(party.name, style: theme.textTheme.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 3),
                    Wrap(
                      spacing: 6,
                      runSpacing: 2,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Container(
                          key: ValueKey('party-wait:${party.id}'),
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                          decoration: BoxDecoration(color: pill, borderRadius: BorderRadius.circular(8)),
                          child: Text(
                            waitWords(waited),
                            semanticsLabel:
                                'waited ${waitWords(waited)}'
                                '${level == TimerLevel.late
                                    ? ', past the time told'
                                    : level == TimerLevel.warn
                                    ? ', nearly the time told'
                                    : ''}',
                            style: theme.textTheme.labelLarge?.copyWith(
                              color: pillText,
                              fontWeight: FontWeight.w700,
                              fontFeatures: PosTheme.tabular,
                            ),
                          ),
                        ),
                        Text(quoted == null ? 'no time told' : 'told ${waitWords(quoted)}', style: small),
                        if (calledAgo != null)
                          Text(
                            calledAgo == 0 ? 'called just now' : 'called ${waitWords(calledAgo!)} ago',
                            key: ValueKey('party-called:${party.id}'),
                            style: small?.copyWith(color: scheme.primary, fontWeight: FontWeight.w600),
                          ),
                        // who it is, as the guest list has them ("VIP"), before what they asked for
                        for (final tag in party.tags) GuestTagMark(tag, key: ValueKey('party-tag:${party.id}:$tag')),
                        if (party.note.isNotEmpty) Text(party.note, style: small),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.tonal(
                key: ValueKey('party-seat:${party.id}'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: busy ? null : onSeat,
                child: const Text('Seat'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// What can be done with a waiting party, as buttons, under what the host knows of it.
class _PartySheet extends StatelessWidget {
  const _PartySheet({required this.party, required this.waited});

  final WaitParty party;
  final int waited;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final quoted = party.quotedMinutes;
    Widget button(_Do what, String key, IconData icon, String label, {bool strong = false}) {
      final child = Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 22),
          const SizedBox(height: 4),
          Text(label, textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis),
        ],
      );
      final style = FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      );
      void pick() => Navigator.of(context).pop(what);
      return strong
          ? FilledButton(key: ValueKey('party-do:$key'), style: style, onPressed: pick, child: child)
          : FilledButton.tonal(key: ValueKey('party-do:$key'), style: style, onPressed: pick, child: child);
    }

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(party.label, style: theme.textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              [
                'Came at ${clockTime(party.atMs)}',
                'waited ${waitWords(waited)}',
                quoted == null ? 'no time told' : 'told ${waitWords(quoted)}',
                if (party.by.isNotEmpty) 'added by ${party.by}',
              ].join(' · '),
              style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
            if (party.phone.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(
                  children: [
                    Icon(Icons.phone_outlined, size: 18, color: scheme.onSurfaceVariant),
                    const SizedBox(width: 6),
                    SelectableText(
                      party.phone,
                      key: const ValueKey('party-sheet-phone'),
                      style: theme.textTheme.titleMedium,
                    ),
                  ],
                ),
              ),
            if (party.tags.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Wrap(
                  key: const ValueKey('party-sheet-tags'),
                  spacing: 6,
                  runSpacing: 4,
                  children: [for (final tag in party.tags) GuestTagMark(tag)],
                ),
              ),
            if (party.note.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(party.note, key: const ValueKey('party-sheet-note'), style: theme.textTheme.bodyLarge),
              ),
            const SizedBox(height: 14),
            // The same grid of buttons a dish's choices are, three across: each tall enough for its picture
            // and two lines of words at the size the person reads at.
            GridView(
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                mainAxisExtent: 44 + MediaQuery.textScalerOf(context).scale(40),
              ),
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                button(_Do.seat, 'seat', Icons.event_seat_outlined, 'Seat', strong: true),
                button(
                  _Do.called,
                  'called',
                  party.calledMs == null ? Icons.campaign_outlined : Icons.undo,
                  party.calledMs == null ? 'Called' : 'Not called',
                ),
                button(_Do.change, 'change', Icons.edit_outlined, 'Change'),
                button(_Do.left, 'left', Icons.directions_walk, 'Left'),
                button(_Do.noShow, 'no_show', Icons.person_off_outlined, 'No-show'),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
