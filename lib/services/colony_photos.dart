import 'dart:io';
import 'dart:typed_data';

import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart' show compute, debugPrint, visibleForTesting;
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import 'bleaching_classifier.dart';
import 'classification_policy.dart';
import 'crop_geometry.dart';
import 'tracked_colony_record.dart';

/// One colony's best sample so far for one label, with its images
/// (sub-plan 18).
class ColonyPhoto {
  const ColonyPhoto({
    required this.trackId,
    required this.label,
    required this.confidence,
    required this.confident,
    required this.context,
    this.crop,
    this.overlay,
  });

  /// Where to draw the colony's mask over [context] and [crop]; `null`
  /// when the sample had no mask. Rendered to PNGs at write time.
  final MaskOverlay? overlay;

  final int trackId;
  final String label;
  final double confidence;

  /// At or above `classifyConfFloor` (sub-plan 10). A colony with no
  /// confident sample keeps its best uncertain one, marked by this.
  final bool confident;

  /// The context photo (box x1.5, longest side 320) and the exact 224x224
  /// classifier input.
  final Uint8List context;
  final Uint8List? crop;
}

typedef _Rank = (bool confident, double confidence);

/// Confident beats uncertain, then higher top-1 confidence; a tie keeps
/// the earlier photo.
bool _beats(_Rank a, _Rank b) => a.$1 != b.$1 ? a.$1 : a.$2 > b.$2;

/// Keeps, per track *and label*, the images of its most confident sample
/// (sub-plan 18 decision 1).
///
/// Per label, because a colony's label is a confidence-weighted average
/// (`HealthAggregator`), not its single most confident sample: three
/// bleached samples at 0.75 outweigh one healthy at 0.95. Keeping the best
/// of each lets the photo shown match the label the colony ends up with --
/// a "bleached colonies" photo must show the bleached sample.
///
/// Only *changed* bests hold image bytes, until [takePending] hands them to
/// [ColonyPhotoStore]; after that only the ranking is kept, so memory stays
/// at the photos not yet written, not every colony's.
class BestColonyPhoto {
  BestColonyPhoto({this.confidenceFloor = ClassificationPolicy.classifyConfFloor});

  final double confidenceFloor;

  final Map<(int, String), _Rank> _rank = {};
  final Map<(int, String), ColonyPhoto> _pending = {};

  /// Records [result] for [trackId] if it beats the track's current best
  /// for the same label. Returns whether it did. A result with no context
  /// photo is ignored.
  bool offer(int trackId, ClassifiedCrop result) {
    final context = result.context;
    if (context == null) return false;

    final label = result.health.label;
    final confidence = result.health.confidence;
    final rank = (confidence >= confidenceFloor, confidence);
    final key = (trackId, label);
    final current = _rank[key];
    if (current != null && !_beats(rank, current)) return false;

    _rank[key] = rank;
    _pending[key] = ColonyPhoto(
      trackId: trackId,
      label: label,
      confidence: confidence,
      confident: rank.$1,
      context: context,
      crop: result.crop,
      overlay: result.overlay,
    );
    return true;
  }

  /// Records a context-only photo for [trackId], cut from its detection
  /// box with no classification -- the fallback so a tracked colony has a
  /// photo even if the classifier never returned a result for it. Stored
  /// under [unclassifiedLabel] with confidence 0, so any classified sample
  /// beats it in [ColonyPhotoStore.photoFor]. Only the first is kept.
  bool offerUnclassified(int trackId, Uint8List context, {MaskOverlay? overlay}) {
    final key = (trackId, unclassifiedLabel);
    if (_rank.containsKey(key)) return false;
    _rank[key] = (false, 0.0);
    _pending[key] = ColonyPhoto(
      trackId: trackId,
      label: unclassifiedLabel,
      confidence: 0,
      confident: false,
      context: context,
      overlay: overlay,
    );
    return true;
  }

  /// The label of an [offerUnclassified] photo.
  static const String unclassifiedLabel = 'UNCLASSIFIED';

