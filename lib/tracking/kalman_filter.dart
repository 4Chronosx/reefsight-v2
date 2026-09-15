import 'linalg.dart' as linalg;

/// The 0.95-quantile chi-square gating thresholds BoT-SORT uses for
/// Mahalanobis gating, keyed by degrees of freedom.
const Map<int, double> chi2inv95 = {
  1: 3.8415,
  2: 5.9915,
  3: 7.8147,
  4: 9.4877,
  5: 11.070,
  6: 12.592,
  7: 14.067,
  8: 15.507,
  9: 16.919,
};

/// A single Kalman filter state: mean over an 8-dim `(x, y, w, h, vx, vy,
/// vw, vh)` state (bounding-box center, width, height, and their
/// velocities) plus its 8x8 covariance.
class KalmanState {
  KalmanState(this.mean, this.covariance);

  final List<double> mean;
  final linalg.Matrix covariance;
}

/// Constant-velocity Kalman filter for tracking bounding boxes in image
/// space. Direct port of BoT-SORT's `tracker/kalman_filter.py`.
///
/// Where the Python reference uses a Cholesky factorization plus a
/// triangular solve (`update`, `gating_distance`), this port uses a direct
/// matrix inverse (`linalg.invert`) instead — algebraically equivalent for
/// these small, well-conditioned matrices, and simpler to hand-verify.
/// `multi_predict`'s vectorized batch form isn't ported: BoT-SORT added it
/// purely for performance at MOT-benchmark track counts, and this project's
/// per-transect colony counts don't need it — `STrack.predict()` calling
/// `predict()` once per track is behaviorally identical.
class KalmanFilter {
  static const int _ndim = 4;
  static const double _dt = 1.0;
  static const double _stdWeightPosition = 1 / 20;
  static const double _stdWeightVelocity = 1 / 160;

  /// Creates a track from an unassociated `(x, y, w, h)` measurement
  /// (center position, width, height). Velocities start at zero mean.
  KalmanState initiate(List<double> measurement) {
    final meanVel = List<double>.filled(_ndim, 0.0);
    final mean = [...measurement, ...meanVel];

    final std = [
      2 * _stdWeightPosition * measurement[2],
      2 * _stdWeightPosition * measurement[3],
      2 * _stdWeightPosition * measurement[2],
      2 * _stdWeightPosition * measurement[3],
      10 * _stdWeightVelocity * measurement[2],
      10 * _stdWeightVelocity * measurement[3],
      10 * _stdWeightVelocity * measurement[2],
      10 * _stdWeightVelocity * measurement[3],
    ];
    final covariance = linalg.diag([for (final s in std) s * s]);
    return KalmanState(mean, covariance);
  }

  linalg.Matrix _motionMatrix() {
    final m = linalg.identity(2 * _ndim);
    for (var i = 0; i < _ndim; i++) {
      m[i][_ndim + i] = _dt;
    }
    return m;
  }

  linalg.Matrix _updateMatrix() {
    // 4x8: identity in the first 4 columns, zero elsewhere — observes
    // position (x, y, w, h) directly, not velocity.
    final m = linalg.zeros(_ndim, 2 * _ndim);
    for (var i = 0; i < _ndim; i++) {
      m[i][i] = 1.0;
    }
    return m;
  }

  /// Runs the prediction step: advances [state] one time step under the
  /// constant-velocity motion model.
  KalmanState predict(KalmanState state) {
    final mean = state.mean;
    final stdPos = [
      _stdWeightPosition * mean[2],
      _stdWeightPosition * mean[3],
      _stdWeightPosition * mean[2],
      _stdWeightPosition * mean[3],
    ];
    final stdVel = [
      _stdWeightVelocity * mean[2],
      _stdWeightVelocity * mean[3],
      _stdWeightVelocity * mean[2],
      _stdWeightVelocity * mean[3],
    ];
    final motionCov = linalg.diag(
      [for (final s in [...stdPos, ...stdVel]) s * s],
    );

    final motionMat = _motionMatrix();
    final newMean = linalg.matVec(motionMat, mean);
    final newCovariance = linalg.matAdd(
      linalg.matMul(
        linalg.matMul(motionMat, state.covariance),
        linalg.transpose(motionMat),
      ),
      motionCov,
    );
    return KalmanState(newMean, newCovariance);
  }

