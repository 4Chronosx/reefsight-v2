import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:csv/csv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:reefsight_mobile/services/health_history_recorder.dart';
import 'package:reefsight_mobile/services/share_package.dart';
import 'package:reefsight_mobile/services/station.dart';
import 'package:reefsight_mobile/services/tracked_colony_record.dart';
import 'package:reefsight_mobile/services/transect_database.dart';
import 'package:reefsight_mobile/services/transect_frame.dart';
import 'package:reefsight_mobile/services/transect_session.dart';

// Issue #9: a station or transect packed into one organized .zip for the
// share sheet -- real SQLite (test/flutter_test_config.dart), real files in
// temp directories, and the zip read back entry by entry.

const _corners = <NormPoint>[(x: 0.1, y: 0.1), (x: 0.9, y: 0.1), (x: 0.9, y: 0.9), (x: 0.1, y: 0.9)];

Station _station({SurveyType type = SurveyType.photoTransect, String code = 'ALG-S1'}) => Station(
      code: code,
      surveyType: type,
      frameMode: type == SurveyType.photoTransect ? FrameMode.physical : null,
      surveyedOn: DateTime(2026, 11, 15),
      siteName: 'Alegria MPA',
      observerName: '=cmd',
      createdAt: DateTime.utc(2026, 11, 15, 1),
    );

TransectSession _transect(int stationId, int number, {CaptureSource source = CaptureSource.inAppPhotos}) =>
    TransectSession(
      startedAt: DateTime.utc(2026, 11, 15, 2, number),
      tapeLengthMeters: 50,
      stationId: stationId,
      transectNumber: number,
      captureSource: source,
      pointsPerFrame: 10,
      depthStartM: 4,
      depthEndM: 5,
    );

TrackedColonyRecord _colony(int sessionId, int trackId, {String? photoPath}) => TrackedColonyRecord(
      sessionId: sessionId,
      trackId: trackId,
      healthLabel: 'healthy',
      healthHistory: const <HealthHistorySample>[],
      firstSeenAt: DateTime.utc(2026, 10, 4, 1),
      lastSeenAt: DateTime.utc(2026, 10, 4, 1, 1),
      photoPath: photoPath,
    );

Map<String, ArchiveFile> _read(String zipPath) {
  final archive = ZipDecoder().decodeBytes(File(zipPath).readAsBytesSync());
  return {for (final f in archive.files) if (f.isFile) f.name: f};
}

List<List<dynamic>> _csv(ArchiveFile f) =>
    const CsvToListConverter(eol: '\n', shouldParseNumbers: false).convert(String.fromCharCodes(f.content).replaceAll('\r\n', '\n'));

