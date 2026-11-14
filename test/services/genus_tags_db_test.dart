import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:reefsight_mobile/services/coralscapes_mapping.dart';
import 'package:reefsight_mobile/services/frame_point.dart';
import 'package:reefsight_mobile/services/genus_tag.dart';
import 'package:reefsight_mobile/services/station.dart';
import 'package:reefsight_mobile/services/transect_database.dart';
import 'package:reefsight_mobile/services/transect_frame.dart';
import 'package:reefsight_mobile/services/transect_session.dart';
import 'package:sqflite/sqflite.dart' show DatabaseException, openDatabase;

// Issue #10 in the database: schema v13's `genus_tags` (TAU tags per frame,
// or on the tape with no frame), what happens to them when frames and
// transects go, and undoing a point correction. Real SQLite
// (test/flutter_test_config.dart).

const _corners = <NormPoint>[(x: 0.1, y: 0.1), (x: 0.9, y: 0.1), (x: 0.9, y: 0.9), (x: 0.1, y: 0.9)];
final _at = DateTime.utc(2026, 11, 16, 3);

Station _station({SurveyType type = SurveyType.photoTransect, String code = 'ALG-S1'}) => Station(
      code: code,
      surveyType: type,
      frameMode: type == SurveyType.photoTransect ? FrameMode.physical : null,
      surveyedOn: DateTime(2026, 11, 15),
      siteName: 'Alegria MPA',
      createdAt: DateTime.utc(2026, 11, 15, 1),
    );

TransectSession _transect(int? stationId, {int number = 1}) => TransectSession(
      startedAt: DateTime.utc(2026, 11, 15, 2),
      tapeLengthMeters: 50,
      stationId: stationId,
      transectNumber: stationId == null ? null : number,
      captureSource: CaptureSource.inAppPhotos,
      pointsPerFrame: 10,
      modelId: kCoralscapesModelId,
    );

TransectFrame _frame(int sessionId, double meter) => TransectFrame(
      sessionId: sessionId,
      meterMark: meter,
      imagePath: 'frames/$sessionId/m$meter.jpg',
      source: FrameSource.inApp,
      corners: _corners,
      cornerSource: CornerSource.manual,
    );

Set<String> _codes(List<GenusTag> tags) => {for (final t in tags) t.tauCode};

