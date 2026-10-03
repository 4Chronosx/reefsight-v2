import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:reefsight_mobile/services/crop_geometry.dart';
import 'package:reefsight_mobile/services/bleaching_classifier.dart';
import 'package:reefsight_mobile/services/colony_photos.dart';
import 'package:reefsight_mobile/services/tracked_colony_record.dart';

// Sub-plan 18 steps 2-3: each track keeps, per label, the images of its most
// confident sample (confident beats uncertain), so the photo shown can match
// the colony's final label. Only a changed best is written to disk, under
// paths relative to the documents directory.

const _bleached = 'CORAL_BL';
const _healthy = 'CORAL';

ClassifiedCrop _result(
  double confidence, {
  String label = _bleached,
  int tag = 1,
  bool withContext = true,
  bool withCrop = true,
  MaskOverlay? overlay,
}) => ClassifiedCrop(
  health: ColonyHealth(label: label, confidence: confidence),
  crop: withCrop ? Uint8List.fromList([tag, 0xC]) : null,
  context: withContext ? Uint8List.fromList([tag, 0xF]) : null,
  overlay: overlay,
);

Map<(int, String), ColonyPhoto> _byKey(List<ColonyPhoto> photos) => {
  for (final photo in photos) (photo.trackId, photo.label): photo,
};

