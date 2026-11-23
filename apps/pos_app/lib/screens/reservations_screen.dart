import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../live.dart';
import '../reservations.dart';
import '../table_timers.dart' show TimerLevel;
import '../takeout.dart' show clockTime, dayName;
import 'booking_dialog.dart';
import 'guest_tag_mark.dart';
import 'guests_picker.dart';
import 'tag_guest.dart';
import 'theme.dart';

/// What the book was left with when a party with a reservation is to sit down: the floor map comes up, and
/// the next table tapped is theirs.
class SeatBooking {
  const SeatBooking(this.booking);

  final Booking booking;
}

/// The book was left for the waitlist.
class OpenWaitlist {
  const OpenWaitlist();
}

/// The reservation book (docs/reservations.md): the tables booked for a day, in the order of their times.
/// Today's is open first; the days ahead that have a reservation are a tap away, and any other day is on
/// the calendar. A table is booked with **Book a table**; a party of today sits down with **Seat** (the
/// floor map comes up for its table), and a tap on a reservation offers the rest: here, change, cancel,
/// no-show. The ones that ended are underneath, each with a way back into the book. A day that is over is
/// read, and nothing in it changes.
///
/// The hub keeps the book and tells this screen when another one changed it. Pops a [SeatBooking] when a
/// party is to be seated and an [OpenWaitlist] for the waitlist; nothing otherwise.
class ReservationsScreen extends StatefulWidget {
  const ReservationsScreen({
    super.key,
    required this.api,
    required this.staffId,
    this.nowMs,
    this.waitlist = true,
    this.day,
    this.open,
    this.device,
  });

  final PosApi api;

  /// This device's name, for the PIN that tags a guest from their reservation (docs/guest-list.md, "From a
  /// reservation or the waitlist"). Null offers no Tags button.
  final String? device;

  /// Who is at the screen: the book keeps who booked a table and who ended a reservation.
  final String staffId;

  /// The hub's clock; the app's reading of it when null.
  final int Function()? nowMs;

  /// Whether the way over to the waitlist is offered.
  final bool waitlist;

  /// The day the book opens at ("2026-11-21"); the hub's today when null.
  final String? day;

  /// A reservation of that day to open as if it had been tapped, once the book is read: the one somebody
  /// is calling about. Nothing opens when it stands no longer.
  final String? open;

  @override
  State<ReservationsScreen> createState() => _ReservationsScreenState();
}

enum _Do { seat, here, change, cancel, noShow, tags }