  /// The bests that changed since the last call. Each is handed over once.
  List<ColonyPhoto> takePending() {
    final taken = _pending.values.toList(growable: false);
    _pending.clear();
    return taken;
  }

  /// Gives back photos whose write failed, so the next flush retries them --
  /// except where a newer best has arrived since, which supersedes them.
  void requeue(Iterable<ColonyPhoto> photos) {
    for (final photo in photos) {
      _pending.putIfAbsent((photo.trackId, photo.label), () => photo);
    }
  }
}

/// A colony photo as written: paths relative to the documents directory,
/// plus the label and confidence of the sample it shows.
class StoredColonyPhoto {
  const StoredColonyPhoto({
    required this.path,
    required this.cropPath,
    required this.label,
    required this.confidence,
    required this.confident,
  });

  final String path;
  final String? cropPath;
  final String label;
  final double confidence;
  final bool confident;
}

/// Writes a session's colony photos under `<documents>/colony_photos/`
/// (sub-plan 18 decision 3), at checkpoints and at finalize.
///
/// Paths are stored relative to the documents directory, with `/`
/// separators: iOS moves the app's container on reinstall, so an absolute
/// path goes stale (the problem `resolveTransectVideo` works around).
/// File names are fixed per track and label, so a better sample overwrites
/// the file and the stored path doesn't change.
class ColonyPhotoStore {
  ColonyPhotoStore({required this.documentsDirectory, required this.sessionId});

  static const String folder = 'colony_photos';

  final String documentsDirectory;
  final int sessionId;

  final Map<int, Map<String, StoredColonyPhoto>> _stored = {};

  /// The written photo to show for [trackId]: the one for [label] (the
  /// colony's aggregated label) if there is one, otherwise the best of any
  /// label -- e.g. an Uncertain colony. `null` if none was written yet.
  StoredColonyPhoto? photoFor(int trackId, {String? label}) {
    final byLabel = _stored[trackId];
    if (byLabel == null || byLabel.isEmpty) return null;
    final match = byLabel[label];
    if (match != null) return match;
    return byLabel.values.reduce(
      (a, b) => _beats((b.confident, b.confidence), (a.confident, a.confidence)) ? b : a,
    );
  }

  /// Writes every best that changed since the last flush. A failed write
  /// doesn't stop the others: it's given back to [best] for the next flush,
  /// and the first error is rethrown once the rest are done.
  Future<void> flush(BestColonyPhoto best) async {
    final pending = best.takePending();
    if (pending.isEmpty) return;

    try {
      await Directory(p.join(documentsDirectory, folder)).create(recursive: true);
    } catch (_) {
      best.requeue(pending);
      rethrow;
    }

    final failed = <ColonyPhoto>[];
    (Object, StackTrace)? firstError;
    for (final photo in pending) {
      try {
        _stored.putIfAbsent(photo.trackId, () => {})[photo.label] = await _write(photo);
      } catch (error, stackTrace) {
        debugPrint('ReefSight: colony photo write failed for track ${photo.trackId}: $error');
        failed.add(photo);
        firstError ??= (error, stackTrace);
      }
    }
    best.requeue(failed);
    if (firstError != null) Error.throwWithStackTrace(firstError.$1, firstError.$2);
  }

