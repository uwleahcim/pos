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

/// A screen with the room for the whole floor at the largest the map draws a table: every table says all
/// it has to say. On a smaller screen a table says less, not the same in smaller letters
/// (floor_readable_test.dart), so a test of what a table says is run here.
const roomy = Size(3400, 2200);

void main() {
  test('the plan parses with rooms, tables and the open check on A7', () {
    final plan = FloorPlan.fromJson(floorJson());
    expect(plan.tables.length, 42);
    expect(plan.rooms.map((r) => r.id), ['D', 'AB', 'JK']);
    expect(plan.courses.map((c) => c.id), ['drinks', '1', '2', '3']);
    final a7 = plan.checksAt('A7').single;
    expect((a7.guests, a7.server, a7.serverId, a7.stage), (4, 'Amy', 's1', 'waiting'));
    expect(plan.checksAt('A8'), isEmpty);
  });

  testWidgets('the map draws every table and a tap names the table', (tester) async {
    final api = PosApi(
      Settings(device: 't1', endpoints: ['http://hub:8000']),
      client: MockClient((request) async => http.Response.bytes(utf8.encode(jsonEncode(floorJson())), 200)),
    );
    final tapped = <String>[];
    tester.view
      ..physicalSize = roomy
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
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
    expect(find.text('\$36.86'), findsOneWidget); // what they have run up
    // whose table it is, by name, on the table itself
    expect(find.descendant(of: find.byKey(const ValueKey('table-server:A7')), matching: find.text('Amy')), findsOne);
    expect(find.byKey(const ValueKey('table-server:A8')), findsNothing); // a free table is nobody's
    await tester.tap(find.text('A7'));
    expect(tapped, ['A7']);

    await tester.tap(find.widgetWithText(ChoiceChip, 'Bar and lounge'));
    await tester.pump();
    // the tables glide to their places in the room, and the other rooms' are gone when they have arrived
    await tester.pump(FloorViewState.glideTime + const Duration(milliseconds: 20));
    expect(find.text('B5'), findsNothing);
    expect(find.text('K1'), findsOneWidget);
    await tester.pumpWidget(const SizedBox()); // stops the refresh timer
  });
}
