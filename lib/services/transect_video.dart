import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'tracked_colony_record.dart';
import 'transect_session.dart';

/// Resolves a session's stored `video_path` to a file that actually exists
/// on disk, or `null` if there isn't one.
///
/// `TransectSession.videoPath` is stored as an absolute path, but iOS moves
/// the app's sandbox container (a new UUID in the path) on every reinstall
/// and on some app updates -- the recording is still in Documents, just not
/// at the old absolute path. So this falls back to looking the file up by
/// name in the *current* documents directory before giving up, instead of
/// hiding the video just because the stored prefix went stale.
Future<File?> resolveTransectVideo(String? storedPath) async {
  if (storedPath == null || storedPath.isEmpty) return null;

  final direct = File(storedPath);
  if (await direct.exists()) return direct;

  final documentsDir = await getApplicationDocumentsDirectory();
  final relocated = File(p.join(documentsDir.path, p.basename(storedPath)));
  if (await relocated.exists()) return relocated;

  return null;
}

/// How long after a survey's start its recording can begin: the Live screen
/// waits up to 10 s for the camera view and 1.5 s more before starting.
const orphanedVideoWindow = Duration(minutes: 1);

/// Crash recovery: the recording of [session], which never reached End
/// Transect (so no path was saved), found in [directory] by the start time
/// in its file name -- the earliest non-empty `transect_*.mov` from a few
/// seconds before the survey started to [orphanedVideoWindow] after. Every
/// survey starts its own recording, so the next survey's file is minutes
/// later. The file may end early (iOS writes it in ~10 s fragments) but
/// plays up to the crash.
Future<File?> findOrphanedVideo(TransectSession session, String directory) async {
  final from = session.startedAt.subtract(const Duration(seconds: 5));
  final to = session.startedAt.add(orphanedVideoWindow);
  File? best;
  DateTime? bestStart;
  await for (final entity in Directory(directory).list()) {
    if (entity is! File) continue;
    final start = videoStartFromFileName(entity.path);
    if (start == null || start.isBefore(from) || start.isAfter(to)) continue;
    if (await entity.length() == 0) continue;
    if (bestStart == null || start.isBefore(bestStart)) {
      best = entity;
      bestStart = start;
    }
  }
  return best;
}

/// Summary's video for [session]: the saved path ([resolveTransectVideo]),
/// or, for a survey that never ended normally, its leftover recording
/// ([findOrphanedVideo]). An ended survey without a saved path is not
/// guessed at: End Transect already checked and found no file.
/// [documentsDirectory] defaults to the app's documents directory.
Future<File?> resolveSessionVideo(
  TransectSession session, {
  String? documentsDirectory,
}) async {
  final stored = session.videoPath;
  if (stored != null && stored.isNotEmpty) return resolveTransectVideo(stored);
  if (session.endedAt != null) return null;
  final directory =
      documentsDirectory ?? (await getApplicationDocumentsDirectory()).path;
  return findOrphanedVideo(session, directory);
}

/// The recording path to save at End Transect: [path] only if a non-empty
/// file is actually there. The native start can report success without
/// recording (third_party/ultralytics_yolo/PATCH.md), so whether
/// `startRecording` threw is not enough -- the file is the evidence. `null`
/// means no video, which Summary explains ([missingVideoNote]).
Future<String?> recordedVideoPath(String? path) async {
  if (path == null) return null;
  final file = File(path);
  if (!await file.exists()) return null;
  return await file.length() > 0 ? path : null;
}

/// Summary's line when [session] has no playable video ([resolved] is
/// `null`), or `null` when it does. Before this, a failed recording just
/// hid the video button. A stored path whose file is gone names the file, so
/// it can be looked for in the Files app (On My iPhone > ReefSight).
String? missingVideoNote(TransectSession session, File? resolved) {
  if (resolved != null) return null;
  final stored = session.videoPath;
  if (stored != null && stored.isNotEmpty) {
    return 'No video: ${p.basename(stored)} is not on this phone.';
  }
  if (session.endedAt == null) {
    return "No video: this survey didn't end normally, so its recording wasn't saved.";
  }
  return "No video: the camera didn't record a file during this survey.";
}

