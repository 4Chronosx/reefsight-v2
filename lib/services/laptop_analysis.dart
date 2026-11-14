import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

import 'analysis_manifest.dart';
import 'coralscapes_mapping.dart';
import 'station.dart';
import 'transect_database.dart';
import 'transect_session.dart';

/// Issue #7: the phone's side of the laptop route. [LaptopAnalysis.exportStation]
/// packs a photo-transect station into one zip for the notebook
/// (`machine-learning-pipeline/notebooks/28_coralscapes_laptop_cover.ipynb`);
/// [LaptopAnalysis.importResults] writes the notebook's results file back.
/// The formats are in `analysis_manifest.dart` and
/// `docs/laptop-analysis-exchange-format.md`.
///
/// Paths are parameters, not resolved here (the `report_exporter.dart`
/// pattern), so tests use real temp directories.

/// What [LaptopAnalysis.exportStation] wrote.
class AnalysisExport {
  const AnalysisExport({required this.zipPath, required this.transects, required this.frames, required this.points});

  final String zipPath;
  final int transects;
  final int frames;
  final int points;
}

class LaptopAnalysis {
  const LaptopAnalysis._();

  /// Samples any frames not sampled yet (`ensureFramePoints`), then writes
  /// `<code>_<date>_analysis.zip` into [outputDirectory]:
  ///
  /// ```
  /// <code>_<date>_analysis/
  ///   manifest.json  README.txt  photos/T1/m00.jpg ...
  /// ```
  ///
  /// Photos are read from [documentsPath] (frames store paths relative to
  /// it) and stored uncompressed -- JPEGs don't shrink, and storing streams
  /// them straight from disk. Transects with no status yet become
  /// `pending`. Throws [ArgumentError] for a station that isn't a photo
  /// transect, and [StateError] when there is nothing to score or a photo
  /// file is missing; no zip is left behind either way.
  static Future<AnalysisExport> exportStation(
    TransectDatabase db,
    int stationId, {
    required String documentsPath,
    required Directory outputDirectory,
    DateTime? now,
  }) async {
    final station = await db.stationById(stationId);
    if (station == null) throw ArgumentError.value(stationId, 'stationId', 'No such station');
    if (station.surveyType != SurveyType.photoTransect) {
      throw ArgumentError('Only photo-transect stations are analyzed on the laptop');
    }

    final transects = <ManifestTransect>[];
    for (final t in await db.transectsForStation(stationId)) {
      await db.ensureFramePoints(t.id!);
      transects.add((
        session: (await db.sessionById(t.id!))!,
        frames: await db.framesForSession(t.id!),
        points: await db.pointsForSession(t.id!),
      ));
    }
    final manifest = buildAnalysisManifest(
      station: station,
      transects: transects,
      modelId: kCoralscapesModelId,
      exportedAt: now ?? DateTime.now(),
    );
    if (manifest.pointCount == 0) {
      throw StateError('Nothing to analyze yet: no photos with their frame corners set');
    }
    final missing = [
      for (final image in manifest.images)
        if (!File(p.join(documentsPath, image.imagePath)).existsSync()) image.imagePath,
    ];
    if (missing.isNotEmpty) {
      throw StateError('${missing.length} photo file(s) are missing from the phone, e.g. ${missing.first}');
    }

    final root = '${_safe(station.code)}_${(manifest.json['station'] as Map)['surveyed_on']}_analysis';
    final zipPath = p.join(outputDirectory.path, '$root.zip');
    final encoder = ZipFileEncoder();
    try {
      encoder.create(zipPath, level: DeflateLevel.none);
      encoder.addArchiveFile(
        ArchiveFile.string('$root/manifest.json', const JsonEncoder.withIndent('  ').convert(manifest.json)),
      );
      encoder.addArchiveFile(ArchiveFile.string('$root/README.txt', _readme(station)));
      for (final image in manifest.images) {
        await encoder.addFile(File(p.join(documentsPath, image.imagePath)), '$root/${image.entry}', DeflateLevel.none);
      }
      await encoder.close();
    } catch (_) {
      final partial = File(zipPath);
      if (partial.existsSync()) await partial.delete();
      rethrow;
    }

    final sent = (manifest.json['transects'] as List).cast<Map>();
    for (final t in sent) {
      final id = t['session_id'] as int;
      final session = transects.firstWhere((x) => x.session.id == id).session;
      if (session.analysisStatus == null) await db.setAnalysisStatus(id, AnalysisStatus.pending);
    }
    return AnalysisExport(
      zipPath: zipPath,
      transects: sent.length,
      frames: manifest.images.length,
      points: manifest.pointCount,
    );
  }

  /// Opens the share sheet (AirDrop, Save to Files, ...) for an export, then
  /// deletes the zip: it is a copy of photos the app already keeps, and a
  /// station's can run to a gigabyte.
  static Future<void> share(String zipPath) async {
    try {
      await Share.shareXFiles(
        [XFile(zipPath, mimeType: 'application/zip')],
        subject: 'ReefSight photo transects for laptop analysis',
      );
    } finally {
      final zip = File(zipPath);
      if (zip.existsSync()) await zip.delete();
    }
  }

  /// A results file is about 100 bytes per point; 10 MB is far above any
  /// station's (5 transects × 51 frames × 10 points).
  static const maxResultsBytes = 10 * 1024 * 1024;

  /// Parses a results file and writes it into the database
  /// (`TransectDatabase.applyAnalysisResults`, all or nothing). Throws
  /// [FormatException] for a file of the wrong shape and [ArgumentError] for
  /// one that doesn't match this phone's transects.
  /// With [stationId], a file for another station's transects is refused.
  static Future<List<AnalysisImport>> importResults(
    TransectDatabase db,
    String text, {
    int? stationId,
    DateTime? now,
  }) async =>
      db.applyAnalysisResults(parseAnalysisResults(text), at: now ?? DateTime.now(), stationId: stationId);
}

/// One line for the import dialog.
String describeImport(List<AnalysisImport> imports) {
  final points = imports.fold(0, (sum, i) => sum + i.pointsLabeled);
  final stale = imports.fold(0, (sum, i) => sum + i.staleFrameIds.length);
  final n = imports.length;
  final summary = '$points points labeled in $n transect${n == 1 ? '' : 's'}.';
  if (stale == 0) return summary;
  return '$summary $stale frame${stale == 1 ? '' : 's'} had moved corners and '
      '${stale == 1 ? 'was' : 'were'} skipped: export and analyze again to label '
      '${stale == 1 ? 'it' : 'them'}.';
}

/// `[A-Za-z0-9_-]` only, like `ReportExporter`'s file names: the station
/// code is free text and becomes a path segment.
String _safe(String text) {
  final safe = text.trim().replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
  return safe.isEmpty ? 'station' : safe;
}

String _readme(Station station) => '''
ReefSight photo transects for laptop analysis (issue #7)
Station: ${station.code}${station.name == null ? '' : ' (${station.name})'}

1. Unzip this folder on the laptop.
2. Open machine-learning-pipeline/notebooks/28_coralscapes_laptop_cover.ipynb,
   set PACKAGE_DIR to this folder, and run it top to bottom.
3. Send the run's results.json back to the phone (AirDrop or Files) and, on
   the station screen, tap "Import analysis results".

manifest.json lists every photo, its four frame corners, and its 10 random
points. Don't rename the photos or edit the manifest; the phone checks the
results against it.

The photos are the originals, EXIF included (camera, time, and GPS if the
camera recorded it). Share this package only with the survey team.
''';