void main() {
  late TransectDatabase db;
  late Directory documents;
  late Directory output;

  setUp(() async {
    db = await TransectDatabase.openInMemoryForTest();
    documents = await Directory.systemTemp.createTemp('share_docs_');
    output = await Directory.systemTemp.createTemp('share_out_');
  });
  tearDown(() async {
    await db.closeForTest();
    await documents.delete(recursive: true);
    await output.delete(recursive: true);
  });

  /// A photo transect with two frames (meters 0 and 1) on disk, every point
  /// labeled: meter 0 branching coral, meter 1 sand.
  Future<int> addPhotoTransect(int stationId, int number) async {
    final id = await db.insertSession(_transect(stationId, number));
    for (final meter in [0.0, 1.0]) {
      final rel = 'frames/$id/m${meter.toInt()}.jpg';
      final file = File(p.join(documents.path, 'frames', '$id', 'm${meter.toInt()}.jpg'));
      await file.create(recursive: true);
      await file.writeAsBytes(List.filled(1000, number));
      await db.insertFrame(TransectFrame(
        sessionId: id,
        meterMark: meter,
        imagePath: rel,
        source: FrameSource.inApp,
        corners: _corners,
        cornerSource: CornerSource.manual,
      ));
    }
    await db.ensureFramePoints(id, newSeed: () => 42 + number);
    final frames = await db.framesForSession(id);
    for (final f in frames) {
      for (final pt in await db.pointsForFrame(f.id!)) {
        await db.setPointModelLabel(pt.id!,
            modelClass: f.meterMark == 0 ? 'branching alive' : 'sand', categoryCode: f.meterMark == 0 ? 'CB' : 'S');
      }
    }
    return id;
  }

  group('a photo-transect station', () {
    late int stationId;
    late int t1, t2, t3;

    setUp(() async {
      stationId = await db.insertStation(_station());
      t1 = await addPhotoTransect(stationId, 1);
      t2 = await addPhotoTransect(stationId, 2);
      t3 = await addPhotoTransect(stationId, 3);
    });

    test('the whole station: summary, info and one folder per transect', () async {
      final source = await ShareSource.forStation(db, stationId, documentsPath: documents.path);
      final options = source.defaultOptions();
      expect(options.sessionIds, {t1, t2, t3});
      expect(options.video, isFalse);
      expect(source.includesStationSummary(options), isTrue);
      expect(source.rootName(options), 'ALG-S1_2026-11-15');

      final zip = await writeShareZip(source, options, outputDirectory: output);
      expect(p.basename(zip), 'ALG-S1_2026-11-15.zip');
      final entries = _read(zip);
      expect(entries.keys.toSet(), {
        'ALG-S1_2026-11-15/station_summary_CPCe.csv',
        'ALG-S1_2026-11-15/station_info.csv',
        for (final t in ['T1', 'T2', 'T3']) ...[
          'ALG-S1_2026-11-15/$t/transect_cover.csv',
          'ALG-S1_2026-11-15/$t/points.csv',
          'ALG-S1_2026-11-15/$t/genus_tags.csv',
          'ALG-S1_2026-11-15/$t/photos/001_m00.jpg',
          'ALG-S1_2026-11-15/$t/photos/002_m01.jpg',
        ],
      });
      // The photo is the original, byte for byte.
      expect(entries['ALG-S1_2026-11-15/T2/photos/001_m00.jpg']!.content, List.filled(1000, 2));
    });

    test('transect_cover.csv has one row per category, majors included', () async {
      final source = await ShareSource.forStation(db, stationId, documentsPath: documents.path);
      final zip = await writeShareZip(source, source.defaultOptions(onlySessionId: t1), outputDirectory: output);
      final rows = _csv(_read(zip)['ALG-S1_2026-11-15_T1/T1/transect_cover.csv']!);
      expect(rows.first, ['Level', 'Code', 'Name', 'Points', 'Total Points', 'Percent', 'Uses Expert']);
      final cb = rows.singleWhere((r) => r[0] == 'code' && r[1] == 'CB');
      expect(cb.sublist(3), ['10', '20', '50.00', 'no']);
      final hc = rows.singleWhere((r) => r[0] == 'major' && r[1] == 'HC');
      expect(hc[2], 'Hard coral');
      expect(hc[5], '50.00');
    });

    // Issue #10: the expert's tags per transect, and diversity in the sheet.
    test('genus_tags.csv per transect, and the station sheet carries diversity', () async {
      final at = DateTime.utc(2026, 11, 16, 3);
      final frame = (await db.framesForSession(t1)).first;
      await db.setFrameTaus(frame.id!, {'PORM', 'ACB'}, by: 'Expert', at: at);
      await db.setTransectTaus(t3, {'HEL'}, by: 'Expert', at: at);
      final source = await ShareSource.forStation(db, stationId, documentsPath: documents.path);
      expect(source.diversity!.stationCount, 3);
      final entries = _read(await writeShareZip(source, source.defaultOptions(), outputDirectory: output));

      final t1Tags = _csv(entries['ALG-S1_2026-11-15/T1/genus_tags.csv']!);
      expect(t1Tags.skip(1).map((r) => (r[0], r[2])), [('photos/001_m00.jpg', 'ACB'), ('photos/001_m00.jpg', 'PORM')]);
      expect(_csv(entries['ALG-S1_2026-11-15/T2/genus_tags.csv']!), hasLength(1));
      expect(_csv(entries['ALG-S1_2026-11-15/T3/genus_tags.csv']!)[1][0], '(on tape, no photo)');

      final sheet = _csv(entries['ALG-S1_2026-11-15/station_summary_CPCe.csv']!);
      expect(sheet.firstWhere((r) => r.first == 'Diversity (station, TAUs)')[1], '3');
    });

    test('genus tags alone (nothing analyzed) still put the sheet in, with diversity', () async {
      final bare = await db.insertStation(_station(code: 'ALG-S9'));
      final t = await db.insertSession(_transect(bare, 1));
      await db.setTransectTaus(t, {'PORM'}, by: 'Expert', at: DateTime.utc(2026, 11, 16));
      final source = await ShareSource.forStation(db, bare, documentsPath: documents.path);
      expect(source.summary?.n, 0);
      final entries = _read(await writeShareZip(source, source.defaultOptions(), outputDirectory: output));
      final sheet = _csv(entries.entries.firstWhere((e) => e.key.endsWith('station_summary_CPCe.csv')).value);
      expect(sheet.firstWhere((r) => r.first == 'Diversity (station, TAUs)')[1], '1');
    });

    test('points.csv names each point\'s photo as it is in the zip', () async {
      final source = await ShareSource.forStation(db, stationId, documentsPath: documents.path);
      final zip = await writeShareZip(source, source.defaultOptions(onlySessionId: t1), outputDirectory: output);
      final rows = _csv(_read(zip)['ALG-S1_2026-11-15_T1/T1/points.csv']!);
      expect(rows.first.take(4), ['Photo', 'Meter Mark', 'Video Time (ms)', 'Point']);
      expect(rows.length, 1 + 20);
      expect(rows[1].take(4), ['photos/001_m00.jpg', '0', '', '0']);
      expect(rows.last.take(4), ['photos/002_m01.jpg', '1', '', '9']);
      final category = rows.first.indexOf('Category');
      expect(rows[1][category], 'CB');
      expect(rows.last[category], 'S');
    });

    test('one transect: no station summary, its own name', () async {
      final source = await ShareSource.forStation(db, stationId, documentsPath: documents.path);
      final options = source.defaultOptions(onlySessionId: t2);
      expect(options.sessionIds, {t2});
      expect(source.includesStationSummary(options), isFalse);
      final zip = await writeShareZip(source, options, outputDirectory: output);
      expect(p.basename(zip), 'ALG-S1_2026-11-15_T2.zip');
      final names = _read(zip).keys.toSet();
      expect(names, contains('ALG-S1_2026-11-15_T2/station_info.csv'));
      expect(names, contains('ALG-S1_2026-11-15_T2/T2/points.csv'));
      expect(names.where((n) => n.contains('station_summary')), isEmpty);
      expect(names.where((n) => n.contains('/T1/') || n.contains('/T3/')), isEmpty);
    });

    test('several transects: only those, named by number', () async {
      final source = await ShareSource.forStation(db, stationId, documentsPath: documents.path);
      final options = source.defaultOptions().copyWith(sessionIds: {t1, t3});
      final zip = await writeShareZip(source, options, outputDirectory: output);
      expect(p.basename(zip), 'ALG-S1_2026-11-15_T1_T3.zip');
      final names = _read(zip).keys;
      expect(names.where((n) => n.contains('/T2/')), isEmpty);
      expect(names.where((n) => n.contains('station_summary')), isEmpty);
    });

    test('station_info.csv: the station, then a row per transect in the package, cells made safe', () async {
      final source = await ShareSource.forStation(db, stationId, documentsPath: documents.path);
      final options = source.defaultOptions().copyWith(sessionIds: {t1, t3});
      final rows = _csv(_read(await writeShareZip(source, options, outputDirectory: output))
          ['ALG-S1_2026-11-15_T1_T3/station_info.csv']!);
      String value(String key) => rows.firstWhere((r) => r.isNotEmpty && r[0] == key)[1] as String;
      expect(value('Station code'), 'ALG-S1');
      expect(value('Survey type'), 'photo_transect');
      expect(value('Surveyed on'), '2026-11-15');
      expect(value('Observer'), "'=cmd");
      final header = rows.indexWhere((r) => r.isNotEmpty && r[0] == 'Transect');
      expect(rows[header].take(2), ['Transect', 'Folder']);
      expect([rows[header + 1][0], rows[header + 2][0]], ['T1', 'T3']);
      expect(rows[header + 1][rows[header].indexOf('Frames')], '2');
    });

    test('photos off: no photos folder, and the size drops by their bytes', () async {
      final source = await ShareSource.forStation(db, stationId, documentsPath: documents.path);
      final on = source.defaultOptions();
      final off = on.copyWith(photos: false);
      expect(source.bytesFor(on), 6 * 1000);
      expect(source.bytesFor(off), 0);
      final names = _read(await writeShareZip(source, off, outputDirectory: output)).keys;
      expect(names.where((n) => n.contains('/photos/')), isEmpty);
      expect(names, contains('ALG-S1_2026-11-15/T1/points.csv'));
    });

    test('a missing photo stops the export and leaves no zip', () async {
      final frame = (await db.framesForSession(t2)).first;
      await File(p.join(documents.path, frame.imagePath)).delete();
      final source = await ShareSource.forStation(db, stationId, documentsPath: documents.path);
      expect(source.missingPhotos(source.defaultOptions()), [frame.imagePath]);
      await expectLater(
        writeShareZip(source, source.defaultOptions(), outputDirectory: output),
        throwsA(isA<StateError>().having((e) => e.message, 'message', contains('1 photo'))),
      );
      expect(output.listSync(), isEmpty);
      // Without photos it still goes.
      await writeShareZip(source, source.defaultOptions().copyWith(photos: false), outputDirectory: output);
    });

    test('not enough free space is refused before writing', () async {
      final source = await ShareSource.forStation(db, stationId, documentsPath: documents.path);
      await expectLater(
        writeShareZip(source, source.defaultOptions(), outputDirectory: output, freeBytes: 1000),
        throwsA(isA<StateError>()),
      );
      expect(output.listSync(), isEmpty);
    });

    test('an empty or foreign selection is refused', () async {
      final source = await ShareSource.forStation(db, stationId, documentsPath: documents.path);
      expect(
        () => writeShareZip(source, source.defaultOptions().copyWith(sessionIds: {}), outputDirectory: output),
        throwsArgumentError,
      );
      expect(
        () => writeShareZip(source, source.defaultOptions().copyWith(sessionIds: {9999}), outputDirectory: output),
        throwsArgumentError,
      );
    });

    test('sharing is read-only: points and frames are unchanged', () async {
      final before = await db.pointsForSession(t1);
      final source = await ShareSource.forStation(db, stationId, documentsPath: documents.path);
      await writeShareZip(source, source.defaultOptions(), outputDirectory: output);
      expect([for (final x in await db.pointsForSession(t1)) x.toMap()], [for (final x in before) x.toMap()]);
    });
  });

  test('a station with no analyzed transect has no summary even when all are in', () async {
    final stationId = await db.insertStation(_station());
    final id = await db.insertSession(_transect(stationId, 1));
    final source = await ShareSource.forStation(db, stationId, documentsPath: documents.path);
    expect(source.includesStationSummary(source.defaultOptions()), isFalse);
    final names = _read(await writeShareZip(source, source.defaultOptions(), outputDirectory: output)).keys;
    expect(names, contains('ALG-S1_2026-11-15/T1/transect_cover.csv'));
    expect(names.where((n) => n.contains('station_summary')), isEmpty);
    expect(id, isPositive);
  });

  test('a preliminary station: stamped names and its video when asked for', () async {
    final stationId = await db.insertStation(_station(type: SurveyType.preliminaryVideo));
    final video = File(p.join(documents.path, 'transect_1.mp4'))..writeAsBytesSync(List.filled(5000, 7));
    final id = await db.insertSession(TransectSession(
      startedAt: DateTime.utc(2026, 11, 15, 2),
      tapeLengthMeters: 50,
      stationId: stationId,
      transectNumber: 1,
      captureSource: CaptureSource.inAppVideo,
      videoPath: video.path,
    ));
    final source = await ShareSource.forStation(db, stationId, documentsPath: documents.path);
    expect(source.hasVideo, isTrue);
    final off = source.defaultOptions();
    expect(off.video, isFalse);
    expect(source.bytesFor(off.copyWith(video: true)), 5000);

    final zip = await writeShareZip(source, off.copyWith(video: true), outputDirectory: output);
    expect(p.basename(zip), 'PRELIMINARY_ALG-S1_2026-11-15.zip');
    final entries = _read(zip);
    expect(entries['PRELIMINARY_ALG-S1_2026-11-15/T1/video.mp4']!.size, 5000);
    final info = _csv(entries['PRELIMINARY_ALG-S1_2026-11-15/station_info.csv']!);
    expect(info.first.first, contains('Preliminary'));
    expect(id, isPositive);
  });

  test('a colony-count station transect: its colony and session CSVs and colony photos', () async {
    final stationId = await db.insertStation(_station(type: SurveyType.colonyCount));
    final id = await db.insertSession(_transect(stationId, 1, source: CaptureSource.legacyColony));
    final photo = File(p.join(documents.path, 'colony_photos', 's${id}_t7.jpg'))
      ..createSync(recursive: true)
      ..writeAsBytesSync(List.filled(300, 1));
    await db.upsertColonies([_colony(id, 7, photoPath: 'colony_photos/s${id}_t7.jpg'), _colony(id, 8)]);

    final source = await ShareSource.forStation(db, stationId, documentsPath: documents.path);
    expect(source.hasColonyPhotos, isTrue);
    final options = source.defaultOptions();
    expect(source.includesStationSummary(options), isFalse);
    final entries = _read(await writeShareZip(source, options, outputDirectory: output));
    final names = entries.keys.toSet();
    expect(names, contains('ALG-S1_2026-11-15/station_info.csv'));
    expect(names, contains('ALG-S1_2026-11-15/T1/colony_photos/${p.basename(photo.path)}'));
    final csvs = names.where((n) => n.startsWith('ALG-S1_2026-11-15/T1/') && n.endsWith('.csv')).toList();
    expect(csvs.where((n) => n.endsWith('_session.csv')), hasLength(1));
    expect(csvs.where((n) => !n.endsWith('_session.csv')), hasLength(1));
    expect(names.where((n) => n.endsWith('points.csv') || n.endsWith('transect_cover.csv')), isEmpty);
    // The colony CSV has both colonies.
    final colonyCsv = _csv(entries[csvs.firstWhere((n) => !n.endsWith('_session.csv'))]!);
    expect(colonyCsv.length, 3);
    expect(source.bytesFor(options.copyWith(colonyPhotos: false)), 0);
  });

  test('an unassigned survey shares like a single transect', () async {
    final startedAt = DateTime(2026, 10, 4, 9, 7);
    final id = await db.insertSession(TransectSession(startedAt: startedAt, tapeLengthMeters: 50, siteName: 'Alegria'));
    await db.upsertColonies([_colony(id, 1)]);
    final source = await ShareSource.forSession(db, id, documentsPath: documents.path);
    expect(source.station, isNull);
    final options = source.defaultOptions();
    expect(source.includesStationSummary(options), isFalse);
    final zip = await writeShareZip(source, options, outputDirectory: output);
    expect(p.basename(zip), 'Alegria_2026-10-04_0907.zip');
    final names = _read(zip).keys.toSet();
    expect(names.every((n) => n.startsWith('Alegria_2026-10-04_0907/transect/')), isTrue);
    expect(names.where((n) => n.endsWith('_session.csv')), hasLength(1));
  });

  test('forSession refuses a station transect: those go through their station', () async {
    final stationId = await db.insertStation(_station());
    final id = await db.insertSession(_transect(stationId, 1));
    expect(() => ShareSource.forSession(db, id, documentsPath: documents.path), throwsArgumentError);
  });
}
