import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/local_order.dart';
import 'package:pos_app/menu.dart';
import 'package:pos_app/outbox.dart';
import 'package:pos_app/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> op(String kind, Map<String, dynamic> data) => {'order_id': 'o1', 'kind': kind, 'data': data};

Line hubLine(String id, {bool fired = false, String course = '2', double rank = 0}) =>
    Line(lineId: id, item: 'Spring Roll', qty: 1, status: 'active', course: course, fired: fired, rank: rank);

const taxes = [
  TaxLine(name: 'Massachusetts meals tax', ratePct: '6.25', amount: '0.00'),
  TaxLine(name: 'Winchester meals tax', ratePct: '0.75', amount: '0.00'),
];

void main() {
  test('a new check shows its table and dishes before the hub has heard of it', () {
    final order = withLocalOps(const Order.empty('o1'), [
      op('create', {'table': 'A7', 'guests': 4}),
      op('add_line', {'line_id': 'L1', 'item': 'Spring Roll', 'qty': 2, 'seat': 1, 'course': '1'}),
    ]);
    expect(order.table, 'A7');
    expect(order.fields['guests'], 4);
    final line = order.lines.single;
    expect((line.qty, line.seat, line.course, line.pending, line.isActive), (2, 1, '1', true, true));
  });

  test('taking a line off and firing follow the hub rules', () {
    final hub = Order(
      orderId: 'o1',
      status: 'open',
      fields: const {},
      lines: [
        hubLine('L1'),
        hubLine('L2', fired: true),
        hubLine('L3', course: '1'),
      ],
      fired: const {},
    );
    final order = withLocalOps(hub, [
      op('void_line', {'line_id': 'L1'}), // never fired: it just comes off
      op('void_line', {'line_id': 'L2'}), // fired: a void
      op('add_line', {'line_id': 'L1', 'item': 'again'}), // the hub already has L1: ignored
      op('fire', {'course': '1'}),
    ]);
    final byId = {for (final l in order.lines) l.lineId: l};
    expect(byId['L1']!.status, 'removed');
    expect(byId['L2']!.status, 'void');
    expect(byId['L3']!.fired, isTrue);
    expect(order.shownLines.map((l) => l.lineId), ['L2', 'L3']);
    expect(order.heldCourses, isEmpty);
    expect(withLocalOps(hub, const []), same(hub));
  });

  test('a dragged line takes its new course and place at once; a new line goes after everything', () {
    final hub = Order(
      orderId: 'o1',
      status: 'open',
      fields: const {},
      lines: [
        hubLine('L1', course: '1', rank: 1),
        hubLine('L2', course: '1', rank: 2),
        hubLine('L3', rank: 3),
      ],
      fired: const {},
    );
    final order = withLocalOps(hub, [
      op('set_line', {'line_id': 'L1', 'course': '2', 'rank': 2.5}),
      op('set_line', {'line_id': 'L2', 'rank': 0.5}),
      op('set_line', {'line_id': 'L3', 'course': null}),
      op('add_line', {'line_id': 'L4', 'item': 'Tea'}),
    ]);
    final byId = {for (final l in order.lines) l.lineId: l};
    expect((byId['L1']!.course, byId['L1']!.rank), ('2', 2.5));
    expect((byId['L2']!.course, byId['L2']!.rank), ('1', 0.5));
    expect(byId['L3']!.course, isNull);
    expect(byId['L4']!.rank, 4.0); // after the highest rank the hub gave, as the hub itself would place it
    expect(Line.fromJson('L9', {'item': 'x', 'rank': 7}).rank, 7.0);
    expect(Line.fromJson('L9', {'item': 'x'}).rank, 0.0);
  });

  test('the estimate adds local lines at the menu price and taxes like the hub', () {
    const read = Check(
      lines: [CheckLine(lineId: 'L1', name: "General Tso's Chicken (Quart)", qty: 1, total: '25.95')],
      subtotal: '25.95',
      taxLines: taxes,
      tax: '1.82',
      taxRatePct: '7.00',
      total: '27.77',
    );
    final order = Order(
      orderId: 'o1',
      status: 'open',
      fields: const {},
      lines: [
        hubLine('L1'),
        const Line(lineId: 'L2', item: 'California Roll', qty: 1, status: 'active', pending: true),
        const Line(lineId: 'L3', item: 'Typed elsewhere', qty: 1, status: 'active', pending: true),
      ],
      fired: const {},
    );
    final check = estimateCheck(read, order, {
      'L2': const LocalLine(unitPrice: '8.50', modifiers: [CheckModifier('no cucumber')]),
    });
    expect(check.estimated, isTrue);
    expect(check.lines.map((l) => (l.lineId, l.total)), [('L1', '25.95'), ('L2', '8.50')]);
    expect(check.line('L2')!.modifiers.map((m) => m.label), ['no cucumber']);
    // 34.45: 6.25% = 2.153 -> 2.15, 0.75% = 0.258 -> 0.26, the hub's own answer for this table
    expect((check.subtotal, check.tax, check.total), ('34.45', '2.41', '36.86'));

    final unchanged = Order(orderId: 'o1', status: 'open', fields: const {}, lines: [hubLine('L1')], fired: const {});
    expect(estimateCheck(read, unchanged, const {}), same(read));
    final removed = withLocalOps(unchanged, [
      op('void_line', {'line_id': 'L1'}),
    ]);
    expect(estimateCheck(read, removed, const {}).total, '0.00');
  });

  test('a price change reads with its sign, and what a discount took off in parentheses', () {
    expect(priceChange('0.50'), '+0.50');
    expect(priceChange('-2.00'), '(2.00)');
    expect(priceChange('0.00'), '');
    expect(priceChange('0'), '');
    expect(inParens('30.00'), '(30.00)');
    expect(inParens('-30.00'), '(30.00)');
  });

  test('a check line reads its choices from a hub that sends labels alone or with what each adds', () {
    final line = CheckLine.fromJson({
      'line_id': 'L1',
      'name': 'x',
      'qty': 1,
      'total': '1.00',
      'modifiers': [
        'Brown rice',
        {'label': 'Add shrimp', 'price': '3.00', 'amount': '3.00'},
      ],
    });
    expect(line.modifiers.map((m) => (m.label, m.amount, m.charged)), [
      ('Brown rice', '0.00', false),
      ('Add shrimp', '3.00', true),
    ]);
    expect(Line.fromJson('L4', {'item': 'x', 'replaces': 'L3'}).replaces, 'L3');
    expect(Line.fromJson('L4', {'item': 'x'}).replaces, isNull);
  });

  test("the estimate scales a dish's choices with its quantity, on the hub's lines and this screen's own", () {
    const read = Check(
      lines: [
        CheckLine(
          lineId: 'L1',
          name: 'GTC',
          qty: 1,
          total: '28.95',
          modifiers: [
            CheckModifier('Add shrimp', price: '3.00', amount: '3.00'),
            CheckModifier('Brown rice'),
          ],
        ),
      ],
      subtotal: '28.95',
      taxLines: taxes,
      tax: '2.03',
      taxRatePct: '7.00',
      total: '30.98',
    );
    final order = Order(
      orderId: 'o1',
      status: 'open',
      fields: const {},
      lines: [
        const Line(lineId: 'L1', item: 'GTC', qty: 2, status: 'active'),
        const Line(lineId: 'L2', item: 'California Roll', qty: 2, status: 'active', pending: true),
      ],
      fired: const {},
    );
    final check = estimateCheck(read, order, {
      'L2': const LocalLine(
        unitPrice: '8.50',
        modifiers: [CheckModifier('Add avocado', price: '1.50')],
      ),
    });
    final gtc = check.line('L1')!;
    expect(gtc.total, '57.90');
    expect(gtc.modifiers.map((m) => (m.label, m.amount, m.charged)), [
      ('Add shrimp', '6.00', true),
      ('Brown rice', '0.00', false),
    ]);
    expect(check.line('L2')!.modifiers.map((m) => (m.label, m.amount)), [('Add avocado', '3.00')]);
    expect(check.line('L2')!.total, '17.00');
  });

  test('the estimate keeps a comp on the line that replaced its line', () {
    // an edit voids the dish and adds the changed one in its place; the comp goes with it
    const read = Check(
      lines: [CheckLine(lineId: 'L2', name: 'Peking Duck', qty: 1, total: '30.00', discount: '30.00')],
      subtotal: '30.00',
      discounts: [
        CheckDiscount(
          discountId: 'D1',
          reason: 'comp',
          name: 'Manager comp',
          kind: 'comp',
          value: '0',
          amount: '30.00',
          lineId: 'L2',
        ),
      ],
      discountTotal: '30.00',
      taxLines: taxes,
      tax: '0.00',
      taxRatePct: '7.00',
      total: '0.00',
    );
    final order = Order(
      orderId: 'o1',
      status: 'open',
      fields: const {},
      lines: [
        const Line(lineId: 'L2', item: 'Peking Duck', qty: 1, status: 'removed'),
        const Line(lineId: 'L3', item: 'Peking Duck', qty: 1, status: 'active', replaces: 'L2', pending: true),
      ],
      fired: const {},
    );
    final check = estimateCheck(read, order, {'L3': const LocalLine(unitPrice: '32.00')});
    expect(check.lines.map((l) => (l.lineId, l.total, l.discount)), [('L3', '32.00', '32.00')]);
    expect((check.discounts.single.lineId, check.discounts.single.amount), ('L3', '32.00'));
    expect((check.discountTotal, check.total), ('32.00', '0.00'));
    // the local replay carries what a new line replaces
    final replayed = withLocalOps(order, [
      op('void_line', {'line_id': 'L3'}),
      op('add_line', {'line_id': 'L4', 'item': 'Peking Duck', 'replaces': 'L3'}),
    ]);
    expect(replayed.lines.firstWhere((l) => l.lineId == 'L4').replaces, 'L3');
  });

  test('the estimate drops a comp whose dish came off the check; a discount on the whole check stays', () {
    const read = Check(
      lines: [
        CheckLine(lineId: 'L1', name: 'Tea', qty: 1, total: '10.00', discount: '10.00'),
        CheckLine(lineId: 'L2', name: 'Duck', qty: 1, total: '20.00'),
      ],
      subtotal: '30.00',
      discounts: [
        CheckDiscount(
          discountId: 'D1',
          reason: 'comp',
          name: 'Manager comp',
          kind: 'comp',
          value: '0',
          amount: '10.00',
          lineId: 'L1',
        ),
        CheckDiscount(
          discountId: 'D2',
          reason: 'birthday',
          name: 'Birthday',
          kind: 'percent',
          value: '10',
          amount: '2.00',
        ),
      ],
      discountTotal: '12.00',
      taxLines: taxes,
      tax: '1.26',
      taxRatePct: '7.00',
      total: '19.26',
    );
    final order = Order(
      orderId: 'o1',
      status: 'open',
      fields: const {},
      lines: [hubLine('L1'), hubLine('L2', fired: true)],
      fired: const {},
    );
    for (final gone in ['L1']) {
      final check = estimateCheck(
        read,
        withLocalOps(order, [
          op('void_line', {'line_id': gone}),
        ]),
        const {},
      );
      expect(check.line('L1'), isNull);
      expect(check.discounts.map((d) => d.discountId), ['D2']);
      // 10% of the 20.00 of duck; tax on the 18.00: 1.13 + 0.14
      expect((check.subtotal, check.discountTotal, check.total), ('20.00', '2.00', '19.27'));
    }
  });

  test('the estimate keeps the discounts and charges on the new lines, in the hub order', () {
    const read = Check(
      lines: [
        CheckLine(lineId: 'L1', name: 'Tea', qty: 1, total: '10.00', discount: '10.00'),
        CheckLine(lineId: 'L2', name: 'Duck', qty: 1, total: '20.00'),
      ],
      subtotal: '30.00',
      discounts: [
        CheckDiscount(
          discountId: 'D1',
          reason: 'comp',
          name: 'Manager comp',
          kind: 'comp',
          value: '0',
          amount: '10.00',
          lineId: 'L1',
        ),
        CheckDiscount(
          discountId: 'D2',
          reason: 'loyalty',
          name: 'Loyalty reward',
          kind: 'percent',
          value: '10',
          amount: '2.00',
        ),
      ],
      discountTotal: '12.00',
      charges: [
        CheckCharge(
          chargeId: 'auto_gratuity',
          name: 'Gratuity 18%',
          kind: 'percent',
          value: '18',
          amount: '3.24',
          gratuity: true,
          automatic: true,
        ),
      ],
      chargeTotal: '3.24',
      taxLines: taxes,
      tax: '1.26',
      taxRatePct: '7.00',
      total: '22.50',
    );
    final order = Order(
      orderId: 'o1',
      status: 'open',
      fields: const {},
      lines: [hubLine('L1'), hubLine('L2')],
      fired: const {},
    );
    final more = withLocalOps(order, [
      op('set_line', {'line_id': 'L2', 'qty': 2}),
    ]);
    final check = estimateCheck(read, more, const {});
    // The comp still takes the whole tea; 10% of the 40.00 of duck; the party's gratuity on the 36.00 left,
    // untaxed; tax on the 36.00: 2.25 + 0.27.
    expect(check.lines.map((l) => (l.lineId, l.total, l.discount)), [
      ('L1', '10.00', '10.00'),
      ('L2', '40.00', '0.00'),
    ]);
    expect(check.discounts.map((d) => d.amount), ['10.00', '4.00']);
    expect(check.charges.single.amount, '6.48');
    expect((check.discountTotal, check.chargeTotal, check.tax, check.total), ('14.00', '6.48', '2.52', '45.00'));
    // A taxed service charge goes into the tax base; a discount whose line is gone is dropped.
    const taxed = Check(
      lines: [CheckLine(lineId: 'L1', name: 'Tea', qty: 1, total: '10.00')],
      subtotal: '10.00',
      discounts: [
        CheckDiscount(
          discountId: 'D3',
          reason: 'promotion',
          name: 'Promotion',
          kind: 'amount',
          value: '50',
          amount: '10.00',
          lineId: 'L1',
        ),
      ],
      charges: [
        CheckCharge(chargeId: 'C1', name: 'Catering', kind: 'percent', value: '18', amount: '0.00', taxed: true),
      ],
      taxLines: taxes,
      tax: '0.00',
      taxRatePct: '7.00',
      total: '0.00',
    );
    final added = withLocalOps(
      Order(orderId: 'o1', status: 'open', fields: const {}, lines: [hubLine('L1')], fired: const {}),
      [
        op('void_line', {'line_id': 'L1'}),
        op('add_line', {'line_id': 'L2', 'item': 'Duck', 'qty': 1}),
      ],
    );
    final again = estimateCheck(taxed, added, {'L2': const LocalLine(unitPrice: '20.00')});
    expect(again.discounts, isEmpty);
    expect(again.charges.single.amount, '3.60');
    expect((again.tax, again.total), ('1.66', '25.26')); // 7% of 23.60: 1.475 -> 1.48, 0.177 -> 0.18
  });

  test('money in cents', () {
    expect(cents('17.95'), 1795);
    expect(cents('8.5'), 850);
    expect(cents('-1.05'), -105);
    expect(money(3686), '36.86');
    expect(money(5), '0.05');
  });

  test('accepted operations stay local until a read that began after them comes back', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final settings = Settings(device: 't1', endpoints: ['http://hub:8000'], prefs: prefs);
    var up = false;
    final api = PosApi(
      settings,
      timeout: const Duration(milliseconds: 100),
      client: MockClient((request) async {
        if (!up) throw http.ClientException('down', request.url);
        final ops = (jsonDecode(request.body) as List).cast<Map<String, dynamic>>();
        return http.Response(jsonEncode({'accepted': ops.map((o) => o['op_id']).toList(), 'cursor': 1}), 202);
      }),
    );
    final outbox = Outbox(api, settings, prefs: prefs);
    await outbox.add('o1', 'add_line', {'line_id': 'L1', 'item': 'x'});
    await outbox.flush();
    expect(outbox.localOps('o1').length, 1); // still queued: the hub is down
    final staleRead = outbox.readMark; // a read that began before the hub accepted it
    up = true;
    await outbox.flush();
    expect(outbox.pending, 0);
    outbox.seen('o1', staleRead);
    expect(outbox.localOps('o1').length, 1); // that read may not show it
    outbox.seen('o1', outbox.readMark);
    expect(outbox.localOps('o1'), isEmpty);
    expect(outbox.localOps('o2'), isEmpty);
    outbox.dispose();
  });
}
