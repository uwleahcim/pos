import 'day_report.dart' show dollars, kindLabel, methodLabel;
import 'delivery_fee.dart';
import 'takeout.dart' show EventDetails, channelLabel, handoverLabel, stageLabel;
import 'voids.dart' show checkName;

/// A check's history as the hub tells it (`GET /orders/{id}/history`, docs/check-history.md): every step the
/// log keeps of one order, oldest first, with who did it, at which screen and when. The hub works the steps
/// out; this reads them into names, and [wordsOf] says each one as a person would.

String _s(Object? value, [String or = '']) => value is String ? value : or;
int? _n(Object? value) => value is num ? value.toInt() : null;

/// One thing that happened to a check.
class HistoryStep {
  const HistoryStep({
    required this.opId,
    required this.what,
    this.atMs = 0,
    this.device = '',
    this.by = '',
    this.byId,
    this.approvedBy = '',
    this.offline = false,
    this.photo,
    this.said = const {},
  });

  factory HistoryStep.fromJson(Map<String, dynamic> json) => HistoryStep(
    opId: _s(json['op_id']),
    what: _s(json['what']),
    atMs: _n(json['at_ms']) ?? 0,
    device: _s(json['device']),
    by: _s(json['by']),
    byId: json['by_id'] as String?,
    approvedBy: _s(json['approved_by']),
    offline: json['offline'] == true,
    photo: json['photo'] as String?,
    said: json,
  );

  final String opId;

  /// What kind of step: `opened`, `added`, `sent`, `voided`, `paid`, ... (the hub's list is in
  /// `pos.orders.history`). One this build has no words for is shown by this name.
  final String what;

  /// When, by the clock of the screen that did it.
  final int atMs;

  /// The screen it was done at.
  final String device;

  /// Who did it: as the step says, else whoever its audit photo shows, else nobody named.
  final String by;
  final String? byId;

  /// The manager behind a void, a comp or a charge taken off, where one was asked.
  final String approvedBy;

  /// Taken while no hub answered, and sent when one did.
  final bool offline;

  /// The audit photo taken with it, while the hub still has the picture.
  final String? photo;

  /// Everything the hub said of the step: what comes with each kind is read by name.
  final Map<String, dynamic> said;

  /// The other check of a dish moved or of two tables made one: its history is a tap away.
  String? get other => said['other'] as String?;

  /// Whether it took something off the check: a void, a dish taken off, a comp, a discount, or its tax.
  bool get cameOff => const {'voided', 'taken_off', 'voided_check', 'discount', 'tax_exempt'}.contains(what);
}

/// The check a history is of.
class HistoryOrder {
  const HistoryOrder({
    required this.orderId,
    this.status = 'open',
    this.table,
    this.orderNo,
    this.customerName = '',
    this.orderType = 'dine_in',
    this.tab = false,
    this.server = '',
    this.guests,
    this.openedMs,
    this.mergedInto,
  });

  factory HistoryOrder.fromJson(Map<String, dynamic> json) => HistoryOrder(
    orderId: _s(json['order_id']),
    status: _s(json['status'], 'open'),
    table: json['table']?.toString(),
    orderNo: _n(json['order_no']),
    customerName: _s(json['customer_name']),
    orderType: _s(json['order_type'], 'dine_in'),
    tab: json['tab'] == true,
    server: _s(json['server']),
    guests: _n(json['guests']),
    openedMs: _n(json['opened_ms']),
    mergedInto: json['merged_into'] as String?,
  );

  final String orderId;
  final String status;
  final String? table;
  final int? orderNo;
  final String customerName;
  final String orderType;

  /// A bar tab that has not sat down: called by the name on it.
  final bool tab;
  final String server;
  final int? guests;
  final int? openedMs;
  final String? mergedInto;

  /// "Table 12", "#7 · Lee", "Tab · Linda", or what kind of order it is when it has none of these.
  String get where {
    final named = checkName(table, orderNo);
    final base = named.isNotEmpty
        ? named
        : tab
        ? 'Tab'
        : kindLabel(orderType);
    return customerName.isEmpty ? base : '$base · $customerName';
  }

