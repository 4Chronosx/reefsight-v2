import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:reefsight_mobile/services/bleaching_classifier.dart';

// Sub-plan 18 step 1: the isolate pass that already cuts each colony's
// 224x224 classifier crop also cuts its context photo (longest side 320,
// JPEG q85) from the same decoded frame. The native classifier isn't
// available under `flutter test`, so this drives the isolate function
// directly.

Uint8List _frameJpeg({int width = 640, int height = 480}) {
  final frame = img.Image(width: width, height: height);
  img.fill(frame, color: img.ColorRgb8(30, 120, 160));
  return Uint8List.fromList(img.encodeJpg(frame));
}

void main() {
  group('cutColonyImages', () {
    test('cuts a 224x224 crop and a 320-long context photo per region', () {
      final images = cutColonyImages((
        frameBytes: _frameJpeg(),
        regions: [(left: 10, top: 10, width: 100, height: 50)],
        contexts: [(left: 0, top: 0, width: 200, height: 100)],
      ));

      expect(images, hasLength(1));
      final crop = img.decodeJpg(images.single.crop)!;
      expect((crop.width, crop.height), (224, 224));
      final context = img.decodeJpg(images.single.context!)!;
      expect((context.width, context.height), (320, 160));
    });

    test('a portrait context keeps its aspect, 320 on the long side', () {
      final images = cutColonyImages((
        frameBytes: _frameJpeg(),
        regions: [(left: 0, top: 0, width: 10, height: 10)],
        contexts: [(left: 0, top: 0, width: 60, height: 240)],
      ));

      final context = img.decodeJpg(images.single.context!)!;
      expect((context.width, context.height), (80, 320));
    });

    test('a region with no context box gets no context photo', () {
      final images = cutColonyImages((
        frameBytes: _frameJpeg(),
        regions: [
          (left: 0, top: 0, width: 10, height: 10),
          (left: 20, top: 20, width: 10, height: 10),
        ],
        contexts: [null, (left: 0, top: 0, width: 40, height: 40)],
      ));

      expect(images, hasLength(2));
      expect(images[0].context, isNull);
      expect(images[1].context, isNotNull);
    });

    test('an undecodable frame yields no images', () {
      final images = cutColonyImages((
        frameBytes: Uint8List.fromList([1, 2, 3]),
        regions: [(left: 0, top: 0, width: 10, height: 10)],
        contexts: [null],
      ));

      expect(images, isEmpty);
    });
  });
}
