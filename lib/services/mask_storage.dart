import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:image/image.dart' as img;

/// Persists a colony's segmentation mask to disk, so the SQLite schema's
/// "reference path to its mask file" (`ReefSight_Specification.md`,
/// "Storage") has something real behind it -- masks are otherwise transient
/// `List<List<double>>` in memory only (sub-plan 3's `colony_size.dart`).
class MaskStorage {
  const MaskStorage._();

  /// Threshold matches `colony_size.dart`'s existing convention for
  /// foreground-vs-background.
  static const double _threshold = 0.5;

  /// Encodes [mask] as a black/white PNG (white = foreground, above
  /// [_threshold]) under `<outputDirectory>/masks/`, named by [sessionId]
  /// and [trackId], and returns the written file's path.
  ///
  /// Encoding runs on a background isolate via [compute] -- mask grids can
  /// be large and this shouldn't block the caller's isolate, mirroring
  /// `bleaching_classifier.dart`'s use of [compute] for its own image work.
  static Future<String> save({
    required String outputDirectory,
    required int sessionId,
    required int trackId,
    required List<List<double>> mask,
  }) async {
    final maskDir = Directory('$outputDirectory/masks');
    if (!maskDir.existsSync()) {
      maskDir.createSync(recursive: true);
    }

    final path = '${maskDir.path}/session${sessionId}_track$trackId.png';
    final bytes = await compute(_encodePng, mask);
    await File(path).writeAsBytes(bytes);
    return path;
  }
}

/// Must stay a top-level (or static) function with no captured state --
/// [compute] runs it on a separate isolate.
Uint8List _encodePng(List<List<double>> mask) {
  final rows = mask.length;
  final cols = rows == 0 ? 0 : mask.first.length;

  final image = img.Image(width: cols == 0 ? 1 : cols, height: rows == 0 ? 1 : rows);
  img.fill(image, color: img.ColorRgb8(0, 0, 0));

  for (var y = 0; y < rows; y++) {
    for (var x = 0; x < cols; x++) {
      if (mask[y][x] >= MaskStorage._threshold) {
        image.setPixelRgb(x, y, 255, 255, 255);
      }
    }
  }

  return Uint8List.fromList(img.encodePng(image));
}
