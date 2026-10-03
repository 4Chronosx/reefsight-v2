// Sub-plan 08: the tracker configuration the live app runs.
import 'package:flutter_test/flutter_test.dart';
import 'package:reefsight_mobile/tracking/cmc_frames.dart';
import 'package:reefsight_mobile/tracking/tracker_config.dart';

void main() {
  test('build() applies the tuned thresholds and CMC', () {
    final tracker = TrackerConfig.build(updateHz: 8);
    expect(tracker.trackHighThresh, 0.35);
    expect(tracker.trackLowThresh, 0.1);
    expect(tracker.newTrackThresh, 0.6);
    expect(tracker.matchThresh, 0.8);
    expect(tracker.fuseScore, isTrue);
    expect(tracker.cameraMotionCompensator, isA<ScaledFrameCompensator>());
    expect(TrackerConfig.build(updateHz: 8, cmc: false).cameraMotionCompensator, isNull);
  });

  test('trackBuffer is seconds converted at the update rate', () {
    // 3.75 s at the app's 8 Hz is exactly the 30 updates sub-plan 08 tested.
    expect(TrackerConfig.build(updateHz: 8).trackBuffer, 30);
    expect(TrackerConfig.trackBufferFor(5), 19);
    expect(TrackerConfig.trackBufferFor(0.01), 1);
  });
}