  /// Where it stands, in a word.
  String get standing => switch (status) {
    'open' => 'Open',
    'closed' => 'Closed',
    'void' => 'Voided',
    _ => status,
  };
}

class CheckHistory {
  const CheckHistory({required this.order, required this.steps});

  factory CheckHistory.fromJson(Map<String, dynamic> json) => CheckHistory(
    order: HistoryOrder.fromJson((json['order'] as Map?)?.cast<String, dynamic>() ?? const {}),
    steps: [
      if (json['steps'] is List)
        for (final step in json['steps'] as List)
          if (step is Map) HistoryStep.fromJson(step.cast<String, dynamic>()),
    ],
  );

  final HistoryOrder order;
  final List<HistoryStep> steps;
}

/// A step in words: what happened, and the lines under it that say the rest.
typedef StepWords = ({String title, List<String> under});

String _text(Object? value) => value == null ? '' : value.toString().trim();

/// "Egg roll", "2 × Egg roll".
String _dish(Map<String, dynamic> said) {
  final qty = _n(said['qty']) ?? 1;
  final dish = _text(said['dish']);
  return qty == 1 ? dish : '$qty × $dish';
}

/// "Table 14", or "another check" when the hub no longer knows where that check stood.
String _otherCheck(Map<String, dynamic> said) {
  final table = _text(said['other_table']);
  if (table.isNotEmpty) return 'Table $table';
  // a bar tab has no table: it is called by the name on it
  final tab = said['other_tab'];
  if (tab is! String) return 'another check';
  return tab.trim().isEmpty ? 'a bar tab' : "${tab.trim()}'s tab";
}

/// "Name set to Wang", "Name changed from Wang to Wong", "Name taken off (was Wang)".
String _changed(String label, String was, String now) => was.isEmpty
    ? '$label set to $now'
    : now.isEmpty
    ? '$label taken off (was $was)'
    : '$label changed from $was to $now';

String _orderKind(String kind) => switch (kind) {
  'dine_in' => 'a table',
  'takeout' => 'to go',
  'delivery' => 'delivery',
  _ => kind,
};

String _split(Object? split) {
  if (split is! Map) return '';
  return switch (split['by']) {
    'seat' => 'by seat',
    'dish' => 'by dish',
    'even' => 'evenly in ${_n(split['ways']) ?? 2}',
    final other => _text(other),
  };
}

String _checksOf(Object? checks) {
  final list = [
    if (checks is List)
      for (final check in checks)
        if (check is num) check.toInt(),
  ];
  if (list.isEmpty) return 'where the split puts it';
  if (list.length == 1) return 'check ${list.single}';
  return 'checks ${list.take(list.length - 1).join(', ')} and ${list.last}';
}

String _lineChange(Map<String, dynamic> change, String Function(int ms) time) {
  final was = change['was'], now = change['now'];
  return switch (change['field']) {
    'qty' => 'Quantity from ${_text(was)} to ${_text(now)}',
    'seat' =>
      was == null
          ? 'Put at seat ${_text(now)}'
          : now == null
          ? 'Taken off seat ${_text(was)}'
          : 'Seat ${_text(was)} to seat ${_text(now)}',
    'course' =>
      _text(was).isEmpty
          ? 'Course set to ${_text(now)}'
          : _text(now).isEmpty
          ? 'Taken out of ${_text(was)}'
          : 'Course from ${_text(was)} to ${_text(now)}',
    'note' => _changed('Note', _text(was), _text(now)),
    'checks' => 'Now on ${_checksOf(now)}',
    final field => '${_text(field)}: ${_text(was)} to ${_text(now)}',
  };
}