class _ReservationsScreenState extends State<ReservationsScreen> {
  Book? _book;
  late String? _day = widget.day; // the day shown ("2026-11-21"); null is the hub's today
  late String? _toOpen = widget.open; // the reservation to open when the book is first read
  bool _away = false; // no hub answers: the book is what was last read, or nothing
  bool _older = false; // the hub that answers has no reservations
  bool _earlier = false; // the reservations that ended are shown
  String? _busy; // the reservation a change is on its way for
  Timer? _timer;
  // Rings once, at the next moment the clock alone changes a colour shown here.
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
      if (change.reservations || change.everything) _reader();
    });
    unawaited(_reader.now());
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

  Future<void> _read() async {
    _poll.asked();
    final day = _day;
    try {
      final book = await widget.api.reservations(day: day);
      if (!mounted || day != _day) return; // another day was picked meanwhile: its own read is on the way
      if (book == null) {
        if (!_older) setState(() => _older = true);
        return;
      }
      // with no hub answering, the api hands back today's book as it was last read
      final away = !widget.api.connection.value.isOnline;
      if (identical(book, _book) && away == _away && !_older) return;
      setState(() {
        _book = book;
        _away = away;
        _older = false;
        if (book.isToday) _day = null; // a book opened at the day it is: today's from here on
      });
      _armClock();
      _openAsked(book);
    } on ApiException {
      if (mounted && !_away) setState(() => _away = true);
    }
  }

  /// The reservation the screen was opened for comes up once, when its day's book is first read.
  void _openAsked(Book book) {
    final id = _toOpen;
    if (id == null) return;
    _toOpen = null;
    for (final booking in book.booked) {
      if (booking.id != id) continue;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_open(booking));
      });
      return;
    }
  }

  void _armClock() {
    _clock?.cancel();
    final now = _now();
    final next = _book?.nextChange(now);
    if (next == null) return;
    _clock = Timer(Duration(milliseconds: (next - now).clamp(1000, 3600000) + 200), () {
      if (!mounted) return;
      setState(() {});
      _armClock();
    });
  }

  /// Another day's book: [day] as the hub names it; today's for null or for the hub's today.
  void _show(String? day) {
    final to = day == null || day == _book?.today ? null : day;
    if (to == _day) return;
    setState(() {
      _day = to;
      _earlier = false;
      // what is on the screen is another day's: it goes, and the day asked for is read
      if (_book != null && _book!.day != (to ?? _book!.today)) _book = _emptyDay(to ?? _book!.today, _book!);
    });
    _armClock();
    unawaited(_reader.now());
  }

  /// The book of [day] before the hub answered for it: nothing in it yet, under the same days ahead.
  static Book _emptyDay(String day, Book from) => Book(
    day: day,
    today: from.today,
    ahead: from.ahead,
    mostGuests: from.mostGuests,
    mostAheadDays: from.mostAheadDays,
    holdMinutes: from.holdMinutes,
    nameMax: from.nameMax,
    noteMax: from.noteMax,
  );

  /// The book as the hub answered a change: the day the reservation is for now, which the screen follows.
  void _took(Book book) {
    setState(() {
      _book = book;
      _day = book.isToday ? null : book.day;
      _away = false;
    });
    _armClock();
  }

  Future<void> _pickDay() async {
    final book = _book;
    final today = bookDay(book?.today ?? '') ?? DateTime.now();
    final first = DateTime(today.year, today.month, today.day);
    final shown = bookDay(book?.day ?? '') ?? first;
    final to = await showDatePicker(
      context: context,
      initialDate: DateTime(shown.year, shown.month, shown.day),
      firstDate: DateTime(first.year - 1, first.month, first.day),
      lastDate: DateTime(first.year, first.month, first.day + (book?.mostAheadDays ?? 366)),
      helpText: 'The day to look at',
    );
    if (to != null && mounted) _show(isoDay(to));
  }

  void _say(String words, {Key? key}) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(key: key, content: Text(words)));
  }

  /// Makes one change at the hub and shows the book as it stands afterwards. What the hub refuses, and a hub
  /// that does not answer, is said in a line at the bottom.
  Future<Book?> _change(String bookingId, Future<Book> Function() call) async {
    if (_busy != null) return null;
    setState(() => _busy = bookingId);
    try {
      final book = await call();
      if (!mounted) return book;
      _took(book);
      return book;
    } on ApiException catch (err) {
      if (!mounted) return null;
      _say(
        err.status == null
            ? 'The hub cannot be reached, and the book is kept there. Try again in a moment.'
            : err.detail?['message'] as String? ?? err.message,
        key: const ValueKey('book-problem'),
      );
      unawaited(_reader.now());
      return null;
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _edit([Booking? booking]) async {
    final shown = _book ?? const Book();
    final book = await showDialog<Book>(
      context: context,
      builder: (_) => BookingDialog(api: widget.api, staffId: widget.staffId, book: shown, booking: booking),
    );
    if (book == null || !mounted) return;
    final moved = book.day != shown.day;
    _took(book);
    final saved = book.booking;
    if (saved == null) return;
    final when = '${_lower(bookDayWords(saved.day, book.today))} at ${saved.time}';
    _say(
      booking == null
          ? '${saved.name} is booked for $when'
          : moved
          ? '${saved.name} is now booked for $when'
          : '${saved.name} is put right',
      key: const ValueKey('booking-saved'),
    );
  }

  void _seat(Booking booking) => Navigator.of(context).pop(SeatBooking(booking));

  /// A reservation was tapped: what the host knows of it, over what can be done with it, as buttons.
  Future<void> _open(Booking booking) async {
    final book = _book;
    if (book == null) return;
    final picked = await showModalBottomSheet<_Do>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) =>
          _BookingSheet(booking: booking, book: book, tags: widget.device != null && canTagGuest(booking.phone)),
    );
    if (picked == null || !mounted) return;
    final api = widget.api, me = widget.staffId;
    switch (picked) {
      case _Do.seat:
        _seat(booking);
      case _Do.here:
        await _change(booking.id, () => api.bookingArrived(me, booking.id, on: !booking.isHere));
      case _Do.change:
        await _edit(booking);
      case _Do.cancel:
        final after = await _change(booking.id, () => api.cancelBooking(me, booking.id));
        if (after != null && mounted) _undo(booking, '${booking.name}\'s reservation is cancelled');
      case _Do.noShow:
        final after = await _change(booking.id, () => api.cancelBooking(me, booking.id, why: 'no_show'));
        if (after != null && mounted) _undo(booking, '${booking.name} is marked a no-show');
      case _Do.tags:
        await _tag(booking);
    }
  }

  /// The guest's tags, put on or taken off from their reservation by whoever may read the guest list. They
  /// are the number's and not the reservation's: the book only shows them, and reads again to do so.
  Future<void> _tag(Booking booking) async {
    final device = widget.device;
    if (device == null) return;
    final kept = await tagGuestHere(context, api: widget.api, device: device, name: booking.name, phone: booking.phone);
    if (kept == null || !mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(key: const ValueKey('guest-tagged'), content: Text(tagsSavedWords(booking.name, kept))));
    await _read();
  }

  /// Says a reservation went out of the book, with the way back beside it.
  void _undo(Booking booking, String words) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          key: const ValueKey('booking-off'),
          content: Text(words),
          action: SnackBarAction(label: 'Put back', onPressed: () => unawaited(_back(booking, quiet: true))),
        ),
      );
  }

  Future<void> _back(Booking booking, {bool quiet = false}) async {
    final book = await _change(booking.id, () => widget.api.bookingBack(widget.staffId, booking.id));
    if (book == null || !mounted || quiet) return;
    _say(
      booking.isSeated && booking.seatedLabel.isNotEmpty
          ? '${booking.name} is back in the book. The check at ${booking.seatedLabel} stays as it is.'
          : '${booking.name} is back in the book',
      key: const ValueKey('booking-is-back'),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final book = _book;
    final now = _now();
    final booked = book?.booked ?? const <Booking>[];
    final earlier = book?.earlier ?? const <Booking>[];
    final counts = book?.counts ?? const BookCounts();
    final muted = theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant);
    final width = MediaQuery.sizeOf(context).width;
    final side = width > 744 ? (width - 720) / 2 : 12.0;
    final today = book?.today ?? '';
    final shown = book?.day ?? '';
    final words = book == null ? '' : bookDayWords(shown, today);
    final over = book?.isOver ?? false;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Reservations'),
            if (book != null && !_older)
              Text(
                [
                  if (words == 'Today' || words == 'Tomorrow' || words == 'Yesterday')
                    '$words, ${dayName(bookDay(shown)!)}'
                  else
                    words,
                  if (booked.isNotEmpty) bookedWords(booked.length, counts.guests),
                ].join(' · '),
                key: const ValueKey('book-count'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
          ],
        ),
        actions: [
          // The way over to the waitlist: by its name where there is room for it.
          if (widget.waitlist && width < 600)
            IconButton(
              key: const ValueKey('book-waitlist'),
              tooltip: 'Waitlist',
              onPressed: () => Navigator.of(context).pop(const OpenWaitlist()),
              icon: const Icon(Icons.groups_2_outlined),
            )
          else if (widget.waitlist)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: TextButton.icon(
                key: const ValueKey('book-waitlist'),
                onPressed: () => Navigator.of(context).pop(const OpenWaitlist()),
                icon: const Icon(Icons.groups_2_outlined),
                label: const Text('Waitlist'),
              ),
            ),
        ],
      ),
      floatingActionButton: _older || book == null || over
          ? null
          : FloatingActionButton.extended(
              key: const ValueKey('booking-add'),
              onPressed: _edit,
              icon: const Icon(Icons.event_available_outlined),
              label: const Text('Book a table'),
            ),
      body: Column(
        children: [
          if (_away && !_older)
            Material(
              key: const ValueKey('book-away'),
              color: scheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: [
                    Icon(Icons.cloud_off_outlined, size: 20, color: scheme.onErrorContainer),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        book == null
                            ? 'The hub cannot be reached, and the book is kept there.'
                            : 'The hub cannot be reached. This is the book as it was last read.',
                        style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onErrorContainer),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (book != null && !_older) _DayStrip(book: book, side: side, onDay: _show, onPick: _pickDay),
          Expanded(
            child: _older
                ? Center(
                    key: const ValueKey('book-older'),
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        'This hub is older than reservations. Update the hub for them.',
                        style: muted,
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                : ListView(
                    key: const ValueKey('book'),
                    // A tablet keeps the rows a hand's width: a name and its Seat button stay together.
                    padding: EdgeInsets.fromLTRB(side, 6, side, 88),
                    children: [
                      if (over)
                        Padding(
                          key: const ValueKey('book-over'),
                          padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
                          child: Text('This day is over. Its reservations are as they ended.', style: muted),
                        ),
                      if (booked.isEmpty)
                        Padding(
                          key: const ValueKey('book-empty'),
                          padding: const EdgeInsets.symmetric(vertical: 36),
                          child: Column(
                            children: [
                              Icon(Icons.event_available_outlined, size: 40, color: scheme.outline),
                              const SizedBox(height: 10),
                              Text(
                                book == null
                                    ? (_away ? 'Nothing was read yet.' : 'Reading the book…')
                                    : over
                                    ? (earlier.isEmpty ? 'No tables were booked.' : 'None was left standing.')
                                    : earlier.isEmpty
                                    ? 'No tables are booked for ${_lower(words)}.'
                                    : 'No more tables are booked for ${_lower(words)}.',
                                style: muted,
                                textAlign: TextAlign.center,
                              ),
                            ],
                          ),
                        ),
                      for (final booking in booked)
                        _BookingCard(
                          key: ValueKey('booking:${booking.id}'),
                          booking: booking,
                          level: book!.isToday ? booking.levelAt(now) : TimerLevel.ok,
                          today: book.isToday,
                          busy: _busy == booking.id,
                          onTap: () => _open(booking),
                          onSeat: () => _seat(booking),
                        ),
                      if (earlier.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        ListTile(
                          key: const ValueKey('book-earlier'),
                          dense: true,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          title: Text(
                            [
                              if (counts.seated > 0) '${counts.seated} seated',
                              if (counts.cancelled > 0) '${counts.cancelled} cancelled',
                              if (counts.noShow > 0) counts.noShow == 1 ? '1 no-show' : '${counts.noShow} no-shows',
                            ].join(' · '),
                            style: theme.textTheme.titleSmall,
                          ),
                          trailing: Icon(_earlier ? Icons.expand_less : Icons.expand_more),
                          onTap: () => setState(() => _earlier = !_earlier),
                        ),
                        if (_earlier)
                          for (final booking in earlier)
                            ListTile(
                              key: ValueKey('earlier:${booking.id}'),
                              dense: true,
                              contentPadding: const EdgeInsets.only(left: 12, right: 4),
                              leading: GuestsBadge(size: booking.size, muted: true),
                              title: Text(
                                booking.name.isEmpty ? 'Name not kept' : booking.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                [
                                  endedWords(booking),
                                  'booked for ${booking.time}',
                                  if (booking.endedBy.isNotEmpty) booking.endedBy,
                                ].join(' · '),
                              ),
                              onTap: () => _open(booking),
                              trailing: over
                                  ? null
                                  : TextButton(
                                      key: ValueKey('booking-back:${booking.id}'),
                                      onPressed: _busy != null ? null : () => _back(booking),
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

  /// "Today" in the middle of a sentence; a date stays as it is.
  static String _lower(String words) =>
      words == 'Today' || words == 'Tomorrow' || words == 'Yesterday' ? words.toLowerCase() : words;
}

/// The days of the book, as a strip of chips that scrolls sideways: today, tomorrow, every later day with a
/// reservation standing (each with how many), the day shown when it is none of those, and the calendar for
/// any other.
class _DayStrip extends StatelessWidget {
  const _DayStrip({required this.book, required this.side, required this.onDay, required this.onPick});

  final Book book;
  final double side;
  final ValueChanged<String?> onDay;
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    final today = book.today;
    final at = bookDay(today);
    final tomorrow = at == null ? '' : isoDay(DateTime.utc(at.year, at.month, at.day + 1));
    final parties = {for (final day in book.ahead) day.day: day.parties};
    // today and tomorrow always, then the days that have a table booked, then the one shown if it is another
    final days = <String>{today, if (tomorrow.isNotEmpty) tomorrow, ...parties.keys, book.day}.toList()..sort();
    String label(String day) {
      final words = bookDayWords(day, today);
      final count = parties[day] ?? 0;
      return count == 0 ? words : '$words · $count';
    }

    return SizedBox(
      height: 48,
      child: ListView(
        key: const ValueKey('book-days'),
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: side, vertical: 6),
        children: [
          for (final day in days) ...[
            ChoiceChip(
              key: ValueKey('book-day:$day'),
              label: Text(label(day)),
              visualDensity: VisualDensity.compact,
              showCheckmark: false,
              selected: day == book.day,
              onSelected: (_) => onDay(day),
            ),
            const SizedBox(width: 6),
          ],
          ActionChip(
            key: const ValueKey('book-day:pick'),
            avatar: const Icon(Icons.calendar_month_outlined, size: 18),
            label: const Text('Another day'),
            visualDensity: VisualDensity.compact,
            onPressed: onPick,
          ),
        ],
      ),
    );
  }
}

/// One standing reservation: its time, how many, the name, what the host should know, and **Seat** on a
/// reservation of today. The time is amber when it is near and red once it has passed with nobody seated.
class _BookingCard extends StatelessWidget {
  const _BookingCard({
    super.key,
    required this.booking,
    required this.level,
    required this.today,
    required this.busy,
    required this.onTap,
    required this.onSeat,
  });

  final Booking booking;
  final TimerLevel level;

  /// The reservation is for today: its party can be seated.
  final bool today;
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
    final clash = booking.clashAtMs;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: busy ? null : onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
          child: Row(
            children: [
              GuestsBadge(size: booking.size),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      booking.name,
                      style: theme.textTheme.titleMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 3),
                    Wrap(
                      spacing: 6,
                      runSpacing: 2,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Container(
                          key: ValueKey('booking-time:${booking.id}'),
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                          decoration: BoxDecoration(color: pill, borderRadius: BorderRadius.circular(8)),
                          child: Text(
                            booking.time,
                            semanticsLabel:
                                'booked for ${booking.time}'
                                '${level == TimerLevel.late
                                    ? ', past its time'
                                    : level == TimerLevel.warn
                                    ? ', nearly its time'
                                    : ''}',
                            style: theme.textTheme.labelLarge?.copyWith(
                              color: pillText,
                              fontWeight: FontWeight.w700,
                              fontFeatures: PosTheme.tabular,
                            ),
                          ),
                        ),
                        if (booking.tableLabel.isNotEmpty)
                          Text(
                            'table ${booking.tableLabel}',
                            key: ValueKey('booking-table:${booking.id}'),
                            style: small?.copyWith(color: scheme.onSurface, fontWeight: FontWeight.w600),
                          ),
                        if (booking.isHere)
                          // a tag of its own, so it is not taken for the warning in red beside it
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                            decoration: BoxDecoration(
                              color: scheme.primaryContainer,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              'here since ${clockTime(booking.arrivedMs!)}',
                              key: ValueKey('booking-here:${booking.id}'),
                              style: small?.copyWith(color: scheme.onPrimaryContainer, fontWeight: FontWeight.w600),
                            ),
                          ),
                        if (booking.isOnline)
                          // the guest booked it on the website: nobody here spoke to them
                          Text(
                            'online',
                            key: ValueKey('booking-online:${booking.id}'),
                            semanticsLabel: 'booked on the website',
                            style: small?.copyWith(color: scheme.tertiary, fontWeight: FontWeight.w600),
                          ),
                        // who it is, as the guest list has them ("VIP"), before what they asked for
                        for (final tag in booking.tags)
                          GuestTagMark(tag, key: ValueKey('booking-tag:${booking.id}:$tag')),
                        if (booking.note.isNotEmpty) Text(booking.note, style: small),
                        if (clash != null)
                          Text(
                            '${booking.tableLabel} is also held for ${booking.clashName} at ${clockTime(clash)}',
                            key: ValueKey('booking-clash:${booking.id}'),
                            style: small?.copyWith(color: scheme.error, fontWeight: FontWeight.w600),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              if (today) ...[
                const SizedBox(width: 8),
                FilledButton.tonal(
                  key: ValueKey('booking-seat:${booking.id}'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: busy ? null : onSeat,
                  child: const Text('Seat'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// What the host knows of a reservation, over what can be done with it, as buttons: everything for one of
/// today, change and cancel for a later day, nothing for one that ended or whose day is over.
class _BookingSheet extends StatelessWidget {
  const _BookingSheet({required this.booking, required this.book, this.tags = false});

  final Booking booking;
  final Book book;

  /// Whether Tags is among the buttons: the reservation has a phone number to keep the guest's tags by.
  final bool tags;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final on = bookDay(booking.day);
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
          ? FilledButton(key: ValueKey('booking-do:$key'), style: style, onPressed: pick, child: child)
          : FilledButton.tonal(key: ValueKey('booking-do:$key'), style: style, onPressed: pick, child: child);
    }

    final open = booking.isBooked && !book.isOver;
    final today = book.isToday;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(booking.name.isEmpty ? 'Party of ${booking.size}' : booking.label, style: theme.textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              [
                '${on == null ? booking.day : dayName(on)} at ${booking.time}',
                if (booking.tableLabel.isNotEmpty) 'table ${booking.tableLabel}',
                if (!booking.isBooked) endedWords(booking),
                if (booking.bookedBy.isNotEmpty) booking.bookedBy,
              ].join(' · '),
              key: const ValueKey('booking-sheet-when'),
              style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
            if (booking.phone.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(
                  children: [
                    Icon(Icons.phone_outlined, size: 18, color: scheme.onSurfaceVariant),
                    const SizedBox(width: 6),
                    SelectableText(
                      booking.phone,
                      key: const ValueKey('booking-sheet-phone'),
                      style: theme.textTheme.titleMedium,
                    ),
                  ],
                ),
              ),
            if (booking.tags.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Wrap(
                  key: const ValueKey('booking-sheet-tags'),
                  spacing: 6,
                  runSpacing: 4,
                  children: [for (final tag in booking.tags) GuestTagMark(tag)],
                ),
              ),
            if (booking.note.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(booking.note, key: const ValueKey('booking-sheet-note'), style: theme.textTheme.bodyLarge),
              ),
            if (open) ...[
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
                  if (today) button(_Do.seat, 'seat', Icons.event_seat_outlined, 'Seat', strong: true),
                  if (today)
                    button(
                      _Do.here,
                      'here',
                      booking.isHere ? Icons.undo : Icons.emoji_people_outlined,
                      booking.isHere ? 'Not here' : 'Here',
                    ),
                  button(_Do.change, 'change', Icons.edit_outlined, 'Change'),
                  button(_Do.cancel, 'cancel', Icons.event_busy_outlined, 'Cancel it'),
                  if (today) button(_Do.noShow, 'no_show', Icons.person_off_outlined, 'No-show'),
                  if (tags) button(_Do.tags, 'tags', Icons.sell_outlined, 'Tags'),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
