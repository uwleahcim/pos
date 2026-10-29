import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pos_app/camera.dart';

void main() {
  // An 8x6 BGRA frame with 4 bytes of row padding: left half red, right half blue.
  FramePixels frame(int rotation) {
    const w = 8, h = 6, stride = w * 4 + 4;
    final bytes = Uint8List(stride * h);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final i = y * stride + x * 4;
        bytes[i] = x < 4 ? 0 : 255; // B
        bytes[i + 1] = 0; // G
        bytes[i + 2] = x < 4 ? 255 : 0; // R
        bytes[i + 3] = 255;
      }
    }
    return FramePixels(w, h, stride, bytes, rotation);
  }

  test('a BGRA frame becomes a JPEG with the colours in place', () {
    final jpeg = encodeFrame(frame(0));
    final decoded = img.decodeJpg(jpeg)!;
    expect((decoded.width, decoded.height), (8, 6));
    final left = decoded.getPixel(1, 3);
    final right = decoded.getPixel(6, 3);
    expect(left.r > 200 && left.b < 60, isTrue, reason: 'left is red: $left');
    expect(right.b > 200 && right.r < 60, isTrue, reason: 'right is blue: $right');
  });

  test('rotation turns the frame upright', () {
    final decoded = img.decodeJpg(encodeFrame(frame(90)))!;
    expect((decoded.width, decoded.height), (6, 8));
  });

  test('big frames shrink to 320 px', () {
    const w = 640, h = 480, stride = w * 4;
    final decoded = img.decodeJpg(encodeFrame(FramePixels(w, h, stride, Uint8List(stride * h), 0)))!;
    expect((decoded.width, decoded.height), (320, 240));
  });

  test("an Android picture is turned upright by its EXIF and shrunk to 320 px", () {
    final photo = img.Image(width: 640, height: 480)..exif.imageIfd.orientation = 6; // taken sideways
    final decoded = img.decodeJpg(shrinkJpeg(img.encodeJpg(photo)))!;
    expect((decoded.width, decoded.height), (240, 320));
  });
}
