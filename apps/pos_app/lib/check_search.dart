/// Finding a check: what the words typed in the search box of the list of checks ask for. Runs on the
/// terminal, over the checks it has read, so the list narrows as the words are typed and still does with no
/// hub in reach.
library;

import 'api.dart';
import 'customers.dart';

/// Whether [order] is one the words in [query] ask for. Every word has to be found somewhere on the check,
/// in any order and whatever its case:
///
/// - in the customer's name, the table or the server's name;
/// - in the name of a party the host seated on the check, from its reservation or the waitlist
///   ([Order.seated]): the check itself carries no such name, the list of checks is told it;
/// - digits: at the start of the order number, or (three digits or more) anywhere in the phone number,
///   however either was punctuated (`555-1234` finds `(781) 555 1234`);
/// - `#42`: the order number only;
/// - `table`: any check that is at a table; `tab`: any bar tab.
///
/// Nothing typed finds every check.
bool checkMatches(Order order, String query) {
  final words = query.toLowerCase().split(RegExp(r'\s+')).where((word) => word.isNotEmpty);
  if (words.isEmpty) return true;
  final name = order.customerName.toLowerCase();
  final seated = [for (final party in order.seated) party.toLowerCase()];
  final table = order.table.toLowerCase();
  final server = (order.fields['server']?.toString() ?? '').toLowerCase();
  final number = order.orderNo?.toString() ?? '';
  final phone = phoneDigits(order.fields['phone']?.toString());

  bool found(String word) {
    if (word.startsWith('#')) {
      final asked = word.substring(1);
      return asked.isNotEmpty && number.startsWith(asked);
    }
    if (name.contains(word) || server.contains(word)) return true;
    if (seated.any((party) => party.contains(word))) return true;
    if (table.isNotEmpty && (table.contains(word) || word == 'table')) return true;
    if (order.isTab && (word == 'tab' || word == 'tabs')) return true;
    // A number, however it was typed: 42, 781-555-1234, (781).
    if (!_numberLike.hasMatch(word)) return false;
    final digits = word.replaceAll(RegExp(r'\D'), '');
    if (digits.isEmpty) return false;
    return number.startsWith(digits) || (digits.length >= 3 && phone.contains(digits));
  }

  return words.every(found);
}

final _numberLike = RegExp(r'^[\d()+.\-]+$');
