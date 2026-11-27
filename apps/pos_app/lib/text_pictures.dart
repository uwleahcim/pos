/// Pictures the staff put in a text to a customer (docs/text-inbox.md, "Instant delivery and pictures").
///
/// A picture is chosen from the device's photos (a file on a Mac) or taken with its camera, and made to fit
/// a text before it leaves the device: a phone's photo is ten times what a phone company carries. What
/// goes to the hub is a JPEG no wider or taller than [textPictureSide] and no heavier than
/// [textPictureBytes], so five of them stay under what the hub takes for one text.
library;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

/// Where a picture for a text comes from.
enum PictureFrom { library, camera }

/// Asks the person at the screen for pictures, at the most [most] of them (one more may come back, so the
/// screen can say that some were left out). Each comes back fitted for a text; null stands for one that
/// could not be read as a picture. Nothing when they chose none. A device that will not open its photos or
/// its camera throws.
typedef PicturePick = Future<List<Uint8List?>> Function(PictureFrom from, int most);

/// The widest or tallest a picture goes in a text, in pixels: plenty for a dish, a receipt or a storefront.
const textPictureSide = 1600;

/// The most one picture weighs once it is fitted, in bytes.
const textPictureBytes = 900000;

/// Whether this device takes a photo for a text: a phone or a tablet does. A Mac chooses a file.
bool get takesPhotos =>
    !kIsWeb && (defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.android);

/// The device's own way of choosing pictures ([PicturePick]).
Future<List<Uint8List?>> pickPictures(PictureFrom from, int most) async {
  final picker = ImagePicker();
  final side = textPictureSide.toDouble();
  final List<XFile> files;
  if (from == PictureFrom.camera) {
    final taken = await picker.pickImage(
      source: ImageSource.camera,
      maxWidth: side,
      maxHeight: side,
      imageQuality: 85,
      requestFullMetadata: false,
    );
    files = [?taken];
  } else {
    files = await picker.pickMultiImage(
      maxWidth: side,
      maxHeight: side,
      imageQuality: 85,
      limit: most < 1 ? 1 : most,
      requestFullMetadata: false,
    );
  }
  final fitted = <Uint8List?>[];
  // not every device holds the choosing to `most`: one more than fits tells the screen so, the rest are left
  for (final file in files.take(most + 1)) {
    Uint8List? raw;
    try {
      raw = await file.readAsBytes();
    } on Object {
      raw = null; // it was there to choose and is not there to read
    }
    fitted.add(raw == null ? null : await compute(fitForText, raw));
  }
  return fitted;
}

bool _gif(Uint8List raw) =>
    raw.length > 6 && raw[0] == 0x47 && raw[1] == 0x49 && raw[2] == 0x46 && raw[3] == 0x38; // "GIF8"

/// [raw] as it goes in a text: turned the way it was taken, no larger than [textPictureSide] a side, as a
/// JPEG of at most [textPictureBytes]. A small GIF goes as it is, so one that moves keeps moving. Null for
/// what is no picture this device can read (a HEIC file on a Mac, a PDF, a video).
Uint8List? fitForText(Uint8List raw) {
  try {
    if (_gif(raw) && raw.length <= textPictureBytes) return raw;
    final decoded = img.decodeImage(raw);
    if (decoded == null) return null;
    var image = img.bakeOrientation(decoded);
    if (image.numChannels == 4) {
      // a JPEG has no see-through: what was clear becomes white, not black
      final white = img.Image(width: image.width, height: image.height)..clear(img.ColorRgb8(255, 255, 255));
      image = img.compositeImage(white, image);
    }
    for (final (side, quality) in const [(textPictureSide, 82), (1280, 74), (1024, 66), (800, 58)]) {
      final jpeg = img.encodeJpg(_within(image, side), quality: quality);
      if (jpeg.length <= textPictureBytes) return jpeg;
    }
    return null;
  } on Object {
    return null; // a file that only looked like a picture
  }
}

img.Image _within(img.Image image, int side) {
  if (image.width <= side && image.height <= side) return image;
  return image.width >= image.height
      ? img.copyResize(image, width: side, interpolation: img.Interpolation.average)
      : img.copyResize(image, height: side, interpolation: img.Interpolation.average);
}
