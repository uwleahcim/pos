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

  static EventCamera forPlatform() {
    if (kIsWeb) return NoCamera();
    if (Platform.isMacOS) return MacCamera();
    if (Platform.isIOS) return IosCamera();
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

/// iOS through the camera plugin: the front camera at the lowest preset (about 320 px).
class IosCamera extends EventCamera {
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
        cam.ResolutionPreset.low,
        enableAudio: false,
        imageFormatGroup: cam.ImageFormatGroup.bgra8888,
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
    return cam.CameraPreview(controller);
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
      final frame = await _oneFrame(controller);
      if (frame == null) return null;
      final turn = _rotation(controller);
      return await compute(encodeFrame, FramePixels.of(frame, turn));
    } catch (err) {
      _error = '$err';
      notifyListeners();
      return null;
    }
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

  FramePixels(this.width, this.height, this.rowStride, this.bytes, this.rotation);

  factory FramePixels.of(cam.CameraImage frame, int rotation) {
    final plane = frame.planes.first;
    return FramePixels(frame.width, frame.height, plane.bytesPerRow, Uint8List.fromList(plane.bytes), rotation);
  }
}

/// Worker: BGRA pixels to a small JPEG, at most 320 px on the long side.
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
  final long = image.width > image.height ? image.width : image.height;
  if (long > 320) {
    image = image.width >= image.height ? img.copyResize(image, width: 320) : img.copyResize(image, height: 320);
  }
  return img.encodeJpg(image, quality: 70);
}
