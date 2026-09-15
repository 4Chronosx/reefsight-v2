import 'package:flutter_test/flutter_test.dart';
import 'package:reefsight_mobile/tracking/kalman_filter.dart';

void main() {
  group('KalmanFilter.initiate', () {
    test('sets zero-mean velocity and position/size-scaled covariance', () {
      final kf = KalmanFilter();
      final state = kf.initiate([10, 20, 4, 8]);

      expect(state.mean, [10, 20, 4, 8, 0, 0, 0, 0]);
      // std = 2 * (1/20) * [w, h, w, h] for position, 10 * (1/160) * [w,h,w,h]
      // for velocity — squared on the diagonal.
      expect(state.covariance[0][0], closeTo(0.16, 1e-9)); // (0.4)^2
      expect(state.covariance[1][1], closeTo(0.64, 1e-9)); // (0.8)^2
      expect(state.covariance[4][4], closeTo(0.0625, 1e-9)); // (0.25)^2
      // Off-diagonal entries are all zero.
      expect(state.covariance[0][1], closeTo(0.0, 1e-12));
    });
  });

  group('KalmanFilter.predict', () {
    test('leaves position unchanged when velocity is zero', () {
      final kf = KalmanFilter();
      final state = kf.initiate([10, 20, 4, 8]);
      final predicted = kf.predict(state);

      expect(predicted.mean.sublist(0, 4), [10, 20, 4, 8]);
      expect(predicted.mean.sublist(4, 8), [0, 0, 0, 0]);
    });

    test('grows positional uncertainty (adds process noise)', () {
      final kf = KalmanFilter();
      final state = kf.initiate([10, 20, 4, 8]);
      final predicted = kf.predict(state);

      // Position variance can only grow: the motion-coupling term folds in
      // the (zero-mean) velocity variance, plus fresh process noise is added
      // on top.
      expect(predicted.covariance[0][0], greaterThan(state.covariance[0][0]));
      expect(predicted.covariance[1][1], greaterThan(state.covariance[1][1]));
    });

    test('advances position by velocity on a moving track', () {
      final kf = KalmanFilter();
      var state = kf.initiate([10, 20, 4, 8]);
      // A single update with no prior predict() can't move the mean's
      // velocity terms: initiate()'s covariance is diagonal (zero
      // position/velocity correlation), so the Kalman gain for the
      // velocity rows is exactly zero on that first correction. A predict()
      // step must run first to fold position/velocity correlation into the
      // covariance (via the motion model) before an update can back-infer
      // velocity from a position innovation.
      state = kf.predict(state);
      // Fold in a measurement 2px to the right to give the track velocity.
      state = kf.update(state, [12, 20, 4, 8]);
      final predicted = kf.predict(state);

      expect(predicted.mean[0], greaterThan(state.mean[0]));
    });
  });

  group('KalmanFilter.update', () {
    test('leaves the mean unchanged when the measurement matches exactly',
        () {
      final kf = KalmanFilter();
      final state = kf.initiate([10, 20, 4, 8]);
      final predicted = kf.predict(state);
      // Measurement equals the predicted position exactly — zero
      // innovation, so the correction step is a no-op on the mean
      // regardless of the Kalman gain.
      final updated = kf.update(predicted, predicted.mean.sublist(0, 4));

      for (var i = 0; i < 8; i++) {
        expect(updated.mean[i], closeTo(predicted.mean[i], 1e-9));
      }
    });

    test('shrinks uncertainty after a correction', () {
      final kf = KalmanFilter();
      final state = kf.initiate([10, 20, 4, 8]);
      final predicted = kf.predict(state);
      final updated = kf.update(predicted, [10, 20, 4, 8]);

      expect(updated.covariance[0][0], lessThan(predicted.covariance[0][0]));
    });
  });

  group('KalmanFilter.gatingDistance', () {
    test('is zero for a measurement matching the projected mean exactly',
        () {
      final kf = KalmanFilter();
      final state = kf.initiate([10, 20, 4, 8]);

      final distances = kf.gatingDistance(state, [
        [10, 20, 4, 8],
      ]);

      expect(distances.single, closeTo(0.0, 1e-9));
    });

    test('increases with distance from the mean', () {
      final kf = KalmanFilter();
      final state = kf.initiate([10, 20, 4, 8]);

      final distances = kf.gatingDistance(state, [
        [10, 20, 4, 8],
        [50, 60, 4, 8],
      ]);

      expect(distances[1], greaterThan(distances[0]));
    });
  });
}
