import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'package:reefsight_mobile/services/laser_dot_detector.dart';

// Issue #14: finding the two laser dots in a still (alignment doc §6,
// "Paired lasers (preferred)"). The images here are synthetic: a blue-green
// water background with speckle, pale "coral", and green laser dots drawn
// the way a camera records them -- a blown-out near-white core inside a
// green halo.

/// A [width]x[height] JPEG with laser dots at [dots] (radius [r]) and pale
/// blobs at [pale]; optional tiny green [specks].
Uint8List _scene(
  int width,
  int height, {
  List<(int, int)> dots = const [],
  int r = 12,
  List<(int, int)> pale = const [],
  List<(int, int)> specks = const [],
}) {
  final img = cv.Mat.fromScalar(height, width, cv.MatType.CV_8UC3, cv.Scalar(120, 95, 40)); // BGR water
  for (var i = 0; i < 400; i++) {
    final x = (i * 7919) % width, y = (i * 104729) % height;
    cv.circle(img, cv.Point(x, y), 2, cv.Scalar(140, 110, 60), thickness: -1);
  }
  for (final (x, y) in pale) {
    cv.circle(img, cv.Point(x, y), 40, cv.Scalar(225, 235, 240), thickness: -1); // bleached coral
  }
  for (final (x, y) in dots) {
    cv.circle(img, cv.Point(x, y), r, cv.Scalar(60, 255, 80), thickness: -1); // green halo
    cv.circle(img, cv.Point(x, y), r ~/ 2, cv.Scalar(235, 255, 235), thickness: -1); // blown-out core
  }
  for (final (x, y) in specks) {
    cv.circle(img, cv.Point(x, y), 1, cv.Scalar(60, 255, 80), thickness: -1);
  }
  final (ok, bytes) = cv.imencode('.jpg', img);
  img.dispose();
  expect(ok, isTrue);
  return bytes;
}

DotBlob _blob(double x, double y, double area) => DotBlob(x: x, y: y, areaPx: area);

void main() {
  group('pickDotPair', () {
    test('fewer than two blobs: no pair', () {
      expect(pickDotPair(const []), isNull);
      expect(pickDotPair([_blob(10, 10, 300)]), isNull);
    });

    test('picks the two largest similar blobs, left to right', () {
      final pair = pickDotPair([_blob(900, 500, 310), _blob(100, 500, 300), _blob(400, 400, 40)])!;
      expect(pair.a.x, 100);
      expect(pair.b.x, 900);
      expect(pair.ambiguous, isFalse);
      expect(pair.gapPx, closeTo(800, 1e-9));
    });

    test('a third blob nearly as large makes the pair ambiguous', () {
      final pair = pickDotPair([_blob(100, 500, 300), _blob(900, 500, 300), _blob(500, 900, 250)])!;
      expect(pair.ambiguous, isTrue);
    });

    test('blobs of very different size are not a pair', () {
      expect(pickDotPair([_blob(100, 500, 2000), _blob(900, 500, 100)]), isNull);
    });

    test('blobs touching each other are not a pair', () {
      expect(pickDotPair([_blob(100, 500, 300), _blob(104, 500, 300)]), isNull);
    });
  });

  group('detectLaserDots', () {
    test('finds both dots to within a pixel or two at full resolution', () {
      final result = detectLaserDots(_scene(1600, 1200, dots: [(500, 600), (1100, 620)]));
      final pair = result.pair!;
      expect(pair.a.x, closeTo(500, 2));
      expect(pair.a.y, closeTo(600, 2));
      expect(pair.b.x, closeTo(1100, 2));
      expect(pair.b.y, closeTo(620, 2));
      expect(pair.ambiguous, isFalse);
      // The still's size, so a caller can check it against the calibration's.
      expect((result.imageWidth, result.imageHeight), (1600, 1200));
    });

    test('ignores pale coral and single-pixel green specks', () {
      final result = detectLaserDots(_scene(
        1600,
        1200,
        dots: [(400, 300), (800, 300)],
        pale: [(1200, 900), (300, 1000)],
        specks: [(1500, 100), (50, 1150), (900, 900)],
      ));
      expect(result.blobs, hasLength(2));
      expect(result.pair, isNotNull);
    });

    test('no dots in the photo: no pair, no error', () {
      final result = detectLaserDots(_scene(1600, 1200, pale: [(800, 600)]));
      expect(result.blobs, isEmpty);
      expect(result.pair, isNull);
      expect(result.error, isNull);
    });

    test('an unreadable file is reported, not thrown', () {
      final result = detectLaserDots(Uint8List.fromList([1, 2, 3]));
      expect(result.pair, isNull);
      expect(result.error, isNotNull);
    });
  });
}
