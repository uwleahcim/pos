import 'phone.dart' show formatPhoneNumber;

/// Who paid a check, said afterwards from the guest list (docs/guest-list.md, "Who paid, said afterwards").
///
/// A check with several guests waits until somebody says which of them paid: its money counts for none of
/// them. A tap on the check says it while the party sits there; when nobody tapped, whoever may read the
/// guest list says it here. The hub hands out each such check with its guests ([PaidCheck]) and keeps the
/// word; this is its answer read into names. Amounts stay the hub's own words ("84.20").

String _s(Object? value, [String or = '']) => value is String ? value : or;
int _i(Object? value) => value is num ? value.toInt() : 0;

/// One guest of a check: a party the host seated on it, the number typed on it, or the number of a check
/// that was merged into it.
class PaidGuest {
  const PaidGuest({required this.key, this.name = '', this.phone = '', this.typed = false, this.pays = false});

  factory PaidGuest.fromJson(Map<String, dynamic> json) => PaidGuest(
    key: _s(json['key']),
    name: _s(json['name']),
    phone: _s(json['phone']),
    typed: json['typed'] == true,
    pays: json['pays'] == true,
  );

  /// What the hub knows this guest of the check by: what is sent back to say that they paid.
  final String key;
  final String name;

  /// Their number, as digits.
  final String phone;

  /// Their number is the one typed on the check: they pay it unless another guest is said to.
  final bool typed;

  /// The check's money counts for this guest.
  final bool pays;

  /// What the guest list calls them: their name, or their number when they gave none.
  String get called => name.isEmpty ? formatPhoneNumber(phone) : name;
}

/// One check with everybody who is a guest of it, and which of them its money counts for.
class PaidCheck {
  const PaidCheck({
    required this.orderId,
    required this.day,
    this.orderNo,
    this.table = '',
    this.openedMs = 0,
    this.kind = '',
    this.net = '0.00',
    this.guests = const [],
    this.waits = false,
    this.saidBy = '',
  });

  factory PaidCheck.fromJson(Map<String, dynamic> json) => PaidCheck(
    orderId: _s(json['order_id']),
    day: DateTime.tryParse(_s(json['day'])) ?? DateTime(2000),
    orderNo: json['order_no'] is num ? _i(json['order_no']) : null,
    table: _s(json['table']),
    openedMs: _i(json['opened_ms']),
    kind: _s(json['kind']),
    net: _s(json['net'], '0.00'),
    guests: [
      if (json['guests'] is List)
        for (final row in json['guests'] as List)
          if (row is Map && _s(row['key']).isNotEmpty) PaidGuest.fromJson(row.cast<String, dynamic>()),
    ],
    waits: json['waits'] == true,
    saidBy: _s(json['said_by']),
  );

  final String orderId;

  /// The day of service the check counts on.
  final DateTime day;
  final int? orderNo;

  /// The table the check is of, as its name is written; empty where the hub does not say.
  final String table;
  final int openedMs;
  final String kind;

  /// What the check comes to before tax: the money that counts for the guest who paid.
  final String net;
  final List<PaidGuest> guests;

  /// Nobody was said to have paid, and no number is typed on it: its money counts for no guest yet.
  final bool waits;

  /// Who said the guest that pays; empty where nobody had to (the number on the check, its only guest).
  final String saidBy;

  /// The guest the check's money counts for, if any.
  PaidGuest? get payer {
    for (final guest in guests) {
      if (guest.pays) return guest;
    }
    return null;
  }

  /// Whether there is anything to say: a check with one guest is that guest's.
  bool get shared => guests.length > 1;

  /// One line on how the check stands: who paid and how the list knows, or that it waits.
  String get standing {
    final paid = payer;
    if (paid == null) return 'Nobody said who paid.';
    if (saidBy.isNotEmpty) return '${paid.called} paid, said by $saidBy.';
    if (paid.typed) return '${paid.called} paid: their number is on the check.';
    return '${paid.called} paid.';
  }
}
