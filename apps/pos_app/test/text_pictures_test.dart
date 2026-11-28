import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pos_app/text_pictures.dart';
import 'package:pos_app/texts.dart';

import 'hub.dart';
import 'texts_test.dart' show dot, key, lee, pat, pumpTexts, tapKey, twoConversations;

/// Pictures in the staff's texts (docs/text-inbox.md, "Instant delivery and pictures"): the button beside
/// the box, what was chosen shown small until the text goes, and what the hub is handed. A picture is made
/// to fit a text on the device; the hub keeps it and tells Twilio where to fetch it.

/// A hub Twilio can fetch pictures from.
void picturesOn(Hub hub) {
  twoConversations(hub);
  hub.textSend = {'pictures': true, 'most': 5, 'bytes': 4500000};
}

/// What the person at the screen chooses, one answer for each time the device's photos are opened, and
/// where each asking said the pictures should come from and how many may.
class Chooser {
  Chooser(this.answers);

  final List<List<Uint8List?>> answers;
  final asked = <(PictureFrom, int)>[];

  Future<List<Uint8List?>> call(PictureFrom from, int most) async {
    asked.add((from, most));
    return answers.removeAt(0);
  }
}

/// A picture that is its own: the dot, with a byte after its end that says which.
Uint8List picture(int n) => Uint8List.fromList([...dot, n]);

/// Opens the conversation with Lee and chooses pictures from the photos.
Future<void> choose(WidgetTester tester, {String from = 'library'}) async {
  await tapKey(tester, 'text-attach');
  await tapKey(tester, 'text-attach-$from');
}

