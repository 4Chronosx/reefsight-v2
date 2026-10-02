import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart' show compute, debugPrint, visibleForTesting;
import 'package:image/image.dart' as img;
import 'package:ultralytics_yolo/ultralytics_yolo.dart';

import 'crop_geometry.dart';

/// An integer pixel region of a frame, as [cutColonyImages] crops it.
typedef PixelRegion = ({int left, int top, int width, int height});

/// Crop + resize job handed to [compute] so the CPU-bound decode/crop/resize
/// pass runs on a background isolate instead of blocking the UI isolate that
/// `onStreamingData` callbacks (and overlay rebuilds) run on. One job covers
/// every region of a frame, so the full camera frame is decoded once per
/// batch rather than once per colony (sub-plan 09, step 3).
///
/// [contexts] is parallel to [regions]: the context photo's region for each
/// colony (sub-plan 18), `null` where none is wanted.
typedef ColonyCropJob = ({
  Uint8List frameBytes,
  List<PixelRegion> regions,
  List<PixelRegion?> contexts,
});

/// The images [cutColonyImages] cuts for one region: the classifier's exact
/// 224x224 input, and the context photo people look at (sub-plan 18).
typedef ColonyImages = ({Uint8List crop, Uint8List? context});

/// Longest side of a context photo, in pixels (sub-plan 18 decision 1).
const int contextPhotoLongSide = 320;

/// Must stay a top-level (or static) function with no captured state --
/// [compute] runs it on a separate isolate. Returns one entry per region,
/// or an empty list if the frame can't be decoded. A context photo that
/// fails to encode is `null`; the classifier crop is still returned.
@visibleForTesting
List<ColonyImages> cutColonyImages(ColonyCropJob job) {
  img.Image? frame;
  try {
    frame = img.decodeImage(job.frameBytes);
  } catch (_) {
    // `decodeImage` can throw on truncated bytes rather than return null.
  }
  if (frame == null) return const [];

  return [
    for (var i = 0; i < job.regions.length; i++)
      (
        crop: Uint8List.fromList(
          img.encodeJpg(
            img.copyResize(
              _copy(frame, job.regions[i]),
              width: 224,
              height: 224,
              // Crop spec v1 step 6 (sub-plan 10): bilinear, JPEG q95 -- the
              // same resampling ML sub-plan 2 harvests training crops with.
              interpolation: img.Interpolation.linear,
            ),
            quality: 95,
          ),
        ),
        context: i < job.contexts.length ? _contextJpeg(frame, job.contexts[i]) : null,
      ),
  ];
}

img.Image _copy(img.Image frame, PixelRegion region) => img.copyCrop(
  frame,
  x: region.left,
  y: region.top,
  width: region.width,
  height: region.height,
);

/// The context photo for [region]: longest side [contextPhotoLongSide],
/// aspect kept, JPEG q85 (sub-plan 18 decision 1).
Uint8List? _contextJpeg(img.Image frame, PixelRegion? region) {
  if (region == null) return null;
  try {
    final scale = contextPhotoLongSide / math.max(region.width, region.height);
    return Uint8List.fromList(
      img.encodeJpg(
        img.copyResize(
          _copy(frame, region),
          width: math.max(1, (region.width * scale).round()),
          height: math.max(1, (region.height * scale).round()),
          interpolation: img.Interpolation.linear,
        ),
        quality: 85,
      ),
    );
  } catch (_) {
    return null;
  }
}

/// Health label + confidence for one classified colony crop.
class ColonyHealth {
  const ColonyHealth({required this.label, required this.confidence});

  final String label;
  final double confidence;
}

/// One colony's classification, with the images it came from (sub-plan 18):
/// [crop] is the exact 224x224 classifier input, [context] the wider photo.
/// Either image is `null` if it couldn't be cut or wasn't asked for.
class ClassifiedCrop {
  const ClassifiedCrop({required this.health, this.crop, this.context});

  final ColonyHealth health;
  final Uint8List? crop;
  final Uint8List? context;
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
  ///
  /// [contextBoxes], parallel to [boxesPixels], are the detection boxes the
  /// context photos are cut around (grown x1.5, sub-plan 18); a missing or
  /// `null` entry means no context photo for that box.
  Future<List<ClassifiedCrop?>> classifyBatch(
    Uint8List frameJpegBytes,
    List<Rect> boxesPixels, {
    required int frameWidth,
    required int frameHeight,
    List<Rect?>? contextBoxes,
  }) {
    if (!_isReady || boxesPixels.isEmpty) {
      return Future.value(List.filled(boxesPixels.length, null));
    }

    final future = _classifyBatch(
      frameJpegBytes,
      boxesPixels,
      contextBoxes ?? const [],
      frameWidth: frameWidth,
      frameHeight: frameHeight,
    );
    _pendingCall = future.then((_) {}, onError: (_) {});
    return future;
  }

  Future<List<ClassifiedCrop?>> _classifyBatch(
    Uint8List frameJpegBytes,
    List<Rect> boxesPixels,
    List<Rect?> contextBoxes, {
    required int frameWidth,
    required int frameHeight,
  }) async {
    final results = List<ClassifiedCrop?>.filled(boxesPixels.length, null);

    List<ColonyImages> images;
    try {
      // Decode/crop/resize/encode is CPU-bound work on a full camera frame —
      // runs on a background isolate so it never blocks the UI isolate that
      // onStreamingData callbacks and overlay rebuilds run on.
      images = await compute(cutColonyImages, (
        frameBytes: frameJpegBytes,
        regions: [
          for (final box in boxesPixels)
            _region(
              computeCropRegion(box, frameWidth: frameWidth, frameHeight: frameHeight),
            ),
        ],
        contexts: [
          for (var i = 0; i < boxesPixels.length; i++)
            i < contextBoxes.length && contextBoxes[i] != null
                ? _region(
                    computeContextRegion(
                      contextBoxes[i]!,
                      frameWidth: frameWidth,
                      frameHeight: frameHeight,
                    ),
                  )
                : null,
        ],
      ));
    } catch (e) {
      debugPrint('BleachingClassifier: crop batch failed: $e');
      return results;
    }

    for (var i = 0; i < images.length && i < results.length; i++) {
      final health = await _predict(images[i].crop);
      if (health == null) continue;
      results[i] = ClassifiedCrop(
        health: health,
        crop: images[i].crop,
        context: images[i].context,
      );
    }
    return results;
  }

  static PixelRegion _region(CropRegion r) =>
      (left: r.left, top: r.top, width: r.width, height: r.height);

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
