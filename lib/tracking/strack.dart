import 'kalman_filter.dart';
import 'linalg.dart' as linalg;
import 'track_state.dart';

/// A single tracked colony's motion state. Direct port of BoT-SORT's
/// `STrack`, with the Re-ID fields (`feat`/`curr_feat`/`smooth_feat`/
/// `features`/`update_features`) removed — this port has no appearance
/// embeddings (see `ReefSight_Development_Plan.md` Track 2).
class STrack {
  STrack(this._tlwh, this.score);

  static int _nextId = 1;

  /// Resets the shared id counter. Call between independent tracking runs
  /// (e.g. at the start of each test, or a new transect session) so ids
  /// restart at 1, matching the reference's `BaseTrack.clear_count()`.
  static void resetIdCounter() => _nextId = 1;

  final List<double> _tlwh;
  double score;

  int trackId = 0;
  bool isActivated = false;
  TrackState state = TrackState.tracked;

  int frameId = 0;
  int startFrame = 0;
  int trackletLen = 0;

  KalmanState? _kalmanState;
  final KalmanFilter _kf = KalmanFilter();

  static List<double> _tlwhToXywh(List<double> tlwh) => [
        tlwh[0] + tlwh[2] / 2,
        tlwh[1] + tlwh[3] / 2,
        tlwh[2],
        tlwh[3],
      ];

  /// Current position as `(top-left x, top-left y, width, height)`.
  List<double> get tlwh {
    final mean = _kalmanState?.mean;
    if (mean == null) return [..._tlwh];
    return [mean[0] - mean[2] / 2, mean[1] - mean[3] / 2, mean[2], mean[3]];
  }

  /// Current position as `(x1, y1, x2, y2)`.
  List<double> get tlbr {
    final box = tlwh;
    return [box[0], box[1], box[0] + box[2], box[1] + box[3]];
  }

  int get endFrame => frameId;

  /// Runs one Kalman prediction step. Non-`tracked` (i.e. lost) tracks are
  /// predicted with velocity zeroed, matching the reference's handling of
  /// stale tracks (it doesn't trust a lost track's last-known velocity).
  void predict() {
    final current = _kalmanState;
    if (current == null) return;
    final mean = [...current.mean];
    if (state != TrackState.tracked) {
      mean[6] = 0;
      mean[7] = 0;
    }
    _kalmanState = _kf.predict(KalmanState(mean, current.covariance));
  }

  /// Starts a new tracklet at [frameId].
  void activate(int frameId) {
    trackId = _nextId++;
    _kalmanState = _kf.initiate(_tlwhToXywh(_tlwh));
    trackletLen = 0;
    state = TrackState.tracked;
    if (frameId == 1) isActivated = true;
    this.frameId = frameId;
    startFrame = frameId;
  }

  /// Re-activates a lost track with a new detection, optionally assigning a
  /// fresh id (the reference always passes `new_id=False` on its only call
  /// site, so [newId] defaults to `false`).
  void reActivate(STrack newTrack, int frameId, {bool newId = false}) {
    _kalmanState = _kf.update(_kalmanState!, _tlwhToXywh(newTrack.tlwh));
    trackletLen = 0;
    state = TrackState.tracked;
    isActivated = true;
    this.frameId = frameId;
    if (newId) trackId = _nextId++;
    score = newTrack.score;
  }

  /// Folds a matched detection into this track.
  void update(STrack newTrack, int frameId) {
    this.frameId = frameId;
    trackletLen++;
    _kalmanState = _kf.update(_kalmanState!, _tlwhToXywh(newTrack.tlwh));
    state = TrackState.tracked;
    isActivated = true;
    score = newTrack.score;
  }

  void markLost() => state = TrackState.lost;
  void markRemoved() => state = TrackState.removed;

  /// Applies a camera-motion warp (2x3 affine matrix) to this track's
  /// Kalman state. Direct port of `STrack.multi_gmc`'s per-track math: the
  /// warp's 2x2 linear part is applied identically to each `(x, y)`-shaped
  /// pair in the 8-dim state — position, size, velocity, and size-velocity
  /// — and only the translation is added to position. Applying a rotation
  /// to a width/height pair looks unintuitive in isolation, but this
  /// matches the reference exactly rather than "fixing" it.
  void applyWarp(linalg.Matrix warp) {
    final current = _kalmanState;
    if (current == null) return;

    final r00 = warp[0][0], r01 = warp[0][1];
    final r10 = warp[1][0], r11 = warp[1][1];
    final tx = warp[0][2], ty = warp[1][2];

    final mean = current.mean;
    final newMean = List<double>.filled(8, 0.0);
    for (var block = 0; block < 4; block++) {
      final i = block * 2;
      newMean[i] = r00 * mean[i] + r01 * mean[i + 1];
      newMean[i + 1] = r10 * mean[i] + r11 * mean[i + 1];
    }
    newMean[0] += tx;
    newMean[1] += ty;

    // R8x8 is block-diagonal with the warp's 2x2 linear part repeated 4
    // times (`np.kron(np.eye(4), R)` in the reference); newCovariance =
    // R8x8 @ covariance @ R8x8.T.
    final r8x8 = linalg.zeros(8, 8);
    for (var block = 0; block < 4; block++) {
      final i = block * 2;
      r8x8[i][i] = r00;
      r8x8[i][i + 1] = r01;
      r8x8[i + 1][i] = r10;
      r8x8[i + 1][i + 1] = r11;
    }
    final newCovariance = linalg.matMul(
      linalg.matMul(r8x8, current.covariance),
      linalg.transpose(r8x8),
    );

    _kalmanState = KalmanState(newMean, newCovariance);
  }
}
