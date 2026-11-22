import 'floor.dart' show TableHold, TableSpot;
import 'table_timers.dart' show TimerLevel;
import 'takeout.dart' show dayName;
import 'waitlist.dart' show ArrivingParty, guestWords;

/// The reservation book as the hub answers it (docs/reservations.md): the tables booked for a day, in the
/// order of their times, and the reservations of that day that ended. The hub makes every rule and stamps
/// every time with its own clock; this is its answers read into names, and the words the screens say about
/// them.

String _s(Object? value, [String or = '']) => value is String ? value : or;
int _i(Object? value, [int or = 0]) => value is num ? value.toInt() : or;
int? _ms(Object? value) => value is num ? value.toInt() : null;
List<Map<String, dynamic>> _rows(Object? value) => [
  if (value is List)
    for (final row in value)
      if (row is Map) row.cast<String, dynamic>(),
];

/// One reservation.
class Booking implements ArrivingParty {
  const Booking({
    required this.id,
    required this.name,
    required this.size,
    this.phone = '',
    this.note = '',
    this.atMs = 0,
    this.day = '',
    this.time = '',
    this.table = '',
    this.tableLabel = '',
    this.madeMs = 0,
    this.by = '',
    this.online = '',
    this.status = 'booked',
    this.soonMs,
    this.lateMs,
    this.arrivedMs,
    this.seatedLabel = '',
    this.seatedTable = '',
    this.orderId = '',
    this.endedBy = '',
    this.clashName = '',
    this.clashAtMs,
  });

  factory Booking.fromJson(Map<String, dynamic> json) {
    final clash = json['clash'];
    return Booking(
      id: _s(json['id']),
      name: _s(json['name']),
      size: _i(json['size'], 1),
      phone: _s(json['phone']),
      note: _s(json['note']),
      atMs: _i(json['at_ms']),
      day: _s(json['day']),
      time: _s(json['time']),
      table: _s(json['table']),
      tableLabel: _s(json['table_label']),
      madeMs: _i(json['made_ms']),
      by: _s(json['by']),
      online: _s(json['online']),
      status: _s(json['status'], 'booked'),
      soonMs: _ms(json['soon_ms']),
      lateMs: _ms(json['late_ms']),
      arrivedMs: _ms(json['arrived_ms']),
      seatedTable: _s(json['seated_table']),
      seatedLabel: _s(json['seated_label']),
      orderId: _s(json['order_id']),
      endedBy: _s(json['ended_by']),
      clashName: clash is Map ? _s(clash['name']) : '',
      clashAtMs: clash is Map ? _ms(clash['at_ms']) : null,
    );
  }

  /// The reservation a table on the floor map is held for ([hold], at [table]), to seat its party from the
  /// map: what the map was told of it, which is all that seating it needs.
  factory Booking.ofHold(TableHold hold, TableSpot table) => Booking(
    id: hold.id,
    name: hold.name,
    size: hold.size,
    atMs: hold.atMs,
    time: hold.time,
    table: table.id,
    tableLabel: table.label,
    soonMs: hold.soonMs,
    lateMs: hold.lateMs,
    arrivedMs: hold.arrivedMs,
  );

  @override
  final String id;
  @override
  final String name;

  /// How many guests.
  @override
  final int size;
  final String phone;
  final String note;

  /// The time the table is booked for, by the hub's clock; [day] is the day of service it falls in
  /// ("2026-11-21") and [time] the time on the restaurant's clock ("18:30").
  final int atMs;
  final String day;
  final String time;

  /// The table held for them; empty when none was picked.
  final String table;
  final String tableLabel;

  /// When it was written into the book, and who by.
  final int madeMs;
  final String by;

  /// The website's own number for a table that was booked there and that the hub wrote into the book by
  /// itself (docs/online-orders.md): what to find it by in GloriaFood's app. Empty for one a person wrote in.
  final String online;

  /// `booked`, `seated`, `cancelled` or `no_show`.
  final String status;

  /// When its time is near (amber from then), and when it is past with nobody seated (red from then).
  final int? soonMs;
  final int? lateMs;

  /// When the party came in, for one that waits for its table; null when it has not.
  final int? arrivedMs;

  /// Where they sat down, which need not be the table held, and the check opened for them.
  final String seatedTable;
  final String seatedLabel;
  final String orderId;

  /// Who sat them down or took the reservation out of the book.
  final String endedBy;

  /// Another reservation that holds the same table close to this one: whose it is and for when. Empty and
  /// null when none does.
  final String clashName;
  final int? clashAtMs;

  bool get isBooked => status == 'booked';

