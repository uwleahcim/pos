import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/camera.dart';
import 'package:pos_app/faces.dart';
import 'package:pos_app/screens/face_enroll_dialog.dart';
import 'package:pos_app/screens/location_settings_screen.dart';
import 'package:pos_app/tags.dart';

import 'hub.dart';

class FrameCamera extends EventCamera {
  int frames = 0;
  @override
  bool get ready => true;
  @override
  String? get error => null;
  @override
  Widget preview() => const SizedBox();
  @override
  Future<Uint8List?> snap() async => Uint8List.fromList([0xff, 0xd8, 1]);
  @override
  Future<Uint8List?> frame({int maxSide = 480}) async {
    frames += 1;
    return Uint8List.fromList([0xff, 0xd8, 2]);
  }
}

/// A reader whose next tag the test provides.
class FakeTagReader implements TagReader {
  Completer<String?>? waiting;

  @override
  Future<String?> next({Duration timeout = const Duration(seconds: 30)}) {
    final c = waiting = Completer<String?>();
    return c.future;
  }

  @override
  void cancel() {
    final c = waiting;
    waiting = null;
    if (c != null && !c.isCompleted) c.complete(null);
  }

  void read(String uid) {
    final c = waiting;
    waiting = null;
    c?.complete(uid);
  }
}

Map<String, dynamic> person(String id, String name, String role, {int samples = 0, int stale = 0}) => {
  'staff_id': id,
  'name': name,
  'role': role,
  'face': {'samples': samples, 'updated_at': samples > 0 ? 1762000000.0 : 0.0, 'stale': stale},
  'tag': {'enrolled': false, 'ends': null, 'updated_at': 0.0},
};

Map<String, dynamic> step({bool accepted = true, String? reason, required int samples, String? looksLike}) => {
  'accepted': accepted,
  'reason': reason,
  'samples': samples,
  'wanted': 5,
  'done': samples >= 5,
  'looks_like': looksLike,
};