void main() {
  group('schema v13', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('reefsight_v13_'));
    tearDown(() => dir.delete(recursive: true));

    test('a fresh install is v13 with genus_tags and its tape-tag index', () async {
      await (await TransectDatabase.open(dir.path)).close();
      final raw = await openDatabase(p.join(dir.path, 'reefsight.db'), singleInstance: false);
      addTearDown(raw.close);
      expect((await raw.rawQuery('PRAGMA user_version')).single.values.single, 13);
      final columns = [for (final r in await raw.rawQuery('PRAGMA table_info(genus_tags)')) r['name']];
      expect(columns, ['id', 'station_id', 'session_id', 'frame_id', 'tau_code', 'tagged_by', 'tagged_at']);
      final index = await raw.rawQuery("SELECT sql FROM sqlite_master WHERE name = 'idx_genus_tags_tape'");
      expect(index.single['sql'], contains('WHERE frame_id IS NULL'));
    });

    test('a v12 file upgrades and keeps its data', () async {
      final path = p.join(dir.path, 'reefsight.db');
      final db = await TransectDatabase.open(dir.path);
      final stationId = await db.insertStation(_station());
      await db.insertSession(_transect(stationId));
      await db.close();
      // Turn the file back into a v12 one.
      final raw = await openDatabase(path, singleInstance: false);
      await raw.execute('DROP INDEX idx_genus_tags_tape');
      await raw.execute('DROP TABLE genus_tags');
      await raw.execute('PRAGMA user_version = 12');
      await raw.close();

      final upgraded = await TransectDatabase.open(dir.path);
      addTearDown(upgraded.close);
      expect(await upgraded.transectsForStation(stationId), hasLength(1));
      expect(await upgraded.genusTagsForStation(stationId), isEmpty);
    });
  });

  group('genus tags', () {
    late TransectDatabase db;
    late int stationId;
    late int sessionId;
    late int frameId;

    setUp(() async {
      db = await TransectDatabase.openInMemoryForTest();
      stationId = await db.insertStation(_station());
      sessionId = await db.insertSession(_transect(stationId));
      frameId = await db.insertFrame(_frame(sessionId, 0));
    });
    tearDown(() => db.close());

    test('setFrameTaus stores the frame\'s set with station, transect, who and when', () async {
      await db.setFrameTaus(frameId, {'PORM', 'ACB'}, by: ' M. Reyes ', at: _at);
      final tags = await db.genusTagsForSession(sessionId);
      expect(_codes(tags), {'PORM', 'ACB'});
      for (final t in tags) {
        expect(t.stationId, stationId);
        expect(t.sessionId, sessionId);
        expect(t.frameId, frameId);
        expect(t.taggedBy, 'M. Reyes');
        expect(t.taggedAt, _at);
      }
    });

    test('setFrameTaus replaces the set, keeping who first tagged an unchanged code', () async {
      await db.setFrameTaus(frameId, {'PORM', 'ACB'}, by: 'A', at: _at);
      await db.setFrameTaus(frameId, {'PORM', 'HEL'}, by: 'B', at: _at.add(const Duration(hours: 1)));
      final tags = {for (final t in await db.genusTagsForSession(sessionId)) t.tauCode: t};
      expect(tags.keys.toSet(), {'PORM', 'HEL'});
      expect(tags['PORM']!.taggedBy, 'A');
      expect(tags['HEL']!.taggedBy, 'B');
      await db.setFrameTaus(frameId, {}, by: 'B', at: _at);
      expect(await db.genusTagsForSession(sessionId), isEmpty);
    });

    test('tape tags (no frame) are their own set, beside the frames\' tags', () async {
      await db.setFrameTaus(frameId, {'PORM'}, by: 'A', at: _at);
      await db.setTransectTaus(sessionId, {'PORM', 'TUBI'}, by: 'A', at: _at);
      final tags = await db.genusTagsForSession(sessionId);
      expect(tags.where((t) => t.frameId == null).map((t) => t.tauCode).toSet(), {'PORM', 'TUBI'});
      expect(tags.where((t) => t.frameId == frameId).map((t) => t.tauCode).toSet(), {'PORM'});
      await db.setTransectTaus(sessionId, {'TUBI'}, by: 'A', at: _at);
      expect(_codes(await db.genusTagsForSession(sessionId)), {'PORM', 'TUBI'});
    });

    test('one tag per TAU per frame, and per transect on the tape, even in raw SQL', () async {
      Future<void> insert(int? frame) => db.rawDatabaseForTest.insert('genus_tags', {
            'station_id': stationId,
            'session_id': sessionId,
            'frame_id': frame,
            'tau_code': 'PORM',
          });
      await insert(frameId);
      await expectLater(insert(frameId), throwsA(isA<DatabaseException>()));
      await insert(null);
      await expectLater(insert(null), throwsA(isA<DatabaseException>()));
    });

    test('rejects unknown codes, a blank tagger, unknown frames and transects, before writing', () async {
      await expectLater(db.setFrameTaus(frameId, {'PORM', 'XYZ'}, by: 'A', at: _at), throwsArgumentError);
      // A life-form code is not a TAU.
      await expectLater(db.setFrameTaus(frameId, {'BLEC'}, by: 'A', at: _at), throwsArgumentError);
      await expectLater(db.setFrameTaus(frameId, {'PORM'}, by: '  ', at: _at), throwsArgumentError);
      await expectLater(db.setFrameTaus(9999, {'PORM'}, by: 'A', at: _at), throwsArgumentError);
      await expectLater(db.setTransectTaus(9999, {'PORM'}, by: 'A', at: _at), throwsArgumentError);
      expect(await db.genusTagsForSession(sessionId), isEmpty);
    });

    test('a transect outside a station, or a colony-count one, takes no tags', () async {
      final loose = await db.insertSession(_transect(null));
      final looseFrame = await db.insertFrame(_frame(loose, 0));
      await expectLater(db.setFrameTaus(looseFrame, {'PORM'}, by: 'A', at: _at), throwsArgumentError);
      await expectLater(db.setTransectTaus(loose, {'PORM'}, by: 'A', at: _at), throwsArgumentError);

      final cc = await db.insertStation(_station(type: SurveyType.colonyCount, code: 'ALG-CC'));
      final ccSession = await db.insertSession(_transect(cc));
      await expectLater(db.setTransectTaus(ccSession, {'PORM'}, by: 'A', at: _at), throwsArgumentError);
    });

    test('genusTagsForStation spans the station\'s transects only', () async {
      final second = await db.insertSession(_transect(stationId, number: 2));
      final other = await db.insertStation(_station(code: 'ALG-S2'));
      final otherSession = await db.insertSession(_transect(other));
      await db.setFrameTaus(frameId, {'PORM'}, by: 'A', at: _at);
      await db.setTransectTaus(second, {'HEL'}, by: 'A', at: _at);
      await db.setTransectTaus(otherSession, {'ACB'}, by: 'A', at: _at);
      final tags = await db.genusTagsForStation(stationId);
      expect({for (final t in tags) (t.sessionId, t.tauCode)}, {(sessionId, 'PORM'), (second, 'HEL')});
    });

    test('tagging never touches the cached cover', () async {
      await db.insertFramePoints([FramePoint(frameId: frameId, pointIndex: 0, xNorm: .5, yNorm: .5, categoryCode: 'S')]);
      await db.refreshTransectCover(sessionId);
      await db.setFrameTaus(frameId, {'PORM'}, by: 'A', at: _at);
      expect(await db.coverForSession(sessionId), isNotEmpty);
    });

    test('replacing a frame\'s photo drops its tags (D7); its tape tags stay', () async {
      await db.setFrameTaus(frameId, {'PORM'}, by: 'A', at: _at);
      await db.setTransectTaus(sessionId, {'HEL'}, by: 'A', at: _at);
      await db.replaceFrameAtMeter(_frame(sessionId, 0));
      expect(_codes(await db.genusTagsForSession(sessionId)), {'HEL'});
    });

    test('moving a frame\'s corners keeps its tags (same photo)', () async {
      await db.setFrameTaus(frameId, {'PORM'}, by: 'A', at: _at);
      await db.updateFrameCorners(
        frameId,
        const [(x: 0.2, y: 0.2), (x: 0.8, y: 0.2), (x: 0.8, y: 0.8), (x: 0.2, y: 0.8)],
        CornerSource.manual,
      );
      expect(_codes(await db.genusTagsForSession(sessionId)), {'PORM'});
    });

    test('an imported frame removed on re-save takes its tags with it', () async {
      final kept = (await db.framesForSession(sessionId)).single;
      final second = await db.insertFrame(_frame(sessionId, 1));
      await db.setFrameTaus(second, {'ACB'}, by: 'A', at: _at);
      await db.setFrameTaus(kept.id!, {'PORM'}, by: 'A', at: _at);
      await db.saveImportedFrames(sessionId, [kept]);
      expect(_codes(await db.genusTagsForSession(sessionId)), {'PORM'});
    });

    test('deleteSession removes the transect\'s tags', () async {
      await db.setFrameTaus(frameId, {'PORM'}, by: 'A', at: _at);
      await db.setTransectTaus(sessionId, {'HEL'}, by: 'A', at: _at);
      expect(await db.deleteSession(sessionId), isNotNull);
      expect(await db.genusTagsForStation(stationId), isEmpty);
    });
  });

  group('lastReviewerForStation', () {
    late TransectDatabase db;
    late int stationId;
    late int sessionId;
    late int frameId;

    setUp(() async {
      db = await TransectDatabase.openInMemoryForTest();
      stationId = await db.insertStation(_station());
      sessionId = await db.insertSession(_transect(stationId));
      frameId = await db.insertFrame(_frame(sessionId, 0));
      await db.insertFramePoints([FramePoint(frameId: frameId, pointIndex: 0, xNorm: .5, yNorm: .5, categoryCode: 'S')]);
    });
    tearDown(() => db.close());

    test('null before anyone has reviewed', () async {
      expect(await db.lastReviewerForStation(stationId), isNull);
    });

    test('the latest of corrections and tags, by time', () async {
      final point = (await db.pointsForFrame(frameId)).single.id!;
      await db.setExpertCategory(point, 'CM', by: 'Early', at: _at);
      expect(await db.lastReviewerForStation(stationId), 'Early');
      await db.setTransectTaus(sessionId, {'PORM'}, by: 'Later', at: _at.add(const Duration(hours: 1)));
      expect(await db.lastReviewerForStation(stationId), 'Later');
      await db.setExpertCategory(point, 'CB', by: 'Latest', at: _at.add(const Duration(hours: 2)));
      expect(await db.lastReviewerForStation(stationId), 'Latest');
    });

    test('another station\'s reviewers don\'t count', () async {
      final other = await db.insertStation(_station(code: 'ALG-S2'));
      final otherSession = await db.insertSession(_transect(other));
      await db.setTransectTaus(otherSession, {'PORM'}, by: 'Elsewhere', at: _at);
      expect(await db.lastReviewerForStation(stationId), isNull);
    });
  });

  group('clearExpertCategory', () {
    late TransectDatabase db;
    late int sessionId;
    late int pointId;

    setUp(() async {
      db = await TransectDatabase.openInMemoryForTest();
      final stationId = await db.insertStation(_station());
      sessionId = await db.insertSession(_transect(stationId));
      final frameId = await db.insertFrame(_frame(sessionId, 0));
      await db.insertFramePoints([
        FramePoint(frameId: frameId, pointIndex: 0, xNorm: .5, yNorm: .5, modelClass: 'sand', categoryCode: 'S'),
      ]);
      pointId = (await db.pointsForFrame(frameId)).single.id!;
    });
    tearDown(() => db.close());

    test('undoes a correction: the model\'s label counts again and the cover cache goes', () async {
      await db.setExpertCategory(pointId, 'CM', by: 'A', at: _at);
      expect((await db.refreshTransectCover(sessionId)).rows.any((r) => r.usesExpert), isTrue);
      await db.clearExpertCategory(pointId);
      expect(await db.coverForSession(sessionId), isEmpty);
      final point = (await db.pointsForSession(sessionId)).single;
      expect(point.expertCategoryCode, isNull);
      expect(point.expertName, isNull);
      expect(point.reviewedAt, isNull);
      expect(point.effectiveCategoryCode, 'S');
      expect((await db.refreshTransectCover(sessionId)).rows.any((r) => r.usesExpert), isFalse);
    });

    test('an unknown point throws', () async {
      await expectLater(db.clearExpertCategory(9999), throwsArgumentError);
    });
  });
}
