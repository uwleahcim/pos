import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/camera.dart';
import 'package:pos_app/coursing.dart';
import 'package:pos_app/screens/order_screen.dart';
import 'package:pos_app/screens/orders_screen.dart';

import 'hub.dart';
import 'location_rows.dart';

/// Location settings: a manager turns coursing on or off and names the courses, as many as the kitchen
/// serves, and every order screen follows (`GET/PUT /settings/coursing`). Quote times live on the same
/// screen.

/// Through the manager PIN to the Location settings screen.
Future<Terminal> pumpLocation(WidgetTester tester, {void Function(Hub hub)? setUp}) async {
  final t = await terminal(tester);
  setUp?.call(t.hub);
  // tall enough for the courses, which stand under the manager's reports, whatever rows come above them
  tester.view.physicalSize = wholeLocation;
  await tester.pumpWidget(
    MaterialApp(
      home: OrdersScreen(
        api: t.api,
        outbox: t.outbox,
        settings: t.settings,
        session: t.session,
        camera: NoCamera(),
        photos: t.photos,
      ),
    ),
  );
  await tester.pumpAndSettle();
  await openHome(tester, 'location');
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField).last, '9999');
  await tester.tap(find.widgetWithText(FilledButton, 'Open location settings'));
  await tester.pumpAndSettle();
  return t;
}

String nameIn(WidgetTester tester, String key) =>
    tester.widget<TextField>(find.byKey(ValueKey('course-name:$key'))).controller!.text;

bool isDefault(WidgetTester tester, String key) =>
    (tester.widget<IconButton>(find.byKey(ValueKey('course-default:$key'))).icon as Icon).icon == Icons.star;

