import 'package:flutter/material.dart';

import '../api.dart';
import '../floor.dart';
import '../reservations.dart';
import '../takeout.dart' show dayName;
import 'guests_picker.dart';
import 'phone_bar.dart' show callStripRoom;

/// A reservation (docs/reservations.md): asked when a table is booked, and again to put a standing one
/// right. A name, how many they are, the day and the time; a table to hold, a phone number and a note when
/// there is one. The hub keeps it and says what it does not take. Pops the book of the day the reservation
/// is for, as the hub has it afterwards; nothing when it was closed.
class BookingDialog extends StatefulWidget {
  const BookingDialog({
    super.key,
    required this.api,
    required this.staffId,
    required this.book,
    this.booking,
    this.name = '',
    this.phone = '',
    this.underCall = false,
  });

  final PosApi api;

  /// Who is at the screen: the book keeps who booked a table.
  final String staffId;

  /// The book as it was last read: what day it is at the hub, the day a new reservation starts on, the
  /// tables its reservations hold, and how long a name and a note may be.
  final Book book;

  /// The reservation being put right; null for a new one.
  final Booking? booking;

  /// What is known already of who a new reservation is for: somebody on the phone has a number, and a name
  /// when the caller ID or their orders gave one. Both can be typed over.
  final String name;
  final String phone;

  /// A call is on at this terminal: the form starts under its strip.
  final bool underCall;

  @override
  State<BookingDialog> createState() => _BookingDialogState();
}

