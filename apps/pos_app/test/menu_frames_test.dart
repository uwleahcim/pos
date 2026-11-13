import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/screens/menu_panel.dart';
import 'package:pos_app/settings.dart';

/// What the menu builds while its trays move, and when a dish goes on the check: the work of a frame.
///
/// The panel is drawn again on every frame of a tray opening. It used to build every tile again each time,
/// with everything inside (over 800 widgets a frame on the restaurant's menu); a slow tablet could not keep
/// up. A tile is now built again only when what it shows changes.
Map<String, dynamic> fixture(String name) =>
    jsonDecode(File('test/fixtures/$name.json').readAsStringSync()) as Map<String, dynamic>;

/// How often widgets were built, by type, since [reset]: for the first time ([fresh]: a new tile, or one
/// thrown away and made from nothing) and again ([again]). Made before the first frame, so that it has seen
/// every widget's first build.
class Builds {
  Builds() {
    debugOnRebuildDirtyWidget = (element, _) {
      final counts = _built.add(element) ? _fresh : _again;
      final type = element.widget.runtimeType.toString();
      counts[type] = (counts[type] ?? 0) + 1;
    };
    addTearDown(() => debugOnRebuildDirtyWidget = null);
  }

  final _built = Set<Element>.identity();
  final _fresh = <String, int>{};
  final _again = <String, int>{};

  int fresh(String type) => _fresh[type] ?? 0;
  int again(String type) => _again[type] ?? 0;

  /// Category tiles and dish tiles built again, and category tiles and dish tiles made from nothing.
  (int, int) get tilesAgain => (again('_SectionButton'), again('_EntryButton'));
  (int, int) get tilesFresh => (fresh('_SectionButton'), fresh('_EntryButton'));

  void reset() {
    _fresh.clear();
    _again.clear();
  }
}

PosApi apiWith(Map<String, dynamic> Function() menu, {int Function()? revision}) => PosApi(
  Settings(device: 't1', endpoints: ['http://hub:8000']),
  client: MockClient((request) async {
    switch (request.url.path) {
      case '/menu':
        return http.Response.bytes(utf8.encode(jsonEncode({...menu(), 'revision': revision?.call() ?? 0})), 200);
      case '/menu/revision':
        return http.Response(jsonEncode({'revision': revision?.call() ?? 0}), 200);
      case '/menu/items/GTC':
        return http.Response.bytes(utf8.encode(jsonEncode(fixture('item_gtc'))), 200);
    }
    return http.Response('{}', 404);
  }),
);

