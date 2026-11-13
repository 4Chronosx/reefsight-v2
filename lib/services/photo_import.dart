import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'photo_import_checks.dart';
import 'photo_import_order.dart';
import 'photo_metadata.dart';
import 'photo_transect_store.dart';
import 'transect_database.dart';
import 'transect_frame.dart';

/// A file the picker handed over: its path (the picker's own copy, or the
/// original in the Files app) and the name to show and sort by.
class PickedPhoto {
  const PickedPhoto({required this.path, required this.name});
  final String path;
  final String name;
}

/// Where photos come from. The real one wraps `image_picker` and
/// `file_picker` (`photo_source.dart`); tests use a fake.
abstract interface class PhotoSource {
  /// Empty when the diver cancels.
  Future<List<PickedPhoto>> pickFromLibrary();
  Future<List<PickedPhoto>> pickFromFiles();
}

/// One position along the tape in the draft: a photo, or a gap (a meter
/// with no photo, e.g. "no photo at 23 m").
sealed class ImportSlot {
  const ImportSlot();
}

class PhotoSlot extends ImportSlot {
  const PhotoSlot(this.photo);
  final ImportedPhoto photo;
}

/// Deliberately not const: each gap is its own instance, so the reorderable
/// list can key gaps apart (`ObjectKey`) when there are several.
class GapSlot extends ImportSlot {
  GapSlot();
}

