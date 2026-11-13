import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show MethodChannel;
import 'package:image/image.dart' as img;

import 'photo_transect_store.dart' show jpegPixelSize;

/// Issue #5: what an imported photo's header says, read without decoding
/// the image (a 12 MP JPEG is ~4 MB; a whole import is ~250 MB).
///
/// [width]/[height] are as the photo is **displayed** -- EXIF orientation
/// applied, so an orientation 5-8 photo has its stored width and height
/// swapped. Flutter shows photos that way, and the corner editor stores its
/// corners against what it shows, so the size has to match (see
/// `../docs/photo-import-ordering-and-frame-corners.md`).
class PhotoMetadata {
  const PhotoMetadata({
    this.width,
    this.height,
    this.orientation = 1,
    this.make,
    this.model,
    this.capturedAt,
    this.focalLength35mm,
  });

  /// From the native reader's reply (`reefsight/device` `photoMetadata`).
  /// The native side reports the stored size; orientation is applied here,
  /// the same as for a JPEG read in Dart.
  factory PhotoMetadata.fromChannel(Map<Object?, Object?>? reply) {
    if (reply == null) return const PhotoMetadata();
    return _oriented(
      width: (reply['width'] as num?)?.toInt(),
      height: (reply['height'] as num?)?.toInt(),
      orientation: (reply['orientation'] as num?)?.toInt() ?? 1,
      make: _clean(reply['make'] as String?),
      model: _clean(reply['model'] as String?),
      capturedAt: parseExifDateTime(reply['dateTimeOriginal'] as String?, reply['offsetTimeOriginal'] as String?),
      focalLength35mm: (reply['focalLength35mm'] as num?)?.toInt(),
    );
  }

  final int? width;
  final int? height;

  /// EXIF orientation, 1-8; 1 when absent.
  final int orientation;
  final String? make;
  final String? model;

  /// `DateTimeOriginal`. With `OffsetTimeOriginal` it's the exact instant
  /// (UTC); without, the camera's wall clock read as local time -- cameras
  /// rarely know their time zone, and every photo of one import shares it.
  final DateTime? capturedAt;

  /// `FocalLengthIn35mmFilm`; a very short one suggests a fisheye lens.
  final int? focalLength35mm;

  int? get pixelCount => width == null || height == null ? null : width! * height!;
}

/// JPEG magic bytes (SOI then a marker), whatever the file is called.
bool isJpeg(Uint8List head) => head.length >= 3 && head[0] == 0xFF && head[1] == 0xD8 && head[2] == 0xFF;

/// EXIF's `YYYY:MM:DD HH:MM:SS`, with `OffsetTimeOriginal`'s `+HH:MM` when
/// there is one. `null` for a blank, all-zero or malformed time; a
/// malformed offset is ignored (the time is kept as local).
DateTime? parseExifDateTime(String? raw, [String? offset]) {
  final text = _clean(raw);
  if (text == null) return null;
  final m = RegExp(r'^(\d{4}):(\d{2}):(\d{2})[ T](\d{2}):(\d{2}):(\d{2})').firstMatch(text);
  if (m == null) return null;
  final f = [for (var i = 1; i <= 6; i++) int.parse(m.group(i)!)];
  if (f[0] == 0 || f[1] < 1 || f[1] > 12 || f[2] < 1 || f[2] > 31) return null;

  final o = RegExp(r'^([+-])(\d{2}):(\d{2})$').firstMatch(_clean(offset) ?? '');
  if (o == null) return DateTime(f[0], f[1], f[2], f[3], f[4], f[5]);
  final sign = o.group(1) == '-' ? -1 : 1;
  final shift = Duration(hours: int.parse(o.group(2)!), minutes: int.parse(o.group(3)!)) * sign;
  return DateTime.utc(f[0], f[1], f[2], f[3], f[4], f[5]).subtract(shift);
}