  /// It was booked on the website, by the guest.
  bool get isOnline => online.isNotEmpty;

  /// Who wrote it into the book, as the reservation's own sheet says it: "booked by Holly", or, for one from
  /// the website, "booked on the website (GloriaFood 1234567)". Empty when the hub does not say.
  String get bookedBy => isOnline ? 'booked on the website (GloriaFood $online)' : (by.isEmpty ? '' : 'booked by $by');
  bool get isSeated => status == 'seated';
  bool get isHere => arrivedMs != null;

  /// "Chen, party of 4".
  @override
  String get label => '$name, party of $size';

  /// How its time stands at [nowMs]: still ahead, near (amber), or past with nobody seated (red).
  TimerLevel levelAt(int nowMs) {
    final soon = soonMs, late = lateMs;
    if (late != null && nowMs >= late) return TimerLevel.late;
    if (soon != null && nowMs >= soon) return TimerLevel.warn;
    return TimerLevel.ok;
  }
}

/// How a day's book adds up.
class BookCounts {
  const BookCounts({this.booked = 0, this.guests = 0, this.seated = 0, this.cancelled = 0, this.noShow = 0});

  factory BookCounts.fromJson(Map<String, dynamic> json) => BookCounts(
    booked: _i(json['booked']),
    guests: _i(json['guests']),
    seated: _i(json['seated']),
    cancelled: _i(json['cancelled']),
    noShow: _i(json['no_show']),
  );

  /// The reservations still standing, and the guests in them.
  final int booked;
  final int guests;

  /// The ones that sat down, were called off, and did not show.
  final int seated;
  final int cancelled;
  final int noShow;
}

/// A day ahead that has reservations standing, and how many.
typedef BookedDay = ({String day, int parties, int guests});

/// One day of the reservation book.
class Book {
  const Book({
    this.day = '',
    this.today = '',
    this.booked = const [],
    this.earlier = const [],
    this.counts = const BookCounts(),
    this.ahead = const [],
    this.mostGuests = 60,
    this.mostAheadDays = 366,
    this.holdMinutes = 90,
    this.nameMax = 24,
    this.noteMax = 80,
    this.booking,
  });

  factory Book.fromJson(Map<String, dynamic> json) {
    final booking = json['booking'];
    return Book(
      day: _s(json['day']),
      today: _s(json['today']),
      booked: [for (final row in _rows(json['booked'])) Booking.fromJson(row)],
      earlier: [for (final row in _rows(json['earlier'])) Booking.fromJson(row)],
      counts: json['counts'] is Map ? BookCounts.fromJson((json['counts'] as Map).cast()) : const BookCounts(),
      ahead: [
        for (final row in _rows(json['ahead']))
          if (_s(row['day']).isNotEmpty) (day: _s(row['day']), parties: _i(row['parties']), guests: _i(row['guests'])),
      ],
      mostGuests: _i(json['most_guests'], 60),
      mostAheadDays: _i(json['most_ahead_days'], 366),
      holdMinutes: _i(json['hold_minutes'], 90),
      nameMax: _i(json['name_max'], 24),
      noteMax: _i(json['note_max'], 80),
      booking: booking is Map ? Booking.fromJson(booking.cast()) : null,
    );
  }

  /// The day this is the book of, and the day of service it is now at the hub ("2026-11-21"). A day runs
  /// until the night ends, so half past midnight is still the evening before.
  final String day;
  final String today;

  /// The reservations still standing, in the order of their times.
  final List<Booking> booked;

  /// The ones that ended: sat down, called off or no-show, the last to end first.
  final List<Booking> earlier;
  final BookCounts counts;

  /// Every day from [today] on with a reservation standing.
  final List<BookedDay> ahead;
  final int mostGuests;

  /// How many days ahead a table can be booked.
  final int mostAheadDays;

  /// How long a booked table counts as taken, from the time it is booked for.
  final int holdMinutes;
  final int nameMax;
  final int noteMax;

  /// The reservation a change was made to, as it stands after it: only on the answer to that change.
  final Booking? booking;

  bool get isToday => day == today;

  /// The booked tables of today that are still to sit down, in the order of their times; none in the book
  /// of another day. What the waitlist's button counts.
  List<Booking> get toCome => isToday ? booked : const [];

  /// A day that is over: its book is read, and nothing in it changes.
  bool get isOver => day.compareTo(today) < 0;

  /// The worst any standing reservation of today stands at [nowMs]; nothing is late on another day.
  TimerLevel levelAt(int nowMs) {
    var worst = TimerLevel.ok;
    if (!isToday) return worst;
    for (final booking in booked) {
      final level = booking.levelAt(nowMs);
      if (level.index > worst.index) worst = level;
    }
    return worst;
  }

