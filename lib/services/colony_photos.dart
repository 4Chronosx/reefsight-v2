import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path/path.dart' as p;

import 'bleaching_classifier.dart';
import 'classification_policy.dart';
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
  });

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
    );
    return true;
  }

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

    final staged = <(File, String)>[];
    try {
      staged.add(await _stage(path, photo.context));
      if (cropPath != null) staged.add(await _stage(cropPath, crop!));
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

    return StoredColonyPhoto(
      path: path,
      cropPath: cropPath,
      label: photo.label,
      confidence: photo.confidence,
      confident: photo.confident,
    );
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

/// A session's colony photos resolved to files that exist, by track id --
/// what Summary shows (sub-plan 18 steps 4-5).
class ColonyPhotoFiles {
  const ColonyPhotoFiles({this.context = const {}, this.crop = const {}});

  static const ColonyPhotoFiles empty = ColonyPhotoFiles();

  final Map<int, File> context;
  final Map<int, File> crop;

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

  final [context, crop] = await Future.wait([
    for (final pick in [(TrackedColonyRecord c) => c.photoPath, (TrackedColonyRecord c) => c.photoCropPath])
      Future.wait([for (final c in colonies) resolve(c.trackId, pick(c))]),
  ]);
  return ColonyPhotoFiles(
    context: Map.fromEntries(context.nonNulls),
    crop: Map.fromEntries(crop.nonNulls),
  );
}
