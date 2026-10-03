// Sub-plan 08 step 2: the live app's CMC input. The stream's encoded frame is decoded straight to
// a reduced grayscale image, and the warp estimated there is scaled back to full-frame pixels,
// where the tracks' boxes are.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'package:reefsight_mobile/tracking/camera_motion_compensation.dart';
import 'package:reefsight_mobile/tracking/cmc_frames.dart';

/// A textured scene shifted [dx] px right, JPEG-encoded at [width]x[height] -- what the plugin's
/// `originalImage` looks like. The texture is random 6 px blocks from a fixed hash, deliberately
/// *non-periodic*: a repeating pattern lets optical flow lock onto a shift one period off (a
/// checkerboard here read a +24 px pan as -22).
Uint8List _jpeg(int width, int height, {int dx = 0}) {
  int block(int bx, int by) => ((bx * 73856093) ^ (by * 19349663)) & 0xff;
  final pixels = [
    for (var y = 0; y < height; y++)
      for (var x = 0; x < width; x++) block((x - dx + 6000) ~/ 6, y ~/ 6),
  ];
  final mat = cv.Mat.fromList(height, width, cv.MatType.CV_8UC1, pixels);
  final (ok, bytes) = cv.imencode('.jpg', mat);
  mat.dispose();
  expect(ok, isTrue);
  return bytes;
}

void main() {
  test('reductionFor picks the libjpeg factor closest to the 640 px target', () {
    expect(reductionFor(640), 1);
    expect(reductionFor(1280), 2);
    expect(reductionFor(1920), 4); // 480 is closer to 640 than 960
    expect(reductionFor(3840), 8);
    expect(reductionFor(1920, targetWidth: 960), 2);
  });

  test('decodeCmcFrame decodes at reduced size and records the scale back', () {
    final frame = decodeCmcFrame(_jpeg(1280, 720), fullWidth: 1280)!;
    expect((frame.width, frame.height), (640, 360));
    expect(frame.scale, 2.0);
    expect(frame.pixels, hasLength(640 * 360));
  });

  test('decodeCmcFrame returns null for bytes that are not an image', () {
    expect(decodeCmcFrame(Uint8List.fromList([0xFF, 0xD8, 0xFF]), fullWidth: 640), isNull);
  });

  test('ScaledFrameCompensator reports translation in full-frame pixels', () {
    // The scene pans 24 px between frames at full (1280) width; the warp is estimated on the
    // 640-wide decode, where that is 12 px, and must come back as ~24.
    final compensator = ScaledFrameCompensator();
    addTearDown(compensator.dispose);
    compensator.apply(decodeCmcFrame(_jpeg(1280, 720), fullWidth: 1280)!);
    final warp = compensator.apply(decodeCmcFrame(_jpeg(1280, 720, dx: 24), fullWidth: 1280)!);
    expect(warp[0][2], closeTo(24, 2));
    expect(warp[1][2], closeTo(0, 2));
    expect(warp[0][0], closeTo(1, 0.02));
  });

  test('a plain GrayscaleFrame is treated as full resolution', () {
    final compensator = ScaledFrameCompensator();
    addTearDown(compensator.dispose);
    final plain = GrayscaleFrame(width: 4, height: 4, pixels: List.filled(16, 0));
    expect(compensator.apply(plain), identityWarp());
  });
}
