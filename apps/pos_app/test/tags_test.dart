import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/tags.dart';

void main() {
  final start = DateTime(2026, 11, 6, 18);

  test('a burst of keys ending in Enter is a tag; keys at a human pace are not', () {
    final bursts = BurstDetector();
    var at = start;
    String? out;
    for (final ch in '04a2b3c4'.split('')) {
      out = bursts.feed(character: ch, at: at);
      expect(out, isNull);
      at = at.add(const Duration(milliseconds: 8));
    }
    expect(bursts.feed(enter: true, at: at), '04A2B3C4', reason: 'upper-cased, as the hub keeps it');
    // Typed by hand: 150 ms between keys.
    at = at.add(const Duration(seconds: 1));
    for (final ch in '1234'.split('')) {
      expect(bursts.feed(character: ch, at: at), isNull);
      at = at.add(const Duration(milliseconds: 150));
    }
    expect(bursts.feed(enter: true, at: at), isNull);
    // Too short for a tag, or Enter too late after the burst.
    at = at.add(const Duration(seconds: 1));
    for (final ch in 'ab'.split('')) {
      bursts.feed(character: ch, at: at);
      at = at.add(const Duration(milliseconds: 5));
    }
    expect(bursts.feed(enter: true, at: at), isNull);
    at = at.add(const Duration(seconds: 1));
    for (final ch in 'abcdef'.split('')) {
      bursts.feed(character: ch, at: at);
      at = at.add(const Duration(milliseconds: 5));
    }
    expect(bursts.feed(enter: true, at: at.add(const Duration(milliseconds: 500))), isNull);
    // A reader that types the id in groups: the separators are dropped; another key breaks the burst.
    at = at.add(const Duration(seconds: 2));
    for (final ch in '04 A2:B3-C4'.split('')) {
      bursts.feed(character: ch, at: at);
      at = at.add(const Duration(milliseconds: 5));
    }
    expect(bursts.feed(enter: true, at: at), '04A2B3C4');
    at = at.add(const Duration(seconds: 2));
    for (final ch in '04A2!B3C'.split('')) {
      bursts.feed(character: ch, at: at);
      at = at.add(const Duration(milliseconds: 5));
    }
    expect(bursts.feed(enter: true, at: at), null, reason: 'the burst starts over at the stray key: B3C is too short');
  });

  test('the reader on the keyboard hands tags to the sign-in, or to the enrollment waiting for one', () async {
    final read = <String>[];
    var now = start;
    final reader = WedgeTagReader(onTag: read.add, clock: () => now);
    KeyEvent key(LogicalKeyboardKey logical, String? character) => KeyDownEvent(
      physicalKey: PhysicalKeyboardKey.keyA,
      logicalKey: logical,
      character: character,
      timeStamp: Duration.zero,
    );
    void type(String text) {
      for (final ch in text.split('')) {
        expect(reader.handle(key(LogicalKeyboardKey.keyA, ch)), isFalse, reason: 'never swallowed');
        now = now.add(const Duration(milliseconds: 5));
      }
      reader.handle(key(LogicalKeyboardKey.enter, null));
      now = now.add(const Duration(seconds: 1));
    }

    type('04a2b3c4');
    expect(read, ['04A2B3C4']);
    expect(
      reader.handle(
        KeyUpEvent(
          physicalKey: PhysicalKeyboardKey.enter,
          logicalKey: LogicalKeyboardKey.enter,
          timeStamp: Duration.zero,
        ),
      ),
      isFalse,
    );
    // An enrollment asks for the next tag: it goes there, not to the sign-in.
    final next = reader.next(timeout: const Duration(seconds: 5));
    type('11112222');
    expect(await next, '11112222');
    expect(read, ['04A2B3C4']);
    type('33334444');
    expect(read, ['04A2B3C4', '33334444'], reason: 'the one after goes to the sign-in again');
    // Cancelled: null, and the tag that then comes signs in.
    final cancelled = reader.next(timeout: const Duration(seconds: 5));
    reader.cancel();
    expect(await cancelled, isNull);
    type('55556666');
    expect(read.last, '55556666');
    // A timeout gives null.
    expect(await reader.next(timeout: const Duration(milliseconds: 10)), isNull);
  });
}