class _BookingDialogState extends State<BookingDialog> {
  late final _name = TextEditingController(text: widget.booking?.name ?? _known(widget.name, widget.book.nameMax));
  late final _phone = TextEditingController(text: widget.booking?.phone ?? widget.phone.trim());
  late final _note = TextEditingController(text: widget.booking?.note ?? '');
  late int _size = widget.booking?.size ?? 2;
  // A day of service, as the hub names it; a new reservation starts on the day the book is open at.
  late String _day = widget.booking?.day ?? (widget.book.isOver || widget.book.day.isEmpty ? _today : widget.book.day);
  late String? _time = widget.booking?.time;
  late String _table = widget.booking?.table ?? '';
  late String _tableLabel = widget.booking?.tableLabel ?? '';
  bool _busy = false;
  String? _message;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _note.dispose();
    super.dispose();
  }

  /// A name that came with a call, as the book takes one: on one line, and no longer than it keeps.
  static String _known(String name, int most) {
    final tidy = name.trim().replaceAll(RegExp(r'\s+'), ' ');
    return tidy.length > most ? tidy.substring(0, most).trimRight() : tidy;
  }

  String get _today => widget.book.today.isEmpty ? isoDay(DateTime.now()) : widget.book.today;

  /// The day after today, by the calendar and not by the hours: a night the clocks change has 23 or 25.
  String get _tomorrow {
    final today = bookDay(_today) ?? DateTime.now();
    return isoDay(DateTime.utc(today.year, today.month, today.day + 1));
  }

  String get _typedName => _name.text.trim().replaceAll(RegExp(r'\s+'), ' ');

  Future<void> _pickDay() async {
    final today = bookDay(_today) ?? DateTime.now();
    final first = DateTime(today.year, today.month, today.day);
    final picked = bookDay(_day);
    final to = await showDatePicker(
      context: context,
      initialDate: picked == null || picked.isBefore(first) ? first : DateTime(picked.year, picked.month, picked.day),
      firstDate: first,
      lastDate: DateTime(first.year, first.month, first.day + widget.book.mostAheadDays),
      helpText: 'The day the table is for',
    );
    if (to != null && mounted) setState(() => _day = isoDay(to));
  }

  Future<void> _pickTime() async {
    final to = await showDialog<String>(
      context: context,
      builder: (_) => TimeGrid(picked: _time),
    );
    if (to != null && mounted) setState(() => _time = to);
  }

  /// The tables other reservations of this day hold close to the time picked: each by its id, with the
  /// reservation it is held for. Known for the day the book is open at.
  Map<String, Booking> get _held {
    final at = _time == null ? null : serviceMinute(_time!);
    if (at == null || _day != widget.book.day) return const {};
    return {
      for (final other in widget.book.booked)
        if (other.table.isNotEmpty && other.id != widget.booking?.id)
          if (((serviceMinute(other.time) ?? at) - at).abs() < widget.book.holdMinutes) other.table: other,
    };
  }

  Future<void> _pickTable() async {
    final FloorPlan plan;
    try {
      plan = await widget.api.floor();
    } on ApiException {
      if (mounted) setState(() => _message = 'The tables cannot be read just now. Book without one, or try again.');
      return;
    }
    if (!mounted) return;
    final to = await showDialog<TableSpot?>(
      context: context,
      builder: (_) => TablePicker(
        tables: plan.tables,
        picked: _table,
        guests: _size,
        held: {for (final MapEntry(:key, :value) in _held.entries) key: '${value.time} ${value.name}'},
      ),
    );
    if (to == null || !mounted) return;
    setState(() {
      _table = to.id;
      _tableLabel = to.label;
    });
  }

  Future<void> _save() async {
    final name = _typedName, time = _time;
    if (name.isEmpty || time == null || _busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    final api = widget.api;
    final booking = widget.booking;
    try {
      final saved = booking == null
          ? await api.addBooking(
              widget.staffId,
              name: name,
              size: _size,
              day: _day,
              time: time,
              phone: _phone.text.trim(),
              note: _note.text.trim(),
              table: _table,
            )
          : await api.changeBooking(
              widget.staffId,
              booking.id,
              name: name,
              size: _size,
              day: _day,
              time: time,
              phone: _phone.text.trim(),
              note: _note.text.trim(),
              table: _table,
            );
      if (mounted) Navigator.of(context).pop(saved);
    } on ApiException catch (err) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _message = err.status == null
            ? 'The hub cannot be reached, and the book is kept there. Try again in a moment.'
            : err.detail?['message'] as String? ?? err.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final booking = widget.booking;
    final book = widget.book;
    final label = theme.textTheme.labelLarge?.copyWith(color: scheme.onSurfaceVariant);
    final today = _today, tomorrow = _tomorrow;
    final other = _day != today && _day != tomorrow;
    final on = bookDay(_day);
    final held = _table.isEmpty ? null : _held[_table];
    return AlertDialog(
      title: Text(booking == null ? 'Book a table' : 'Change ${booking.name}'),
      // a phone keeps its width
      insetPadding: EdgeInsets.fromLTRB(16, widget.underCall ? callStripRoom : 24, 16, 24),
      contentPadding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          padding: const EdgeInsets.only(top: 8), // the name's label stands above its box, and is not cut off
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                key: const ValueKey('booking-name'),
                controller: _name,
                // a name that came with the call is there to read: the keyboard stays down until it is wanted
                autofocus: booking == null && _name.text.isEmpty,
                maxLength: book.nameMax,
                textCapitalization: TextCapitalization.words,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(labelText: 'Name', counterText: ''),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 12),
              GuestsPicker(
                prefix: 'booking',
                size: _size,
                most: book.mostGuests,
                onChanged: (size) => setState(() => _size = size),
              ),
              const SizedBox(height: 14),
              Text('When', style: label),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  ChoiceChip(
                    key: const ValueKey('booking-day:today'),
                    label: const Text('Today'),
                    visualDensity: VisualDensity.compact,
                    showCheckmark: false,
                    selected: _day == today,
                    onSelected: (_) => setState(() => _day = today),
                  ),
                  ChoiceChip(
                    key: const ValueKey('booking-day:tomorrow'),
                    label: const Text('Tomorrow'),
                    visualDensity: VisualDensity.compact,
                    showCheckmark: false,
                    selected: _day == tomorrow,
                    onSelected: (_) => setState(() => _day = tomorrow),
                  ),
                  ChoiceChip(
                    key: const ValueKey('booking-day:other'),
                    avatar: other ? null : const Icon(Icons.calendar_month_outlined, size: 18),
                    label: Text(other && on != null ? dayName(on) : 'Another day'),
                    visualDensity: VisualDensity.compact,
                    showCheckmark: false,
                    selected: other,
                    onSelected: (_) => _pickDay(),
                  ),
                  FilledButton.tonalIcon(
                    key: const ValueKey('booking-time'),
                    style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
                    onPressed: _pickTime,
                    icon: const Icon(Icons.schedule, size: 18),
                    label: Text(_time ?? 'Time'),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(top: 6),
                // The day by its date whatever chip says it: near midnight "today" is the evening before.
                child: Text(
                  [
                    if (on != null) dayName(on),
                    _time == null ? 'pick a time' : 'at $_time',
                  ].join(_time == null ? ', ' : ' '),
                  key: const ValueKey('booking-when'),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: _time == null ? scheme.onSurfaceVariant : scheme.onSurface,
                    fontWeight: _time == null ? null : FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  OutlinedButton.icon(
                    key: const ValueKey('booking-table'),
                    style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
                    onPressed: _pickTable,
                    icon: const Icon(Icons.table_restaurant_outlined, size: 18),
                    label: Text(_table.isEmpty ? 'Hold a table' : 'Table $_tableLabel'),
                  ),
                  if (_table.isNotEmpty)
                    TextButton(
                      key: const ValueKey('booking-no-table'),
                      style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                      onPressed: () => setState(() {
                        _table = '';
                        _tableLabel = '';
                      }),
                      child: const Text('No table'),
                    ),
                ],
              ),
              if (held != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '$_tableLabel is also held for ${held.name} at ${held.time}.',
                    key: const ValueKey('booking-held'),
                    style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
                  ),
                ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('booking-phone'),
                controller: _phone,
                keyboardType: TextInputType.phone,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(labelText: 'Phone (if they give one)', isDense: true),
              ),
              const SizedBox(height: 10),
              TextField(
                key: const ValueKey('booking-note'),
                controller: _note,
                maxLength: book.noteMax,
                textCapitalization: TextCapitalization.sentences,
                textInputAction: TextInputAction.done,
                decoration: const InputDecoration(
                  labelText: 'Note',
                  hintText: 'Birthday, high chair, by the window',
                  isDense: true,
                  counterText: '',
                ),
                onSubmitted: (_) => _save(),
              ),
              if (_message != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    _message!,
                    key: const ValueKey('booking-problem'),
                    style: theme.textTheme.bodyMedium?.copyWith(color: scheme.error),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('booking-save'),
          onPressed: _typedName.isEmpty || _time == null || _busy ? null : _save,
          child: Text(booking == null ? 'Book' : 'Save'),
        ),
      ],
    );
  }
}

