import 'package:flutter_test/flutter_test.dart';
import 'package:reefsight_mobile/tracking/strack.dart';

STrack _activatedTrack(double x1, double y1, double x2, double y2) {
  final t = STrack([x1, y1, x2 - x1, y2 - y1], 0.9);
  t.activate(1);
  return t;
}

void main() {
  setUp(STrack.resetIdCounter);

  group('STrack.applyWarp', () {
    test('identity warp leaves position and size unchanged', () {
      final track = _activatedTrack(10, 20, 30, 60); // tlwh: 10,20,20,40

      track.applyWarp([
        [1.0, 0.0, 0.0],
        [0.0, 1.0, 0.0],
      ]);

      final box = track.tlwh;
      expect(box[0], closeTo(10, 1e-6));
      expect(box[1], closeTo(20, 1e-6));
      expect(box[2], closeTo(20, 1e-6));
      expect(box[3], closeTo(40, 1e-6));
    });

    test('a pure translation shifts position but leaves width/height alone',
        () {
      final track = _activatedTrack(10, 20, 30, 60); // tlwh: 10,20,20,40

      track.applyWarp([
        [1.0, 0.0, 5.0],
        [0.0, 1.0, -3.0],
      ]);

      final box = track.tlwh;
      expect(box[0], closeTo(15, 1e-6)); // 10 + 5
      expect(box[1], closeTo(17, 1e-6)); // 20 - 3
      expect(box[2], closeTo(20, 1e-6)); // unchanged
      expect(box[3], closeTo(40, 1e-6)); // unchanged
    });

    test(
        'a pure-scale warp scales width/height too — matches the reference '
        'exactly, however unintuitive that looks in isolation', () {
      final track = _activatedTrack(0, 0, 20, 40); // center (10,20), w=20,h=40

      track.applyWarp([
        [2.0, 0.0, 0.0],
        [0.0, 2.0, 0.0],
      ]);

      final mean = track.tlwh; // tlwh derived from the doubled center/size
      // Center (10,20) -> (20,40); width/height (20,40) -> (40,80) since the
      // same 2x2 linear part is applied to every (x,y)-shaped pair in the
      // state, per STrack.multi_gmc in the Python reference.
      expect(mean[2], closeTo(40, 1e-6)); // width
      expect(mean[3], closeTo(80, 1e-6)); // height
    });

    test('does nothing to an unactivated (no Kalman state) track', () {
      final track = STrack([10, 20, 20, 40], 0.9); // never activated

      expect(
        () => track.applyWarp([
          [1.0, 0.0, 5.0],
          [0.0, 1.0, 5.0],
        ]),
        returnsNormally,
      );
      expect(track.tlwh, [10, 20, 20, 40]);
    });
  });
}