void main() {
  testWidgets('while a tray opens or closes, no tile is built again', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final builds = Builds();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MenuPanel(api: apiWith(() => fixture('menu')), onChosen: (_) {}),
        ),
      ),
    );
    await tester.pumpAndSettle();

    /// Draws every frame of what `act` started. The tiles built again on the first frame, where the tap
    /// lands; [builds] then holds the whole of it.
    Future<(int, int)> frames(Future<void> Function() act) async {
      builds.reset();
      await act();
      await tester.pump();
      final first = builds.tilesAgain;
      var drawn = 0;
      while (tester.binding.hasScheduledFrame && drawn < 200) {
        await tester.pump(const Duration(milliseconds: 16));
        drawn++;
      }
      return first;
    }

    // Opening a category: its own tile changes (it is the open one now) on the frame of the tap, and the
    // other five are left alone. The four dishes are made as the tray shows them. On the frames that move
    // the tray, nothing else: no tile built again, none thrown away and made from nothing.
    var first = await frames(() => tester.tap(find.text('Appetizers')));
    expect(find.text('Egg roll'), findsOneWidget);
    expect(find.byType(TextField), findsNothing); // the search row folded away on the way
    expect(first, (1, 0));
    expect(builds.tilesAgain, (1, 0));
    expect(builds.tilesFresh, (0, 4));
    expect(builds.again('MenuPanel'), greaterThan(10)); // the tray did move, frame by frame

    // Another category: the tile that closes and the one that opens, and its four dishes.
    first = await frames(() => tester.tap(find.text('Sushi bar')));
    expect(find.text('Dragon roll'), findsOneWidget);
    expect(first, (2, 0));
    expect(builds.tilesAgain, (2, 0));
    expect(builds.tilesFresh, (0, 4));

    // A dish that asks its size opens the tray under the dishes: that dish's tile is marked, no other.
    await frames(() => tester.tap(find.text("Chef's Specials")));
    await frames(() async {
      await tester.tap(find.text("General Tso's Chicken"));
      await tester.pump(); // the dish's sizes and choices come back
    });
    expect(find.byKey(const ValueKey('required-selections')), findsOneWidget);
    expect(builds.tilesAgain, (0, 1));
    expect(builds.tilesFresh, (0, 0));
    expect(builds.again('MenuPanel'), greaterThan(10));
    // the two sizes it asks are buttons made once, not once a frame while their tray opens
    expect((builds.fresh('ChoiceTile'), builds.again('ChoiceTile')), (2, 0));

    // Closing it all: the category's tile is no longer the open one, and the search row comes back above
    // the categories without a single tile being thrown away and made from nothing.
    first = await frames(() => tester.tap(find.text("Chef's Specials")));
    expect(find.text("General Tso's Chicken"), findsNothing);
    expect(find.byType(TextField), findsOneWidget);
    expect(first, (1, 1)); // and the dish is no longer the one being asked about
    expect(builds.tilesAgain, (1, 1));
    expect(builds.tilesFresh, (0, 0));

    // What the search finds are tiles like the others: a tray opening under them builds only the one marked.
    await tester.enterText(find.byType(TextField), 'chicken');
    await tester.pumpAndSettle();
    expect(find.text('Chicken wings'), findsOneWidget);
    await frames(() async {
      await tester.tap(find.text("General Tso's Chicken"));
      await tester.pump();
    });
    expect(find.byKey(const ValueKey('required-selections')), findsOneWidget);
    expect(builds.tilesAgain, (0, 1));
    expect(builds.tilesFresh, (0, 0));
    expect(builds.again('MenuPanel'), greaterThan(10));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a dish added to the check builds its own tile again and no other', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final builds = Builds();
    final onCheck = <String, int>{}; // as the order screen counts them, from the check
    var redraws = 0;
    late StateSetter redraw;
    final api = apiWith(() => fixture('menu'));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              redraw = setState;
              redraws++;
              return MenuPanel(
                api: api,
                onChosen: (line) => setState(() => onCheck[line.itemId!] = (onCheck[line.itemId!] ?? 0) + line.qty),
                qtyOf: (entry) => onCheck[entry.item] ?? 0,
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Appetizers'));
    await tester.pumpAndSettle();

    builds.reset();
    await tester.tap(find.text('Egg roll'));
    await tester.pumpAndSettle();
    final badge = find.byKey(const ValueKey('entry-qty:dinner:1:EGGROLL'));
    expect(find.descendant(of: badge, matching: find.text('1×')), findsOneWidget);
    expect((builds.tilesAgain, builds.tilesFresh), ((0, 1), (0, 0)));

    builds.reset();
    await tester.tap(find.text('Egg roll'));
    await tester.tap(find.text('Spring roll'));
    await tester.pumpAndSettle();
    expect(find.descendant(of: badge, matching: find.text('2×')), findsOneWidget);
    expect(find.byKey(const ValueKey('entry-qty:dinner:2:SPRINGROLL')), findsOneWidget);
    expect((builds.tilesAgain, builds.tilesFresh), ((0, 2), (0, 0)));

    // The order screen draws again every time its check is read; with nothing new on it, no tile is touched.
    builds.reset();
    final before = redraws;
    redraw(() {});
    await tester.pumpAndSettle();
    expect(redraws, before + 1);
    expect((builds.tilesAgain, builds.tilesFresh), ((0, 0), (0, 0)));

    // A dish taken off the check elsewhere (the check panel, another terminal) loses its count here.
    redraw(() => onCheck.remove('SPRINGROLL'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('entry-qty:dinner:2:SPRINGROLL')), findsNothing);
    expect((builds.tilesAgain, builds.tilesFresh), ((0, 1), (0, 0)));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a saved menu reaches the tiles and the search results that were kept', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var revision = 3;
    Map<String, dynamic> menu() {
      final menu = fixture('menu');
      final apps = ((menu['menus'] as List)[0]['sections'] as List)[0] as Map;
      final first = (apps['entries'] as List)[0] as Map;
      if (revision > 3) {
        first['name'] = 'Egg roll (new recipe)';
        apps['name'] = 'Starters';
      }
      return menu;
    }

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MenuPanel(
            api: apiWith(menu, revision: () => revision),
            onChosen: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'egg');
    await tester.pumpAndSettle();
    expect(find.text('Egg roll'), findsOneWidget);

    revision = 4; // a manager saves
    await tester.pump(MenuPanelCheck.every);
    await tester.pumpAndSettle();
    expect(find.text('Egg roll (new recipe)'), findsOneWidget);
    expect(find.text('Egg roll'), findsNothing);

    await tester.tap(find.byTooltip('Clear'));
    await tester.pumpAndSettle();
    expect(find.text('Starters'), findsOneWidget);
    expect(find.text('Appetizers'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
