import 'package:flutter_test/flutter_test.dart';
import 'package:reefsight_mobile/services/point_sampler.dart';
import 'package:reefsight_mobile/services/transect_frame.dart';

// Issue #6: CPCe-style random points, 10 per frame, reproducible from the
// transect's `point_seed`. The golden values come from the reference
// JavaScript Mulberry32 and MurmurHash3 fmix32 (run with Node, not from this
// Dart port), so the #7 laptop notebook can check its own port against the
// same numbers (`docs/cpce-point-sampling-and-cover.md`).

void main() {
  group('Mulberry32', () {
    test('matches the reference implementation', () {
      for (final (seed, expected) in [
        (0, [1144304738, 1416247, 958946056]),
        (42, [2581720956, 1925393290, 3661312704]),
        (4294967295, [3850105811, 813802916, 3073704848]),
      ]) {
        final rng = Mulberry32(seed);
        expect([rng.nextUint32(), rng.nextUint32(), rng.nextUint32()], expected, reason: 'seed $seed');
      }
    });

    test('nextDouble is in [0, 1)', () {
      final rng = Mulberry32(7);
      for (var i = 0; i < 1000; i++) {
        final d = rng.nextDouble();
        expect(d >= 0 && d < 1, isTrue);
      }
    });
  });

  group('frameSeed', () {
    test('matches the reference mix of the transect seed and the frame key', () {
      expect(frameSeed(42, 0), 142593372);
      expect(frameSeed(42, 1000), 628122554);
      expect(frameSeed(42, 50000), 1027786144);
      expect(frameSeed(123456789, 7000), 278790221);
    });
  });

  group('frameKey', () {
    test('a still is keyed by its meter mark in millimetres', () {
      expect(frameKey(meterMark: 1, videoTimeMs: null), 1000);
      expect(frameKey(meterMark: 12.5, videoTimeMs: null), 12500);
    });

    test('a video frame by its time', () {
      expect(frameKey(meterMark: null, videoTimeMs: 7000), 7000);
    });

    test('a frame with neither has no key', () {
      expect(() => frameKey(meterMark: null, videoTimeMs: null), throwsArgumentError);
    });
  });

  group('samplePoints', () {
    test('matches the reference points', () {
      final points = samplePoints(42, 1000, 2);
      expect(points[0].x, closeTo(0.6889322043862194, 1e-15));
      expect(points[0].y, closeTo(0.3359531017486006, 1e-15));
      expect(points[1].x, closeTo(0.893565627746284, 1e-15));
      expect(points[1].y, closeTo(0.9953378764912486, 1e-15));
    });

    test('the same seed and key give the same points; another seed or key does not', () {
      expect(samplePoints(42, 1000, 10), samplePoints(42, 1000, 10));
      expect(samplePoints(42, 1000, 10), isNot(samplePoints(43, 1000, 10)));
      expect(samplePoints(42, 1000, 10), isNot(samplePoints(42, 2000, 10)));
    });

    test('points stay inside the 1 x 1 m area', () {
      for (var key = 0; key < 50000; key += 1000) {
        for (final p in samplePoints(99, key, 10)) {
          expect(p.x >= 0 && p.x < 1 && p.y >= 0 && p.y < 1, isTrue);
        }
      }
    });

    test('asks for a positive count', () {
      expect(() => samplePoints(42, 0, 0), throwsArgumentError);
    });
  });

  group('frameToImage', () {
    const square = <NormPoint>[(x: 0.2, y: 0.1), (x: 0.8, y: 0.1), (x: 0.8, y: 0.7), (x: 0.2, y: 0.7)];
    // A frame seen at an angle: the far (top) edge is shorter.
    const trapezoid = <NormPoint>[(x: 0.3, y: 0.2), (x: 0.7, y: 0.2), (x: 0.95, y: 0.9), (x: 0.05, y: 0.9)];

    void expectNear(NormPoint actual, NormPoint expected) {
      expect(actual.x, closeTo(expected.x, 1e-12));
      expect(actual.y, closeTo(expected.y, 1e-12));
    }

    test('the corners of the area land on the frame corners (TL, TR, BR, BL)', () {
      for (final c in [square, trapezoid]) {
        expectNear(frameToImage(c, (x: 0, y: 0)), c[0]);
        expectNear(frameToImage(c, (x: 1, y: 0)), c[1]);
        expectNear(frameToImage(c, (x: 1, y: 1)), c[2]);
        expectNear(frameToImage(c, (x: 0, y: 1)), c[3]);
      }
    });

    test('an upright square frame is a plain scale and shift', () {
      expectNear(frameToImage(square, (x: 0.5, y: 0.5)), (x: 0.5, y: 0.4));
      expectNear(frameToImage(square, (x: 0.25, y: 0.75)), (x: 0.35, y: 0.55));
    });

    test('the centre of a tilted frame is where its diagonals cross, not the corner average', () {
      // Diagonals TL-BR and TR-BL of the trapezoid cross at y = 0.2 + 0.7 * 4/13.
      final centre = frameToImage(trapezoid, (x: 0.5, y: 0.5));
      expect(centre.x, closeTo(0.5, 1e-12));
      expect(centre.y, closeTo(0.2 + 0.7 * 4 / 13, 1e-12));
      expect(centre.y, isNot(closeTo(0.55, 1e-3)));
    });

    test('refuses corners with three in a line rather than returning NaN', () {
      const flat = <NormPoint>[(x: 0.1, y: 0.1), (x: 0.5, y: 0.1), (x: 0.9, y: 0.1), (x: 0.2, y: 0.8)];
      expect(() => frameToImage(flat, (x: 0.5, y: 0.5)), throwsArgumentError);
      // TR, BR, BL in a line: the case where the homography divides by zero.
      const flatBack = <NormPoint>[(x: 0.1, y: 0.1), (x: 0.9, y: 0.1), (x: 0.5, y: 0.5), (x: 0.1, y: 0.9)];
      expect(() => frameToImage(flatBack, (x: 0.5, y: 0.5)), throwsArgumentError);
    });

    test('refuses a folded (bow-tie) quadrilateral', () {
      const bowTie = <NormPoint>[(x: 0.1, y: 0.1), (x: 0.9, y: 0.9), (x: 0.9, y: 0.1), (x: 0.1, y: 0.9)];
      expect(() => frameToImage(bowTie, (x: 0.5, y: 0.5)), throwsArgumentError);
    });

    test('needs four corners', () {
      expect(() => frameToImage(square.sublist(0, 3), (x: 0.5, y: 0.5)), throwsArgumentError);
    });
  });
}
