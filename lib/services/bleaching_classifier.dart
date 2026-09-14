import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart' show compute, debugPrint;
import 'package:image/image.dart' as img;
import 'package:ultralytics_yolo/ultralytics_yolo.dart';

import 'crop_geometry.dart';

/// Crop + resize job handed to [compute] so the CPU-bound decode/crop/resize
/// pass runs on a background isolate instead of blocking the UI isolate that
/// `onStreamingData` callbacks (and overlay rebuilds) run on.
typedef _CropJob = ({
  Uint8List frameBytes,
  int left,
  int top,
  int width,
  int height,
});

/// Must stay a top-level (or static) function with no captured state —
/// [compute] runs it on a separate isolate.
Uint8List _cropAndResizeToJpeg(_CropJob job) {
  final frame = img.decodeImage(job.frameBytes);
  if (frame == null) return Uint8List(0);

  final cropped = img.copyCrop(
    frame,
    x: job.left,
    y: job.top,
    width: job.width,
    height: job.height,
  );
  final resized = img.copyResize(cropped, width: 224, height: 224);
  return Uint8List.fromList(img.encodeJpg(resized));
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
/// [classifyCrop] takes the frame the box was detected in and the box
/// itself, nothing else.
class BleachingClassifier {
  BleachingClassifier({required String modelAssetPath})
    : _yolo = YOLO(
        modelPath: modelAssetPath,
        task: YOLOTask.classify,
        useMultiInstance: true,
      );

  final YOLO _yolo;
  bool _isReady = false;

  // Tracks the in-flight classifyCrop call (if any) so dispose() can wait
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

  /// Crops [frameJpegBytes] to [boxPixels], resizes to the classifier's
  /// 224x224 training resolution, and classifies the crop. Returns null if
  /// the classifier isn't loaded yet, the frame can't be decoded, the native
  /// side returns no classification for this crop, or inference fails.
  Future<ColonyHealth?> classifyCrop(
    Uint8List frameJpegBytes,
    Rect boxPixels, {
    required int frameWidth,
    required int frameHeight,
  }) {
    if (!_isReady) return Future.value(null);

    final future = _classifyCrop(
      frameJpegBytes,
      boxPixels,
      frameWidth: frameWidth,
      frameHeight: frameHeight,
    );
    _pendingCall = future.then((_) {}, onError: (_) {});
    return future;
  }

  Future<ColonyHealth?> _classifyCrop(
    Uint8List frameJpegBytes,
    Rect boxPixels, {
    required int frameWidth,
    required int frameHeight,
  }) async {
    try {
      final region = computeCropRegion(
        boxPixels,
        frameWidth: frameWidth,
        frameHeight: frameHeight,
      );

      // Decode/crop/resize/encode is CPU-bound work on a full camera frame —
      // runs on a background isolate so it never blocks the UI isolate that
      // onStreamingData callbacks and overlay rebuilds run on.
      final jpegBytes = await compute(_cropAndResizeToJpeg, (
        frameBytes: frameJpegBytes,
        left: region.left,
        top: region.top,
        width: region.width,
        height: region.height,
      ));
      if (jpegBytes.isEmpty) return null;

      final result = await _yolo.predict(jpegBytes);
      final detections = (result['detections'] as List?)
          ?.whereType<Map>()
          .map(YOLOResult.fromMap)
          .toList(growable: false);
      if (detections == null || detections.isEmpty) return null;

      final top = detections.first;
      return ColonyHealth(label: top.className, confidence: top.confidence);
    } catch (e) {
      debugPrint('BleachingClassifier: classifyCrop failed: $e');
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