void main() {
  test('the coursing settings parse with the standard courses when the hub says nothing', () {
    final coursing = Coursing.fromJson({'revision': 0}); // an older hub
    expect((coursing.enabled, coursing.defaultCourse), (true, '1'));
    expect(coursing.courses.map((c) => c.name), ['Drinks', 'Appetizers', 'Entrees', 'Dessert']);
    expect(coursing.active.length, 4);

    final off = Coursing.fromJson({
      'enabled': false,
      'default': 'gone',
      'courses': [
        {'id': 'soup', 'name': 'Soup'},
        {'id': 'mains', 'name': 'Mains'},
      ],
    });
    expect((off.enabled, off.defaultCourse), (false, 'soup')); // a default not on the list falls to the first
    expect(off.active, isEmpty);
    expect((off.nameOf('mains'), off.nameOf('old')), ('Mains', 'old'));
    expect(off.toJson(), {
      'enabled': false,
      'default': 'soup',
      'courses': [
        {'id': 'soup', 'name': 'Soup'},
        {'id': 'mains', 'name': 'Mains'},
      ],
    });
    expect(Coursing.fromJson({'enabled': false, 'courses': []}).defaultCourse, isNull);
  });

  test('a new course is named by its name, like the hub does, and never twice', () {
    expect(newCourseId('Soup & Salad', {}), 'soup-salad');
    expect(newCourseId('Soup & Salad', {'soup-salad'}), 'soup-salad-2');
    expect(newCourseId('汤', {'course'}), 'course-2');
    expect(newCourseId('x' * 40, {}), 'x' * 28);
  });

  testWidgets('a manager names, adds, reorders and removes courses for every terminal', (tester) async {
    final t = await pumpLocation(tester);
    expect(t.hub.pins, ['9999']);
    expect(find.text('Location settings'), findsOneWidget);
    for (final (key, name) in const [('drinks', 'Drinks'), ('1', 'Appetizers'), ('2', 'Entrees'), ('3', 'Dessert')]) {
      expect(nameIn(tester, key), name);
    }
    expect(isDefault(tester, '1'), isTrue); // a new dish goes to the appetizers
    expect(isDefault(tester, 'drinks'), isFalse);

    await tester.enterText(find.byKey(const ValueKey('course-name:2')), 'Mains');
    await tester.tap(find.byKey(const ValueKey('course-delete:3')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('course-name:3')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('course-add')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('course-name:new-1')), 'Soup');
    await tester.tap(find.byKey(const ValueKey('course-default:new-1')));
    await tester.pumpAndSettle();
    expect(isDefault(tester, 'new-1'), isTrue);
    expect(isDefault(tester, '1'), isFalse);
    // the soup comes first: drag it to the top
    await tester.drag(find.byKey(const ValueKey('course-handle:new-1')), const Offset(0, -400));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('location-save')));
    await tester.pumpAndSettle();
    expect(t.hub.coursingAuth, 'Bearer tok-admin');
    expect(t.hub.coursing['enabled'], isTrue);
    expect(t.hub.coursing['default'], 'soup');
    expect((t.hub.coursing['courses'] as List).map((c) => '${c['id']}=${c['name']}'), [
      'soup=Soup',
      'drinks=Drinks',
      '1=Appetizers',
      '2=Mains',
    ]);
    expect(find.text('Courses saved'), findsOneWidget);
    // the row keeps the id the hub gave the new course, so a second save does not make it twice
    expect(find.byKey(const ValueKey('course-name:soup')), findsOneWidget);
    await stop(tester);
  });

  testWidgets('coursing can be turned off and keeps its courses; an empty list cannot be saved on', (tester) async {
    final t = await pumpLocation(tester);
    await tester.tap(find.byKey(const ValueKey('coursing-enabled')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('course-name:1')), findsNothing); // the list folds away while off
    await tester.tap(find.byKey(const ValueKey('location-save')));
    await tester.pumpAndSettle();
    expect(t.hub.coursing['enabled'], isFalse);
    expect((t.hub.coursing['courses'] as List).length, 4); // kept for when it comes back

    await tester.tap(find.byKey(const ValueKey('coursing-enabled')));
    await tester.pumpAndSettle();
    for (final key in const ['drinks', '1', '2', '3']) {
      await tester.tap(find.byKey(ValueKey('course-delete:$key')));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.byKey(const ValueKey('location-save')));
    await tester.pumpAndSettle();
    expect(saveProblem(tester), 'Courses: Coursing needs at least one course, or turn it off.');
    expect(t.hub.coursing['enabled'], isFalse); // nothing was sent

    await tester.tap(find.byKey(const ValueKey('course-add')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('location-save')));
    await tester.pumpAndSettle();
    expect(saveProblem(tester), 'Courses: Every course needs a name.');
    await tester.enterText(find.byKey(const ValueKey('course-name:new-1')), 'Only');
    t.hub.refuse = 'the course id is listed twice';
    await tester.tap(find.byKey(const ValueKey('location-save')));
    await tester.pumpAndSettle();
    expect(saveProblem(tester), 'Courses: the course id is listed twice'); // what the hub said, as it said it
    await stop(tester);
  });

  testWidgets('the quote times are set from the same screen; a server has no Location button', (tester) async {
    final t = await pumpLocation(tester);
    await bringUp(tester, 'quote-times');
    expect(find.text('Counter 15 · Phone 20 · Online 25 · Delivery 45 · Catering 60 min'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('quote-times')));
    await tester.pumpAndSettle();
    expect(find.text('Quote times'), findsNWidgets(2)); // the row and the dialog's title
    await tester.enterText(find.byKey(const ValueKey('quote:phone')), '25');
    await tester.tap(find.byKey(const ValueKey('quotes-save')));
    await tester.pumpAndSettle();
    expect(t.hub.quotes['minutes'], {'counter': 15, 'phone': 25, 'online': 25, 'delivery': 45, 'catering': 60});
    expect(find.text('Counter 15 · Phone 25 · Online 25 · Delivery 45 · Catering 60 min'), findsOneWidget);
    await stop(tester);

    await pumpOrders(tester, const [], role: 'server');
    expect(homeIds(tester), isNot(contains('location')));
    expect(find.byTooltip('Quote times'), findsNothing);
    await stop(tester);
  });

  testWidgets('with coursing off a dish goes without a course and one Fire sends everything', (tester) async {
    final t = await pumpOrders(tester, [
      table('o1', {'L1': line('Egg roll')}),
    ]);
    t.hub.coursing = {'enabled': false, 'default': '1', 'courses': standard};
    await tester.tap(find.text('Table A1'));
    await tester.pumpAndSettle();
    expect(find.byType(OrderScreen), findsOneWidget);
    expect(find.text('Seat  '), findsOneWidget);
    expect(find.text('Course  '), findsNothing); // no course chips: the row is the seats alone
    expect(find.text('Items'), findsOneWidget); // one group on the check, with its sent/held state
    expect(find.text('No course'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('s:dinner/apps')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('e:dinner:1:EGGROLL')));
    await tester.pumpAndSettle();
    final added = t.hub.opsFor('o1').last;
    expect(added['kind'], 'add_line');
    expect((added['data'] as Map).containsKey('course'), isFalse);

    await tester.tap(find.byTooltip('Fire'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Fire Appetizers'), findsNothing);
    expect(find.text('Fire everything'), findsOneWidget);
    await tester.tap(find.text('Fire everything'));
    await tester.pumpAndSettle();
    expect(t.hub.opsFor('o1').last['data'], {'course': '*'});
    await stop(tester);
  });

  testWidgets('the courses a manager named are the ones the order screen offers', (tester) async {
    final t = await terminal(tester);
    t.hub.orders.add(
      table('o1', {'L1': line('Egg roll', course: 'mains'), 'L2': line('Hot tea', course: 'old', fired: true)}),
    );
    final coursing = Coursing(
      enabled: true,
      defaultCourse: 'mains',
      courses: const [Course('soup', 'Soup'), Course('mains', 'Mains')],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: OrderScreen(api: t.api, outbox: t.outbox, photos: t.photos, orderId: 'o1', coursing: coursing),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ChoiceChip, 'Soup'), findsOneWidget);
    expect(tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Mains')).selected, isTrue); // the default
    expect(find.widgetWithText(ChoiceChip, 'Appetizers'), findsNothing); // (the menu's category tile stays)
    expect(find.text('Mains'), findsNWidgets(2)); // the chip and the group on the check
    expect(find.text('old'), findsOneWidget); // a course no longer on the list still shows, by its id

    await tester.tap(find.byKey(const ValueKey('s:dinner/apps')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('e:dinner:1:EGGROLL')));
    await tester.pumpAndSettle();
    expect((t.hub.opsFor('o1').last['data'] as Map)['course'], 'mains');

    await tester.tap(find.byTooltip('Fire'));
    await tester.pumpAndSettle();
    expect(find.text('Fire Mains'), findsOneWidget); // held
    expect(find.text('Fire Soup'), findsNothing); // nothing in it
    expect(find.text('Fire Entrees'), findsNothing);
    await stop(tester);
  });
}
