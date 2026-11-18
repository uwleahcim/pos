import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/frames.dart';
import 'package:pos_app/screens/settings_screen.dart';
import 'package:pos_app/settings.dart';

const ms = Duration(milliseconds: 1);

void main() {
  test('frames are counted, and the ones that took longer than a sixtieth of a second are kept', () {
    var clock = DateTime(2026, 11, 12, 19, 15, 2);
    final frames = FrameWatch(now: () => clock);
    var heard = 0;
    frames.addListener(() => heard++);

    // a second of smooth drawing: counted, and nobody is told (a screen showing the count must not draw a
    // frame for every batch of frames, its own among them)
    frames.add([for (var i = 0; i < 60; i++) FrameWatch.timing(build: ms * 4, paint: ms * 6)]);
    expect((frames.frames, frames.late, frames.worst), (60, 0, ms * 6));
    expect(frames.latest, isEmpty);
    expect(heard, 0);

    // one frame whose building took too long, one whose painting did; exactly the budget is still in time
    frames.add([
      FrameWatch.timing(build: ms * 41, paint: ms * 6),
      FrameWatch.timing(build: FrameWatch.budget, paint: ms * 2),
    ]);
    clock = clock.add(const Duration(seconds: 3));
    frames.add([FrameWatch.timing(build: ms * 3, paint: ms * 25)]);
    expect((frames.frames, frames.late, frames.worst), (63, 2, ms * 41));
    expect(frames.latest.map((f) => (f.at.second, f.build, f.paint)), [(5, ms * 3, ms * 25), (2, ms * 41, ms * 6)]);
    expect(heard, 2);

    // only the latest are kept, newest first
    frames.add([for (var i = 0; i < 30; i++) FrameWatch.timing(build: ms * (20 + i), paint: ms)]);
    expect(frames.late, 32);
    expect(frames.latest, hasLength(FrameWatch.keep));
    expect(frames.latest.first.build, ms * 49);

    clock = clock.add(const Duration(minutes: 1));
    frames.reset();
    expect((frames.frames, frames.late, frames.worst, frames.latest.length), (0, 0, Duration.zero, 0));
    expect(frames.since, clock);
  });

  testWidgets('Settings says how smoothly the device draws, and starts the count over', (tester) async {
    // tall enough for every card of the settings screen above this one (the list builds only what shows)
    await tester.binding.setSurfaceSize(const Size(800, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var clock = DateTime(2026, 11, 12, 18, 2);
    final frames = FrameWatch(now: () => clock);
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          settings: Settings(device: 'mac1', endpoints: const ['http://hub1:8000']),
          frames: frames,
        ),
      ),
    );
    String line() => tester.widget<Text>(find.byKey(const ValueKey('smoothness-line'))).data!;
    expect(line(), 'No frames counted since 18:02');

    frames.add([for (var i = 0; i < 4200; i++) FrameWatch.timing(build: ms * 4, paint: ms * 6)]);
    clock = DateTime(2026, 11, 12, 19, 15, 2);
    frames.add([FrameWatch.timing(build: ms * 41, paint: const Duration(microseconds: 6400))]);
    await tester.pump();
    expect(line(), '4,201 frames since 18:02, 1 late (1 in 4,201). The slowest took 41 ms.');
    expect(find.text('19:15:02  41 ms building the screen, 6.4 ms painting it'), findsOneWidget);

    clock = DateTime(2026, 11, 12, 19, 20);
    await tester.tap(find.byKey(const ValueKey('smoothness-reset')));
    await tester.pump();
    expect(line(), 'No frames counted since 19:20');
    expect(find.byKey(const ValueKey('late-frame:0')), findsNothing);

    frames.add([for (var i = 0; i < 120; i++) FrameWatch.timing(build: ms * 4, paint: ms * 6)]);
    await tester.tap(find.byKey(const ValueKey('smoothness-reset'))); // any redraw shows the count as it stands
    frames.add([FrameWatch.timing(build: ms * 4, paint: ms * 6)]);
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          settings: Settings(device: 'mac1', endpoints: const ['http://hub1:8000']),
          frames: frames,
        ),
      ),
    );
    expect(line(), '1 frame since 19:20, none late. The slowest took 6.0 ms.');

    // a terminal being set up for the first time has nothing to say about it yet
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          settings: Settings(device: 'mac1', endpoints: const ['http://hub1:8000']),
          firstRun: true,
          frames: frames,
        ),
      ),
    );
    expect(find.text('Smoothness'), findsNothing);
  });
}
