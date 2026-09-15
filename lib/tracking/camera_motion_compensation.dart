import 'package:opencv_dart/opencv_dart.dart' as cv;

import 'linalg.dart' as linalg;

/// A single grayscale frame — plain pixel data (row-major, one byte per
/// pixel), decoupled from any specific camera/plugin frame type, matching
/// how [TrackerDetection] stays decoupled from the live detector's output
/// type.
class GrayscaleFrame {
  const GrayscaleFrame({
    required this.width,
    required this.height,
    required this.pixels,
  });

  final int width;
  final int height;

  /// Row-major, single-channel byte data. Length must be `width * height`.
  final List<int> pixels;
}

/// The 2x3 identity affine warp — no estimated camera motion.
linalg.Matrix identityWarp() => [
      [1.0, 0.0, 0.0],
      [0.0, 1.0, 0.0],
    ];

/// Estimates frame-to-frame camera motion as a 2x3 affine warp. Direct port
/// of BoT-SORT's `tracker/gmc.py` `GMC` class's `sparseOptFlow` method — the
/// reference's own default `cmc_method` — using sparse Lucas-Kanade optical
/// flow on `goodFeaturesToTrack` corners, with `estimateAffinePartial2D`'s
/// RANSAC fitting a similarity transform to the surviving correspondences.
///
/// The reference's other methods (`orb`/`sift`/`ecc`/`file`) aren't ported:
/// `sparseOptFlow` is what BoT-SORT actually runs by default, and the
/// sub-plan's cited `VideoCameraCorrection/cmc.cpp` reference instead uses
/// `cv::videostab` APIs that `opencv_dart` doesn't bind (confirmed against
/// its `dartcv` module list: core/imgproc/imgcodecs/calib3d/features2d/
/// video/dnn/objdetect/photo/stitching/videoio/contrib/gapi — no
/// videostab), so it isn't a viable direct-port target here.
class CameraMotionCompensator {
  CameraMotionCompensator({this.downscale = 2});

  /// Frames are downscaled by this factor before feature detection, purely
  /// for speed — the resulting warp's translation is scaled back up before
  /// being returned, so callers always get a warp in original-frame units.
  final int downscale;

  static const _maxCorners = 1000;
  static const _qualityLevel = 0.01;
  static const _minDistance = 1.0;
  static const _blockSize = 3;

  cv.Mat? _prevFrame;
  cv.VecPoint2f? _prevKeyPoints;
  bool _initialized = false;

  /// Estimates the warp from the previously-seen frame to [frame]. Returns
  /// [identityWarp] on the first call (nothing to compare against yet) and
  /// whenever too few correspondences survive to fit a reliable transform —
  /// matching the reference's own fallback behavior ("not enough matching
  /// points").
  linalg.Matrix apply(GrayscaleFrame frame) {
    final fullResMat = cv.Mat.fromList(
      frame.height,
      frame.width,
      cv.MatType.CV_8UC1,
      frame.pixels,
    );
    // `cv.resize` allocates a new Mat rather than resizing in place, so the
    // full-resolution source must be disposed separately once the
    // downscaled copy exists — otherwise it's a leaked native buffer on
    // every call (the default configuration, since downscale defaults to
    // 2).
    final cv.Mat mat;
    if (downscale > 1) {
      mat = cv.resize(
        fullResMat,
        (frame.width ~/ downscale, frame.height ~/ downscale),
      );
      fullResMat.dispose();
    } else {
      mat = fullResMat;
    }

    final keypoints = cv.goodFeaturesToTrack(
      mat,
      _maxCorners,
      _qualityLevel,
      _minDistance,
      blockSize: _blockSize,
    );

    if (!_initialized) {
      _prevFrame = mat;
      _prevKeyPoints = keypoints;
      _initialized = true;
      return identityWarp();
    }

    var warp = identityWarp();
    final prevKeyPoints = _prevKeyPoints!;
    if (prevKeyPoints.isNotEmpty) {
      final (nextPts, status, err) = cv.calcOpticalFlowPyrLK(
        _prevFrame!,
        mat,
        prevKeyPoints,
        cv.VecPoint2f(),
      );

      final prevPoints = <cv.Point2f>[];
      final currPoints = <cv.Point2f>[];
      for (var i = 0; i < status!.length; i++) {
        if (status[i] != 0) {
          prevPoints.add(prevKeyPoints[i]);
          currPoints.add(nextPts[i]);
        }
      }
      nextPts.dispose();
      status.dispose();
      err?.dispose();

      if (prevPoints.length > 4) {
        final prevVec = cv.VecPoint2f.fromList(prevPoints);
        final currVec = cv.VecPoint2f.fromList(currPoints);
        final (affine, inliers) = cv.estimateAffinePartial2D(
          prevVec,
          currVec,
        );
        prevVec.dispose();
        currVec.dispose();
        if (affine.rows == 2 && affine.cols == 3) {
          warp = [
            [
              affine.at<double>(0, 0),
              affine.at<double>(0, 1),
              affine.at<double>(0, 2) * downscale,
            ],
            [
              affine.at<double>(1, 0),
              affine.at<double>(1, 1),
              affine.at<double>(1, 2) * downscale,
            ],
          ];
        }
        affine.dispose();
        inliers.dispose();
      }
    }

    _prevFrame!.dispose();
    _prevKeyPoints!.dispose();
    _prevFrame = mat;
    _prevKeyPoints = keypoints;

    return warp;
  }

  /// Releases the native-backed previous-frame state. Call when done
  /// tracking (e.g. end of a transect session).
  void dispose() {
    _prevFrame?.dispose();
    _prevKeyPoints?.dispose();
    _prevFrame = null;
    _prevKeyPoints = null;
    _initialized = false;
  }
}
