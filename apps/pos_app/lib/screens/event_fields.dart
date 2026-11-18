import 'package:flutter/material.dart';

import '../takeout.dart';

/// The day and the time an order is for (docs/catering.md): today, tomorrow or any later day off a
/// calendar, and the time. Chips that wrap, so the row fits a phone at any size of type.
class WhenPicker extends StatelessWidget {
  const WhenPicker({super.key, required this.day, required this.time, required this.onDay, required this.onTime});

  /// The day picked (its date alone counts).
  final DateTime day;
  final TimeOfDay? time;
  final ValueChanged<DateTime> onDay;
  final ValueChanged<TimeOfDay> onTime;

  /// How far ahead an order can be taken.
  static const ahead = Duration(days: 366);

  static DateTime dateOf(DateTime at) => DateTime(at.year, at.month, at.day);

  /// [day] at [time], on the terminal's clock.
  static DateTime at(DateTime day, TimeOfDay time) => DateTime(day.year, day.month, day.day, time.hour, time.minute);

  @override
  Widget build(BuildContext context) {
    final today = dateOf(DateTime.now());
    final tomorrow = dateOf(today.add(const Duration(days: 1, hours: 6))); // an hour's change of clock aside
    final picked = dateOf(day);
    final other = picked != today && picked != tomorrow;
    Future<void> pickDay() async {
      final to = await showDatePicker(
        context: context,
        initialDate: picked.isBefore(today) ? today : picked,
        firstDate: today,
        lastDate: today.add(ahead),
        helpText: 'The day it is for',
      );
      if (to != null) onDay(dateOf(to));
    }

    Future<void> pickTime() async {
      final to = await showTimePicker(context: context, initialTime: time ?? TimeOfDay.now());
      if (to != null) onTime(to);
    }

    return Wrap(
      spacing: 8,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        ChoiceChip(
          key: const ValueKey('day:today'),
          label: const Text('Today'),
          selected: picked == today,
          onSelected: (_) => onDay(today),
        ),
        ChoiceChip(
          key: const ValueKey('day:tomorrow'),
          label: const Text('Tomorrow'),
          selected: picked == tomorrow,
          onSelected: (_) => onDay(tomorrow),
        ),
        ChoiceChip(
          key: const ValueKey('day:other'),
          avatar: other ? null : const Icon(Icons.calendar_month_outlined, size: 18),
          label: Text(other ? dayName(picked) : 'Another day'),
          selected: other,
          onSelected: (_) => pickDay(),
        ),
        OutlinedButton.icon(
          key: const ValueKey('takeout-time'),
          onPressed: pickTime,
          icon: const Icon(Icons.schedule),
          label: Text(time == null ? 'Time' : time!.format(context)),
        ),
      ],
    );
  }
}

/// How a to-go order leaves, on its form: whether it is picked up or delivered, and for a delivery the
/// address. A catering order ([guests] given) says how many guests too, and has a note for the kitchen or
/// the driver about its event (docs/catering.md). Any other order has no guests to count, and its note is
/// for the driver: asked only of a delivery (docs/delivery.md).
class EventFields extends StatelessWidget {
  const EventFields({
    super.key,
    this.guests,
    required this.address,
    required this.note,
    required this.handover,
    required this.onHandover,
    this.onChanged,
  });

  /// The guests of a catering order's event; null on any other order.
  final TextEditingController? guests;
  final TextEditingController address;
  final TextEditingController note;
  final String handover;
  final ValueChanged<String> onHandover;

  /// Something was typed.
  final VoidCallback? onChanged;

  /// What the boxes hold, as an order carries it. With no [guests] box it is no catering order: the note is
  /// the driver's, and an order the customer comes for has none.
  static EventDetails read({
    TextEditingController? guests,
    required TextEditingController address,
    required TextEditingController note,
    required String handover,
  }) {
    final n = int.tryParse(guests?.text.trim() ?? '');
    return EventDetails(
      guests: n != null && n > 0 ? n : null,
      handover: handover,
      address: oneLine(address.text),
      note: guests == null && handover != 'delivery' ? '' : oneLine(note.text),
    );
  }

