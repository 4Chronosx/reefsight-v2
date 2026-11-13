import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path/path.dart' as p;

/// Issue #4: where photo-transect stills live on the phone --
/// `<documents>/transect_photos/session<id>_m<NN>_<epoch ms>.jpg`.
///
/// Same conventions as `ColonyPhotoStore`: paths are stored relative to the
/// documents directory with `/` separators (iOS moves the app's container
/// on reinstall), the `session<id>_` prefix lets `deleteSessionFiles` sweep
/// them, and a file only appears under its real name once it is complete.
/// Each shot gets its own name (the capture time is in it), so a retake
/// never overwrites the photo it replaces before the database has switched
/// to the new one.
class PhotoTransectStore {
  PhotoTransectStore({required this.documentsDirectory, required this.sessionId});

  static const String folder = 'transect_photos';

  final String documentsDirectory;
  final int sessionId;

  String absolutePath(String relativePath) =>
      p.joinAll([documentsDirectory, ...p.posix.split(relativePath)]);

  /// Moves the camera's temp file at [sourcePath] into the store and reads
  /// its pixel size from the JPEG header (no full decode of a 12 MP image).
  /// The size is `null` if the header can't be read.
  Future<StoredStill> save(String sourcePath, {required double meterMark, required DateTime at}) async {
    await Directory(p.join(documentsDirectory, folder)).create(recursive: true);
    final meter = meterMark.round().toString().padLeft(2, '0');
    final relative = p.posix.join(folder, 'session${sessionId}_m${meter}_${at.millisecondsSinceEpoch}.jpg');
    final target = absolutePath(relative);
    final staged = File('$target.tmp');

    try {
      try {
        await File(sourcePath).rename(staged.path);
      } on FileSystemException {
        // The camera's temp directory can be on another volume.
        await File(sourcePath).copy(staged.path);
        await _deleteQuietly(File(sourcePath));
      }
      await staged.rename(target);
    } catch (_) {
      await _deleteQuietly(staged);
      rethrow;
    }

    final size = jpegPixelSize(await File(target).readAsBytes());
    return StoredStill(relativePath: relative, width: size?.width, height: size?.height);
  }

  /// Issue #5: copies an imported photo into the store as
  /// `session<id>_imp<NNN>_<epoch ms>.<ext>` and returns its relative path.
  /// A **copy**, never a move: the source (the picker's file, or one in the
  /// Files app) is left exactly as it was. The extension is kept, lowercased
  /// (`.jpg`, `.heic`), so the format stays visible; `.img` if there is
  /// none. [index] is the photo's position in the import, so names don't
  /// collide within one [at].
  Future<String> importCopy(String sourcePath, {required int index, required DateTime at}) async {
    await Directory(p.join(documentsDirectory, folder)).create(recursive: true);
    final ext = p.extension(sourcePath).toLowerCase();
    final n = index.toString().padLeft(3, '0');
    final relative =
        p.posix.join(folder, 'session${sessionId}_imp${n}_${at.millisecondsSinceEpoch}${ext.isEmpty ? '.img' : ext}');
    final target = absolutePath(relative);
    final staged = File('$target.tmp');
    try {
      await File(sourcePath).copy(staged.path);
      await staged.rename(target);
    } catch (_) {
      await _deleteQuietly(staged);
      rethrow;
    }
    return relative;
  }

  /// Removes a stored still. An empty path (a missing meter) or a file
  /// that's already gone is fine; a failed delete is logged, never thrown --
  /// the worst case is a leftover file, which the survey delete sweeps.
  Future<void> delete(String relativePath) async {
    if (relativePath.isEmpty) return;
    await _deleteQuietly(File(absolutePath(relativePath)));
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (error) {
      debugPrint('ReefSight: could not delete ${file.path}: $error');
    }
  }
}

class StoredStill {
  const StoredStill({required this.relativePath, this.width, this.height});

  final String relativePath;
  final int? width;
  final int? height;
}

/// The pixel size in a JPEG's SOF header, or `null` if [bytes] isn't a
/// JPEG or ends before one. Walks the marker segments from the start, so an
/// iPhone's large EXIF/MPF segments ahead of the SOF are skipped by length.
({int width, int height})? jpegPixelSize(Uint8List bytes) {
  if (bytes.length < 4 || bytes[0] != 0xFF || bytes[1] != 0xD8) return null;
  var i = 2;
  while (i + 1 < bytes.length) {
    if (bytes[i] != 0xFF) return null;
    // Fill bytes: any number of 0xFF before the marker code.
    while (i < bytes.length && bytes[i] == 0xFF) {
      i++;
    }
    if (i >= bytes.length) return null;
    final marker = bytes[i++];
    if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) continue; // no length
    if (marker == 0xD9 || marker == 0xDA) return null; // EOI / SOS before any SOF
    if (i + 1 >= bytes.length) return null;
    final length = (bytes[i] << 8) | bytes[i + 1];
    final isSof = marker >= 0xC0 && marker <= 0xCF && marker != 0xC4 && marker != 0xC8 && marker != 0xCC;
    if (isSof) {
      if (i + 6 >= bytes.length) return null;
      final height = (bytes[i + 3] << 8) | bytes[i + 4];
      final width = (bytes[i + 5] << 8) | bytes[i + 6];
      return (width: width, height: height);
    }
    if (length < 2) return null;
    i += length;
  }
  return null;
}
