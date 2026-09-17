import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:reefsight_mobile/services/mask_storage.dart';

// Sub-plan 4 (storage-and-metrics), task 4: masks are transient
// `List<List<double>>` in memory only (sub-plan 3's `colony_size.dart`) --
// the schema's "reference path to its mask file"
// (ReefSight_Specification.md, "Storage") needs an actual write-to-disk
// step. Threshold matches `colony_size.dart`'s existing 0.5 convention.
// Uses `dart:io` directly (a real temp directory) rather than
// `path_provider`, since the directory is a caller-supplied parameter here
// -- `path_provider`'s platform channel is only needed by the live screen
// that supplies it, not by this test.

void main() {
  group('MaskStorage', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('mask_storage_test');
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('writes a PNG whose foreground pixel count matches the '
        'thresholded mask', () async {
      const mask = [
        [0.0, 1.0],
        [1.0, 0.0],
      ];

      final path = await MaskStorage.save(
        outputDirectory: tempDir.path,
        sessionId: 1,
        trackId: 7,
        mask: mask,
      );

      final file = File(path);
      expect(file.existsSync(), isTrue);

      final decoded = img.decodePng(file.readAsBytesSync())!;
      expect(decoded.width, 2);
      expect(decoded.height, 2);

      var foregroundPixels = 0;
      for (var y = 0; y < decoded.height; y++) {
        for (var x = 0; x < decoded.width; x++) {
          if (decoded.getPixel(x, y).r > 0) foregroundPixels++;
        }
      }
      expect(foregroundPixels, 2);
    });

    test('file path is scoped by session and track id', () async {
      const mask = [
        [1.0],
      ];

      final path = await MaskStorage.save(
        outputDirectory: tempDir.path,
        sessionId: 3,
        trackId: 9,
        mask: mask,
      );

      expect(path, contains('3'));
      expect(path, contains('9'));
      expect(path, endsWith('.png'));
    });

    test('an empty mask writes a valid (all-background) file rather than '
        'throwing', () async {
      final path = await MaskStorage.save(
        outputDirectory: tempDir.path,
        sessionId: 1,
        trackId: 1,
        mask: const [],
      );

      expect(File(path).existsSync(), isTrue);
    });
  });
}
