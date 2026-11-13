import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/line_ops.dart';
import 'package:pos_app/menu.dart';
import 'package:pos_app/outbox.dart';
import 'package:pos_app/queue_store.dart';
import 'package:pos_app/screens/menu_panel.dart';
import 'package:pos_app/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> fixture(String name) =>
    jsonDecode(File('test/fixtures/$name.json').readAsStringSync()) as Map<String, dynamic>;

Map<String, dynamic> line(String status, {bool fired = false, String course = '2'}) => {
  'item': "General Tso's Chicken (Quart)",
  'qty': 1,
  'seat': 1,
  'course': course,
  'status': status,
  'fired': fired,
  'request': {
    'variant_id': 'GTC:quart',
    'entry_id': 'dinner:87',
    'selections': [
      {'group_id': 'rice', 'option_id': 'rice:brown'},
      {'group_id': 'addons', 'option_id': 'addons:shrimp'},
    ],
  },
  'priced': {'item': 'GTC', 'entry_id': 'dinner:87', 'variant_id': 'GTC:quart'},
};

void main() {
  test('removed lines leave the screen; a course is held while any line is unsent', () {
    final order = Order.fromJson({
      'order_id': 'o1',
      'lines': {
        'L1': line('removed'),
        'L2': line('void', fired: true),
        'L3': line('active', fired: true),
        'L4': line('active', course: '3'),
        'L5': line('active', course: '2'),
      },
    });
    expect(order.shownLines.map((l) => l.lineId), ['L2', 'L3', 'L4', 'L5']);
    expect(order.activeLines.map((l) => l.lineId), ['L3', 'L4', 'L5']);
    expect(order.heldCourses, {'2', '3'});
    final l3 = order.lines.firstWhere((l) => l.lineId == 'L3');
    expect(l3.fired && l3.canEdit, isTrue);
    expect(l3.itemId, 'GTC');
    expect(l3.request!.selections, {
      'rice': ['rice:brown'],
      'addons': ['addons:shrimp'],
    });
    expect(l3.request!.toJson(), line('active')['request']);
    expect(order.lines.firstWhere((l) => l.lineId == 'L2').canEdit, isFalse);
  });

  test('fewer of a sent dish re-adds the rest in its place; one more is a new line of the extra', () {
    const sent = Line(lineId: 'L1', item: 'Duck', qty: 2, status: 'active', fired: true, course: '2');
    final fewer = qtyChange(sent, 1, newId: () => 'L9');
    expect(fewer.ops.map((o) => o.$1), ['void_line', 'add_line', 'fire']);
    expect((fewer.ops[1].$2['line_id'], fewer.ops[1].$2['qty'], fewer.ops[1].$2['replaces']), ('L9', 1, 'L1'));
    final more = qtyChange(sent, 3, newId: () => 'L9');
    expect(more.ops.single.$1, 'add_line');
    expect(more.ops.single.$2.containsKey('replaces'), isFalse); // the extra, not a replacement
  });

  test('a change goes to the backend as one batch', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final settings = Settings(device: 't1', endpoints: ['http://hub:8000'], prefs: prefs);
    final batches = <List<String>>[];
    final api = PosApi(
      settings,
      client: MockClient((request) async {
        final ops = (jsonDecode(request.body) as List).cast<Map<String, dynamic>>();
        batches.add([for (final op in ops) op['kind'] as String]);
        return http.Response(jsonEncode({'accepted': ops.map((o) => o['op_id']).toList(), 'cursor': 3}), 202);
      }),
    );
    final outbox = Outbox(api, settings, store: MemoryStore());
    final ids = await outbox.addAll('o1', [
      ('void_line', {'line_id': 'L1'}),
      ('add_line', {'line_id': 'L2', 'item': 'x'}),
      ('fire', {'course': '2'}),
    ]);
    await outbox.flush();
    expect(ids.toSet().length, 3);
    expect(batches, [
      ['void_line', 'add_line', 'fire'],
    ]);
  });

  testWidgets('a line reopens with its choices and comes back changed', (tester) async {
    final settings = Settings(device: 't1', endpoints: ['http://hub:8000']);
    final api = PosApi(
      settings,
      client: MockClient((request) async {
        switch (request.url.path) {
          case '/menu/items/GTC':
            return http.Response.bytes(utf8.encode(jsonEncode(fixture('item_gtc'))), 200);
          case '/menu/price':
            return http.Response(jsonEncode({'name': "General Tso's Chicken (Quart)", 'unit_price': '26.95'}), 200);
        }
        return http.Response('{}', 404);
      }),
    );
    final existing = Line.fromJson('L3', line('active', fired: true));
    final detail = ItemDetail.fromJson(fixture('item_gtc'));
    ChosenLine? result;
    await tester.binding.setSurfaceSize(const Size(1000, 900));
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => result = await showDialog<ChosenLine>(
              context: context,
              builder: (_) => ItemSheet(
                api: api,
                entry: MenuEntry.fromDetail(detail, entryId: existing.entryId),
                initial: ChosenLine(name: existing.item, request: existing.request!, qty: 2, note: 'well done'),
                warning: 'Already sent to the kitchen',
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();

    Finder chip(String label) => find.ancestor(of: find.textContaining(label), matching: find.byType(ChoiceTile));
    bool selected(String label) => tester.widget<ChoiceTile>(chip(label)).selected;
    expect(selected('Brown rice'), isTrue);
    expect(selected('White rice'), isFalse); // the line's choice, not the menu default
    expect(selected('Medium'), isFalse);
    expect(find.text('2'), findsOneWidget);
    expect(find.text('well done'), findsOneWidget);
    expect(find.text('Already sent to the kitchen'), findsOneWidget);

    await tester.tap(chip('White rice'));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Update'));
    await tester.pumpAndSettle();
    expect(result!.qty, 2);
    expect(result!.request.selections['rice'], ['rice:white']);
    expect(result!.request.selections['addons'], ['addons:shrimp']);
    expect(existing.request!.selections['rice'], ['rice:brown']); // the order's own copy is untouched
  });
}
