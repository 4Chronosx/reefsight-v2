import 'package:flutter_test/flutter_test.dart';
import 'package:reefsight_mobile/services/share_package.dart';
import 'package:reefsight_mobile/services/station.dart';
import 'package:reefsight_mobile/services/transect_frame.dart';
import 'package:reefsight_mobile/services/transect_session.dart';

// Issue #9: the names inside a share package -- the zip, its root folder,
// each transect's folder and each photo -- so a station saved to Drive sorts
// the same way on every phone.

TransectFrame _frame({double? meter, int? videoMs, String path = 'frames/1/a.jpg'}) => TransectFrame(
      sessionId: 1,
      meterMark: meter,
      videoTimeMs: videoMs,
      imagePath: path,
      source: meter == null ? FrameSource.videoFrame : FrameSource.inApp,
    );

Station _station({String code = 'ALG-S1', SurveyType type = SurveyType.photoTransect}) => Station(
      code: code,
      surveyType: type,
      surveyedOn: DateTime(2026, 11, 15),
      createdAt: DateTime.utc(2026, 11, 15),
    );

void main() {
  group('photoEntryName', () {
    test('order number, then the meter mark padded to two digits', () {
      expect(photoEntryName(1, _frame(meter: 0)), '001_m00.jpg');
      expect(photoEntryName(12, _frame(meter: 11)), '012_m11.jpg');
      expect(photoEntryName(51, _frame(meter: 50)), '051_m50.jpg');
    });

    test('a decimal meter mark keeps its decimal, with a dash', () {
      expect(photoEntryName(13, _frame(meter: 12.5)), '013_m12-5.jpg');
    });

    test('a video frame is named by its time in the video', () {
      expect(photoEntryName(3, _frame(videoMs: 65400)), '003_t01-05.jpg');
    });

    test('a frame with neither is just its order number', () {
      expect(photoEntryName(4, _frame()), '004.jpg');
    });

    test("keeps the file's own extension, lowercased", () {
      expect(photoEntryName(1, _frame(meter: 0, path: 'imports/7/GOPR0001.JPG')), '001_m00.jpg');
      expect(photoEntryName(1, _frame(meter: 0, path: 'imports/7/IMG_1.HEIC')), '001_m00.heic');
      expect(photoEntryName(1, _frame(meter: 0, path: 'imports/7/noext')), '001_m00.jpg');
    });
  });

  group('stationRootName', () {
    test('station code and survey day when every transect is in', () {
      expect(stationRootName(_station(), const [1, 2, 3], all: true), 'ALG-S1_2026-11-15');
    });

    test('one transect adds its number', () {
      expect(stationRootName(_station(), const [2], all: false), 'ALG-S1_2026-11-15_T2');
    });

    test('several, not all, list their numbers', () {
      expect(stationRootName(_station(), const [3, 1], all: false), 'ALG-S1_2026-11-15_T1_T3');
    });

    test('a preliminary station is stamped on the name', () {
      expect(
        stationRootName(_station(type: SurveyType.preliminaryVideo), const [1], all: true),
        'PRELIMINARY_ALG-S1_2026-11-15',
      );
    });

    test('the free-text code cannot leave the folder', () {
      expect(stationRootName(_station(code: '../x/ S1'), const [1], all: true), '___x__S1_2026-11-15');
      expect(stationRootName(_station(code: '  '), const [1], all: true), 'station_2026-11-15');
    });
  });

  group('unassignedRootName', () {
    test('site, local day and start time', () {
      final startedAt = DateTime(2026, 10, 4, 9, 7);
      final session = TransectSession(startedAt: startedAt, tapeLengthMeters: 50, siteName: 'Alegria MPA');
      expect(unassignedRootName(session), 'Alegria_MPA_2026-10-04_0907');
    });

    test('no site name', () {
      final session = TransectSession(startedAt: DateTime(2026, 10, 4, 14, 30), tapeLengthMeters: 50);
      expect(unassignedRootName(session), 'Unknown_Site_2026-10-04_1430');
    });
  });

  test('transectFolder', () {
    expect(
      transectFolder(TransectSession(startedAt: DateTime(2026), tapeLengthMeters: 50, stationId: 1, transectNumber: 4)),
      'T4',
    );
    expect(transectFolder(TransectSession(startedAt: DateTime(2026), tapeLengthMeters: 50)), 'transect');
  });

  test('describeBytes', () {
    expect(describeBytes(0), '0 KB');
    expect(describeBytes(900), '1 KB');
    expect(describeBytes(2400000), '2.4 MB');
    expect(describeBytes(1250000000), '1.25 GB');
  });
}
