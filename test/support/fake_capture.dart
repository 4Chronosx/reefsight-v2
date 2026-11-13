import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:reefsight_mobile/services/screen_awake.dart';
import 'package:reefsight_mobile/services/still_camera.dart';
import 'package:reefsight_mobile/services/tilt.dart';

// Issue #4: stand-ins for the photo capture screen's platform pieces --
// the `camera` plugin, `sensors_plus` and `wakelock_plus` have no platform
// channel under `flutter test`.

/// A JPEG header for a 4032 × 3024 (12 MP) still -- enough for
/// `jpegPixelSize`; it doesn't decode as an image.
Uint8List fakeJpeg12mp() => Uint8List.fromList([
      0xFF, 0xD8, 0xFF, 0xC0, 0x00, 0x11, 0x08, 0x0B, 0xD0, 0x0F, 0xC0, //
      0x03, 0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01, 0xFF, 0xD9,
    ]);

/// Writes [fakeJpeg12mp] into [dir] for each shot.
class FakeStillCamera implements StillCamera {
  FakeStillCamera(this.dir);
  final Directory dir;
  var shots = 0;
  var disposed = false;

  @override
  Widget buildPreview() => const ColoredBox(color: Color(0xFF000000));

  @override
  double get portraitAspectRatio => 3 / 4;

  @override
  Future<String> takePicture() async {
    final f = File(p.join(dir.path, 'cam_${shots++}.jpg'));
    await f.writeAsBytes(fakeJpeg12mp());
    return f.path;
  }

  @override
  Future<void> dispose() async => disposed = true;
}

class FakeStillCameraOpener implements StillCameraOpener {
  FakeStillCameraOpener(this.camera, {this.fail = false});
  final FakeStillCamera camera;
  final bool fail;

  @override
  Future<StillCamera> open() async {
    if (fail) throw Exception('camera permission denied');
    return camera;
  }
}

/// Readings arrive when the test adds them, synchronously, as a sensor
/// event does between frames.
class FakeTiltSource implements TiltSource {
  final controller = StreamController<double>.broadcast(sync: true);
  @override
  Stream<double> tiltDegrees() => controller.stream;
}

class FakeScreenAwake implements ScreenAwake {
  var enabled = 0;
  var disabled = 0;
  @override
  Future<void> enable() async => enabled++;
  @override
  Future<void> disable() async => disabled++;
}
