import 'package:camera/camera.dart';
import 'package:flutter/services.dart' show DeviceOrientation;
import 'package:flutter/widgets.dart';

/// Issue #4: the still camera for photo-transect capture, behind an
/// interface because the `camera` plugin has no platform channel under
/// `flutter test`.
///
/// This uses the `camera` plugin, not `YOLOView`: photo capture runs no
/// segmentation, and needs full-resolution stills (the iPhone 14's 12 MP
/// main camera; TB 2017-05 asks for at least 5 MP), which `YOLOView`'s
/// session doesn't take. Live and this screen never run at the same time,
/// so the two never compete for the camera.
abstract interface class StillCamera {
  Widget buildPreview();

  /// Width over height of the preview as shown in portrait.
  double get portraitAspectRatio;

  /// Takes one still; returns the path of the camera's temp JPEG.
  Future<String> takePicture();

  Future<void> dispose();
}

abstract interface class StillCameraOpener {
  Future<StillCamera> open();
}

/// The real [StillCameraOpener]: the back wide camera at the highest
/// preset, JPEG, flash off, no audio.
class PluginStillCameraOpener implements StillCameraOpener {
  const PluginStillCameraOpener();

  @override
  Future<StillCamera> open() async {
    final cameras = await availableCameras();
    final back = cameras.where((c) => c.lensDirection == CameraLensDirection.back);
    if (back.isEmpty) throw CameraException('noBackCamera', 'This phone has no back camera');
    final controller = CameraController(
      back.first,
      ResolutionPreset.max,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );
    try {
      await controller.initialize();
      await controller.setFlashMode(FlashMode.off);
      // Pointing straight down, the phone's orientation is ambiguous (face
      // up), so the plugin could rotate stills by however the diver last held
      // it. Locked to portrait: every still and the preview keep one shape,
      // and corners/points (#6-7) normalise against one width and height.
      await controller.lockCaptureOrientation(DeviceOrientation.portraitUp);
    } catch (_) {
      await controller.dispose();
      rethrow;
    }
    return _PluginStillCamera(controller);
  }
}

class _PluginStillCamera implements StillCamera {
  _PluginStillCamera(this._controller);

  final CameraController _controller;

  @override
  Widget buildPreview() => CameraPreview(_controller);

  // The controller reports the sensor's landscape aspect.
  @override
  double get portraitAspectRatio => 1 / _controller.value.aspectRatio;

  @override
  Future<String> takePicture() async => (await _controller.takePicture()).path;

  @override
  Future<void> dispose() => _controller.dispose();
}
