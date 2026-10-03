// Tests for tool/src/track_eval_lib.dart, the building blocks of sub-plan 08's offline tracking
// harness (tool/track_eval.dart). The parity group is the important one: it proves the harness
// drives `BoTSortTracker` exactly the way the reference-parity fixtures do, so harness output is
// the shipped tracker's behaviour and not an artefact of the harness.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reefsight_mobile/tracking/camera_motion_compensation.dart';
import 'package:reefsight_mobile/tracking/tracker_detection.dart';

import '../../tool/src/track_eval_lib.dart';

TrackerDetection _det(double x1, double y1, double score, {double w = 40, double h = 40}) =>
    TrackerDetection(x1: x1, y1: y1, x2: x1 + w, y2: y1 + h, score: score);

void main() {
  group('reference parity through the harness', () {
    final fixtureFiles = Directory('test/tracking/fixtures').existsSync()
        ? (Directory('test/tracking/fixtures').listSync().whereType<File>()
            .where((f) => f.path.endsWith('.json')).toList()
          ..sort((a, b) => a.path.compareTo(b.path)))
        : <File>[];

    test('fixtures are present', () => expect(fixtureFiles, hasLength(4)));

    for (final file in fixtureFiles) {
      final name = file.uri.pathSegments.last.replaceAll('.json', '');
      test('runSequence reproduces "$name"', () {
        final fixture = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
        final c = fixture['config'] as Map<String, dynamic>;
        final frames = (fixture['frames'] as List<dynamic>).cast<Map<String, dynamic>>();

        // detFloor 0: the fixtures carry their own low-score detections and expect the tracker,
        // not a cutoff in front of it, to handle them.
        final config = const EvalConfig(detFloor: 0).withOverrides({
          'trackHighThresh': c['trackHighThresh'],
          'trackLowThresh': c['trackLowThresh'],
          'newTrackThresh': c['newTrackThresh'],
          'matchThresh': c['matchThresh'],
          'trackBuffer': c['trackBuffer'],
          'fuseScore': c['fuseScore'],
        }, hz: 8);
        final detections = {
          for (var i = 0; i < frames.length; i++)
            i + 1: [
              for (final d in (frames[i]['detections'] as List<dynamic>).cast<Map<String, dynamic>>())
                TrackerDetection(
                  x1: (d['x1'] as num).toDouble(),
                  y1: (d['y1'] as num).toDouble(),
                  x2: (d['x2'] as num).toDouble(),
                  y2: (d['y2'] as num).toDouble(),
                  score: (d['score'] as num).toDouble(),
                ),
            ],
        };

        final rows = runSequence(numFrames: frames.length, detections: detections, config: config);

        for (var i = 0; i < frames.length; i++) {
          final expected = (frames[i]['expected_tracks'] as List<dynamic>).cast<Map<String, dynamic>>();
          final actual = rows.where((r) => r.frame == i + 1).toList();
          expect(actual.map((r) => r.trackId).toList(),
              expected.map((t) => t['track_id'] as int).toList(),
              reason: 'track ids on frame $i of "$name"');
          for (var k = 0; k < actual.length; k++) {
            final tlbr = (expected[k]['tlbr'] as List<dynamic>).map((v) => (v as num).toDouble());
            for (final (j, v) in tlbr.indexed) {
              expect(actual[k].tlbr[j], closeTo(v, 1e-6), reason: 'tlbr[$j], frame $i of "$name"');
            }
          }
        }
      });
    }
  });

  group('MOT parsing and formatting', () {
    test('parseMotDetections converts xywh to tlbr per frame and keeps every score', () {
      final dets = parseMotDetections('1,-1,10.00,20.00,30.00,40.00,0.91000,-1,-1,-1\n'
          '1,-1,100,100,10,10,0.06,-1,-1,-1\n'
          '\n'
          '3,-1,5,5,5,5,0.5,-1,-1,-1\n');
      expect(dets.keys, [1, 3]);
      expect(dets[1], hasLength(2));
      final d = dets[1]!.first;
      expect([d.x1, d.y1, d.x2, d.y2, d.score], [10, 20, 40, 60, 0.91]);
      expect(dets[1]![1].score, 0.06, reason: 'no floor at parse time');
    });

    test('parseMotDetections drops zero-area boxes instead of tripping TrackerDetection', () {
      expect(parseMotDetections('1,-1,10,10,0,5,0.9,-1,-1,-1\n'), isEmpty);
    });

    test('parseGtAsOracle keeps class-1 colonies only, at score 1.0', () {
      final dets = parseGtAsOracle('1,1,10,10,20,20,1,1,1\n'
          '1,2,50,50,20,20,1,8,1\n'
          '2,1,12,10,20,20,1,1,1\n');
      expect(dets[1], hasLength(1));
      expect(dets[1]!.single.score, 1.0);
      expect(dets[2]!.single.x1, 12);
    });

    test('formatMot writes frame,id,x,y,w,h,conf,-1,activated,-1', () {
      final text = formatMot(const [
        MotRow(2, 7, [10, 20, 40, 60], 0.87654, true),
        MotRow(2, 8, [1, 2, 3, 4], 0.5, false),
      ]);
      expect(text.trim().split('\n'), [
        '2,7,10.00,20.00,30.00,40.00,0.8765,-1,1,-1',
        '2,8,1.00,2.00,2.00,2.00,0.5000,-1,0,-1',
      ]);
    });

    test('formatMot output round-trips through parseMotDetections', () {
      final dets = parseMotDetections(formatMot(const [MotRow(4, 1, [10, 20, 40, 60], 0.9, true)]));
      final d = dets[4]!.single;
      expect([d.x1, d.y1, d.x2, d.y2, d.score], [10, 20, 40, 60, 0.9]);
    });
  });

  group('EvalConfig', () {
    test('defaults are the tracker as the app ships it', () {
      const c = EvalConfig();
      expect(c.toJson(), {
        'trackHighThresh': 0.6,
        'trackLowThresh': 0.1,
        'newTrackThresh': 0.7,
        'matchThresh': 0.8,
        'trackBuffer': 30,
        'fuseScore': true,
        'detFloor': 0.25,
        'cmc': false,
      });
    });

    test('bufferUpdatesFor converts seconds to tracker updates at the given rate', () {
      expect(bufferUpdatesFor(seconds: 3.75, hz: 8), 30);
      expect(bufferUpdatesFor(seconds: 2, hz: 25 / 3), 17);
      expect(bufferUpdatesFor(seconds: 0.01, hz: 5), 1, reason: 'never below one update');
      expect(() => bufferUpdatesFor(seconds: 0, hz: 8), throwsArgumentError);
    });

    test('trackBufferSeconds override converts; giving both units is rejected', () {
      expect(const EvalConfig().withOverrides({'trackBufferSeconds': 1.5}, hz: 8).trackBuffer, 12);
      expect(() => const EvalConfig().withOverrides({'trackBuffer': 10, 'trackBufferSeconds': 1},
          hz: 8), throwsArgumentError);
    });

    test('unknown keys are rejected rather than silently ignored', () {
      expect(() => const EvalConfig().withOverrides({'trackHighThreshold': 0.5}, hz: 8),
          throwsArgumentError);
    });
  });

  group('expandSweep', () {
    test('grid is a cartesian product on top of base; arms keep their names', () {
      final arms = expandSweep({
        'base': {'detFloor': 0.3},
        'arms': [
          {'name': 'shipped'},
        ],
        'grid': {
          'trackHighThresh': [0.4, 0.5],
          'trackBufferSeconds': [1, 2],
        },
      }, base: const EvalConfig(), hz: 8);
      expect(arms, hasLength(5));
      expect(arms.first.$1, 'shipped');
      expect(arms.every((a) => a.$2.detFloor == 0.3), isTrue);
      expect({for (final a in arms.skip(1)) (a.$2.trackHighThresh, a.$2.trackBuffer)},
          {(0.4, 8), (0.4, 16), (0.5, 8), (0.5, 16)});
    });

    test('duplicate arm names and empty specs are errors', () {
      expect(() => expandSweep({
            'arms': [{}, {}],
          }, base: const EvalConfig(), hz: 8), throwsArgumentError);
      expect(() => expandSweep({}, base: const EvalConfig(), hz: 8), throwsArgumentError);
    });
  });

  group('runSequence', () {
    // One colony last seen on frame 2, trackBuffer 3. The tracker marks it removed on frame 6
    // (6 - 2 > 3), but -- faithfully to the BoT-SORT/ByteTrack reference -- `_lostStracks` is pruned
    // against the *previous* update's removed list before this update's removals are appended, so
    // the track is still matchable on frame 7 and only gone from frame 8. Net effect: a track
    // survives `trackBuffer + 1` empty updates. Both cases below only hold if update() ran on the
    // empty frames in between.
    List<int> idsWhenReappearingOn(int frame) => {
          for (final r in runSequence(
            numFrames: frame,
            detections: {
              1: [_det(100, 100, 0.9)],
              2: [_det(102, 100, 0.9)],
              frame: [_det(104, 100, 0.9)],
            },
            config: const EvalConfig(trackBuffer: 3),
          ))
            r.trackId,
        }.toList();

    test('a track reappearing within trackBuffer + 1 empty updates keeps its id', () {
      expect(idsWhenReappearingOn(7), [1]);
    });

    test('calls update on empty frames, so a lost track ages out on schedule', () {
      expect(idsWhenReappearingOn(8), [1, 2]);
    });

    test('detFloor removes detections before the tracker sees them', () {
      final dets = {
        for (var f = 1; f <= 3; f++) f: [_det(100, 100, 0.2)],
      };
      final atApp = runSequence(numFrames: 3, detections: dets, config: const EvalConfig(
          trackHighThresh: 0.1, newTrackThresh: 0.1));
      final lower = runSequence(numFrames: 3, detections: dets, config: const EvalConfig(
          trackHighThresh: 0.1, newTrackThresh: 0.1, detFloor: 0.1));
      expect(atApp, isEmpty, reason: '0.2 < the app floor of 0.25');
      expect(lower, isNotEmpty);
    });

    test('records unconfirmed tracks as not activated', () {
      // Frame 1 auto-activates; a new detection appearing on frame 2 starts unconfirmed.
      final rows = runSequence(
        numFrames: 2,
        detections: {
          1: [_det(100, 100, 0.9)],
          2: [_det(101, 100, 0.9), _det(400, 400, 0.9)],
        },
        config: const EvalConfig(),
      );
      final frame2 = rows.where((r) => r.frame == 2).toList();
      expect(frame2.map((r) => r.activated).toList(), unorderedEquals([true, false]));
      expect(summarize(rows), {'rows': 3, 'unique_ids': 2, 'unique_activated_ids': 1});
    });

    test('replayed precomputed warps reproduce live CMC exactly', () {
      // A textured scene panning 3 px/frame, with two colonies moving with it -- enough real
      // camera motion for CMC to produce non-identity warps.
      GrayscaleFrame frameAt(int f) => GrayscaleFrame(width: 160, height: 120, pixels: [
            for (var y = 0; y < 120; y++)
              for (var x = 0; x < 160; x++)
                (((x + 3 * f) ~/ 9) + (y ~/ 7)).isEven ? 30 + (x * 7 + y * 3) % 40 : 210,
          ]);
      final dets = {
        for (var f = 1; f <= 12; f++)
          f: [
            _det(80.0 - 3 * f, 30, 0.9, w: 20, h: 20),
            if (f.isOdd) _det(100.0 - 3 * f, 70, 0.4, w: 16, h: 16),
          ],
      };
      const config = EvalConfig(cmc: true);
      final live = runSequence(numFrames: 12, detections: dets, config: config, frameLoader: frameAt);
      final warps = computeWarps(numFrames: 12, frameLoader: frameAt);
      final replayed = runSequence(numFrames: 12, detections: dets, config: config, warps: warps);

      expect(warps.skip(1).any((w) => w[0][2] != 0 || w[1][2] != 0), isTrue,
          reason: 'the scene must produce real (non-identity) warps for this test to mean anything');
      expect(formatMot(replayed), formatMot(live));
      expect(() => runSequence(numFrames: 13, detections: dets, config: config, warps: warps),
          throwsArgumentError, reason: 'warp count must match the frame count');
    });

    test('cmc without a frame loader is an error; with one, frames are requested in order', () {
      expect(() => runSequence(numFrames: 1, detections: {}, config: const EvalConfig(cmc: true)),
          throwsArgumentError);
      final requested = <int>[];
      final pixels = [
        for (var y = 0; y < 64; y++)
          for (var x = 0; x < 64; x++) ((x ~/ 8) + (y ~/ 8)).isEven ? 40 : 220,
      ];
      runSequence(
        numFrames: 3,
        detections: {
          1: [_det(10, 10, 0.9, w: 20, h: 20)],
        },
        config: const EvalConfig(cmc: true),
        frameLoader: (f) {
          requested.add(f);
          return GrayscaleFrame(width: 64, height: 64, pixels: pixels);
        },
      );
      expect(requested, [1, 2, 3]);
    });
  });
}
