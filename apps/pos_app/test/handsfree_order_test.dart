import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/local_order.dart';
import 'package:pos_app/screens/order_screen.dart';
import 'package:pos_app/session.dart';

import 'hub.dart';

Map<String, dynamic> ben() => {
  'staff_id': 's2',
  'name': 'Ben',
  'role': 'server',
  'method': 'face',
  'preferences': {'text_scale': 1.0, 'high_contrast': false, 'locale': 'en'},
};

void main() {
  test("a line carries who added it, from the hub and from this screen's own operations", () {
    final order = Order.fromJson({
      'order_id': 'o1',
      'fields': {'server': 'Amy', 'server_id': 's1'},
      'lines': {
        'L1': {...line('Egg roll'), 'by': 'Amy', 'by_id': 's1'},
        'L2': line('Tea'),
      },
    });
    expect((order.lines[0].by, order.lines[0].byId), ('Amy', 's1'));
    expect((order.lines[1].by, order.lines[1].byId), ('', null), reason: 'an older app did not say');
    final local = withLocalOps(order, [
      {
        'op_id': 'x',
        'order_id': 'o1',
        'kind': 'add_line',
        'hlc': '1-0',
        'device': 't1',
        'data': {'line_id': 'L3', 'item': 'Pudding', 'by': 'Ben', 'by_id': 's2'},
      },
    ]);
    final l3 = local.lines.firstWhere((l) => l.lineId == 'L3');
    expect((l3.by, l3.byId, l3.pending), ('Ben', 's2', true));
    expect((l3.copyWith(qty: 2).by, l3.copyWith(qty: 2).byId), ('Ben', 's2'));
  });

  testWidgets("a hands-free switch mid-order keeps the order open; the next dishes are the new person's", (
    tester,
  ) async {
    final t = await terminal(tester);
    t.session.staff = const Staff(staffId: 's1', name: 'Amy', role: 'server', method: 'pin');
    t.hub.orders.add({
      ...table('o1', {}),
      'fields': {'table': 'A1', 'guests': 2, 'order_type': 'dine_in', 'server': 'Amy', 'server_id': 's1'},
    });
    await tester.pumpWidget(
      MaterialApp(
        home: OrderScreen(api: t.api, outbox: t.outbox, photos: t.photos, orderId: 'o1', session: t.session),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('s:dinner/apps')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('e:dinner:1:EGGROLL')));
    await tester.pumpAndSettle();
    final first = t.hub.opsFor('o1').last['data'] as Map;
    expect((first['by'], first['by_id']), ('Amy', 's1'));
    expect(find.textContaining('by Amy'), findsNothing, reason: "the order is Amy's: her own dishes need no name");

    // Ben steps up: the camera knew him, the session is his, and the order stays on the screen.
    t.session.applySignIn(ben());
    await tester.pumpAndSettle();
    expect(find.byType(OrderScreen), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('e:dinner:1:EGGROLL')));
    await tester.pumpAndSettle();
    final second = t.hub.opsFor('o1').last['data'] as Map;
    expect((second['by'], second['by_id']), ('Ben', 's2'));
    expect(find.textContaining('by Ben'), findsOneWidget, reason: 'the check says whose the new dish is');
    await stop(tester);
  });
}