/// The time a table is booked for, as a grid of buttons: a row for each hour of a day of service (six in
/// the morning round to three at night), a button for each quarter of it. It opens at the time picked, or
/// at five in the afternoon. Pops the time tapped ("18:30"); nothing when it was closed.
class TimeGrid extends StatefulWidget {
  const TimeGrid({super.key, this.picked});

  /// The time picked so far ("18:30"); null when none is.
  final String? picked;

  @override
  State<TimeGrid> createState() => _TimeGridState();
}

class _TimeGridState extends State<TimeGrid> {
  static const _row = 46.0;
  late final ScrollController _scroll;

  @override
  void initState() {
    super.initState();
    final hour = int.tryParse((widget.picked ?? '17:00').split(':').first) ?? 17;
    final at = serviceHours.indexOf(hour);
    // the hour picked stands second from the top, with the one before it in sight
    _scroll = ScrollController(initialScrollOffset: ((at < 0 ? 11 : at) - 1).clamp(0, serviceHours.length) * _row);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    String two(int n) => n.toString().padLeft(2, '0');
    return AlertDialog(
      title: const Text('Time'),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      contentPadding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      content: SizedBox(
        width: 320,
        height: _row * 7.5, // half a row shows there is more below
        child: ListView.builder(
          key: const ValueKey('time-grid'),
          controller: _scroll,
          itemExtent: _row,
          itemCount: serviceHours.length,
          itemBuilder: (context, at) {
            final hour = serviceHours[at];
            return Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: [
                  for (final minute in const [0, 15, 30, 45]) ...[
                    if (minute > 0) const SizedBox(width: 6),
                    Expanded(
                      child: Builder(
                        builder: (context) {
                          final time = '${two(hour)}:${two(minute)}';
                          final style = FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 2),
                            minimumSize: const Size(0, _row - 6),
                            textStyle: theme.textTheme.labelLarge?.copyWith(
                              fontWeight: minute == 0 ? FontWeight.w800 : FontWeight.w500,
                            ),
                          );
                          final label = FittedBox(fit: BoxFit.scaleDown, child: Text(time));
                          void pick() => Navigator.of(context).pop(time);
                          return time == widget.picked
                              ? FilledButton(key: ValueKey('time:$time'), style: style, onPressed: pick, child: label)
                              : FilledButton.tonal(
                                  key: ValueKey('time:$time'),
                                  style: style,
                                  onPressed: pick,
                                  child: label,
                                );
                        },
                      ),
                    ),
                  ],
                ],
              ),
            );
          },
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel'))],
    );
  }
}

