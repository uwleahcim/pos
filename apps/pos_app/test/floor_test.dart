import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/floor.dart';
import 'package:pos_app/screens/floor_view.dart';
import 'package:pos_app/settings.dart';

/// The backend's own /floor answer: the restaurant's plan with table A7 seated, appetizers fired, entrees held.
Map<String, dynamic> floorJson() =>
    jsonDecode(File('test/fixtures/floor.json').readAsStringSync()) as Map<String, dynamic>;

void main() {
  test('the plan parses with rooms, tables and the open check on A7', () {
    final plan = FloorPlan.fromJson(floorJson());
    expect(plan.tables.length, 42);
    expect(plan.rooms.map((r) => r.id), ['D', 'AB', 'JK']);
    expect(plan.courses.map((c) => c.id), ['drinks', '1', '2', '3']);
    final a7 = plan.checksAt('A7').single;
    expect((a7.guests, a7.server, a7.stage), (4, 'Amy', 'waiting'));
    expect(plan.checksAt('A8'), isEmpty);
  });

  testWidgets('the map draws every table and a tap names the table', (tester) async {
    final api = PosApi(
      Settings(device: 't1', endpoints: ['http://hub:8000']),
      client: MockClient((request) async => http.Response.bytes(utf8.encode(jsonEncode(floorJson())), 200)),
    );
    final tapped = <String>[];
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FloorView(api: api, onTable: (plan, table) => tapped.add(table.id)),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('1 of 42 tables open'), findsOneWidget);
    expect(find.text('B5'), findsOneWidget);
    expect(find.textContaining('4p'), findsOneWidget); // A7's party of four
    expect(find.text('\$36.86 A'), findsOneWidget); // what they have run up, and Amy's initial
    await tester.tap(find.text('A7'));
    expect(tapped, ['A7']);

    await tester.tap(find.widgetWithText(ChoiceChip, 'Bar and lounge'));
    await tester.pump();
    expect(find.text('B5'), findsNothing);
    expect(find.text('K1'), findsOneWidget);
    await tester.pumpWidget(const SizedBox()); // stops the refresh timer
  });
}