  /// The next moment after [nowMs] at which a standing reservation of today changes colour; null when none
  /// will.
  int? nextChange(int nowMs) {
    if (!isToday) return null;
    int? next;
    for (final booking in booked) {
      for (final at in [booking.soonMs, booking.lateMs]) {
        if (at != null && at > nowMs && (next == null || at < next)) next = at;
      }
    }
    return next;
  }
}

/// The tables one phone number has booked, today and ahead, the soonest first, and the day of service it is
/// at the hub: what a screen that picks up a call is told of the caller's reservations.
typedef CallerTables = ({String today, List<Booking> booked});

/// When a caller's reservation is for: "Tomorrow at 18:30".
String callerTableWhen(Booking booking, String today) => '${bookDayWords(booking.day, today)} at ${booking.time}';

/// What a caller's reservation is, under when it is for: "Table A8 booked · 4 guests". It says whose it
/// is when that is not the name the caller goes by ([asName]): "Table booked for Chen · 10 guests".
String callerTableWhat(Booking booking, {String asName = ''}) {
  final same = booking.name.trim().toLowerCase() == asName.trim().toLowerCase();
  return [
    [
      booking.tableLabel.isEmpty ? 'Table booked' : 'Table ${booking.tableLabel} booked',
      if (!same && booking.name.isNotEmpty) 'for ${booking.name}',
    ].join(' '),
    guestWords(booking.size),
  ].join(' · ');
}

/// How many of today's booked tables are still to sit down: "1 booked table to come". What the waitlist's
/// button and the waitlist say of the book.
String bookedToComeWords(int tables) => tables == 1 ? '1 booked table to come' : '$tables booked tables to come';

/// The next of today's reservations in a line, its time first so a narrow screen cuts what matters least:
/// "Next at 18:30: Chen, 4 guests · table A8". "Here for 18:30: …" once the party came in and waits for its
/// table, and "Due since 18:30: …" when the time is past with nobody seated.
String nextBookedWords(Booking booking, int nowMs) {
  final lead = booking.isHere
      ? 'Here for'
      : booking.levelAt(nowMs) == TimerLevel.late
      ? 'Due since'
      : 'Next at';
  return [
    '$lead ${booking.time}: ${[if (booking.name.isNotEmpty) booking.name, guestWords(booking.size)].join(', ')}',
    if (booking.tableLabel.isNotEmpty) 'table ${booking.tableLabel}',
  ].join(' · ');
}

/// The hour a night's service is over for sure, as the hub has it: a time before it is the small hours
/// after the day's midnight.
const nightEndsHour = 4;

/// The hours of a day of service, in the order they come: six in the morning round to three at night.
const serviceHours = [6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 0, 1, 2, 3];

/// A time of the restaurant's clock ("18:30") as minutes into its day of service, so that half past
/// midnight comes after eleven at night; null for words that are no time.
int? serviceMinute(String time) {
  final parts = time.split(':');
  if (parts.length != 2) return null;
  final hour = int.tryParse(parts[0]), minute = int.tryParse(parts[1]);
  if (hour == null || minute == null || hour < 0 || hour > 23 || minute < 0 || minute > 59) return null;
  return (hour < nightEndsHour ? hour + 24 : hour) * 60 + minute;
}

/// A day of the book as a date ("2026-11-21"); null for words that are no day.
DateTime? bookDay(String day) => DateTime.tryParse(day);

/// A day of the book in words, as seen from the hub's [today]: "Today", "Tomorrow", "Sat 21 Nov".
String bookDayWords(String day, String today) {
  final on = bookDay(day), now = bookDay(today);
  if (on == null) return day;
  if (now != null) {
    final days = (DateTime.utc(on.year, on.month, on.day).difference(DateTime.utc(now.year, now.month, now.day)))
        .inDays;
    if (days == 0) return 'Today';
    if (days == 1) return 'Tomorrow';
    if (days == -1) return 'Yesterday';
  }
  return dayName(on);
}

/// How a day's standing reservations add up: "3 reservations · 12 guests".
String bookedWords(int parties, int guests) =>
    '${parties == 1 ? '1 reservation' : '$parties reservations'} · ${guestWords(guests)}';

/// How a reservation ended, in words.
String endedWords(Booking booking) => switch (booking.status) {
  'seated' => booking.seatedLabel.isEmpty ? 'Seated' : 'Seated at ${booking.seatedLabel}',
  'no_show' => 'No-show',
  'cancelled' => 'Cancelled',
  _ => 'Booked',
};
