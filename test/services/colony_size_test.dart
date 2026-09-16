import 'package:flutter_test/flutter_test.dart';
import 'package:reefsight_mobile/services/colony_size.dart';

// Sub-plan 3 "Done when": a mask-derived size, in addition to track id and
// health. Pixel-only at this stage -- real-world scaling via the physical
// transect tape is sub-plan 4's job (Track 3 §8-10), not this one.
//
// `YOLOResult.mask` (ultralytics_yolo) is documented only as "each inner
// list represents a row of mask values" -- no stated value range or whether
// the grid is box-sized or a different resolution. maskAreaPixels() is
// written to be correct either way: it scales each mask cell by the ratio of
// the box's real pixel size to the mask grid's cell count, rather than
// assuming a 1:1 mapping.

void main() {
  group('maskAreaPixels', () {
    test('an all-foreground mask covering the whole box returns the box area',
        () {
      final mask = [
        [1.0, 1.0],
        [1.0, 1.0],
      ];

      final area = maskAreaPixels(
        mask,
        boxWidthPx: 40,
        boxHeightPx: 20,
      );

      expect(area, closeTo(40 * 20, 1e-9));
    });

    test('an all-background mask returns zero', () {
      final mask = [
        [0.0, 0.0],
        [0.0, 0.0],
      ];

      final area = maskAreaPixels(mask, boxWidthPx: 40, boxHeightPx: 20);

      expect(area, 0);
    });

    test('half the cells foreground returns half the box area', () {
      final mask = [
        [1.0, 1.0, 0.0, 0.0],
      ];

      final area = maskAreaPixels(mask, boxWidthPx: 100, boxHeightPx: 10);

      expect(area, closeTo(100 * 10 / 2, 1e-9));
    });

    test('a coarser mask grid than the box still scales to full box area',
        () {
      // 2x2 grid representing a 200x200px box -- each cell is 100x100px.
      final mask = [
        [1.0, 1.0],
        [1.0, 1.0],
      ];

      final area = maskAreaPixels(mask, boxWidthPx: 200, boxHeightPx: 200);

      expect(area, closeTo(200 * 200, 1e-9));
    });

    test('a value exactly at the default threshold counts as foreground', () {
      final mask = [
        [0.5],
      ];

      final area = maskAreaPixels(mask, boxWidthPx: 10, boxHeightPx: 10);

      expect(area, closeTo(100, 1e-9));
    });

    test('a custom threshold excludes values below it', () {
      final mask = [
        [0.5, 0.9],
      ];

      final area = maskAreaPixels(
        mask,
        boxWidthPx: 20,
        boxHeightPx: 10,
        threshold: 0.6,
      );

      // Only the 0.9 cell counts -> half the box area.
      expect(area, closeTo(20 * 10 / 2, 1e-9));
    });

    test('an empty mask returns zero without crashing', () {
      expect(maskAreaPixels([], boxWidthPx: 10, boxHeightPx: 10), 0);
    });

    test('a mask with empty rows returns zero without crashing', () {
      expect(maskAreaPixels([[]], boxWidthPx: 10, boxHeightPx: 10), 0);
    });
  });
}