/// Size from the SOF header and the EXIF fields from APP1. Never throws:
/// a photo whose header can't be read imports with empty metadata, and the
/// checks flag what's missing.
PhotoMetadata parseJpegMetadata(Uint8List bytes) {
  final size = jpegPixelSize(bytes);
  img.ExifData? exif;
  try {
    exif = img.decodeJpgExif(bytes);
  } catch (error) {
    debugPrint('ReefSight: unreadable EXIF: $error');
  }
  if (exif == null) return PhotoMetadata(width: size?.width, height: size?.height);

  final ifd0 = exif.imageIfd;
  final sub = exif.exifIfd;
  return _oriented(
    width: size?.width,
    height: size?.height,
    orientation: ifd0['Orientation']?.toInt() ?? 1,
    make: _clean(ifd0['Make']?.toString()),
    model: _clean(ifd0['Model']?.toString()),
    capturedAt: parseExifDateTime(sub['DateTimeOriginal']?.toString(), sub['OffsetTimeOriginal']?.toString()),
    focalLength35mm: sub['FocalLengthIn35mmFilm']?.toInt(),
  );
}

PhotoMetadata _oriented({
  required int? width,
  required int? height,
  required int orientation,
  String? make,
  String? model,
  DateTime? capturedAt,
  int? focalLength35mm,
}) {
  final o = orientation < 1 || orientation > 8 ? 1 : orientation;
  final swap = o >= 5;
  return PhotoMetadata(
    width: swap ? height : width,
    height: swap ? width : height,
    orientation: o,
    make: make,
    model: model,
    capturedAt: capturedAt,
    focalLength35mm: focalLength35mm,
  );
}

/// EXIF strings are fixed-width and NUL-padded.
String? _clean(String? s) {
  if (s == null) return null;
  final t = s.replaceAll('\u0000', '').trim();
  return t.isEmpty ? null : t;
}

abstract interface class PhotoMetadataReader {
  /// Never throws for a bad or unreadable photo; returns what it could read.
  Future<PhotoMetadata> read(String path);
}

/// JPEGs (GoPros, most cameras, "Most Compatible" iPhones), in Dart. Reads
/// only the start of the file: EXIF (at most 64 KB) and the SOF header sit
/// ahead of the image data. Falls back to the whole file if the size isn't
/// in that window (a camera with a very large embedded preview).
class DartJpegMetadataReader implements PhotoMetadataReader {
  const DartJpegMetadataReader();

  static const int _headBytes = 512 * 1024;

  @override
  Future<PhotoMetadata> read(String path) async {
    try {
      final head = await _readHead(path, _headBytes);
      final meta = parseJpegMetadata(head);
      if (meta.width != null || head.length < _headBytes) return meta;
      return parseJpegMetadata(await File(path).readAsBytes());
    } catch (error) {
      debugPrint('ReefSight: could not read $path: $error');
      return const PhotoMetadata();
    }
  }
}

Future<Uint8List> _readHead(String path, int bytes) async {
  final file = await File(path).open();
  try {
    return await file.read(bytes);
  } finally {
    await file.close();
  }
}

/// HEIC and anything else Dart can't parse (an iPhone's default format),
/// through ImageIO on the `reefsight/device` channel (`AppDelegate.swift`).
class NativePhotoMetadataReader implements PhotoMetadataReader {
  const NativePhotoMetadataReader();

  static const _channel = MethodChannel('reefsight/device');

  @override
  Future<PhotoMetadata> read(String path) async {
    final reply = await _channel.invokeMapMethod<Object?, Object?>('photoMetadata', {'path': path});
    return PhotoMetadata.fromChannel(reply);
  }
}

/// Chooses the reader by the file's magic bytes, not its name: JPEGs in
/// Dart (testable off-device), the rest natively. A reader that fails gives
/// empty metadata, so one odd file never stops an import.
class RoutingMetadataReader implements PhotoMetadataReader {
  const RoutingMetadataReader({
    this.jpeg = const DartJpegMetadataReader(),
    this.native = const NativePhotoMetadataReader(),
  });

  final PhotoMetadataReader jpeg;
  final PhotoMetadataReader native;

  @override
  Future<PhotoMetadata> read(String path) async {
    try {
      final head = await _readHead(path, 4);
      return await (isJpeg(head) ? jpeg : native).read(path);
    } catch (error) {
      debugPrint('ReefSight: could not read $path: $error');
      return const PhotoMetadata();
    }
  }
}
