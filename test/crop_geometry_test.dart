import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:reefsight_mobile/services/crop_geometry.dart';

void main() {
  group('computeCropRegion', () {
    test('keeps a box fully inside the frame as-is', () {
      final region = computeCropRegion(
        const Rect.fromLTWH(100, 50, 200, 150),
        frameWidth: 1280,
        frameHeight: 720,
      );

      expect(region.left, 100);
      expect(region.top, 50);
      expect(region.width, 200);
      expect(region.height, 150);
    });

    test('clamps a box that overshoots the right/bottom edge', () {
      final region = computeCropRegion(
        const Rect.fromLTWH(1200, 700, 200, 150),
        frameWidth: 1280,
        frameHeight: 720,
      );

      expect(region.left + region.width, lessThanOrEqualTo(1280));
      expect(region.top + region.height, lessThanOrEqualTo(720));
    });

    test('clamps a box with a negative origin from an imprecise detection', () {
      final region = computeCropRegion(
        const Rect.fromLTWH(-20, -10, 100, 80),
        frameWidth: 640,
        frameHeight: 480,
      );

      expect(region.left, 0);
      expect(region.top, 0);
    });

    test('never returns a zero-size region for a degenerate box at the corner', () {
      final region = computeCropRegion(
        const Rect.fromLTWH(639, 479, 0, 0),
        frameWidth: 640,
        frameHeight: 480,
      );

      expect(region.width, greaterThan(0));
      expect(region.height, greaterThan(0));
    });

    test('never returns a region larger than the frame', () {
      final region = computeCropRegion(
        const Rect.fromLTWH(-100, -100, 2000, 2000),
        frameWidth: 640,
        frameHeight: 480,
      );

      expect(region.left, 0);
      expect(region.top, 0);
      expect(region.width, 640);
      expect(region.height, 480);
    });

    test('falls back to a minimal region for a non-positive frame size', () {
      final region = computeCropRegion(
        const Rect.fromLTWH(0, 0, 10, 10),
        frameWidth: 0,
        frameHeight: 0,
      );

      expect(region.width, greaterThan(0));
      expect(region.height, greaterThan(0));
    });
  });

  // Sub-plan 10 (classifier input and reject), crop spec v1. Masks are
  // treated as box-local grids (the same assumption `maskAreaPixels` makes)
  // until step 0's on-device check settles the coordinate space.
  List<List<double>> full(int rows, int cols) =>
      List.generate(rows, (_) => List.filled(cols, 1.0));

  group('deepestMaskCell', () {
    test('a single foreground cell is its own anchor', () {
      final mask = [
        [0.0, 0.0, 0.0],
        [0.0, 1.0, 0.0],
        [0.0, 0.0, 0.0],
      ];

      expect(deepestMaskCell(mask), (row: 1, col: 1));
    });

    test('a filled square peaks at its centre', () {
      expect(deepestMaskCell(full(5, 5)), (row: 2, col: 2));
    });

    test('ties are broken towards the mask centroid, not the first cell', () {
      // A 1-row strip: every cell is equally far from the background.
      final anchor = deepestMaskCell(full(1, 9))!;

      expect(anchor.row, 0);
      expect(anchor.col, 4);
    });

    test('a body with a long thin arm anchors in the body, not the centroid',
        () {
      // A 5x5 block (cols 0-4) with a 1-cell-thick arm along row 2 out to
      // col 11. The arm drags the centroid right, into the arm; the deepest
      // point is still the block's centre.
      final mask = List.generate(
        5,
        (r) => List.generate(
          12,
          (c) => c <= 4 || r == 2 ? 1.0 : 0.0,
        ),
      );

      expect(deepestMaskCell(mask), (row: 2, col: 2));
    });

    test('an empty or all-background mask has no anchor', () {
      expect(deepestMaskCell(const []), isNull);
      expect(deepestMaskCell([
        [0.0, 0.2],
        [0.4, 0.0],
      ]), isNull);
    });
  });

  group('computeClassifierCrop (insideMaskSquare)', () {
    test('a fully-masked box gives its own square with full coverage', () {
      final crop = computeClassifierCrop(
        style: CropStyle.insideMaskSquare,
        box: const Rect.fromLTWH(100, 100, 200, 200),
        mask: full(5, 5),
        frameWidth: 640,
        frameHeight: 480,
      )!;

      expect(crop.window, const Rect.fromLTWH(100, 100, 200, 200));
      expect(crop.coverage, closeTo(1.0, 1e-9));
    });

    test('the side is min(box w, h) and the window is centred on the anchor',
        () {
      final crop = computeClassifierCrop(
        style: CropStyle.insideMaskSquare,
        box: const Rect.fromLTWH(100, 100, 300, 150),
        mask: full(3, 5),
        frameWidth: 640,
        frameHeight: 480,
      )!;

      expect(crop.window.width, 150);
      expect(crop.window.height, 150);
      expect(crop.window.center, const Offset(250, 175));
      expect(crop.coverage, closeTo(1.0, 1e-9));
    });

    test('at the frame edge the window shifts inside without shrinking', () {
      // Foreground only in the rightmost column, so the anchor sits near the
      // right frame edge and a centred window would overhang it.
      final mask = List.generate(
        5,
        (_) => [0.0, 0.0, 0.0, 0.0, 1.0],
      );

      final crop = computeClassifierCrop(
        style: CropStyle.insideMaskSquare,
        box: const Rect.fromLTWH(560, 100, 80, 80),
        mask: mask,
        frameWidth: 640,
        frameHeight: 480,
      )!;

      // Anchor x = 560 + 4.5 * 16 = 632; centred left 592 would overhang
      // 640, so it shifts to 640 - 80 = 560. Only the rightmost 16 px
      // column is mask: coverage 16 * 80 / 6400 = 0.2.
      expect(crop.window, const Rect.fromLTWH(560, 100, 80, 80));
      expect(crop.coverage, closeTo(0.2, 1e-9));
    });

    test('a thin, elongated colony gets low coverage', () {
      final crop = computeClassifierCrop(
        style: CropStyle.insideMaskSquare,
        box: const Rect.fromLTWH(100, 100, 200, 20),
        mask: full(1, 10),
        frameWidth: 640,
        frameHeight: 480,
      )!;

      // min(200, 20) = 20 is clamped up to the 64 px floor; only the 20 px
      // tall strip inside it is coral.
      expect(crop.window.width, 64);
      expect(crop.coverage, closeTo(20 / 64, 1e-9));
    });

    test('a colony smaller than the 64 px floor is clamped up to 64', () {
      final crop = computeClassifierCrop(
        style: CropStyle.insideMaskSquare,
        box: const Rect.fromLTWH(300, 200, 20, 20),
        mask: full(4, 4),
        frameWidth: 640,
        frameHeight: 480,
      )!;

      expect(crop.window.width, 64);
      expect(crop.window.height, 64);
      expect(crop.coverage, closeTo(400 / 4096, 1e-9));
    });

    test('the side never exceeds the frame\'s shorter edge', () {
      final crop = computeClassifierCrop(
        style: CropStyle.insideMaskSquare,
        box: const Rect.fromLTWH(0, 0, 50, 40),
        mask: full(4, 5),
        frameWidth: 50,
        frameHeight: 40,
      )!;

      expect(crop.window, const Rect.fromLTWH(5, 0, 40, 40));
    });

    test('no mask, an empty mask, or an all-background mask gives no crop',
        () {
      ClassifierCrop? crop(List<List<double>>? mask) => computeClassifierCrop(
        style: CropStyle.insideMaskSquare,
        box: const Rect.fromLTWH(100, 100, 50, 50),
        mask: mask,
        frameWidth: 640,
        frameHeight: 480,
      );

      expect(crop(null), isNull);
      expect(crop(const []), isNull);
      expect(crop([
        [0.0, 0.0],
        [0.0, 0.0],
      ]), isNull);
    });
  });

  group('computeClassifierCrop (comparison styles)', () {
    test('boxStretch is today\'s crop: the box itself, clamped to the frame',
        () {
      final crop = computeClassifierCrop(
        style: CropStyle.boxStretch,
        box: const Rect.fromLTWH(600, 100, 80, 50),
        frameWidth: 640,
        frameHeight: 480,
      )!;

      expect(crop.window, const Rect.fromLTWH(600, 100, 40, 50));
      expect(crop.coverage, 1.0);
    });

    test('boxSquarePad is a square around the box, inside the frame', () {
      final crop = computeClassifierCrop(
        style: CropStyle.boxSquarePad,
        box: const Rect.fromLTWH(100, 100, 200, 100),
        frameWidth: 640,
        frameHeight: 480,
      )!;

      expect(crop.window, const Rect.fromLTWH(100, 50, 200, 200));
    });

    test('boxSquarePad shifts inside the frame at an edge', () {
      final crop = computeClassifierCrop(
        style: CropStyle.boxSquarePad,
        box: const Rect.fromLTWH(500, 420, 140, 60),
        frameWidth: 640,
        frameHeight: 480,
      )!;

      expect(crop.window.width, 140);
      expect(crop.window.height, 140);
      expect(crop.window.bottom, lessThanOrEqualTo(480));
      expect(crop.window.right, lessThanOrEqualTo(640));
    });

    test('comparison styles need no mask', () {
      for (final style in [CropStyle.boxStretch, CropStyle.boxSquarePad]) {
        expect(
          computeClassifierCrop(
            style: style,
            box: const Rect.fromLTWH(10, 10, 30, 30),
            frameWidth: 640,
            frameHeight: 480,
          ),
          isNotNull,
        );
      }
    });
  });
}
