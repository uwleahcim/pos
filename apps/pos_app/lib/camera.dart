import 'dart:async';
import 'dart:io' show Platform;

import 'package:camera/camera.dart' as cam;
import 'package:camera_macos/camera_macos.dart' as mac;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show DeviceOrientation;
import 'package:image/image.dart' as img;

/// The front camera as the app uses it: a live preview widget, and one small frame on demand.
///
/// The preview must be on screen for the camera to run; the orders screen keeps a thumbnail in its app bar,
/// which is also the visible sign that the operator may be photographed.
abstract class EventCamera extends ChangeNotifier {
  bool get ready;
  String? get error;

  Widget preview();

  /// A JPEG of the operator right now, or null when the camera is not ready.
  Future<Uint8List?> snap();

  /// A frame for the face sign-in, bigger than an audit photo (about [maxSide] px on the long side, so a
  /// face at arm's length is a hundred pixels or more) and silent on every platform. The audit [snap] by
  /// default.
  Future<Uint8List?> frame({int maxSide = 480}) => snap();

  static EventCamera forPlatform() {
    if (kIsWeb) return NoCamera();
    if (Platform.isMacOS) return MacCamera();
    if (Platform.isIOS || Platform.isAndroid) return PhoneCamera();
    return NoCamera();
  }
}

class NoCamera extends EventCamera {
  @override
  bool get ready => false;
  @override
  String? get error => 'no camera on this platform';
  @override
  Widget preview() => const ColoredBox(
    color: Colors.black26,
    child: Center(child: Icon(Icons.no_photography)),
  );
  @override
  Future<Uint8List?> snap() async => null;
}

/// macOS through the camera_macos plugin: the view creates the controller once it is in the tree.
class MacCamera extends EventCamera {
  final GlobalKey _key = GlobalKey();
  mac.CameraMacOSController? _controller;
  String? _error;

  @override
  bool get ready => _controller != null;
  @override
  String? get error => _error;

  @override
  Widget preview() => mac.CameraMacOSView(
    key: _key,
    fit: BoxFit.cover,
    cameraMode: mac.CameraMacOSMode.photo,
    enableAudio: false,
    resolution: mac.PictureResolution.low,
    pictureFormat: mac.PictureFormat.jpg,
    onCameraInizialized: (controller) {
      _controller = controller;
      _error = null;
      notifyListeners();
    },
    onCameraDestroyed: () {
      _controller = null;
      notifyListeners();
      return const SizedBox.shrink();
    },
  );

  @override
  Future<Uint8List?> snap() async {
    final controller = _controller;
    if (controller == null) return null;
    try {
      final file = await controller.takePicture();
      return file?.bytes;
    } catch (err) {
      _error = '$err';
      notifyListeners();
      return null;
    }
  }
}

/// iOS and Android through the camera plugin: the front camera at the medium preset (640x480), which the
/// face sign-in wants; an audit photo is shrunk to 320 px.
class PhoneCamera extends EventCamera {
  /// iOS takes the photo off the preview stream (its still capture plays a shutter sound and flashes the
  /// screen); Android's still capture is silent, so it takes an ordinary picture. A face frame comes off
  /// the stream on both (see [frame]): a still every second would be a shutter sound a second on a Samsung
  /// that forces one.
  final bool fromStream = Platform.isIOS;

  cam.CameraController? _controller;
  Future<void>? _starting;
  String? _error;

  @override
  bool get ready => _controller?.value.isInitialized ?? false;
  @override
  String? get error => _error;

  Future<void> start() => _starting ??= _start();

  Future<void> _start() async {
    try {
      final cameras = await cam.availableCameras();
      if (cameras.isEmpty) {
        _error = 'no camera';
        notifyListeners();
        return;
      }
      final front = cameras.firstWhere(
        (c) => c.lensDirection == cam.CameraLensDirection.front,
        orElse: () => cameras.first,
      );
      final controller = cam.CameraController(
        front,
        cam.ResolutionPreset.medium,
        enableAudio: false,
        // The stream's pixel format: BGRA on iOS, the planar YUV Android's camera gives (encodeYuv turns it
        // into a JPEG).
        imageFormatGroup: Platform.isIOS ? cam.ImageFormatGroup.bgra8888 : cam.ImageFormatGroup.yuv420,
      );
      await controller.initialize();
      _controller = controller;
      _error = null;
    } catch (err) {
      _error = '$err';
    }
    notifyListeners();
  }

