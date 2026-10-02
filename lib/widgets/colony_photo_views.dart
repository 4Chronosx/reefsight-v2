import 'dart:io';

import 'package:flutter/material.dart';

import '../constants/app_colors.dart';
import '../services/classification_policy.dart';
import '../services/colony_photos.dart';
import '../services/health_aggregator.dart';
import '../services/tracked_colony_record.dart';

/// Sub-plan 18 step 4, on the Executive tab: the bleached colonies'
/// context photos, tappable to enlarge. A standalone widget so sub-plan 19
/// can move it when it redesigns the tab.
///
/// When prevalence is below sub-plan 17's small-n threshold, the heading
/// says these are the app's calls rather than a finding.
class BleachedColonyStrip extends StatelessWidget {
  const BleachedColonyStrip({
    super.key,
    required this.colonies,
    required this.photos,
    required this.prevalenceReliable,
  });

  final List<TrackedColonyRecord> colonies;
  final ColonyPhotoFiles photos;
  final bool prevalenceReliable;

  @override
  Widget build(BuildContext context) {
    final bleached = [
      for (final colony in colonies)
        if (colony.healthLabel == HealthAggregator.bleachedLabel) colony,
    ];
    final withPhoto = [
      for (final colony in bleached)
        if (photos.context[colony.trackId] != null) colony,
    ];
    final missing = bleached.length - withPhoto.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          prevalenceReliable ? 'Bleached colonies' : 'Colonies the app marked bleached',
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 15,
            color: AppColors.onSurface,
          ),
        ),
        const SizedBox(height: 8),
        if (bleached.isEmpty)
          Text(
            'No bleached colonies found',
            style: TextStyle(color: AppColors.onSurface.withValues(alpha: 0.7), fontSize: 14),
          )
        else ...[
          if (withPhoto.isNotEmpty)
            SizedBox(
              height: 96,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: withPhoto.length,
                separatorBuilder: (context, index) => const SizedBox(width: 8),
                itemBuilder: (context, index) {
                  final colony = withPhoto[index];
                  final file = photos.context[colony.trackId]!;
                  return GestureDetector(
                    key: ValueKey('bleached-photo-${colony.trackId}'),
                    onTap: () => _showEnlarged(context, colony.trackId, file),
                    child: _PhotoImage(file: file, size: 96),
                  );
                },
              ),
            ),
          if (missing > 0)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                '$missing bleached ${missing == 1 ? 'colony has' : 'colonies have'} no photo.',
                style: TextStyle(color: AppColors.onSurface.withValues(alpha: 0.6), fontSize: 12),
              ),
            ),
        ],
      ],
    );
  }

  static void _showEnlarged(BuildContext context, int trackId, File file) {
    showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                'Colony #$trackId',
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
              ),
            ),
            InteractiveViewer(
              maxScale: 4,
              child: Image.file(
                file,
                fit: BoxFit.contain,
                errorBuilder: (context, error, stackTrace) =>
                    const SizedBox(height: 200, child: Center(child: Icon(Icons.broken_image))),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Sub-plan 18 step 5: a colony row's photo thumbnail on the Technical tab.
/// Tapping it opens [showColonyPhotoDetail].
class ColonyThumbnail extends StatelessWidget {
  const ColonyThumbnail({
    super.key,
    required this.colony,
    required this.photo,
    this.crop,
    this.size = 32,
  });

  final TrackedColonyRecord colony;
  final File photo;
  final File? crop;
  final double size;

  @override
  Widget build(BuildContext context) {
    // The padding brings the tap target to 48 px around a 32 px image.
    return InkWell(
      key: ValueKey('colony-thumbnail-${colony.trackId}'),
      onTap: () => showColonyPhotoDetail(context, colony, photo: photo, crop: crop),
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: _PhotoImage(file: photo, size: size, radius: 4),
      ),
    );
  }
}

/// Both images side by side -- the context photo people look at and the
/// exact classifier input -- with the label and confidence of the sample
/// they come from (sub-plan 18 step 5).
Future<void> showColonyPhotoDetail(
  BuildContext context,
  TrackedColonyRecord colony, {
  required File photo,
  File? crop,
}) {
  final label = colony.photoLabel;
  final confidence = colony.photoConfidence;
  final uncertain =
      confidence != null && confidence < ClassificationPolicy.classifyConfFloor;

  Widget panel(String title, File? file) => Expanded(
    child: Column(
      children: [
        Text(title, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        AspectRatio(
          aspectRatio: 1,
          child: file == null
              ? const Center(child: Text('—'))
              : _PhotoImage(file: file, fit: BoxFit.contain),
        ),
      ],
    ),
  );

  return showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('Colony #${colony.trackId}'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                panel('Context', photo),
                const SizedBox(width: 8),
                panel('Classifier input', crop),
              ],
            ),
            const SizedBox(height: 12),
            if (label != null && confidence != null)
              Text(
                '${_labelText(label)} · confidence ${confidence.toStringAsFixed(2)}',
                style: const TextStyle(fontSize: 14),
              ),
            if (uncertain)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Uncertain sample: the colony had no confident classification.',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.onSurface.withValues(alpha: 0.7),
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}

String _labelText(String label) => switch (label) {
  HealthAggregator.bleachedLabel => 'Bleached',
  HealthAggregator.healthyLabel => 'Healthy',
  _ => label,
};

class _PhotoImage extends StatelessWidget {
  const _PhotoImage({required this.file, this.size, this.radius = 8, this.fit = BoxFit.cover});

  final File file;
  final double? size;
  final double radius;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    final size = this.size;
    // Decode thumbnails at their shown size, not the full 320 px photo.
    final cacheSize =
        size == null ? null : (size * MediaQuery.devicePixelRatioOf(context)).round();
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Image.file(
        file,
        width: size,
        height: size,
        cacheWidth: cacheSize,
        fit: fit,
        errorBuilder: (context, error, stackTrace) => Container(
          width: size,
          height: size,
          color: AppColors.surface,
          child: const Icon(Icons.broken_image_outlined, size: 16),
        ),
      ),
    );
  }
}
