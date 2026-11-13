// Tests for tool/src/cordova_replay_lib.dart, the core of tool/cordova_replay.dart (notebook 27's
// tracker replay). The point of the tool is that the colony list comes from the shipped tracker and
// the shipped counting rule, so the tests pin those behaviours through the replay path.
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reefsight_mobile/tracking/cmc_frames.dart';

import '../../tool/src/cordova_replay_lib.dart';

const _hz = 8.0;

List<ReplayUpdate> _updates(int n) =>
    [for (var i = 1; i <= n; i++) (update: i, frameIdx: (i - 1) * 4, tSec: (i - 1) / _hz)];

/// One colony drifting right 5 px per update, plus a one-off detection at update 3.
String _detsCsv(int n) {
  final sb = StringBuffer()..writeln('update,det,x1,y1,x2,y2,conf');
  for (var i = 1; i <= n; i++) {
    final x = 100.0 + 5 * (i - 1);
    sb.writeln('$i,0,$x,200,${x + 80},280,0.9');
  }
  sb.writeln('3,1,900,500,960,560,0.8');
  return sb.toString();
}

void main() {
  group('parsing', () {
    test('parseUpdates reads rows and rejects gaps', () {
      final u = parseUpdates('update,frame_idx,t_sec\n1,0,0.000\n2,4,0.125\n');
      expect(u, hasLength(2));
      expect(u[1], (update: 2, frameIdx: 4, tSec: 0.125));
      expect(() => parseUpdates('update,frame_idx,t_sec\n1,0,0\n3,8,0.25\n'), throwsFormatException);
    });

    test('parseDetections keeps the frame index as payload and drops degenerate boxes', () {
      final d = parseDetections('update,det,x1,y1,x2,y2,conf\n'
          '1,0,10,10,50,50,0.9\n1,1,60,60,60,90,0.8\n2,0,12,10,52,50,0.7\n');
      expect(d[1], hasLength(1));
      expect(d[1]!.single.payload, 0);
      expect(d[2]!.single.score, 0.7);
    });

    test('parseDetections rejects a malformed row', () {
      expect(() => parseDetections('update,det,x1,y1,x2,y2,conf\n1,0,10,10,50\n'), throwsFormatException);
    });
  });

  group('replayClip', () {
    test('counts only confirmed tracks, like ConfirmedSightings in the app', () {
      final r = replayClip(updates: _updates(6), detections: parseDetections(_detsCsv(6)), hz: _hz, cmc: false);

      // The drifting colony is one confirmed track; the one-off detection at update 3 starts a
      // track that is never matched again, so it's returned once, unconfirmed, and not counted.
      expect(r.sightings.firstSeenAt, hasLength(1));
      final oneOff = r.assignments.where((a) => a.update == 3 && a.det == 1).toList();
      expect(oneOff, hasLength(1));
      expect(oneOff.single.activated, isFalse);
      expect(r.sightings.firstSeenAt.containsKey(oneOff.single.trackId), isFalse);
    });

    test('maps every update of the colony to its detection, with times from updates.csv', () {
      final r = replayClip(updates: _updates(6), detections: parseDetections(_detsCsv(6)), hz: _hz, cmc: false);
      final id = r.sightings.firstSeenAt.keys.single;
      final rows = r.assignments.where((a) => a.trackId == id).toList();
      expect(rows.map((a) => a.update), [1, 2, 3, 4, 5, 6]);
      expect(rows.every((a) => a.det == 0), isTrue);
      expect(secondsOf(r.sightings.firstSeenAt[id]!), 0.0);
      expect(secondsOf(r.sightings.lastSeenAt[id]!), 5 / _hz);
    });

    test('updates with no detections still advance the tracker', () {
      // Colony at updates 1-2, nothing at 3-4, back at 5: within the 3.75 s buffer, so it's the
      // same track, not a second colony.
      final dets = parseDetections('update,det,x1,y1,x2,y2,conf\n'
          '1,0,100,200,180,280,0.9\n2,0,100,200,180,280,0.9\n5,0,100,200,180,280,0.9\n');
      final r = replayClip(updates: _updates(5), detections: dets, hz: _hz, cmc: false);
      expect(r.sightings.firstSeenAt, hasLength(1));
      expect(secondsOf(r.sightings.lastSeenAt.values.single), 4 / _hz);
    });

    test('feeds CMC frames when given, and counts updates without one', () {
      final rng = Random(0);
      final pixels = Uint8List.fromList([for (var i = 0; i < 160 * 90; i++) rng.nextInt(256)]);
      final frame = ScaledGrayscaleFrame(width: 160, height: 90, pixels: pixels, scale: 12);
      final r = replayClip(
        updates: _updates(6),
        detections: parseDetections(_detsCsv(6)),
        hz: _hz,
        frameFor: (u) => u == 4 ? null : frame,
      );
      expect(r.cmcFrames, 5);
      expect(r.sightings.firstSeenAt, hasLength(1));
    });
  });

  test('formatAssignments and formatColonies write the documented headers', () {
    final r = replayClip(updates: _updates(3), detections: parseDetections(_detsCsv(3)), hz: _hz, cmc: false);
    expect(formatAssignments(r.assignments).split('\n').first, 'update,track_id,det,activated');
    final colonies = formatColonies(r.sightings).trim().split('\n');
    expect(colonies.first, 'track_id,first_seen_sec,last_seen_sec');
    expect(colonies.skip(1).single, '1,0.000,0.250');
  });
}
