import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:reefsight_mobile/services/session_files.dart';
import 'package:reefsight_mobile/services/transect_session.dart';

// Survey deletion: a deleted session's files -- video, masks, colony photos
// -- are removed from the documents directory, and nobody else's are.

void main() {
  late Directory docs;

  setUp(() => docs = Directory.systemTemp.createTempSync('reefsight_session_files_'));
  tearDown(() => docs.deleteSync(recursive: true));

  final started = DateTime.utc(2026, 10, 1, 9);

  File touch(String relative) {
    final file = File(p.joinAll([docs.path, ...p.posix.split(relative)]));
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync([1]);
    return file;
  }

  TransectSession session({required int id, String? videoPath, DateTime? endedAt}) =>
      TransectSession(
        id: id,
        startedAt: started,
        endedAt: endedAt,
        tapeLengthMeters: 50,
        videoPath: videoPath,
      );

  test('removes the saved video, masks and every colony photo of that session only', () async {
    final video = touch('transect_2026-10-01T09-00-02-000Z.mov');
    final otherVideo = touch('transect_2026-10-01T11-00-02-000Z.mov');
    final mask = touch('masks/session1_track3.png');
    final otherMask = touch('masks/session12_track3.png');
    // Photos are per track *and* label; only one is in the DB row.
    final photo = touch('colony_photos/session1_track3_CORAL.jpg');
    final otherLabel = touch('colony_photos/session1_track3_CORAL_BL_crop.jpg');
    final staged = touch('colony_photos/session1_track4_CORAL.jpg.tmp');
    final otherPhoto = touch('colony_photos/session2_track3_CORAL.jpg');

    final removed = await deleteSessionFiles(
      session(id: 1, videoPath: video.path, endedAt: started.add(const Duration(hours: 1))),
      documentsDirectory: docs.path,
    );

    expect(removed, 5);
    for (final gone in [video, mask, photo, otherLabel, staged]) {
      expect(gone.existsSync(), isFalse, reason: gone.path);
    }
    for (final kept in [otherVideo, otherMask, otherPhoto]) {
      expect(kept.existsSync(), isTrue, reason: kept.path);
    }
  });

  test('finds a video whose stored path went stale (iOS moved the container)', () async {
    final video = touch('transect_2026-10-01T09-00-02-000Z.mov');

    await deleteSessionFiles(
      session(
        id: 1,
        videoPath: '/old/container/Documents/${p.basename(video.path)}',
        endedAt: started.add(const Duration(hours: 1)),
      ),
      documentsDirectory: docs.path,
    );

    expect(video.existsSync(), isFalse);
  });

  test("an incomplete survey's leftover recording is removed", () async {
    final orphan = touch('transect_2026-10-01T09-00-03-000Z.mov');
    final nextSurvey = touch('transect_2026-10-01T09-20-00-000Z.mov');

    await deleteSessionFiles(session(id: 1), documentsDirectory: docs.path);

    expect(orphan.existsSync(), isFalse);
    expect(nextSurvey.existsSync(), isTrue);
  });

  test('an ended survey without a saved video does not guess one', () async {
    final nearby = touch('transect_2026-10-01T09-00-03-000Z.mov');

    await deleteSessionFiles(
      session(id: 1, endedAt: started.add(const Duration(hours: 1))),
      documentsDirectory: docs.path,
    );

    expect(nearby.existsSync(), isTrue);
  });

  test('nothing on disk is fine', () async {
    expect(await deleteSessionFiles(session(id: 1), documentsDirectory: docs.path), 0);
  });
}