/// What [step] did, as a person would say it. [time] writes a time of day the way this device does: a
/// promised time is one.
StepWords wordsOf(HistoryStep step, {required String Function(int ms) time}) {
  final said = step.said;
  String at(Object? ms) => ms is num ? time(ms.toInt()) : '';
  switch (step.what) {
    case 'opened':
      final fields = (said['fields'] as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{};
      final named = checkName(fields['table']?.toString(), _n(fields['order_no']));
      final kind = _s(fields['order_type'], 'dine_in');
      final guests = _n(fields['guests']);
      return (
        title: 'Opened the check',
        under: [
          [
            if (named.isNotEmpty) named,
            if (named.isEmpty && fields['tab'] == true) 'Bar tab',
            if (kind != 'dine_in') kindLabel(kind),
            if (_text(fields['customer_name']).isNotEmpty) _text(fields['customer_name']),
            if (_text(fields['phone']).isNotEmpty) _text(fields['phone']),
            if (_text(fields['channel']).isNotEmpty) 'taken by ${channelLabel(_text(fields['channel'])).toLowerCase()}',
            if (guests != null) '$guests ${guests == 1 ? 'guest' : 'guests'}',
            if (_text(fields['server']).isNotEmpty) 'server ${_text(fields['server'])}',
          ].join(' · '),
          [
            if (fields['promised_at'] is num) 'For ${at(fields['promised_at'])}',
            if (fields['quoted_minutes'] is num) 'quoted ${_n(fields['quoted_minutes'])} minutes',
          ].join(', '),
          if (_text(fields['note']).isNotEmpty) 'Note: ${_text(fields['note'])}',
          // a catering order: what its event needs; a delivery: where to and the note for the driver
          if (fields['handover'] != null || fields['event_guests'] != null)
            EventDetails(
              guests: _n(fields['event_guests']),
              handover: _text(fields['handover']) == 'delivery' ? 'delivery' : 'pickup',
              address: _text(fields['address']),
              note: _text(fields['event_note']),
            ).words,
        ].where((line) => line.isNotEmpty).toList(),
      );
    case 'table':
      final was = _text(said['was']), now = _text(said['now']);
      return (
        title: was.isEmpty
            ? 'Put at table $now'
            : now.isEmpty
            ? 'Taken off table $was'
            : 'Moved from table $was to table $now',
        under: const [],
      );
    case 'server':
      final was = _text(said['was']), now = _text(said['now']);
      return (
        title: was.isEmpty
            ? 'Given to $now'
            : now.isEmpty
            ? 'Taken from $was: nobody has it now'
            : 'Handed from $was to $now',
        under: const [],
      );
    case 'guests':
      return (title: _changed('Guests', _text(said['was']), _text(said['now'])), under: const []);
    case 'stage':
      // an order that was brought to the customer was delivered, not picked up (docs/delivery.md)
      final delivery = said['delivery'] == true;
      final was = stageLabel(_text(said['was']), delivery: delivery);
      final now = stageLabel(_text(said['now']), delivery: delivery);
      // a delivery that left says who took it, and one that came back that it did
      if (delivery && said['now'] == 'out') {
        final driver = _text(said['driver']);
        return (title: driver.isEmpty ? 'Left with a driver' : 'Left with $driver', under: const []);
      }
      if (delivery && said['was'] == 'out' && said['now'] != 'picked_up') {
        return (title: 'Came back from the driver', under: const []);
      }
      return (
        title: now.isNotEmpty
            ? 'Marked ${now.toLowerCase()}'
            : was.isEmpty
            ? 'Put back with the kitchen'
            : 'No longer ${was.toLowerCase()}',
        under: const [],
      );
    case 'driver':
      // on its way, it changed hands
      final was = _text(said['was']), now = _text(said['now']);
      return (title: was.isEmpty ? 'Handed to $now' : 'Handed from $was to $now', under: const []);
    case 'promised':
      return (title: _changed('Time promised', at(said['was']), at(said['now'])), under: const []);
    case 'quoted':
      final was = _text(said['was']), now = _text(said['now']);
      return (
        title: now.isEmpty ? 'Quote taken off' : 'Quoted $now minutes',
        under: [if (was.isNotEmpty && now.isNotEmpty) 'It was $was'],
      );
    case 'split':
      final was = _split(said['was']), now = _split(said['now']);
      return (
        title: now.isEmpty ? 'Put back as one check' : 'Split $now',
        under: [if (was.isNotEmpty) 'It was split $was'],
      );
    case 'merged':
      return (title: 'Made one with ${_otherCheck(said)}', under: const ['Its dishes went to that check']);
    case 'field':
      final was = _text(said['was']), now = _text(said['now']);
      return switch (said['field']) {
        'customer_name' => (title: _changed('Name', was, now), under: const <String>[]),
        'phone' => (title: _changed('Phone', was, now), under: const <String>[]),
        'note' => (title: _changed('Note', was, now), under: const <String>[]),
        'order_type' => (
          title: 'Made ${_orderKind(now)} order',
          under: [if (was.isNotEmpty) 'It was ${_orderKind(was)} order'],
        ),
        'channel' => (title: _changed('Taken by', channelLabel(was), channelLabel(now)), under: const <String>[]),
        // what a catering order's event needs (docs/catering.md)
        'event_guests' => (title: _changed('Guests for the event', was, now), under: const <String>[]),
        'handover' => (
          title: now.isEmpty ? 'Pickup or delivery taken off' : 'Set for ${handoverLabel(now).toLowerCase()}',
          under: [if (was.isNotEmpty && now.isNotEmpty) 'It was for ${handoverLabel(was).toLowerCase()}'],
        ),
        'address' => (title: _changed('Address', was, now), under: const <String>[]),
        // a catering order's note is about its event; any other order's is for the driver
        'event_note' => (
          title: _changed(said['catering'] == false ? 'Note for the driver' : 'Note for the event', was, now),
          under: const <String>[],
        ),
        final field => (title: _changed(_text(field), was, now), under: const <String>[]),
      };
    case 'added' || 'moved_in':
      final options = [
        if (said['options'] is List)
          for (final option in said['options'] as List) _text(option),
      ];
      final price = _text(said['unit_price']);
      final moved = step.what == 'moved_in';
      return (
        title: moved ? '${_dish(said)} came over from ${_otherCheck(said)}' : 'Rang in ${_dish(said)}',
        under: [
          if (options.isNotEmpty) options.join(', '),
          [
            if (said['seat'] != null) 'seat ${_text(said['seat'])}',
            if (_text(said['course']).isNotEmpty) _text(said['course']),
            if (price.isNotEmpty) '${dollars(price)}${(_n(said['qty']) ?? 1) == 1 ? '' : ' each'}',
          ].join(' · '),
          if (_text(said['note']).isNotEmpty) 'Note: ${_text(said['note'])}',
          if (said['changed'] == true) 'In place of the one changed',
          if (moved && _text(said['rung_by']).isNotEmpty) 'Rung in by ${_text(said['rung_by'])}',
          if (moved && said['sent'] == true) 'The kitchen already had it',
        ].where((line) => line.isNotEmpty).toList(),
      );
    case 'moved_out':
      return (title: '${_dish(said)} went to ${_otherCheck(said)}', under: const []);
    case 'changed':
      return (
        title: 'Changed ${_text(said['dish'])}',
        under: [
          if (said['changes'] is List)
            for (final change in said['changes'] as List)
              if (change is Map) _lineChange(change.cast<String, dynamic>(), time),
        ],
      );
    case 'taken_off':
      return (title: 'Took off ${_dish(said)}', under: const ['Before the kitchen was sent it']);
    case 'voided':
      final reason = _text(said['reason']);
      return (title: 'Voided ${_dish(said)}', under: [if (reason.isNotEmpty) reason]);
    case 'sent':
      final course = _text(said['course']);
      return (
        title: course.isEmpty ? 'Sent to the kitchen' : 'Sent $course to the kitchen',
        under: [
          [
            if (said['dishes'] is List)
              for (final dish in said['dishes'] as List)
                if (dish is Map) _dish(dish.cast<String, dynamic>()),
          ].join(', '),
        ].where((line) => line.isNotEmpty).toList(),
      );
    case 'closed':
      return (title: 'Closed the check', under: const []);
    case 'reopened':
      return (title: 'Reopened the check', under: const []);
    case 'voided_check':
      final reason = _text(said['reason']);
      return (title: 'Voided the whole check', under: [if (reason.isNotEmpty) reason]);
    case 'discount':
      final on = _text(said['dish']).isEmpty ? 'the whole check' : _text(said['dish']);
      final value = _text(said['value']);
      final off = switch (said['kind']) {
        'comp' => 'Comped $on',
        'percent' => '$value% off $on',
        _ => '${dollars(value)} off $on',
      };
      return (
        // one that came with its dish from another check was given there, not here
        title: said['carried'] == true ? '$off, as it came over' : off,
        under: [
          if (_text(said['name']).isNotEmpty) _text(said['name']),
          if (_text(said['note']).isNotEmpty) 'Note: ${_text(said['note'])}',
        ],
      );
    case 'discount_removed':
      final on = _text(said['dish']).isEmpty ? 'the whole check' : _text(said['dish']);
      return (
        title: 'Took the discount back off $on',
        under: [if (_text(said['name']).isNotEmpty) _text(said['name'])],
      );
    case 'charge':
      final value = _text(said['value']);
      return (
        title: 'Added a charge: ${_text(said['name'])}',
        under: [if (value.isNotEmpty) said['kind'] == 'percent' ? '$value%' : dollars(value)],
      );
    case 'charge_removed':
      return (title: 'Took off the charge: ${_text(said['name'])}', under: const []);
    case 'paid':
      final tendered = _text(said['tendered']);
      return (
        title: 'Payment of ${dollars(_text(said['amount']))}',
        under: [
          [
            methodLabel(_text(said['method'])),
            if (tendered.isNotEmpty) '${dollars(tendered)} handed over',
            if (said['check'] is num) 'for check ${_n(said['check'])}',
          ].join(' · '),
          if (_text(said['note']).isNotEmpty) 'Note: ${_text(said['note'])}',
        ],
      );
    case 'allergy' || 'allergy_cleared':
      final where = said['seat'] == null ? 'for the whole table' : 'at seat ${_text(said['seat'])}';
      if (step.what == 'allergy_cleared') return (title: 'Allergy $where cleared', under: const []);
      final allergens = [
        if (said['allergens'] is List)
          for (final allergen in said['allergens'] as List) _text(allergen),
      ];
      return (
        title: 'Allergy $where',
        under: [
          if (allergens.isNotEmpty) allergens.join(', '),
          if (_text(said['note']).isNotEmpty) _text(said['note']),
        ],
      );
    case 'tax_exempt':
      final certificate = _text(said['certificate']);
      return (
        title: 'Marked tax exempt',
        under: [
          if (_text(said['organisation']).isNotEmpty) _text(said['organisation']),
          if (certificate.isNotEmpty) 'Certificate $certificate',
        ],
      );
    case 'tax_exempt_removed':
      final organisation = _text(said['organisation']);
      return (
        title: 'Put the sales tax back on',
        under: [if (organisation.isNotEmpty) 'It was tax exempt for $organisation'],
      );
    case 'bag':
      final items = [
        if (said['items'] is List)
          for (final item in said['items'] as List)
            if (item is Map)
              (item['qty'] is int && item['qty'] as int > 1 ? '${item['qty']}x ' : '') + _text(item['name']),
      ];
      return (
        title: said['changed'] == true ? 'Changed what goes in the bag' : 'Asked what goes in the bag',
        under: [items.isEmpty ? 'Nothing' : items.join(', ')],
      );
    case 'delivery_fee':
      // what a delivery costs the customer was picked, changed or taken back (docs/delivery.md)
      final now = OrderFee.of(said['now']), was = OrderFee.of(said['was']);
      return (
        title: now == null
            ? 'Delivery fee taken back'
            : now.none
            ? 'No delivery fee'
            : 'Delivery fee ${feeWords(now.amount)}',
        under: [
          if (now != null && !now.none) now.reach,
          // the hub was asked how far the address is, and this is what whoever picked was told
          if (now?.measured case final measured?) 'The map said ${measured.words}',
          if (was != null) 'It was ${was.none ? 'no fee' : was.words}',
        ],
      );
    default:
      return (title: step.what, under: const []);
  }
}

/// Who did a step and where, in one line: "Amy · mac1 · approved by Mike".
String whoLine(HistoryStep step) => [
  if (step.by.isNotEmpty) step.by,
  if (step.device.isNotEmpty) step.by.isEmpty ? 'at ${step.device}, nobody named' : step.device,
  if (step.approvedBy.isNotEmpty) 'approved by ${step.approvedBy}',
  if (step.offline) 'taken while the hub was not answering',
].join(' · ');
