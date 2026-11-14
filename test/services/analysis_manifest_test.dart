import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:reefsight_mobile/services/analysis_manifest.dart';
import 'package:reefsight_mobile/services/coralscapes_mapping.dart';
import 'package:reefsight_mobile/services/frame_point.dart';
import 'package:reefsight_mobile/services/point_sampler.dart';
import 'package:reefsight_mobile/services/station.dart';
import 'package:reefsight_mobile/services/transect_frame.dart';
import 'package:reefsight_mobile/services/transect_session.dart';

// Issue #7: the app -> laptop manifest and the laptop -> app results file.
// Format spec: docs/laptop-analysis-exchange-format.md.

const _corners = <NormPoint>[(x: 0.1, y: 0.12), (x: 0.88, y: 0.1), (x: 0.9, y: 0.9), (x: 0.12, y: 0.86)];

final _station = Station(
  id: 4,
  code: 'ALG-S1',
  name: 'Alegria north',
  surveyType: SurveyType.photoTransect,
  frameMode: FrameMode.physical,
  surveyedOn: DateTime(2026, 11, 15),
  siteName: 'Alegria MPA',
  createdAt: DateTime.utc(2026, 11, 15, 1),
);

TransectSession _session(int id, int number) => TransectSession(
      id: id,
      startedAt: DateTime.utc(2026, 11, 15, 2),
      tapeLengthMeters: 50,
      stationId: 4,
      transectNumber: number,
      pointsPerFrame: 2,
      pointSeed: 123456789,
    );

TransectFrame _frame(int id, int sessionId, double meter,
        {List<NormPoint>? corners = _corners, bool excluded = false, String? path}) =>
    TransectFrame(
      id: id,
      sessionId: sessionId,
      meterMark: meter,
      imagePath: path ?? 'photo_transects/$sessionId/m$meter.jpg',
      source: FrameSource.inApp,
      widthPx: 4032,
      heightPx: 3024,
      corners: corners,
      cornerSource: corners == null ? null : CornerSource.manual,
      excluded: excluded,
    );

List<FramePoint> _points(int frameId, int firstId) => [
      FramePoint(id: firstId, frameId: frameId, pointIndex: 0, xNorm: 0.25, yNorm: 0.5),
      FramePoint(id: firstId + 1, frameId: frameId, pointIndex: 1, xNorm: 0.75, yNorm: 0.1),
    ];

