import 'package:flutter_test/flutter_test.dart';
import 'package:reefsight_mobile/services/photo_import_checks.dart';
import 'package:reefsight_mobile/services/photo_import_order.dart';
import 'package:reefsight_mobile/services/photo_metadata.dart';

// Issue #5: putting imported photos in tape order (EXIF time, filename as
// the fallback) and the checks TB 2017-05 implies (>= 5 MP, ~51 frames on a
// 50 m tape, no fisheye).

ImportedPhoto photo(String name, {DateTime? at, String? make, int? focal}) => ImportedPhoto(
      relativePath: 'transect_photos/$name',
      originalName: name,
      metadata: PhotoMetadata(width: 4000, height: 3000, capturedAt: at, make: make, focalLength35mm: focal),
    );

List<String> names(List<ImportedPhoto> photos) => [for (final p in photos) p.originalName];

void main() {
  group('naturalCompare', () {
    test('compares digit runs as numbers', () {
      final list = ['IMG_10.jpg', 'IMG_9.jpg', 'IMG_100.jpg', 'IMG_1.jpg']..sort(naturalCompare);
      expect(list, ['IMG_1.jpg', 'IMG_9.jpg', 'IMG_10.jpg', 'IMG_100.jpg']);
    });

    test('GoPro file numbers with leading zeros', () {
      final list = ['GOPR0012.JPG', 'GOPR0002.JPG', 'GOPR0011.JPG']..sort(naturalCompare);
      expect(list, ['GOPR0002.JPG', 'GOPR0011.JPG', 'GOPR0012.JPG']);
    });

    test('ignores case, then breaks ties by the exact text', () {
      expect(naturalCompare('a.jpg', 'B.jpg'), lessThan(0));
      expect(naturalCompare('img_01', 'img_1'), isNot(0));
      expect(naturalCompare('x', 'x'), 0);
    });
  });

  group('sortForImport', () {
    test('by capture time when every photo has one', () {
      final sorted = sortForImport([
        photo('c.jpg', at: DateTime(2026, 11, 15, 9, 0, 2)),
        photo('a.jpg', at: DateTime(2026, 11, 15, 9, 0, 3)),
        photo('b.jpg', at: DateTime(2026, 11, 15, 9, 0, 1)),
      ]);
      expect(names(sorted), ['b.jpg', 'c.jpg', 'a.jpg']);
    });

    test('equal times (a burst within one second) fall back to the filename', () {
      final t = DateTime(2026, 11, 15, 9);
      final sorted = sortForImport([photo('IMG_12.jpg', at: t), photo('IMG_2.jpg', at: t)]);
      expect(names(sorted), ['IMG_2.jpg', 'IMG_12.jpg']);
    });

    test('by filename when any photo has no capture time', () {
      final sorted = sortForImport([
        photo('IMG_3.jpg', at: DateTime(2026, 11, 15, 9, 0, 1)),
        photo('IMG_1.jpg'),
        photo('IMG_2.jpg', at: DateTime(2026, 11, 15, 9, 0, 0)),
      ]);
      expect(names(sorted), ['IMG_1.jpg', 'IMG_2.jpg', 'IMG_3.jpg']);
    });

    test('does not change the list it was given', () {
      final input = [photo('b.jpg'), photo('a.jpg')];
      sortForImport(input);
      expect(names(input), ['b.jpg', 'a.jpg']);
    });

    test('orderedByTime says which rule was used', () {
      expect(orderedByTime([photo('a', at: DateTime(2026)), photo('b', at: DateTime(2026))]), isTrue);
      expect(orderedByTime([photo('a', at: DateTime(2026)), photo('b')]), isFalse);
      expect(orderedByTime([]), isFalse);
    });
  });

  group('checks', () {
    test('the 5 MP line is 5,000,000 pixels', () {
      expect(isUnder5Mp(const PhotoMetadata(width: 2500, height: 2000)), isFalse);
      expect(isUnder5Mp(const PhotoMetadata(width: 2500, height: 1999)), isTrue);
      expect(isUnder5Mp(const PhotoMetadata(width: 4000, height: 3000)), isFalse);
    });

    test('an unknown size is its own flag, not "under 5 MP"', () {
      expect(isUnder5Mp(const PhotoMetadata()), isFalse);
      expect(isSizeUnknown(const PhotoMetadata()), isTrue);
      expect(isSizeUnknown(const PhotoMetadata(width: 1, height: 1)), isFalse);
    });

    test('expected frames: one per meter from 0, as in-app capture', () {
      expect(expectedFrameCount(50), 51);
      expect(expectedFrameCount(20), 21);
      expect(expectedFrameCount(50.5), 51);
    });

    test('a count far from the expected one is flagged', () {
      expect(frameCountFarOff(51, 50), isFalse);
      expect(frameCountFarOff(48, 50), isFalse);
      expect(frameCountFarOff(47, 50), isTrue);
      expect(frameCountFarOff(54, 50), isFalse);
      expect(frameCountFarOff(55, 50), isTrue);
    });

    test('a GoPro is suspected fisheye unless the diver says it shot Linear', () {
      const gopro = PhotoMetadata(make: 'GoPro', model: 'HERO11 Black');
      expect(suspectFisheye(gopro), isTrue);
      expect(suspectFisheye(gopro, lensMode: LensMode.wide), isTrue);
      expect(suspectFisheye(gopro, lensMode: LensMode.superView), isTrue);
      expect(suspectFisheye(gopro, lensMode: LensMode.unknown), isTrue);
      expect(suspectFisheye(gopro, lensMode: LensMode.linear), isFalse);
    });

    test('other cameras: only a very short focal length', () {
      expect(suspectFisheye(const PhotoMetadata(make: 'Apple', focalLength35mm: 26)), isFalse);
      expect(suspectFisheye(const PhotoMetadata(make: 'Apple', focalLength35mm: 13)), isFalse);
      expect(suspectFisheye(const PhotoMetadata(make: 'Olympus', focalLength35mm: 8)), isTrue);
      expect(suspectFisheye(const PhotoMetadata(make: 'Olympus')), isFalse);
      expect(suspectFisheye(const PhotoMetadata(focalLength35mm: 0)), isFalse, reason: '0 means unknown');
    });

    test('isActionCamera finds GoPros by make, any spelling', () {
      expect(isActionCamera(const PhotoMetadata(make: 'GoPro')), isTrue);
      expect(isActionCamera(const PhotoMetadata(make: 'GOPRO')), isTrue);
      expect(isActionCamera(const PhotoMetadata(make: 'Apple')), isFalse);
      expect(isActionCamera(const PhotoMetadata()), isFalse);
    });

    test('mixed cameras in one import are counted', () {
      expect(cameraCount([photo('a', make: 'GoPro'), photo('b', make: 'GoPro')]), 1);
      expect(cameraCount([photo('a', make: 'GoPro'), photo('b', make: 'Apple')]), 2);
      expect(cameraCount([photo('a'), photo('b')]), 0);
    });
  });
}
