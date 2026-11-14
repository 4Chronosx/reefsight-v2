import 'dart:io';
import 'dart:ui' show Rect;

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

import 'colony_photos.dart';
import 'cover_calculator.dart';
import 'frame_point.dart';
import 'report_exporter.dart';
import 'station.dart';
import 'station_checks.dart';
import 'station_summary.dart';
import 'tracked_colony_record.dart';
import 'transect_database.dart';
import 'transect_frame.dart';
import 'transect_session.dart';

/// Issue #9: a station, some of its transects, or one unassigned survey,
/// packed into one organized .zip for the iOS share sheet (Save to Files →
/// Google Drive, AirDrop, email). A zip, because the folder layout must
/// survive all three:
///
/// ```
/// ALG-S1_2026-11-15/
///   station_summary_CPCe.csv     (every transect in, and one analyzed)
///   station_info.csv
///   T1/ photos/001_m00.jpg …  transect_cover.csv  points.csv  [video.mp4]
/// ```
///
/// A colony-count or unassigned transect's folder holds its existing colony
/// and session CSVs and `colony_photos/` instead. Layout and naming rules:
/// `docs/organized-share-package-layout.md`; alignment doc §9b (layer 1).
///
/// Paths are parameters, not resolved here (the `laptop_analysis.dart`
/// pattern), so tests use real temp directories. Building a [ShareSource]
/// never changes a label, frame or point; it only rebuilds the derived
/// cover cache, as the station summary does.

/// Room kept free beyond the package itself before writing.
const kShareFreeSpaceMarginBytes = 50 * 1000 * 1000;

/// Above this, the picker warns that Drive and email may not take it.
const kLargeShareBytes = 500 * 1000 * 1000;

/// `[A-Za-z0-9_-]` only, character by character (like `LaptopAnalysis`):
/// the station code and site are free text and become path segments.
String _safe(String? text, String fallback) {
  final trimmed = text?.trim() ?? '';
  if (trimmed.isEmpty) return fallback;
  return trimmed.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
}

String _two(int n) => n.toString().padLeft(2, '0');

