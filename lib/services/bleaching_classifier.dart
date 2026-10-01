import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart' show compute, debugPrint;
import 'package:image/image.dart' as img;
import 'package:ultralytics_yolo/ultralytics_yolo.dart';

import 'crop_geometry.dart';

/// Crop + resize job handed to [compute] so the CPU-bound decode/crop/resize
/// pass runs on a background isolate instead of blocking the UI isolate that
/// `onStreamingData` callbacks (and overlay rebuilds) run on. One job covers
/// every region of a frame, so the full camera frame is decoded once per
/// batch rather than once per colony (sub-plan 09, step 3).
typedef _BatchCropJob = ({
  Uint8List frameBytes,
  List<({int left, int top, int width, int height})> regions,
});

/// Must stay a top-level (or static) function with no captured state —
/// [compute] runs it on a separate isolate. Returns one 224x224 JPEG per
/// region, or an empty list if the frame can't be decoded.
List<Uint8List> _cropAndResizeAllToJpeg(_BatchCropJob job) {
  final frame = img.decodeImage(job.frameBytes);
  if (frame == null) return const [];

  return [
    for (final region in job.regions)
      Uint8List.fromList(
        img.encodeJpg(
          img.copyResize(
            img.copyCrop(
              frame,
              x: region.left,
              y: region.top,
              width: region.width,
              height: region.height,
            ),
            width: 224,
            height: 224,
            // Crop spec v1 step 6 (sub-plan 10): bilinear, JPEG q95 -- the
            // same resampling ML sub-plan 2 harvests training crops with.
            interpolation: img.Interpolation.linear,
          ),
          quality: 95,
        ),
      ),
  ];
}

/// Health label + confidence for one classified colony crop.
class ColonyHealth {
  const ColonyHealth({required this.label, required this.confidence});

  final String label;
  final double confidence;
}

/// Wraps the NMFS-OSI bleaching classifier as its own [YOLO] instance
/// (task: classify), independent of the live segmentation [YOLOView]
/// pipeline.
///
/// Per Spec Phase C "Per-colony decisions": the crop comes directly from the
/// segmentation model's own box, so there is no separate matching step —
/// [classifyBatch] takes the frame the boxes were detected in and the boxes
/// themselves, nothing else.
class BleachingClassifier {
  BleachingClassifier({required String modelAssetPath})
    : _yolo = YOLO(
        modelPath: modelAssetPath,
        task: YOLOTask.classify,
        useMultiInstance: true,
      );

  final YOLO _yolo;
  bool _isReady = false;

  // Tracks the in-flight classifyBatch call (if any) so dispose() can wait
  // for it instead of tearing down the native instance mid-inference.
  Future<void>? _pendingCall;

  bool get isReady => _isReady;

  Future<void> load() async {
    try {
      _isReady = await _yolo.loadModel();
    } catch (e) {
      _isReady = false;
      debugPrint('BleachingClassifier: loadModel failed: $e');
      rethrow;
    }
  }

  /// Crops [frameJpegBytes] to each of [boxesPixels], resizes each crop to
  /// the classifier's 224x224 training resolution, and classifies them in
  /// turn. Returns one result per box, `null` where the classifier isn't
  /// loaded yet, the frame can't be decoded, the native side returns no
  /// classification for that crop, or inference fails. Never throws.
  Future<List<ColonyHealth?>> classifyBatch(
    Uint8List frameJpegBytes,
    List<Rect> boxesPixels, {
    required int frameWidth,
    required int frameHeight,
  }) {
    if (!_isReady || boxesPixels.isEmpty) {
      return Future.value(List.filled(boxesPixels.length, null));
    }

    final future = _classifyBatch(
      frameJpegBytes,
      boxesPixels,
      frameWidth: frameWidth,
      frameHeight: frameHeight,
    );
    _pendingCall = future.then((_) {}, onError: (_) {});
    return future;
  }

  Future<List<ColonyHealth?>> _classifyBatch(
    Uint8List frameJpegBytes,
    List<Rect> boxesPixels, {
    required int frameWidth,
    required int frameHeight,
  }) async {
    final results = List<ColonyHealth?>.filled(boxesPixels.length, null);

    List<Uint8List> crops;
    try {
      // Decode/crop/resize/encode is CPU-bound work on a full camera frame —
      // runs on a background isolate so it never blocks the UI isolate that
      // onStreamingData callbacks and overlay rebuilds run on.
      crops = await compute(_cropAndResizeAllToJpeg, (
        frameBytes: frameJpegBytes,
        regions: [
          for (final box in boxesPixels)
            _region(box, frameWidth: frameWidth, frameHeight: frameHeight),
        ],
      ));
    } catch (e) {
      debugPrint('BleachingClassifier: crop batch failed: $e');
      return results;
    }

    for (var i = 0; i < crops.length && i < results.length; i++) {
      results[i] = await _predict(crops[i]);
    }
    return results;
  }

  static ({int left, int top, int width, int height}) _region(
    Rect box, {
    required int frameWidth,
    required int frameHeight,
  }) {
    final r = computeCropRegion(
      box,
      frameWidth: frameWidth,
      frameHeight: frameHeight,
    );
    return (left: r.left, top: r.top, width: r.width, height: r.height);
  }

  Future<ColonyHealth?> _predict(Uint8List jpegBytes) async {
    try {
      final result = await _yolo.predict(jpegBytes);
      final detections = (result['detections'] as List?)
          ?.whereType<Map>()
          .map(YOLOResult.fromMap)
          .toList(growable: false);
      if (detections == null || detections.isEmpty) return null;

      final top = detections.first;
      return ColonyHealth(label: top.className, confidence: top.confidence);
    } catch (e) {
      debugPrint('BleachingClassifier: predict failed for one crop: $e');
      return null;
    }
  }

  Future<void> dispose() async {
    // Let any in-flight predict() finish before tearing down the native
    // instance it's running on.
    if (_pendingCall != null) await _pendingCall;
    await _yolo.dispose();
  }
}