Future<Terminal> pumpLocation(WidgetTester tester, {EventCamera? camera, TagReader? tags}) async {
  final t = await terminal(tester);
  t.hub.faceStatus = {'enabled': false, 'ready': true, 'active': false, 'enrolled': 1, 'model': 'r50', 'error': null};
  t.hub.staffList = [person('s1', 'Amy', 'server', samples: 5), person('s2', 'Ben', 'bartender')];
  tester.view.physicalSize = const Size(1100, 2900); // the whole list on one tall screen, nothing to scroll
  await tester.pumpWidget(
    MaterialApp(
      home: LocationSettingsScreen(
        api: t.api,
        token: 'tok-admin',
        device: 't1',
        camera: camera ?? FrameCamera(),
        tags: tags,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return t;
}

String hint(WidgetTester tester) => tester.widget<Text>(find.byKey(const ValueKey('enroll-hint'))).data!;

void main() {
  testWidgets('the card lists the staff with their enrollment, the switch and the forget button', (tester) async {
    final t = await pumpLocation(tester);
    expect(find.text('Sign in by face'), findsOneWidget);
    expect(find.text('Hub ready · 1 enrolled · switched off: no screen looks until the switch is on'), findsOneWidget);
    expect(find.text('Server · Enrolled, 5 views on 11/1'), findsOneWidget);
    expect(find.text('Bartender · Not enrolled: signs in by PIN'), findsOneWidget);
    expect(find.text('Enroll again'), findsOneWidget);
    expect(find.text('Enroll'), findsOneWidget);
    expect(find.byKey(const ValueKey('forget:s1')), findsOneWidget);
    expect(find.byKey(const ValueKey('forget:s2')), findsNothing);
    expect(t.hub.faceAuth, 'Bearer tok-admin');

    await tester.tap(find.byKey(const ValueKey('faces-enabled')));
    await tester.pumpAndSettle();
    expect(t.hub.facesSetting, {'enabled': true});
    expect(tester.widget<SwitchListTile>(find.byKey(const ValueKey('faces-enabled'))).value, isTrue);

    await tester.tap(find.byKey(const ValueKey('forget:s1')));
    await tester.pumpAndSettle();
    expect(t.hub.forgotten, ['s1']);
    expect(find.text('Amy signs in by PIN now'), findsOneWidget);
    expect(find.text('Server · Not enrolled: signs in by PIN'), findsOneWidget);
    expect(find.byKey(const ValueKey('forget:s1')), findsNothing);
  });

  testWidgets('enrolling takes views until the hub has five, with a hint for each refused one', (tester) async {
    final t = await pumpLocation(tester);
    t.hub.enrollAnswers = [
      step(accepted: false, reason: 'no_face', samples: 0),
      step(samples: 1),
      step(accepted: false, reason: 'same_view', samples: 1),
      step(accepted: false, reason: 'looks_like', samples: 1, looksLike: 'Amy'),
      step(samples: 2),
      step(samples: 3),
      step(samples: 4),
      step(samples: 5),
    ];
    await tester.tap(find.byKey(const ValueKey('enroll:s2')));
    await tester.pump();
    expect(find.text('Enroll Ben'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 10)); // the first view goes at once
    expect(hint(tester), 'Ask Ben to look at the camera');
    expect(t.hub.enrolled.first, ('s2', true), reason: 'the first view starts a fresh enrollment');
    await tester.pump(const Duration(milliseconds: 650));
    expect(hint(tester), 'Good. Now turn the head a little');
    expect(t.hub.enrolled.last, ('s2', false));
    await tester.pump(const Duration(milliseconds: 650));
    expect(hint(tester), 'Turn the head a little: to a side, up, down');
    await tester.pump(const Duration(milliseconds: 650));
    expect(hint(tester), 'This looks like Amy. Is Ben the one at the camera?');
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 650));
    }
    expect(hint(tester), 'Enrolled: Ben can sign in by face now');
    expect(find.text('Ben enrolled'), findsOneWidget);
    expect(find.text('5 of 5 views'), findsOneWidget);
    final posted = t.hub.enrolled.length;
    await tester.pump(const Duration(seconds: 2));
    expect(t.hub.enrolled.length, posted, reason: 'done: no more views');
    await tester.tap(find.byKey(const ValueKey('enroll-done')));
    await tester.pumpAndSettle();
    expect(find.text('Ben: 5 views enrolled'), findsOneWidget);
    expect(find.text('Bartender · Enrolled, 5 views on 10/27'), findsOneWidget);
    expect(find.byKey(const ValueKey('forget:s2')), findsOneWidget);
  });

  testWidgets('stopping early keeps what was enrolled so far', (tester) async {
    final t = await pumpLocation(tester);
    await tester.tap(find.byKey(const ValueKey('enroll:s2')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('2 of 5 views'), findsOneWidget);
    expect(find.text('Stop here'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('enroll-cancel')));
    await tester.pumpAndSettle();
    expect(find.text('Ben: 2 views enrolled'), findsOneWidget);
    expect(t.hub.enrolled.length, 2);
  });

  testWidgets('the hands-free card saves the switch and the away time', (tester) async {
    final t = await pumpLocation(tester);
    expect(find.text('Switch to whoever steps up'), findsOneWidget);
    expect(tester.widget<SwitchListTile>(find.byKey(const ValueKey('hands-free-switch'))).value, isTrue);
    await tester.tap(find.byKey(const ValueKey('hands-free-switch')));
    await tester.pumpAndSettle();
    expect(t.hub.handsFree, {'switch': false, 'away_seconds': 60});
    expect(t.hub.faceAuth, 'Bearer tok-admin');
    expect(tester.widget<SwitchListTile>(find.byKey(const ValueKey('hands-free-switch'))).value, isFalse);
    await tester.tap(find.byKey(const ValueKey('hands-free-away')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('5 minutes').last);
    await tester.pumpAndSettle();
    expect(t.hub.handsFree, {'switch': false, 'away_seconds': 300});
  });

  testWidgets('a tag held to the reader is given to the person; one that is someone else\'s is refused', (
    tester,
  ) async {
    final reader = FakeTagReader();
    final t = await pumpLocation(tester, tags: reader);
    expect(find.byKey(const ValueKey('forget-tag:s2')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('tag:s2')));
    await tester.pumpAndSettle();
    expect(find.text('A tag for Ben'), findsOneWidget);
    expect(find.text('Hold the tag to this screen\'s reader now.'), findsOneWidget);
    reader.read('04A2B3C4D5E6F7');
    await tester.pumpAndSettle();
    expect(t.hub.tagged, [('s2', '04A2B3C4D5E6F7')]);
    expect(find.text('A tag for Ben'), findsNothing, reason: 'kept: the dialog closes');
    expect(find.text('Ben: tag …E6F7 kept'), findsOneWidget);
    expect(find.text('Bartender · Not enrolled: signs in by tag or PIN · tag …E6F7'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5)); // the word about it goes
    await tester.pumpAndSettle();
    // Someone else's tag.
    t.hub.tagTakenBy = 'Amy';
    await tester.tap(find.byKey(const ValueKey('tag:s2')));
    await tester.pumpAndSettle();
    reader.read('99999999');
    await tester.pumpAndSettle();
    expect(find.text('That tag is Amy\'s'), findsOneWidget);
    expect(find.text('A tag for Ben'), findsOneWidget, reason: 'the dialog stays for another tag');
    await tester.tap(find.byKey(const ValueKey('tag-cancel')));
    await tester.pumpAndSettle();
    expect(find.text('A tag for Ben'), findsNothing);
    // The bin forgets the tag.
    await tester.tap(find.byKey(const ValueKey('forget-tag:s2')));
    await tester.pumpAndSettle();
    expect(t.hub.tagsForgotten, ['s2']);
    expect(find.text('Ben\'s tag forgotten'), findsOneWidget);
    expect(find.byKey(const ValueKey('forget-tag:s2')), findsNothing);
  });

  testWidgets('without a reader, the tag\'s id is typed', (tester) async {
    final t = await pumpLocation(tester);
    await tester.tap(find.byKey(const ValueKey('tag:s1')));
    await tester.pumpAndSettle();
    expect(find.textContaining('This screen has no reader'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('tag-save'))).onPressed, isNull);
    await tester.enterText(find.byKey(const ValueKey('tag-typed')), '04:a2:b3:c4');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('tag-save')));
    await tester.pumpAndSettle();
    expect(t.hub.tagged, [('s1', '04:A2:B3:C4')], reason: 'as typed; the hub tidies it');
    expect(find.text('Amy: tag …B3C4 kept'), findsOneWidget);
  });

  testWidgets('a screen without a camera cannot enroll', (tester) async {
    await pumpLocation(tester, camera: NoCamera());
    expect(tester.widget<TextButton>(find.byKey(const ValueKey('enroll:s2'))).onPressed, isNull);
    expect(find.textContaining('This screen has no camera'), findsOneWidget);
  });

  testWidgets('an older hub without face sign-in says so', (tester) async {
    final t = await terminal(tester);
    t.hub.faces = false;
    tester.view.physicalSize = const Size(1100, 2200); // tall enough for the cards above the face card
    await tester.pumpWidget(
      MaterialApp(
        home: LocationSettingsScreen(api: t.api, token: 'tok-admin', device: 't1', camera: FrameCamera()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('The hub has not answered about face sign-in'), findsOneWidget);
    expect(tester.widget<SwitchListTile>(find.byKey(const ValueKey('faces-enabled'))).onChanged, isNull);
  });

  testWidgets('the dialog on its own: a hub error is shown and the views go on', (tester) async {
    final t = await terminal(tester);
    final camera = FrameCamera();
    await tester.pumpWidget(
      MaterialApp(
        home: FaceEnrollDialog(
          api: t.api,
          token: 'tok-admin',
          staff: const StaffEntryFixture().ben,
          camera: camera,
          device: 't1',
          interval: const Duration(milliseconds: 100),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 10));
    expect(find.text('1 of 5 views'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('2 of 5 views'), findsOneWidget);
    expect(camera.frames, 2);
  });
}

/// The staff entries the dialog test needs without the whole screen.
class StaffEntryFixture {
  const StaffEntryFixture();
  StaffEntry get ben => const StaffEntry(staffId: 's2', name: 'Ben', role: 'bartender');
}
