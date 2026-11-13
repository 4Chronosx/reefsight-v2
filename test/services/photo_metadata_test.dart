import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:reefsight_mobile/services/photo_metadata.dart';

// Issue #5: reading what an imported photo's header says -- pixel size,
// camera, capture time, orientation and lens -- without decoding the image.
// Fixtures are real JPEGs built in code with EXIF injected by `package:image`.

Uint8List jpegWithExif({
  int width = 64,
  int height = 48,
  String? make,
  String? model,
  String? taken,
  String? offset,
  int? orientation,
  int? focal35,
}) {
  final bytes = img.encodeJpg(img.Image(width: width, height: height));
  final exif = img.ExifData();
  if (make != null) exif.imageIfd['Make'] = make;
  if (model != null) exif.imageIfd['Model'] = model;
  if (orientation != null) exif.imageIfd['Orientation'] = orientation;
  if (taken != null) exif.exifIfd['DateTimeOriginal'] = taken;
  if (offset != null) exif.exifIfd['OffsetTimeOriginal'] = offset;
  // `package:image`'s tag table has no type for this tag, so its setter
  // drops a plain int; cameras write it as a SHORT.
  if (focal35 != null) exif.exifIfd['FocalLengthIn35mmFilm'] = img.IfdValueShort(focal35);
  return img.injectJpgExif(bytes, exif)!;
}