void main() {
  group('buildAnalysisManifest', () {
    AnalysisManifest build() => buildAnalysisManifest(
          station: _station,
          transects: [
            (
              session: _session(12, 1),
              frames: [
                _frame(301, 12, 0),
                _frame(302, 12, 1),
                _frame(303, 12, 2, excluded: true),
                _frame(304, 12, 3, corners: null),
                TransectFrame.missingMeter(sessionId: 12, meterMark: 4),
                _frame(306, 12, 12.5, path: 'imported/12/IMG_0042.JPEG'),
              ],
              points: [..._points(301, 9001), ..._points(302, 9003), ..._points(303, 9005), ..._points(306, 9007)],
            ),
          ],
          modelId: kCoralscapesModelId,
          exportedAt: DateTime.utc(2026, 11, 16, 1, 2, 3),
        );

    test('carries the header, station and transect identity', () {
      final json = build().json;
      expect(json['format'], kManifestFormat);
      expect(json['version'], kAnalysisFormatVersion);
      expect(json['model_id'], kCoralscapesModelId);
      expect(json['exported_at'], '2026-11-16T01:02:03.000Z');
      expect(json['station'], containsPair('code', 'ALG-S1'));
      expect(json['station'], containsPair('surveyed_on', '2026-11-15'));
      final t = (json['transects'] as List).single as Map;
      expect(t['session_id'], 12);
      expect(t['transect_number'], 1);
      expect(t['point_seed'], 123456789);
    });

    test('only frames that can be scored and have points are sent', () {
      final t = (build().json['transects'] as List).single as Map;
      expect([for (final f in t['frames'] as List) (f as Map)['frame_id']], [301, 302, 306]);
    });

    test('each point carries its area and photo positions; the photo one is frameToImage', () {
      final t = (build().json['transects'] as List).single as Map;
      final f = (t['frames'] as List).first as Map;
      expect(f['width_px'], 4032);
      expect(f['height_px'], 3024);
      expect(f['corners'], [for (final c in _corners) [c.x, c.y]]);
      final p = (f['points'] as List).first as Map;
      final expected = frameToImage(_corners, (x: 0.25, y: 0.5));
      expect(p['point_id'], 9001);
      expect(p['index'], 0);
      expect(p['u'], 0.25);
      expect(p['v'], 0.5);
      expect(p['img_x'], closeTo(expected.x, 1e-12));
      expect(p['img_y'], closeTo(expected.y, 1e-12));
    });

    test('photo names are per transect and meter, keeping the extension', () {
      final m = build();
      expect([for (final i in m.images) i.entry], [
        'photos/T1/m00.jpg',
        'photos/T1/m01.jpg',
        'photos/T1/m12_5.jpeg',
      ]);
      expect(m.images.first.imagePath, 'photo_transects/12/m0.0.jpg');
      final t = (m.json['transects'] as List).single as Map;
      expect([for (final f in t['frames'] as List) (f as Map)['image']], [for (final i in m.images) i.entry]);
    });

    test('a transect with nothing to score is left out', () {
      final m = buildAnalysisManifest(
        station: _station,
        transects: [(session: _session(13, 2), frames: [_frame(401, 13, 0)], points: const [])],
        modelId: kCoralscapesModelId,
        exportedAt: DateTime.utc(2026, 11, 16),
      );
      expect(m.json['transects'], isEmpty);
      expect(m.images, isEmpty);
    });

    test('is plain JSON', () {
      expect(() => jsonEncode(build().json), returnsNormally);
    });
  });

  group('parseAnalysisResults', () {
    Map<String, Object?> valid() => {
          'format': kResultsFormat,
          'version': 1,
          'run_id': '20261116_101500',
          'model_id': kCoralscapesModelId,
          'model_revision': 'c61183ec41b40a660491ea90babf54ff40b673dd',
          'transects': [
            {
              'session_id': 12,
              'point_seed': 123456789,
              'frames': [
                {
                  'frame_id': 301,
                  'corners': [for (final c in _corners) [c.x, c.y]],
                  'points': [
                    {'point_id': 9001, 'model_class': 'branching alive', 'confidence': 0.87},
                    {'point_id': 9002, 'model_class': 'sand', 'confidence': 1},
                  ],
                },
              ],
            },
          ],
        };

    test('reads a valid file', () {
      final r = parseAnalysisResults(jsonEncode(valid()));
      expect(r.modelId, kCoralscapesModelId);
      expect(r.runId, '20261116_101500');
      expect(r.modelRevision, startsWith('c61183ec'));
      final t = r.transects.single;
      expect(t.sessionId, 12);
      expect(t.pointSeed, 123456789);
      final f = t.frames.single;
      expect(f.frameId, 301);
      expect(f.corners, _corners);
      expect(f.points.first.pointId, 9001);
      expect(f.points.first.modelClass, 'branching alive');
      expect(f.points.first.confidence, 0.87);
      expect(f.points.last.confidence, 1.0);
    });

    test('a missing confidence is allowed', () {
      final j = valid();
      _point0(j).remove('confidence');
      expect(parseAnalysisResults(jsonEncode(j)).transects.single.frames.single.points.first.confidence, isNull);
    });

    test('rejects text that is not JSON', () {
      expect(() => parseAnalysisResults('not json'), throwsFormatException);
    });

    void rejects(String why, void Function(Map<String, Object?> j) breakIt) {
      test('rejects $why', () {
        final j = valid();
        breakIt(j);
        expect(() => parseAnalysisResults(jsonEncode(j)), throwsFormatException);
      });
    }

    rejects('the manifest itself', (j) => j['format'] = kManifestFormat);
    rejects('a newer version', (j) => j['version'] = 2);
    rejects('a missing model id', (j) => j.remove('model_id'));
    rejects('no transects', (j) => j['transects'] = []);
    rejects('a missing point seed', (j) => ((j['transects'] as List).first as Map).remove('point_seed'));
    rejects('three corners', (j) => (_frame0(j)['corners'] as List).removeLast());
    rejects('a blank class', (j) => _point0(j)['model_class'] = ' ');
    rejects('a confidence above 1', (j) => _point0(j)['confidence'] = 1.5);
    rejects('a point id as text', (j) => _point0(j)['point_id'] = '9001');
    rejects('the same point twice', (j) {
      final points = _frame0(j)['points'] as List;
      points.add(points.first);
    });
    rejects('the same frame twice', (j) {
      final frames = ((j['transects'] as List).first as Map)['frames'] as List;
      frames.add(frames.first);
    });
    rejects('the same transect twice', (j) => (j['transects'] as List).add((j['transects'] as List).first));
  });
}

Map<String, Object?> _frame0(Map<String, Object?> j) =>
    ((((j['transects'] as List).first as Map)['frames'] as List).first as Map).cast<String, Object?>();

Map<String, Object?> _point0(Map<String, Object?> j) =>
    ((_frame0(j)['points'] as List).first as Map).cast<String, Object?>();
