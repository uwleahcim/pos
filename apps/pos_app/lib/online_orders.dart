/// An order that came from the restaurant's website by itself (docs/online-orders.md, "On the screens"):
/// what the hub keeps on it of where it came from, and the words the screens say of it. Nothing here writes
/// anything: where an order came from is the hub's to say, and a screen cannot make it up.
library;

import 'api.dart';
import 'day_report.dart' show dollars, methodLabel;
import 'takeout.dart' show oneLine;

/// What a screen says of such an order, in the list of checks (as the mark's name) and on the order.
const fromTheWebsite = 'From the website';

/// The note the hub writes on the payment of an order that was paid on the website.
const paidOnlineNote = 'Paid online';

/// What the hub wrote on an order it took from the website (`online` on the order): the website's own
/// number for it, whether it is picked up or delivered, how the customer chose to pay there, and what they
/// were charged.
class OnlineOrder {
  const OnlineOrder({this.source = '', this.id = '', this.type = '', this.payment = '', this.total = ''});

  /// As an order carries it; null for an order that was rung in on a screen, whatever its channel says.
  static OnlineOrder? of(Map<String, dynamic> fields) {
    final about = fields['online'];
    if (about is! Map) return null;
    return OnlineOrder(
      source: oneLine(about['source']),
      id: oneLine(about['id']),
      type: oneLine(about['type']),
      payment: oneLine(about['payment']).toUpperCase(),
      total: oneLine(about['total']),
    );
  }

  final String source;

  /// The website's own number for the order: what to look it up by in GloriaFood's app.
  final String id;
  final String type; // pickup | delivery

  /// How the customer chose to pay on the website, in GloriaFood's word: ONLINE, CASH, CARD, CARD_PHONE.
  final String payment;

  /// What the website charged, to the cent; empty when it gave no total.
  final String total;

  /// "GloriaFood" for the one website the hub takes orders from today, and a name nobody knows as it came.
  String get sourceName => source == 'gloriafood' ? 'GloriaFood' : source;
}

/// Whether a payment is the one the hub records for an order paid on the website: money taken outside the
/// POS, with the hub's own note.
bool paidOnline(Payment payment) => payment.method == 'elsewhere' && payment.note == paidOnlineNote;

/// How a payment was taken, in words: "Paid online" for the website's, otherwise as the reports say a
/// method ("Cash", "Card", "Paid elsewhere").
String paidAs(String method, String note) =>
    method == 'elsewhere' && note == paidOnlineNote ? paidOnlineNote : methodLabel(method);

/// How an order from the website is to be paid while the POS has taken nothing on it, by what the customer
/// chose there: "pays cash at pickup", "pays by card at the door". Null for an order that was rung in on a
/// screen, and for a way of paying this build does not know.
String? paysHow(Order order) {
  final online = order.online;
  if (online == null) return null;
  final where = order.isDelivery ? 'at the door' : 'at pickup';
  return switch (online.payment) {
    'CASH' => 'pays cash $where',
    'CARD' => 'pays by card $where',
    'CARD_PHONE' => 'pays by card over the phone',
    // the website took money and the hub recorded none of it: it was paid in more than one way there, or
    // the website gave no total (docs/online-orders.md, "The money")
    'ONLINE' => 'check ${online.sourceName} for what was paid online',
    _ => null,
  };
}

/// What the order's own screen lists of an order from the website, a line each: what to find it by on the
/// website, and what the customer was charged there.
List<String> onlineFacts(OnlineOrder online) => [
  [
    if (online.id.isNotEmpty) 'Order ${online.id}',
    if (online.sourceName.isNotEmpty) 'on ${online.sourceName}',
    if (online.type.isNotEmpty) '· ${online.type}',
  ].join(' '),
  if (online.total.isNotEmpty) 'Charged on the website: ${dollars(online.total)}',
].where((line) => line.isNotEmpty).toList();