  /// Projects [state] into measurement space (the observed `(x, y, w, h)`
  /// subspace), adding observation noise.
  KalmanState project(KalmanState state) {
    final mean = state.mean;
    final std = [
      _stdWeightPosition * mean[2],
      _stdWeightPosition * mean[3],
      _stdWeightPosition * mean[2],
      _stdWeightPosition * mean[3],
    ];
    final innovationCov = linalg.diag([for (final s in std) s * s]);

    final updateMat = _updateMatrix();
    final projectedMean = linalg.matVec(updateMat, mean);
    final projectedCov = linalg.matAdd(
      linalg.matMul(
        linalg.matMul(updateMat, state.covariance),
        linalg.transpose(updateMat),
      ),
      innovationCov,
    );
    return KalmanState(projectedMean, projectedCov);
  }

  /// Runs the correction step, folding a new `(x, y, w, h)` [measurement]
  /// into [state].
  KalmanState update(KalmanState state, List<double> measurement) {
    final projected = project(state);
    final updateMat = _updateMatrix();

    // kalmanGain = covariance @ updateMat.T @ inv(projectedCov)
    final gain = linalg.matMul(
      linalg.matMul(state.covariance, linalg.transpose(updateMat)),
      linalg.invert(projected.covariance),
    );

    final innovation = linalg.vecSub(measurement, projected.mean);
    final newMean = linalg.vecAdd(
      state.mean,
      linalg.matVec(gain, innovation),
    );
    final newCovariance = linalg.matSub(
      state.covariance,
      linalg.matMul(
        linalg.matMul(gain, projected.covariance),
        linalg.transpose(gain),
      ),
    );
    return KalmanState(newMean, newCovariance);
  }

  /// Squared Mahalanobis (or, with `metric: 'gaussian'`, plain squared
  /// Euclidean) distance between [state] and each row of [measurements]
  /// (each an `(x, y, w, h)` row). Pass [onlyPosition] to gate on `(x, y)`
  /// alone (2 degrees of freedom instead of 4).
  List<double> gatingDistance(
    KalmanState state,
    List<List<double>> measurements, {
    bool onlyPosition = false,
    String metric = 'maha',
  }) {
    final projected = project(state);
    var mean = projected.mean;
    var covariance = projected.covariance;
    var meas = measurements;

    if (onlyPosition) {
      mean = mean.sublist(0, 2);
      covariance = [covariance[0].sublist(0, 2), covariance[1].sublist(0, 2)];
      meas = [for (final row in measurements) row.sublist(0, 2)];
    }

    if (metric == 'gaussian') {
      return [
        for (final row in meas)
          _sumSquares(linalg.vecSub(row, mean)),
      ];
    } else if (metric == 'maha') {
      final covInv = linalg.invert(covariance);
      return [
        for (final row in meas) _mahalanobisSquared(row, mean, covInv),
      ];
    }
    throw ArgumentError('invalid distance metric: $metric');
  }

  double _sumSquares(List<double> v) {
    var sum = 0.0;
    for (final x in v) {
      sum += x * x;
    }
    return sum;
  }

  double _mahalanobisSquared(
    List<double> row,
    List<double> mean,
    linalg.Matrix covInv,
  ) {
    final d = linalg.vecSub(row, mean);
    final z = linalg.matVec(covInv, d);
    var sum = 0.0;
    for (var i = 0; i < d.length; i++) {
      sum += d[i] * z[i];
    }
    return sum;
  }
}
