import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/screens/location_settings_screen.dart';

/// Brings a row of Location settings (by its key) up onto the screen. The screen is a list that builds only
/// what is near the screen, so a row far down it is neither found nor tapped until the list is scrolled to
/// it: every row added near the top pushes the ones below a little further out.
Future<void> bringUp(WidgetTester tester, String key) async {
  final row = find.byKey(ValueKey(key));
  if (row.evaluate().isEmpty) {
    final list = find.descendant(of: find.byType(LocationSettingsScreen), matching: find.byType(Scrollable)).first;
    await tester.scrollUntilVisible(row, 200, scrollable: list);
  }
  await tester.ensureVisible(row);
  await tester.pumpAndSettle();
}
