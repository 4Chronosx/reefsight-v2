import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reefsight_mobile/services/tracked_colony_record.dart';
import 'package:reefsight_mobile/services/transect_recorder.dart';
import 'package:reefsight_mobile/services/transect_session.dart';
import 'package:reefsight_mobile/services/transect_video.dart';

// Sub-plan 16: a colony's wall-clock sighting -> a position in the transect
// video. Video zero is the stored recording start, else the timestamp in the
// recording's file name, else the session start (the last two flagged
// approximate).

void main() {
  final sessionStart = DateTime.utc(2026, 10, 1, 9, 0, 0);
  final videoStart = DateTime.utc(2026, 10, 1, 9, 0, 1, 500);

  TransectSession session({
    DateTime? videoStartedAt,
    String? videoPath,
    DateTime? endedAt,
  }) =>
      TransectSession(
        startedAt: sessionStart,
        endedAt: endedAt,
        tapeLengthMeters: 50,
        videoPath: videoPath,
        videoStartedAt: videoStartedAt,
      );

  TrackedColonyRecord colony(DateTime firstSeen, [DateTime? lastSeen]) => TrackedColonyRecord(
        sessionId: 1,
        trackId: 12,
        healthHistory: const [],
        firstSeenAt: firstSeen,
        lastSeenAt: lastSeen ?? firstSeen,
      );

  group('videoOffsetFor', () {
    test('seeks 2 s before the first sighting, measured from the recording start', () {
      final offset = videoOffsetFor(
        colony(videoStart.add(const Duration(minutes: 3, seconds: 41)),
            videoStart.add(const Duration(minutes: 3, seconds: 52))),
        session(videoStartedAt: videoStart),
      );

      expect(offset.start, const Duration(minutes: 3, seconds: 39));
      expect(offset.firstSeen, const Duration(minutes: 3, seconds: 41));
      expect(offset.lastSeen, const Duration(minutes: 3, seconds: 52));
      expect(offset.approximate, isFalse);
    });

    test('a colony seen in the first 2 s clamps the pre-roll at 0', () {
      final offset = videoOffsetFor(
        colony(videoStart.add(const Duration(milliseconds: 800))),
        session(videoStartedAt: videoStart),
      );

      expect(offset.start, Duration.zero);
    });

    test('a colony seen before the recording started clamps at 0', () {
      final offset = videoOffsetFor(
        colony(sessionStart),
        session(videoStartedAt: videoStart),
      );

      expect(offset.start, Duration.zero);
      expect(offset.firstSeen, Duration.zero);
    });

    test('clamps at the end of the session', () {
      final offset = videoOffsetFor(
        colony(videoStart.add(const Duration(minutes: 10))),
        session(
          videoStartedAt: videoStart,
          endedAt: videoStart.add(const Duration(minutes: 5)),
        ),
      );

      expect(offset.start, const Duration(minutes: 5));
    });

    test('without videoStartedAt, falls back to the file-name timestamp, approximate', () {
      final offset = videoOffsetFor(
        colony(DateTime.utc(2026, 10, 1, 9, 1, 0)),
        session(videoPath: '/docs/transect_2026-10-01T09-00-02-250Z.mov'),
      );

      expect(offset.start, const Duration(seconds: 55, milliseconds: 750));
      expect(offset.approximate, isTrue);
    });

    test('with no usable file name either, falls back to startedAt, approximate', () {
      final offset = videoOffsetFor(
        colony(DateTime.utc(2026, 10, 1, 9, 1, 0)),
        session(videoPath: '/docs/clip.mov'),
      );

      expect(offset.start, const Duration(seconds: 58));
      expect(offset.approximate, isTrue);
    });
  });

  group('videoStartFromFileName', () {
    test('parses the millisecond and microsecond forms TransectRecorder writes', () {
      expect(
        videoStartFromFileName('/a/b/transect_2026-10-01T09-12-33-123Z.mov'),
        DateTime.utc(2026, 10, 1, 9, 12, 33, 123),
      );
      expect(
        videoStartFromFileName('transect_2026-10-01T09-12-33-123456Z.mov'),
        DateTime.utc(2026, 10, 1, 9, 12, 33, 123, 456),
      );
    });

    test("parses the name TransectRecorder's default builder actually writes", () async {
      final recorder = TransectRecorder(startRecording: (_) async {}, stopRecording: () async {});
      final before = DateTime.now().toUtc();
      final path = await recorder.start('/docs');

      final parsed = videoStartFromFileName(path);
      expect(parsed, isNotNull, reason: path);
      expect(parsed!.difference(before).inSeconds.abs(), lessThan(5));
    });

    test('returns null for anything else', () {
      expect(videoStartFromFileName(null), isNull);
      expect(videoStartFromFileName('/docs/clip.mov'), isNull);
      expect(videoStartFromFileName('transect_2026-13-45T99-99-99-000Z.mov'), isNull);
    });
  });

  test('formatVideoTime pads minutes and seconds, adds hours past an hour', () {
    expect(formatVideoTime(const Duration(minutes: 3, seconds: 41)), '03:41');
    expect(formatVideoTime(const Duration(hours: 1, minutes: 2, seconds: 3)), '1:02:03');
  });

  recordingFailureTests();
}

// Recording failures used to be silent end to end: the native start
// reported success even when it failed, End Transect saved the planned path
// anyway, and Summary hid the video button without a word. Now the path is
// saved only for a real, non-empty file, and Summary says why there's none.
void recordingFailureTests() {
  group('recordedVideoPath', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('reefsight_video_'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('keeps the path of a non-empty file', () async {
      final file = File('${dir.path}/transect_a.mov')..writeAsBytesSync([1, 2, 3]);
      expect(await recordedVideoPath(file.path), file.path);
    });

    test('drops a path whose file was never written', () async {
      expect(await recordedVideoPath('${dir.path}/transect_missing.mov'), isNull);
    });

    test('drops an empty file', () async {
      final file = File('${dir.path}/transect_empty.mov')..createSync();
      expect(await recordedVideoPath(file.path), isNull);
    });

    test('no path (recording never started) stays null', () async {
      expect(await recordedVideoPath(null), isNull);
    });
  });

  group('missingVideoNote', () {
    final start = DateTime.utc(2026, 10, 1, 9);

    TransectSession session({String? videoPath, bool ended = true}) => TransectSession(
          startedAt: start,
          endedAt: ended ? start.add(const Duration(minutes: 30)) : null,
          tapeLengthMeters: 50,
          videoPath: videoPath,
        );

    test('no note when the video was found', () {
      expect(
        missingVideoNote(session(videoPath: '/x/transect_a.mov'), File('/x/transect_a.mov')),
        isNull,
      );
    });

    test('a survey that did not end normally', () {
      expect(
        missingVideoNote(session(ended: false), null),
        "No video: this survey didn't end normally, so its recording wasn't saved.",
      );
    });

    test('ended, but no recording was saved', () {
      expect(
        missingVideoNote(session(), null),
        "No video: the camera didn't record a file during this survey.",
      );
    });

    test('a saved path whose file is gone names the file', () {
      expect(
        missingVideoNote(session(videoPath: '/old/container/transect_2026-10-01T09-00-01-500Z.mov'), null),
        'No video: transect_2026-10-01T09-00-01-500Z.mov is not on this phone.',
      );
    });
  });
}
