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
                    onTap: () => _showEnlarged(
                      context,
                      colony.trackId,
                      file,
                      photos.contextMask[colony.trackId],
                    ),
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

  static void _showEnlarged(BuildContext context, int trackId, File file, File? mask) {
    var showMask = true;
    showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => Dialog(
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
                child: _MaskedPhoto(
                  photo: Image.file(
                    file,
                    fit: BoxFit.contain,
                    errorBuilder: (context, error, stackTrace) => const SizedBox(
                      height: 200,
                      child: Center(child: Icon(Icons.broken_image)),
                    ),
                  ),
                  mask: showMask ? mask : null,
                  maskKey: const ValueKey('photo-mask-context'),
                ),
              ),
              if (mask != null)
                _MaskToggle(value: showMask, onChanged: (v) => setState(() => showMask = v)),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Close'),
              ),
            ],
          ),
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
    this.confidenceFloor = ClassificationPolicy.classifyConfFloor,
    this.photoMask,
    this.cropMask,
  });

  final TrackedColonyRecord colony;
  final File photo;
  final File? crop;
  final double size;

  /// The colony's mask overlays for [photo] and [crop], shown in the
  /// detail (too small to read on the thumbnail itself).
  final File? photoMask;
  final File? cropMask;

  /// The session's confidence floor, for the detail's uncertain-sample note.
  final double confidenceFloor;

  @override
  Widget build(BuildContext context) {
    // The padding brings the tap target to 48 px around a 32 px image.
    return InkWell(
      key: ValueKey('colony-thumbnail-${colony.trackId}'),
      onTap: () => showColonyPhotoDetail(
        context,
        colony,
        photo: photo,
        crop: crop,
        confidenceFloor: confidenceFloor,
        photoMask: photoMask,
        cropMask: cropMask,
      ),
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
  double confidenceFloor = ClassificationPolicy.classifyConfFloor,
  File? photoMask,
  File? cropMask,
}) {
  final label = colony.photoLabel;
  final unclassified = label == BestColonyPhoto.unclassifiedLabel;
  final confidence = unclassified ? null : colony.photoConfidence;
  // Against the floor the session ran with (its stored thresholds), so a
  // comparison run's note matches how the sample was actually counted.
  final uncertain = confidence != null && confidence < confidenceFloor;
  final hasMask = photoMask != null || (crop != null && cropMask != null);
  var showMask = true;

  Widget panel(String title, File? file, File? mask, String maskId) => Expanded(
    child: Column(
      children: [
        Text(title, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        AspectRatio(
          aspectRatio: 1,
          child: file == null
              ? const Center(child: Text('—'))
              : _MaskedPhoto(
                  photo: _PhotoImage(file: file, fit: BoxFit.contain),
                  mask: showMask ? mask : null,
                  maskKey: ValueKey('photo-mask-$maskId'),
                ),
        ),
      ],
    ),
  );

  return showDialog<void>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
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
                panel('Context', photo, photoMask, 'context'),
                const SizedBox(width: 8),
                panel('Classifier input', crop, cropMask, 'crop'),
              ],
            ),
            if (hasMask)
              _MaskToggle(value: showMask, onChanged: (v) => setState(() => showMask = v)),
            const SizedBox(height: 12),
            if (label != null && confidence != null)
              Text(
                '${_labelText(label)} · confidence ${confidence.toStringAsFixed(2)}',
                style: const TextStyle(fontSize: 14),
              ),
            if (unclassified)
              const Text(
                'Not classified: the classifier returned no result for this colony. '
                'Photo cut from its detection box.',
                style: TextStyle(fontSize: 14),
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
    ),
  );
}

/// [photo] with the colony's mask overlay ([mask], a transparent PNG the
/// photo's size) drawn over it. Both fill the same box with
/// [BoxFit.contain] and share an aspect ratio, so they line up exactly.
/// `null` [mask] shows the photo alone.
class _MaskedPhoto extends StatelessWidget {
  const _MaskedPhoto({required this.photo, required this.mask, required this.maskKey});

  final Widget photo;
  final File? mask;
  final Key maskKey;

  @override
  Widget build(BuildContext context) {
    final mask = this.mask;
    if (mask == null) return photo;
    return Stack(
      alignment: Alignment.center,
      children: [
        photo,
        Positioned.fill(
          child: Image.file(
            mask,
            key: maskKey,
            fit: BoxFit.contain,
            // A missing overlay just shows the bare photo.
            errorBuilder: (context, error, stackTrace) => const SizedBox.shrink(),
          ),
        ),
      ],
    );
  }
}

/// Shows or hides the colony outline, in the photo detail and enlarged view.
class _MaskToggle extends StatelessWidget {
  const _MaskToggle({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => SwitchListTile(
    key: const ValueKey('mask-toggle'),
    contentPadding: EdgeInsets.zero,
    dense: true,
    title: const Text('Outline colony'),
    value: value,
    onChanged: onChanged,
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