  /// Both images are first written to temp files; only once both are on
  /// disk are they renamed over the real paths. A failed write (disk full)
  /// therefore changes nothing, rather than leaving a new context photo
  /// next to the old crop and the old label. Only a crash between the two
  /// renames can still mix them.
  Future<StoredColonyPhoto> _write(ColonyPhoto photo) async {
    final base = 'session${sessionId}_track${photo.trackId}_${_safe(photo.label)}';
    final path = p.posix.join(folder, '$base.jpg');
    final crop = photo.crop;
    final cropPath = crop == null ? null : p.posix.join(folder, '${base}_crop.jpg');
    final masks = await _renderMasks(photo);

    final staged = <(File, String)>[];
    try {
      staged.add(await _stage(path, photo.context));
      if (cropPath != null) staged.add(await _stage(cropPath, crop!));
      if (masks.context case final bytes?) staged.add(await _stage(maskPathFor(path), bytes));
      if (cropPath != null && masks.crop != null) {
        staged.add(await _stage(maskPathFor(cropPath), masks.crop!));
      }
      for (final (temp, target) in staged.reversed) {
        await temp.rename(target);
      }
    } catch (_) {
      for (final (temp, _) in staged) {
        try {
          if (await temp.exists()) await temp.delete();
        } catch (_) {}
      }
      rethrow;
    }

    // A mask left from an earlier best would outline the wrong photo.
    if (masks.context == null) await _deleteIfPresent(maskPathFor(path));
    if (masks.crop == null || cropPath == null) {
      await _deleteIfPresent(maskPathFor(p.posix.join(folder, '${base}_crop.jpg')));
    }

    return StoredColonyPhoto(
      path: path,
      cropPath: cropPath,
      label: photo.label,
      confidence: photo.confidence,
      confident: photo.confident,
    );
  }

  /// [photo]'s mask overlays, rendered at its context photo's and crop's
  /// pixel sizes on a background isolate. A failed render only costs the
  /// outline, never the photo.
  Future<({Uint8List? context, Uint8List? crop})> _renderMasks(ColonyPhoto photo) async {
    final overlay = photo.overlay;
    if (overlay == null) return (context: null, crop: null);
    try {
      final region = overlay.contextRegion;
      final size = scaledToLongSide(region.width, region.height, contextPhotoLongSide);
      final context = await compute(renderMaskOverlay, (
        mask: overlay.mask,
        box: overlay.box,
        region: region,
        width: size.width,
        height: size.height,
      ));
      final cropRegion = overlay.cropRegion;
      final crop = photo.crop == null || cropRegion == null
          ? null
          : await compute(renderMaskOverlay, (
              mask: overlay.mask,
              box: overlay.box,
              region: cropRegion,
              width: classifierInputSize,
              height: classifierInputSize,
            ));
      return (context: context, crop: crop);
    } catch (error) {
      debugPrint('ReefSight: colony mask overlay failed for track ${photo.trackId}: $error');
      return (context: null, crop: null);
    }
  }

