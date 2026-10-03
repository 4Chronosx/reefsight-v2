// Sub-plan 08 step 4: only confirmed tracks are tallied and persisted as colonies.
import 'package:flutter_test/flutter_test.dart';
import 'package:reefsight_mobile/services/confirmed_sightings.dart';
import 'package:reefsight_mobile/tracking/strack.dart';

STrack _track(int id, {required bool confirmed}) => STrack([0, 0, 10, 10], 0.9)
  ..trackId = id
  ..isActivated = confirmed;

DateTime _t(int s) => DateTime.utc(2026, 10, 4, 9, 0, s);

void main() {
  test('unconfirmed tracks are not counted', () {
    final sightings = ConfirmedSightings()
      ..observe([_track(1, confirmed: true), _track(2, confirmed: false)], _t(0));
    expect(sightings.firstSeenAt.keys, [1]);
    expect(sightings.lastSeenAt.keys, [1]);
    expect(sightings.pendingCount, 1);
  });

  test('a track confirmed later is counted from when it first appeared', () {
    final sightings = ConfirmedSightings()
      ..observe([_track(2, confirmed: false)], _t(0))
      ..observe([_track(2, confirmed: true)], _t(1))
      ..observe([_track(2, confirmed: true)], _t(2));
    expect(sightings.firstSeenAt, {2: _t(0)});
    expect(sightings.lastSeenAt, {2: _t(2)});
    expect(sightings.pendingCount, 0);
  });

  test('a one-frame flicker never counts and does not linger', () {
    final sightings = ConfirmedSightings()
      ..observe([_track(3, confirmed: false)], _t(0))
      ..observe(const [], _t(1));
    expect(sightings.firstSeenAt, isEmpty);
    expect(sightings.pendingCount, 0);
  });

  test('a confirmed colony stays counted after it leaves view', () {
    final sightings = ConfirmedSightings()
      ..observe([_track(4, confirmed: true)], _t(0))
      ..observe(const [], _t(1));
    expect(sightings.firstSeenAt, {4: _t(0)});
    expect(sightings.lastSeenAt, {4: _t(0)});
  });
}
