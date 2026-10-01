import 'package:flutter/foundation.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// Keeps the device screen from auto-locking -- sub-plan 11 step 1.
///
/// iOS doesn't disable Auto-Lock just because the camera is running. If the
/// phone locks mid-transect, Live goes to the background, the capture
/// session is interrupted, and inference and recording both stop -- and
/// nobody can tap a sealed housing to wake it. Behind an interface so a
/// test can check that enable and disable are paired.
abstract interface class ScreenAwake {
  Future<void> enable();
  Future<void> disable();
}

/// The real [ScreenAwake]: `wakelock_plus` (`UIApplication.idleTimerDisabled`
/// on iOS, `FLAG_KEEP_SCREEN_ON` on Android).
class WakelockScreenAwake implements ScreenAwake {
  const WakelockScreenAwake();

  @override
  Future<void> enable() => WakelockPlus.enable();

  @override
  Future<void> disable() => WakelockPlus.disable();
}

/// Holds the screen awake for exactly one Live session.
///
/// Fire-and-forget, matching `live_transect_screen.dart`'s
/// `.catchError(...)`-and-log pattern for non-critical platform calls: a
/// wakelock failure must never block or fail the transect. [release] is
/// idempotent, because both `_endTransect` and the `dispose` that follows
/// it call it. [acquire] always re-enables, so calling it again on
/// `AppLifecycleState.resumed` reasserts the lock if the OS dropped it while
/// the app was in the background.
class ScreenAwakeLease {
  ScreenAwakeLease(this._screenAwake);

  final ScreenAwake _screenAwake;
  bool _held = false;

  void acquire() {
    _held = true;
    _screenAwake.enable().catchError((Object error) {
      debugPrint('ReefSight: failed to keep the screen awake: $error');
    });
  }

  void release() {
    if (!_held) return;
    _held = false;
    _screenAwake.disable().catchError((Object error) {
      debugPrint('ReefSight: failed to release the screen wakelock: $error');
    });
  }
}
