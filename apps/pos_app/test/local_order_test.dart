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

Line hubLine(String id, {bool fired = false, String course = '2'}) =>
    Line(lineId: id, item: 'Spring Roll', qty: 1, status: 'active', course: course, fired: fired);

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
      'L2': const LocalLine(unitPrice: '8.50', modifiers: ['no cucumber']),
    });
    expect(check.estimated, isTrue);
    expect(check.lines.map((l) => (l.lineId, l.total)), [('L1', '25.95'), ('L2', '8.50')]);
    expect(check.line('L2')!.modifiers, ['no cucumber']);
    // 34.45: 6.25% = 2.153 -> 2.15, 0.75% = 0.258 -> 0.26, the hub's own answer for this table
    expect((check.subtotal, check.tax, check.total), ('34.45', '2.41', '36.86'));

    final unchanged = Order(orderId: 'o1', status: 'open', fields: const {}, lines: [hubLine('L1')], fired: const {});
    expect(estimateCheck(read, unchanged, const {}), same(read));
    final removed = withLocalOps(unchanged, [
      op('void_line', {'line_id': 'L1'}),
    ]);
    expect(estimateCheck(read, removed, const {}).total, '0.00');
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