void main() {
  group('BestColonyPhoto', () {
    test('a higher-confidence sample replaces a lower one', () {
      final best = BestColonyPhoto(confidenceFloor: 0.7);

      expect(best.offer(1, _result(0.75, tag: 1)), isTrue);
      expect(best.offer(1, _result(0.9, tag: 2)), isTrue);
      expect(best.offer(1, _result(0.8, tag: 3)), isFalse);

      expect(best.takePending().single.context, [2, 0xF]);
    });

    test('confident beats uncertain, whatever the confidences', () {
      final best = BestColonyPhoto(confidenceFloor: 0.7);

      best.offer(1, _result(0.69, tag: 1));
      expect(best.offer(1, _result(0.7, tag: 2)), isTrue);
      expect(best.offer(1, _result(0.69, tag: 3)), isFalse);

      final photo = best.takePending().single;
      expect(photo.confident, isTrue);
      expect(photo.confidence, 0.7);
    });

    test('with only uncertain samples, the most confident one is kept, '
        'marked uncertain', () {
      final best = BestColonyPhoto(confidenceFloor: 0.7);

      best.offer(1, _result(0.55, tag: 1));
      best.offer(1, _result(0.65, tag: 2));

      final photo = best.takePending().single;
      expect(photo.confident, isFalse);
      expect(photo.context, [2, 0xF]);
    });

    test('a sample with no context photo is ignored', () {
      final best = BestColonyPhoto(confidenceFloor: 0.7);

      expect(best.offer(1, _result(0.95, withContext: false)), isFalse);
      expect(best.takePending(), isEmpty);
    });

    test('each label keeps its own best', () {
      final best = BestColonyPhoto(confidenceFloor: 0.7);

      best.offer(1, _result(0.75, tag: 1));
      expect(best.offer(1, _result(0.95, label: _healthy, tag: 2)), isTrue);

      final pending = _byKey(best.takePending());
      expect(pending[(1, _bleached)]!.context, [1, 0xF]);
      expect(pending[(1, _healthy)]!.context, [2, 0xF]);
    });

    test('takePending hands each changed best over once', () {
      final best = BestColonyPhoto(confidenceFloor: 0.7)
        ..offer(1, _result(0.8))
        ..offer(2, _result(0.8));

      expect(best.takePending().map((photo) => photo.trackId), unorderedEquals([1, 2]));
      expect(best.takePending(), isEmpty);

      // The ranking survives the hand-over: a worse sample still loses.
      expect(best.offer(1, _result(0.75)), isFalse);
    });

    test('requeue gives a failed write back, unless a newer best arrived', () {
      final best = BestColonyPhoto(confidenceFloor: 0.7)..offer(1, _result(0.8, tag: 1));
      final failed = best.takePending();

      best.offer(1, _result(0.9, tag: 2));
      best.requeue(failed);

      expect(best.takePending().single.context, [2, 0xF]);

      best.requeue(failed);
      expect(best.takePending().single.context, [1, 0xF]);
    });

    test('an unclassified photo is kept once, with no crop', () {
      final best = BestColonyPhoto(confidenceFloor: 0.7);

      expect(best.offerUnclassified(1, Uint8List.fromList([1, 0xF])), isTrue);
      expect(best.offerUnclassified(1, Uint8List.fromList([2, 0xF])), isFalse);

      final photo = best.takePending().single;
      expect(photo.label, BestColonyPhoto.unclassifiedLabel);
      expect(photo.context, [1, 0xF]);
      expect(photo.crop, isNull);
      expect(photo.confident, isFalse);
    });
  });

  group('ColonyPhotoStore', () {
    late Directory documents;

    setUp(() async {
      documents = await Directory.systemTemp.createTemp('reefsight_photos_');
    });

    tearDown(() async {
      if (await documents.exists()) await documents.delete(recursive: true);
    });

    File file(String relativePath) => File(p.join(documents.path, relativePath));

    test('writes both images under colony_photos/ with relative paths', () async {
      final best = BestColonyPhoto(confidenceFloor: 0.7)..offer(7, _result(0.82, tag: 4));
      final store = ColonyPhotoStore(documentsDirectory: documents.path, sessionId: 3);

      await store.flush(best);

      final stored = store.photoFor(7)!;
      expect(stored.path, 'colony_photos/session3_track7_CORAL_BL.jpg');
      expect(stored.cropPath, 'colony_photos/session3_track7_CORAL_BL_crop.jpg');
      expect(stored.label, _bleached);
      expect(stored.confidence, 0.82);
      expect(await file(stored.path).readAsBytes(), [4, 0xF]);
      expect(await file(stored.cropPath!).readAsBytes(), [4, 0xC]);
    });

    // Review finding: the aggregate label can differ from the single most
    // confident sample's label -- three bleached samples at 0.75 outweigh one
    // healthy at 0.95. The colony is bleached, so its photo must be too.
    test('photoFor picks the photo matching the colony label', () async {
      final best = BestColonyPhoto(confidenceFloor: 0.7)
        ..offer(1, _result(0.75, tag: 1))
        ..offer(1, _result(0.95, label: _healthy, tag: 2));
      final store = ColonyPhotoStore(documentsDirectory: documents.path, sessionId: 1);
      await store.flush(best);

      expect(store.photoFor(1, label: _bleached)!.label, _bleached);
      expect(await file(store.photoFor(1, label: _bleached)!.path).readAsBytes(), [1, 0xF]);
      expect(store.photoFor(1, label: _healthy)!.label, _healthy);
    });

    test('without a label (Uncertain), photoFor picks the best overall', () async {
      final best = BestColonyPhoto(confidenceFloor: 0.7)
        ..offer(1, _result(0.75))
        ..offer(1, _result(0.95, label: _healthy))
        ..offer(2, _result(0.69))
        ..offer(2, _result(0.7, label: _healthy));
      final store = ColonyPhotoStore(documentsDirectory: documents.path, sessionId: 1);
      await store.flush(best);

      expect(store.photoFor(1)!.confidence, 0.95);
      // Confident beats uncertain here too.
      expect(store.photoFor(2)!.label, _healthy);
      // A label with no photo falls back the same way.
      expect(store.photoFor(2, label: 'OTHER')!.label, _healthy);
      expect(store.photoFor(3), isNull);
    });

    test('an unclassified photo is shown only until a classified one exists', () async {
      final best = BestColonyPhoto(confidenceFloor: 0.7)
        ..offerUnclassified(1, Uint8List.fromList([1, 0xF]));
      final store = ColonyPhotoStore(documentsDirectory: documents.path, sessionId: 1);
      await store.flush(best);

      final fallback = store.photoFor(1)!;
      expect(fallback.label, BestColonyPhoto.unclassifiedLabel);
      expect(fallback.path, 'colony_photos/session1_track1_UNCLASSIFIED.jpg');
      expect(fallback.cropPath, isNull);
      expect(await file(fallback.path).readAsBytes(), [1, 0xF]);

      // Even an uncertain classification beats it.
      best.offer(1, _result(0.55, tag: 2));
      await store.flush(best);
      expect(store.photoFor(1)!.label, _bleached);
    });

    test('writes a file only when that track\'s best changed', () async {
      final best = BestColonyPhoto(confidenceFloor: 0.7)..offer(1, _result(0.8));
      final store = ColonyPhotoStore(documentsDirectory: documents.path, sessionId: 1);
      await store.flush(best);
      final photo = file(store.photoFor(1)!.path);
      await photo.delete();

      // Nothing changed: no rewrite.
      best.offer(1, _result(0.75));
      await store.flush(best);
      expect(await photo.exists(), isFalse);

      // A better sample: rewritten.
      best.offer(1, _result(0.95, tag: 9));
      await store.flush(best);
      expect(await photo.readAsBytes(), [9, 0xF]);
      expect(store.photoFor(1)!.confidence, 0.95);
    });

    test('a missing crop leaves cropPath null', () async {
      final best = BestColonyPhoto(confidenceFloor: 0.7)..offer(1, _result(0.8, withCrop: false));
      final store = ColonyPhotoStore(documentsDirectory: documents.path, sessionId: 1);

      await store.flush(best);

      expect(store.photoFor(1)!.cropPath, isNull);
    });

    test('a failed write throws after trying the rest, and is retried next time',
        () async {
      final best = BestColonyPhoto(confidenceFloor: 0.7)
        ..offer(1, _result(0.8))
        ..offer(2, _result(0.8));
      // A directory where track 1's photo should go makes its write fail.
      final blocker = Directory(
        p.join(documents.path, 'colony_photos', 'session1_track1_CORAL_BL.jpg'),
      );
      await blocker.create(recursive: true);
      final store = ColonyPhotoStore(documentsDirectory: documents.path, sessionId: 1);

      await expectLater(store.flush(best), throwsA(isA<FileSystemException>()));
      expect(store.photoFor(1), isNull);
      expect(store.photoFor(2), isNotNull);

      await blocker.delete();
      await store.flush(best);
      expect(store.photoFor(1), isNotNull);
    });

    // Review finding: an overwrite whose crop can't be written must not leave
    // the new context photo next to the old label and confidence.
    test('a failed crop write leaves the previous photo in place', () async {
      final best = BestColonyPhoto(confidenceFloor: 0.7)..offer(1, _result(0.8, tag: 1));
      final store = ColonyPhotoStore(documentsDirectory: documents.path, sessionId: 1);
      await store.flush(best);
      final stored = store.photoFor(1)!;
      // Block the crop's temp file, so staging fails before any rename.
      await Directory('${file(stored.cropPath!).path}.tmp').create();

      best.offer(1, _result(0.95, tag: 9));
      await expectLater(store.flush(best), throwsA(isA<FileSystemException>()));

      expect(await file(stored.path).readAsBytes(), [1, 0xF]);
      expect(await file(stored.cropPath!).readAsBytes(), [1, 0xC]);
      expect(store.photoFor(1)!.confidence, 0.8);
    });

    test('relative paths resolve after the documents directory moves', () async {
      final best = BestColonyPhoto(confidenceFloor: 0.7)..offer(1, _result(0.8));
      final store = ColonyPhotoStore(documentsDirectory: documents.path, sessionId: 1);
      await store.flush(best);
      final stored = store.photoFor(1)!;

      // A reinstall gives the sandbox a new container path.
      final moved = await documents.rename('${documents.path}_moved');
      documents = moved;

      final resolved = await resolveColonyPhoto(stored.path, documentsDirectory: moved.path);
      expect(resolved, isNotNull);
      expect(await resolved!.readAsBytes(), [1, 0xF]);
    });

    test('resolveColonyPhoto is null for null or missing files', () async {
      expect(await resolveColonyPhoto(null, documentsDirectory: documents.path), isNull);
      expect(
        await resolveColonyPhoto('colony_photos/nope.jpg', documentsDirectory: documents.path),
        isNull,
      );
    });

    test('resolveColonyPhotos maps track ids to the files that exist', () async {
      final best = BestColonyPhoto(confidenceFloor: 0.7)
        ..offer(1, _result(0.8))
        ..offer(2, _result(0.8, withCrop: false));
      final store = ColonyPhotoStore(documentsDirectory: documents.path, sessionId: 1);
      await store.flush(best);
      TrackedColonyRecord row(int trackId) => TrackedColonyRecord(
        sessionId: 1,
        trackId: trackId,
        healthHistory: const [],
        firstSeenAt: DateTime.utc(2026, 1, 1),
        lastSeenAt: DateTime.utc(2026, 1, 1),
        photoPath: store.photoFor(trackId)?.path,
        photoCropPath: store.photoFor(trackId)?.cropPath,
      );

      final files = await resolveColonyPhotos(
        [row(1), row(2), row(3)],
        documentsDirectory: documents.path,
      );

      expect(files.context.keys, unorderedEquals([1, 2]));
      expect(files.crop.keys, [1]);
      expect(files.contextPaths, hasLength(2));
    });

    test('a photo with a mask overlay writes mask images beside both photos', () async {
      final best = BestColonyPhoto(confidenceFloor: 0.7)
        ..offer(1, _result(0.8, overlay: _overlay));
      final store = ColonyPhotoStore(documentsDirectory: documents.path, sessionId: 1);
      await store.flush(best);

      final contextMask = file('colony_photos/session1_track1_CORAL_BL_mask.png');
      final cropMask = file('colony_photos/session1_track1_CORAL_BL_crop_mask.png');
      // Rendered at the photos' own sizes: the 100x50 region at 320 long
      // side, and the classifier's 224x224.
      final contextImage = img.decodePng(await contextMask.readAsBytes())!;
      expect((contextImage.width, contextImage.height), (320, 160));
      final cropImage = img.decodePng(await cropMask.readAsBytes())!;
      expect((cropImage.width, cropImage.height), (224, 224));

      final files = await resolveColonyPhotos([
        TrackedColonyRecord(
          sessionId: 1,
          trackId: 1,
          healthHistory: const [],
          firstSeenAt: DateTime.utc(2026, 1, 1),
          lastSeenAt: DateTime.utc(2026, 1, 1),
          photoPath: store.photoFor(1)!.path,
          photoCropPath: store.photoFor(1)!.cropPath,
        ),
      ], documentsDirectory: documents.path);
      expect(p.normalize(files.contextMask[1]!.path), p.normalize(contextMask.path));
      expect(p.normalize(files.cropMask[1]!.path), p.normalize(cropMask.path));
    });

    test('a newer best without a mask removes the old mask images', () async {
      final best = BestColonyPhoto(confidenceFloor: 0.7)
        ..offer(1, _result(0.75, overlay: _overlay));
      final store = ColonyPhotoStore(documentsDirectory: documents.path, sessionId: 1);
      await store.flush(best);
      final mask = file('colony_photos/session1_track1_CORAL_BL_mask.png');
      expect(await mask.exists(), isTrue);

      best.offer(1, _result(0.9));
      await store.flush(best);

      expect(await mask.exists(), isFalse);
      expect(await file('colony_photos/session1_track1_CORAL_BL_crop_mask.png').exists(), isFalse);
    });
  });

  group('renderMaskOverlay', () {
    // A 2x2 mask over a 100x100 box, only the top-left cell; the photo is
    // that box exactly, at 100x100.
    img.Image render() => img.decodePng(
      renderMaskOverlay((
        mask: const [
          [1.0, 0.0],
          [0.0, 0.0],
        ],
        box: const Rect.fromLTWH(0, 0, 100, 100),
        region: const CropRegion(left: 0, top: 0, width: 100, height: 100),
        width: 100,
        height: 100,
      )),
    )!;

    test('colony pixels are a translucent fill, others transparent', () {
      final image = render();

      expect(image.getPixel(25, 25).a, maskFillAlpha);
      expect(image.getPixel(75, 75).a, 0);
      expect(image.getPixel(75, 25).a, 0);
    });

    test('the colony boundary is an opaque outline', () {
      final image = render();

      // x 49 is the last colony column before the background at x 50.
      expect(image.getPixel(49, 25).a, 255);
      expect(image.getPixel(25, 49).a, 255);
    });
  });
}

/// A mask overlay for a 100x50 box whose photos are cut from the box itself.
final _overlay = MaskOverlay(
  mask: const [
    [1.0, 1.0],
    [1.0, 0.0],
  ],
  box: const Rect.fromLTWH(10, 10, 100, 50),
  contextRegion: const CropRegion(left: 10, top: 10, width: 100, height: 50),
  cropRegion: const CropRegion(left: 10, top: 10, width: 100, height: 50),
);
