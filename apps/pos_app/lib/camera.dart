import 'dart:io' show Platform;

import 'package:camera/camera.dart' as cam;
import 'package:camera_macos/camera_macos.dart' as mac;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

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
      final controller = cam.CameraController(front, cam.ResolutionPreset.low, enableAudio: false);
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

  @override
  Future<Uint8List?> snap() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized || controller.value.isTakingPicture) return null;
    try {
      final file = await controller.takePicture();
      return await file.readAsBytes();
    } catch (err) {
      _error = '$err';
      notifyListeners();
      return null;
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }
}