void main() {
  group('a picture is made to fit a text', () {
    test('a large one becomes a JPEG no wider than a text carries, turned the way it was taken', () {
      final large = img.Image(width: 3000, height: 2000)..clear(img.ColorRgb8(200, 30, 30));
      final fitted = fitForText(img.encodePng(large))!;
      final read = img.decodeJpg(fitted)!;
      expect((read.width, read.height), (1600, 1067));
      expect(fitted.length, lessThanOrEqualTo(textPictureBytes));
      final tall = img.Image(width: 900, height: 2400)..clear(img.ColorRgb8(30, 30, 200));
      final upright = img.decodeJpg(fitForText(img.encodeJpg(tall))!)!;
      expect((upright.width, upright.height), (600, 1600));
    });

    test('a small one keeps its size, and what was see-through becomes white', () {
      final clear = img.Image(width: 40, height: 30, numChannels: 4); // every dot clear
      final read = img.decodeJpg(fitForText(img.encodePng(clear))!)!;
      expect((read.width, read.height), (40, 30));
      final middle = read.getPixel(20, 15);
      expect([middle.r, middle.g, middle.b], everyElement(greaterThan(240)));
    });

    test('a small GIF goes as it is, and what is no picture does not go', () {
      final gif = img.encodeGif(img.Image(width: 8, height: 8));
      expect(fitForText(gif), same(gif));
      expect(fitForText(Uint8List.fromList(utf8.encode('%PDF-1.7 not a picture at all'))), isNull);
      expect(fitForText(Uint8List(0)), isNull);
    });
  });

  group('the words', () {
    test('what the hub says a text can carry is read, and a hub that says nothing carries no picture', () {
      const before = TextSends();
      expect((before.known, before.pictures), (false, false));
      final said = TextSends.fromJson({'pictures': true, 'most': 3, 'bytes': 1000});
      expect((said.known, said.pictures, said.most, said.bytes), (true, true, 3, 1000));
      final page = TextPage.fromJson({
        'thread': {'phone': pat},
        'send': {'pictures': true, 'most': 5, 'bytes': 4500000},
      });
      expect(page.sends.pictures, isTrue);
      expect(page.withTexts(const []).sends.pictures, isTrue, reason: 'kept when the texts change');
    });

    test('a first text that is only a picture still says who it is from', () {
      const page = TextPage(
        thread: TextThread(phone: pat),
        before: 'China Sky: ',
        after: '\nReply STOP to opt out.',
      );
      expect(wrapped(page, '', pictures: true), 'China Sky\nReply STOP to opt out.');
      expect(wrapped(page, 'Here it is', pictures: true), 'China Sky: Here it is\nReply STOP to opt out.');
      const begun = TextPage(thread: TextThread(phone: pat));
      expect(wrapped(begun, '', pictures: true), '');
    });
  });

  group('the picture button', () {
    testWidgets('is not there on a hub from before pictures in a text', (tester) async {
      final chooser = Chooser([]);
      await pumpTexts(
        tester,
        pick: chooser.call,
        hub: (hub) {
          twoConversations(hub);
          hub.textSend = null;
        },
      );
      await tapKey(tester, 'text-thread:$lee');
      expect(key('text-box'), findsOneWidget);
      expect(key('text-attach'), findsNothing);
      await stop(tester);
    });

    testWidgets('says why on a hub Twilio cannot fetch a picture from yet, and opens nothing', (tester) async {
      final chooser = Chooser([]);
      await pumpTexts(tester, pick: chooser.call);
      await tapKey(tester, 'text-thread:$lee');
      await tapKey(tester, 'text-attach');
      expect(
        find.descendant(
          of: key('text-pick-said'),
          matching: find.textContaining('Location › Keys and connections, Texts to customers'),
        ),
        findsOneWidget,
      );
      expect(key('text-attach-library'), findsNothing);
      expect(chooser.asked, isEmpty);
      // said over the box, not on a bar across it: the box and Send stay in reach, and it can be put away
      expect(tester.getRect(key('text-pick-said')).bottom, lessThanOrEqualTo(tester.getRect(key('text-box')).top));
      await tapKey(tester, 'text-pick-said-off');
      expect(key('text-pick-said'), findsNothing);
      await stop(tester);
    });

    testWidgets('pictures chosen show small by the box, one comes off, and the text goes with the rest', (
      tester,
    ) async {
      final chooser = Chooser([
        [picture(1), picture(2)],
      ]);
      final (t, _) = await pumpTexts(tester, pick: chooser.call, hub: picturesOn);
      await tapKey(tester, 'text-thread:$lee');
      expect(tester.widget<IconButton>(key('text-send')).onPressed, isNull);
      await choose(tester);
      expect(chooser.asked, [(PictureFrom.library, 5)]);
      expect(key('text-picked:0'), findsOneWidget);
      expect(key('text-picked:1'), findsOneWidget);
      expect(tester.widget<IconButton>(key('text-send')).onPressed, isNotNull, reason: 'a picture needs no words');
      expect(key('text-goes-as'), findsNothing, reason: 'the conversation has begun');
      await tapKey(tester, 'text-picked-off:0');
      expect(key('text-picked:1'), findsNothing);
      await tapKey(tester, 'text-send');
      final (to, sent) = t.hub.textPosts.single;
      expect((to, sent['body']), (lee, ''));
      expect(sent['pictures'], [base64Encode(picture(2))]);
      expect(key('text-picked'), findsNothing, reason: 'they went with the text');
      // the text shows at once with its picture, which is not fetched back from the hub
      final id = sent['id'] as String;
      expect(find.descendant(of: key('text-picture:$id/0'), matching: find.byType(Image)), findsOneWidget);
      expect(t.hub.requests.where((r) => r.startsWith('GET /texts/picture/$id')), isEmpty);
      expect(find.textContaining('You: A picture'), findsOneWidget); // its line of the list
      await stop(tester);
    });

    testWidgets('words and pictures go together', (tester) async {
      final chooser = Chooser([
        [picture(1)],
      ]);
      final (t, _) = await pumpTexts(tester, pick: chooser.call, hub: picturesOn);
      await tapKey(tester, 'text-thread:$lee');
      await choose(tester);
      await tester.enterText(key('text-box'), 'This is the round table by the window.');
      await tester.pumpAndSettle();
      await tapKey(tester, 'text-send');
      final (_, sent) = t.hub.textPosts.single;
      expect(sent['body'], 'This is the round table by the window.');
      expect((sent['pictures'] as List).length, 1);
      expect(find.text('This is the round table by the window.'), findsOneWidget);
      expect(tester.widget<TextField>(key('text-box')).controller!.text, isEmpty);
      await stop(tester);
    });

    testWidgets('a phone or a tablet may take the photo; a Mac chooses a file and is not asked which', (tester) async {
      final chooser = Chooser([
        [picture(1)],
        [picture(2)],
      ]);
      await pumpTexts(tester, pick: chooser.call, hub: picturesOn);
      await tapKey(tester, 'text-thread:$lee');
      await choose(tester, from: 'camera');
      expect(chooser.asked, [(PictureFrom.camera, 5)]);
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      try {
        await tapKey(tester, 'text-attach');
        expect(key('text-attach-library'), findsNothing);
        expect(chooser.asked.last, (PictureFrom.library, 4), reason: 'there is room for four more');
        expect(key('text-picked:1'), findsOneWidget);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
      await stop(tester);
    });

    testWidgets('a text carries five at the most: what is over is left out, and it is said', (tester) async {
      final chooser = Chooser([
        [for (var n = 0; n < 4; n++) picture(n)],
        [picture(4), picture(5)],
      ]);
      await pumpTexts(tester, pick: chooser.call, hub: picturesOn);
      await tapKey(tester, 'text-thread:$lee');
      await choose(tester);
      await choose(tester);
      expect(chooser.asked.last, (PictureFrom.library, 1));
      expect(key('text-picked:4'), findsOneWidget);
      expect(key('text-picked:5'), findsNothing);
      expect(find.text('A text carries 5 pictures at the most: the others were left out.'), findsOneWidget);
      await tapKey(tester, 'text-attach');
      expect(find.text('A text carries 5 pictures at the most.'), findsOneWidget);
      expect(chooser.asked.length, 2, reason: "the device's photos are not opened for a sixth");
      await stop(tester);
    });

    testWidgets('what is no picture is left out and said, and a device that will not open its photos too', (
      tester,
    ) async {
      final chooser = Chooser([
        [null],
        [picture(1), null, null],
      ]);
      await pumpTexts(tester, pick: chooser.call, hub: picturesOn);
      await tapKey(tester, 'text-thread:$lee');
      await choose(tester);
      expect(find.text('That is not a picture a text can carry. A photo, a JPEG or a PNG goes.'), findsOneWidget);
      expect(key('text-picked'), findsNothing);
      await choose(tester);
      expect(find.text('2 were left out: not a picture a text can carry.'), findsOneWidget);
      expect(key('text-picked:0'), findsOneWidget);
      await choose(tester); // the chooser has no answer left: it throws, as a device that says no does
      expect(find.text('The pictures could not be opened on this device.'), findsOneWidget);
      expect(key('text-picked:0'), findsOneWidget, reason: 'what was chosen before stays');
      expect(tester.widget<IconButton>(key('text-attach')).onPressed, isNotNull);
      await stop(tester);
    });

    testWidgets('a hub that will not take the pictures says why, and they stay by the box', (tester) async {
      final chooser = Chooser([
        [picture(1), picture(2)],
      ]);
      final (t, _) = await pumpTexts(tester, pick: chooser.call, hub: picturesOn);
      await tapKey(tester, 'text-thread:$lee');
      await choose(tester);
      t.hub.refuseText = (422, 'too_big', 'Those pictures are too big together for one text.');
      await tapKey(tester, 'text-send');
      expect(
        find.text('Those pictures are too big together for one text. Take one off and send it again.'),
        findsOneWidget,
      );
      expect(key('text-picked:1'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5)); // the bar that said so goes
      await tester.pumpAndSettle();
      t.hub.refuseText = (409, 'no_way', "A picture needs the hub's way in from the internet.");
      await tapKey(tester, 'text-send');
      expect(find.textContaining('A picture cannot go yet'), findsOneWidget);
      expect(key('text-picked:1'), findsOneWidget);
      await stop(tester);
    });

    testWidgets('the first text to a number, with only a picture, shows what it goes as', (tester) async {
      final chooser = Chooser([
        [picture(1)],
      ]);
      final (t, _) = await pumpTexts(tester, pick: chooser.call, hub: picturesOn);
      await tapKey(tester, 'text-new');
      await tester.enterText(key('text-new-number'), '781 555 0199');
      await tester.pumpAndSettle();
      await tapKey(tester, 'text-new-open');
      await choose(tester);
      expect(tester.widget<Text>(key('text-goes-as')).data, endsWith('It goes as:\nChina Sky\nReply STOP to opt out.'));
      await tapKey(tester, 'text-send');
      expect(t.hub.textPosts.single.$2['body'], '');
      expect(find.text('China Sky\nReply STOP to opt out.'), findsOneWidget);
      await stop(tester);
    });

    testWidgets('pictures chosen for one customer do not follow to another', (tester) async {
      final chooser = Chooser([
        [picture(1)],
      ]);
      await pumpTexts(tester, pick: chooser.call, hub: picturesOn);
      await tapKey(tester, 'text-thread:$lee');
      await choose(tester);
      expect(key('text-picked:0'), findsOneWidget);
      await tapKey(tester, 'text-thread:$pat');
      expect(key('text-picked'), findsNothing);
      expect(tester.widget<IconButton>(key('text-send')).onPressed, isNull);
      await stop(tester);
    });

    testWidgets('on a phone five pictures and a long text fit: the pictures slide, nothing is cut', (tester) async {
      final chooser = Chooser([
        [for (var n = 0; n < 5; n++) picture(n)],
      ]);
      await pumpTexts(tester, pick: chooser.call, hub: picturesOn, size: const Size(320, 640));
      await tapKey(tester, 'text-thread:$lee');
      await choose(tester);
      await tester.enterText(key('text-box'), 'These are the five party platters we talked about on the phone.');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(key('text-picked:0'), findsOneWidget);
      final box = tester.getRect(key('text-box')), add = tester.getRect(key('text-attach'));
      expect(add.right, lessThanOrEqualTo(box.left));
      expect(tester.getRect(key('text-send')).right, lessThanOrEqualTo(320));
      await tester.drag(key('text-picked'), const Offset(-200, 0));
      await tester.pumpAndSettle();
      expect(key('text-picked:4'), findsOneWidget);
      await stop(tester);
    });
  });
}
