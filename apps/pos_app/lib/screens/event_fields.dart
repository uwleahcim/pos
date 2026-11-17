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

/// What an event needs, on the form of a catering order: how many guests, whether it is picked up or
/// delivered, the address for a delivery, and a note for the kitchen or the driver.
class EventFields extends StatelessWidget {
  const EventFields({
    super.key,
    required this.guests,
    required this.address,
    required this.note,
    required this.handover,
    required this.onHandover,
    this.onChanged,
  });

  final TextEditingController guests;
  final TextEditingController address;
  final TextEditingController note;
  final String handover;
  final ValueChanged<String> onHandover;

  /// Something was typed.
  final VoidCallback? onChanged;

  /// What the boxes hold, as an order carries it.
  static EventDetails read({
    required TextEditingController guests,
    required TextEditingController address,
    required TextEditingController note,
    required String handover,
  }) {
    final n = int.tryParse(guests.text.trim());
    return EventDetails(
      guests: n != null && n > 0 ? n : null,
      handover: handover,
      address: oneLine(address.text),
      note: oneLine(note.text),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const ValueKey('event-fields'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
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
        const SizedBox(height: 8),
        TextField(
          key: const ValueKey('event-note'),
          controller: note,
          maxLength: eventTextMax,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            labelText: 'Note for the event',
            hintText: 'e.g. set up by 11:30, side door',
            prefixIcon: Icon(Icons.event_note_outlined),
            counterText: '',
          ),
          onChanged: (_) => onChanged?.call(),
        ),
      ],
    );
  }
}

/// What the dialog over an order for later hands back: its new time, and for a catering order what its
/// event needs.
typedef WhenAndEvent = ({DateTime promised, EventDetails? event});

/// The time an order for later is for, changed on the order: the day, the time and, on a catering order,
/// the guests, how it leaves, the address and the note. The kitchen's ticket waits for the new time
/// (docs/printing.md, "Orders sent ahead").
class WhenDialog extends StatefulWidget {
  const WhenDialog({super.key, required this.promised, this.event});

  final DateTime promised;

  /// What the order's event needs now; null on an order that is no catering order.
  final EventDetails? event;

  @override
  State<WhenDialog> createState() => _WhenDialogState();
}

class _WhenDialogState extends State<WhenDialog> {
  late DateTime _day = WhenPicker.dateOf(widget.promised);
  late TimeOfDay _time = TimeOfDay.fromDateTime(widget.promised);
  late final _guests = TextEditingController(text: widget.event?.guests?.toString() ?? '');
  late final _address = TextEditingController(text: widget.event?.address ?? '');
  late final _note = TextEditingController(text: widget.event?.note ?? '');
  late String _handover = widget.event?.handover ?? 'pickup';

  @override
  void dispose() {
    _guests.dispose();
    _address.dispose();
    _note.dispose();
    super.dispose();
  }

  void _save() => Navigator.of(context).pop<WhenAndEvent>((
    promised: WhenPicker.at(_day, _time),
    event: widget.event == null
        ? null
        : EventFields.read(guests: _guests, address: _address, note: _note, handover: _handover),
  ));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final past = WhenPicker.at(_day, _time).isBefore(DateTime.now());
    return AlertDialog(
      title: Text(widget.event == null ? 'When it is for' : 'The event'),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
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
                const SizedBox(height: 12),
                EventFields(
                  guests: _guests,
                  address: _address,
                  note: _note,
                  handover: _handover,
                  onHandover: (way) => setState(() => _handover = way),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(key: const ValueKey('when-save'), onPressed: past ? null : _save, child: const Text('Save')),
      ],
    );
  }
}
