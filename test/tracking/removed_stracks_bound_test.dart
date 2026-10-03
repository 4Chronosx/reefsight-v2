// Sub-plan 08 step 5: `BoTSortTracker._removedStracks` must stay bounded over a long transect
// without changing a single output. The golden file was recorded from the tracker *before* the
// bound existed (unbounded list, as in the Python reference), on test/tracking/long_sequence.dart.
// The 4 reference-parity fixtures (reference_parity_test.dart) must keep passing as well.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reefsight_mobile/tracking/bot_sort_tracker.dart';

import 'long_sequence.dart';

void main() {
  final golden = jsonDecode(
    File('test/tracking/golden/removed_stracks_long_sequence.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final expectedFrames = (golden['frames'] as List<dynamic>).cast<List<dynamic>>();

  test('output is identical to the unbounded tracker on a long, adversarial sequence', () {
    final tracker = BoTSortTracker(trackBuffer: longSequenceTrackBuffer);
    final frames = buildLongSequence();
    expect(frames, hasLength(expectedFrames.length));
    for (var i = 0; i < frames.length; i++) {
      final actual = [
        for (final t in tracker.update(frames[i])) [t.trackId, ...t.tlbr],
      ];
      final expected = [
        for (final t in expectedFrames[i].cast<List<dynamic>>()) [for (final v in t) v as num],
      ];
      expect(actual, expected, reason: 'frame ${i + 1}');
    }
  });

  test('the re-found-then-lost-again edge case still gets a new id (stale removed entry kept)', () {
    // Frame 9: re-found while already in the removed list (keeps id 1). Frame 13: lost again and
    // dropped at once because of that stale entry, so frame 14 must start a new id.
    final tracker = BoTSortTracker(trackBuffer: longSequenceTrackBuffer);
    final frames = buildLongSequence();
    final idsOn = <int, List<int>>{};
    for (var i = 0; i < 14; i++) {
      idsOn[i + 1] = [for (final t in tracker.update(frames[i])) t.trackId];
    }
    expect(idsOn[9], contains(1));
    expect(idsOn[14], isNot(contains(1)));
  });

  test('the removed list stays bounded by the live tracks', () {
    final tracker = BoTSortTracker(trackBuffer: longSequenceTrackBuffer);
    var maxRemoved = 0;
    for (final dets in buildLongSequence()) {
      tracker.update(dets);
      if (tracker.removedTrackCount > maxRemoved) maxRemoved = tracker.removedTrackCount;
    }
    // Unbounded, it ends at golden['unbounded_removed_count_at_end'] (203) and only ever grows.
    expect(golden['unbounded_removed_count_at_end'], greaterThan(100));
    expect(maxRemoved, lessThan(30));
  });
}