  @override
  Widget preview() {
    start();
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return const ColoredBox(
        color: Colors.black26,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    // The preview keeps the sensor's aspect ratio and is cropped to the box it is given, never stretched.
    final value = controller.value;
    final orientation = value.lockedCaptureOrientation ?? value.deviceOrientation;
    final landscape = orientation == DeviceOrientation.landscapeLeft || orientation == DeviceOrientation.landscapeRight;
    final ratio = landscape ? value.aspectRatio : 1 / value.aspectRatio;
    return ClipRect(
      child: FittedBox(
        fit: BoxFit.cover,
        clipBehavior: Clip.hardEdge,
        child: SizedBox(width: 100 * ratio, height: 100, child: cam.CameraPreview(controller)),
      ),
    );
  }

  Future<Uint8List?>? _snapping;

  /// One frame off the preview stream, encoded here: no shutter sound, no screen flash, unlike
  /// `takePicture`, which goes through the system photo capture on iOS.
  @override
  Future<Uint8List?> snap() => _snapping ??= _snap().whenComplete(() => _snapping = null);

  Future<Uint8List?> _snap() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return null;
    try {
      if (!fromStream) {
        final photo = await controller.takePicture();
        return await compute(shrinkJpeg, await photo.readAsBytes());
      }
      return await _streamed(controller, 320);
    } catch (err) {
      _error = '$err';
      notifyListeners();
      return null;
    }
  }

  @override
  Future<Uint8List?> frame({int maxSide = 480}) async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return null;
    try {
      return await _streamed(controller, maxSide);
    } catch (err) {
      _error = '$err';
      notifyListeners();
      return null;
    }
  }

  /// One frame off the preview stream as a JPEG at most [maxSide] px on the long side, upright.
  Future<Uint8List?> _streamed(cam.CameraController controller, int maxSide) async {
    final frame = await _oneFrame(controller);
    if (frame == null) return null;
    final turn = _rotation(controller);
    if (frame.format.group == cam.ImageFormatGroup.bgra8888) {
      return compute(encodeFrame, FramePixels.of(frame, turn, maxSide: maxSide));
    }
    if (frame.planes.length == 3) return compute(encodeYuv, YuvPixels.of(frame, turn, maxSide: maxSide));
    throw StateError('unexpected camera frame: ${frame.format.group} with ${frame.planes.length} planes');
  }

  /// Start the image stream, keep the first frame, stop the stream again.
  Future<cam.CameraImage?> _oneFrame(cam.CameraController controller) async {
    if (controller.value.isStreamingImages) return null;
    final first = Completer<cam.CameraImage>();
    await controller.startImageStream((image) {
      if (!first.isCompleted) first.complete(image);
    });
    try {
      return await first.future.timeout(const Duration(seconds: 2));
    } on TimeoutException {
      return null;
    } finally {
      if (controller.value.isStreamingImages) await controller.stopImageStream();
    }
  }

  /// Degrees to turn a raw sensor frame so it is upright for the operator (front camera).
  static int _rotation(cam.CameraController controller) {
    final device = switch (controller.value.deviceOrientation) {
      DeviceOrientation.portraitUp => 0,
      DeviceOrientation.landscapeLeft => 90,
      DeviceOrientation.portraitDown => 180,
      DeviceOrientation.landscapeRight => 270,
    };
    return (controller.description.sensorOrientation + device) % 360;
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }
}

/// A BGRA frame copied out of the camera image, so it can cross to a worker isolate.
class FramePixels {
  final int width;
  final int height;
  final int rowStride;
  final Uint8List bytes;
  final int rotation;
  final int maxSide;

  FramePixels(this.width, this.height, this.rowStride, this.bytes, this.rotation, {this.maxSide = 320});

