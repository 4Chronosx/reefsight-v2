import 'photo_metadata.dart';

/// Issue #5: one photo copied into the app for a photo transect, before (or
/// after) it has a meter mark. [frameId] is set once it has a
/// `transect_frames` row -- a photo from an earlier import being reordered.
class ImportedPhoto {
  const ImportedPhoto({
    required this.relativePath,
    required this.originalName,
    required this.metadata,
    this.frameId,
    this.savedFisheyeFlag,
  });

  /// The `fisheye_flag` a saved row already has. Only the flag is stored,
  /// not the focal length it came from, so a re-save keeps it rather than
  /// re-deriving it from metadata that no longer has the lens.
  final bool? savedFisheyeFlag;

  /// The copy in app storage, relative to the documents directory.
  final String relativePath;

  /// The source file's name, for display and the filename fallback order.
  final String originalName;
  final PhotoMetadata metadata;
  final int? frameId;
}

/// True when every photo has an EXIF capture time, so [sortForImport] put
/// them in time order. Shown on the import screen ("Ordered by capture time"
/// / "by filename"), so the diver knows which to double-check.
bool orderedByTime(List<ImportedPhoto> photos) =>
    photos.isNotEmpty && photos.every((p) => p.metadata.capturedAt != null);

/// Tape order for a new import (alignment doc §9): by EXIF capture time,
/// with the filename as the tie-break (a burst inside one second). If *any*
/// photo has no capture time, all of them go by filename -- mixing the two
/// rules would put the untimed photos at an arbitrary place in the run.
/// Returns a new list; [photos] is left as it was.
List<ImportedPhoto> sortForImport(List<ImportedPhoto> photos) {
  final byTime = orderedByTime(photos);
  return [...photos]..sort((a, b) {
      if (byTime) {
        final t = a.metadata.capturedAt!.compareTo(b.metadata.capturedAt!);
        if (t != 0) return t;
      }
      return naturalCompare(a.originalName, b.originalName);
    });
}

final _chunks = RegExp(r'\d+|\D+');

/// Filename order a person expects: digit runs compare as numbers, so
/// `IMG_9` comes before `IMG_10`, and case is ignored. Ties (`img_01` and
/// `img_1`) are broken by the plain text, so the order is total.
int naturalCompare(String a, String b) {
  final ca = _chunks.allMatches(a.toLowerCase()).map((m) => m[0]!).toList();
  final cb = _chunks.allMatches(b.toLowerCase()).map((m) => m[0]!).toList();
  for (var i = 0; i < ca.length && i < cb.length; i++) {
    final x = ca[i], y = cb[i];
    final nx = int.tryParse(x), ny = int.tryParse(y);
    final c = nx != null && ny != null ? nx.compareTo(ny) : x.compareTo(y);
    if (c != 0) return c;
  }
  final byLength = ca.length.compareTo(cb.length);
  return byLength != 0 ? byLength : a.compareTo(b);
}
