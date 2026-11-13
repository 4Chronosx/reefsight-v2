import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:reefsight_mobile/services/photo_import.dart';
import 'package:reefsight_mobile/services/photo_import_checks.dart';
import 'package:reefsight_mobile/services/photo_metadata.dart';
import 'package:reefsight_mobile/services/photo_transect_store.dart';
import 'package:reefsight_mobile/services/station.dart';
import 'package:reefsight_mobile/services/transect_database.dart';
import 'package:reefsight_mobile/services/transect_frame.dart';
import 'package:reefsight_mobile/services/transect_session.dart';

// Issue #5: the state of one transect's photo import -- pick, copy, order,
// reorder, drop, gap, save -- kept out of the screen so it can be tested
// without a picker.

/// Each source file's contents are its own name, so the fake finds a
/// copy's metadata by reading it, whatever the copy is called.
class _FakeReader implements PhotoMetadataReader {
  _FakeReader(this.byName);
  final Map<String, PhotoMetadata> byName;

  @override
  Future<PhotoMetadata> read(String path) async => byName[File(path).readAsStringSync()] ?? const PhotoMetadata();
}

void main() {
  late Directory docs;
  late Directory src;
  late TransectDatabase db;
  late int sessionId;
  late Map<String, PhotoMetadata> meta;
  late PhotoImport import;

  PickedPhoto pick(String name) {
    final file = File(p.join(src.path, name))..writeAsStringSync(name);
    return PickedPhoto(path: file.path, name: name);
  }

  PhotoImport newImport() => PhotoImport(
        db: db,
        store: PhotoTransectStore(documentsDirectory: docs.path, sessionId: sessionId),
        reader: _FakeReader(meta),
        sessionId: sessionId,
        tapeLengthMeters: 4,
        clock: () => DateTime.fromMillisecondsSinceEpoch(1000),
      );

  List<String> order(PhotoImport i) => [
        for (final s in i.slots)
          switch (s) {
            PhotoSlot(:final photo) => photo.originalName,
            GapSlot() => '-',
          },
      ];

  setUp(() async {
    docs = await Directory.systemTemp.createTemp('reefsight_docs_');
    src = await Directory.systemTemp.createTemp('reefsight_src_');
    db = await TransectDatabase.openInMemoryForTest();
    final stationId = await db.insertStation(Station(
      code: 'ALG-S2',
      surveyType: SurveyType.photoTransect,
      frameMode: FrameMode.importedMixed,
      surveyedOn: DateTime(2026, 11, 15),
      siteName: 'Alegria MPA',
      createdAt: DateTime.utc(2026, 11, 15, 1),
    ));
    sessionId = await db.insertSession(TransectSession(
      startedAt: DateTime.utc(2026, 11, 15, 2),
      tapeLengthMeters: 4,
      stationId: stationId,
      transectNumber: 1,
      captureSource: CaptureSource.importedPhotos,
    ));
    meta = {
      for (var i = 0; i < 8; i++)
        'G$i.JPG': PhotoMetadata(
          width: 4000,
          height: 3000,
          make: 'GoPro',
          model: 'HERO11 Black',
          capturedAt: DateTime(2026, 11, 15, 9, 0, 10 - i), // shot in reverse name order
        ),
    };
    import = newImport();
  });

  tearDown(() async {
    import.dispose();
    await db.close();
    await docs.delete(recursive: true);
    await src.delete(recursive: true);
  });

  test('a first pick is copied, read and put in capture-time order', () async {
    await import.addPhotos([pick('G0.JPG'), pick('G1.JPG'), pick('G2.JPG')]);
    expect(order(import), ['G2.JPG', 'G1.JPG', 'G0.JPG']);
    expect(import.orderedByTime, isTrue);
    expect(File(p.join(src.path, 'G0.JPG')).existsSync(), isTrue, reason: 'sources untouched');
    final copied = (import.slots.first as PhotoSlot).photo.relativePath;
    expect(File(p.join(docs.path, copied)).existsSync(), isTrue);
  });

  test('a later pick is appended after what is already there, in its own order', () async {
    await import.addPhotos([pick('G0.JPG')]);
    await import.addPhotos([pick('G3.JPG'), pick('G4.JPG')]);
    expect(order(import), ['G0.JPG', 'G4.JPG', 'G3.JPG']);
  });

  test('reorder, insert a gap, drop', () async {
    await import.addPhotos([pick('G0.JPG'), pick('G1.JPG'), pick('G2.JPG')]); // G2 G1 G0
    import.move(0, 3); // ReorderableListView semantics: to the end
    expect(order(import), ['G1.JPG', 'G0.JPG', 'G2.JPG']);
    import.insertGap(1);
    expect(order(import), ['G1.JPG', '-', 'G0.JPG', 'G2.JPG']);
    import.drop(3);
    expect(order(import), ['G1.JPG', '-', 'G0.JPG']);
    import.drop(1);
    expect(order(import), ['G1.JPG', 'G0.JPG']);
  });

  test('meter marks are positions along the list', () async {
    await import.addPhotos([pick('G0.JPG'), pick('G1.JPG')]);
    import.insertGap(0);
    expect([for (var i = 0; i < import.slots.length; i++) import.meterAt(i)], [0, 1, 2]);
  });

  test('checks: expected count, too many to save, far off', () async {
    expect(import.expectedCount, 5); // a 4 m tape: meters 0-4
    await import.addPhotos([for (var i = 0; i < 7; i++) pick('G$i.JPG')]);
    expect(import.extraCount, 2);
    expect(import.canSave, isFalse, reason: 'more photos than meters: drop the extras first');
    import.drop(0);
    import.drop(0);
    expect(import.extraCount, 0);
    expect(import.canSave, isTrue);
    expect(import.countFarOff, isFalse);
  });

  test('a GoPro import asks for the lens mode; Linear clears the fisheye flag', () async {
    await import.addPhotos([pick('G0.JPG')]);
    expect(import.needsLensAnswer, isTrue);
    expect(import.fisheyeSuspected((import.slots.single as PhotoSlot).photo), isTrue);
    import.setLensMode(LensMode.linear);
    expect(import.needsLensAnswer, isFalse);
    expect(import.fisheyeSuspected((import.slots.single as PhotoSlot).photo), isFalse);
  });

  test("a non-GoPro photo's saved fisheye flag survives a reorder and re-save (review fix)", () async {
    meta['W0.JPG'] = PhotoMetadata(width: 4000, height: 3000, make: 'Olympus', focalLength35mm: 8, capturedAt: DateTime(2026));
    meta['W1.JPG'] = PhotoMetadata(width: 4000, height: 3000, make: 'Olympus', focalLength35mm: 8, capturedAt: DateTime(2027));
    await import.addPhotos([pick('W0.JPG'), pick('W1.JPG')]);
    await import.save();
    expect((await db.framesForSession(sessionId)).every((f) => f.fisheyeFlag == true), isTrue);

    final again = newImport();
    addTearDown(again.dispose);
    await again.load();
    again.move(1, 0);
    await again.save();
    expect((await db.framesForSession(sessionId)).every((f) => f.fisheyeFlag == true), isTrue);
  });

  test('each gap is its own slot, so a list can key them apart', () async {
    import.insertGap(0);
    import.insertGap(0);
    expect(identical(import.slots[0], import.slots[1]), isFalse);
  });

  test('save writes frames and gaps with their EXIF fields', () async {
    await import.addPhotos([pick('G0.JPG'), pick('G1.JPG')]);
    import.insertGap(1);
    import.setLensMode(LensMode.wide);
    await import.save();

    final frames = await db.framesForSession(sessionId);
    expect(frames.map((f) => f.meterMark), [0, 1, 2]);
    expect(frames[0].source, FrameSource.imported);
    expect(frames[0].cameraMake, 'GoPro');
    expect(frames[0].cameraModel, 'HERO11 Black');
    expect(frames[0].capturedAt, DateTime(2026, 11, 15, 9, 0, 9));
    expect(frames[0].widthPx, 4000);
    expect(frames[0].fisheyeFlag, isTrue);
    expect(frames[1].isMissing, isTrue);
    expect(frames[1].source, FrameSource.imported);
    expect(import.dirty, isFalse);
  });

  test('load resumes a saved import; reorder and re-save keeps the rows', () async {
    await import.addPhotos([pick('G0.JPG'), pick('G1.JPG')]);
    await import.save();
    final before = await db.framesForSession(sessionId);

    final again = newImport();
    addTearDown(again.dispose);
    await again.load();
    expect(again.slots, hasLength(2));
    again.move(1, 0);
    await again.save();

    final after = await db.framesForSession(sessionId);
    expect(after.map((f) => f.id), [before[1].id, before[0].id]);
  });

  test('load turns meters with no row into gaps, so positions stay put', () async {
    await db.saveImportedFrames(sessionId, [
      TransectFrame(sessionId: sessionId, meterMark: 0, imagePath: 'transect_photos/a.jpg', source: FrameSource.imported),
      TransectFrame(sessionId: sessionId, meterMark: 2, imagePath: 'transect_photos/b.jpg', source: FrameSource.imported),
    ]);
    await import.load();
    expect(import.slots.map((s) => s is GapSlot), [false, true, false]);
  });

  test('a saved photo dropped and re-saved has its file deleted after the commit', () async {
    await import.addPhotos([pick('G0.JPG'), pick('G1.JPG')]);
    await import.save();
    final path = (import.slots.first as PhotoSlot).photo.relativePath;
    import.drop(0);
    await import.save();
    expect(File(p.join(docs.path, path)).existsSync(), isFalse);
    expect(await db.framesForSession(sessionId), hasLength(1));
  });

  test('discard deletes copies that were never saved, and keeps saved ones', () async {
    await import.addPhotos([pick('G0.JPG')]);
    await import.save();
    final saved = (import.slots.single as PhotoSlot).photo.relativePath;
    await import.addPhotos([pick('G1.JPG')]);
    final unsaved = (import.slots.last as PhotoSlot).photo.relativePath;
    expect(import.dirty, isTrue);

    await import.discard();

    expect(File(p.join(docs.path, unsaved)).existsSync(), isFalse);
    expect(File(p.join(docs.path, saved)).existsSync(), isTrue);
  });

  test('a photo that fails to copy is reported and the rest still import', () async {
    await import.addPhotos([pick('G0.JPG'), PickedPhoto(path: p.join(src.path, 'vanished.jpg'), name: 'vanished.jpg')]);
    expect(order(import), ['G0.JPG']);
    expect(import.failedNames, ['vanished.jpg']);
  });

  test('progress counts up while copying and busy blocks a second pick', () async {
    final seen = <int>[];
    import.addListener(() => seen.add(import.progressDone));
    final first = import.addPhotos([pick('G0.JPG'), pick('G1.JPG')]);
    expect(import.busy, isTrue);
    await expectLater(import.addPhotos([pick('G2.JPG')]), throwsStateError);
    await first;
    expect(import.busy, isFalse);
    expect(seen, containsAllInOrder([1, 2]));
  });
}