String _isoDay(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${_two(d.month)}-${_two(d.day)}';

/// `001_m00.jpg`: the frame's place along the tape (1-based, so names sort
/// in order) and its meter mark -- `m12-5` for a decimal one, `t01-05`
/// (minutes, seconds into the video) for a preliminary frame with no mark.
/// Keeps the photo's own extension, lowercased.
String photoEntryName(int index, TransectFrame frame) {
  final ext = p.extension(frame.imagePath).toLowerCase();
  final meter = frame.meterMark;
  final ms = frame.videoTimeMs;
  final String suffix;
  if (meter != null) {
    suffix = meter == meter.roundToDouble()
        ? '_m${_two(meter.toInt())}'
        : '_m${meter.toString().replaceAll('.', '-')}';
  } else if (ms != null) {
    final seconds = ms ~/ 1000;
    suffix = '_t${_two(seconds ~/ 60)}-${_two(seconds % 60)}';
  } else {
    suffix = '';
  }
  return '${index.toString().padLeft(3, '0')}$suffix${ext.isEmpty ? '.jpg' : ext}';
}

/// `ALG-S1_2026-11-15`, with `_T2` (or `_T1_T3`) when not every transect is
/// in, and `PRELIMINARY_` in front for a preliminary station (alignment doc
/// §7: the stamp is on every export).
String stationRootName(Station station, List<int> transectNumbers, {required bool all}) {
  final prefix = station.surveyType == SurveyType.preliminaryVideo ? 'PRELIMINARY_' : '';
  final base = '$prefix${_safe(station.code, 'station')}_${_isoDay(station.surveyedOn)}';
  if (all) return base;
  final numbers = [...transectNumbers]..sort();
  return '$base${numbers.map((n) => '_T$n').join()}';
}

/// An unassigned survey has no station code: `<site>_<day>_<HHmm>`, local
/// time, so two dives at one site on one day are told apart.
String unassignedRootName(TransectSession session) {
  final t = session.startedAt.toLocal();
  return '${_safe(session.siteName, 'Unknown_Site')}_${_isoDay(t)}_${_two(t.hour)}${_two(t.minute)}';
}

/// `T<n>` for a station transect; `transect` for an unassigned survey.
String transectFolder(TransectSession session) {
  final number = session.transectNumber;
  if (number != null) return 'T$number';
  return session.stationId == null ? 'transect' : 'T_${session.id}';
}

/// Decimal units, as iOS's Files app shows them.
String describeBytes(int bytes) {
  if (bytes < 1000 * 1000) return '${(bytes / 1000).ceil()} KB';
  if (bytes < 1000 * 1000 * 1000) return '${(bytes / 1e6).toStringAsFixed(1)} MB';
  return '${(bytes / 1e9).toStringAsFixed(2)} GB';
}

/// A file on the phone and where it goes inside its transect's folder.
class ShareFile {
  const ShareFile({required this.entry, required this.file, required this.bytes});

  final String entry;
  final File file;
  final int bytes;
}

/// One transect as it would be packed.
class ShareTransect {
  const ShareTransect({
    required this.session,
    required this.folder,
    required this.frames,
    required this.points,
    required this.colonies,
    required this.cover,
    required this.photos,
    required this.photoNames,
    required this.missingPhotos,
    required this.colonyPhotos,
    required this.video,
  });

  final TransectSession session;
  final String folder;
  final List<TransectFrame> frames;
  final List<FramePoint> points;
  final List<TrackedColonyRecord> colonies;

  /// Photo and preliminary transects' cover (bulletin categories); `null`
  /// for colony count and unassigned surveys, which share their colony CSVs.
  final CoverComputation? cover;

  final List<ShareFile> photos;

  /// `photos/<name>` by frame id, for points.csv -- every frame with an
  /// image, including those whose file is gone.
  final Map<int, String> photoNames;

  /// Stored paths of frame images no longer on the phone.
  final List<String> missingPhotos;

  final List<ShareFile> colonyPhotos;
  final ShareFile? video;

  int get id => session.id!;
}

/// What the picker chose.
class ShareOptions {
  const ShareOptions({required this.sessionIds, this.photos = true, this.colonyPhotos = true, this.video = false});

  final Set<int> sessionIds;
  final bool photos;
  final bool colonyPhotos;

  /// Off by default: roughly 0.6-1.2 GB per transect.
  final bool video;

  ShareOptions copyWith({Set<int>? sessionIds, bool? photos, bool? colonyPhotos, bool? video}) => ShareOptions(
        sessionIds: sessionIds ?? this.sessionIds,
        photos: photos ?? this.photos,
        colonyPhotos: colonyPhotos ?? this.colonyPhotos,
        video: video ?? this.video,
      );
}

/// Everything that could go in a package, loaded once for the picker.
class ShareSource {
  ShareSource._({required this.station, required this.transects, required this.summary});

  /// `null` for an unassigned survey.
  final Station? station;
  final List<ShareTransect> transects;

  /// The station's cover summary, when it has one: a photo or preliminary
  /// station with at least one analyzed transect.
  final StationCoverSummary? summary;

  /// Throws [ArgumentError] for an unknown station.
  static Future<ShareSource> forStation(TransectDatabase db, int stationId, {required String documentsPath}) async {
    final station = await db.stationById(stationId);
    if (station == null) throw ArgumentError.value(stationId, 'stationId', 'No such station');
    final bulletin = reportsBulletinCover(station.surveyType);
    final inputs = bulletin ? await db.stationCoverInputs(stationId) : const <StationTransectCover>[];
    final covers = {for (final c in inputs) c.transect.id!: c.cover};
    final summary = bulletin ? StationCoverSummary.compute(station, inputs) : null;
    return ShareSource._(
      station: station,
      transects: [
        for (final t in await db.transectsForStation(stationId))
          await _load(db, t, covers[t.id], documentsPath, bulletin: bulletin),
      ],
      summary: summary != null && summary.analyzed.isNotEmpty ? summary : null,
    );
  }

  /// An unassigned survey (all of them before v11, and quick transects).
  /// Throws [ArgumentError] for an unknown session or a station transect,
  /// which is shared from its station.
  static Future<ShareSource> forSession(TransectDatabase db, int sessionId, {required String documentsPath}) async {
    final session = await db.sessionById(sessionId);
    if (session == null) throw ArgumentError.value(sessionId, 'sessionId', 'No such survey');
    if (session.stationId != null) {
      throw ArgumentError('A station transect is shared from its station');
    }
    return ShareSource._(
      station: null,
      transects: [await _load(db, session, null, documentsPath, bulletin: false)],
      summary: null,
    );
  }

  static Future<ShareTransect> _load(
    TransectDatabase db,
    TransectSession session,
    CoverComputation? cover,
    String documentsPath, {
    required bool bulletin,
  }) async {
    final id = session.id!;
    final frames = await db.framesForSession(id);
    final photos = <ShareFile>[];
    final names = <int, String>{};
    final missing = <String>[];
    var index = 0;
    for (final f in frames) {
      if (f.imagePath.isEmpty) continue;
      final entry = 'photos/${photoEntryName(++index, f)}';
      names[f.id!] = entry;
      final file = File(p.joinAll([documentsPath, ...p.posix.split(f.imagePath)]));
      if (await file.exists()) {
        photos.add(ShareFile(entry: entry, file: file, bytes: await file.length()));
      } else {
        missing.add(f.imagePath);
      }
    }

    final colonies = await db.colonyRowsForSession(id);
    final colonyPhotos = <String, ShareFile>{};
    for (final c in colonies) {
      final file = await resolveColonyPhoto(c.photoPath, documentsDirectory: documentsPath);
      if (file == null) continue;
      final entry = 'colony_photos/${p.basename(file.path)}';
      colonyPhotos[entry] ??= ShareFile(entry: entry, file: file, bytes: await file.length());
    }

    final videoFile = await _resolveVideo(session.videoPath, documentsPath);
    final ext = videoFile == null ? '' : p.extension(videoFile.path).toLowerCase();

    return ShareTransect(
      session: session,
      folder: transectFolder(session),
      frames: frames,
      points: bulletin ? await db.pointsForSession(id) : const [],
      colonies: colonies,
      cover: bulletin ? cover : null,
      photos: photos,
      photoNames: names,
      missingPhotos: missing,
      colonyPhotos: colonyPhotos.values.toList(growable: false),
      video: videoFile == null
          ? null
          : ShareFile(entry: 'video${ext.isEmpty ? '.mp4' : ext}', file: videoFile, bytes: await videoFile.length()),
    );
  }

  /// The stored path, or the same name in the *current* documents directory
  /// (it moves on reinstall) -- `resolveTransectVideo`'s rule, without
  /// `path_provider`.
  static Future<File?> _resolveVideo(String? stored, String documentsPath) async {
    if (stored == null || stored.isEmpty) return null;
    final file = File(stored);
    if (await file.exists()) return file;
    final relocated = File(p.join(documentsPath, p.basename(stored)));
    return await relocated.exists() ? relocated : null;
  }

  bool get hasPhotos => transects.any((t) => t.photos.isNotEmpty || t.missingPhotos.isNotEmpty);
  bool get hasColonyPhotos => transects.any((t) => t.colonyPhotos.isNotEmpty);
  bool get hasVideo => transects.any((t) => t.video != null);

  /// Every transect, or only [onlySessionId]; photos in, video out.
  ShareOptions defaultOptions({int? onlySessionId}) {
    if (onlySessionId != null && !transects.any((t) => t.id == onlySessionId)) {
      throw ArgumentError.value(onlySessionId, 'onlySessionId', 'Not in this package');
    }
    return ShareOptions(sessionIds: onlySessionId == null ? {for (final t in transects) t.id} : {onlySessionId});
  }

  /// The chosen transects, in order. Throws [ArgumentError] for an empty
  /// choice or one naming a transect that isn't here.
  List<ShareTransect> selected(ShareOptions options) {
    if (options.sessionIds.isEmpty) throw ArgumentError('Choose at least one transect');
    final known = {for (final t in transects) t.id};
    if (!known.containsAll(options.sessionIds)) throw ArgumentError('A chosen transect is not in this package');
    return [for (final t in transects) if (options.sessionIds.contains(t.id)) t];
  }

  bool _all(ShareOptions options) => options.sessionIds.length == transects.length;

  /// Only when every transect is in: a summary of a subset would read as the
  /// station's result.
  bool includesStationSummary(ShareOptions options) => summary != null && _all(options);

  String rootName(ShareOptions options) {
    final station = this.station;
    if (station == null) return unassignedRootName(transects.single.session);
    return stationRootName(
      station,
      [for (final t in selected(options)) t.session.transectNumber ?? 0],
      all: _all(options),
    );
  }

  /// The photos, colony photos and video chosen; the CSVs add a few KB.
  int bytesFor(ShareOptions options) {
    var total = 0;
    for (final t in selected(options)) {
      if (options.photos) total += t.photos.fold(0, (s, f) => s + f.bytes);
      if (options.colonyPhotos) total += t.colonyPhotos.fold(0, (s, f) => s + f.bytes);
      if (options.video) total += t.video?.bytes ?? 0;
    }
    return total;
  }

  /// Frame images the package would need but the phone no longer has.
  List<String> missingPhotos(ShareOptions options) =>
      options.photos ? [for (final t in selected(options)) ...t.missingPhotos] : const [];
}

/// Writes `<root>.zip` into [outputDirectory] and returns its path. Photos
/// and video are stored uncompressed and streamed from disk (JPEG and MP4
/// don't shrink). Throws [ArgumentError] for a bad selection, and
/// [StateError] when a chosen photo is missing or, given [freeBytes], there
/// isn't room; no zip is left behind either way.
Future<String> writeShareZip(
  ShareSource source,
  ShareOptions options, {
  required Directory outputDirectory,
  int? freeBytes,
  DateTime? now,
}) async {
  final selected = source.selected(options);
  final missing = source.missingPhotos(options);
  if (missing.isNotEmpty) {
    throw StateError('${missing.length} photo file(s) are missing from the phone, e.g. ${missing.first}. '
        'Leave photos out to share the rest.');
  }
  final bytes = source.bytesFor(options);
  if (freeBytes != null && freeBytes < bytes + kShareFreeSpaceMarginBytes) {
    throw StateError('Not enough free space: the package needs about ${describeBytes(bytes)}, '
        'and ${describeBytes(freeBytes)} is free.');
  }

  final root = source.rootName(options);
  final zipPath = p.join(outputDirectory.path, '$root.zip');
  final staging = await outputDirectory.createTemp('.share_');
  final encoder = ZipFileEncoder();
  var open = false;
  try {
    encoder.create(zipPath, level: DeflateLevel.none);
    open = true;
    Future<void> add(String path, String entry) => encoder.addFile(File(path), '$root/$entry');

    final station = source.station;
    if (station != null) {
      await add(
        await ReportExporter.exportStationInfoCsv(
          outputDirectory: staging.path,
          station: station,
          transects: [
            for (final t in selected) (transect: t.session, folder: t.folder, frames: t.photoNames.length),
          ],
          exportedAt: now ?? DateTime.now(),
        ),
        'station_info.csv',
      );
    }
    if (source.includesStationSummary(options)) {
      await add(
        await ReportExporter.exportStationCpceCsv(outputDirectory: staging.path, summary: source.summary!),
        'station_summary_CPCe.csv',
      );
    }

    for (final t in selected) {
      final dir = (await Directory(p.join(staging.path, t.folder)).create()).path;
      final cover = t.cover;
      if (station != null && reportsBulletinCover(station.surveyType)) {
        await add(
          await ReportExporter.exportTransectCoverCsv(
            outputDirectory: dir,
            rows: cover != null && cover.isComplete ? cover.rows : const [],
          ),
          '${t.folder}/transect_cover.csv',
        );
        await add(
          await ReportExporter.exportPointsCsv(
            outputDirectory: dir,
            frames: t.frames,
            points: t.points,
            photoNames: t.photoNames,
          ),
          '${t.folder}/points.csv',
        );
      } else {
        for (final path in [
          await ReportExporter.exportCsv(
            outputDirectory: dir,
            session: t.session,
            colonies: t.colonies,
            station: station,
          ),
          await ReportExporter.exportSessionCsv(
            outputDirectory: dir,
            session: t.session,
            colonies: t.colonies,
            station: station,
          ),
        ]) {
          await add(path, '${t.folder}/${p.basename(path)}');
        }
      }
      if (options.photos) {
        for (final f in t.photos) {
          await add(f.file.path, '${t.folder}/${f.entry}');
        }
      }
      if (options.colonyPhotos) {
        for (final f in t.colonyPhotos) {
          await add(f.file.path, '${t.folder}/${f.entry}');
        }
      }
      if (options.video && t.video != null) await add(t.video!.file.path, '${t.folder}/${t.video!.entry}');
    }
    open = false;
    await encoder.close();
  } catch (_) {
    if (open) {
      try {
        await encoder.close();
      } catch (_) {}
    }
    final partial = File(zipPath);
    if (partial.existsSync()) await partial.delete();
    rethrow;
  } finally {
    await staging.delete(recursive: true);
  }
  return zipPath;
}

/// Opens the share sheet for a package, then deletes the zip: it is a copy
/// of files the app keeps, and a station with video runs to gigabytes.
/// [origin] anchors the sheet's popover on iPad.
Future<void> shareZip(String zipPath, {required String subject, Rect? origin}) async {
  try {
    await Share.shareXFiles(
      [XFile(zipPath, mimeType: 'application/zip')],
      subject: subject,
      sharePositionOrigin: origin,
    );
  } finally {
    final zip = File(zipPath);
    if (zip.existsSync()) await zip.delete();
  }
}
