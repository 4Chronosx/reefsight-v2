import 'package:flutter_test/flutter_test.dart';
import 'package:reefsight_mobile/tracking/matching.dart';
import 'package:reefsight_mobile/tracking/strack.dart';

STrack _track(double x1, double y1, double x2, double y2, {double score = 0.9}) {
  final t = STrack([x1, y1, x2 - x1, y2 - y1], score);
  t.activate(1);
  return t;
}

void main() {
  setUp(STrack.resetIdCounter);

  group('iouDistance', () {
    test('is 0 (cost) for identical boxes', () {
      final a = _track(0, 0, 10, 10);
      final b = _track(0, 0, 10, 10);
      expect(iouDistance([a], [b])[0][0], closeTo(0.0, 1e-9));
    });

    test('is 1 (cost) for non-overlapping boxes', () {
      final a = _track(0, 0, 10, 10);
      final b = _track(100, 100, 110, 110);
      expect(iouDistance([a], [b])[0][0], closeTo(1.0, 1e-9));
    });

    test('is between 0 and 1 for partially overlapping boxes', () {
      final a = _track(0, 0, 10, 10);
      final b = _track(5, 5, 15, 15);
      final cost = iouDistance([a], [b])[0][0];
      expect(cost, greaterThan(0.0));
      expect(cost, lessThan(1.0));
    });
  });

  group('fuseScore', () {
    test('worsens cost for a low-confidence detection', () {
      final a = _track(0, 0, 10, 10);
      final highConf = _track(0, 0, 10, 10, score: 0.95);
      final lowConf = _track(0, 0, 10, 10, score: 0.2);

      final costHigh = fuseScore(iouDistance([a], [highConf]), [highConf])[0][0];
      final costLow = fuseScore(iouDistance([a], [lowConf]), [lowConf])[0][0];

      expect(costLow, greaterThan(costHigh));
    });
  });

  group('linearAssignment', () {
    test('matches the lowest-cost pairing across rows and columns', () {
      // Row 0 prefers col 1, row 1 prefers col 0 — a naive greedy scan
      // would double-book col 0 or col 1; the optimal assignment doesn't.
      final cost = [
        [0.9, 0.1],
        [0.2, 0.8],
      ];
      final result = linearAssignment(cost, 0.95);

      expect(result.matches.toSet(), {
        [0, 1],
        [1, 0],
      });
      expect(result.unmatchedA, isEmpty);
      expect(result.unmatchedB, isEmpty);
    });

    test('rejects a pairing whose cost exceeds the threshold', () {
      final cost = [
        [0.9],
      ];
      final result = linearAssignment(cost, 0.5);

      expect(result.matches, isEmpty);
      expect(result.unmatchedA, [0]);
      expect(result.unmatchedB, [0]);
    });

    test('handles an empty cost matrix', () {
      final result = linearAssignment(const [], 0.5);
      expect(result.matches, isEmpty);
      expect(result.unmatchedA, isEmpty);
      expect(result.unmatchedB, isEmpty);
    });

    test('leaves extra rows/columns unmatched on a rectangular matrix', () {
      final cost = [
        [0.1, 0.9, 0.9],
        [0.9, 0.9, 0.9],
      ];
      final result = linearAssignment(cost, 0.5);

      expect(result.matches, [
        [0, 0],
      ]);
      expect(result.unmatchedA, [1]);
      expect(result.unmatchedB, [1, 2]);
    });
  });

  group('jointTracks / subTracks', () {
    test('jointTracks de-duplicates by track id, preferring the first list',
        () {
      final a = _track(0, 0, 10, 10);
      final b = _track(50, 50, 60, 60);
      final dupOfA = _track(0, 0, 10, 10);
      dupOfA.trackId = a.trackId;

      final result = jointTracks([a], [b, dupOfA]);
      expect(result.map((t) => t.trackId).toSet(), {a.trackId, b.trackId});
      expect(result.length, 2);
    });

    test('subTracks removes tracks present in the second list by id', () {
      final a = _track(0, 0, 10, 10);
      final b = _track(50, 50, 60, 60);
      final result = subTracks([a, b], [b]);
      expect(result, [a]);
    });
  });

  group('removeDuplicateTracks', () {
    test('drops the shorter-lived track when two tracks nearly overlap', () {
      final older = _track(0, 0, 10, 10)
        ..startFrame = 1
        ..frameId = 10;
      final newer = _track(0.1, 0.1, 10.1, 10.1)
        ..startFrame = 8
        ..frameId = 10;

      final (resA, resB) = removeDuplicateTracks([older], [newer]);
      expect(resA, [older]);
      expect(resB, isEmpty);
    });
  });
}
