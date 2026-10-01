import 'package:flutter_test/flutter_test.dart';
import 'package:reefsight_mobile/services/screen_awake.dart';

// Sub-plan 11 step 1: Live keeps the screen awake for exactly its own
// lifetime. `LiveTransectScreen` itself has no widget test (`YOLOView` is a
// platform view), so the enable/disable pairing is pinned down here, on the
// lease the screen calls from `initState`, `dispose` and `_endTransect`.

class _FakeScreenAwake implements ScreenAwake {
  final calls = <String>[];
  bool failEnable = false;
  bool failDisable = false;

  @override
  Future<void> enable() async {
    calls.add('enable');
    if (failEnable) throw StateError('enable failed');
  }

  @override
  Future<void> disable() async {
    calls.add('disable');
    if (failDisable) throw StateError('disable failed');
  }
}

void main() {
  group('ScreenAwakeLease', () {
    late _FakeScreenAwake fake;
    late ScreenAwakeLease lease;

    setUp(() {
      fake = _FakeScreenAwake();
      lease = ScreenAwakeLease(fake);
    });

    test('acquire on init, release on dispose: enable then disable', () async {
      lease.acquire();
      lease.release();
      await pumpEventQueue();

      expect(fake.calls, ['enable', 'disable']);
    });

    test('release on End Transect, then again on dispose: disables once', () async {
      lease.acquire();
      lease.release();
      lease.release();
      await pumpEventQueue();

      expect(fake.calls, ['enable', 'disable']);
    });

    test('release without acquire does nothing', () async {
      lease.release();
      await pumpEventQueue();

      expect(fake.calls, isEmpty);
    });

    test('re-acquiring on resume re-enables, and one release still disables',
        () async {
      lease.acquire();
      lease.acquire();
      lease.release();
      await pumpEventQueue();

      expect(fake.calls, ['enable', 'enable', 'disable']);
    });

    test('a failing wakelock never throws into the caller', () async {
      fake
        ..failEnable = true
        ..failDisable = true;

      expect(lease.acquire, returnsNormally);
      expect(lease.release, returnsNormally);
      // An unhandled async error here would fail the test.
      await pumpEventQueue();

      expect(fake.calls, ['enable', 'disable']);
    });
  });
}