/// Sub-plan 16: where a colony sits in its session's transect video.
class VideoOffset {
  const VideoOffset({
    required this.start,
    required this.firstSeen,
    required this.lastSeen,
    required this.approximate,
  });

  /// Where to open the player: [colonyPreRoll] before [firstSeen], clamped
  /// to the recording.
  final Duration start;

  /// The colony's sighting window, in video time.
  final Duration firstSeen;
  final Duration lastSeen;

  /// Video zero was estimated, not stored: the session predates schema v8
  /// (`TransectSession.videoStartedAt`).
  final bool approximate;
}

/// Opens the player this long before a colony's first sighting -- absorbs
/// the native recorder starting a little after `TransectRecorder.start`
/// returns, and gives the viewer context.
const colonyPreRoll = Duration(seconds: 2);

/// Maps [colony]'s wall-clock sighting to a position in [session]'s video.
///
/// Video zero is `videoStartedAt` when stored. Older sessions fall back to
/// the timestamp in the recording's file name (taken just before the native
/// start call), then to `startedAt` (which precedes the DB open and insert,
/// so it's the loosest) -- both flagged [VideoOffset.approximate]. The start
/// is clamped at 0 and, when the session ended, at its end; the player
/// clamps again against the file's real duration, which isn't known here.
VideoOffset videoOffsetFor(
  TrackedColonyRecord colony,
  TransectSession session, {
  Duration preRoll = colonyPreRoll,
}) {
  final stored = session.videoStartedAt;
  final zero = stored ?? videoStartFromFileName(session.videoPath) ?? session.startedAt;

  Duration at(DateTime t) {
    final d = t.difference(zero);
    return d.isNegative ? Duration.zero : d;
  }

  var start = at(colony.firstSeenAt) - preRoll;
  if (start.isNegative) start = Duration.zero;
  final endedAt = session.endedAt;
  if (endedAt != null && start > at(endedAt)) start = at(endedAt);

  return VideoOffset(
    start: start,
    firstSeen: at(colony.firstSeenAt),
    lastSeen: at(colony.lastSeenAt),
    approximate: stored == null,
  );
}

/// The UTC time `TransectRecorder._defaultFileName` wrote into a recording's
/// name (`transect_2026-10-01T09-12-33-123Z.mov`, `:`/`.` replaced by `-`),
/// or `null` if [path] isn't one of those.
DateTime? videoStartFromFileName(String? path) {
  if (path == null) return null;
  final match = _fileNamePattern.firstMatch(p.basename(path));
  if (match == null) return null;
  final [year, month, day, hour, minute, second] =
      [for (var i = 1; i <= 6; i++) int.parse(match.group(i)!)];
  final fraction = match.group(7)!.padRight(6, '0');
  final parsed = DateTime.utc(
    year,
    month,
    day,
    hour,
    minute,
    second,
    int.parse(fraction.substring(0, 3)),
    int.parse(fraction.substring(3)),
  );
  // DateTime.utc normalizes out-of-range fields (month 13 -> next year);
  // a name that doesn't survive the round trip isn't a real timestamp.
  final valid = parsed.month == month && parsed.day == day && parsed.hour == hour &&
      parsed.minute == minute && parsed.second == second;
  return valid ? parsed : null;
}

final _fileNamePattern =
    RegExp(r'^transect_(\d{4})-(\d{2})-(\d{2})T(\d{2})-(\d{2})-(\d{2})-(\d{3,6})Z\.mov$');

/// `mm:ss`, or `h:mm:ss` past an hour -- the player's and Summary's video
/// time format.
String formatVideoTime(Duration d) {
  final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return d.inHours > 0 ? '${d.inHours}:$minutes:$seconds' : '$minutes:$seconds';
}