  factory FramePixels.of(cam.CameraImage frame, int rotation, {int maxSide = 320}) {
    final plane = frame.planes.first;
    return FramePixels(
      frame.width,
      frame.height,
      plane.bytesPerRow,
      Uint8List.fromList(plane.bytes),
      rotation,
      maxSide: maxSide,
    );
  }
}

/// A planar YUV 4:2:0 frame (Android's camera stream) copied out of the camera image: the Y plane, then the
/// U and V planes with their own row stride and the pixel stride that interleaves them when the camera
/// hands out NV21 as three planes.
class YuvPixels {
  final int width;
  final int height;
  final Uint8List y;
  final int yRowStride;
  final Uint8List u;
  final Uint8List v;
  final int uvRowStride;
  final int uvPixelStride;
  final int rotation;
  final int maxSide;

  YuvPixels(
    this.width,
    this.height,
    this.y,
    this.yRowStride,
    this.u,
    this.v,
    this.uvRowStride,
    this.uvPixelStride,
    this.rotation, {
    this.maxSide = 320,
  });

  factory YuvPixels.of(cam.CameraImage frame, int rotation, {int maxSide = 320}) {
    final planes = frame.planes;
    return YuvPixels(
      frame.width,
      frame.height,
      Uint8List.fromList(planes[0].bytes),
      planes[0].bytesPerRow,
      Uint8List.fromList(planes[1].bytes),
      Uint8List.fromList(planes[2].bytes),
      planes[1].bytesPerRow,
      planes[1].bytesPerPixel ?? 1,
      rotation,
      maxSide: maxSide,
    );
  }
}

/// Worker: a camera JPEG (Android) turned upright and made small like the iOS frames.
Uint8List shrinkJpeg(Uint8List jpeg) {
  final decoded = img.decodeJpg(jpeg);
  if (decoded == null) return jpeg;
  return _small(img.bakeOrientation(decoded));
}

/// Worker: BGRA pixels to a small JPEG, at most `maxSide` px on the long side (320 for an audit photo).
Uint8List encodeFrame(FramePixels f) {
  var image = img.Image.fromBytes(
    width: f.width,
    height: f.height,
    bytes: f.bytes.buffer,
    bytesOffset: f.bytes.offsetInBytes,
    rowStride: f.rowStride,
    numChannels: 4,
    order: img.ChannelOrder.bgra,
  );
  if (f.rotation != 0) image = img.copyRotate(image, angle: f.rotation);
  return _small(image, f.maxSide);
}

/// Worker: planar YUV 4:2:0 pixels to a small JPEG, at most `maxSide` px on the long side. BT.601, full range,
/// as Android's camera streams it.
Uint8List encodeYuv(YuvPixels f) {
  final rgb = Uint8List(f.width * f.height * 3);
  var out = 0;
  for (var row = 0; row < f.height; row++) {
    final yRow = row * f.yRowStride;
    final uvRow = (row >> 1) * f.uvRowStride;
    for (var col = 0; col < f.width; col++) {
      final luma = f.y[yRow + col];
      final uv = uvRow + (col >> 1) * f.uvPixelStride;
      final cb = f.u[uv] - 128;
      final cr = f.v[uv] - 128;
      rgb[out++] = _clamp(luma + ((359 * cr) >> 8));
      rgb[out++] = _clamp(luma - ((88 * cb + 183 * cr) >> 8));
      rgb[out++] = _clamp(luma + ((454 * cb) >> 8));
    }
  }
  var image = img.Image.fromBytes(width: f.width, height: f.height, bytes: rgb.buffer, numChannels: 3);
  if (f.rotation != 0) image = img.copyRotate(image, angle: f.rotation);
  return _small(image, f.maxSide);
}

int _clamp(int v) => v < 0 ? 0 : (v > 255 ? 255 : v);

Uint8List _small(img.Image image, [int maxSide = 320]) {
  final long = image.width > image.height ? image.width : image.height;
  if (long > maxSide) {
    image = image.width >= image.height
        ? img.copyResize(image, width: maxSide)
        : img.copyResize(image, height: maxSide);
  }
  return img.encodeJpg(image, quality: maxSide > 320 ? 80 : 70);
}
