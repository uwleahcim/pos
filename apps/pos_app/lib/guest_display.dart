/// The guest display (docs/guest-display.md): a screen turned to the customer that shows the order being rung
/// up on the screen it is linked to. Two halves are here. What the hub answers for a display
/// (`GET /guest-display?of=`): the order as a guest reads it, which is its bill, worked out on the hub and
/// only drawn here. And [Showing]: what a screen where orders are taken tells the hub it has open, so that a
/// display linked to it has something to show.
library;

import 'dart:async';

import 'api.dart';
import 'live.dart';
import 'session.dart';

/// A line of words with an amount beside it: a sum under the dishes ("Sales tax 7%", "2.80"), a payment
/// ("Paid cash", "-40.00"). A row with no amount is words only ("40.00 handed over, 3.73 change").
class GuestRow {
  const GuestRow(this.label, [this.amount = '']);

  factory GuestRow.fromJson(Map<String, dynamic> json) =>
      GuestRow(json['label'] as String? ?? '', json['amount'] as String? ?? '');

  final String label;
  final String amount;
}

/// One dish as the bill lists it: how many, its name, what it comes to with its choices, and under it its
/// choices and a comp on it, each with how far in it stands (a choice of a choice is one step in).
class GuestLine {
  const GuestLine({required this.qty, required this.name, required this.amount, this.notes = const []});

  factory GuestLine.fromJson(Map<String, dynamic> json) => GuestLine(
    qty: (json['qty'] as num?)?.toInt() ?? 1,
    name: json['name'] as String? ?? '',
    amount: json['amount'] as String? ?? '',
    notes: [
      for (final note in json['notes'] as List? ?? const [])
        (text: (note as Map)['text']?.toString() ?? '', depth: (note['depth'] as num?)?.toInt() ?? 0),
    ],
  );

  final int qty;
  final String name;
  final String amount;
  final List<({String text, int depth})> notes;
}

/// An order as a guest reads it.
class GuestOrder {
  const GuestOrder({
    required this.orderId,
    this.where = '',
    this.detail = '',
    this.lines = const [],
    this.sums = const [],
    this.total = '',
    this.paid = const [],
    this.due,
    this.paidInFull = false,
  });

  factory GuestOrder.fromJson(Map<String, dynamic> json) => GuestOrder(
    orderId: json['order_id'] as String? ?? '',
    where: json['where'] as String? ?? '',
    detail: json['detail'] as String? ?? '',
    lines: [for (final line in json['lines'] as List? ?? const []) GuestLine.fromJson(line as Map<String, dynamic>)],
    sums: [for (final row in json['sums'] as List? ?? const []) GuestRow.fromJson(row as Map<String, dynamic>)],
    total: json['total'] as String? ?? '',
    paid: [for (final row in json['paid'] as List? ?? const []) GuestRow.fromJson(row as Map<String, dynamic>)],
    due: json['due'] as String?,
    paidInFull: json['paid_in_full'] == true,
  );

  final String orderId;

  /// "Table 12", "Order #7", "Bar tab".
  final String where;

  /// The first name on a to-go order or a tab; empty for a table.
  final String detail;
  final List<GuestLine> lines;

  /// Between the dishes and the total: the subtotal, each discount and charge, sales tax as one line.
  final List<GuestRow> sums;
  final String total;

  /// Under the total: each payment, and the change of one paid in cash.
  final List<GuestRow> paid;

  /// What is still owed once something was paid; null while nothing was.
  final String? due;
  final bool paidInFull;
}

/// What a guest display shows now, as the hub answers it.
class GuestDisplay {
  const GuestDisplay({this.head = const [], this.showing, this.order, this.left, this.known = true});

  factory GuestDisplay.fromJson(Map<String, dynamic> json) {
    final left = json['left'];
    return GuestDisplay(
      head: [for (final line in json['head'] as List? ?? const []) line.toString()],
      showing: json['showing'] as String?,
      order: json['order'] is Map<String, dynamic> ? GuestOrder.fromJson(json['order'] as Map<String, dynamic>) : null,
      left: left is Map && left['order_id'] is String
          ? (orderId: left['order_id'] as String, paidInFull: left['paid_in_full'] == true)
          : null,
      known: json['known'] != false,
    );
  }

  /// The restaurant's own lines, as on its bills; the first is its name.
  final List<String> head;

  /// The order the linked screen has open, whether or not there is anything to show of it yet; null when
  /// it has none open.
  final String? showing;

  /// That order as a guest reads it; null while there is nothing to show.
  final GuestOrder? order;

  /// The order the linked screen had open before this one (or before none), and whether it is paid in full
  /// now: an order paid and left in one tap is thanked for although no read ever saw it paid.
  final ({String orderId, bool paidInFull})? left;

  /// Whether the hub hears from the linked screen at all right now.
  final bool known;

  /// The restaurant's name, to greet with; empty when the location never gave one.
  String get name => head.isEmpty ? '' : head.first;
}

/// Tells the hub which order this screen has open, for a guest display linked to it.
///
/// The order screen says when it comes up ([open]) and when it goes ([close]); this passes it on, one call
/// at a time, the latest word last. It is a help and no more: a hub that does not answer, or one older than
/// guest displays, costs nothing and is never a reason to say the hub is away. With nobody signed in (a
/// sign-out, a screen that locked itself for standing idle) the screen has nothing open as far as a guest
/// goes, whatever lies under the sign-in pad; signed in again, the order is back.
///
/// Nothing is said until [start]: the app starts it, a test need not. The hub is told again whenever it is
/// found again (it keeps this in memory and may have restarted), and told "nothing" when the app comes up,
/// so an order that was open when the app was closed does not stay on the guest's screen.
class Showing {
  Showing(this._api);

  final PosApi _api;
  Session? _session;
  StreamSubscription<LiveChange>? _live;
  bool _started = false;
  String? _open; // the order the order screen has up
  bool _busy = false;
  bool _again = false;
  bool _told = false; // the hub has this screen's word since it was last found
  String? _said; // what it was told

  /// What this screen would have a guest see now: the open order, unless nobody is signed in.
  String? get now => (_session?.signedIn ?? true) ? _open : null;

  void start({Session? session}) {
    if (_started) return;
    _started = true;
    _session = session?..addListener(_tell);
    // found again: the hub may have forgotten, so the word is said afresh
    _live = _api.live.changes.listen((change) {
      if (!change.everything) return;
      _told = false;
      _tell();
    });
    _tell();
  }

  /// The order screen of [orderId] came up.
  void open(String orderId) {
    _open = orderId;
    _tell();
  }

  /// The order screen of [orderId] went. (Another may have come up before this one went: that one stays.)
  void close(String orderId) {
    if (_open != orderId) return;
    _open = null;
    _tell();
  }

  void _tell() {
    if (!_started) return;
    if (_busy) {
      _again = true;
      return;
    }
    unawaited(_send());
  }

  Future<void> _send() async {
    _busy = true;
    try {
      do {
        _again = false;
        final word = now;
        if (_told && word == _said) continue;
        if (!_api.settings.isConfigured) break;
        if (!await _api.sayShowing(word)) break; // nothing answered: said again when the hub is found again
        _told = true;
        _said = word;
      } while (_again);
    } finally {
      _busy = false;
    }
  }

  void dispose() {
    _started = false;
    _session?.removeListener(_tell);
    unawaited(_live?.cancel());
  }
}