void main() {
  group('parseExifDateTime', () {
    test('reads EXIF wall-clock time as local time', () {
      expect(parseExifDateTime('2026:11:15 09:12:33'), DateTime(2026, 11, 15, 9, 12, 33));
    });

    test('with an offset, gives the exact instant in UTC', () {
      expect(parseExifDateTime('2026:11:15 09:12:33', '+08:00'), DateTime.utc(2026, 11, 15, 1, 12, 33));
      expect(parseExifDateTime('2026:11:15 09:12:33', '-03:30'), DateTime.utc(2026, 11, 15, 12, 42, 33));
    });

    test('ignores a malformed offset rather than the whole time', () {
      expect(parseExifDateTime('2026:11:15 09:12:33', 'junk'), DateTime(2026, 11, 15, 9, 12, 33));
    });

    test('rejects blanks, zeros and junk', () {
      expect(parseExifDateTime(null), isNull);
      expect(parseExifDateTime(''), isNull);
      expect(parseExifDateTime('0000:00:00 00:00:00'), isNull);
      expect(parseExifDateTime('    :  :     :  :  '), isNull);
      expect(parseExifDateTime('yesterday'), isNull);
    });

    test('tolerates trailing NULs from fixed-width EXIF strings', () {
      expect(parseExifDateTime('2026:11:15 09:12:33\u0000'), DateTime(2026, 11, 15, 9, 12, 33));
    });
  });

  group('parseJpegMetadata', () {
    test('reads size, camera, time and lens', () {
      final meta = parseJpegMetadata(jpegWithExif(
        width: 80,
        height: 60,
        make: 'GoPro',
        model: 'HERO11 Black',
        taken: '2026:11:15 09:12:33',
        focal35: 15,
      ));
      expect(meta.width, 80);
      expect(meta.height, 60);
      expect(meta.make, 'GoPro');
      expect(meta.model, 'HERO11 Black');
      expect(meta.capturedAt, DateTime(2026, 11, 15, 9, 12, 33));
      expect(meta.focalLength35mm, 15);
      expect(meta.orientation, 1);
    });

    test('a rotated photo (orientation 6) swaps width and height', () {
      final meta = parseJpegMetadata(jpegWithExif(width: 80, height: 60, orientation: 6));
      expect(meta.orientation, 6);
      expect(meta.width, 60);
      expect(meta.height, 80);
    });

    test('orientation 3 (upside down) keeps width and height', () {
      final meta = parseJpegMetadata(jpegWithExif(width: 80, height: 60, orientation: 3));
      expect(meta.width, 80);
      expect(meta.height, 60);
    });

    test('a JPEG with no EXIF still gives its size', () {
      final meta = parseJpegMetadata(img.encodeJpg(img.Image(width: 30, height: 20)));
      expect(meta.width, 30);
      expect(meta.height, 20);
      expect(meta.make, isNull);
      expect(meta.capturedAt, isNull);
      expect(meta.orientation, 1);
    });

    test('blank camera strings come back null', () {
      final meta = parseJpegMetadata(jpegWithExif(make: '  ', model: ''));
      expect(meta.make, isNull);
      expect(meta.model, isNull);
    });

    test('not a JPEG gives empty metadata, not an error', () {
      final meta = parseJpegMetadata(Uint8List.fromList([1, 2, 3, 4, 5]));
      expect(meta.width, isNull);
      expect(meta.height, isNull);
      expect(meta.make, isNull);
    });

    test('megapixels', () {
      expect(const PhotoMetadata(width: 4000, height: 3000).pixelCount, 12000000);
      expect(const PhotoMetadata().pixelCount, isNull);
    });
  });

  group('isJpeg', () {
    test('by magic bytes, not by name', () {
      expect(isJpeg(Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE1])), isTrue);
      // An HEIC: `....ftypheic`.
      expect(isJpeg(Uint8List.fromList([0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70])), isFalse);
      expect(isJpeg(Uint8List(1)), isFalse);
    });
  });

  group('DartJpegMetadataReader', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('reefsight_meta_'));
    tearDown(() async => dir.delete(recursive: true));

    test('reads a file on disk', () async {
      final file = File(p.join(dir.path, 'GOPR0001.JPG'));
      await file.writeAsBytes(jpegWithExif(width: 40, height: 30, make: 'GoPro', taken: '2026:11:15 09:00:00'));
      final meta = await const DartJpegMetadataReader().read(file.path);
      expect(meta.width, 40);
      expect(meta.make, 'GoPro');
      expect(meta.capturedAt, DateTime(2026, 11, 15, 9));
    });
  });

  group('RoutingMetadataReader', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('reefsight_meta_'));
    tearDown(() async => dir.delete(recursive: true));

    test('JPEGs go to the Dart reader, everything else to the native one', () async {
      final jpeg = File(p.join(dir.path, 'a.jpg'))..writeAsBytesSync(jpegWithExif(width: 40, height: 30));
      final heic = File(p.join(dir.path, 'b.heic'))
        ..writeAsBytesSync([0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70, 0x68, 0x65, 0x69, 0x63]);
      final native = _FakeReader(const PhotoMetadata(width: 4032, height: 3024, make: 'Apple'));
      final reader = RoutingMetadataReader(native: native);

      expect((await reader.read(jpeg.path)).width, 40);
      expect(native.paths, isEmpty);
      expect((await reader.read(heic.path)).make, 'Apple');
      expect(native.paths, [heic.path]);
    });

    test('a failing native reader gives empty metadata rather than stopping the import', () async {
      final heic = File(p.join(dir.path, 'b.heic'))..writeAsBytesSync([0, 0, 0, 0x18, 0x66, 0x74]);
      final reader = RoutingMetadataReader(native: _ThrowingReader());
      final meta = await reader.read(heic.path);
      expect(meta.width, isNull);
    });
  });

  group('PhotoMetadata.fromChannel', () {
    test('maps the native reader\'s reply', () {
      final meta = PhotoMetadata.fromChannel({
        'width': 4032,
        'height': 3024,
        'orientation': 6,
        'make': 'Apple',
        'model': 'iPhone 14',
        'dateTimeOriginal': '2026:11:15 09:12:33',
        'offsetTimeOriginal': '+08:00',
        'focalLength35mm': 26,
      });
      expect(meta.width, 3024, reason: 'orientation 6 swaps');
      expect(meta.height, 4032);
      expect(meta.make, 'Apple');
      expect(meta.capturedAt, DateTime.utc(2026, 11, 15, 1, 12, 33));
      expect(meta.focalLength35mm, 26);
    });

    test('a null reply is empty metadata', () {
      expect(PhotoMetadata.fromChannel(null).width, isNull);
    });
  });
}

class _FakeReader implements PhotoMetadataReader {
  _FakeReader(this.result);
  final PhotoMetadata result;
  final paths = <String>[];

  @override
  Future<PhotoMetadata> read(String path) async {
    paths.add(path);
    return result;
  }
}

class _ThrowingReader implements PhotoMetadataReader {
  @override
  Future<PhotoMetadata> read(String path) => throw Exception('channel gone');
}
