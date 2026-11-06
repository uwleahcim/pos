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

  /// Keeps the camera's frames coming while a screen looks for faces, so [frame] answers at once with the
  /// newest one, and counts in [motion] the times the view in front of the camera changed. Answers whether
  /// the camera can do that; one that cannot (the Mac) goes on answering [frame] as before. Each call is
  /// paired with an [unwatch].
  Future<bool> watch() async => false;

  void unwatch() {}

  /// Goes up, with a notification, each time the picture in front of a watched camera changes (someone
  /// stepping up to the screen): the sign-in loop sends a frame at once rather than waiting its turn.
  int motion = 0;

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

  // While watched, the preview stream stays open and the newest frame is kept here.
  int _watchers = 0;
  cam.CameraImage? _latest;
  int _latestSeq = 0; // goes up with each frame delivered
  int _handedSeq = 0; // the frame last handed out
  Completer<cam.CameraImage>? _waiting; // a caller waiting for the next frame
  Uint8List? _handedLook; // a coarse picture of the frame last handed out, to see the view change
  int _delivered = 0;
  int _motionAt = 0;
  Future<void>? _stopping; // the stream's stop in flight after the last unwatch

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
        // Fifteen frames a second are plenty for the preview and the sign-in, and half the copying while the
        // stream is open (a hint: the platform picks the nearest rate it supports).
        fps: 15,
      );
      await controller.initialize();
      _controller = controller;
      _error = null;
    } catch (err) {
      _error = '$err';
    }
    notifyListeners();
  }

  /// The live picture once the controller is up. The widget follows the camera on its own, so a screen built
  /// while the camera was still starting (the sign-in screen at app start) shows the picture the moment it is
  /// there, with no rebuild of its own.
  @override
  Widget preview() {
    start();
    return ListenableBuilder(listenable: this, builder: (context, _) => _livePreview());
  }

  Widget _livePreview() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return ColoredBox(
        color: Colors.black26,
        child: Center(child: _error == null ? const CircularProgressIndicator() : const Icon(Icons.no_photography)),
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

  @override
  Future<bool> watch() async {
    _watchers += 1;
    if (_watchers > 1) return true;
    await start();
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return false;
    try {
      await _snapping; // an audit photo's own short stream ends first
      await _stopping; // and so does the stop of the stream a previous watcher left
      if (!controller.value.isStreamingImages) await controller.startImageStream(_onFrame);
      return true;
    } catch (err) {
      _error = '$err';
      notifyListeners();
      return false;
    }
  }

  @override
  void unwatch() {
    if (_watchers == 0) return;
    _watchers -= 1;
    if (_watchers > 0) return;
    _latest = null;
    _handedLook = null;
    final controller = _controller;
    if (controller != null && controller.value.isStreamingImages) {
      _stopping = controller
          .stopImageStream()
          .catchError((Object err) => _error = '$err')
          .whenComplete(() => _stopping = null);
    }
  }

  void _onFrame(cam.CameraImage image) {
    _latest = image;
    _latestSeq += 1;
    final waiting = _waiting;
    if (waiting != null && !waiting.isCompleted) {
      _waiting = null;
      waiting.complete(image);
    }
    _delivered += 1;
    if (_delivered % 3 == 0) _lookForMotion(image);
  }

  /// The newest frame: straight off the open stream while watched (never the same frame twice), else one
  /// frame off a short stream of its own.
  Future<cam.CameraImage?> _grab(cam.CameraController controller) async {
    if (_watchers == 0 || !controller.value.isStreamingImages) return _oneFrame(controller);
    var image = _latest;
    if (image == null || _latestSeq == _handedSeq) {
      final next = _waiting ??= Completer<cam.CameraImage>();
      try {
        image = await next.future.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        return null; // the app is in the background, or the camera went
      }
    }
    _handedSeq = _latestSeq;
    _handedLook = _look(image);
    return image;
  }

  /// A coarse grey picture of a frame, 24 by 18 samples of its first plane (the luma on Android, the green
  /// of BGRA on iOS): enough to tell an empty view from one with someone in it.
  static Uint8List _look(cam.CameraImage image) {
    final plane = image.planes.first;
    final step = plane.bytesPerPixel ?? 1;
    final offset = step == 4 ? 1 : 0;
    final bytes = plane.bytes;
    final out = Uint8List(24 * 18);
    var k = 0;
    for (var row = 0; row < 18; row++) {
      final y = (row * image.height + image.height ~/ 2) ~/ 18;
      for (var col = 0; col < 24; col++) {
        final x = (col * image.width + image.width ~/ 2) ~/ 24;
        final i = y * plane.bytesPerRow + x * step + offset;
        out[k++] = i < bytes.length ? bytes[i] : 0;
      }
    }
    return out;
  }

  /// Has the view changed since the frame last handed out? Then [motion] goes up, at most a few times a
  /// second. A still view, with or without someone in it, stays quiet.
  void _lookForMotion(cam.CameraImage image) {
    final before = _handedLook;
    if (before == null) return;
    final now = _look(image);
    var diff = 0;
    for (var i = 0; i < now.length; i++) {
      diff += (now[i] - before[i]).abs();
    }
    if (diff < motionThreshold * now.length) return;
    final at = DateTime.now().millisecondsSinceEpoch;
    if (at - _motionAt < 300) return;
    _motionAt = at;
    motion += 1;
    notifyListeners();
  }

  /// Mean change per sample (of 255) between two looks that counts as the view changing.
  static const int motionThreshold = 12;

  /// One frame off the preview stream as a JPEG at most [maxSide] px on the long side, upright.
  Future<Uint8List?> _streamed(cam.CameraController controller, int maxSide) async {
    final frame = await _grab(controller);
    if (frame == null) return null;
    final turn = _rotation(controller);
    if (frame.format.group == cam.ImageFormatGroup.bgra8888) {
      return compute(encodeFrame, FramePixels.of(frame, turn, maxSide: maxSide));
    }
    if (frame.planes.length == 3) return compute(encodeYuv, YuvPixels.of(frame, turn, maxSide: maxSide));
    throw StateError('unexpected camera frame: ${frame.format.group} with ${frame.planes.length} planes');
  }

  /// Start the image stream, keep the first frame, stop the stream again (the camera is not watched).
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
  // Chroma at half resolution, as every camera JPEG has it: a quarter less to encode, a smaller file.
  return img.encodeJpg(image, quality: maxSide > 320 ? 80 : 70, chroma: img.JpegChroma.yuv420);
}