/// The table a reservation holds, picked from the floor plan's tables as a grid of buttons: each with its
/// name and its seats, and the ones another reservation holds close to the same time say for whom. They
/// can still be picked: the host knows which party will be gone by then. Pops the table tapped; nothing
/// when it was closed.
class TablePicker extends StatelessWidget {
  const TablePicker({super.key, required this.tables, this.picked = '', this.guests = 2, this.held = const {}});

  final List<TableSpot> tables;

  /// The id of the table held so far; empty when none is.
  final String picked;

  /// How many the party is: a table with fewer seats is drawn lighter.
  final int guests;

  /// The tables other reservations hold close to this time, by id, each with the time and the name.
  final Map<String, String> held;

  static final _number = RegExp(r'\d+');

  /// Tables in the order a person reads their names: A2 before A10.
  static int byName(TableSpot a, TableSpot b) {
    String letters(String label) => label.replaceAll(_number, '').toLowerCase();
    int digits(String label) => int.tryParse(_number.firstMatch(label)?.group(0) ?? '') ?? 0;
    final first = letters(a.label).compareTo(letters(b.label));
    if (first != 0) return first;
    final second = digits(a.label).compareTo(digits(b.label));
    return second != 0 ? second : a.label.compareTo(b.label);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final sorted = [...tables]..sort(byName);
    final scale = MediaQuery.textScalerOf(context);
    return AlertDialog(
      title: const Text('Table to hold'),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      contentPadding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      content: SizedBox(
        width: 380,
        child: GridView.builder(
          key: const ValueKey('table-grid'),
          shrinkWrap: true,
          gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 92,
            mainAxisSpacing: 6,
            crossAxisSpacing: 6,
            mainAxisExtent: 22 + scale.scale(34),
          ),
          itemCount: sorted.length,
          itemBuilder: (context, at) {
            final table = sorted[at];
            final other = held[table.id];
            final small = table.seats < guests;
            final child = Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // no colour of their own: the words take the button's, whichever way it is filled
                Text(
                  table.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: theme.textTheme.titleSmall?.fontSize, fontWeight: FontWeight.w800),
                ),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    other ?? (table.seats == 1 ? '1 seat' : '${table.seats} seats'),
                    key: other == null ? null : ValueKey('table-held:${table.id}'),
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: theme.textTheme.bodySmall?.fontSize,
                      color: other == null ? null : scheme.error,
                      fontWeight: other == null ? FontWeight.w400 : FontWeight.w600,
                    ),
                  ),
                ),
              ],
            );
            final style = FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            );
            void pick() => Navigator.of(context).pop(table);
            return Opacity(
              opacity: small && table.id != picked ? 0.6 : 1,
              child: table.id == picked
                  ? FilledButton(key: ValueKey('table:${table.id}'), style: style, onPressed: pick, child: child)
                  : FilledButton.tonal(key: ValueKey('table:${table.id}'), style: style, onPressed: pick, child: child),
            );
          },
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel'))],
    );
  }
}
