import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';

import '../services/bleaching_classifier.dart';
import '../services/model_assets.dart';

/// Live segmentation + crop-and-classify screen.
///
/// Wires the two models as independent pipelines: `YOLOView` streams
/// `coralvos_primary` segmentation live (native overlay + `onStreamingData`),
/// and a separate [BleachingClassifier] instance classifies a crop of the
/// top detection per frame. There is no tracker here — that's sub-plan 3
/// (`mobile/sub-plans/03-crop-classify-and-tracking.md`); this screen only
/// has to prove the segment -> crop -> classify chain works end to end and
/// that neither model blocks the other.
class LiveTransectScreen extends StatefulWidget {
  const LiveTransectScreen({super.key});

  @override
  State<LiveTransectScreen> createState() => _LiveTransectScreenState();
}

class _LiveTransectScreenState extends State<LiveTransectScreen> {
  final _classifier = BleachingClassifier(
    modelAssetPath: ModelAssets.nmfsOsiBleachingClassifier,
  );

  // Compute-budget guard (Spec Open Item #1 / sub-plan's flagged risk): never
  // let classify calls queue up behind the live segmentation stream. A frame
  // is simply skipped for classification while the previous crop is still
  // being classified.
  bool _isClassifying = false;

  ColonyHealth? _latestHealth;
  double? _segProcessingMs;
  int? _classifyLatencyMs;
  String? _segmentationError;

  @override
  void initState() {
    super.initState();
    _classifier.load().catchError((Object error) {
      debugPrint('ReefSight: classifier failed to load: $error');
    });
  }

  @override
  void dispose() {
    _classifier.dispose();
    super.dispose();
  }

  void _handleStreamingData(Map<String, dynamic> event) async {
    final segProcessingMs = (event['processingTimeMs'] as num?)?.toDouble();
    if (segProcessingMs != null && mounted) {
      setState(() => _segProcessingMs = segProcessingMs);
    }

    if (_isClassifying) return;

    final detectionsRaw = event['detections'] as List<dynamic>?;
    final frameBytes = event['originalImage'] as Uint8List?;
    final frameWidth = event['imageWidth'] as int?;
    final frameHeight = event['imageHeight'] as int?;
    if (detectionsRaw == null ||
        detectionsRaw.isEmpty ||
        frameBytes == null ||
        frameWidth == null ||
        frameHeight == null) {
      return;
    }

    final detections = detectionsRaw
        .whereType<Map>()
        .map(YOLOResult.fromMap)
        .toList(growable: false);
    if (detections.isEmpty) return;

    // Highest-confidence colony in this frame — no tracker yet to pick a
    // stable target, so each frame independently classifies its best box.
    final topDetection = detections.reduce(
      (a, b) => b.confidence > a.confidence ? b : a,
    );

    _isClassifying = true;
    final stopwatch = Stopwatch()..start();
    try {
      final health = await _classifier.classifyCrop(
        frameBytes,
        topDetection.boundingBox,
        frameWidth: frameWidth,
        frameHeight: frameHeight,
      );
      stopwatch.stop();
      if (!mounted) return;
      setState(() {
        _latestHealth = health;
        _classifyLatencyMs = stopwatch.elapsedMilliseconds;
      });
      // Concurrency verification (sub-plan's "Done when" #3): actual timing
      // numbers for both pipelines, not an eyeballed frame rate.
      debugPrint(
        'ReefSight perf: segmentation=${segProcessingMs?.toStringAsFixed(1)}ms '
        'classify=${stopwatch.elapsedMilliseconds}ms '
        'label=${health?.label} confidence=${health?.confidence}',
      );
    } finally {
      _isClassifying = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          YOLOView(
            modelPath: ModelAssets.coralvosPrimarySegmentation,
            task: YOLOTask.segment,
            streamingConfig: const YOLOStreamingConfig.custom(
              includeOriginalImage: true,
              // Caps both inference and how often a full camera frame is
              // shipped over the platform channel — Spec's "Target: 5-8 fps"
              // (ReefSight_Specification.md:88), not an arbitrary number.
              inferenceFrequency: 8,
            ),
            onStreamingData: _handleStreamingData,
            onModelError: (error, modelPath, task) {
              debugPrint(
                'ReefSight: segmentation model error for $modelPath ($task): $error',
              );
              if (mounted) setState(() => _segmentationError = error.toString());
            },
            onModelLoad: (modelPath, task) {
              debugPrint('ReefSight: segmentation model loaded: $modelPath ($task)');
              if (mounted) setState(() => _segmentationError = null);
            },
          ),
          Positioned(
            left: 12,
            bottom: 12,
            child: SafeArea(
              child: _PerformanceAndHealthOverlay(
                segProcessingMs: _segProcessingMs,
                classifyLatencyMs: _classifyLatencyMs,
                health: _latestHealth,
                segmentationError: _segmentationError,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PerformanceAndHealthOverlay extends StatelessWidget {
  const _PerformanceAndHealthOverlay({
    required this.segProcessingMs,
    required this.classifyLatencyMs,
    required this.health,
    required this.segmentationError,
  });

  final double? segProcessingMs;
  final int? classifyLatencyMs;
  final ColonyHealth? health;
  final String? segmentationError;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'seg: ${segProcessingMs?.toStringAsFixed(1) ?? '--'}ms   '
            'classify: ${classifyLatencyMs ?? '--'}ms',
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
          if (health != null)
            Text(
              '${health!.label} (${(health!.confidence * 100).toStringAsFixed(1)}%)',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          if (segmentationError != null)
            Text(
              'Segmentation model error: $segmentationError',
              style: const TextStyle(color: Colors.redAccent, fontSize: 12),
            ),
        ],
      ),
    );
  }
}
