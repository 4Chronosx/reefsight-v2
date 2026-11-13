import 'package:flutter_test/flutter_test.dart';
import 'package:reefsight_mobile/services/frame_corners.dart';

// Issue #5: the 1 x 1 m area's four corners -- normalized, put in image
// order (TL, TR, BR, BL) whatever order they were dragged to, and checked
// to be a real, convex quadrilateral before they're saved.

void main() {
  test('the default shape is a centered square inside the image', () {
    final c = defaultCorners();
    expect(c, hasLength(4));
    expect(c.every((p) => p.x > 0 && p.x < 1 && p.y > 0 && p.y < 1), isTrue);
    expect(isValidFrame(c), isTrue);
  });

  test('orderCorners: TL, TR, BR, BL from any starting order', () {
    const tl = (x: 0.1, y: 0.15), tr = (x: 0.85, y: 0.1), br = (x: 0.9, y: 0.9), bl = (x: 0.12, y: 0.8);
    expect(orderCorners([br, tl, bl, tr]), [tl, tr, br, bl]);
    expect(orderCorners([tr, br, bl, tl]), [tl, tr, br, bl]);
    expect(orderCorners([bl, br, tr, tl]), [tl, tr, br, bl]);
  });

  test('a frame seen at an angle (a trapezoid) is valid', () {
    expect(isValidFrame(const [(x: 0.3, y: 0.2), (x: 0.7, y: 0.2), (x: 0.95, y: 0.9), (x: 0.05, y: 0.9)]), isTrue);
  });

  test('a crossed (bow-tie) shape is not', () {
    expect(isValidFrame(const [(x: 0.1, y: 0.1), (x: 0.9, y: 0.9), (x: 0.9, y: 0.1), (x: 0.1, y: 0.9)]), isFalse);
  });

  test('a concave (dart) shape is not', () {
    expect(isValidFrame(const [(x: 0.1, y: 0.1), (x: 0.5, y: 0.6), (x: 0.9, y: 0.1), (x: 0.5, y: 0.9)]), isFalse);
  });

  test('a collapsed or tiny shape is not', () {
    expect(isValidFrame(const [(x: 0.1, y: 0.1), (x: 0.5, y: 0.1), (x: 0.9, y: 0.1), (x: 0.5, y: 0.1)]), isFalse);
    expect(isValidFrame(const [(x: 0.5, y: 0.5), (x: 0.51, y: 0.5), (x: 0.51, y: 0.51), (x: 0.5, y: 0.51)]), isFalse);
  });

  test('not four points is not', () {
    expect(isValidFrame(const [(x: 0.1, y: 0.1), (x: 0.9, y: 0.1), (x: 0.9, y: 0.9)]), isFalse);
  });

  test('clampNorm keeps a dragged corner inside the image', () {
    expect(clampNorm((x: -0.2, y: 1.4)), (x: 0.0, y: 1.0));
    expect(clampNorm((x: 0.3, y: 0.4)), (x: 0.3, y: 0.4));
  });

  test('quadArea of the unit square, in normalized units', () {
    expect(quadArea(const [(x: 0, y: 0), (x: 1, y: 0), (x: 1, y: 1), (x: 0, y: 1)]), closeTo(1, 1e-9));
  });
}