  @override
  Widget build(BuildContext context) {
    final guests = this.guests;
    final catering = guests != null;
    return Column(
      key: ValueKey(catering ? 'event-fields' : 'delivery-fields'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (guests != null)
              SizedBox(
                width: 110,
                child: TextField(
                  key: const ValueKey('event-guests'),
                  controller: guests,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Guests', isDense: true),
                  onChanged: (_) => onChanged?.call(),
                ),
              ),
            for (final way in handovers)
              ChoiceChip(
                key: ValueKey('handover:$way'),
                label: Text(handoverLabel(way)),
                selected: handover == way,
                onSelected: (_) => onHandover(way),
              ),
          ],
        ),
        if (handover == 'delivery') ...[
          const SizedBox(height: 8),
          TextField(
            key: const ValueKey('event-address'),
            controller: address,
            maxLength: eventTextMax,
            textCapitalization: TextCapitalization.words,
            keyboardType: TextInputType.streetAddress,
            decoration: const InputDecoration(
              labelText: 'Deliver to',
              prefixIcon: Icon(Icons.place_outlined),
              counterText: '',
            ),
            onChanged: (_) => onChanged?.call(),
          ),
        ],
        if (catering || handover == 'delivery') ...[
          const SizedBox(height: 8),
          TextField(
            key: const ValueKey('event-note'),
            controller: note,
            maxLength: eventTextMax,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              labelText: catering ? 'Note for the event' : 'Note for the driver',
              hintText: catering ? 'e.g. set up by 11:30, side door' : 'e.g. ring twice, side door',
              prefixIcon: Icon(catering ? Icons.event_note_outlined : Icons.delivery_dining_outlined),
              counterText: '',
            ),
            onChanged: (_) => onChanged?.call(),
          ),
        ],
      ],
    );
  }
}

/// What the dialog over a to-go order hands back: its new time when it is an order for later, and how it
/// leaves (on a catering order, what its event needs).
typedef WhenAndEvent = ({DateTime? promised, EventDetails? event});

/// How a to-go order leaves, changed on the order: whether it is picked up or delivered, where to, and the
/// note for the driver (docs/delivery.md). An order for later ([promised] given) also changes its day and
/// time here: the kitchen's ticket waits for the new time (docs/printing.md, "Orders sent ahead"). A
/// catering order ([catering]) changes its guests and the note for its event too. A delivery that is no
/// catering order needs its address: without one it cannot be saved.
class WhenDialog extends StatefulWidget {
  const WhenDialog({super.key, this.promised, this.event, this.catering = false});

  /// The time an order for later is for; null on an order for now, whose time is not the customer's.
  final DateTime? promised;

  /// How the order leaves now; null where only the time is changed.
  final EventDetails? event;

  /// A catering order: its event has guests and a note of its own.
  final bool catering;

  @override
  State<WhenDialog> createState() => _WhenDialogState();
}

class _WhenDialogState extends State<WhenDialog> {
  late DateTime _day = WhenPicker.dateOf(widget.promised ?? DateTime.now());
  late TimeOfDay _time = TimeOfDay.fromDateTime(widget.promised ?? DateTime.now());
  late final _guests = TextEditingController(text: widget.event?.guests?.toString() ?? '');
  late final _address = TextEditingController(text: widget.event?.address ?? '');
  late final _note = TextEditingController(text: widget.event?.note ?? '');
  late String _handover = widget.event?.handover ?? 'pickup';

  /// A delivery with nowhere to go. (A catering order may be given its address later: it is days away.)
  bool get _nowhere =>
      widget.event != null && !widget.catering && _handover == 'delivery' && oneLine(_address.text).isEmpty;

  @override
  void dispose() {
    _guests.dispose();
    _address.dispose();
    _note.dispose();
    super.dispose();
  }

  void _save() => Navigator.of(context).pop<WhenAndEvent>((
    promised: widget.promised == null ? null : WhenPicker.at(_day, _time),
    event: widget.event == null
        ? null
        : EventFields.read(
            guests: widget.catering ? _guests : null,
            address: _address,
            note: _note,
            handover: _handover,
          ),
  ));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final later = widget.promised != null;
    final past = later && WhenPicker.at(_day, _time).isBefore(DateTime.now());
    final nowhere = _nowhere;
    return AlertDialog(
      title: Text(
        widget.catering
            ? 'The event'
            : later
            ? 'When it is for'
            : 'Pickup or delivery',
      ),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (later)
                WhenPicker(
                  day: _day,
                  time: _time,
                  onDay: (day) => setState(() => _day = day),
                  onTime: (time) => setState(() => _time = time),
                ),
              if (past)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    'That time has passed.',
                    key: const ValueKey('when-past'),
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
                  ),
                ),
              if (widget.event != null) ...[
                if (later) const SizedBox(height: 12),
                EventFields(
                  guests: widget.catering ? _guests : null,
                  address: _address,
                  note: _note,
                  handover: _handover,
                  onHandover: (way) => setState(() => _handover = way),
                  onChanged: () => setState(() {}),
                ),
              ],
              if (nowhere)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    'Type the address it goes to.',
                    key: const ValueKey('address-needed'),
                    style: theme.textTheme.bodySmall,
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('when-save'),
          onPressed: past || nowhere ? null : _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
