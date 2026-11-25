import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/screens/location_settings_screen.dart';

/// A screen tall enough for the whole of Location settings with nothing to scroll, and room for the rows
/// still to come: for the tests of the cards at its bottom. A height that just fits the list as it is
/// today pushes those cards out with the next row added above them.
const wholeLocation = Size(1100, 5000);

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

/// What the Save bar at the bottom of a settings screen says did not get through, each in one line
/// ("Courses: Every course needs a name.").
List<String> saveProblems(WidgetTester tester) => [
  for (final line in tester.widgetList<Text>(find.byKey(const ValueKey('save-problem')))) line.textSpan!.toPlainText(),
];

/// The one thing the Save bar says did not get through.
String saveProblem(WidgetTester tester) => saveProblems(tester).single;

/// What the Save bar says is waiting ("Not saved: courses, time clock"); null while there is no bar.
String? saveWaiting(WidgetTester tester) {
  final line = find.byKey(const ValueKey('save-waiting'));
  return line.evaluate().isEmpty ? null : tester.widget<Text>(line).data;
}

/// Taps Save in the bar at the bottom of Location settings: the one Save for everything that screen sets
/// itself.
Future<void> saveLocation(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('location-save')));
  await tester.pumpAndSettle();
}