/// Issue #5: one photo transect's import (alignment doc §9), kept out of
/// the screen so it can be tested without a picker.
///
/// Picked photos are copied into app storage straight away (the sources are
/// never touched) and read for EXIF; the draft is a list of slots whose
/// position is the meter mark. Nothing reaches the database until [save],
/// which writes the whole set in one transaction; [discard] deletes copies
/// that were never saved.
class PhotoImport extends ChangeNotifier {
  PhotoImport({
    required this.db,
    required this.store,
    required this.reader,
    required this.sessionId,
    required this.tapeLengthMeters,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final TransectDatabase db;
  final PhotoTransectStore store;
  final PhotoMetadataReader reader;
  final int sessionId;
  final double tapeLengthMeters;
  final DateTime Function() _clock;

  final List<ImportSlot> _slots = [];

  /// Copies made since the last save: deleted on [discard], or at [save]
  /// if they were dropped from the draft first.
  final Set<String> _unsaved = {};

  bool _dirty = false;
  bool _busy = false;
  int _progressDone = 0;
  int _progressTotal = 0;
  LensMode? _lensMode;
  List<String> _failedNames = const [];
  int _copyIndex = 0;
  int _savedWithoutCorners = 0;

  /// Saved photos still without corners (and not marked "no frame
  /// visible"), as of the last [load] -- the transect isn't ready to score
  /// until this is 0.
  int get savedWithoutCorners => _savedWithoutCorners;

  List<ImportSlot> get slots => List.unmodifiable(_slots);
  List<ImportedPhoto> get photos => [for (final s in _slots) if (s is PhotoSlot) s.photo];

  /// The draft differs from what's saved.
  bool get dirty => _dirty;
  bool get busy => _busy;
  int get progressDone => _progressDone;
  int get progressTotal => _progressTotal;

  /// Photos the last pick couldn't copy (shown, then replaced on the next).
  List<String> get failedNames => _failedNames;

  double meterAt(int index) => index.toDouble();

  int get expectedCount => expectedFrameCount(tapeLengthMeters);

  /// Slots beyond the tape's last meter: drop them before saving.
  int get extraCount => max(0, _slots.length - expectedCount);
  bool get countFarOff => frameCountFarOff(photos.length, tapeLengthMeters);
  bool get orderedByTime => photos.isNotEmpty && photos.every((p) => p.metadata.capturedAt != null);
  int get cameras => cameraCount(photos);

  LensMode? get lensMode => _lensMode;

  /// An action camera was used and the diver hasn't said which lens mode.
  bool get needsLensAnswer => _lensMode == null && photos.any((p) => isActionCamera(p.metadata));

  /// A GoPro follows the lens answer. Any other camera's saved photo keeps
  /// the flag it was saved with (its focal length isn't stored); a new one
  /// is judged from its metadata.
  bool fisheyeSuspected(ImportedPhoto photo) {
    final saved = photo.savedFisheyeFlag;
    if (saved != null && !isActionCamera(photo.metadata)) return saved;
    return suspectFisheye(photo.metadata, lensMode: _lensMode);
  }

  bool get canSave => !_busy && _slots.isNotEmpty && extraCount == 0;

  /// Reads what's saved: one slot per meter from 0 to the last saved one,
  /// a gap where there's a missing-meter row or no row at all, so every
  /// photo stays at its meter.
  Future<void> load() async {
    _slots.clear();
    final byMeter = <int, TransectFrame>{};
    for (final f in await db.framesForSession(sessionId)) {
      final m = f.meterMark;
      if (m != null && m >= 0) byMeter[m.round()] = f;
    }
    final last = byMeter.keys.fold(-1, max);
    for (var m = 0; m <= last; m++) {
      final f = byMeter[m];
      _slots.add(f == null || f.isMissing ? GapSlot() : PhotoSlot(_fromFrame(f)));
    }
    _lensMode = _lensFromFrames(byMeter.values);
    _savedWithoutCorners =
        byMeter.values.where((f) => !f.isMissing && f.corners == null && f.excludeReason != kNoFrameReason).length;
    _dirty = false;
    notifyListeners();
  }

  /// Copies and reads [picked], one at a time (a 51-photo set is ~250 MB),
  /// then adds them in tape order: the whole draft is sorted if it was
  /// empty; otherwise the new batch, sorted on its own, goes after what's
  /// there (the diver has already arranged it). A photo that fails to copy
  /// is skipped and named in [failedNames].
  Future<void> addPhotos(List<PickedPhoto> picked) => _exclusive(() async {
        _progressDone = 0;
        _progressTotal = picked.length;
        final failed = <String>[];
        final batch = <ImportedPhoto>[];
        final at = _clock();
        for (final photo in picked) {
          try {
            final relative = await store.importCopy(photo.path, index: _copyIndex++, at: at);
            _unsaved.add(relative);
            final metadata = await reader.read(store.absolutePath(relative));
            batch.add(ImportedPhoto(relativePath: relative, originalName: photo.name, metadata: metadata));
          } catch (error) {
            debugPrint('ReefSight: could not import ${photo.name}: $error');
            failed.add(photo.name);
          }
          _progressDone++;
          notifyListeners();
        }
        _failedNames = failed;
        if (batch.isNotEmpty) {
          _slots.addAll([for (final photo in sortForImport(batch)) PhotoSlot(photo)]);
          _dirty = true;
        }
      });

  /// `ReorderableListView.onReorder` semantics: [newIndex] counts the item
  /// being moved, so moving down lands one before it.
  void move(int oldIndex, int newIndex) {
    final to = newIndex > oldIndex ? newIndex - 1 : newIndex;
    if (to == oldIndex) return;
    _slots.insert(to, _slots.removeAt(oldIndex));
    _changed();
  }

  void insertGap(int index) {
    _slots.insert(index, GapSlot());
    _changed();
  }

  /// Removes a photo (an extra shot) or a gap. The file is deleted at
  /// [save] or [discard], so an accidental drop costs nothing until then.
  void drop(int index) {
    _slots.removeAt(index);
    _changed();
  }

  void setLensMode(LensMode mode) {
    _lensMode = mode;
    _changed();
  }

  /// Writes the draft (one transaction), then deletes the files of photos
  /// that were dropped: copies never saved, and saved photos whose rows
  /// [TransectDatabase.saveImportedFrames] removed. Then reloads, so new
  /// rows have their ids.
  Future<void> save() => _exclusive(() async {
        if (extraCount > 0) throw StateError('Drop the $extraCount photos past the end of the tape first');
        final frames = <TransectFrame>[];
        for (var i = 0; i < _slots.length; i++) {
          frames.add(switch (_slots[i]) {
            PhotoSlot(:final photo) => _toFrame(photo, meterAt(i)),
            GapSlot() => TransectFrame.missingMeter(
                sessionId: sessionId,
                meterMark: meterAt(i),
                source: FrameSource.imported,
              ),
          });
        }
        final result = await db.saveImportedFrames(sessionId, frames);

        final kept = {for (final photo in photos) photo.relativePath};
        for (final f in result.removed) {
          if (!kept.contains(f.imagePath)) await store.delete(f.imagePath);
        }
        for (final path in _unsaved.difference(kept)) {
          await store.delete(path);
        }
        _unsaved.clear();
        await load();
      });

  /// Leaving without saving: deletes the copies made since the last save.
  Future<void> discard() async {
    for (final path in _unsaved) {
      await store.delete(path);
    }
    _unsaved.clear();
  }

  TransectFrame _toFrame(ImportedPhoto photo, double meter) {
    final m = photo.metadata;
    return TransectFrame(
      id: photo.frameId,
      sessionId: sessionId,
      meterMark: meter,
      imagePath: photo.relativePath,
      source: FrameSource.imported,
      widthPx: m.width,
      heightPx: m.height,
      cameraMake: m.make,
      cameraModel: m.model,
      capturedAt: m.capturedAt,
      fisheyeFlag: fisheyeSuspected(photo),
    );
  }

  ImportedPhoto _fromFrame(TransectFrame f) => ImportedPhoto(
        relativePath: f.imagePath,
        originalName: p.posix.basename(f.imagePath),
        frameId: f.id,
        savedFisheyeFlag: f.fisheyeFlag,
        metadata: PhotoMetadata(
          width: f.widthPx,
          height: f.heightPx,
          make: f.cameraMake,
          model: f.cameraModel,
          capturedAt: f.capturedAt,
        ),
      );

  /// The lens answer isn't stored on its own; a saved GoPro frame's fisheye
  /// flag says what it was (false only after "Linear").
  LensMode? _lensFromFrames(Iterable<TransectFrame> frames) {
    final gopro = frames.where((f) => !f.isMissing && (f.cameraMake?.toLowerCase().contains('gopro') ?? false));
    if (gopro.isEmpty) return null;
    return gopro.every((f) => f.fisheyeFlag == false) ? LensMode.linear : LensMode.unknown;
  }

  void _changed() {
    _dirty = true;
    notifyListeners();
  }

  Future<T> _exclusive<T>(Future<T> Function() body) async {
    if (_busy) throw StateError('An import is still being saved');
    _busy = true;
    notifyListeners();
    try {
      return await body();
    } finally {
      _busy = false;
      notifyListeners();
    }
  }
}