  Future<void> _deleteIfPresent(String relativePath) async {
    try {
      final file = File(_absolute(relativePath));
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  Future<(File, String)> _stage(String relativePath, Uint8List bytes) async {
    final target = _absolute(relativePath);
    final temp = File('$target.tmp');
    await temp.writeAsBytes(bytes, flush: true);
    return (temp, target);
  }

  String _absolute(String relativePath) =>
      p.joinAll([documentsDirectory, ...p.posix.split(relativePath)]);

  static String _safe(String label) => label.replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_');
}

/// The file a stored colony photo path points to under the *current*
/// [documentsDirectory], or `null` if [relativePath] is null or the file
/// is gone.
Future<File?> resolveColonyPhoto(
  String? relativePath, {
  required String documentsDirectory,
}) async {
  if (relativePath == null || relativePath.isEmpty) return null;
  final file = File(p.joinAll([documentsDirectory, ...p.posix.split(relativePath)]));
  return await file.exists() ? file : null;
}

/// Where a photo's mask overlay is stored: beside it, `<name>_mask.png`.
/// Derived, not stored, so it needs no database column.
String maskPathFor(String photoPath) => photoPath.endsWith('.jpg')
    ? '${photoPath.substring(0, photoPath.length - 4)}_mask.png'
    : '${photoPath}_mask.png';

/// The overlay's fill alpha; the outline is opaque.
const int maskFillAlpha = 70;

/// Amber: stands out against blue-green reef in both photos.
const _maskColor = (r: 255, g: 213, b: 79);

/// One mask overlay to render: frame-pixel [mask]/[box], and the frame
/// [region] a [width] x [height] photo was cut from.
typedef MaskRenderJob = ({
  List<List<double>> mask,
  Rect box,
  CropRegion region,
  int width,
  int height,
});

/// The colony's mask as a transparent PNG the size of its photo: a
/// translucent fill with an opaque ~2 px outline. Each photo pixel is mapped
/// back to the frame and looked up with [maskCoversPoint], so the overlay
/// follows the same mask mapping as the coverage gate. Must stay top-level
/// for [compute].
@visibleForTesting
Uint8List renderMaskOverlay(MaskRenderJob job) {
  final w = job.width, h = job.height, region = job.region;
  final covered = List<bool>.filled(w * h, false);
  for (var y = 0; y < h; y++) {
    final fy = region.top + (y + 0.5) * region.height / h;
    for (var x = 0; x < w; x++) {
      final fx = region.left + (x + 0.5) * region.width / w;
      covered[y * w + x] = maskCoversPoint(job.mask, job.box, fx, fy);
    }
  }
  // The photo's edge isn't the colony's: off-image counts as covered, so a
  // colony cut by the edge isn't outlined along it.
  bool at(int x, int y) => x < 0 || y < 0 || x >= w || y >= h || covered[y * w + x];

  const outlineWidth = 2;
  final image = img.Image(width: w, height: h, numChannels: 4);
  final (:r, :g, :b) = _maskColor;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      if (!covered[y * w + x]) continue;
      var edge = false;
      for (var d = 1; d <= outlineWidth && !edge; d++) {
        edge = !at(x - d, y) || !at(x + d, y) || !at(x, y - d) || !at(x, y + d);
      }
      image.setPixelRgba(x, y, r, g, b, edge ? 255 : maskFillAlpha);
    }
  }
  return Uint8List.fromList(img.encodePng(image));
}

/// A session's colony photos resolved to files that exist, by track id --
/// what Summary shows (sub-plan 18 steps 4-5).
class ColonyPhotoFiles {
  const ColonyPhotoFiles({
    this.context = const {},
    this.crop = const {},
    this.contextMask = const {},
    this.cropMask = const {},
  });

  static const ColonyPhotoFiles empty = ColonyPhotoFiles();

  final Map<int, File> context;
  final Map<int, File> crop;

  /// The mask overlays drawn over [context] and [crop], where one exists.
  final Map<int, File> contextMask;
  final Map<int, File> cropMask;

  /// The context photos, for "Share report with photos". The classifier
  /// crops stay out: they're technical, and they'd double an already long
  /// share-sheet list.
  List<String> get contextPaths => [for (final file in context.values) file.path];
}

/// Resolves every colony's stored photo paths under [documentsDirectory],
/// leaving out any file that's gone.
Future<ColonyPhotoFiles> resolveColonyPhotos(
  List<TrackedColonyRecord> colonies, {
  required String documentsDirectory,
}) async {
  Future<MapEntry<int, File>?> resolve(int trackId, String? path) async {
    final file = await resolveColonyPhoto(path, documentsDirectory: documentsDirectory);
    return file == null ? null : MapEntry(trackId, file);
  }

  String? mask(String? path) => path == null ? null : maskPathFor(path);
  final [context, crop, contextMask, cropMask] = await Future.wait([
    for (final pick in [
      (TrackedColonyRecord c) => c.photoPath,
      (TrackedColonyRecord c) => c.photoCropPath,
      (TrackedColonyRecord c) => mask(c.photoPath),
      (TrackedColonyRecord c) => mask(c.photoCropPath),
    ])
      Future.wait([for (final c in colonies) resolve(c.trackId, pick(c))]),
  ]);
  return ColonyPhotoFiles(
    context: Map.fromEntries(context.nonNulls),
    crop: Map.fromEntries(crop.nonNulls),
    contextMask: Map.fromEntries(contextMask.nonNulls),
    cropMask: Map.fromEntries(cropMask.nonNulls),
  );
}
