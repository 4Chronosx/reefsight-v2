import 'package:camera/camera.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reefsight_mobile/services/lens_calibration.dart';
import 'package:reefsight_mobile/services/still_camera.dart';

// Issue #14: choosing the main or the ultra-wide lens for stills. The iOS
// plugin lists each physical lens with its type; Android reports `unknown`.

CameraDescription _cam(String name, CameraLensDirection dir, CameraLensType type) =>
    CameraDescription(name: name, lensDirection: dir, sensorOrientation: 90, lensType: type);

void main() {
  final iphone = [
    _cam('wide', CameraLensDirection.back, CameraLensType.wide),
    _cam('ultra', CameraLensDirection.back, CameraLensType.ultraWide),
    _cam('front', CameraLensDirection.front, CameraLensType.wide),
  ];

  test('the main lens is the back wide camera', () {
    expect(pickBackCamera(iphone, CameraLens.main)!.name, 'wide');
  });

  test('the ultra-wide is picked by its lens type, wherever it is listed', () {
    expect(pickBackCamera(iphone, CameraLens.ultraWide)!.name, 'ultra');
    expect(pickBackCamera(iphone.reversed.toList(), CameraLens.ultraWide)!.name, 'ultra');
  });

  test('unknown lens types: main falls back to the first back camera, ultra-wide to none', () {
    final android = [
      _cam('front', CameraLensDirection.front, CameraLensType.unknown),
      _cam('0', CameraLensDirection.back, CameraLensType.unknown),
      _cam('2', CameraLensDirection.back, CameraLensType.unknown),
    ];
    expect(pickBackCamera(android, CameraLens.main)!.name, '0');
    expect(pickBackCamera(android, CameraLens.ultraWide), isNull);
  });

  test('a front camera is never picked', () {
    final frontOnly = [_cam('front', CameraLensDirection.front, CameraLensType.ultraWide)];
    expect(pickBackCamera(frontOnly, CameraLens.main), isNull);
    expect(pickBackCamera(frontOnly, CameraLens.ultraWide), isNull);
  });
}
